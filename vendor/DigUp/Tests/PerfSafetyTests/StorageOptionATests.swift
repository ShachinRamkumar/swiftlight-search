import CryptoKit
import Darwin
@testable import DigUpCoreAIRuntime
import HostTableCodec
import XCTest
@testable import DigUpKit

final class StorageOptionATests: XCTestCase {
    @available(macOS 27, *)
    func testMergedTextAuditUsesOneSharedBudgetWithoutSpecializing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merged-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let variable = "P3B_SPECIALIZATION_AUDIT_DIR"
        let old = ProcessInfo.processInfo.environment[variable]
        setenv(variable, root.path, 1)
        defer {
            if let old { setenv(variable, old, 1) } else { unsetenv(variable) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let limitVariable = "P3B_SPECIALIZATION_LIMIT"
        let oldLimit = ProcessInfo.processInfo.environment[limitVariable]
        setenv(limitVariable, "1", 1)
        defer {
            if let oldLimit { setenv(limitVariable, oldLimit, 1) } else { unsetenv(limitVariable) }
        }
        let observer = try XCTUnwrap(SpecializationAudit.fromEnvironment(cacheRoots: [root.path]))
        let url = root.appendingPathComponent("runtime/text.aimodel")
        XCTAssertNoThrow(try observer(url, .begin))
        XCTAssertNoThrow(try observer(url, .success))
        let counts = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appendingPathComponent("counts.json")))
        XCTAssertEqual(counts, ["text.aimodel": 1])
        XCTAssertThrowsError(try observer(url, .begin), "all seven text functions share this budget")
    }

    @available(macOS 27, *)
    func testHostResourcePathsSelectTheInstalledLayout() {
        let root = URL(fileURLWithPath: "/temporary/runtime")
        let raw = RuntimeDirectory.HostResourcePaths(directory: root, compact: false)
        XCTAssertEqual(raw.tokenizer.lastPathComponent, "tokenizer.json")
        XCTAssertEqual(raw.tokenTable.lastPathComponent, "token-table.bf16")
        let compact = RuntimeDirectory.HostResourcePaths(directory: root, compact: true)
        XCTAssertEqual(compact.tokenizer.lastPathComponent, "tokenizer.json.zst")
        XCTAssertEqual(compact.tokenTable.lastPathComponent, "token-table.slht")
        XCTAssertEqual(compact.ropeTables, raw.ropeTables)
    }

    @available(macOS 27, *)
    func testVerificationOnlyRuntimeIsRejectedBeforeAnyModelOrReceiptAccess() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent("unapproved-staging-\(UUID())")
        let root=parent.appendingPathComponent("coreai-eg2-v1")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let manifest:[String:Any]=["verification_only":true,"model_key":"coreai-eg2-v1","files":[String:String](),
            "production_assets":[[String:String]](),"checkpoint":["model":"google/embeddinggemma-2","revision":"914f7f8","sha256":"weights"]]
        let url=root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject:manifest).write(to:url)
        XCTAssertThrowsError(try RuntimeDirectory(root)) { XCTAssertTrue(String(describing:$0).contains("verification-only")) }
        XCTAssertThrowsError(try CoreAIAssets(directory:root,manifest:url)) { XCTAssertTrue(String(describing:$0).contains("verification-only")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:parent.appendingPathComponent(".coreai-verification").path))
    }

    func testPackedReaderEvictionBoundsAndMalformedFrames() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("packed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = Data(base64Encoded: "U0xIT1NUMDFAAAAAAQAAAIEAAAACAAAAQAAAAAMAAACq+laTZP45SjbFcqIvrITr754l2X6X/6CziDyh1b+qfXgAAAAAAAAAjQAAAAAAAAAaAQAAAAAAAC8BAAAAAAAAvAEAAAAAAADLAQAAAAAAANoBAAAAAAAAKLUv/SSARQAAEAAAAQA7BVgXfJ72KLUv/SSAAQQAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+Sq7lHKLUv/SSARQAAEAAAAQA7BVgXfJ72KLUv/SSAAQQAgIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+goaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v9WDGWFKLUv/SQCEQAAAQF6mTyhKLUv/SQCEQAAAAHWfFuo")!
        try fixture.write(to: url)
        let table = try PackedRowTable(url: url, cacheBytes: 256)
        for _ in 0..<3 {
            XCTAssertEqual(try table.gather([128, 0, 64, 1, 128]), [256, 257, 0, 1, 128, 129, 2, 3, 256, 257])
        }
        table.clearCache()
        XCTAssertThrowsError(try table.gather([129]))
        var corrupt = fixture
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: url, options: .atomic)
        XCTAssertThrowsError(try PackedRowTable(url: url).gather([128]))
        corrupt = fixture
        corrupt[64] = 0
        try corrupt.write(to: url, options: .atomic)
        XCTAssertThrowsError(try PackedRowTable(url: url))
        let frame = Data(base64Encoded: "KLUv/SQHOQAAcGF5bG9hZFwsInM=")!
        XCTAssertEqual(try HostTableZstd.decode(frame, size: 7), Data("payload".utf8))
        XCTAssertThrowsError(try HostTableZstd.decode(frame + frame, size: 7))
        XCTAssertThrowsError(try HostTableZstd.decode(frame.dropLast(), size: 7))
    }

    @available(macOS 27, *)
    func testUnapprovedMergedPackageAndChangedVisionIdentityAreRejected() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("models/CoreAI/manifest.json"))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-rejection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")
        for change in ["package", "vision", "host"] {
            var manifest = original
            manifest["storage_layout"] = "option-a-v1"
            manifest["semantic_revision"] = CoreAIAssets.optionASemanticRevision
            manifest.removeValue(forKey: "function_assets")
            var assets = (original["production_assets"] as! [[String: String]]).filter { $0["path"] == "vision.aimodel" }
            assets.append(["path": "text.aimodel", "sha256": String(repeating: "a", count: 64)])
            if change == "vision" { assets[0]["sha256"] = String(repeating: "b", count: 64) }
            if change == "host" {
                var vision = manifest["vision_identity"] as! [String: Any]
                var host = vision["host"] as! [String: Any]
                host["host_sha256"] = String(repeating: "c", count: 64)
                vision["host"] = host; manifest["vision_identity"] = vision
            }
            manifest["production_assets"] = assets
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url), "must reject \(change)")
        }
    }

    @available(macOS 27, *)
    func testRepackagingKeepsExistingModelIDBuildAndVectors() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let originalURL = repo.appendingPathComponent("models/CoreAI/manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as! [String: Any]
        let original = try CoreAIAssets(directory: repo, manifest: originalURL)
        XCTAssertEqual(original.revision, CoreAIAssets.optionASemanticRevision)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("option-a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        func info(_ revision: String) -> WorkerInfo {
            WorkerInfo(model: "google/embeddinggemma-2", revision: revision, runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        }
        let weights = "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"
        let existing = try store.registerShadow(key: "coreai-eg2-v1", info: info(original.revision), weightsSHA256: weights)
        XCTAssertEqual(existing, 2)
        let vector = Data(repeating: 7, count: 1536)
        try store.db.execute("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/existing','doc',1,0,0,0)")
        try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(1,1,'chunk','text',?)", [.blob(vector)])
        try store.db.execute("INSERT INTO embedding_inputs(segment,input,content_rev) VALUES(1,'existing',zeroblob(32))")
        try store.db.run("INSERT INTO vectors(model,segment,content_rev,modality,vec) VALUES(?,1,zeroblob(32),'text',?)", [.int(existing), .blob(vector)])
        try store.db.run("UPDATE embedding_models SET state='active' WHERE id=?", [.int(existing)])
        let build = try store.modelGeneration
        manifest["storage_layout"] = "option-a-v1"
        manifest["semantic_revision"] = CoreAIAssets.optionASemanticRevision
        manifest["production_assets"] = [["path": "text.aimodel", "sha256": "new-package-hash"], ["path": "vision.aimodel", "sha256": "vision"]]
        manifest.removeValue(forKey: "audio_identity")
        manifest.removeValue(forKey: "function_assets")
        let url = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let textInventory: [String: [String: Any]] = ["main.mlirb": ["bytes": 7, "sha256": String(repeating: "a", count: 64)]]
        let approved = SHA256.hash(data: try JSONSerialization.data(withJSONObject: textInventory, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(format: "%02x", $0) }.joined()
        let sourceFiles = manifest["files"] as! [String: String]
        var visionInventory: [String: [String: Any]] = [:]
        for (name, bytes) in [("main.hash", 32), ("main.mlirb", 316473127), ("metadata.json", 105)] {
            visionInventory[name] = ["bytes": bytes, "sha256": sourceFiles["vision.aimodel/" + name]!]
        }
        manifest["production_assets"] = [["path": "text.aimodel", "sha256": approved],
            ((try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as! [String: Any])["production_assets"] as! [[String: String]]).first(where: { $0["path"] == "vision.aimodel" })!]
        manifest["asset_inventory"] = ["text.aimodel": textInventory, "vision.aimodel": visionInventory]
        var files = sourceFiles.merging(OptionASemanticIdentity.packedHostHashes) { _, new in new }
        files["text.aimodel/main.mlirb"] = String(repeating: "a", count: 64)
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url), "fixture package is not production approved")
        let merged = try CoreAIAssets(directory: root, manifest: url, approvedMergedTextSHA256: approved)
        XCTAssertEqual(merged.revision, original.revision)
        XCTAssertNil(merged.audioRevision)
        XCTAssertEqual(try store.registerShadow(key: "coreai-eg2-v1", info: info(merged.revision), weightsSHA256: weights), existing)
        XCTAssertEqual(try store.modelGeneration, build)
        try store.db.query("SELECT vec FROM vectors WHERE model=2 AND segment=1") { XCTAssertEqual($0.blob(0), vector) }
        try store.db.query("SELECT state FROM embedding_models WHERE id=2") { XCTAssertEqual($0.text(0), "active") }
        for change in ["package", "vision", "host", "packed-host", "package-file"] {
            var changed = manifest
            if change == "package" || change == "vision" {
                var entries = changed["production_assets"] as! [[String: String]]
                entries[change == "package" ? 0 : 1]["sha256"] = String(repeating: "d", count: 64)
                changed["production_assets"] = entries
            } else if change == "host" {
                var vision = changed["vision_identity"] as! [String: Any]
                var host = vision["host"] as! [String: Any]
                host["host_sha256"] = String(repeating: "e", count: 64)
                vision["host"] = host; changed["vision_identity"] = vision
            } else {
                var hashes = changed["files"] as! [String: String]
                hashes[change == "packed-host" ? "vision-host/cos-841.f32" : "text.aimodel/main.mlirb"] = String(repeating: "f", count: 64)
                changed["files"] = hashes
            }
            try JSONSerialization.data(withJSONObject: changed).write(to: url)
            XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url, approvedMergedTextSHA256: approved), change)
        }
        manifest["semantic_revision"] = "changed-weights-must-use-new-model-key"
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: url))
    }

    @available(macOS 27, *)
    func testMergedSourceRecoveryRemainsFullyVerified() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("merged-recovery-\(UUID().uuidString)")
        let asset = root.appendingPathComponent("text.aimodel")
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("merged weights".utf8)
        try data.write(to: asset.appendingPathComponent("main.mlirb"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["production_assets": [], "files": ["text.aimodel/main.mlirb": hash]] as [String: Any]).write(to: manifest)
        XCTAssertNoThrow(try RuntimeDirectory.verifyAssetForRecovery(asset, manifest: manifest))
        try Data("corrupted".utf8).write(to: asset.appendingPathComponent("main.mlirb"))
        XCTAssertThrowsError(try RuntimeDirectory.verifyAssetForRecovery(asset, manifest: manifest))
        XCTAssertNoThrow(try VisionHostPrep.validateCoordinate(839))
        XCTAssertThrowsError(try VisionHostPrep.validateCoordinate(840))
    }
}
