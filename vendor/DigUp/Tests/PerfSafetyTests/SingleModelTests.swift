import CryptoKit
@testable import DigUpCoreAIRuntime
import XCTest

final class SingleModelTests: XCTestCase {
    @available(macOS 27, *)
    func testLiveSingleSourceExtractsAllFourGroupsWithoutAuthoringSDK() throws {
        guard let path = ProcessInfo.processInfo.environment["SINGLE_MODEL_EXTRACTION_RUNTIME"] else {
            throw XCTSkip("live source extraction is run separately with the research runtime")
        }
        let directory = URL(fileURLWithPath: path)
        let assets = try CoreAIAssets(directory: directory, manifest: directory.appendingPathComponent("manifest.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("single-group-extraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for group in SingleModelGroups.order {
            let target = root.appendingPathComponent(group + ".aimodel")
            let hash = try SingleModelGroups.materialize(assets, group: group, destination: target)
            XCTAssertEqual(try SourceRecovery.fileHash(target.appendingPathComponent("main.mlirb")), hash)
            let stored = try Data(contentsOf: target.appendingPathComponent("main.hash"))
            XCTAssertEqual(stored.map { String(format: "%02x", $0) }.joined(), hash)
            try FileManager.default.removeItem(at: target)
        }
    }

    @available(macOS 27, *)
    func testDownloadRepairPolicyAllowsSourceDeletion() throws {
        try SingleModelSemanticIdentity.requireRetentionPolicy(deleteSourceAfterCompile: false)
        try SingleModelSemanticIdentity.requireRetentionPolicy(deleteSourceAfterCompile: true)
    }

    @available(macOS 27, *)
    func testEveryTextVisionAndAudioFunctionUsesOneApprovedAsset() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let originalURL = repo.appendingPathComponent("models/CoreAI/manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as! [String: Any]
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("single-model-\(UUID())")
        let root = container.appendingPathComponent("coreai-eg2-v1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let url = root.appendingPathComponent("manifest.json")
        let inventory: [String: [String: Any]] = ["main.hash": ["bytes": 32, "sha256": String(repeating: "a", count: 64)],
            "main.mlirb": ["bytes": 7, "sha256": String(repeating: "b", count: 64)],
            "metadata.json": ["bytes": 105, "sha256": String(repeating: "c", count: 64)]]
        let approved = SHA256.hash(data: try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(format: "%02x", $0) }.joined()
        let asset = SingleModelSemanticIdentity.asset
        manifest["production_assets"] = [["path": asset, "sha256": approved]]
        manifest["asset_inventory"] = [asset: inventory]
        manifest["files"] = OptionASemanticIdentity.packedHostHashes.merging(Dictionary(uniqueKeysWithValues: inventory.map { (asset + "/" + $0.key, $0.value["sha256"] as! String) })) { _, new in new }
        var files = manifest["files"] as! [String: String]
        for (name, hash) in SingleModelGroups.recipeHashes { files["group-" + name + ".json"] = hash }
        files.merge(SingleModelSemanticIdentity.audioHostHashes) { _, new in new }
        files.merge(SourceRecovery.hashes) { _, new in new }
        manifest["files"] = files
        manifest["storage_layout"] = SingleModelSemanticIdentity.layout
        manifest["semantic_revision"] = CoreAIAssets.optionASemanticRevision
        manifest.removeValue(forKey: "function_assets")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url))
        let single = try CoreAIAssets(directory: root, manifest: url, approvedMergedTextSHA256: nil, approvedSingleModelSHA256: approved)
        XCTAssertEqual(single.names, [asset])
        XCTAssertEqual(single.revision, CoreAIAssets.optionASemanticRevision)
        XCTAssertNotNil(single.audioRevision)
        XCTAssertNil(QueryBootstrap.generation(single))
        try QueryBootstrap.markReady(single)
        let generation = QueryBootstrap.generation(single)
        XCTAssertNotNil(generation)
        try QueryBootstrap.markReady(single)
        XCTAssertEqual(QueryBootstrap.generation(single), generation)
        try QueryBootstrap.markReady(single, replaceGeneration: true)
        XCTAssertNotEqual(QueryBootstrap.generation(single), generation)
        QueryBootstrap.invalidate(single)
        XCTAssertNil(QueryBootstrap.generation(single))
        for function in ["q32","q64","q128","d256","d512","d1024","d2048","v630","v1260","v2520","a3000"] {
            XCTAssertEqual(try single.sourceAsset(for: function), asset)
        }
        XCTAssertThrowsError(try single.sourceAsset(for: "unknown"))
        for change in ["vision", "host", "package", "audio", "partition", "bootstrap"] {
            var changed = manifest
            switch change {
            case "vision":
                var vision = changed["vision_identity"] as! [String: Any]
                vision["asset_sha256"] = String(repeating: "e", count: 64)
                changed["vision_identity"] = vision
            case "host":
                var files = changed["files"] as! [String: String]
                files["token-table.slht"] = String(repeating: "e", count: 64)
                changed["files"] = files
            case "package": changed["production_assets"] = [["path": asset, "sha256": String(repeating: "e", count: 64)]]
            case "audio": changed["audio_identity"] = ["asset_sha256": "unexpected"]
            case "bootstrap":
                var files = changed["files"] as! [String: String]
                files["group-query3.json"] = String(repeating: "e", count: 64)
                changed["files"] = files
            default: changed["function_assets"] = ["q32": "function-assets/q32.aimodel"]
            }
            try JSONSerialization.data(withJSONObject: changed).write(to: url)
            XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url, approvedMergedTextSHA256: nil, approvedSingleModelSHA256: approved), change)
        }
        XCTAssertTrue(SourceRecovery.enabled)
    }
}
