import XCTest
@testable import DigUpKit
import Darwin

final class VideoShadowTests: XCTestCase {
    func testScheduleRetainsPartialAndStopsAtCoverage() throws {
        XCTAssertEqual(try VideoDecoder.schedule(duration:20),[VideoClipRange(start:0,end:14),VideoClipRange(start:10,end:20)])
        XCTAssertEqual(try VideoDecoder.schedule(duration:14).count,1)
        XCTAssertEqual(try VideoDecoder.schedule(duration:0.1),[VideoClipRange(start:0,end:0.1)])
        XCTAssertEqual(try VideoDecoder.schedule(duration:60).map(\.start),[0,10,20,30,40,50])
        XCTAssertEqual(try VideoDecoder.schedule(duration:14.1).last,VideoClipRange(start:10,end:14.1))
        for duration in [0,Double.nan,Double.infinity,-1] { XCTAssertThrowsError(try VideoDecoder.schedule(duration:duration)) }
    }

    func testVideoIdentitySourceRefusalCascadeAndPreservedModalities() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("p6-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source=folder.appendingPathComponent("source.bin")
        try Data([0]).write(to:source)
        let store=try IndexStore(directory:folder.appendingPathComponent("index"))
        var st=Darwin.stat();XCTAssertEqual(stat(source.path,&st),0)
        let time=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,?,'video',?,?,?,0)",[.text(source.path),.int(st.st_size),.double(time),.int(Int64(st.st_ino))])
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"retained",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:false,loadSeconds:nil)
        let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"same")
        var vector=[Float](repeating:0,count:768);vector[0]=1
        let rev=IndexStore.contentRevision("prior")
        for (id,modality) in [(Int64(1),"text"),(2,"image"),(3,"audio")] {
            try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,1,?,?,?)",[.int(id),.text(modality),.text(modality),.blob(Vectors.half(vector))])
            try store.db.run("INSERT INTO embedding_inputs VALUES(?,'prior',?)",[.int(id),.blob(rev)])
            try store.db.run("INSERT INTO vectors VALUES(?,?,?, ?,?)",[.int(model),.int(id),.blob(rev),.text(modality),.blob(Vectors.half(vector))])
        }
        XCTAssertTrue(try store.finishShadowIfCovered(model:model))
        let identity=String(repeating:"a",count:64)
        try store.registerShadowVideo(model:model,identity:identity)
        XCTAssertThrowsError(try store.registerShadowVideo(model:model,identity:String(repeating:"b",count:64)))
        try store.db.run("INSERT INTO segments(id,file,kind,modality,loc,loc_end) VALUES(4,1,'clip','video',0,1)")
        XCTAssertEqual(try store.shadowCounts(model:model).eligible,4)
        XCTAssertFalse(try store.finishShadowIfCovered(model:model))
        XCTAssertEqual(try store.eligibleShadowSegments(model:model,modalities:["video"]),[4])
        let frames=[try RGBImage(width:1,height:1,pixels:[1,2,3])],range=VideoClipRange(start:0,end:1)
        let text=IndexStore.videoIdentity(frames,range:range),vrev=IndexStore.contentRevision(text)
        try store.db.run("INSERT INTO embedding_inputs VALUES(4,?,?)",[.text(text),.blob(vrev)])
        var snapshot=""
        try store.db.query("SELECT json_array(s.file,s.kind,s.modality,s.loc,s.loc_end,f.path,f.size,f.mtime,f.inode,f.device) FROM segments s JOIN files f ON f.id=s.file WHERE s.id=4") { snapshot=$0.text(0)! }
        let input=RebuiltVideo(segment:4,path:source.path,range:range,frames:frames,snapshot:snapshot,identity:text,contentRev:vrev)
        XCTAssertTrue(try store.commitShadowVideo(model:model,input:input,vector:vector))
        XCTAssertTrue(try store.finishShadowIfCovered(model:model))
        let altered=RebuiltVideo(segment:4,path:source.path,range:range,frames:[try RGBImage(width:1,height:1,pixels:[9,2,3])],snapshot:snapshot,identity:text,contentRev:vrev)
        XCTAssertFalse(try store.commitShadowVideo(model:model,input:altered,vector:vector))
        try Data([0,1]).write(to:source)
        XCTAssertFalse(try store.commitShadowVideo(model:model,input:input,vector:vector))
        XCTAssertThrowsError(try store.rebuildVideo(segment:4))
        try store.db.run("DELETE FROM segments WHERE id=4")
        XCTAssertEqual(try store.shadowCounts(model:model).done,3)
        var count=0;try store.db.query("SELECT count(*) FROM vectors WHERE content_rev=?",[.blob(rev)]) { count=Int($0.int(0)) };XCTAssertEqual(count,3)
        try removeActivationFromFixture(store)
        try store.db.execute("DROP TRIGGER shadow_clip_insert; PRAGMA user_version=9")
        let reopened=try IndexStore(directory:folder.appendingPathComponent("index"))
        count=0;try reopened.db.query("SELECT count(*) FROM vectors WHERE content_rev=?",[.blob(rev)]) { count=Int($0.int(0)) };XCTAssertEqual(count,3)
        var version: Int64=0;try reopened.db.query("PRAGMA user_version") { version=$0.int(0) };XCTAssertEqual(version,12)
    }
}
