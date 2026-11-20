import DigUpKit
import Foundation

@available(macOS 27, *)
func checkStorage(_ config: Configuration) throws -> [String:Any] {
    let root=URL(fileURLWithPath:config.index).deletingLastPathComponent().appendingPathComponent("storage-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let fixture=root.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
    let doc=fixture.appendingPathComponent("example.md")
    try Data("A short document about conservation of energy.".utf8).write(to:doc)
    let candidate=Crawler.crawl([fixture],options:IndexOptions()).candidates.first!
    var checks: [String]=[]
    let mutations: [(String,(IndexStore,Int64,Int64) throws -> Void,Bool)] = [
        ("segment_delete",{ s,_,id in try s.db.run("DELETE FROM segments WHERE id=?",[.int(id)]) },true),
        ("legacy_vec_null_migrations",{ s,_,id in try s.db.run("UPDATE segments SET vec=NULL WHERE id=?",[.int(id)]) },true),
        ("segment_excerpt_update",{ s,_,id in try s.db.run("UPDATE segments SET excerpt='changed' WHERE id=?",[.int(id)]) },true),
        ("fts_update",{ s,_,id in try s.db.run("UPDATE fts SET body='changed' WHERE rowid=?",[.int(id)]) },true),
        ("fts_delete",{ s,_,id in try s.db.run("DELETE FROM fts WHERE rowid=?",[.int(id)]) },true),
        ("fts_replace",{ s,_,id in try s.db.run("INSERT OR REPLACE INTO fts(rowid,name,body) VALUES(?,'','replaced')",[.int(id)]) },true),
        ("fts_update_rollback",{ s,_,id in
            do {
                try s.db.transaction {
                    try s.db.run("UPDATE fts SET body='rolled back' WHERE rowid=?",[.int(id)])
                    throw CheckError("intentional rollback")
                }
            } catch let error as CheckError where error.description == "intentional rollback" {}
        },false),
        ("file_delete",{ s,f,_ in try s.delete(f) },true),
        ("prune",{ s,_,_ in try s.prune(keepingUnder:[]) },true),
        ("resetAll_reindex",{ s,_,_ in try s.resetAll() },true),
        ("requeue_changed",{ s,f,_ in try s.requeue(f,as:candidate) },true),
        ("move",{ s,f,_ in try s.move(f,to:doc.path+".moved") },true),
        ("file_identity_update",{ s,f,_ in try s.db.run("UPDATE files SET mtime=mtime+1 WHERE id=?",[.int(f)]) },true),
        ("readAgainOnce",{ s,f,_ in
            for key in ["scans_ocr","pictures_drawn","fast_screenshot_ocr_v1"] { try s.setMeta(key,"1") }
            try s.finish(f,state:"failed",detail:"It took more than 99 seconds to read")
            _=try s.readAgainOnce()
        },true),
        ("finish_metadata",{ s,f,_ in try s.finish(f,state:"partial",info:["read_to":"40"]) },false),
        ("tags",{ s,f,_ in try s.addTags(["blue"],to:f) },false),
        ("long_file_append",{ s,f,_ in
            try s.addSegment(file:f,kind:.chunk,modality:.text,loc:41,text:"More text",vector:[Float](repeating:0.01,count:768))
        },false),
        ("compaction",{ s,_,_ in
            try s.db.execute("CREATE TABLE scratch_padding(x BLOB); INSERT INTO scratch_padding VALUES(zeroblob(40000000)); DELETE FROM scratch_padding;")
            try require(try s.compactIfSparse() != nil,"compaction did not run")
        },false)
    ]
    for (name,mutate,drops) in mutations {
        let store=try IndexStore(directory:root.appendingPathComponent(name))
        let file=try store.insert(candidate)
        let text=Prompts.document(title:"example",text:"A short document about conservation of energy.")
        let vector=[Float](repeating:1/Float(768).squareRoot(),count:768)
        try store.addSegment(file:file,kind:.chunk,modality:.text,loc:1,text:"A short document about conservation of energy.",vector:vector,modelInput:text)
        let segment=try store.eligibleShadowSegments()[0]
        let info=WorkerInfo(model:"google/embeddinggemma-2",revision:"storage-test",runtime:"coreai-ane",dtype:"fp16",dim:768,textOnly:true,loadSeconds:nil)
        let model=try store.registerShadow(key:"coreai-eg2-text-v1",info:info,weightsSHA256:"test")
        let input=try store.rebuildInput(segment:segment,scratch:root)
        try require(try store.commitShadow(model:model,input:input,vector:vector),"initial commit failed: \(name)")
        try require(try store.finishShadowIfCovered(model:model),"initial coverage incomplete")
        try mutate(store,file,segment)
        let counts=try store.shadowCounts(model:model)
        try require(counts.done == (drops ? 0 : 1),"invalidation mismatch: \(name), \(counts.done)")
        if drops { try require(try !store.commitShadow(model:model,input:input,vector:vector),"stale commit accepted: \(name)") }
        var fk=0
        try store.db.query("PRAGMA foreign_keys") { fk=Int($0.int(0)) }
        try require(fk==1,"foreign keys disabled")
        try store.db.query("PRAGMA foreign_key_check") { _ in throw CheckError("foreign key violation: \(name)") }
        checks.append(name)
    }
    return ["passed":true,"checks":checks,"count":checks.count,"scratch":root.path]
}
