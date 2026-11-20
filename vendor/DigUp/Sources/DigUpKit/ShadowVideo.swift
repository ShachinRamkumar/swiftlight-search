import CryptoKit
import Darwin
import Foundation

public struct RebuiltVideo {
    public let segment: Int64
    public let path: String
    public let range: VideoClipRange
    public let frames: [RGBImage]
    public let snapshot: String
    public let identity: String
    public let contentRev: Data
}

extension IndexStore {
    private static let videoColumns = """
        SELECT f.path,s.loc,s.loc_end,f.size,f.mtime,f.inode,
        json_array(s.file,s.kind,s.modality,s.loc,s.loc_end,f.path,f.size,f.mtime,f.inode,f.device)
        FROM segments s JOIN files f ON f.id=s.file WHERE s.id=? AND s.kind='clip' AND s.modality='video' AND s.vec IS NULL
        """
    public func videoSourceCurrent(segment: Int64, snapshot: String? = nil) throws -> Bool {
        var current=false
        try db.query(Self.videoColumns,[.int(segment)]) { r in
            var st=Darwin.stat()
            guard stat(r.text(0)!,&st)==0 else { return }
            let mtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
            current=st.st_size==r.int(3) && mtime==r.double(4) && UInt64(st.st_ino)==UInt64(bitPattern:r.int(5)) && (snapshot == nil || snapshot==r.text(6))
        }
        return current
    }
    public func registerShadowVideo(model: Int64, identity: String) throws {
        guard identity.count==64,identity.allSatisfy({$0.isHexDigit}) else { throw WorkerError.failed("invalid video runtime identity") }
        try db.transaction {
            var old: String?
            try db.query("SELECT identity FROM embedding_modality_identities WHERE model=? AND modality='video'",[.int(model)]) { old=$0.text(0) }
            guard old == nil || old==identity else { throw WorkerError.failed("video runtime identity mismatch") }
            try db.run("INSERT OR IGNORE INTO embedding_modality_identities VALUES(?,'video',?)",[.int(model),.text(identity)])
        }
    }
    public func ensureVideoClips() throws {
        var files: [(Int64,String)] = []
        try db.query("SELECT id,path FROM files WHERE kind='video' AND state IN ('done','partial') ORDER BY id") { files.append(($0.int(0),$0.text(1)!)) }
        for (file,path) in files {
            let ranges=try VideoDecoder.schedule(duration:VideoDecoder.duration(URL(fileURLWithPath:path)))
            try db.transaction {
                for range in ranges {
                    try db.run("INSERT INTO segments(file,kind,modality,loc,loc_end) SELECT ?,'clip','video',?,? WHERE NOT EXISTS(SELECT 1 FROM segments WHERE file=? AND kind='clip' AND loc=? AND loc_end=?)",[.int(file),.double(range.start),.double(range.end),.int(file),.double(range.start),.double(range.end)])
                }
            }
        }
    }
    public func rebuildVideo(segment: Int64) throws -> RebuiltVideo {
        var fields: (String,Double,Double,String)?
        try db.query(Self.videoColumns,[.int(segment)]) { fields=($0.text(0)!,$0.double(1),$0.double(2),$0.text(6)!) }
        guard let (path,start,end,snapshot)=fields,try videoSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
        let range=VideoClipRange(start:start,end:end)
        let frames=try VideoDecoder.decode(URL(fileURLWithPath:path),range:range)
        let identity=Self.videoIdentity(frames,range:range),rev=Self.contentRevision(identity)
        try db.transaction {
            guard try videoSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
            try db.run("INSERT INTO embedding_inputs VALUES(?,?,?) ON CONFLICT(segment) DO UPDATE SET input=excluded.input,content_rev=excluded.content_rev WHERE embedding_inputs.content_rev!=excluded.content_rev",[.int(segment),.text(identity),.blob(rev)])
        }
        return RebuiltVideo(segment:segment,path:path,range:range,frames:frames,snapshot:snapshot,identity:identity,contentRev:rev)
    }
    static func videoIdentity(_ frames: [RGBImage], range: VideoClipRange) -> String {
        let hashes=frames.map { f in "\(f.width)x\(f.height):"+SHA256.hash(data:Data(f.pixels)).map { String(format:"%02x",$0) }.joined() }
        return "video-v1\nAVFoundation-exact-native1fps:budget140:framing-video:clip14-hop10\nrange=\(range.start)-\(range.end)\n"+hashes.joined(separator:"\n")
    }
    @discardableResult
    public func commitShadowVideo(model: Int64, input: RebuiltVideo, vector: [Float]) throws -> Bool {
        guard vector.count==768,vector.allSatisfy(\.isFinite),abs(vector.reduce(Float(0)) {$0+$1*$1}-1)<0.001 else { throw WorkerError.failed("invalid video vector") }
        return try db.transaction {
            guard Self.videoIdentity(input.frames,range:input.range)==input.identity,try videoSourceCurrent(segment:input.segment,snapshot:input.snapshot),try storedRevision(input.segment)==input.contentRev else { return false }
            var bound=false
            try db.query("SELECT 1 FROM embedding_modality_identities WHERE model=? AND modality='video'",[.int(model)]) { _ in bound=true }
            guard bound else { throw WorkerError.failed("unregistered video identity") }
            try db.run("INSERT INTO vectors VALUES(?,?,?,'video',?) ON CONFLICT(model,segment) DO UPDATE SET content_rev=excluded.content_rev,vec=excluded.vec",[.int(model),.int(input.segment),.blob(input.contentRev),.blob(Vectors.half(vector))])
            try db.run("DELETE FROM embedding_failures WHERE model=? AND segment=?",[.int(model),.int(input.segment)])
            return true
        }
    }
    func migrateVideoShadowVectors() throws {
        try db.execute("""
            DROP TRIGGER shadow_coverage_delete;
            CREATE TABLE vectors_v10(model INTEGER NOT NULL REFERENCES embedding_models(id),segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                content_rev BLOB NOT NULL CHECK(length(content_rev)=32),modality TEXT NOT NULL CHECK(modality IN ('text','image','audio','video')),
                vec BLOB NOT NULL CHECK(length(vec)=1536),PRIMARY KEY(model,segment),
                FOREIGN KEY(segment,content_rev) REFERENCES embedding_inputs(segment,content_rev) ON DELETE CASCADE) WITHOUT ROWID;
            INSERT INTO vectors_v10 SELECT * FROM vectors;
            DROP TABLE vectors;
            ALTER TABLE vectors_v10 RENAME TO vectors;
            CREATE INDEX vectors_segment ON vectors(segment);
            CREATE TRIGGER shadow_coverage_delete AFTER DELETE ON vectors BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE id=OLD.model AND state IN ('complete','active');
            END;
            CREATE TABLE modality_v10(model INTEGER NOT NULL REFERENCES embedding_models(id) ON DELETE CASCADE,
                modality TEXT NOT NULL CHECK(modality IN ('audio','video')),identity TEXT NOT NULL CHECK(length(identity)=64),PRIMARY KEY(model,modality)) WITHOUT ROWID;
            INSERT INTO modality_v10 SELECT * FROM embedding_modality_identities;
            DROP TABLE embedding_modality_identities;
            ALTER TABLE modality_v10 RENAME TO embedding_modality_identities;
            CREATE TRIGGER shadow_clip_insert AFTER INSERT ON segments WHEN NEW.kind='clip' AND NEW.modality='video' BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE key='coreai-eg2-v1' AND state IN ('complete','active');
            END;
            PRAGMA user_version=10;
            """)
    }
}
