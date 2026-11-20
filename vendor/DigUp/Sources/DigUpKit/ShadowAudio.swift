import CryptoKit
import Darwin
import Foundation

public struct RebuiltAudio {
    public let segment: Int64
    public let path: String
    public let prepared: URL
    public let start: Double
    public let end: Double
    public let snapshot: String
    public let identity: String
    public let contentRev: Data
}

extension IndexStore {
    private static let audioPrep = "indexer-avfoundation-pcm16le-16000mono-v1:window30:hop25:minimum2:rms0.003;eg2-audio-spec-sha256=56c3d80b79561e71fdb50a77aecfba926e0f43b920a1a5545b461c0cbdc8896e"
    private static let audioColumns = """
        SELECT f.path,s.loc,s.loc_end,f.size,f.mtime,f.inode,
        json_array(s.file,s.kind,s.modality,s.loc,s.loc_end,s.excerpt,hex(s.vec),f.path,f.kind,f.size,f.mtime,f.inode,f.device),json_array(f.path,f.size,f.mtime,f.inode,f.device)
        FROM segments s JOIN files f ON f.id=s.file
        WHERE s.id=? AND s.modality='audio' AND s.kind='audio'
        """
    public func audioSourceCurrent(segment: Int64, snapshot: String? = nil) throws -> Bool {
        var current=false
        try db.query(Self.audioColumns,[.int(segment)]) { row in
            var st=Darwin.stat()
            guard stat(row.text(0)!,&st)==0 else { return }
            let mtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
            current=st.st_size==row.int(3) && mtime==row.double(4) && UInt64(st.st_ino)==UInt64(bitPattern:row.int(5))
                && (snapshot == nil || snapshot == row.text(6))
        }
        return current
    }
    public func rebuildAudio(segment: Int64, scratch: URL) throws -> RebuiltAudio {
        guard try meta("fingerprint")?.hasSuffix("audio30.0/25.0s") == true else { throw WorkerError.failed("unsupported index audio window options") }
        var fields: (String,Double,Double,String,String)?
        try db.query(Self.audioColumns,[.int(segment)]) { fields=($0.text(0)!,$0.double(1),$0.double(2),$0.text(6)!,$0.text(7)!) }
        guard let (path,start,end,snapshot,source)=fields,try audioSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
        let folder=scratch.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            if shadowAudioPCM?.source != source {
                shadowAudioPCM = nil
                let samples=try runBlocking { try await ShadowAudioDecoder.decode(URL(fileURLWithPath:path)) }
                guard try audioSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed during audio decode: \(segment)") }
                shadowAudioPCM=(source,samples)
            }
            let samples=shadowAudioPCM!.samples
            let first=Int((start*16000).rounded()),last=Int((end*16000).rounded())
            guard first>=0,last>first,last<=samples.count else { throw WorkerError.failed("audio range exceeds decoded full track: \(segment), need \(last), have \(samples.count)") }
            let prepared=folder.appendingPathComponent("window.wav")
            try AudioExtractor.writeWAV(samples[first..<last],to:prepared)
            guard try audioSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed during audio preparation: \(segment)") }
            let identity=try Self.audioIdentity(prepared:prepared,start:start,end:end),rev=Self.contentRevision(identity)
            try db.transaction {
                guard try audioSourceCurrent(segment:segment,snapshot:snapshot) else { throw WorkerError.failed("source_changed: \(segment)") }
                try db.run("INSERT INTO embedding_inputs(segment,input,content_rev) VALUES(?,?,?) ON CONFLICT(segment) DO UPDATE SET input=excluded.input,content_rev=excluded.content_rev WHERE embedding_inputs.content_rev!=excluded.content_rev",[.int(segment),.text(identity),.blob(rev)])
            }
            return RebuiltAudio(segment:segment,path:path,prepared:prepared,start:start,end:end,snapshot:snapshot,identity:identity,contentRev:rev)
        } catch { try? FileManager.default.removeItem(at:folder);throw error }
    }
    static func audioIdentity(prepared: URL, start: Double, end: Double) throws -> String {
        let pcm=try PCM16.decode(prepared)
        let digest=pcm.withUnsafeBytes { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() }
        return "audio-v1\n\(audioPrep)\nwindow=\(start)-\(end)\nsamples=\(pcm.count)\npcm_sha256=\(digest)"
    }
    @discardableResult
    public func commitShadowAudio(model: Int64, input: RebuiltAudio, vector: [Float]) throws -> Bool {
        guard vector.count==768,vector.allSatisfy(\.isFinite),abs(vector.reduce(Float(0)) { $0+$1*$1 }-1)<0.001 else { throw WorkerError.failed("invalid audio shadow vector") }
        return try db.transaction {
            guard let identity=try? Self.audioIdentity(prepared:input.prepared,start:input.start,end:input.end),identity==input.identity,
                  Self.contentRevision(identity)==input.contentRev,try audioSourceCurrent(segment:input.segment,snapshot:input.snapshot),
                  try storedRevision(input.segment)==input.contentRev else { return false }
            var bound=false
            try db.query("SELECT 1 FROM embedding_modality_identities WHERE model=? AND modality='audio'",[.int(model)]) { _ in bound=true }
            guard bound else { throw WorkerError.failed("audio runtime identity is not registered") }
            try db.run("""
                INSERT INTO vectors(model,segment,content_rev,modality,vec)
                SELECT ?,s.id,i.content_rev,'audio',? FROM segments s JOIN embedding_inputs i ON i.segment=s.id
                WHERE s.id=? AND s.modality='audio' AND i.content_rev=?
                ON CONFLICT(model,segment) DO UPDATE SET content_rev=excluded.content_rev,vec=excluded.vec
                """,[.int(model),.blob(Vectors.half(vector)),.int(input.segment),.blob(input.contentRev)])
            try db.run("DELETE FROM embedding_failures WHERE model=? AND segment=?",[.int(model),.int(input.segment)])
            return true
        }
    }
    public func registerShadowAudio(model: Int64, identity: String) throws {
        guard identity.count==64,identity.allSatisfy({ $0.isHexDigit }) else { throw WorkerError.failed("invalid audio runtime identity") }
        try db.transaction {
            var old: String?
            try db.query("SELECT identity FROM embedding_modality_identities WHERE model=? AND modality='audio'",[.int(model)]) { old=$0.text(0) }
            guard old == nil || old == identity else { throw WorkerError.failed("audio runtime identity mismatch; existing text/image rows retained") }
            try db.run("INSERT OR IGNORE INTO embedding_modality_identities(model,modality,identity) VALUES(?,'audio',?)",[.int(model),.text(identity)])
        }
    }
}

extension IndexStore {
    func migrateAudioShadowVectors() throws {
        try db.execute("""
            DROP TRIGGER shadow_coverage_delete;
            DROP TRIGGER shadow_coverage_insert;
            DROP TRIGGER shadow_segment_update;
            DROP TRIGGER shadow_file_update;
            DROP TRIGGER shadow_input_update;
            CREATE TABLE vectors_v9(
                model INTEGER NOT NULL REFERENCES embedding_models(id),
                segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                content_rev BLOB NOT NULL CHECK(length(content_rev)=32),
                modality TEXT NOT NULL CHECK(modality IN ('text','image','audio')),
                vec BLOB NOT NULL CHECK(length(vec)=1536),PRIMARY KEY(model,segment),
                FOREIGN KEY(segment,content_rev) REFERENCES embedding_inputs(segment,content_rev) ON DELETE CASCADE
            ) WITHOUT ROWID;
            INSERT INTO vectors_v9 SELECT * FROM vectors;
            DROP TABLE vectors;
            ALTER TABLE vectors_v9 RENAME TO vectors;
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
            CREATE TRIGGER shadow_coverage_insert AFTER INSERT ON segments WHEN NEW.vec IS NOT NULL AND NEW.modality IN ('text','image','audio') BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE storage='vectors' AND state IN ('complete','active')
                AND (NEW.modality='text' OR key='coreai-eg2-v1');
            END;
            CREATE TABLE embedding_modality_identities(model INTEGER NOT NULL REFERENCES embedding_models(id) ON DELETE CASCADE,modality TEXT NOT NULL CHECK(modality='audio'),identity TEXT NOT NULL CHECK(length(identity)=64),PRIMARY KEY(model,modality)) WITHOUT ROWID;
            UPDATE embedding_models SET state='building',completed_at=NULL
            WHERE key='coreai-eg2-v1' AND storage='vectors' AND state IN ('complete','active')
            AND EXISTS(SELECT 1 FROM segments WHERE vec IS NOT NULL AND modality='audio');
            PRAGMA user_version=9;
            """)
    }
}
