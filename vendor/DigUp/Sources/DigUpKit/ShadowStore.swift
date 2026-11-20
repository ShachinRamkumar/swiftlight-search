import CryptoKit
import Foundation

extension IndexStore {
    func migrateShadowVectors() throws {
        try db.execute("""
            CREATE TABLE embedding_models(
                id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, model TEXT, weights_sha256 TEXT,
                build TEXT, prompts TEXT, preprocessing TEXT, dim INTEGER,
                storage TEXT NOT NULL CHECK(storage IN ('legacy','vectors')),
                state TEXT NOT NULL CHECK(state IN ('building','complete','active','retired')),
                created_at REAL, completed_at REAL);
            CREATE TABLE embedding_inputs(
                segment INTEGER PRIMARY KEY REFERENCES segments(id) ON DELETE CASCADE,
                input TEXT NOT NULL, content_rev BLOB NOT NULL CHECK(length(content_rev)=32),
                UNIQUE(segment,content_rev));
            CREATE TABLE vectors(
                model INTEGER NOT NULL REFERENCES embedding_models(id),
                segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                content_rev BLOB NOT NULL CHECK(length(content_rev)=32),
                modality TEXT NOT NULL CHECK(modality='text'),
                vec BLOB NOT NULL CHECK(length(vec)=1536),
                PRIMARY KEY(model,segment),
                FOREIGN KEY(segment,content_rev) REFERENCES embedding_inputs(segment,content_rev) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE INDEX vectors_segment ON vectors(segment);
            CREATE TABLE embedding_failures(
                model INTEGER NOT NULL REFERENCES embedding_models(id),
                segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                reason TEXT NOT NULL, recorded_at REAL NOT NULL,
                PRIMARY KEY(model,segment)) WITHOUT ROWID;
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
                UPDATE embedding_models SET state='building', completed_at=NULL
                WHERE id=OLD.model AND state IN ('complete','active');
            END;
            CREATE TRIGGER shadow_coverage_insert AFTER INSERT ON segments WHEN NEW.vec IS NOT NULL AND NEW.modality='text' BEGIN
                UPDATE embedding_models SET state='building', completed_at=NULL
                WHERE storage='vectors' AND state IN ('complete','active');
            END;
            PRAGMA user_version=7;
            """)
        let source = try meta("vector_source") ?? "unrecorded"
        let parts = source.split(separator: " ", maxSplits: 1).map(String.init)
        try db.run("""
            INSERT INTO embedding_models(key,model,build,prompts,preprocessing,dim,storage,state,created_at)
            VALUES('llama-vectors1',?,?,?,?,768,'legacy','active',?)
            """, [.text(parts[0]), .text(parts.count > 1 ? parts[1] : "unrecorded"),
                    .text("Prompts.document/query"), .text(try meta("fingerprint") ?? "unrecorded"),
                    .double(Date().timeIntervalSince1970)])
    }

    public static func contentRevision(_ input: String) -> Data { Data(SHA256.hash(data: Data(input.utf8))) }

    public func registerShadow(key: String, info: WorkerInfo, weightsSHA256: String) throws -> Int64 {
        guard ["coreai-eg2-text-v1","coreai-eg2-v1"].contains(key), info.dim == 768, info.runtime == "coreai-ane" else {
            throw WorkerError.failed("unsupported shadow model identity: \(key)")
        }
        var id: Int64?
        try db.query("SELECT id, build, weights_sha256, storage FROM embedding_models WHERE key=?", [.text(key)]) { row in
            guard row.text(1) == info.revision, row.text(2) == weightsSHA256, row.text(3) == "vectors" else {
                throw WorkerError.failed("shadow model identity mismatch: \(key)")
            }
            id = row.int(0)
        }
        if let id { return id }
        try db.run("""
            INSERT INTO embedding_models(key,model,weights_sha256,build,prompts,preprocessing,dim,storage,state,created_at)
            VALUES(?,?,?,?,?,?,768,'vectors','building',?)
            """, [.text(key), .text(info.model), .text(weightsSHA256), .text(info.revision),
                    .text("title: {title-or-none} | text: {text}"), .text("p3a-bf16-fp32scale-shipped-rope-v1;tokenizers-0.23.2"),
                    .double(Date().timeIntervalSince1970)])
        return db.lastInsertID
    }

    public func shadowCounts(model: Int64) throws -> (done: Int, eligible: Int, failed: Int) {
        let modalities=try shadowModalitiesSQL(model:model)
        var eligible=0, done=0, failed=0
        try db.query("SELECT COUNT(*) FROM segments WHERE modality IN (\(modalities))") { eligible=Int($0.int(0)) }
        try db.query("""
            SELECT COUNT(*) FROM vectors v JOIN segments s ON s.id=v.segment JOIN embedding_inputs i ON i.segment=s.id
            WHERE v.model=? AND s.modality IN (\(modalities)) AND v.modality=s.modality AND v.content_rev=i.content_rev
            """, [.int(model)]) { done=Int($0.int(0)) }
        try db.query("SELECT COUNT(*) FROM embedding_failures WHERE model=?", [.int(model)]) { failed=Int($0.int(0)) }
        return (done,eligible,failed)
    }

    func shadowModalitiesSQL(model: Int64) throws -> String {
        var key: String?
        try db.query("SELECT key FROM embedding_models WHERE id=?",[.int(model)]) { key=$0.text(0) }
        return key == "coreai-eg2-v1" ? "'text','image','audio','video'" : "'text'"
    }

    public func recordShadowFailure(model: Int64, segment: Int64, reason: String) throws {
        let modalities=try shadowModalitiesSQL(model:model)
        try db.run("""
            INSERT INTO embedding_failures(model,segment,reason,recorded_at)
            SELECT ?,id,?,? FROM segments WHERE id=? AND modality IN (\(modalities))
            ON CONFLICT(model,segment) DO UPDATE SET reason=excluded.reason, recorded_at=excluded.recorded_at
            """, [.int(model),.text(reason),.double(Date().timeIntervalSince1970),.int(segment)])
    }

    @discardableResult
    public func commitShadow(model: Int64, input: RebuiltInput, vector: [Float]) throws -> Bool {
        guard vector.count == 768, vector.allSatisfy(\.isFinite),
              abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.001 else {
            throw WorkerError.failed("invalid or non-normalized shadow vector")
        }
        return try db.transaction {
            guard try inputIsCurrent(input), try storedRevision(input.segment) == input.contentRev else { return false }
            try db.run("""
                INSERT INTO vectors(model,segment,content_rev,modality,vec)
                SELECT ?,s.id,i.content_rev,'text',? FROM segments s JOIN embedding_inputs i ON i.segment=s.id
                WHERE s.id=? AND s.modality='text' AND i.content_rev=?
                ON CONFLICT(model,segment) DO UPDATE SET content_rev=excluded.content_rev, vec=excluded.vec
                """, [.int(model),.blob(Vectors.half(vector)),.int(input.segment),.blob(input.contentRev)])
            try db.run("DELETE FROM embedding_failures WHERE model=? AND segment=?", [.int(model),.int(input.segment)])
            return true
        }
    }

    public func finishShadowIfCovered(model: Int64) throws -> Bool {
        try db.transaction {
            let counts = try activationCoverage(model: model)
            guard counts.done + counts.explained == counts.eligible, counts.explained <= counts.legacyFailures else { return false }
            var state: String?
            try db.query("SELECT state FROM embedding_models WHERE id=?", [.int(model)]) { state = $0.text(0) }
            if state != "active" && state != "complete" {
                try db.run("UPDATE embedding_models SET state='complete',completed_at=? WHERE id=?",
                           [.double(Date().timeIntervalSince1970),.int(model)])
                try setMeta("embedding_generation", String(try modelGeneration + 1))
            }
            return true
        }
    }

    func storedRevision(_ segment: Int64) throws -> Data? {
        var rev: Data?
        try db.query("SELECT content_rev FROM embedding_inputs WHERE segment=?", [.int(segment)]) { rev=$0.blob(0) }
        return rev
    }
}
