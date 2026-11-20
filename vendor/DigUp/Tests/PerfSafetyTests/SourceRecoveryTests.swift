@testable import DigUpCoreAIRuntime
import XCTest

final class SourceRecoveryTests: XCTestCase {
    @available(macOS 27, *)
    func testLegacyPartitionRepairBindsTheFullRelativeSourcePath() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let data = try Data(contentsOf: repo.appendingPathComponent("models/CoreAI/manifest.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-source-pin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        try data.write(to: manifest)
        let assets = try CoreAIAssets(directory: root, manifest: manifest)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let files = object["files"] as! [String: String]
        XCTAssertEqual(try SourceRecovery.sourcePin(assets, source: root.appendingPathComponent("function-assets/q32.aimodel")), files["function-assets/q32.aimodel/main.mlirb"])
        XCTAssertThrowsError(try SourceRecovery.sourcePin(assets, source: root.deletingLastPathComponent().appendingPathComponent("q32.aimodel")))
    }

    @available(macOS 27, *)
    func testDownloadRetriesInterruptedAndCorruptFilesAndKeepsVerifiedCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["main.hash", "main.mlirb", "metadata.json"]
        let bytes = Data("unchanged source bytes".utf8)
        let pins = Dictionary(uniqueKeysWithValues: names.map { ($0, SourceRecovery.Pin(bytes: bytes.count, sha256: QueryBootstrap.digest(bytes))) })
        let urls = Dictionary(uniqueKeysWithValues: names.map { ($0, ["url": "https://example.invalid/" + $0] as [String: Any]) })
        var attempts: [String: Int] = [:]
        try SourceRecovery.downloadFiles(urls, pins: pins, destination: root) { url, destination, _ in
            let name = url.lastPathComponent
            attempts[name, default: 0] += 1
            if attempts[name] == 1 {
                try Data("partial".utf8).write(to: destination)
                throw NSError(domain: "interrupted", code: 1)
            }
            if attempts[name] == 2 { try Data(repeating: 0, count: bytes.count).write(to: destination) }
            else { try bytes.write(to: destination) }
        }
        for name in names {
            XCTAssertEqual(attempts[name], 3)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".partial").path))
        }
        try SourceRecovery.downloadFiles(urls, pins: pins, destination: root) { _, _, _ in XCTFail("verified checkpoint downloaded twice") }
        try Data("broken".utf8).write(to: root.appendingPathComponent("main.mlirb"))
        XCTAssertThrowsError(try SourceRecovery.downloadFiles(urls, pins: pins, destination: root, attempts: 2) { _, destination, _ in
            try Data(repeating: 0, count: bytes.count).write(to: destination)
        })
    }

    @available(macOS 27, *)
    func testLocalDownloadAndMissingURLPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-repair-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["main.hash", "main.mlirb", "metadata.json"]
        let data = Data("pinned".utf8)
        let pins = Dictionary(uniqueKeysWithValues: names.map { ($0, SourceRecovery.Pin(bytes: data.count, sha256: QueryBootstrap.digest(data))) })
        var urls: [String: [String: Any]] = [:]
        for name in names {
            try data.write(to: source.appendingPathComponent(name))
            urls[name] = ["url": source.appendingPathComponent(name).absoluteString]
        }
        XCTAssertThrowsError(try SourceRecovery.downloadURLs([:], files: Set(names)))
        XCTAssertThrowsError(try SourceRecovery.downloadURLs(urls, files: Set(names)))
        let destination = root.appendingPathComponent("downloaded.aimodel")
        try SourceRecovery.downloadFiles(urls, pins: pins, destination: destination, allowFileURLs: true)
        for name in names { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), data) }
    }
}
