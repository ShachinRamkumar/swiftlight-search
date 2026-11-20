import DigUpCoreAIRuntime
import Foundation

@available(macOS 27, *)
func directDocuments(_ config: Configuration) throws -> [String:Any] {
    struct Input: Decodable { let segment: Int64; let input: String }
    guard let file=config.inputsFile else { throw CheckError("inputsFile is required") }
    let inputs=try load([Input].self,URL(fileURLWithPath:file))
    let embedder=try config.embedder(.document)
    defer { embedder.close() }
    var results: [[String:Any]]=[]
    for input in inputs {
        let vector=try embedder.embedTexts([input.input])[0]
        let halves=vector.map { Float16($0) }
        results.append(["segment":input.segment,"vec":halves.withUnsafeBufferPointer { Data(buffer:$0) }.base64EncodedString(),
                        "bucket":embedder.lastTimings[0].bucket])
    }
    return ["passed":true,"vectors":results,"count":results.count]
}
