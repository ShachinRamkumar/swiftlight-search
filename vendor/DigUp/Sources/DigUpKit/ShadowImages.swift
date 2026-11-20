import CryptoKit
import Darwin
import Foundation

public struct RebuiltImage {
    public let segment: Int64
    public let path: String
    public let prepared: URL
    public let budget: Int
    public let snapshot: String
    public let identity: String
    public let contentRev: Data
}

extension IndexStore {
    static let imageColumns = """
        SELECT f.path,f.kind,s.kind,coalesce(s.loc,0),f.size,f.mtime,f.inode,
        json_array(s.file,s.kind,s.modality,s.loc,s.loc_end,s.excerpt,hex(s.vec),f.path,f.kind,f.size,f.mtime,f.inode,f.device)
        FROM segments s JOIN files f ON f.id=s.file WHERE s.id=? AND s.modality='image'
        """

    public func imageSourceCurrent(segment: Int64, snapshot: String? = nil) throws -> Bool {
        var current=false
        try db.query(Self.imageColumns,[.int(segment)]) { row in
            var st=Darwin.stat()
            guard stat(row.text(0)!,&st)==0 else { return }
            let mtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
            current=st.st_size==row.int(4) && mtime==row.double(5) && UInt64(st.st_ino)==UInt64(bitPattern:row.int(6))
                && (snapshot == nil || snapshot == row.text(7))
        }
        return current
    }

    public func rebuildImage(segment: Int64, scratch: URL) throws -> RebuiltImage {
        guard let fingerprint=try meta("fingerprint"), fingerprint.contains("photo140 shot280 page280 frame70/3.0s") else {
            throw WorkerError.failed("unsupported index image options fingerprint")
        }
        var fields: (String,String,String,Double,String)?
        try db.query(Self.imageColumns,[.int(segment)]) { fields=($0.text(0)!,$0.text(1)!,$0.text(2)!,$0.double(3),$0.text(7)!) }
        guard let (path,fileKind,kind,loc,snapshot)=fields,
              try imageSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        let url=URL(fileURLWithPath:path)
        let prepared: URL, budget: Int, prep: String
        switch kind {
        case "image":
            guard ["image","screenshot"].contains(fileKind) else { throw WorkerError.failed("unsupported image file kind") }
            let shot=fileKind == "screenshot"
            prepared=URL(fileURLWithPath:try ImageExtractor.prepare(url,maxPixel:shot ? 1536 : 1024,minSide:256,to:scratch,png:shot).path)
            budget=shot ? 280 : 140
            prep="indexer-imageio-thumbnail-v1:maxPixel=\(shot ? 1536 : 1024):minSide=256:png=\(shot)"
        case "frame":
            guard fileKind == "video" else { throw WorkerError.failed("frame source is not video") }
            let decoded=try runBlocking { try await VideoExtractor.keyframes(of:url,every:3,maxPixel:1024,to:scratch) }
            guard let frame=decoded.frames.first(where: { $0.start==loc }) else { throw WorkerError.failed("legacy frame missing") }
            prepared=URL(fileURLWithPath:frame.path)
            for other in decoded.frames where other.path != frame.path { try FileManager.default.removeItem(atPath:other.path) }
            budget=70;prep="indexer-video-keyframes-v1:interval3:maxPixel1024:time=\(frame.start)"
        case "page_image":
            prepared=scratch.appendingPathComponent(UUID().uuidString+".png")
            try PDFExtractor.renderPage(Int(loc),of:url,pixels:1400,to:prepared,png:true)
            budget=280;prep="indexer-pdf-page-v1:page=\(loc):minText=200:renderPixels=1400"
        default: throw WorkerError.failed("unsupported legacy image segment kind: \(kind)")
        }
        guard try imageSourceCurrent(segment:segment,snapshot:snapshot) else {
            try? FileManager.default.removeItem(at:prepared)
            throw WorkerError.failed("source_changed during image preparation: \(segment)")
        }
        let identity=try Self.imageIdentity(prepared:prepared,prep:prep,budget:budget)
        let rev=Self.contentRevision(identity)
        try db.transaction {
            guard try imageSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
            // Changed model pixels invalidate previous rows via shadow_input_update.
            try db.run("INSERT INTO embedding_inputs(segment,input,content_rev) VALUES(?,?,?) ON CONFLICT(segment) DO UPDATE SET input=excluded.input,content_rev=excluded.content_rev WHERE embedding_inputs.content_rev!=excluded.content_rev",
                       [.int(segment),.text(identity),.blob(rev)])
        }
        return RebuiltImage(segment:segment,path:path,prepared:prepared,budget:budget,snapshot:snapshot,identity:identity,contentRev:rev)
    }

    static func imageIdentity(prepared: URL, prep: String, budget: Int) throws -> String {
        let rgb=try ImageDecoder.decode(prepared)
        let digest=SHA256.hash(data:Data(rgb.pixels)).map { String(format:"%02x",$0) }.joined()
        return "image-v2\n\(prep)\nbudget=\(budget)\nwidth=\(rgb.width)\nheight=\(rgb.height)\nrgb_sha256=\(digest)"
    }

    @discardableResult
    public func commitShadowImage(model: Int64, input: RebuiltImage, vector: [Float]) throws -> Bool {
        guard vector.count==768, vector.allSatisfy(\.isFinite), abs(vector.reduce(Float(0)) { $0+$1*$1 }-1)<0.001 else {
            throw WorkerError.failed("invalid image shadow vector")
        }
        return try db.transaction {
            let fields=input.identity.components(separatedBy:"\n")
            guard fields.count==6,
                  let identity=try? Self.imageIdentity(prepared:input.prepared,prep:fields[1],budget:input.budget),
                  identity==input.identity, Self.contentRevision(identity)==input.contentRev else { return false }
            guard try imageSourceCurrent(segment:input.segment,snapshot:input.snapshot),
                  try storedRevision(input.segment)==input.contentRev else { return false }
            try db.run("""
                INSERT INTO vectors(model,segment,content_rev,modality,vec)
                SELECT ?,s.id,i.content_rev,'image',? FROM segments s JOIN embedding_inputs i ON i.segment=s.id
                WHERE s.id=? AND s.modality='image' AND i.content_rev=?
                ON CONFLICT(model,segment) DO UPDATE SET content_rev=excluded.content_rev,vec=excluded.vec
                """,[.int(model),.blob(Vectors.half(vector)),.int(input.segment),.blob(input.contentRev)])
            try db.run("DELETE FROM embedding_failures WHERE model=? AND segment=?",[.int(model),.int(input.segment)])
            return true
        }
    }

    public func segmentModality(_ id: Int64) throws -> String? {
        var value: String?
        try db.query("SELECT modality FROM segments WHERE id=?",[.int(id)]) { value=$0.text(0) }
        return value
    }

    public func carryShadowText(model: Int64, from key: String, sourceBuild: String, weights: String) throws -> Int {
        guard key=="coreai-eg2-text-v1" else { throw WorkerError.failed("unsupported carry source") }
        return try db.transaction {
            var source: Int64?
            try db.query("""
                SELECT old.id FROM embedding_models old JOIN embedding_models target ON target.id=?
                WHERE old.key=? AND old.build=? AND old.weights_sha256=? AND old.storage='vectors'
                AND target.key='coreai-eg2-v1' AND old.prompts=target.prompts AND old.preprocessing=target.preprocessing
                AND old.model=target.model AND old.dim=target.dim AND old.weights_sha256=target.weights_sha256
                """,[.int(model),.text(key),.text(sourceBuild),.text(weights)]) { source=$0.int(0) }
            guard let source else { throw WorkerError.failed("carry source model identity mismatch") }
            var rows: [(Int64,Data,Data)]=[]
            try db.query("""
                SELECT v.segment,v.content_rev,v.vec,i.input FROM vectors v
                JOIN segments s ON s.id=v.segment JOIN embedding_inputs i ON i.segment=s.id AND i.content_rev=v.content_rev
                WHERE v.model=? AND v.modality='text' AND s.modality='text' AND s.vec IS NOT NULL
                AND NOT EXISTS(SELECT 1 FROM vectors n WHERE n.model=? AND n.segment=s.id)
                """,[.int(source),.int(model)]) { row in
                    guard let rev=row.blob(1), let input=row.text(3), Self.contentRevision(input)==rev else {
                        throw WorkerError.failed("carry text content revision mismatch")
                    }
                    rows.append((row.int(0),rev,row.blob(2)!))
                }
            for (segment,rev,vec) in rows {
                try db.run("INSERT INTO vectors(model,segment,content_rev,modality,vec) VALUES(?,?,?,'text',?)",
                           [.int(model),.int(segment),.blob(rev),.blob(vec)])
                try db.run("DELETE FROM embedding_failures WHERE model=? AND segment=?",[.int(model),.int(segment)])
            }
            return rows.count
        }
    }

    func migrateImageShadowVectors() throws {
        try db.execute("""
            DROP TRIGGER shadow_coverage_delete;
            DROP TRIGGER shadow_coverage_insert;
            DROP TRIGGER shadow_segment_update;
            DROP TRIGGER shadow_file_update;
            DROP TRIGGER shadow_input_update;
            CREATE TABLE vectors_v8(
                model INTEGER NOT NULL REFERENCES embedding_models(id),
                segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                content_rev BLOB NOT NULL CHECK(length(content_rev)=32),
                modality TEXT NOT NULL CHECK(modality IN ('text','image')),
                vec BLOB NOT NULL CHECK(length(vec)=1536),PRIMARY KEY(model,segment),
                FOREIGN KEY(segment,content_rev) REFERENCES embedding_inputs(segment,content_rev) ON DELETE CASCADE
            ) WITHOUT ROWID;
            INSERT INTO vectors_v8 SELECT * FROM vectors;
            DROP TABLE vectors;
            ALTER TABLE vectors_v8 RENAME TO vectors;
            CREATE INDEX vectors_segment ON vectors(segment);
            CREATE TRIGGER shadow_segment_update AFTER UPDATE ON segments BEGIN
                DELETE FROM embedding_inputs WHERE segment=OLD.id;
                DELETE FROM vectors WHERE segment=OLD.id;
                DELETE FROM embedding_failures WHERE segment=OLD.id;
            END;
            CREATE TRIGGER shadow_file_update AFTER UPDATE OF path,kind,size,mtime,inode,device ON files BEGIN
                DELETE FROM embedding_inputs WHERE segment IN (SELECT id FROM segments WHERE file=OLD.id);
                DELETE FROM vectors WHERE segment IN (SELECT id FROM segments WHERE file=OLD.id);
                DELETE FROM embedding_failures WHERE segment IN (SELECT id FROM segments WHERE file=OLD.id);
            END;
            CREATE TRIGGER shadow_input_update BEFORE UPDATE ON embedding_inputs
            WHEN OLD.content_rev != NEW.content_rev OR CAST(OLD.input AS BLOB) != CAST(NEW.input AS BLOB) BEGIN
                DELETE FROM vectors WHERE segment=OLD.segment;
            END;
            CREATE TRIGGER shadow_coverage_delete AFTER DELETE ON vectors BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE id=OLD.model AND state IN ('complete','active');
            END;
            CREATE TRIGGER shadow_coverage_insert AFTER INSERT ON segments WHEN NEW.vec IS NOT NULL AND NEW.modality IN ('text','image') BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE storage='vectors' AND state IN ('complete','active')
                AND (NEW.modality='text' OR key='coreai-eg2-v1');
            END;
            PRAGMA user_version=8;
            """)
    }
}
