import CryptoKit
@testable import DigUpCoreAIRuntime
import XCTest

final class QueryBootstrapTests: XCTestCase {
    @available(macOS 27, *)
    func testRangeRecipeReconstructsExactFilesAndRejectsChangedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let bytes = Data("0123456789".utf8)
        try bytes.write(to: source)
        let expected = Data("23456789!".utf8)
        let files: [String: Any] = Dictionary(uniqueKeysWithValues: ["main.mlirb", "main.hash", "metadata.json"].map { name in
            (name, ["bytes": expected.count, "sha256": QueryBootstrap.digest(expected),
                    "segments": [["offset": 2, "bytes": 8], ["literal": Data("!".utf8).base64EncodedString()]]] as [String: Any])
        })
        var record: [String: Any] = ["format": "swiftlight-bootstrap-ranges-1", "function": "q32",
            "source_bytes": bytes.count, "source_sha256": QueryBootstrap.digest(bytes), "files": files]
        func recipe() throws -> QueryBootstrap.Recipe {
            try JSONDecoder().decode(QueryBootstrap.Recipe.self, from: JSONSerialization.data(withJSONObject: record))
        }
        let output = root.appendingPathComponent("q32.aimodel")
        try QueryBootstrap.materializeRecipe(recipe(), source: source, destination: output)
        for name in files.keys { XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(name)), expected) }
        try Data("012345678X".utf8).write(to: source)
        let rejected = root.appendingPathComponent("rejected")
        XCTAssertThrowsError(try QueryBootstrap.materializeRecipe(recipe(), source: source, destination: rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        try bytes.write(to: source)
        record["files"] = ["../escape": files["main.mlirb"]!]
        XCTAssertThrowsError(try QueryBootstrap.materializeRecipe(recipe(), source: source, destination: rejected))
        record["files"] = files
        record["source_bytes"] = -1
        XCTAssertThrowsError(try QueryBootstrap.materializeRecipe(recipe(), source: source, destination: rejected))
    }

}
