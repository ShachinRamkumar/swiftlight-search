import XCTest
import CryptoKit
import DigUpCoreAIRuntime

final class RuntimeVerificationTests: XCTestCase {
    @available(macOS 27, *)
    func testVerifiedReceiptAvoidsRepeatedHashingAndRejectsChangedContent() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("verification-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        var files: [String: String] = [:]
        for name in ["token-table.bf16", "tokenizer.json", "tokenizer_config.json", "rope-tables/sha256.json", "text-query.aimodel/main.hash", "text-doc.aimodel/main.hash"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(name.utf8)
            try data.write(to: url)
            files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest: [String: Any] = ["model_key": "coreai-eg2-text-v1", "files": files,
            "checkpoint": ["model": "google/embeddinggemma-2", "revision": "914f7f8", "sha256": "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"],
            "production_assets": [["path": "text-query.aimodel", "sha256": "query"], ["path": "text-doc.aimodel", "sha256": "doc"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        _ = try RuntimeDirectory(root)
        let receipt = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: parent.appendingPathComponent(".coreai-verification"), includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: receipt)
        let stamp = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try RuntimeDirectory(root)
        XCTAssertEqual(try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
        let table = root.appendingPathComponent("token-table.bf16")
        try Data("changed".utf8).write(to: table, options: .atomic)
        XCTAssertThrowsError(try RuntimeDirectory(root)) { XCTAssertTrue(String(describing: $0).contains("SHA-256 mismatch")) }
        XCTAssertEqual(try Data(contentsOf: receipt), original)
        try Data("token-table.bf16".utf8).write(to: table, options: .atomic)
        _ = try RuntimeDirectory(root)
        XCTAssertNotEqual(try Data(contentsOf: receipt), original)
        XCTAssertNoThrow(try RuntimeDirectory(root, fullVerify: true))
    }
}
