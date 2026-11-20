import XCTest
@testable import DigUpKit

final class ShadowCarryTests: XCTestCase {
    func testCarryMatchesEveryModalityByIdentityAndRevisionAcrossSegmentRenumbering() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try IndexStore(directory: root.appendingPathComponent("source"))
        let target = try IndexStore(directory: root.appendingPathComponent("target"))
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "test", runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        let old = try source.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        let new = try target.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        let revision = IndexStore.contentRevision("input")
        let vector = [Float(1)] + [Float](repeating: 0, count: 767)
        for (index, modality) in ["text", "image", "audio", "video"].enumerated() {
            for (store, offset, model) in [(source, 0, old), (target, 100, new)] {
                let id = Int64(index + offset + 1)
                try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(?,?,'doc',0,0,0,0)", [.int(id), .text("/carry/\(modality)")])
                try store.db.run("INSERT INTO segments(id,file,kind,modality) VALUES(?,?,'chunk',?)", [.int(id), .int(id), .text(modality)])
                try store.db.run("INSERT INTO embedding_inputs VALUES(?,'input',?)", [.int(id), .blob(revision)])
                if offset == 0 {
                    try store.db.run("INSERT INTO vectors VALUES(?,?,?,?,?)", [.int(model), .int(id), .blob(revision), .text(modality), .blob(Vectors.half(vector))])
                }
            }
        }
        try source.db.run("UPDATE embedding_models SET state='complete' WHERE id=?", [.int(old)])
        let carry = try ShadowCarrySource(index: source.directory, target: target, model: new)
        for id in Int64(101)...104 {
            XCTAssertEqual(try carry.vector(target: target, segment: id, revision: revision), vector)
            XCTAssertNil(try carry.vector(target: target, segment: id, revision: IndexStore.contentRevision("changed")))
        }
        try target.db.execute("UPDATE files SET path='/different' WHERE id=101")
        XCTAssertNil(try carry.vector(target: target, segment: 101, revision: revision))
        try target.db.run("UPDATE embedding_models SET build='different' WHERE id=?", [.int(new)])
        XCTAssertThrowsError(try ShadowCarrySource(index: source.directory, target: target, model: new))
        XCTAssertThrowsError(try Database(path: source.file.path, readOnly: true).execute("DELETE FROM vectors"))
    }
}
