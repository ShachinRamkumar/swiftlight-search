import XCTest
@testable import DigUpKit
import DigUpCoreAIRuntime

final class FirstRunTests: XCTestCase {
    private func model(_ store: IndexStore) throws {
        try store.useCoreAIModel(key: "coreai-eg2-v1", info: WorkerInfo(model: "google/embeddinggemma-2", revision: "test",
            runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil),
            weights: "test", audioIdentity: nil, videoIdentity: nil)
    }

    func testProductionTestNamespacesRequireAnExplicitMatchingOptIn() throws {
        let signer = RuntimeCacheIdentity.productionIdentifier
        let test = signer + ".test.p7.first-run"
        XCTAssertThrowsError(try RuntimeCacheIdentity.validateOwner(identifier: signer, namespace: test))
        XCTAssertNoThrow(try RuntimeCacheIdentity.validateOwner(identifier: signer, namespace: test, testNamespace: test))
        XCTAssertThrowsError(try RuntimeCacheIdentity.validateOwner(identifier: "wrong", namespace: test, testNamespace: test))
        XCTAssertThrowsError(try RuntimeCacheIdentity.validateOwner(identifier: signer, namespace: "org.coreai.p7.stage0.test", testNamespace: "org.coreai.p7.stage0.test"))
        XCTAssertThrowsError(try RuntimeCacheIdentity.validateOwner(identifier: signer, namespace: test, testNamespace: test + "-other"))
    }

    func testOnlyANewNormalIndexReceivesProgressiveSearchPermission() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("first-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try IndexStore(directory: root.appendingPathComponent("fresh"))
        try model(fresh)
        XCTAssertEqual(try fresh.meta("first_run_embedding_model"), "coreai-eg2-v1")
        let existing = try IndexStore(directory: root.appendingPathComponent("existing"))
        try existing.db.execute("INSERT INTO files(path,kind,size,mtime,inode,device) VALUES('/existing','doc',1,0,0,0)")
        try model(existing)
        XCTAssertNil(try existing.meta("first_run_embedding_model"))
    }

    func testPriorityAndKeywordPreviewLeaveOnlyTheFinalContent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keyword-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(directory: root)
        try model(store)
        for (id,path,kind,size,mtime) in [(1,"/home/Desktop/old.txt","doc",10,1),
            (2,"/home/Other/new.txt","doc",10,5), (3,"/home/Documents/new.txt","doc",10,5),
            (4,"/home/Documents/large.txt","doc",2_000_000,10), (5,"/home/Desktop/photo.jpg","image",10,20)] {
            try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(?,?,?,?,?,0,0)",
                [.int(Int64(id)),.text(path),.text(kind),.int(Int64(size)),.double(Double(mtime))])
        }
        XCTAssertEqual(try store.pending(limit: nil).map(\.id), [3,1,2,4,5])
        try store.publishKeywordPreview(file: 1, texts: ["tidal turbines generate electricity"])
        var hits = 0
        try store.db.query("SELECT COUNT(*) FROM fts WHERE fts MATCH 'turbines'") { hits = Int($0.int(0)) }
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(try store.pendingCount(), 5)
        try store.beginVectorJob()
        let vector = [Float(1)] + [Float](repeating: 0, count: 767)
        try store.addSegment(file: 1, kind: .chunk, modality: .text, text: "final turbines", vector: vector, modelInput: "exact input")
        var previews = 0, vectors = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE kind='keyword_preview'") { previews = Int($0.int(0)) }
        try store.db.query("SELECT COUNT(*) FROM vectors") { vectors = Int($0.int(0)) }
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(vectors, 1)
        try store.db.query("SELECT COUNT(*) FROM fts WHERE fts MATCH 'turbines'") { hits = Int($0.int(0)) }
        XCTAssertEqual(hits, 1)
    }
}
