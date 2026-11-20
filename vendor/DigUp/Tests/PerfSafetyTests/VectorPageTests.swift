import XCTest
@testable import DigUpKit

final class VectorPageTests: XCTestCase {
    func testNewIndexesKeepModelVectorsInlineAndCompactionIsIdempotent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vector-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IndexStore(directory: dir)
        var size: Int64 = 0
        try store.db.query("PRAGMA page_size") { size = $0.int(0) }
        XCTAssertEqual(size, 16384)
        XCTAssertFalse(try store.compactVectorPages().changed)
    }

    func testOldLayoutPreservesVectorsGenerationAndActivationRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vector-repage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IndexStore(directory: dir)
        try store.db.execute("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/vector-page-test','doc',0,0,0,0)")
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "test", runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        let model = try store.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        let revision = IndexStore.contentRevision("page layout fixture")
        for id in Int64(1)...64 {
            let vector = Data(repeating: UInt8(id), count: 1536)
            try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,1,'chunk','text',?)", [.int(id), .blob(vector)])
            try store.db.run("INSERT INTO embedding_inputs VALUES(?,'page layout fixture',?)", [.int(id), .blob(revision)])
            try store.db.run("INSERT INTO vectors VALUES(?,?,?,?,?)", [.int(model), .int(id), .blob(revision), .text("text"), .blob(vector)])
        }
        try store.db.run("UPDATE embedding_models SET state='complete' WHERE id=?", [.int(model)])
        try store.activateModel(key: "coreai-eg2-v1")
        try store.db.execute("PRAGMA journal_mode=DELETE; PRAGMA page_size=4096; VACUUM; PRAGMA journal_mode=WAL;")
        func payloads() throws -> [Data] {
            var values: [Data] = []
            try store.db.query("SELECT s.vec,v.vec FROM segments s JOIN vectors v ON v.segment=s.id ORDER BY s.id,v.model") {
                values.append($0.blob(0)!); values.append($0.blob(1)!)
            }
            return values
        }
        let before = try payloads()
        let generation = try store.modelGeneration
        let result = try store.compactVectorPages()
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.pageSizeBefore, 4096)
        XCTAssertEqual(try payloads(), before)
        XCTAssertEqual(try store.modelGeneration, generation)
        XCTAssertFalse(try store.compactVectorPages().changed)
        var mode = ""
        try store.db.query("PRAGMA journal_mode") { mode = $0.text(0)! }
        XCTAssertEqual(mode, "wal")
        var foreignKeys = 0
        try store.db.query("PRAGMA foreign_key_check") { _ in foreignKeys += 1 }
        XCTAssertEqual(foreignKeys, 0)
        try store.activateModel(key: "llama-vectors1", rollback: true)
        try store.activateModel(key: "coreai-eg2-v1")
        XCTAssertEqual(try payloads(), before)
    }

    func testCompactionRefusesAnActiveReaderWithoutChangingLayout() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vector-page-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IndexStore(directory: dir)
        try store.db.execute("PRAGMA journal_mode=DELETE; PRAGMA page_size=4096; VACUUM; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=10;")
        let reader = try Database(path: store.file.path)
        try reader.execute("BEGIN;")
        defer { try? reader.execute("ROLLBACK;") }
        try reader.query("SELECT COUNT(*) FROM files") { _ in }
        XCTAssertThrowsError(try store.compactVectorPages())
        var size: Int64 = 0
        try store.db.query("PRAGMA page_size") { size = $0.int(0) }
        XCTAssertEqual(size, 4096)
        var mode = ""
        try store.db.query("PRAGMA journal_mode") { mode = $0.text(0)! }
        XCTAssertEqual(mode, "wal")
    }
}
