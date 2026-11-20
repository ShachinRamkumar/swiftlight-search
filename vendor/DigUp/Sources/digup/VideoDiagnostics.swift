import CryptoKit
import DigUpCoreAIRuntime
import DigUpKit
import Foundation

@available(macOS 27, *)
func videoDiagnostic(_ config: [String:Any]) throws -> [String:Any] {
    let runtime=try RuntimeDirectory(URL(fileURLWithPath:config["runtime"] as! String))
    let mode=config["mode"] as! String,cases=config["cases"] as? [[String:Any]] ?? []
    let shared=try runtime.hostResources()
    let embedder = mode == "video-embed" || mode == "video-direct" ? try runtime.embedder(.document) : nil
    defer { embedder?.close() }
    var rows: [[String:Any]]=[]
    if mode == "video-direct" {
        let store=try IndexStore(directory:URL(fileURLWithPath:config["index"] as! String))
        for c in cases {
            let id=(c["segment"] as! NSNumber).int64Value
            let input=try store.rebuildVideo(segment:id)
            let vector=try embedder!.embedVideoFrames(input.frames)
            try vector.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["vector_out"] as! String))
            rows.append(["segment":id,"content_rev":input.contentRev.map {String(format:"%02x",$0)}.joined()])
        }
    } else {
        for c in cases {
            let start=Date()
            var frames: [RGBImage]=[]
            if let files=c["rgb"] as? [String] {
                frames=try files.map { try RGBImage(width:c["width"] as! Int,height:c["height"] as! Int,pixels:Array(Data(contentsOf:URL(fileURLWithPath:$0)))) }
            } else {
                frames=try VideoHostPrep.decode(URL(fileURLWithPath:c["path"] as! String),range:VideoClipRange(start:c["start"] as! Double,end:c["end"] as! Double))
            }
            if let output=c["decoded_out"] as? String {
                for (i,f) in frames.enumerated() { try Data(f.pixels).write(to:URL(fileURLWithPath:output+"-\(i).rgb")) }
            }
            if mode == "video-prep" {
                let hashes=c["input_hashes"] as! [[String:String]]
                for (i,frame) in frames.enumerated() {
                    let prepared=try shared.withVision { vision,_ in try vision.prepare(frame,budget:140) }
                    for (n,digest) in hashes[i] {
                        guard SHA256.hash(data:prepared.inputs[n]!.bytes).map({String(format:"%02x",$0)}).joined()==digest else { throw CLIError("video prep mismatch \(c["id"]!) frame \(i) \(n)") }
                    }
                }
                let soft=try (c["soft"] as! [String]).map { try Data(contentsOf:URL(fileURLWithPath:$0)).withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) } }
                let text=try shared.withText { _,host in try VideoHostPrep.compose(soft,counts:c["counts"] as! [Int],host:host) }
                for (n,digest) in c["text_hashes"] as! [String:String] {
                    guard SHA256.hash(data:text.inputs[n]!.bytes).map({String(format:"%02x",$0)}).joined()==digest else { throw CLIError("video compose mismatch \(c["id"]!) \(n)") }
                }
                rows.append(["id":c["id"]!,"frames":frames.count,"byte_exact":true,"bucket":text.bucket])
            } else if mode == "video-decode" {
                rows.append(["id":c["id"]!,"frames":frames.count,"width":frames[0].width,"height":frames[0].height])
            } else if mode == "video-embed" {
                let vector: [Float]
                if let path=c["path"] as? String {
                    vector=try embedder!.embedVideoClips(URL(fileURLWithPath:path),schedule:[VideoClipRange(start:c["start"] as! Double,end:c["end"] as! Double)])[0]
                } else { vector=try embedder!.embedVideoFrames(frames) }
                try vector.withUnsafeBytes { Data($0) }.write(to:URL(fileURLWithPath:c["vector_out"] as! String))
                rows.append(["id":c["id"]!,"frames":frames.count,"seconds":Date().timeIntervalSince(start)])
            } else { throw CLIError("unknown video mode") }
        }
    }
    return ["passed":true,"mode":mode,"rows":rows]
}
