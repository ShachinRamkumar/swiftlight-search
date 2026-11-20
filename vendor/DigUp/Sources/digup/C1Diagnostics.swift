import CryptoKit
import Darwin
import DigUpCoreAIRuntime
import DigUpKit
import Foundation

private func h2hCPUSeconds() -> Double {
    var value=rusage()
    getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec)+Double(value.ru_utime.tv_usec)/1e6+Double(value.ru_stime.tv_sec)+Double(value.ru_stime.tv_usec)/1e6
}

private final class C1Exit: @unchecked Sendable { var code: Int32=1 }

func c1Diagnostic(_ args: Arguments) throws -> Int32 {
    try RuntimeCacheIdentity.requireDiagnosticHelper()
    guard let input=args.values["--inputs"], let output=args.values["--output"] else { throw CLIError("c1-check needs --inputs JSON --output JSON") }
    let result=C1Exit(), done=DispatchSemaphore(value:0)
    Thread.detachNewThread {
        defer { done.signal() }
        do {
            guard #available(macOS 27, *) else { throw CLIError("Core AI requires macOS 27") }
            let config=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:input))) as! [String:Any]
            let data=try runC1Diagnostic(config)
            try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
            result.code=0
        } catch { emit(["event":"error","message":"\(error)"]); result.code=1 }
    }
    done.wait(); return result.code
}

@available(macOS 27, *)
private func runC1Diagnostic(_ config: [String:Any]) throws -> [String:Any] {
    if (config["mode"] as? String)?.hasPrefix("cache-") == true { return try cacheDiagnostic(config) }
    if (config["mode"] as? String)?.hasPrefix("video-") == true { return try videoDiagnostic(config) }
    let started=ProcessInfo.processInfo.systemUptime
    let mode=config["mode"] as! String
    let runtime=try RuntimeDirectory(URL(fileURLWithPath:config["runtime"] as! String))
    let resources: SharedHostResources?
    if ["tokens","text","prep","audio-prep"].contains(mode) {
        resources=try runtime.hostResources()
    } else { resources=nil }
    let cases=config["cases"] as? [[String:Any]] ?? []
    var rows: [[String:Any]]=[]
    if mode == "tokens" {
        let resources=resources!
        for c in cases { for limit in [512,2048] {
            let actual=try resources.withText { tok,_ in try tok.tokenize(c["text"] as! String,limit:limit) }
            guard actual == (c["ids\(limit)"] as! [NSNumber]).map(\.uint32Value) else { throw CLIError("token mismatch: \(c["id"]!) \(limit)") }
        } }
        return ["passed":true,"arrays":cases.count*2]
    }
    if mode == "function-golden" {
        let embedder = try runtime.embedder(.document)
        defer { embedder.close() }
        let resources = try runtime.hostResources()
        for c in cases {
            let bucket = c["bucket"] as! Int
            let ids = (c["ids"] as! [NSNumber]).map(\.uint32Value)
            let inputs = try resources.withText { _, host in try host.prepare(ids, bucket: bucket) }
            let vector = try TextHostPrep.finalize(embedder.rawOutput(inputs, bucket: bucket))
            let expected = (c["unit"] as! [NSNumber]).map(\.doubleValue)
            let actual = vector.map(Double.init)
            let dot = zip(actual, expected).reduce(0.0) { $0 + $1.0 * $1.1 }
            let norm = (actual.reduce(0.0) { $0 + $1*$1 } * expected.reduce(0.0) { $0 + $1*$1 }).squareRoot()
            let cosine = dot / norm
            guard vector.allSatisfy(\.isFinite), cosine >= 0.9999 else { throw CLIError("full text golden failed: \(c["id"]!), cosine=\(cosine)") }
            rows.append(["id": c["id"]!, "bucket": bucket, "cosine": cosine])
        }
    } else if mode == "text" {
        let resources=resources!
        for role in [TextRole.query,.document] {
            let embedder=try runtime.embedder(role)
            defer { embedder.close() }
            for c in cases where ((c["bucket"] as! Int)<=128) == (role == .query) {
                let bucket=c["bucket"] as! Int
                let ids=(c["ids"] as! [NSNumber]).map(\.uint32Value)
                let inputs=try resources.withText { _,host in try host.prepare(ids,bucket:bucket) }
                let expected=c["inputs"] as! [String:[String:Any]]
                for name in TextHostPrep.inputNames {
                    guard try inputs[name]!.bytes == Data(contentsOf:URL(fileURLWithPath:expected[name]!["file"] as! String)) else { throw CLIError("text host mismatch \(c["id"]!) \(name)") }
                }
                let raw=try embedder.rawOutput(inputs,bucket:bucket)
                guard try raw.withUnsafeBytes({ Data($0) }) == Data(contentsOf:URL(fileURLWithPath:c["output"] as! String)) else { throw CLIError("text output mismatch \(c["id"]!)") }
                rows.append(["id":c["id"]!,"passed":true])
            }
        }
    } else if mode == "audio-prep" {
        let audio=try AudioHostPrep(folder:runtime.directory.appendingPathComponent("audio-host"))
        for c in cases {
            let pcm=try PCM16.decode(URL(fileURLWithPath:c["path"] as! String))
            let mel=try audio.mel(pcm)
            let expected=try Data(contentsOf:URL(fileURLWithPath:c["features"] as! String)).withUnsafeBytes { Array($0.bindMemory(to:Double.self)) }
            let mask=(c["mask"] as! [Bool])
            guard mel.mask == mask, mel.tokens == c["tokens"] as! Int, mel.features.count == expected.count else { throw CLIError("audio mask/count mismatch: \(c["id"]!)") }
            let error=zip(mel.features,expected).map { abs(Double($0)-$1) }.max() ?? 0
            let bound=config["bound"] as! Double
            guard error <= bound else { throw CLIError("audio mel mismatch: \(c["id"]!) max=\(error) bound=\(bound)") }
            // Composition/input byte gates receive exactly the Python features, independent of FFT rounding.
            let referenceMel=AudioHostPrep.Mel(features:expected.map(Float.init),mask:mask)
            let prepared=try audio.prepare(referenceMel)
            for (name,digest) in c["input_hashes"] as! [String:String] {
                let actual=SHA256.hash(data:prepared[name]!.bytes).map { String(format:"%02x",$0) }.joined()
                guard actual==digest else { throw CLIError("audio input byte mismatch: \(c["id"]!) \(name)") }
            }
            let soft=try Data(contentsOf:URL(fileURLWithPath:c["soft"] as! String)).withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) }
            let composed=try resources!.withText { _,host in try AudioHostPrep.compose(soft,tokens:mel.tokens,host:host) }
            for (name,digest) in c["text_hashes"] as! [String:String] {
                let actual=SHA256.hash(data:composed.inputs[name]!.bytes).map { String(format:"%02x",$0) }.joined()
                guard actual==digest else { throw CLIError("audio composition byte mismatch: \(c["id"]!) \(name)") }
            }
            rows.append(["id":c["id"]!,"max_abs":error,"tokens":mel.tokens,"frames":mel.mask.count,"byte_exact":true])
        }
    } else if mode == "prep" {
        let resources=resources!
        for c in cases {
            let rgb=try RGBImage(width:c["width"] as! Int,height:c["height"] as! Int,
                pixels:Array(Data(contentsOf:URL(fileURLWithPath:c["rgb"] as! String))))
            let budget=c["budget"] as! Int
            let prepared=try resources.withVision { vision,_ in try vision.prepare(rgb,budget:budget) }
            for name in VisionHostPrep.inputNames {
                let expected=try Data(contentsOf:URL(fileURLWithPath:(c["inputs"] as! [String:String])[name]!))
                guard prepared.inputs[name]!.bytes == expected else {
                    let bits=prepared.inputs[name]!.bytes
                    let first=zip(bits,expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    throw CLIError("vision prep mismatch \(c["id"]!) \(name) first byte \(String(describing:first))")
                }
            }
            if let file=c["soft"] as? String {
                let soft=try Data(contentsOf:URL(fileURLWithPath:file)).withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) }
                let composed=try resources.withVision { _,host in try VisionHostPrep.compose(soft,tokens:prepared.tokens,budget:budget,host:host) }
                for (name,path) in c["text_inputs"] as! [String:String] {
                    guard try composed.inputs[name]!.bytes == Data(contentsOf:URL(fileURLWithPath:path)) else { throw CLIError("image text composition mismatch \(c["id"]!) \(name)") }
                }
            }
            rows.append(["id":c["id"]!,"passed":true,"tokens":prepared.tokens])
        }
    } else if mode == "audio-rebuild" {
        let store=try IndexStore(directory:URL(fileURLWithPath:config["index"] as! String))
        let scratch=URL(fileURLWithPath:config["scratch"] as! String)
        for c in cases {
            let id=(c["segment"] as! NSNumber).int64Value,start=Date()
            do {
                let input=try store.rebuildAudio(segment:id,scratch:scratch)
                rows.append(["segment":id,"path":input.path,"prepared":input.prepared.path,"start":input.start,"end":input.end,
                    "content_rev":input.contentRev.map { String(format:"%02x",$0) }.joined(),"identity":input.identity,"rebuild_seconds":Date().timeIntervalSince(start)])
            } catch { rows.append(["segment":id,"error":"\(error)"]) }
        }
    } else if mode == "audio-reference-inputs" {
        let embedder=try runtime.embedder(.document)
        defer { embedder.close() }
        let audio=try AudioHostPrep(folder:runtime.directory.appendingPathComponent("audio-host"))
        let shared=try runtime.hostResources()
        for c in cases {
            let features=try Data(contentsOf:URL(fileURLWithPath:c["features"] as! String)).withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
            let mask=c["mask"] as! [Bool],mel=AudioHostPrep.Mel(features:features,mask:mask)
            let inputs=try audio.prepare(mel)
            let hashes=inputs.mapValues { SHA256.hash(data:$0.bytes).map { String(format:"%02x",$0) }.joined() }
            let soft=try embedder.audioOutput(inputs)
            let composed=try shared.withText { _,host in try AudioHostPrep.compose(soft,tokens:mel.tokens,host:host) }
            let raw=try embedder.rawOutput(composed.inputs,bucket:composed.bucket)
            try soft.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["soft_out"] as! String))
            try raw.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["raw_out"] as! String))
            var row: [String:Any] = ["id":c["id"]!,"hashes":hashes,"tokens":mel.tokens]
            if let path=c["path"] as? String {
                let decoded=try audio.mel(PCM16.decode(URL(fileURLWithPath:path)))
                let decodedInputs=try audio.prepare(decoded)
                row["decoded_input_half_differences"]=Dictionary(uniqueKeysWithValues:AudioHostPrep.inputNames.map { name in
                    (name,zip(inputs[name]!.bits,decodedInputs[name]!.bits).filter { $0 != $1 }.count)
                })
                row["decoded_mel_max_abs_vs_hf"]=zip(features,decoded.features).map { abs($0-$1) }.max() ?? 0
            }
            rows.append(row)
        }
    } else if mode == "audio-embed" {
        let embedder=try runtime.embedder(.document)
        defer { embedder.close() }
        for c in cases {
            let start=Date(),path=c["path"] as! String
            let vector: [Float]
            if c["zero_framing_check"] as? Bool == true {
                let audio=try AudioHostPrep(folder:runtime.directory.appendingPathComponent("audio-host"))
                let mel=try audio.mel(PCM16.decode(URL(fileURLWithPath:path)))
                guard mel.tokens==0,try embedder.embedAudio([path])[0].vector==nil else { throw CLIError("zero audio skip failed") }
                let soft=try embedder.audioOutput(audio.prepare(mel))
                let shared=try runtime.hostResources()
                let text=try shared.withText { _,host in try AudioHostPrep.compose(soft,tokens:0,host:host) }
                vector=try TextHostPrep.finalize(embedder.rawOutput(text.inputs,bucket:text.bucket))
            } else {
                let value=try embedder.embedAudio([path])[0]
                guard let v=value.vector else { throw CLIError(value.error ?? "audio embedding failed") }
                vector=v
            }
            try vector.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["vector_out"] as! String))
            rows.append(["id":c["id"]!,"seconds":Date().timeIntervalSince(start),"audio_timings":try JSONSerialization.jsonObject(with:JSONEncoder().encode(embedder.lastAudioTimings))])
            RuntimeDiagnostics.mark("audio_item")
        }
        if config["idle_probe"] as? Bool == true {
            let before=try embedder.loadedAssets()
            Thread.sleep(forTimeInterval:31)
            let after=try embedder.loadedAssets(),start=Date()
            guard !after.contains("audio") else { throw CLIError("audio was not released after idle deadline") }
            _=try embedder.embedAudio([cases[0]["path"] as! String])
            rows.append(["idle_before":before,"idle_after":after,"reload_e2e_seconds":Date().timeIntervalSince(start)])
        }
    } else if mode == "h2h-inputs" {
        let store=try IndexStore(directory:URL(fileURLWithPath:config["index"] as! String))
        let scratch=URL(fileURLWithPath:config["scratch"] as! String)
        for c in cases {
            let id=(c["segment"] as! NSNumber).int64Value
            if c["modality"] as! String == "text" {
                let input=try store.rebuildInput(segment:id,scratch:scratch)
                try input.text.write(toFile:c["text_file"] as! String,atomically:true,encoding:.utf8)
                rows.append(["segment":id,"content_rev":input.contentRev.map { String(format:"%02x",$0) }.joined()])
            } else {
                let image=try store.rebuildImage(segment:id,scratch:scratch)
                rows.append(["segment":id,"path":image.prepared.path,"budget":image.budget,
                    "content_rev":image.contentRev.map { String(format:"%02x",$0) }.joined()])
            }
        }
    } else if mode == "h2h" {
        let embedder=try runtime.embedder(.document)
        defer { embedder.close() }
        emit(["event":"benchmark_ready","startup_seconds":ProcessInfo.processInfo.systemUptime-started])
        for c in cases {
            let begin=ProcessInfo.processInfo.systemUptime, cpuBegin=h2hCPUSeconds()
            let vector: [Float]
            if config["modality"] as! String == "text" {
                let text=try String(contentsOfFile:c["text_file"] as! String,encoding:.utf8)
                vector=try embedder.embedTexts([text])[0]
            } else {
                let image=try embedder.embedImages([c["path"] as! String],budget:c["budget"] as! Int)[0]
                guard let value=image.vector else { throw CLIError(image.error ?? "no image vector") }
                vector=value
            }
            let elapsed=ProcessInfo.processInfo.systemUptime-begin
            guard vector.count==768 && vector.allSatisfy(\.isFinite) else { throw CLIError("invalid benchmark vector") }
            try vector.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["vector_out"] as! String))
            let row: [String:Any]=["id":c["id"]!,"seconds":elapsed,"cpu_seconds":h2hCPUSeconds()-cpuBegin,"timings":try JSONSerialization.jsonObject(with:JSONEncoder().encode(embedder.lastTimings))]
            rows.append(row);emit(["event":"benchmark_item","row":row])
        }
    } else if mode == "decode" {
        for c in cases {
            let image=try VisionHostPrep.decode(URL(fileURLWithPath:c["path"] as! String))
            try Data(image.pixels).write(to:URL(fileURLWithPath:c["rgb_out"] as! String))
            rows.append(["id":c["id"]!,"width":image.width,"height":image.height])
        }
    } else if mode == "embed" {
        let embedder=try runtime.embedder(.document)
        defer { embedder.close() }
        for c in cases {
            let start=Date()
            let image=try embedder.embedImages([c["path"] as! String],budget:c["budget"] as! Int)[0]
            guard let vector=image.vector else { throw CLIError(image.error ?? "no image vector") }
            let elapsed=Date().timeIntervalSince(start)
            try vector.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["vector_out"] as! String))
            rows.append(["id":c["id"]!,"seconds":elapsed,"timings":try JSONSerialization.jsonObject(with:JSONEncoder().encode(embedder.lastTimings))])
        }
        if config["idle_probe"] as? Bool == true {
            let before=try embedder.loadedAssets()
            Thread.sleep(forTimeInterval:31)
            let after=try embedder.loadedAssets()
            let c=cases[0], start=Date()
            _=try embedder.embedImages([c["path"] as! String],budget:c["budget"] as! Int)
            rows.append(["idle_before":before,"idle_after":after,"reload_e2e_seconds":Date().timeIntervalSince(start)])
        }
    } else if mode == "rebuild" {
        let store=try IndexStore(directory:URL(fileURLWithPath:config["index"] as! String))
        let scratch=URL(fileURLWithPath:config["scratch"] as! String)
        for c in cases {
            let id=(c["segment"] as! NSNumber).int64Value, start=Date()
            do {
                let image=try store.rebuildImage(segment:id,scratch:scratch)
                rows.append(["segment":id,"path":image.path,"prepared":image.prepared.path,"budget":image.budget,
                    "content_rev":image.contentRev.map { String(format:"%02x",$0) }.joined(),"prep_seconds":Date().timeIntervalSince(start)])
            } catch { rows.append(["segment":id,"error":"\(error)"]) }
        }
    } else { throw CLIError("unknown c1-check mode") }
    return ["passed":true,"mode":mode,"cases":rows.count,"rows":rows]
}
