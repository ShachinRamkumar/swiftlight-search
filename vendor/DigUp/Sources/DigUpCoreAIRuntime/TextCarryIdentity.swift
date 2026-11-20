import DigUpKit
import Foundation

@available(macOS 27, *)
extension RuntimeDirectory {
    public func verifiedTextCarrySource(_ source: URL) throws -> RuntimeDirectory {
        guard modelKey=="coreai-eg2-v1" else { throw WorkerError.failed("carry target must be coreai-eg2-v1") }
        let old=try RuntimeDirectory(source,fullVerify:true)
        guard old.modelKey==Self.modelKey else { throw WorkerError.failed("carry source must be text-v1") }
        let target=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as! [String:Any]
        let origin=try JSONSerialization.jsonObject(with:Data(contentsOf:source.appendingPathComponent("manifest.json"))) as! [String:Any]
        for key in ["checkpoint","host_prep","host_prep_source_sha256","tokenizer"] {
            guard let a=target[key], let b=origin[key],
                  NSDictionary(dictionary:[key:a]).isEqual(to:[key:b]) else { throw WorkerError.failed("text carry identity mismatch: \(key)") }
        }
        if assets.names.contains("text.aimodel") || assets.names.contains(SingleModelSemanticIdentity.asset) {
            guard assets.revision == CoreAIAssets.optionASemanticRevision,
                  let identity = target["text_identity"] as? [String: Any],
                  NSDictionary(dictionary: identity).isEqual(to: origin.filter {
                      ["checkpoint", "host_prep", "host_prep_source_sha256", "tokenizer", "production_assets"].contains($0.key)
                  }) else { throw WorkerError.failed("option A text carry semantic identity mismatch") }
            return old
        }
        let oldFiles=origin["files"] as! [String:String], newFiles=target["files"] as! [String:String]
        guard oldFiles.allSatisfy({ newFiles[$0.key]==$0.value }),
              let identity=target["text_identity"] as? [String:Any],
              NSDictionary(dictionary:identity).isEqual(to:origin.filter { ["checkpoint","host_prep","host_prep_source_sha256","tokenizer","production_assets"].contains($0.key) }) else {
            throw WorkerError.failed("text carry asset/table/tokenizer/RoPE/prompt identity mismatch")
        }
        return old
    }
}
