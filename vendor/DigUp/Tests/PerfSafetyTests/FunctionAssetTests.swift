import XCTest
import CryptoKit
import DigUpCoreAIRuntime

final class FunctionAssetTests: XCTestCase {
    func testSigningIdentityIsStableAndMismatchesAreRejectedBeforeModelPreparation() throws {
        XCTAssertNoThrow(try RuntimeCacheIdentity.validate("com.shachin.swiftlight.indexer"))
        XCTAssertThrowsError(try RuntimeCacheIdentity.validate("digup"))
        XCTAssertThrowsError(try RuntimeCacheIdentity.validate("org.coreai.p7.wrong-signer"))
    }

    @available(macOS 27, *)
    func testSingleFunctionRecoveryIsFullyHashedAndConfinedToItsManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p7-functions-\(UUID().uuidString)")
        let asset = root.appendingPathComponent("function-assets/q32.aimodel")
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [String: String] = [:]
        for (index, name) in ["main.mlirb", "main.hash", "metadata.json"].enumerated() {
            let data = Data([UInt8(index)])
            try data.write(to: asset.appendingPathComponent(name))
            files["function-assets/q32.aimodel/" + name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["files": files, "production_assets": []] as [String: Any]).write(to: manifest)
        XCTAssertNoThrow(try RuntimeDirectory.verifyAssetForRecovery(asset, manifest: manifest))
        try Data([99]).write(to: asset.appendingPathComponent("main.mlirb"))
        XCTAssertThrowsError(try RuntimeDirectory.verifyAssetForRecovery(asset, manifest: manifest))
        XCTAssertThrowsError(try RuntimeDirectory.verifyAssetForRecovery(root.appendingPathComponent("../q32.aimodel"), manifest: manifest))
        XCTAssertThrowsError(try RuntimeDirectory.verifyAssetForRecovery(root.appendingPathComponent("function-assets/unknown.aimodel"), manifest: manifest))
    }

    @available(macOS 27, *)
    func testFunctionMappingRejectsEscapesAndUnrecognizedEntrypoints() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p7-function-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        let assets = [["path": "text-query.aimodel", "sha256": "query"], ["path": "text-doc.aimodel", "sha256": "doc"]]
        for mapping in [["q32": "../q32.aimodel"], ["unknown": "function-assets/unknown.aimodel"]] {
            try JSONSerialization.data(withJSONObject: ["production_assets": assets, "checkpoint": ["sha256": "weights"], "function_assets": mapping] as [String: Any]).write(to: manifest)
            XCTAssertThrowsError(try CoreAIAssets(directory: root, manifest: manifest))
        }
    }
}
