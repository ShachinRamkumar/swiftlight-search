use rusqlite::{Connection, OpenFlags, OptionalExtension};
use std::{error::Error, path::Path, time::Duration};

const MIGRATION: &str = "storage_compaction_v1";

fn compact(db: &mut Connection) -> Result<bool, Box<dyn Error>> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != 12 {
        return Err("compaction requires DigUp schema 12".into());
    }
    let state: Option<String> = db
        .query_row("SELECT value FROM meta WHERE key=?1", [MIGRATION], |r| {
            r.get(0)
        })
        .optional()?;
    if state.as_deref() == Some("complete") {
        return Ok(false);
    }
    // A failed optimize rolls back with its marker. Vacuum can then be retried
    // after interruption without requiring another FTS merge.
    if state.as_deref() != Some("optimized") {
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("INSERT INTO fts(fts) VALUES('optimize')", [])?;
        tx.execute(
            "INSERT INTO meta(key,value) VALUES(?1,'optimized') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [MIGRATION],
        )?;
        tx.commit()?;
    }
    // Preserve page size, tokenizer, content, all vectors and the schema version.
    db.execute_batch("VACUUM;")?;
    db.execute("UPDATE meta SET value='complete' WHERE key=?1", [MIGRATION])?;
    Ok(true)
}

fn run(path: &Path) -> Result<(), Box<dyn Error>> {
    let mut db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(Duration::from_millis(250))?;
    db.execute_batch("PRAGMA cache_size=-4096; PRAGMA temp_store=FILE;")?;
    let before = std::fs::metadata(path)?.len();
    let changed = compact(&mut db)?;
    // PASSIVE never waits for readers or forces their transactions to end.
    let (busy, frames, checkpointed): (i64, i64, i64) =
        db.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?;
    println!(
        "changed={changed} database_bytes_before={before} database_bytes_after={} checkpoint_busy={busy} wal_frames={frames} checkpointed_frames={checkpointed}",
        std::fs::metadata(path)?.len()
    );
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1);
    let path = args
        .next()
        .ok_or("usage: compact-index /explicit/path/index.sqlite")?;
    if args.next().is_some() {
        return Err("usage: compact-index /explicit/path/index.sqlite".into());
    }
    run(Path::new(&path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(
            "PRAGMA user_version=12;
             CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);
             INSERT INTO meta VALUES('embedding_generation','7'),('active_embedding_model','coreai-eg2-v1');
             CREATE TABLE vectors(id INTEGER PRIMARY KEY,vec BLOB);
             INSERT INTO vectors VALUES(1,X'00010002FFFE');
             CREATE VIRTUAL TABLE fts USING fts5(name,body,original UNINDEXED,tokenize='porter unicode61');
             INSERT INTO fts(rowid,name,body) VALUES(1,'running','runner runners'),(2,'run','running');
             INSERT INTO fts(rowid,name,body) VALUES(3,'obsolete','deleted');
             DELETE FROM fts WHERE rowid=3;",
        ).unwrap();
        db
    }

    fn hits(db: &Connection) -> Vec<(i64, f64)> {
        db.prepare("SELECT rowid,bm25(fts,4.0,1.0) FROM fts WHERE fts MATCH '\"run\"*' ORDER BY bm25(fts,4.0,1.0)")
            .unwrap().query_map([], |r| Ok((r.get(0)?,r.get(1)?))).unwrap()
            .collect::<rusqlite::Result<_>>().unwrap()
    }

    #[test]
    fn migration_preserves_ranking_vectors_and_generation_and_is_idempotent() {
        let mut db = fixture();
        let before = hits(&db);
        let bytes: Vec<u8> = db
            .query_row("SELECT vec FROM vectors", [], |r| r.get(0))
            .unwrap();
        assert!(compact(&mut db).unwrap());
        assert_eq!(hits(&db), before);
        assert_eq!(
            db.query_row::<Vec<u8>, _, _>("SELECT vec FROM vectors", [], |r| r.get(0))
                .unwrap(),
            bytes
        );
        assert_eq!(
            db.query_row::<String, _, _>(
                "SELECT value FROM meta WHERE key='embedding_generation'",
                [],
                |r| r.get(0)
            )
            .unwrap(),
            "7"
        );
        assert!(!compact(&mut db).unwrap());
    }

    #[test]
    fn resumes_after_optimize_was_committed() {
        let mut db = fixture();
        db.execute("INSERT INTO meta VALUES(?1,'optimized')", [MIGRATION])
            .unwrap();
        let before = hits(&db);
        assert!(compact(&mut db).unwrap());
        assert_eq!(hits(&db), before);
        assert!(!compact(&mut db).unwrap());
    }

    #[test]
    fn failed_optimize_does_not_publish_a_migration_marker() {
        let mut db = fixture();
        db.execute_batch("DROP TABLE fts").unwrap();
        assert!(compact(&mut db).is_err());
        assert_eq!(
            db.query_row::<i64, _, _>("SELECT count(*) FROM meta WHERE key=?1", [MIGRATION], |r| r
                .get(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn rejects_other_schemas_before_writing() {
        let mut db = fixture();
        db.execute_batch("PRAGMA user_version=13").unwrap();
        assert!(compact(&mut db).is_err());
        assert_eq!(
            db.query_row::<i64, _, _>("SELECT count(*) FROM meta WHERE key=?1", [MIGRATION], |r| r
                .get(0))
                .unwrap(),
            0
        );
    }
}
