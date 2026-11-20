import CryptoKit
import DigUpKit
import Foundation

@available(macOS 27, *)
enum OptionASemanticIdentity {
    // Set only after the authored package passes the owner's bit-exact comparison.
    static let approvedMergedTextPackageSHA256: String? = nil
    static let packedHostHashes: [String: String] = [
        "host-tables.json": "e706ebc556c604d860c254c2a5ae2962ebf3cfcd5b69d552708db4494c3bbb7a",
        "rope-tables/2048-global_cos.f16": "e18d5f673a7ffca566d78eb8cdb1bea63e2da24575a5d7c91748b2a6a6cd2b31",
        "rope-tables/2048-global_sin.f16": "f0a028934bf88d094129829a1586d102dbd03c8b3ae7cb856cf52775972a0b10",
        "rope-tables/2048-local_cos.f16": "6726119c2a78148f7ac632ff4ea487ce20a307e891394416159fa817ffe2cab3",
        "rope-tables/2048-local_sin.f16": "3d1ebc264eaf19c02b25804b5a51e20fbf340b969a474464f3558eb130993196",
        "rope-tables/sha256.json": "db6717acee35098dde0ef9ad8523357b3cf0862dd7835892ff80b87aa434bab4",
        "token-table.slht": "07bd69d605150176c54794372757198c866b8042afa2f9c74e8a047048e82082",
        "tokenizer.json.zst": "622668ab7ba9ab89df8d4b3f50b4ee5010af705f013986917eabbb3f88848ad5",
        "vision-host/cos-841.f32": "d4f828431a3d7f9a73b633ecf9d3024cf53afccc02947ba9d0201a886feec2ae",
        "vision-host/identity.json": "9c4c7641b9b5e8ed7e5384905286fe77ef4687d39f84fc8f5f44dbd3c887b070",
        "vision-host/position-table-840.bf16": "154233d4fac8ed8bac6fdc20f72ccccd178e263220cc9f15e7c9c2f8e72e4826",
        "vision-host/sin-841.f32": "330fcb33d2b5c5d1fc251d8053682bfa88a0f10c1fba6919e0c8b28950af4451",
    ]

    static func originalRevision(_ manifest: [String: Any], merged: Bool = false) throws -> String {
        guard let checkpoint = manifest["checkpoint"] as? [String: Any], let weights = checkpoint["sha256"] as? String,
              var assets = manifest["production_assets"] as? [[String: String]],
              let vision = manifest["vision_identity"] as? [String: Any],
              let host = vision["host"] as? [String: Any], let hostFiles = host["files"] as? [String: String] else {
            throw WorkerError.failed("missing option A source semantic identity")
        }
        if merged {
            guard let text = manifest["text_identity"] as? [String: Any],
                  let originals = text["production_assets"] as? [[String: String]] else {
                throw WorkerError.failed("missing original text semantic identity")
            }
            assets = originals + assets.filter { $0["path"] == "vision.aimodel" }
        }
        guard assets.filter({ $0["path"] != "audio.aimodel" }).count == 3 else {
            throw WorkerError.failed("unexpected semantic source asset set")
        }
        var parts = [weights] + assets.filter { $0["path"] != "audio.aimodel" }.compactMap { $0["sha256"] }.sorted()
            + ["p3a-bf16-fp32scale-shipped-rope-v1"]
        for value in [vision["asset_sha256"], vision["stage_b_manifest_sha256"], host["host_sha256"], host["spec_sha256"]] {
            guard let value = value as? String else { throw WorkerError.failed("missing vision semantic identity") }
            parts.append(value)
        }
        for name in hostFiles.keys.sorted() { parts += [name, hostFiles[name]!] }
        return digest(Data(parts.joined(separator: ":").utf8))
    }

    static func validate(_ manifest: [String: Any], approvedTextSHA256: String? = approvedMergedTextPackageSHA256) throws {
        guard try originalRevision(manifest, merged: true) == CoreAIAssets.optionASemanticRevision else {
            throw WorkerError.failed("option A source semantic identity changed")
        }
        guard let approvedTextSHA256, approvedTextSHA256.count == 64,
              let assets = manifest["production_assets"] as? [[String: String]],
              assets.first(where: { $0["path"] == "text.aimodel" })?["sha256"] == approvedTextSHA256 else {
            throw WorkerError.failed("merged text package has no matching verified approval")
        }
        guard let files = manifest["files"] as? [String: String],
              let inventories = manifest["asset_inventory"] as? [String: [String: [String: Any]]],
              packedHostHashes.allSatisfy({ files[$0.key] == $0.value }) else {
            throw WorkerError.failed("option A packed host identity changed")
        }
        for name in ["text.aimodel", "vision.aimodel"] {
            guard let inventory = inventories[name], !inventory.isEmpty,
                  let asset = assets.first(where: { $0["path"] == name }),
                  digest(try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys, .withoutEscapingSlashes])) == asset["sha256"],
                  Set(files.keys.filter { $0.hasPrefix(name + "/") }) == Set(inventory.keys.map { name + "/" + $0 }),
                  inventory.allSatisfy({ files[name + "/" + $0.key] == $0.value["sha256"] as? String }) else {
                throw WorkerError.failed("option A package inventory changed: \(name)")
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
