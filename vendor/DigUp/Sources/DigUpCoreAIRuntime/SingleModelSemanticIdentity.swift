import CryptoKit
import DigUpKit
import Foundation

@available(macOS 27, *)
enum SingleModelSemanticIdentity {
    static let asset = "EmbeddingGemma2.aimodel"
    static let layout = "single-model-v2"
    static let audioIdentitySHA256 = "86e0217145cb0bba8b3f8894e9d3f50df5ff39f17ca40cd44c1736707ae2995d"
    static let audioHostHashes: [String: String] = [
        "audio-host/identity.json": "2c4553fd420f32e995e11accb1799160e569fa5c7201ebbf108560f3e726b9ad",
        "audio-host/mel-bank.f32": "427860b9a9429175f0e450512def4224f46ced89960dfb1d9cf7479d7e485e2b",
        "audio-host/mel-bank.f64": "525f8745cf88c08d054328635e93aa8a663e1239bdec4004a73d5d8bd0d3ef41",
        "audio-host/positions.f32": "d6220713c4b60d14ff7821c6bb5e7419b447be592b62ded41e7a8f9f03f1d84c",
        "audio-host/window.f32": "8ac4fd109da552d6d3ef7a90083306384c9ee2bc32a60dd9f1ecfe931d8caf44",
    ]
    // Numerical equivalence and source-free cache survival are independent approvals.
    static let approvedPackageSHA256: String? = "c6bd6427f56678667897c93d57cc475c70960407d67d11e11faed4feda349ad8"

    static func requireRetentionPolicy(deleteSourceAfterCompile: Bool) throws {
        guard !deleteSourceAfterCompile || SourceRecovery.allowed else {
            throw WorkerError.failed("source deletion is disabled")
        }
    }

    static func validate(_ manifest: [String: Any], approved: String? = approvedPackageSHA256) throws {
        guard let approved, approved.count == 64,
              manifest["storage_layout"] as? String == layout,
              manifest["semantic_revision"] as? String == CoreAIAssets.optionASemanticRevision,
              let audio = manifest["audio_identity"] as? [String: Any],
              QueryBootstrap.digest(try JSONSerialization.data(withJSONObject: audio, options: [.sortedKeys, .withoutEscapingSlashes])) == audioIdentitySHA256,
              let assets = manifest["production_assets"] as? [[String: String]],
              assets == [["path": asset, "sha256": approved]],
              let inventories = manifest["asset_inventory"] as? [String: [String: [String: Any]]],
              Set(inventories.keys) == [asset], let inventory = inventories[asset],
              Set(inventory.keys) == ["main.hash", "main.mlirb", "metadata.json"],
              let files = manifest["files"] as? [String: String],
              SingleModelGroups.recipeHashes.allSatisfy({ files["group-" + $0.key + ".json"] == $0.value }),
              audioHostHashes.allSatisfy({ files[$0.key] == $0.value }),
              OptionASemanticIdentity.packedHostHashes.allSatisfy({ files[$0.key] == $0.value }),
              !files.keys.contains(where: { $0.hasPrefix("audio.aimodel/") || ($0.contains(".aimodel/") && !$0.hasPrefix(asset + "/")) }),
              Set(files.keys.filter { $0.hasPrefix(asset + "/") }) == Set(inventory.keys.map { asset + "/" + $0 }),
              inventory.allSatisfy({ files[asset + "/" + $0.key] == $0.value["sha256"] as? String }),
              SHA256.hash(data: try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map({ String(format: "%02x", $0) }).joined() == approved,
              let vision = manifest["vision_identity"] as? [String: Any], let visionHash = vision["asset_sha256"] as? String else {
            throw WorkerError.failed("single model package/host identity has no matching verified approval")
        }
        var original = manifest
        original["production_assets"] = [["path": "vision.aimodel", "sha256": visionHash]]
        guard try OptionASemanticIdentity.originalRevision(original, merged: true) == CoreAIAssets.optionASemanticRevision else {
            throw WorkerError.failed("single model source semantic identity changed")
        }
    }
}
