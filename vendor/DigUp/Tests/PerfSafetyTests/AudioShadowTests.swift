import XCTest
@testable import DigUpKit
import Darwin

final class AudioShadowTests: XCTestCase {
    func testAbsentAudioEncoderKeepsRowsUntilTheSourceIsDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("retained.wav")
        let samples = [Int16](repeating: 1000, count: 16000)
        try AudioExtractor.writeWAV(samples[...], to: wav)
        let store = try IndexStore(directory: root.appendingPathComponent("index.noindex"))
        store.indexingKinds = Set(FileKind.allCases).subtracting([.audio])
        let indexer = try Indexer(store: store, options: IndexOptions()) { XCTFail("must not embed audio"); throw NSError(domain: "test", code: 1) }
        defer { indexer.finish() }
        XCTAssertEqual(try indexer.sync([root]).added, 1)
        let file = try XCTUnwrap(store.files(under: [root.path]).first)
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "test", runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        let model = try store.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        let vector = Data(repeating: 0, count: 1536)
        XCTAssertEqual(file.kind, .audio)
        try store.db.run("DELETE FROM segments WHERE file=?", [.int(file.id)])
        try store.db.run("INSERT INTO segments(id,file,kind,modality,loc,loc_end,vec) VALUES(1,?,'audio','audio',0,1,?)", [.int(file.id), .blob(vector)])
        try store.db.execute("INSERT INTO embedding_inputs VALUES(1,'existing',zeroblob(32))")
        try store.db.run("INSERT INTO vectors VALUES(?,1,zeroblob(32),'audio',?)", [.int(model), .blob(vector)])
        XCTAssertEqual(try indexer.sync([root]).removed, 0)
        for table in ["files", "segments", "vectors"] {
            try store.db.query("SELECT COUNT(*) FROM \(table)") { XCTAssertEqual($0.int(0), 1, table) }
        }
        try FileManager.default.removeItem(at: wav)
        XCTAssertEqual(try indexer.sync([root]).removed, 1)
        for table in ["files", "segments", "vectors"] {
            try store.db.query("SELECT COUNT(*) FROM \(table)") { XCTAssertEqual($0.int(0), 0, table) }
        }
    }

    func testRebuildUsesTheIndexedSampleEndpoint() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("p6-audio-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source=folder.appendingPathComponent("source.wav"),samples=[Int16](repeating:1000,count:40000)
        try AudioExtractor.writeWAV(samples[...],to:source)
        let store=try IndexStore(directory:folder.appendingPathComponent("index"))
        try store.db.run("INSERT INTO meta VALUES('fingerprint','audio30.0/25.0s')")
        var st=Darwin.stat();XCTAssertEqual(stat(source.path,&st),0)
        let time=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,?,'video',?,?,?,0)",[.text(source.path),.int(st.st_size),.double(time),.int(Int64(st.st_ino))])
        try store.db.run("INSERT INTO segments(id,file,kind,modality,loc,loc_end,vec) VALUES(1,1,'audio','audio',0,2.49,?)",[.blob(Data(repeating:0,count:1536))])
        let input=try store.rebuildAudio(segment:1,scratch:folder.appendingPathComponent("prepared"))
        XCTAssertEqual(try PCM16.decode(input.prepared).count,39840)
        XCTAssertTrue(input.identity.contains("samples=39840"))
    }

    func testSchemaNineReopensCoverageForExistingLegacyAudio() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("p5-audio-coverage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        do {
            let store=try IndexStore(directory:folder)
            try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/p5-audio-coverage','audio',0,0,0,0)")
            try store.db.run("INSERT INTO segments(id,file,kind,modality,loc,loc_end,vec) VALUES(1,1,'audio','audio',0,30,?)",[.blob(Data(repeating:0,count:1536))])
            let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"p4-build",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:false,loadSeconds:nil)
            let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same")
            try store.db.run("UPDATE embedding_models SET state='complete',completed_at=1 WHERE id=?",[.int(model)])
            try removeActivationFromFixture(store)
            try store.db.execute("DROP TRIGGER shadow_clip_insert; DROP TABLE embedding_modality_identities; PRAGMA user_version=8;")
        }
        let migrated=try IndexStore(directory:folder)
        var model: Int64=0,state: String?
        try migrated.db.query("SELECT id,state FROM embedding_models WHERE key='coreai-eg2-v1'") { model=$0.int(0);state=$0.text(1) }
        XCTAssertEqual(state,"building")
        XCTAssertEqual(try migrated.shadowCounts(model:model).eligible,1)
        XCTAssertFalse(try migrated.finishShadowIfCovered(model:model))
    }

    func testAudioRevisionCommitSourceRefusalIdentityAndCascade() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("p5-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source=folder.appendingPathComponent("source.wav")
        let samples=(0..<40000).map { Int16(($0%160)-80)*200 }
        try AudioExtractor.writeWAV(samples[...],to:source)
        let store=try IndexStore(directory:folder.appendingPathComponent("index"))
        try store.db.run("INSERT INTO meta(key,value) VALUES('fingerprint','photo140 shot280 page280 frame70/3.0s audio30.0/25.0s')")
        var st=Darwin.stat();XCTAssertEqual(stat(source.path,&st),0)
        func stamp() throws {
            XCTAssertEqual(stat(source.path,&st),0)
            try store.db.run("UPDATE files SET size=?,mtime=?,inode=? WHERE id=1",[.int(st.st_size),.double(Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9),.int(Int64(st.st_ino))])
        }
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,?,'audio',0,0,0,0)",[.text(source.path)])
        try stamp()
        var vector=[Float](repeating:0,count:768);vector[0]=1
        for (id,modality) in [(Int64(1),"audio"),(2,"text"),(3,"image")] {
            try store.db.run("INSERT INTO segments(id,file,kind,modality,loc,loc_end,vec) VALUES(?,1,?,?,0,2.5,?)",[.int(id),.text(modality),.text(modality),.blob(Vectors.half(vector))])
        }
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"preserved-build",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:false,loadSeconds:nil)
        let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same-weights")
        let rev=IndexStore.contentRevision("existing")
        for (id,modality) in [(Int64(2),"text"),(3,"image")] {
            try store.db.run("INSERT INTO embedding_inputs VALUES(?,'existing',?)",[.int(id),.blob(rev)])
            try store.db.run("INSERT INTO vectors VALUES(?,?,?, ?,?)",[.int(model),.int(id),.blob(rev),.text(modality),.blob(Vectors.half(vector))])
        }
        let identity=String(repeating:"a",count:64)
        try store.registerShadowAudio(model:model,identity:identity)
        try store.registerShadowAudio(model:model,identity:identity)
        XCTAssertThrowsError(try store.registerShadowAudio(model:model,identity:String(repeating:"b",count:64)))
        XCTAssertEqual(try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same-weights"),model)
        let input=try store.rebuildAudio(segment:1,scratch:folder.appendingPathComponent("prepared"))
        XCTAssertTrue(input.identity.hasPrefix("audio-v1\n"))
        XCTAssertTrue(input.identity.contains("\nsamples=40000\n"))
        XCTAssertTrue(try store.commitShadowAudio(model:model,input:input,vector:vector))
        for _ in 0..<3 {
            let repeated=try store.rebuildAudio(segment:1,scratch:folder.appendingPathComponent("repeat"))
            XCTAssertEqual(repeated.contentRev,input.contentRev)
        }
        XCTAssertEqual(try store.shadowCounts(model:model).done,3)
        XCTAssertTrue(try store.finishShadowIfCovered(model:model))
        let original=try Data(contentsOf:input.prepared)
        try (original+Data("container metadata ignored".utf8)).write(to:input.prepared)
        XCTAssertTrue(try store.commitShadowAudio(model:model,input:input,vector:vector))
        var changed=original;changed[44] ^= 1;try changed.write(to:input.prepared)
        XCTAssertFalse(try store.commitShadowAudio(model:model,input:input,vector:vector))
        try original.write(to:input.prepared)
        let writer=try FileHandle(forWritingTo:source);try writer.seekToEnd();try writer.write(contentsOf:Data([0]));try writer.close()
        XCTAssertFalse(try store.commitShadowAudio(model:model,input:input,vector:vector))
        XCTAssertThrowsError(try store.rebuildAudio(segment:1,scratch:folder.appendingPathComponent("changed"))) { error in XCTAssertTrue(String(describing:error).contains("source_changed")) }
        let changedSamples=samples.map { $0+1 };try AudioExtractor.writeWAV(changedSamples[...],to:source);try stamp()
        let updated=try store.rebuildAudio(segment:1,scratch:folder.appendingPathComponent("updated"))
        XCTAssertNotEqual(updated.contentRev,input.contentRev)
        XCTAssertTrue(try store.commitShadowAudio(model:model,input:updated,vector:vector))
        try store.db.run("DELETE FROM segments WHERE id=1")
        var count=0;try store.db.query("SELECT COUNT(*) FROM vectors WHERE segment=1") { count=Int($0.int(0)) };XCTAssertEqual(count,0)
        var violations=0;try store.db.query("PRAGMA foreign_key_check") { _ in violations+=1 };XCTAssertEqual(violations,0)
    }
    func testSchemaNinePreservesExistingTextAndImageRowsAndModelIdentity() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("p5-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let blob=Data(repeating:3,count:1536),rev=IndexStore.contentRevision("retained")
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"p4-build",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:false,loadSeconds:nil)
        do {
            let store=try IndexStore(directory:folder)
            let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same")
            try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/p5-migration-fixture','image',0,0,0,0)")
            for (id,modality) in [(Int64(1),"text"),(2,"image")] {
                try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,1,?,?,?)",[.int(id),.text(modality),.text(modality),.blob(blob)])
                try store.db.run("INSERT INTO embedding_inputs VALUES(?,'retained',?)",[.int(id),.blob(rev)])
                try store.db.run("INSERT INTO vectors VALUES(?,?,?, ?,?)",[.int(model),.int(id),.blob(rev),.text(modality),.blob(blob)])
            }
            XCTAssertTrue(try store.finishShadowIfCovered(model:model))
            try removeActivationFromFixture(store)
            try store.db.execute("DROP TRIGGER shadow_clip_insert; DROP TABLE embedding_modality_identities; PRAGMA user_version=8;")
        }
        let migrated=try IndexStore(directory:folder)
        let model=try migrated.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same")
        var rows=0
        try migrated.db.query("SELECT content_rev,vec FROM vectors WHERE model=?",[.int(model)]) {
            XCTAssertEqual($0.blob(0),rev);XCTAssertEqual($0.blob(1),blob);rows+=1
        }
        XCTAssertEqual(rows,2)
        var state: String?
        try migrated.db.query("SELECT state FROM embedding_models WHERE id=?",[.int(model)]) { state=$0.text(0) }
        XCTAssertEqual(state,"complete")
    }

}
