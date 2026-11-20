import DigUpKit
import Foundation

@available(macOS 27, *)
func checkInputRecovery(_ config: Configuration) throws -> [String: Any] {
    let root=URL(fileURLWithPath:config.index).deletingLastPathComponent().appendingPathComponent("r4-input-check-\(UUID().uuidString)")
    let fixture=root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
    let url=fixture.appendingPathComponent("ohms.md")
    let original="The resistance is 100 \u{2126}, measured in the laboratory."
    try Data(original.utf8).write(to:url)
    let candidate=Crawler.crawl([fixture],options:IndexOptions()).candidates.first!
    let store=try IndexStore(directory:root.appendingPathComponent("index"))
    let file=try store.insert(candidate)
    let vector=[Float](repeating:1/Float(768).squareRoot(),count:768)
    // Reproduce the old writer, without the new exact-input retention.
    try store.addSegment(file:file,kind:.chunk,modality:.text,loc:1,text:original,vector:vector)
    let segment=try store.eligibleShadowSegments()[0]
    var wasNull=false
    try store.db.query("SELECT original IS NULL FROM fts WHERE rowid=?",[.int(segment)]) { wasNull=$0.int(0)==1 }
    try require(wasNull,"fixture did not reproduce the legacy canonical-equivalence loss")
    let rebuilt=try store.rebuildInput(segment:segment,scratch:root)
    try require(rebuilt.text.utf8.elementsEqual(Prompts.document(title:"ohms",text:original).utf8),"original Unicode bytes were not recovered")
    let nul="title: NUL | text: before\u{0}after"
    try store.db.run("UPDATE embedding_inputs SET input=?,content_rev=? WHERE segment=?",[.text(nul),.blob(IndexStore.contentRevision(nul)),.int(segment)])
    var roundtrip: String?
    try store.db.query("SELECT input FROM embedding_inputs WHERE segment=?",[.int(segment)]) { roundtrip=$0.text(0) }
    try require(roundtrip?.utf8.elementsEqual(nul.utf8)==true,"SQLite truncated embedded NUL")
    try store.db.run("DELETE FROM embedding_inputs WHERE segment=?",[.int(segment)])
    try Data((original+" changed").utf8).write(to:url)
    var refused=false
    do { _=try store.rebuildInput(segment:segment,scratch:root) }
    catch { refused=String(describing:error).contains("changed:") }
    try require(refused,"changed source was read")
    return ["passed":true,"legacy_original_was_null":wasNull,"utf8_recovered":true,"sqlite_nul_roundtrip":true,"changed_source_refused":refused,"scratch":root.path]
}

@available(macOS 27, *)
func checkShadowRace(_ config: Configuration) throws -> [String: Any] {
    let store=try IndexStore(directory:URL(fileURLWithPath:config.index))
    let writer=try IndexStore(directory:URL(fileURLWithPath:config.index))
    var model: Int64=0
    var ids: [Int64]=[]
    try store.db.query("SELECT id FROM embedding_models WHERE key='coreai-eg2-text-v1'") { model=$0.int(0) }
    try store.db.query("SELECT segment FROM vectors WHERE model=? ORDER BY segment LIMIT 2",[.int(model)]) { ids.append($0.int(0)) }
    try require(model>0 && ids.count==2,"race check needs two real shadow vectors")
    let vector=[Float](repeating:1/Float(768).squareRoot(),count:768)
    let before=try store.rebuildInput(segment:ids[0],scratch:store.directory)
    try writer.db.run("UPDATE fts SET body='simulated indexer text edit',original=NULL WHERE rowid=?",[.int(ids[0])])
    try require(try !store.commitShadow(model:model,input:before,vector:vector),"in-flight old revision committed after text changed")
    var remaining=0
    try store.db.query("SELECT count(*) FROM vectors WHERE segment=?",[.int(ids[0])]) { remaining=Int($0.int(0)) }
    try require(remaining==0,"changed text retained a shadow vector")
    let deleted=try store.rebuildInput(segment:ids[1],scratch:store.directory)
    try writer.db.run("DELETE FROM segments WHERE id=?",[.int(ids[1])])
    try require(try !store.commitShadow(model:model,input:deleted,vector:vector),"deleted segment accepted an in-flight vector")
    try store.db.query("SELECT count(*) FROM vectors WHERE segment=?",[.int(ids[1])]) { remaining=Int($0.int(0)) }
    try require(remaining==0,"segment deletion did not cascade")
    try store.db.query("PRAGMA foreign_key_check") { _ in throw CheckError("foreign key violation after race") }
    return ["passed":true,"text_change_refused_old_commit":true,"text_change_dropped_vector":true,"delete_cascaded":true,"delete_refused_old_commit":true,"segments":ids]
}
