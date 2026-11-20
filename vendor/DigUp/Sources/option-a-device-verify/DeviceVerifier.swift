import Darwin
import CoreAI
import DigUpCoreAIRuntime
import DigUpKit
import Foundation
import OptionAVerificationSupport

@available(macOS 27, *)
func deletePurgedResearchEntry(bookmark: Data) throws {
    let value = try JSONSerialization.jsonObject(with: bookmark) as! [String: Any]
    let identity = value["entryIdentifier"] as! [String: String]
    guard let model = identity["modelHash"], model.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let options = identity["optionsHash"], options.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
        throw VerificationError("invalid research bookmark")
    }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/coreai-cache")
        .appendingPathComponent(RuntimeCacheIdentity.osBuild).appendingPathComponent(OptionAVerification.namespace)
        .appendingPathComponent(model).appendingPathComponent(options)
    guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw VerificationError("research entry missing") }
    var hashes: [String] = []
    for case let path as URL in paths where path.lastPathComponent == "manifest.plist" {
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any]
        for version in (value?["Package Version"] as? [String: [String: Any]] ?? [:]).values {
            hashes += Array((version["ANERegionsHash"] as? [String: String] ?? [:]).values)
        }
    }
    guard !hashes.isEmpty else { throw VerificationError("cannot prove protected program cleanup") }
    let process = Process(), pipe = Pipe()
    process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftlight-research/single-model/bin/AnePurge")
    let signing = Process(), signingOutput = Pipe()
    signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signing.arguments = ["-dv", process.executableURL!.path]
    signing.standardError = signingOutput
    try signing.run()
    let identityText = String(decoding: signingOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    signing.waitUntilExit()
    guard signing.terminationStatus == 0, identityText.components(separatedBy: "\n").contains("Identifier=" + OptionAVerification.namespace) else {
        throw VerificationError("purge tool has a different research signing identity")
    }
    process.arguments = ["purge-if-exists"] + hashes
    process.standardOutput = pipe
    try process.run()
    let result = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
    process.waitUntilExit()
    guard process.terminationStatus == 0, let rows = result?["rows"] as? [[String: Any]], rows.count == hashes.count,
          rows.allSatisfy({ $0["after"] as? Bool == false }) else { throw VerificationError("research ANE program purge failed") }
    try AIModelCache.deleteEntry(referencedBy: bookmark)
}

@available(macOS 27, *)
func deletePurgedResearchSource(_ source: URL, options: SpecializationOptions) throws {
    if let model = try AIModelCache.default.model(for: source, options: options) {
        try deletePurgedResearchEntry(bookmark: model.bookmarkData)
    }
}

struct Job: Decodable {
    let operation: String
    let output: String
    let source: String?
    let bookmark: String?
    let original: String?
    let candidate: String?
    let originalQuery: String?
    let originalDocument: String?
    let originalRuntime: String?
    let stagingRuntime: String?
    let fixtures: String?
    let fixtureID: String?
    let expected: String?
    let reverse: Bool?
    let frequentReshapes: Bool?
    let deleteCaches: Bool?
    let deleteSource: Bool?
    let probeQueries: Bool?
}

@available(macOS 27, *)
struct Sample {
    let bits: [UInt16]
    let inferenceMS: [Double]
    let functionLoadMS: Double
}

@available(macOS 27, *)
final class SetupQueryProbe: @unchecked Sendable {
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    var model: CoreAIEmbedder?
    var phase = ""
    var error: String?
    func finish() { done.wait(); model?.close() }
}

@available(macOS 27, *)
func resolve(_ path: String) throws -> AIModel {
    let url=try OptionAVerification.confined(URL(fileURLWithPath:path))
    guard let model=try AIModel(resolvingBookmark:Data(contentsOf:url)) else { throw VerificationError("bookmark did not resolve: \(path)") }
    return model
}

@available(macOS 27, *)
func run(_ model: AIModel, function name: String, inputs: [String: HostTensor], count: Int = 5) async throws -> Sample {
    let begin=Date()
    guard let function=try model.loadFunction(named:name) else { throw VerificationError("missing function: \(name)") }
    let loadMS=Date().timeIntervalSince(begin)*1000
    var arrays: [String:NDArray]=[:]
    for (name,tensor) in inputs {
        guard case .ndArray(let descriptor)=function.descriptor.inputDescriptor(of:name),
              descriptor.scalarType == .float16, descriptor.shape == tensor.shape else { throw VerificationError("input descriptor mismatch: \(name)") }
        var array=NDArray(shape:tensor.shape,scalarType:.float16)
        array.mutableView(as:Float16.self).withUnsafeMutablePointer { pointer,_,_ in
            tensor.bits.withUnsafeBytes { UnsafeMutableRawPointer(pointer).copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
        }
        arrays[name]=array
    }
    var times:[Double]=[], first:[UInt16]?
    for _ in 0..<count {
        try OptionAVerification.space()
        let started=Date()
        var result=try await function.run(inputs:arrays)
        times.append(Date().timeIntervalSince(started)*1000)
        guard let output=result.remove("y")?.ndArray, output.scalarType == .float16 else { throw VerificationError("expected FP16 output y") }
        let shape=output.shape
        let bits=output.view(as:Float16.self).withUnsafePointer { pointer,_,strides in
            (0..<shape.reduce(1,*)).map { flat -> UInt16 in
                var remaining=flat, offset=0
                for axis in shape.indices.reversed() { offset += (remaining % shape[axis])*strides[axis]; remaining /= shape[axis] }
                return pointer[offset].bitPattern
            }
        }
        guard bits.allSatisfy({ Float16(bitPattern:$0).isFinite }) else { throw VerificationError("nonfinite output: \(name)") }
        if let first, first != bits { throw VerificationError("first/warm output bits differ: \(name)") }
        first=bits
    }
    return Sample(bits:first!,inferenceMS:times,functionLoadMS:loadMS)
}

func bytes(_ bits: [UInt16]) -> Data { bits.withUnsafeBytes { Data($0) } }

func sourceManifest(_ source: URL) -> URL {
    let parent = source.deletingLastPathComponent()
    return (parent.lastPathComponent == "function-assets" ? parent.deletingLastPathComponent() : parent)
        .appendingPathComponent("manifest.json")
}

@available(macOS 27, *)
func mixedImage(_ soft: [UInt16], tokens: Int, budget: Int, resources: SharedHostResources) throws -> (inputs: [String: HostTensor], bucket: Int) {
    try resources.withText { tokenizer, host in
        let text = try tokenizer.tokenize("Describe the storage report, 中文, and diagram version 42.", limit: 64)
        let ids: [UInt32] = [2] + text + [255999] + [UInt32](repeating: 258880, count: tokens) + [258882, 1]
        let bucket = try TextHostPrep.bucketFor(ids.count, role: .document)
        var inputs = try host.prepare(ids, bucket: bucket)
        var x = inputs["x"]!.bits
        for c in 0..<512 { for i in 0..<tokens { x[c*bucket+text.count+2+i] = soft[c*budget+i] } }
        inputs["x"] = HostTensor(shape: [1,512,1,bucket], bits: x)
        return (inputs, bucket)
    }
}

@available(macOS 27, *)
func compare(_ old: AIModel, _ new: AIModel, function: String, inputs: [String:HostTensor], reverse: Bool,
             output: URL, label: String, storedVector: String? = nil) async throws -> (Sample,[String:Any]) {
    let a:Sample, b:Sample
    if reverse { b=try await run(new,function:function,inputs:inputs); a=try await run(old,function:function,inputs:inputs) }
    else { a=try await run(old,function:function,inputs:inputs); b=try await run(new,function:function,inputs:inputs) }
    guard a.bits == b.bits else { throw VerificationError("raw FP16 bits differ: \(label)") }
    let oldPath=output.appendingPathComponent(label+"-original.f16"), newPath=output.appendingPathComponent(label+"-candidate.f16")
    try bytes(a.bits).write(to:oldPath); try bytes(b.bits).write(to:newPath)
    var row:[String:Any]=["id":label,"function":function,"raw_bits_equal":true,"elements":a.bits.count,
        "original_inference_ms":a.inferenceMS,"candidate_inference_ms":b.inferenceMS,
        "original_function_load_ms":a.functionLoadMS,"candidate_function_load_ms":b.functionLoadMS,
        "original_raw":oldPath.path,"candidate_raw":newPath.path,"reverse_order":reverse]
    if let storedVector {
        let stored=try Data(contentsOf:OptionAVerification.confined(URL(fileURLWithPath:storedVector)))
        let normalized=try TextHostPrep.finalize(b.bits).map { Float16($0).bitPattern }
        guard stored == bytes(normalized) else { throw VerificationError("normalized FP16 differs from model-2 stored vector: \(label)") }
        row["stored_model_2_vector_equal"]=true
    }
    return (b,row)
}

@available(macOS 27, *)
func fixture(_ job: Job) throws -> SavedFixture {
    let manifest=try OptionAVerification.load(SavedFixtures.self,OptionAVerification.confined(URL(fileURLWithPath:job.fixtures!)))
    guard manifest.hostInputsExact, let selected=manifest.cases.first(where:{$0.id==job.fixtureID}) else { throw VerificationError("missing verified host fixture") }
    return selected
}

@available(macOS 27, *)
func execute(_ job:Job) async throws -> [String:Any] {
    let output=try OptionAVerification.confined(URL(fileURLWithPath:job.output))
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    var options=SpecializationOptions(preferredComputeUnitKind:.neuralEngine)
    options.expectFrequentReshapes = job.frequentReshapes ?? false
    if job.operation == "known-answer" {
        let model = try resolve(job.bookmark!)
        let fixtures = try OptionAVerification.load(SavedFixtures.self, OptionAVerification.confined(URL(fileURLWithPath: job.fixtures!)))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: OptionAVerification.confined(URL(fileURLWithPath: job.expected!)))) as! [String: Any]
        let references = expected["rows"] as! [[String: Any]]
        var rows: [[String: Any]] = []
        for selected in fixtures.cases {
            let result = try await run(model, function: selected.function, inputs: loadInputs(selected), count: 3)
            let reference = references.first { $0["id"] as? String == selected.id }!
            let path = try OptionAVerification.confined(URL(fileURLWithPath: reference["candidate_raw"] as! String))
            guard bytes(result.bits) == (try Data(contentsOf: path)) else { throw VerificationError("rebuilt model differs from known output: \(selected.id)") }
            rows.append(["id": selected.id, "function": selected.function, "raw_bits_equal": true, "inference_ms": result.inferenceMS])
        }
        return ["all_raw_bits_equal": true, "rows": rows]
    }
    if job.operation == "upper-loss" || job.operation == "restore-source" {
        let source = try OptionAVerification.confined(URL(fileURLWithPath: job.source!))
        let runtime = try RuntimeDirectory(source, fullVerify: true)
        let presentBefore = FileManager.default.fileExists(atPath: source.appendingPathComponent("EmbeddingGemma2.aimodel").path)
        if job.operation == "upper-loss" {
            try deletePurgedResearchEntry(bookmark: Data(contentsOf: OptionAVerification.confined(URL(fileURLWithPath: job.bookmark!))))
        }
        let began = Date()
        try runtime.restoreSourceFromDownload()
        let model = source.appendingPathComponent("EmbeddingGemma2.aimodel")
        try RuntimeDirectory.verifyAssetForRecovery(model, manifest: source.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as! [String: Any]
        let hashes = manifest["files"] as! [String: String]
        return ["seconds": Date().timeIntervalSince(began), "source_present_before": presentBefore, "source_restored_and_verified": true,
                "main_sha256": hashes["EmbeddingGemma2.aimodel/main.mlirb"]!]
    }
    if job.operation == "setup" || job.operation == "resume" {
        let source = try OptionAVerification.confined(URL(fileURLWithPath: job.source!))
        let runtime = try RuntimeDirectory(source, fullVerify: true)
        if job.deleteCaches == true {
            for url in [source.appendingPathComponent("EmbeddingGemma2.aimodel"), try OptionAVerification.confined(URL(fileURLWithPath: job.candidate!))] {
                try RuntimeDirectory.verifyAssetForRecovery(url, manifest: sourceManifest(url))
                if try AIModelCache.default.model(for: url, options: options) != nil { try deletePurgedResearchSource(url, options: options) }
            }
            let hash = OptionAVerification.hash(try Data(contentsOf: source.appendingPathComponent("manifest.json")))
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent().appendingPathComponent(".coreai-setup/\(hash)/ready.json"))
        }
        let began = Date()
        var phases: [[String: Any]] = []
        let probe = SetupQueryProbe()
        var probeStarted = false
        defer { if probeStarted { probe.finish() } }
        try runtime.prepareSingleModel(deleteSourceAfterCompile: job.deleteSource ?? false) { phase in
            probe.lock.withLock { probe.phase = phase.rawValue }
            phases.append(["phase": phase.rawValue, "seconds": Date().timeIntervalSince(began)])
            if let data = try? JSONSerialization.data(withJSONObject: phases, options: [.sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("phases.json"), options: .atomic)
            }
            if phase == .loadingDocuments, job.probeQueries == true, !probeStarted {
                probeStarted = true
                Thread.detachNewThread {
                    defer { probe.done.signal() }
                    do {
                        let query = try runtime.embedder(.query)
                        probe.model = query
                        Thread.sleep(forTimeInterval: 2)
                        let phase = probe.lock.withLock { probe.phase }
                        let beganQuery = Date()
                        let vectors = try query.embedTexts([Prompts.query("storage report")])
                        guard vectors.count == 1, vectors[0].count == 768 else { throw VerificationError("query probe vector dimensions") }
                        let report: [String: Any] = ["phase": phase, "seconds_since_setup": Date().timeIntervalSince(began),
                            "query_seconds": Date().timeIntervalSince(beganQuery), "loaded_assets": try query.loadedAssets(), "passed": true]
                        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: output.appendingPathComponent("query-during-setup.json"))
                    } catch { probe.error = String(describing: error) }
                }
            }
        }
        if probeStarted {
            probe.finish()
            probeStarted = false
            if let error = probe.error { throw VerificationError(error) }
        }
        let query = try runtime.embedder(.query)
        defer { query.close() }
        let queryAssets = try query.loadedAssets()
        guard queryAssets.count == 1, queryAssets[0].hasPrefix("query3-") else { throw VerificationError("query did not load only its query group") }
        let hash = OptionAVerification.hash(try Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let bootstrap = source.deletingLastPathComponent().appendingPathComponent(".coreai-setup/\(hash)/bootstrap")
        guard !FileManager.default.fileExists(atPath: bootstrap.path) else { throw VerificationError("temporary query source survived setup") }
        return ["seconds": Date().timeIntervalSince(began), "phases": phases, "query_assets": queryAssets,
                "bootstrap_removed": true, "source_retained": FileManager.default.fileExists(atPath: source.appendingPathComponent("EmbeddingGemma2.aimodel").path), "namespace": OptionAVerification.namespace]
    }
    if job.operation == "delete" {
        let source = try OptionAVerification.confined(URL(fileURLWithPath: job.source!))
        try RuntimeDirectory.verifyAssetForRecovery(source, manifest: sourceManifest(source))
        try deletePurgedResearchSource(source, options: options)
        return ["deleted_exact_research_entry": source.path, "namespace": OptionAVerification.namespace]
    }
    if job.operation == "materialize" {
        let source = try OptionAVerification.confined(URL(fileURLWithPath: job.source!))
        let recipe = try OptionAVerification.confined(URL(fileURLWithPath: job.expected!))
        let root = output.appendingPathComponent("derived")
        let target = root.appendingPathComponent("function-assets/q32.aimodel")
        let began = Date()
        try RuntimeDirectory.materializeSetupQuery(source: source, recipe: recipe, destination: target)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recipe)) as! [String: Any]
        let files = record["files"] as! [String: [String: Any]]
        let hashes = Dictionary(uniqueKeysWithValues: files.map { ("function-assets/q32.aimodel/" + $0.key, $0.value["sha256"] as! String) })
        try JSONSerialization.data(withJSONObject: ["files": hashes, "production_assets": []] as [String: Any], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"))
        try RuntimeDirectory.verifyAssetForRecovery(target, manifest: root.appendingPathComponent("manifest.json"))
        return ["seconds": Date().timeIntervalSince(began), "source": target.path, "files": hashes, "cpu_only": true]
    }
    if job.operation == "prepare" {
        let source=try OptionAVerification.confined(URL(fileURLWithPath:job.source!))
        try RuntimeDirectory.verifyAssetForRecovery(source,manifest:sourceManifest(source))
        try OptionAVerification.space(2_000_000_000)
        let began=Date()
        let model=try await AIModel.specialize(contentsOf:source,options:options,cachePolicy:.persistent)
        let bookmark=try OptionAVerification.confined(URL(fileURLWithPath:job.bookmark!))
        try model.bookmarkData.write(to:bookmark,options:.atomic)
        return ["prepared":source.path,"seconds":Date().timeIntervalSince(began),"functions":model.functionNames,"namespace":OptionAVerification.namespace]
    }
    if job.operation == "recover" {
        let source=try OptionAVerification.confined(URL(fileURLWithPath:job.source!))
        let manifest=sourceManifest(source)
        try RuntimeDirectory.verifyAssetForRecovery(source,manifest:manifest)
        try deletePurgedResearchSource(source, options:options)
        guard try AIModelCache.default.model(for:source,options:options) == nil else { throw VerificationError("targeted compiled entry survived deletion") }
        let began=Date()
        let model=try await AIModel.specialize(contentsOf:source,options:options,cachePolicy:.persistent)
        let seconds=Date().timeIntervalSince(began)
        try model.bookmarkData.write(to:OptionAVerification.confined(URL(fileURLWithPath:job.bookmark!)),options:.atomic)
        let selected=try fixture(job), result=try await run(model,function:selected.function,inputs:loadInputs(selected))
        let expected=try Data(contentsOf:OptionAVerification.confined(URL(fileURLWithPath:job.expected!)))
        guard bytes(result.bits)==expected else { throw VerificationError("recovery output bits changed") }
        try RuntimeDirectory.verifyAssetForRecovery(source,manifest:manifest)
        return ["source_retained_and_verified":true,"deleted_only_exact_entry":source.path,"repair_seconds":seconds,"raw_bits_equal":true,"inference_ms":result.inferenceMS]
    }
    if job.operation == "compare" {
        let selected=try fixture(job), old=try resolve(job.original!), new=try resolve(job.candidate!)
        let (soft,row)=try await compare(old,new,function:selected.function,inputs:loadInputs(selected),reverse:job.reverse ?? false,
                                       output:output,label:selected.id,storedVector:selected.storedVector)
        var rows=[row]
        if selected.family == "vision" {
            let oldHost=try RuntimeDirectory.HostResourcePaths(directory:URL(fileURLWithPath:job.originalRuntime!),compact:false).acquire()
            let newHost=try RuntimeDirectory.HostResourcePaths(directory:URL(fileURLWithPath:job.stagingRuntime!),compact:true).acquire()
            let budget=selected.budget!, tokens=selected.softTokens!
            let a=try oldHost.withText { _,host in try VisionHostPrep.compose(soft.bits,tokens:tokens,budget:budget,host:host) }
            let b=try newHost.withText { _,host in try VisionHostPrep.compose(soft.bits,tokens:tokens,budget:budget,host:host) }
            let inputs=try saveInputs(b.inputs,reference:a.inputs,folder:output.appendingPathComponent("image-composition"))
            let synthetic=SavedFixture(id:"composition",family:"text",function:"",inputs:inputs)
            let function=(b.bucket<=128 ? "q":"d")+String(b.bucket)
            let original=try resolve(b.bucket<=128 ? job.originalQuery! : job.originalDocument!)
            let candidate=try resolve(job.bookmark!)
            let (_,composition)=try await compare(original,candidate,function:function,inputs:loadInputs(synthetic),reverse:job.reverse ?? false,output:output,label:selected.id+"-image-composition")
            rows.append(composition)
            let oldMixed = try mixedImage(soft.bits, tokens: tokens, budget: budget, resources: oldHost)
            let newMixed = try mixedImage(soft.bits, tokens: tokens, budget: budget, resources: newHost)
            let mixedInputs = try saveInputs(newMixed.inputs, reference: oldMixed.inputs, folder: output.appendingPathComponent("mixed-composition"))
            let mixedFixture = SavedFixture(id: "mixed", family: "text", function: "", inputs: mixedInputs)
            let (_, mixed) = try await compare(resolve(job.originalDocument!), candidate, function: "d\(newMixed.bucket)", inputs: loadInputs(mixedFixture),
                reverse: job.reverse ?? false, output: output, label: selected.id + "-mixed-image-text")
            rows.append(mixed)
            if budget == 140 {
                for frames in [2,14] {
                    let values=Array(repeating:soft.bits,count:frames), counts=Array(repeating:tokens,count:frames)
                    let a=try oldHost.withText { _,host in try VideoHostPrep.compose(values,counts:counts,host:host) }
                    let b=try newHost.withText { _,host in try VideoHostPrep.compose(values,counts:counts,host:host) }
                    let inputs=try saveInputs(b.inputs,reference:a.inputs,folder:output.appendingPathComponent("video-\(frames)-composition"))
                    let synthetic=SavedFixture(id:"video",family:"text",function:"",inputs:inputs)
                    let (_,video)=try await compare(resolve(job.originalDocument!),candidate,function:"d\(b.bucket)",inputs:loadInputs(synthetic),reverse:job.reverse ?? false,output:output,label:selected.id+"-\(frames)-frame-composition")
                    rows.append(video)
                }
            }
        }
        return ["passed":true,"rows":rows,"first_call_scope":"first call of each function in this fresh process; AB/BA, not device-cold"]
    }
    if job.operation == "padding" {
        let model = try resolve(job.bookmark!)
        let host = try RuntimeDirectory.HostResourcePaths(directory:URL(fileURLWithPath:job.stagingRuntime!),compact:true).acquire()
        var rows:[[String:Any]]=[]
        for (small,large) in [(256,512),(512,1024),(1024,2048)] {
            for count in [17,small-1,small] {
                let ids = (0..<count).map { UInt32(($0 * 997 + 17) % 262144) }
                let a = try host.withText { _,prep in try prep.prepare(ids,bucket:small) }
                let b = try host.withText { _,prep in try prep.prepare(ids,bucket:large) }
                let x = try await run(model,function:"d\(small)",inputs:a,count:3)
                let y = try await run(model,function:"d\(large)",inputs:b,count:3)
                let different = zip(x.bits,y.bits).filter { $0 != $1 }.count
                let delta = zip(x.bits,y.bits).map { abs(Float(Float16(bitPattern:$0))-Float(Float16(bitPattern:$1))) }.max()!
                rows.append(["small":small,"large":large,"tokens":count,"raw_bits_equal":different==0,
                             "different_elements":different,"max_absolute_delta":delta,
                             "small_ms":x.inferenceMS,"large_ms":y.inferenceMS])
            }
        }
        return ["rows":rows,"scope":"same token IDs, unchanged mask/pool/RoPE host preparation; synthetic diagnostic, no corpus quality claim"]
    }
    if job.operation == "audio" {
        let oldAudio=try resolve(job.original!), newAudio=try resolve(job.candidate!)
        let oldRoot=URL(fileURLWithPath:job.originalRuntime!), newRoot=try OptionAVerification.confined(URL(fileURLWithPath:job.stagingRuntime!))
        let oldHost=try RuntimeDirectory.HostResourcePaths(directory:oldRoot,compact:false).acquire(), newHost=try RuntimeDirectory.HostResourcePaths(directory:newRoot,compact:true).acquire()
        let oldPrep=try AudioHostPrep(folder:oldRoot.appendingPathComponent("audio-host")), newPrep=try AudioHostPrep(folder:newRoot.appendingPathComponent("audio-host"))
        var rows:[[String:Any]]=[]
        for seconds in [1,12,28] {
            let pcm=(0..<(16000*seconds)).map { Float(sin(Double($0)*2*Double.pi*440/16000)*0.2) }
            let a=try oldPrep.mel(pcm), b=try newPrep.mel(pcm)
            guard a.features==b.features, a.mask==b.mask else { throw VerificationError("audio frontend changed") }
            let originalInputs=try oldPrep.prepare(a), candidateInputs=try newPrep.prepare(b)
            let saved=try saveInputs(candidateInputs,reference:originalInputs,folder:output.appendingPathComponent("audio-\(seconds)"))
            let fixture=SavedFixture(id:"audio",family:"audio",function:"a3000",inputs:saved)
            let (soft,row)=try await compare(oldAudio,newAudio,function:"a3000",inputs:loadInputs(fixture),reverse:job.reverse ?? false,output:output,label:"audio-\(seconds)")
            rows.append(row)
            let oldText=try oldHost.withText { _,host in try AudioHostPrep.compose(soft.bits,tokens:a.tokens,host:host) }
            let newText=try newHost.withText { _,host in try AudioHostPrep.compose(soft.bits,tokens:b.tokens,host:host) }
            let savedText=try saveInputs(newText.inputs,reference:oldText.inputs,folder:output.appendingPathComponent("audio-\(seconds)-text"))
            let text=SavedFixture(id:"audio-text",family:"text",function:"",inputs:savedText)
            let (_,composition)=try await compare(resolve(job.originalDocument!),resolve(job.bookmark!),function:"d\(newText.bucket)",inputs:loadInputs(text),reverse:job.reverse ?? false,output:output,label:"audio-\(seconds)-composition")
            rows.append(composition)
        }
        return ["passed":true,"rows":rows]
    }
    throw VerificationError("unknown verification operation")
}

@main
struct DeviceVerifier {
    static func main() async {
        do {
            guard #available(macOS 27, *) else { throw VerificationError("macOS 27 required") }
            guard Bundle.main.bundleIdentifier == OptionAVerification.namespace,
                  try RuntimeCacheIdentity.signingIdentifier() == OptionAVerification.namespace else { throw VerificationError("research-only signing/cache namespace mismatch") }
            guard ProcessInfo.processInfo.environment["SWIFTLIGHT_OPTION_A_NEURAL_ENGINE_FREE"] == "1" else { throw VerificationError("owner must explicitly confirm Neural Engine exclusivity") }
            guard CommandLine.arguments.count == 2 else { throw VerificationError("expected one job JSON") }
            let path=try OptionAVerification.confined(URL(fileURLWithPath:CommandLine.arguments[1]))
            let job=try OptionAVerification.load(Job.self,path)
            try OptionAVerification.space()
            let research = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftlight-research")
            let lock = open(research.appendingPathComponent("ane.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw VerificationError("cannot open shared ANE lock") }
            defer { _ = flock(lock, LOCK_UN); close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw VerificationError("ANE_BUSY: shared research lock held") }
            try Data("Swiftlight storage-option-a: \(job.operation) \(job.source ?? job.fixtureID ?? "verification") pid=\(getpid())\n".utf8)
                .write(to:research.appendingPathComponent("ane.lock.owner"),options:.atomic)
            let report=try await execute(job)
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:OptionAVerification.confined(URL(fileURLWithPath:job.output)).appendingPathComponent("result.json"),options:.atomic)
            FileHandle.standardOutput.write(data+Data([10]))
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}
