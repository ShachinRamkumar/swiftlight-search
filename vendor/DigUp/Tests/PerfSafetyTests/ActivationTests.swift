import XCTest
import Darwin
@testable import DigUpKit

final class ActivationTests: XCTestCase {
    func fixture() throws -> (URL, IndexStore, Int64) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p7-activation-\(UUID().uuidString)")
        let store = try IndexStore(directory: dir)
        try store.db.execute("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/p7-test','doc',0,0,0,0)")
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "test", runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        let model = try store.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        return (dir, store, model)
    }

    func testActivationRefusesUncoveredAndExcessExplainedFailures() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(1,1,'chunk','text',?)", [.blob(Data(repeating: 0, count: 1536))])
        let before = try store.modelGeneration
        XCTAssertThrowsError(try store.activateModel(key: "coreai-eg2-v1"))
        XCTAssertEqual(try store.modelGeneration, before)
        try store.recordShadowFailure(model: model, segment: 1, reason: "source_changed")
        XCTAssertThrowsError(try store.activateModel(key: "coreai-eg2-v1"))
        try store.db.execute("INSERT INTO embedding_failures SELECT id,1,'source_changed',0 FROM embedding_models WHERE storage='legacy'")
        XCTAssertNoThrow(try store.activateModel(key: "coreai-eg2-v1"))
        try store.db.run("UPDATE embedding_failures SET reason='unknown' WHERE model=?", [.int(model)])
        XCTAssertThrowsError(try store.activateModel(key: "coreai-eg2-v1"))
    }

    func testFileSourceUpdateInvalidatesAJobEvenBeforeAnySegmentsExist() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.indexingModel = model
        try store.beginVectorJob()
        try store.db.execute("UPDATE files SET path='/p7-changed' WHERE id=1")
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        XCTAssertThrowsError(try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "late"))
    }

    func testSubMillisecondSourceEditsAreRefusedAtCommit() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        try Data("old".utf8).write(to: source)
        var before = Darwin.stat(); XCTAssertEqual(stat(source.path, &before), 0)
        let originalTime = Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec)/1e9
        store.indexingModel = model
        store.indexingFiles = [1: FileRecord(id: 1, path: source.path, kind: .doc, size: 3, mtime: originalTime,
                                            inode: UInt64(before.st_ino), device: UInt64(before.st_dev), state: "pending")]
        try store.beginVectorJob()
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: Data("new".utf8)); try writer.close()
        let micros = Int(before.st_mtimespec.tv_nsec)/1000 + 500
        let timestamp = timeval(tv_sec: before.st_mtimespec.tv_sec + micros/1_000_000, tv_usec: Int32(micros%1_000_000))
        let times = [timestamp, timestamp]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimes(source.path, $0.baseAddress) }, 0)
        var after = Darwin.stat(); XCTAssertEqual(stat(source.path, &after), 0)
        let changedTime = Double(after.st_mtimespec.tv_sec) + Double(after.st_mtimespec.tv_nsec)/1e9
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertNotEqual(changedTime, originalTime)
        XCTAssertLessThan(abs(changedTime-originalTime), 0.001)
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        XCTAssertThrowsError(try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "late")) {
            XCTAssertTrue(String(describing: $0).contains("source_changed"))
        }
    }

    func testDeviceRenumberingDoesNotInvalidateAnUnchangedSource() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        try Data("same".utf8).write(to: source)
        var st = Darwin.stat(); XCTAssertEqual(stat(source.path, &st), 0)
        store.indexingModel = model
        store.indexingFiles = [1: FileRecord(id: 1, path: source.path, kind: .doc, size: 4,
            mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec)/1e9,
            inode: UInt64(st.st_ino), device: UInt64(st.st_dev) ^ 1, state: "pending")]
        try store.beginVectorJob()
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        XCTAssertNoThrow(try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "same"))
    }

    func testCompletionBumpsGenerationOnceAndIsIdempotent() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.indexingModel = model
        try store.beginVectorJob()
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "exact")
        let before = try store.modelGeneration
        XCTAssertTrue(try store.finishShadowIfCovered(model: model))
        XCTAssertEqual(try store.modelGeneration, before + 1)
        XCTAssertTrue(try store.finishShadowIfCovered(model: model))
        XCTAssertEqual(try store.modelGeneration, before + 1)
    }

    func testLegacyIndexingQueuesFilesWrittenOnlyByCoreAI() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.indexingModel = model
        try store.beginVectorJob()
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "current")
        try store.db.execute("UPDATE files SET state='done' WHERE id=1")
        store.indexingModel = nil
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { throw WorkerError.failed("must not load") })
        try indexer.checkModel()
        XCTAssertEqual(try store.pendingCount(), 1)
        var models = 0
        try store.db.query("SELECT COUNT(*) FROM embedding_models") { models = Int($0.int(0)) }
        XCTAssertEqual(models, 2)
    }

    func testActivationBetweenPreparationAndCommitStopsTheIndexer() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.indexingModel = model
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { throw WorkerError.failed("must not load") })
        _ = indexer
        try store.activateModel(key: "coreai-eg2-v1")
        XCTAssertThrowsError(try store.beginVectorJob())
    }

    func testLegacyInFlightWriteIsRejectedAfterCoreAIActivation() throws {
        let (dir, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { throw WorkerError.failed("must not load") })
        _ = indexer
        try store.beginVectorJob()
        try store.activateModel(key: "coreai-eg2-v1")
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        XCTAssertThrowsError(try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: vector, modelInput: "late legacy"))
    }

    func testCoreAIOnlyWritesActivationRollbackAndLateWrite() throws {
        let (dir, store, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.indexingModel = model
        try store.beginVectorJob()
        var v = [Float](repeating: 0, count: 768); v[0] = 1
        try store.addSegment(file: 1, kind: .chunk, modality: .text, text: "current text", vector: v, modelInput: "exact prompt")
        var legacy: Int64 = -1, coreai: Int64 = 0
        try store.db.query("SELECT COUNT(vec) FROM segments") { legacy = $0.int(0) }
        try store.db.query("SELECT COUNT(*) FROM vectors") { coreai = $0.int(0) }
        XCTAssertEqual(legacy, 0); XCTAssertEqual(coreai, 1)
        XCTAssertEqual(try store.activationCoverage(model: model).done, 1)
        let a = try store.activateModel(key: "coreai-eg2-v1")
        XCTAssertThrowsError(try store.addSegment(file: 1, kind: .chunk, modality: .text, vector: v, modelInput: "late"))
        let b = try store.activateModel(key: "llama-vectors1", rollback: true)
        XCTAssertEqual(b, a + 1)
        let c = try store.activateModel(key: "coreai-eg2-v1")
        XCTAssertEqual(c, b + 1)
        var active: [String] = []
        try store.db.query("SELECT key FROM embedding_models WHERE state='active'") { active.append($0.text(0)!) }
        XCTAssertEqual(active, ["coreai-eg2-v1"])
        try store.db.execute("DELETE FROM segments WHERE modality='text'")
        XCTAssertEqual(try store.activationCoverage(model: model).done, 0)
        var count = -1
        try store.db.query("SELECT COUNT(*) FROM vectors") { count = Int($0.int(0)) }
        XCTAssertEqual(count, 0)
    }
}

func removeActivationFromFixture(_ store: IndexStore) throws {
    var names: [String] = []
    try store.db.query("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'generation_%'") { names.append($0.text(0)!) }
    for name in names { try store.db.execute("DROP TRIGGER \(name)") }
    try store.db.execute("CREATE TRIGGER shadow_clip_insert AFTER INSERT ON segments WHEN NEW.kind='clip' BEGIN UPDATE embedding_models SET state='building',completed_at=NULL WHERE key='coreai-eg2-v1' AND state IN ('complete','active'); END")
}
