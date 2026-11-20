import XCTest
@testable import DigUpKit
import DigUpCoreAIRuntime
import CoreGraphics
import ImageIO
import Darwin

final class ImageShadowTests: XCTestCase {
    func testImageCommitUsesDecodedPixelsRefusesChangedSourceAndCascades() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("c1-image-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source=folder.appendingPathComponent("source.png")
        let pixels=Data(repeating:127,count:256*256*3)
        let provider=CGDataProvider(data:pixels as CFData)!
        let image=CGImage(width:256,height:256,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:256*3,
                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
                          decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let destination=CGImageDestinationCreateWithURL(source as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var st=Darwin.stat()
        XCTAssertEqual(stat(source.path,&st),0)
        let mtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
        let store=try IndexStore(directory:folder.appendingPathComponent("index"))
        try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('fingerprint','photo140 shot280 page280 frame70/3.0s')")
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,?,'image',?,?,?,?)",
                         [.text(source.path),.int(st.st_size),.double(mtime),.int(Int64(st.st_ino)),.int(Int64(st.st_dev))])
        var vector=[Float](repeating:0,count:768); vector[0]=1
        try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(1,1,'image','image',?)",[.blob(Vectors.half(vector))])
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"fake",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:false,loadSeconds:nil)
        let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"fake")
        let input=try store.rebuildImage(segment:1,scratch:folder.appendingPathComponent("prepared"))
        XCTAssertTrue(try store.commitShadowImage(model:model,input:input,vector:vector))
        let repeated=try store.rebuildImage(segment:1,scratch:folder.appendingPathComponent("repeated"))
        XCTAssertEqual(input.contentRev,repeated.contentRev)
        XCTAssertTrue(input.identity.hasPrefix("image-v2\n"))
        let original=try Data(contentsOf:input.prepared)
        try (original+Data("ignored container trailer".utf8)).write(to:input.prepared)
        XCTAssertTrue(try store.commitShadowImage(model:model,input:input,vector:vector))
        try Data([0]).write(to:input.prepared)
        XCTAssertFalse(try store.commitShadowImage(model:model,input:input,vector:vector))
        try original.write(to:input.prepared)
        let writer=try FileHandle(forWritingTo:source)
        try writer.seekToEnd(); try writer.write(contentsOf:Data([0])); try writer.close()
        XCTAssertFalse(try store.commitShadowImage(model:model,input:input,vector:vector))
        XCTAssertThrowsError(try store.rebuildImage(segment:1,scratch:folder.appendingPathComponent("changed"))) { error in
            XCTAssertTrue(String(describing:error).contains("source_changed"))
        }
        let changedProvider=CGDataProvider(data:Data(repeating:128,count:256*256*3) as CFData)!
        let changed=CGImage(width:256,height:256,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:256*3,
                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:changedProvider,
                            decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let changedDestination=CGImageDestinationCreateWithURL(source as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(changedDestination,changed,nil)
        XCTAssertTrue(CGImageDestinationFinalize(changedDestination))
        XCTAssertEqual(stat(source.path,&st),0)
        let changedMtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
        try store.db.run("UPDATE files SET size=?,mtime=?,inode=? WHERE id=1",
                         [.int(st.st_size),.double(changedMtime),.int(Int64(st.st_ino))])
        let rebuilt=try store.rebuildImage(segment:1,scratch:folder.appendingPathComponent("updated"))
        XCTAssertNotEqual(input.contentRev,rebuilt.contentRev)
        XCTAssertTrue(try store.commitShadowImage(model:model,input:rebuilt,vector:vector))
        try store.db.run("DELETE FROM segments WHERE id=1")
        var remaining: Int64 = -1
        try store.db.query("SELECT count(*) FROM vectors WHERE model=?",[.int(model)]) { remaining=$0.int(0) }
        XCTAssertEqual(remaining,0)
        var violations=0
        try store.db.query("PRAGMA foreign_key_check") { _ in violations += 1 }
        XCTAssertEqual(violations,0)
    }

    func testCarryCopiesOnlyEligibleTextWithMatchingIdentityAndRevision() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("c1-carry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=try IndexStore(directory:folder)
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"fake",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:true,loadSeconds:nil)
        let source=try store.registerShadow(key:"coreai-eg2-text-v1",info:info,weightsSHA256:"fake")
        let target=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"fake")
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/c1-carry-unit','doc',1,0,1,1)")
        let blob=Data(repeating:7,count:1536), rev=IndexStore.contentRevision("exact prompt")
        for (id,modality,eligible) in [(Int64(1),"text",true),(2,"image",true),(3,"text",false)] {
            try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,1,'chunk',?,?)",[.int(id),.text(modality),eligible ? .blob(blob) : .null])
            try store.db.run("INSERT INTO embedding_inputs VALUES(?,'exact prompt',?)",[.int(id),.blob(rev)])
            try store.db.run("INSERT INTO vectors VALUES(?,?,?, ?,?)",[.int(source),.int(id),.blob(rev),.text(modality),.blob(blob)])
        }
        XCTAssertThrowsError(try store.carryShadowText(model:target,from:"coreai-eg2-text-v1",sourceBuild:"wrong",weights:"fake"))
        XCTAssertEqual(try store.carryShadowText(model:target,from:"coreai-eg2-text-v1",sourceBuild:"fake",weights:"fake"),1)
        XCTAssertEqual(try store.carryShadowText(model:target,from:"coreai-eg2-text-v1",sourceBuild:"fake",weights:"fake"),0)
        var carried: [(Int64,Data)]=[]
        try store.db.query("SELECT segment,vec FROM vectors WHERE model=?",[.int(target)]) { carried.append(($0.int(0),$0.blob(1)!)) }
        XCTAssertEqual(carried.count,1);XCTAssertEqual(carried[0].0,1);XCTAssertEqual(carried[0].1,blob)
        let wrongRevision=IndexStore.contentRevision("different prompt")
        try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(4,1,'chunk','text',?)",[.blob(blob)])
        try store.db.run("INSERT INTO embedding_inputs VALUES(4,'exact prompt',?)",[.blob(wrongRevision)])
        try store.db.run("INSERT INTO vectors VALUES(?,4,?,'text',?)",[.int(source),.blob(wrongRevision),.blob(blob)])
        XCTAssertThrowsError(try store.carryShadowText(model:target,from:"coreai-eg2-text-v1",sourceBuild:"fake",weights:"fake"))
        try store.db.run("DELETE FROM segments WHERE id=4")
        try store.db.run("UPDATE embedding_models SET prompts='different' WHERE id=?",[.int(target)])
        XCTAssertThrowsError(try store.carryShadowText(model:target,from:"coreai-eg2-text-v1",sourceBuild:"fake",weights:"fake"))
    }

    func testSchemaEightPreservesTextAndCascadesImageInputs() throws {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("c1-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=try IndexStore(directory:folder)
        var version: Int64=0
        try store.db.query("PRAGMA user_version") { version=$0.int(0) }
        XCTAssertEqual(version,12)
        try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(1,'/c1-unit-image','image',1,0,1,1)")
        try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(1,1,'image','image',?)",[.blob(Data(repeating:0,count:1536))])
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"fake",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:true,loadSeconds:nil)
        let model=try store.registerShadow(key:"coreai-eg2-v1",info:info,weightsSHA256:"fake")
        let rev=IndexStore.contentRevision("prepared-image")
        try store.db.run("INSERT INTO embedding_inputs VALUES(1,'prepared-image',?)",[.blob(rev)])
        try store.db.run("INSERT INTO vectors VALUES(?,1,?,'image',?)",[.int(model),.blob(rev),.blob(Data(repeating:0,count:1536))])
        XCTAssertEqual(try store.shadowCounts(model:model).eligible,1)
        XCTAssertTrue(try store.finishShadowIfCovered(model:model))
        try store.db.run("UPDATE embedding_inputs SET input='different',content_rev=? WHERE segment=1",[.blob(IndexStore.contentRevision("different"))])
        XCTAssertEqual(try store.shadowCounts(model:model).done,0)
        var state: String?
        try store.db.query("SELECT state FROM embedding_models WHERE id=?",[.int(model)]) { state=$0.text(0) }
        XCTAssertEqual(state,"building")
        try store.db.run("DELETE FROM segments WHERE id=1")
        var remaining=0
        try store.db.query("SELECT COUNT(*) FROM embedding_inputs") { remaining=Int($0.int(0)) }
        XCTAssertEqual(remaining,0)
        var violations=0
        try store.db.query("PRAGMA foreign_key_check") { _ in violations += 1 }
        XCTAssertEqual(violations,0)
    }
}
