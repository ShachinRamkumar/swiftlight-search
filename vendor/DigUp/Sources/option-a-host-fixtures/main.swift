import DigUpCoreAIRuntime
import DigUpKit
import Foundation
import OptionAVerificationSupport

struct IndexedCase: Decodable { let id: Int64; let input: String; let vector: String }

@available(macOS 27, *)
func prepare() throws {
    guard CommandLine.arguments.count == 4 else { throw VerificationError("usage: option-a-host-fixtures SOURCE STAGING OUTPUT") }
    let source=URL(fileURLWithPath:CommandLine.arguments[1]), stage=try OptionAVerification.confined(URL(fileURLWithPath:CommandLine.arguments[2]))
    let output=try OptionAVerification.confined(URL(fileURLWithPath:CommandLine.arguments[3]))
    try OptionAVerification.space(400_000_000)
    guard !FileManager.default.fileExists(atPath: output.path) else { throw VerificationError("fixture destination exists") }
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let old=try RuntimeDirectory.HostResourcePaths(directory:source,compact:false).acquire()
    let new=try RuntimeDirectory.HostResourcePaths(directory:stage,compact:true).acquire()
    var cases: [SavedFixture]=[]
    let variants=["A quarterly report about storage, caches, and model recovery. ", "中文 العربية हिन्दी café storage. ", "func recover(cache: Int) -> Bool { return cache == 2048 } 0x42 12.345 "]
    for role in [TextRole.query, .document] {
        for bucket in role == .query ? [32,64,128,256,512] : [256,512,1024,2048] {
            for (variant, seed) in variants.enumerated() {
                let text=String(repeating:seed,count:bucket)
                let prompt=role == .query ? Prompts.query(text) : Prompts.document(title:"Storage report",text:text)
                let ids=try old.withText { tok,_ in try tok.tokenize(prompt,limit:bucket) }
                let newIDs=try new.withText { tok,_ in try tok.tokenize(prompt,limit:bucket) }
                guard ids == newIDs, ids.count == bucket else { throw VerificationError("tokenizer fixture count/bits differ") }
                let a=try old.withText { _,host in try host.prepare(ids,bucket:bucket) }
                let b=try new.withText { _,host in try host.prepare(newIDs,bucket:bucket) }
                let id="\(role.rawValue)-\(bucket)-\(variant)"
                let inputs=try saveInputs(b,reference:a,folder:output.appendingPathComponent(id))
                cases.append(SavedFixture(id:id,family:"text",function:(bucket <= 128 ? "q" : "d")+String(bucket),inputs:inputs,bucket:bucket))
            }
        }
    }
    let indexURL=OptionAVerification.root.appendingPathComponent("index-cases.json")
    if FileManager.default.fileExists(atPath:indexURL.path) {
        let indexed=try OptionAVerification.load([IndexedCase].self,indexURL)
        var counts: [Int:Int]=[:]
        for item in indexed {
            let ids=try old.withText { tok,_ in try tok.tokenize(item.input,limit:2048) }
            let bucket=try TextHostPrep.bucketFor(ids.count,role:.document)
            if counts[bucket,default:0] >= 3 { continue }
            counts[bucket,default:0] += 1
            let id="indexed-\(item.id)-\(bucket)"
            let a=try old.withText { _,host in try host.prepare(ids,bucket:bucket) }
            let b=try new.withText { _,host in try host.prepare(ids,bucket:bucket) }
            let inputs=try saveInputs(b,reference:a,folder:output.appendingPathComponent(id))
            cases.append(SavedFixture(id:id,family:"indexed-text",function:"d\(bucket)",inputs:inputs,bucket:bucket,storedVector:item.vector))
        }
    }
    for budget in [70,140,280] {
        for (index, size) in [(96,128),(budget*48,48),(48,budget*48)].enumerated() {
            let (w,h)=size
            let image=try RGBImage(width:w,height:h,pixels:(0..<(w*h*3)).map { UInt8(truncatingIfNeeded:$0) })
            let a=try old.withVision { vision,_ in try vision.prepare(image,budget:budget) }
            let b=try new.withVision { vision,_ in try vision.prepare(image,budget:budget) }
            guard a.tokens == b.tokens else { throw VerificationError("vision token counts differ") }
            let id="vision-\(budget)-\(index)"
            let inputs=try saveInputs(b.inputs,reference:a.inputs,folder:output.appendingPathComponent(id))
            cases.append(SavedFixture(id:id,family:"vision",function:"v\(budget*9)",inputs:inputs,budget:budget,softTokens:b.tokens))
        }
    }
    let a=try Data(contentsOf:source.appendingPathComponent("manifest.json")), b=try Data(contentsOf:stage.appendingPathComponent("manifest.json"))
    try OptionAVerification.save(SavedFixtures(cases:cases,originalManifestSHA256:OptionAVerification.hash(a),stagingManifestSHA256:OptionAVerification.hash(b)),output.appendingPathComponent("manifest.json"))
    print("CPU-only host preparation passed for \(cases.count) fixtures; no Core AI runtime calls")
}

do {
    if #available(macOS 27, *) { try prepare() } else { throw VerificationError("macOS 27 required") }
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
