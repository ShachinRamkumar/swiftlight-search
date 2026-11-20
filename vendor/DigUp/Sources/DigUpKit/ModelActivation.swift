import Foundation
import Darwin

extension IndexStore {
    public var modelGeneration: Int64 {
        get throws { Int64(try meta("embedding_generation") ?? "0") ?? 0 }
    }

    func migrateModelActivation() throws {
        try db.execute("""
            INSERT OR IGNORE INTO meta VALUES('embedding_generation','0');
            DROP TRIGGER shadow_coverage_delete;
            DROP TRIGGER shadow_coverage_insert;
            DROP TRIGGER shadow_clip_insert;
            CREATE TRIGGER shadow_coverage_delete AFTER DELETE ON vectors BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE id=OLD.model AND state='complete';
            END;
            CREATE TRIGGER shadow_coverage_insert AFTER INSERT ON segments WHEN NEW.modality!='none' BEGIN
                UPDATE embedding_models SET state='building',completed_at=NULL WHERE storage='vectors' AND state='complete';
            END;
            PRAGMA user_version=11;
            """)
        for table in ["segments", "vectors", "embedding_inputs", "embedding_failures"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try db.execute("""
                    CREATE TRIGGER generation_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN
                        UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='embedding_generation';
                    END;
                    """)
            }
        }
    }

    func migrateSourceGenerations() throws {
        try db.execute("""
            CREATE TRIGGER generation_files_source AFTER UPDATE OF path,kind,size,mtime,inode,device ON files BEGIN
                UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='embedding_generation';
            END;
            CREATE TRIGGER generation_files_insert AFTER INSERT ON files BEGIN
                UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='embedding_generation';
            END;
            CREATE TRIGGER generation_files_delete AFTER DELETE ON files BEGIN
                UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='embedding_generation';
            END;
            PRAGMA user_version=12;
            """)
    }

    public func useCoreAIModel(key: String, info: WorkerInfo, weights: String,
                               audioIdentity: String?, videoIdentity: String?) throws {
        indexingModel = try registerShadow(key: key, info: info, weightsSHA256: weights)
        if let audioIdentity { try registerShadowAudio(model: indexingModel!, identity: audioIdentity) }
        if let videoIdentity { try registerShadowVideo(model: indexingModel!, identity: videoIdentity) }
        var files = 0
        try db.query("SELECT COUNT(*) FROM files") { files = Int($0.int(0)) }
        if files == 0, try meta("active_embedding_model") == nil, try meta("vector_source") == nil {
            try setMeta("first_run_embedding_model", key)
        }
    }

    func beginVectorJob() throws {
        try checkIndexingActivation()
        indexingGeneration = try modelGeneration
    }

    private func checkIndexingActivation() throws {
        guard indexingActivationAtStart == (try meta("active_embedding_model")) else {
            throw WorkerError.failed("active embedding model changed during indexing; restart the service")
        }
    }

    func checkVectorJob(file: Int64) throws {
        try checkIndexingActivation()
        guard indexingModel != nil else { return }
        guard indexingGeneration == (try modelGeneration) else {
            throw WorkerError.failed("model generation changed during indexing; retry the file")
        }
        if let source = indexingFiles[file] {
            var st = Darwin.stat()
            guard stat(source.path, &st) == 0, st.st_size == source.size,
                  UInt64(st.st_ino) == source.inode,
                  Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec)/1e9 == source.mtime else {
                throw WorkerError.failed("source_changed during incremental indexing: \(source.path)")
            }
        }
    }

    /// Coverage always joins the current segment and its retained input revision.
    public func activationCoverage(model: Int64) throws -> (done: Int, eligible: Int, explained: Int, legacyFailures: Int) {
        let modalities = try shadowModalitiesSQL(model: model)
        var done = 0, eligible = 0, explained = 0, legacyFailures = 0, unexplained = 0
        try db.query("SELECT COUNT(*) FROM segments WHERE modality IN (\(modalities))") { eligible = Int($0.int(0)) }
        try db.query("""
            SELECT COUNT(*) FROM vectors v JOIN segments s ON s.id=v.segment
            JOIN embedding_inputs i ON i.segment=s.id AND i.content_rev=v.content_rev
            WHERE v.model=? AND v.modality=s.modality AND s.modality IN (\(modalities))
            """, [.int(model)]) { done = Int($0.int(0)) }
        try db.query("""
            SELECT COUNT(*), SUM(CASE WHEN e.reason IN ('source_changed','source_unreproducible') THEN 1 ELSE 0 END)
            FROM embedding_failures e JOIN segments s ON s.id=e.segment
            WHERE e.model=? AND s.modality IN (\(modalities))
            AND NOT EXISTS(SELECT 1 FROM vectors v JOIN embedding_inputs i ON i.segment=v.segment AND i.content_rev=v.content_rev
                           WHERE v.model=e.model AND v.segment=e.segment AND v.modality=s.modality)
            """, [.int(model)]) { unexplained = Int($0.int(0) - $0.int(1)); explained = Int($0.int(1)) }
        try db.query("""
            SELECT COUNT(*) FROM embedding_failures e JOIN embedding_models m ON m.id=e.model
            JOIN segments s ON s.id=e.segment WHERE m.storage='legacy' AND s.modality IN (\(modalities))
            """) { legacyFailures = Int($0.int(0)) }
        guard unexplained == 0 else { throw WorkerError.failed("activation refused: \(unexplained) unexplained failures") }
        return (done, eligible, explained, legacyFailures)
    }

    @discardableResult
    public func activateModel(key: String, rollback: Bool = false) throws -> Int64 {
        try db.transaction {
            var target: (Int64, String)?
            try db.query("SELECT id,storage FROM embedding_models WHERE key=?", [.text(key)]) { target = ($0.int(0), $0.text(1)!) }
            guard let (id, storage) = target, rollback == (storage == "legacy") else {
                throw WorkerError.failed("invalid activation/rollback model: \(key)")
            }
            if storage == "vectors" {
                let c = try activationCoverage(model: id)
                guard c.done + c.explained == c.eligible, c.explained <= c.legacyFailures else {
                    throw WorkerError.failed("activation refused: done=\(c.done) eligible=\(c.eligible) explained=\(c.explained) legacy_failures=\(c.legacyFailures)")
                }
                try db.run("UPDATE embedding_models SET state='complete',completed_at=? WHERE id=?", [.double(Date().timeIntervalSince1970), .int(id)])
            }
            try db.run("UPDATE embedding_models SET state='retired' WHERE state='active' AND id!=?", [.int(id)])
            try db.run("UPDATE embedding_models SET state='active' WHERE id=?", [.int(id)])
            try setMeta("active_embedding_model", key)
            let generation = try modelGeneration + 1
            try setMeta("embedding_generation", String(generation))
            return generation
        }
    }
}
