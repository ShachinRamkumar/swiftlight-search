use crate::{Config, Hit};
use base64::{Engine, engine::general_purpose::STANDARD};
use half::f16;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver, TryRecvError},
    time::{Duration, Instant},
};

const DIM: usize = 768;

/// Words nearly every document holds: as keywords they match everything (and "of"* expands to "office", "offer"...).
const STOP_WORDS: &[&str] = &[
    "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "i",
    "is", "are", "was", "it", "its", "by", "from", "about", "this", "that", "what", "where",
    "which", "how", "do", "does", "did", "be", "as", "into", "so", "not", "no", "any", "some",
    "all", "find", "show",
];
/// A keyword query of this many words or more may match a file missing some of them (`Keyword`).
const RELAXED_FROM: usize = 3;
/// How much of such a query a file's words must hold to count at all: missing words make it a weak match, shown only
/// beside a meaning match that passed its gate. (At 0.6, "tax return 2019" brought tax notes holding two of its words.)
const RELAXED_COVERAGE: f64 = 0.75;
/// The same for queries of five words or more, which describe a file in other words than it uses.
const LONG_COVERAGE: f64 = 0.6;

/// The rank a content hit (meaning or words) starts from: descriptive queries ("tidal turbines generate power") are
/// asked of content more than names, so their content matches sit higher. The file's place lowers it a little.
pub fn content_base(config: &Config, query: &str, path: &str, mtime: f64) -> f64 {
    let band = if query.split_whitespace().count() >= 3 {
        300.
    } else {
        270.
    };
    band + 0.15 * buried(config, path) + recent(mtime)
}
/// A small lift for files changed lately (a tenth to a third of a deviation): of two equally good matches, last
/// month's waiver confirmation over last year's.
fn recent(mtime: f64) -> f64 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0., |d| d.as_secs_f64());
    let days = (now - mtime).max(0.) / 86400.;
    if days < 30. {
        1.2
    } else if days < 365. {
        0.4
    } else {
        0.
    }
}

/// Content keyword search over the helper's FTS table. The read-only connection is kept between
/// keystrokes; WAL readers see the indexer's commits without reopening.
#[derive(Default)]
pub struct Keyword {
    db: Option<Connection>,
}
impl Keyword {
    /// `current` is asked as SQLite works (every few thousand steps): a query typed past is abandoned mid-scan.
    pub fn search(
        &mut self,
        config: &Config,
        query: &str,
        current: impl Fn() -> bool + Send + 'static,
    ) -> Result<Vec<Hit>, String> {
        let result = self.run(config, query, current);
        if let Some(db) = &self.db {
            let _ = db.progress_handler(0, None::<fn() -> bool>);
        }
        match result {
            Err(e) if e.contains("interrupt") => Ok(vec![]),
            Err(e) => {
                self.db = None;
                Err(e)
            }
            ok => ok,
        }
    }
    fn run(
        &mut self,
        config: &Config,
        query: &str,
        current: impl Fn() -> bool + Send + 'static,
    ) -> Result<Vec<Hit>, String> {
        if self.db.is_none() {
            let path = config.index.join("index.sqlite");
            if !path.exists() {
                return Ok(vec![]);
            }
            let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| e.to_string())?;
            db.busy_timeout(Duration::from_millis(150))
                .map_err(|e| e.to_string())?;
            self.db = Some(db);
        }
        let db = self.db.as_ref().unwrap();
        db.progress_handler(2000, Some(move || !current()))
            .map_err(|e| e.to_string())?;
        keyword(db, config, query)
    }
}

/// The words of `query` worth looking for: no stop words (unless that leaves none), each once, at most eight.
fn keywords(query: &str) -> Vec<String> {
    let mut words: Vec<String> = vec![];
    for word in query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
    {
        let word = word.to_lowercase();
        if !words.contains(&word) {
            words.push(word);
        }
    }
    let content: Vec<String> = words
        .iter()
        .filter(|w| !STOP_WORDS.contains(&w.as_str()))
        .cloned()
        .collect();
    let mut words = if content.is_empty() { words } else { content };
    words.truncate(8);
    words
}
/// An FTS5 term: a prefix for words of three letters or more ("tur" while "turbines" is typed), the exact word for
/// shorter ones. A one- or two-letter prefix expands to thousands of index terms: "s"* took 1.7 s.
fn term(word: &str) -> String {
    if word.chars().count() >= 3 {
        format!("\"{word}\"*")
    } else {
        format!("\"{word}\"")
    }
}

fn keyword(db: &Connection, config: &Config, query: &str) -> Result<Vec<Hit>, String> {
    let words = keywords(query);
    if words.is_empty() {
        return Ok(vec![]);
    }
    let terms: Vec<String> = words.iter().map(|w| term(w)).collect();
    // Up to two words, a file must hold them all. From three, it may miss some: "growth rates of logs polynomials and
    // exponentials" is a screenshot reading "constants < logs < polynomials < exponentials". Each segment's count of
    // the words it holds comes from one FTS lookup per word.
    let relaxed = terms.len() >= RELAXED_FROM;
    let (sql, mut params) = if relaxed {
        let counts = (0..terms.len())
            .map(|i| {
                format!(
                    "(hit.id IN (SELECT rowid FROM fts WHERE fts MATCH ?{}))",
                    i + 2
                )
            })
            .collect::<Vec<_>>()
            .join(" + ");
        (
            format!(
                "WITH hit AS (SELECT rowid AS id, bm25(fts,4.0,1.0) AS score FROM fts WHERE fts MATCH ?1 ORDER BY score LIMIT 400) \
                 SELECT f.path, f.kind, {counts}, f.mtime FROM hit JOIN segments s ON s.id=hit.id JOIN files f ON f.id=s.file ORDER BY hit.score"
            ),
            vec![terms.join(" OR ")],
        )
    } else {
        (
            format!(
                "SELECT f.path, f.kind, {}, f.mtime FROM fts JOIN segments s ON s.id=fts.rowid JOIN files f ON f.id=s.file WHERE fts MATCH ?1 ORDER BY bm25(fts,4.0,1.0) LIMIT 64",
                terms.len()
            ),
            vec![terms.join(" AND ")],
        )
    };
    if relaxed {
        params.extend(terms.iter().cloned());
    }
    let mut stmt = db.prepare_cached(&sql).map_err(|e| e.to_string())?;
    let mut rows = stmt
        .query(rusqlite::params_from_iter(params.iter()))
        .map_err(|e| e.to_string())?;
    // Each file once, at its segment holding the most words (then the best bm25: rows come in that order).
    let mut best: Vec<(String, String, usize, f64)> = vec![];
    let mut seen: HashMap<String, usize> = HashMap::new();
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let path: String = row.get(0).map_err(|e| e.to_string())?;
        let matched = row.get::<_, i64>(2).map_err(|e| e.to_string())?.max(0) as usize;
        match seen.get(&path) {
            Some(&i) => best[i].2 = best[i].2.max(matched),
            None => {
                seen.insert(path.clone(), best.len());
                let mtime = row.get::<_, Option<f64>>(3).map_err(|e| e.to_string())?;
                best.push((
                    path,
                    row.get(1).map_err(|e| e.to_string())?,
                    matched,
                    mtime.unwrap_or(0.),
                ));
            }
        }
    }
    let total = terms.len();
    let floor = if total >= 5 {
        LONG_COVERAGE
    } else {
        RELAXED_COVERAGE
    };
    let mut ordered: Vec<_> = best
        .into_iter()
        .enumerate()
        .filter(|(_, (_, _, matched, _))| *matched as f64 >= floor * total as f64)
        .collect();
    ordered.sort_by_key(|(order, (_, _, matched, _))| (std::cmp::Reverse(*matched), *order));
    let mut hits = vec![];
    for (position, (path, kind, matched, mtime)) in ordered.into_iter().map(|(_, b)| b).enumerate()
    {
        if hits.len() >= 30 {
            break;
        }
        if !config.semantic_allowed(Path::new(&path)) {
            continue;
        }
        let coverage = matched as f64 / total as f64;
        // Found by its words alone, a file ranks just below what meaning's gate lets through (Z_GATE), more words a
        // little higher. Beside a meaning match, the words lift that instead (the merge, `KEYWORD_LIFT`). A
        // screenshot's words are what it says, and its picture's vector hardly reads them: there, every word found
        // counts more ("eigenvalues and eigenfunctions problem" is the text of a homework screenshot).
        let evidence = if kind == "screenshot" {
            4.4 + 0.2 * matched.min(5) as f64
        } else {
            3.9 + 0.1 * matched.min(5) as f64
        };
        let base = content_base(config, query, &path, mtime);
        hits.push(Hit {
            title: title(&path),
            kind,
            source: "keyword".into(),
            rank: base + 4. * evidence - position as f64 * 0.01,
            category: "content".into(),
            evidence,
            base,
            weak: matched < total,
            coverage,
            path,
            ..Hit::default()
        });
    }
    Ok(hits)
}
/// Content found inside cloned repositories and research dumps ranks below filed documents.
fn buried(config: &Config, path: &str) -> f64 {
    let path = Path::new(path);
    let relative = config
        .file_roots()
        .iter()
        .chain(std::iter::once(&config.home))
        .find_map(|root| path.strip_prefix(root).ok())
        .unwrap_or(path);
    crate::fast::location_adjustment(relative)
}
fn title(path: &str) -> String {
    Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into()
}

/// The query model in its own process. One text is encoded at a time; `request` starts one without waiting, so a
/// keystroke's text is being encoded while the search waits out the typing pause.
struct Encoder {
    child: Child,
    input: ChildStdin,
    replies: Receiver<Result<(Value, Instant), String>>,
    /// The text being encoded now.
    pending: Option<(String, i64)>,
    response_timeout: Duration,
    requested: Instant,
}
impl Encoder {
    fn start(config: &Config) -> Result<Self, String> {
        #[cfg(test)]
        if config.helper != Path::new("/bin/cat") {
            return Err("unit tests cannot launch a configured model helper".into());
        }
        config.coreai().ok_or("Core AI embedding is not configured")?;
        let started = Instant::now();
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(config.index.join("query-model.log"))
            .map_err(|e| e.to_string())?;
        let mut command = Command::new(&config.helper);
        command.args(["worker", "--text-only"]);
        if config.coreai().is_some() {
            let runtime = config.coreai_runtime();
            command
                .args(["--engine", "coreai", "--runtime"])
                .arg(runtime);
        }
        if config.coreai().is_some() {
            command.env(
                "DIGUP_COREAI_LOG",
                config
                    .index
                    .parent()
                    .unwrap_or(&config.index)
                    .join("launcher.log"),
            );
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(log)
            .spawn()
            .map_err(|e| e.to_string())?;
        let input = child.stdin.take().ok_or("model stdin missing")?;
        let output = child.stdout.take().ok_or("model stdout missing")?;
        let (tx, replies) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let value = line
                    .map_err(|e| e.to_string())
                    .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()));
                if tx.send(value.map(|value| (value, Instant::now()))).is_err() {
                    break;
                }
            }
        });
        let encoder = Self {
            child,
            input,
            replies,
            pending: None,
            response_timeout: Duration::from_secs(300),
            requested: Instant::now(),
        };
        let (ready, _) = encoder
            .replies
            .recv_timeout(encoder.response_timeout)
            .map_err(|e| format!("model response: {e}"))??;
        let identity_matches = if config.coreai().is_some() {
            let db = Connection::open_with_flags(
                config.index.join("index.sqlite"),
                OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .map_err(|e| e.to_string())?;
            let (_, revision) =
                checked_coreai_model(&db, config)?.ok_or("Core AI model missing")?;
            ready["info"]["revision"] == revision
                && ready["info"]["runtime"] == "coreai-ane"
                && ready["info"]["dtype"] == "fp16"
                && ready["info"]["model"] == "google/embeddinggemma-2"
        } else {
            false
        };
        if ready["ready"] != true || ready["info"]["dim"] != DIM || !identity_matches {
            return Err(ready["error"]
                .as_str()
                .unwrap_or("model version mismatch")
                .into());
        }
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "SEMANTIC_STARTUP worker_ready_ms={:.2}",
                started.elapsed().as_secs_f64() * 1e3
            );
        }
        Ok(encoder)
    }
    fn panel_visible(&mut self, visible: bool) -> Result<(), String> {
        writeln!(
            self.input,
            "{}",
            json!({"op": if visible { "panel_opened" } else { "panel_closed" }})
        )
        .map_err(|e| e.to_string())?;
        self.input.flush().map_err(|e| e.to_string())
    }
    /// Starts encoding `text`. Call only when nothing is pending.
    fn request(&mut self, text: &str, generation: i64) -> Result<(), String> {
        self.requested = Instant::now();
        writeln!(
            self.input,
            "{}",
            json!({"id":generation,"op":"text","inputs":[format!("task: search result | query: {text}")]})
        )
        .map_err(|e| e.to_string())?;
        self.input.flush().map_err(|e| e.to_string())?;
        self.pending = Some((text.into(), generation));
        Ok(())
    }
    /// The pending text's vector: waits for it, or returns None at once if it isn't ready (`wait` false).
    fn collect(&mut self, wait: bool) -> Result<Option<(String, Vec<f32>, i64)>, String> {
        if self.pending.is_none() {
            return Ok(None);
        }
        let (reply, received) = if wait {
            self.replies
                .recv_timeout(self.response_timeout)
                .map_err(|e| format!("model response: {e}"))??
        } else {
            match self.replies.try_recv() {
                Ok(reply) => reply?,
                Err(TryRecvError::Empty) => return Ok(None),
                Err(e) => return Err(format!("model response: {e}")),
            }
        };
        let (text, generation) = self.pending.take().unwrap();
        if reply["id"].as_i64() != Some(generation) {
            return Err("query reply generation mismatch".into());
        }
        let decode_started = Instant::now();
        let vector = Self::vector(&reply)?;
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            let roundtrip_ms = received.duration_since(self.requested).as_secs_f64() * 1e3;
            let encode_ms = reply["profile_encode_ms"].as_f64();
            eprintln!(
                "SEMANTIC_ENCODING bytes={} roundtrip_ms={:.3} decode_ms={:.3} worker_encode_ms={:?} ipc_ms={:?}",
                text.len(),
                roundtrip_ms,
                decode_started.elapsed().as_secs_f64() * 1e3,
                encode_ms,
                encode_ms.map(|ms| roundtrip_ms - ms)
            );
        }
        Ok(Some((text, vector, generation)))
    }
    fn vector(reply: &Value) -> Result<Vec<f32>, String> {
        if reply["ok"] != true
            || reply["dim"] != DIM
            || reply["count"] != 1
            || reply["errors"][0].is_string()
        {
            return Err(reply["error"]
                .as_str()
                .unwrap_or("invalid model embedding")
                .into());
        }
        let raw = STANDARD
            .decode(reply["vectors"].as_str().ok_or("missing vector")?)
            .map_err(|e| e.to_string())?;
        if raw.len() != DIM * 4 {
            return Err("wrong query vector size".into());
        }
        let mut vector: Vec<_> = raw
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| f32::from_le_bytes(*c))
            .collect();
        let norm = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm < 0.001 {
            return Err("invalid query vector values".into());
        }
        for v in &mut vector {
            *v /= norm;
        }
        Ok(vector)
    }
}
impl Drop for Encoder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// How far a file's best segment must stand out from this query's scores (`meaning`) to be shown. Real matches on
/// the evaluation set stand 6–12 deviations out; nearest neighbours of a query with no answer stand 3–4 out.
pub const Z_GATE: f64 = 4.5;
/// Fewer vectors than this can't describe a query's spread (a new or test index): there, a file needs only to stand
/// a deviation above the rest.
const SMALL_INDEX: usize = 500;
/// In a small index a file whose cosine reaches this is shown however few vectors there are to stand out from (with
/// one or two, none can). Over the 19k vectors of the home index, queries with no answer reach 0.70 at most and real
/// answers mostly 0.74–0.87 (2026-10-14); a small index has fewer near misses still.
const SMALL_INDEX_COSINE: f32 = 0.72;
/// A picture whose tags (DigUp's `ImageTags`: its colours, what Vision sees in it) hold every descriptive word of the
/// query needs only to stand this far out: a second signal that agrees. "red and blue screenshot" puts the right
/// screenshot 2nd of 4.7k pictures at 3.3 deviations, where a picture-only gate can't go: with no answer at all,
/// "photo of a dog" brings pictures 3.8 out (2026-10-13).
const CONFIRMED_GATE: f64 = 2.5;
/// How much a confirmed picture rises, in deviations: about where a match the gate lets through on its own sits.
const CONFIRMED_LIFT: f64 = 1.5;
/// Files this far out are passed on as weak matches: not shown, but a keyword match on the same file is (the merge
/// counts both).
const NEAR_GATE: f64 = 3.0;
/// Pages past a long PDF's first step and chunks past a document's (DigUp's `pdfStep`, `docStep`, `bigPDFPages`).
const PDF_STEP: f64 = 30.;
const DOC_STEP: f64 = 40.;
const BIG_PDF_PAGES: i64 = 50;
/// Rows scored between checks that the query is still the latest.
const BLOCK_ROWS: usize = 4096;

/// A file whose vectors are loaded, as the index described it when they were read.
struct Loaded {
    path: String,
    kind: String,
    stamp: f64,
    mtime: f64,
    /// The words of a picture's tags (`tag_words`); empty for other files.
    tags: HashSet<String>,
}

/// Words that say what kind of file is wanted, or nothing at all: not what a picture shows.
const PLAIN_WORDS: &[&str] = &[
    "a",
    "an",
    "the",
    "of",
    "in",
    "on",
    "at",
    "to",
    "for",
    "with",
    "and",
    "or",
    "my",
    "me",
    "that",
    "this",
    "from",
    "about",
    "some",
    "any",
    "find",
    "show",
    "where",
    "what",
    "which",
    "is",
    "was",
    "are",
    "it",
    "its",
    "file",
    "files",
    "photo",
    "photos",
    "picture",
    "pictures",
    "pic",
    "pics",
    "image",
    "images",
    "screenshot",
    "screenshots",
    "shot",
    "screen",
    "document",
    "documents",
    "pdf",
    "pdfs",
    "scan",
    "scans",
];

/// Lowercase words, singular ("dogs" and "dog" meet).
fn tag_words(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| {
            let w = w.to_lowercase();
            match w.strip_suffix('s') {
                Some(stem) if stem.chars().count() >= 3 && !stem.ends_with('s') => stem.to_string(),
                _ => w,
            }
        })
}

/// A unit vector as signed bytes and the scale that restores it: a quarter of the f32 size, and scored with the M1's
/// 8-bit dot product (`dot`). The rounding moves a cosine by about 0.0005, against score spreads of 0.02 or more.
fn quantize(vector: &[f32], codes: &mut Vec<i8>) -> f32 {
    let largest = vector.iter().fold(0f32, |m, v| m.max(v.abs()));
    let scale = if largest > 0. { largest / 127. } else { 1. };
    codes.extend(
        vector
            .iter()
            .map(|v| (v / scale).round().clamp(-127., 127.) as i8),
    );
    scale
}

/// Dot products of `query` with each 768-byte row of `rows`, into `out`.
fn dot_rows(rows: &[i8], query: &[i8], out: &mut [i32]) {
    #[cfg(target_arch = "aarch64")]
    if std::arch::is_aarch64_feature_detected!("dotprod") {
        // Safety: the feature was detected, and every row and the query are DIM bytes (DIM is a multiple of 64).
        unsafe { dot_rows_neon(rows, query, out) };
        return;
    }
    for (row, out) in rows.as_chunks::<DIM>().0.iter().zip(out.iter_mut()) {
        *out = row
            .iter()
            .zip(query)
            .map(|(&a, &b)| a as i32 * b as i32)
            .sum();
    }
}
#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "dotprod")]
unsafe fn dot_rows_neon(rows: &[i8], query: &[i8], out: &mut [i32]) {
    use std::arch::aarch64::*;
    assert!(query.len() == DIM && rows.len() >= out.len() * DIM);
    unsafe {
        for (r, out) in out.iter_mut().enumerate() {
            let row = rows.as_ptr().add(r * DIM);
            let (mut a, mut b, mut c, mut d) = (
                vdupq_n_s32(0),
                vdupq_n_s32(0),
                vdupq_n_s32(0),
                vdupq_n_s32(0),
            );
            let mut i = 0;
            while i < DIM {
                a = vdotq_s32(a, vld1q_s8(row.add(i)), vld1q_s8(query.as_ptr().add(i)));
                b = vdotq_s32(
                    b,
                    vld1q_s8(row.add(i + 16)),
                    vld1q_s8(query.as_ptr().add(i + 16)),
                );
                c = vdotq_s32(
                    c,
                    vld1q_s8(row.add(i + 32)),
                    vld1q_s8(query.as_ptr().add(i + 32)),
                );
                d = vdotq_s32(
                    d,
                    vld1q_s8(row.add(i + 48)),
                    vld1q_s8(query.as_ptr().add(i + 48)),
                );
                i += 64;
            }
            *out = vaddvq_s32(vaddq_s32(vaddq_s32(a, b), vaddq_s32(c, d)));
        }
    }
}

fn model_generation(db: &Connection) -> Result<i64, String> {
    db.query_row(
        "SELECT CAST(value AS INTEGER) FROM meta WHERE key='embedding_generation'",
        [],
        |r| r.get(0),
    )
    .optional()
    .map(|v| v.unwrap_or(0))
    .map_err(|e| e.to_string())
}

fn active_config(db: &Connection, config: &Config) -> Result<Config, String> {
    let mut selected = config.clone();
    if config.coreai().is_some() {
        let active: Option<String> = db
            .query_row(
                "SELECT value FROM meta WHERE key='active_embedding_model'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if let Some(key) = active {
            // Preserve the catalog key so legacy activations fail Core AI identity checks, never select a fallback.
            selected.embedding.as_mut().unwrap().model_key = Some(key);
        }
    }
    Ok(selected)
}

#[derive(Default)]
pub struct ModelCatalog {
    db: Option<Connection>,
}

impl ModelCatalog {
    fn connection(&mut self, config: &Config) -> Option<&Connection> {
        if self.db.is_none() {
            self.db = Connection::open_with_flags(
                config.index.join("index.sqlite"),
                OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .ok();
        }
        self.db.as_ref()
    }

    pub fn generation(&mut self, config: &Config) -> Option<i64> {
        self.connection(config)
            .and_then(|db| model_generation(db).ok())
    }

    pub fn selected_config(&mut self, config: &Config) -> Config {
        if config.coreai().is_none() {
            return config.clone();
        }
        self.connection(config)
            .and_then(|db| active_config(db, config).ok())
            .unwrap_or_else(|| config.clone())
    }
}

pub fn indexing_config(config: &Config) -> Config {
    if config.coreai().is_none() {
        return config.clone();
    }
    Connection::open_with_flags(
        config.index.join("index.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()
    .and_then(|db| active_config(&db, config).ok())
    .unwrap_or_else(|| config.clone())
}

fn checked_coreai_model(db: &Connection, config: &Config) -> Result<Option<(i64, String)>, String> {
    let coreai = config
        .coreai()
        .ok_or("Core AI embedding is not configured")?;
    let key = coreai
        .model_key
        .as_deref()
        .ok_or("Core AI model_key missing")?;
    if !["coreai-eg2-text-v1", "coreai-eg2-v1"].contains(&key) {
        return Err("unsupported Core AI model key".into());
    }
    if (matches!(coreai.image_vectors, crate::scope::ImageVectors::Coreai)
        || matches!(coreai.audio_vectors, crate::scope::ImageVectors::Coreai)
        || coreai.video_clip_vectors)
        && key != "coreai-eg2-v1"
    {
        return Err("Core AI media vectors require coreai-eg2-v1".into());
    }
    let row = db
        .query_row(
            "SELECT id,build,state,storage,dim,weights_sha256 FROM embedding_models WHERE key=?1",
            [key],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, String>(5)?,
                ))
            },
        )
        .optional()
        .map_err(|e| format!("Core AI model catalog: {e}"))?
        .ok_or_else(|| format!("Core AI model {key} is not registered"))?;
    if row.3 != "vectors"
        || row.4 != DIM as i64
        || row.5 != "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"
    {
        return Err("Core AI model catalog identity mismatch".into());
    }
    let progressive = row.2 == "building"
        && db
            .query_row(
                "SELECT value FROM meta WHERE key='first_run_embedding_model'",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(|e| e.to_string())?
            .as_deref()
            == Some(key);
    if !coreai.allow_incomplete && !progressive && !matches!(row.2.as_str(), "complete" | "active")
    {
        return Err(format!(
            "Core AI model {key} is {}; semantic search requires complete/active",
            row.2
        ));
    }
    Ok(Some((row.0, row.1)))
}

fn vector_columns(config: &Config, model: Option<i64>, files: Option<&[i64]>) -> String {
    let audio_available = config.coreai().is_none() || config.coreai_audio_installed();
    let mut modalities = vec!["'text'"];
    if let Some(embedding) = config.coreai() {
        if matches!(embedding.image_vectors, crate::scope::ImageVectors::Coreai) {
            modalities.push("'image'");
        }
        if matches!(embedding.audio_vectors, crate::scope::ImageVectors::Coreai) && audio_available
        {
            modalities.push("'audio'");
        }
    }
    let clips = config.coreai().is_some_and(|e| e.video_clip_vectors);
    if clips {
        modalities.push("'video'");
    }
    let selected = format!("({})", modalities.join(","));
    let mut filter = if !audio_available {
        " AND s.modality != 'audio'".to_string()
    } else {
        String::new()
    };
    if let Some(ids) = files {
        if ids.is_empty() {
            filter.push_str(" AND 0");
        } else {
            filter.push_str(&format!(
                " AND s.file IN ({})",
                ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
            ));
        }
    }
    if let Some(modalities) = &config.semantic_modalities {
        if modalities.is_empty() {
            filter.push_str(" AND 0");
        } else {
            filter.push_str(&format!(
                " AND s.modality IN ({})",
                modalities
                    .iter()
                    .map(|m| m.sql())
                    .collect::<Vec<_>>()
                    .join(",")
            ));
        }
    }
    let columns = "s.file,s.modality,s.kind,s.loc";
    let pages = "CAST(json_extract(f.info, '$.pages') AS INTEGER)";
    match model {
        None => format!(
            "SELECT {columns},s.vec,{pages} FROM segments s JOIN files f ON f.id=s.file WHERE s.vec IS NOT NULL{filter} ORDER BY s.id"
        ),
        Some(id) => {
            let end = if clips { ",s.loc_end" } else { "" };
            format!(
                "SELECT {columns},v.vec,{pages}{end},v.segment AS sort_id FROM vectors v JOIN segments s ON s.id=v.segment JOIN files f ON f.id=s.file WHERE v.model={id} AND s.modality IN {selected} AND v.vec IS NOT NULL{filter} \
                UNION ALL SELECT {columns},s.vec,{pages}{end},s.id AS sort_id FROM segments s JOIN files f ON f.id=s.file WHERE s.modality NOT IN {selected} AND s.vec IS NOT NULL{filter} ORDER BY sort_id"
            )
        }
    }
}

/// The index's vectors in memory, kept in step with the indexer: files it finished, changed or removed since the
/// last search are read or dropped by themselves, so a search never re-reads all of them.
pub struct SemanticSearch {
    db: Option<Connection>,
    version: i64,
    generation: i64,
    model_identity: Option<(Option<i64>, String)>,
    audio_available: Option<bool>,
    selected_config: Option<Config>,
    checked: Instant,
    files: HashMap<i64, Loaded>,
    row_file: Vec<i64>,
    /// 0 text, 1 image, 2 audio, 3 anything else.
    row_modality: Vec<u8>,
    row_clip_range: Vec<Option<(f64, f64)>>,
    /// Whether the row sets this query's scale (`meaning`): the later pages of long files are scored but don't.
    row_scale: Vec<bool>,
    row_alive: Vec<bool>,
    dead: usize,
    /// Each row's vector (`quantize`), DIM bytes a row, and its scale.
    codes: Vec<i8>,
    row_unit: Vec<f32>,
    /// Every word some picture's tags hold: a query word outside it describes nothing a tag could confirm.
    tag_vocabulary: HashSet<String>,
    encoder: Option<Encoder>,
    query_cache: HashMap<String, Vec<f32>>,
    /// Kept between searches.
    dots: Vec<i32>,
    scores: Vec<f32>,
}
impl SemanticSearch {
    pub fn new() -> Self {
        Self {
            db: None,
            version: -1,
            generation: -1,
            model_identity: None,
            audio_available: None,
            selected_config: None,
            checked: Instant::now() - Duration::from_secs(10),
            files: HashMap::new(),
            row_file: vec![],
            row_modality: vec![],
            row_clip_range: vec![],
            row_scale: vec![],
            row_alive: vec![],
            dead: 0,
            codes: vec![],
            row_unit: vec![],
            tag_vocabulary: HashSet::new(),
            encoder: None,
            query_cache: HashMap::new(),
            dots: vec![],
            scores: vec![],
        }
    }
    pub fn generation(&self) -> i64 {
        self.generation
    }
    fn rows(&self) -> usize {
        self.row_file.len()
    }
    fn reload(&mut self, config: &Config) -> Result<(), String> {
        let reload_started = Instant::now();
        let initial = self.version < 0;
        if self.db.is_none() {
            let path = config.index.join("index.sqlite");
            if !path.exists() {
                return Ok(());
            }
            let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| e.to_string())?;
            db.busy_timeout(Duration::from_millis(200))
                .map_err(|e| e.to_string())?;
            if config.coreai().is_some() {
                db.pragma_update(None, "temp_store", 2)
                    .map_err(|e| e.to_string())?;
            }
            self.db = Some(db);
        }
        let db = self.db.as_mut().unwrap();
        let version: i64 = db
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        let selected_config = self.selected_config.as_ref().unwrap_or(config);
        let audio_available =
            selected_config.coreai().is_none() || selected_config.coreai_audio_installed();
        if (version == self.version && self.audio_available == Some(audio_available))
            || (config.coreai().is_none()
                && self.version >= 0
                && self.checked.elapsed() < Duration::from_millis(500))
        {
            return Ok(());
        }
        let tx = db.transaction().map_err(|e| e.to_string())?;
        let generation = model_generation(&tx)?;
        let selected = active_config(&tx, config)?;
        let config = &selected;
        let coreai_model = checked_coreai_model(&tx, config)?;
        let identity = coreai_model
            .as_ref()
            .map(|(id, build)| (Some(*id), build.clone()))
            .ok_or("Core AI model missing")?;
        let audio_available = config.coreai_audio_installed();
        if self.generation != generation || self.audio_available != Some(audio_available) {
            self.files.clear();
            self.row_file.clear();
            self.row_modality.clear();
            self.row_clip_range.clear();
            self.row_scale.clear();
            self.row_alive.clear();
            self.codes.clear();
            self.row_unit.clear();
            self.dead = 0;
            if self.model_identity.as_ref() != Some(&identity) {
                self.encoder = None;
            }
            self.query_cache.clear();
        }
        // The worker loads its query group while this thread decodes vectors.
        let has_coreai_vectors = match coreai_model.as_ref() {
            Some((id, _)) => tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM vectors WHERE model=?1 LIMIT 1)",
                    [id],
                    |r| r.get::<_, bool>(0),
                )
                .map_err(|e| e.to_string())?,
            None => false,
        };
        if has_coreai_vectors && self.encoder.is_none() {
            self.encoder = Some(Encoder::start(config)?);
        }
        // Each searchable file and when it was last written: a step of a long file, a re-read and a move all change it.
        let mut current: HashMap<i64, Loaded> = HashMap::new();
        {
            let mut stmt = tx
                .prepare_cached("SELECT id, path, kind, indexed_at, mtime FROM files WHERE state IN ('done','partial') AND indexed_at IS NOT NULL")
                .map_err(|e| e.to_string())?;
            let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let path: String = row.get(1).map_err(|e| e.to_string())?;
                if config.semantic_lexical(Path::new(&path)) {
                    current.insert(
                        row.get(0).map_err(|e| e.to_string())?,
                        Loaded {
                            path,
                            kind: row.get(2).map_err(|e| e.to_string())?,
                            stamp: row.get(3).map_err(|e| e.to_string())?,
                            mtime: row
                                .get::<_, Option<f64>>(4)
                                .map_err(|e| e.to_string())?
                                .unwrap_or(0.),
                            tags: HashSet::new(),
                        },
                    );
                }
            }
        }
        let stale: HashSet<i64> = self
            .files
            .iter()
            .filter(|(id, old)| {
                current
                    .get(id)
                    .is_none_or(|now| now.stamp != old.stamp || now.path != old.path)
            })
            .map(|(id, _)| *id)
            .collect();
        if !stale.is_empty() {
            for (row, file) in self.row_file.iter().enumerate() {
                if self.row_alive[row] && stale.contains(file) {
                    self.row_alive[row] = false;
                    self.dead += 1;
                }
            }
            self.files.retain(|id, _| !stale.contains(id));
        }
        let fresh: Vec<i64> = current
            .keys()
            .filter(|id| !self.files.contains_key(id))
            .copied()
            .collect();
        let fresh_none = fresh.is_empty();
        if !fresh.is_empty() {
            // The first load reads everything at once; later ones only the files that changed.
            let batches: Vec<Option<&[i64]>> = if self.files.is_empty() {
                vec![None]
            } else {
                fresh.chunks(500).map(Some).collect()
            };
            let mut unit = vec![0f32; DIM];
            for batch in batches {
                let sql = vector_columns(config, coreai_model.as_ref().map(|m| m.0), batch);
                let mut stmt = tx.prepare(&sql).map_err(|e| e.to_string())?;
                let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
                while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                    let file: i64 = row.get(0).map_err(|e| e.to_string())?;
                    let Some(entry) = current.get(&file) else {
                        continue;
                    };
                    let blob = row.get_ref(4).map_err(|e| e.to_string())?;
                    let blob = blob.as_blob().map_err(|e| e.to_string())?;
                    if blob.len() != DIM * 2 {
                        return Err("index vector dimension mismatch".into());
                    }
                    for (v, c) in unit.iter_mut().zip(blob.as_chunks::<2>().0) {
                        *v = f16::from_bits(u16::from_le_bytes(*c)).to_f32();
                    }
                    let scale = quantize(&unit, &mut self.codes);
                    self.row_unit.push(scale);
                    let modality: String = row.get(1).map_err(|e| e.to_string())?;
                    let segment: String = row.get(2).map_err(|e| e.to_string())?;
                    let place: f64 = row
                        .get::<_, Option<f64>>(3)
                        .map_err(|e| e.to_string())?
                        .unwrap_or(0.);
                    let pages: i64 = row
                        .get::<_, Option<i64>>(5)
                        .map_err(|e| e.to_string())?
                        .unwrap_or(0);
                    let later = if entry.kind == "pdf" {
                        segment != "chunk" && pages > BIG_PDF_PAGES && place > PDF_STEP
                    } else {
                        segment == "chunk" && place > DOC_STEP
                    };
                    self.row_clip_range.push(if modality == "video" {
                        Some((place, row.get::<_, f64>(6).map_err(|e| e.to_string())?))
                    } else {
                        None
                    });
                    self.row_file.push(file);
                    self.row_modality.push(match modality.as_str() {
                        "text" => 0,
                        "image" => 1,
                        "audio" => 2,
                        _ => 3,
                    });
                    self.row_scale.push(!later);
                    self.row_alive.push(true);
                }
            }
            {
                let mut stmt = tx
                    .prepare_cached("SELECT file, excerpt FROM segments WHERE kind = 'tags'")
                    .map_err(|e| e.to_string())?;
                let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
                while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                    let file: i64 = row.get(0).map_err(|e| e.to_string())?;
                    if let Some(entry) = current.get_mut(&file) {
                        let tags: Option<String> = row.get(1).map_err(|e| e.to_string())?;
                        entry.tags = tag_words(&tags.unwrap_or_default()).collect();
                    }
                }
            }
            for id in fresh {
                if let Some(entry) = current.remove(&id) {
                    self.files.insert(id, entry);
                }
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
        if !stale.is_empty() || !fresh_none {
            self.tag_vocabulary = self
                .files
                .values()
                .flat_map(|f| f.tags.iter().cloned())
                .collect();
        }
        if self.dead > 4096 && self.dead * 4 > self.rows() {
            self.compact();
        }
        self.generation = generation;
        self.model_identity = Some(identity);
        self.selected_config = Some(selected);
        self.audio_available = Some(audio_available);
        self.version = version;
        self.checked = Instant::now();
        if initial && std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "SEMANTIC_STARTUP initial_reload_ms={:.2} rows={}",
                reload_started.elapsed().as_secs_f64() * 1e3,
                self.rows()
            );
        }
        Ok(())
    }
    /// Pictures whose tags hold every word of the query that some picture's tags hold ("red and blue screenshot":
    /// red, blue). None when tags could show less than two thirds of what the query asks for: a café photo tagged
    /// "restaurant" isn't a "receipt from a restaurant".
    fn confirmed(&self, query: &str) -> HashSet<i64> {
        let plain: HashSet<String> = PLAIN_WORDS.iter().flat_map(|w| tag_words(w)).collect();
        let asked: HashSet<String> = tag_words(query).filter(|w| !plain.contains(w)).collect();
        let described: HashSet<String> = asked
            .iter()
            .filter(|w| self.tag_vocabulary.contains(*w))
            .cloned()
            .collect();
        if described.is_empty() || described.len() * 3 < asked.len() * 2 {
            return HashSet::new();
        }
        self.files
            .iter()
            .filter(|(_, f)| described.is_subset(&f.tags))
            .map(|(id, _)| *id)
            .collect()
    }
    /// Drops the rows of files that changed or left, once they are a quarter of the matrix.
    fn compact(&mut self) {
        let mut codes = Vec::with_capacity((self.rows() - self.dead) * DIM);
        let mut keep = 0;
        for row in 0..self.rows() {
            if self.row_alive[row] {
                codes.extend_from_slice(&self.codes[row * DIM..(row + 1) * DIM]);
                self.row_file[keep] = self.row_file[row];
                self.row_modality[keep] = self.row_modality[row];
                self.row_clip_range[keep] = self.row_clip_range[row];
                self.row_scale[keep] = self.row_scale[row];
                self.row_unit[keep] = self.row_unit[row];
                keep += 1;
            }
        }
        self.row_file.truncate(keep);
        self.row_modality.truncate(keep);
        self.row_clip_range.truncate(keep);
        self.row_scale.truncate(keep);
        self.row_unit.truncate(keep);
        self.row_alive = vec![true; keep];
        self.codes = codes;
        self.dead = 0;
    }
    pub fn panel_closed(&mut self) {
        if let Some(encoder) = &mut self.encoder {
            let _ = encoder.panel_visible(false);
        }
    }
    pub fn holds_model(&self) -> bool {
        self.encoder.is_some()
    }
    /// Loads the vectors and starts the query model so the first search after opening the pill
    /// does not pay the ~1–2 s model start.
    pub fn prewarm(&mut self, config: &Config, query: Option<&str>) -> Result<(), String> {
        let started = Instant::now();
        if config.coreai().is_some()
            && let Some(encoder) = &mut self.encoder
        {
            encoder.panel_visible(true)?;
        }
        self.reload(config)?;
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "SEMANTIC_STARTUP vector_load_ms={:.2} rows={}",
                started.elapsed().as_secs_f64() * 1e3,
                self.rows()
            );
        }
        let selected = self.selected_config.as_ref().unwrap_or(config);
        if self.rows() > 0
            && self.encoder.is_none()
            && query.is_none_or(|q| !self.query_cache.contains_key(q))
        {
            self.encoder = Some(Encoder::start(selected)?);
        }
        if let Some(encoder) = &mut self.encoder {
            encoder.panel_visible(true)?;
        }
        Ok(())
    }
    fn remember(&mut self, text: String, vector: Vec<f32>, generation: i64) {
        if generation != self.generation {
            return;
        }
        if self.query_cache.len() >= 64 {
            self.query_cache.clear();
        }
        self.query_cache.insert(text, vector);
    }
    /// `query`'s vector: known, being encoded, or encoded now.
    fn vector(
        &mut self,
        config: &Config,
        query: &str,
        current: &impl Fn() -> bool,
    ) -> Result<Vec<f32>, String> {
        loop {
            if !current() {
                return Err("query superseded".into());
            }
            if let Some(v) = self.query_cache.get(query) {
                return Ok(v.clone());
            }
            if self.encoder.is_none() {
                self.encoder = Some(Encoder::start(config)?);
            }
            if !current() {
                return Err("query superseded".into());
            }
            let encoder = self.encoder.as_mut().unwrap();
            if encoder.pending.is_none() {
                encoder.request(query, self.generation)?;
            }
            if let Some((text, vector, generation)) = encoder.collect(true)? {
                self.remember(text, vector, generation);
            }
        }
    }
    pub fn search(
        &mut self,
        config: &Config,
        query: &str,
        current: impl Fn() -> bool,
    ) -> Result<Vec<Hit>, String> {
        let t0 = Instant::now();
        self.reload(config)?;
        let t_reload = t0.elapsed();
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "SEMANTIC_GENERATION_CAPTURED generation={} bytes={}",
                self.generation,
                query.len()
            );
        }
        if self.rows() == 0 || !current() {
            return Ok(vec![]);
        }
        let selected = self
            .selected_config
            .clone()
            .unwrap_or_else(|| config.clone());
        let config = &selected;
        let vector = match self.vector(config, query, &current) {
            Ok(v) => v,
            Err(e) => {
                if !e.contains("coreai readiness") && e != "query superseded" {
                    self.encoder = None;
                }
                return Err(e);
            }
        };
        if let Some(db) = &self.db
            && model_generation(db)? != self.generation
        {
            self.query_cache.clear();
            return Err("embedding generation changed; late query reply rejected".into());
        }
        let t_encode = t0.elapsed();
        let mut query_codes = Vec::with_capacity(DIM);
        let query_unit = quantize(&vector, &mut query_codes);
        let rows = self.rows();
        self.dots.resize(rows, 0);
        for start in (0..rows).step_by(BLOCK_ROWS) {
            if !current() {
                return Ok(vec![]);
            }
            let end = (start + BLOCK_ROWS).min(rows);
            dot_rows(
                &self.codes[start * DIM..end * DIM],
                &query_codes,
                &mut self.dots[start..end],
            );
        }
        self.scores.clear();
        self.scores.extend(
            self.dots
                .iter()
                .zip(&self.row_unit)
                .map(|(&d, &u)| d as f32 * u * query_unit),
        );
        let t_score = t0.elapsed();
        let meaning = meaning(&self.scores, &self.row_modality, |row| {
            self.row_alive[row] && self.row_scale[row]
        });
        let small = self.rows() - self.dead < SMALL_INDEX;
        let gate = if small { 1. } else { Z_GATE };
        let near = NEAR_GATE.min(gate);
        let confirmed = self.confirmed(query);
        let mut clip_winners = HashMap::new();
        let mut best: HashMap<i64, (f64, f32)> = HashMap::new();
        for (row, &z) in meaning.iter().enumerate() {
            let mut z = z;
            if !self.row_alive[row] || !z.is_finite() {
                continue;
            }
            if small && self.scores[row] >= SMALL_INDEX_COSINE {
                z = z.max(gate);
            }
            if confirmed.contains(&self.row_file[row]) {
                if z < CONFIRMED_GATE.min(gate) {
                    continue;
                }
                z += CONFIRMED_LIFT;
            } else if z < near {
                continue;
            }
            let wins = best
                .get(&self.row_file[row])
                .is_none_or(|entry| z > entry.0);
            if wins {
                clip_winners.insert(
                    self.files[&self.row_file[row]].path.clone(),
                    self.row_clip_range[row],
                );
            }
            let entry = best
                .entry(self.row_file[row])
                .or_insert((z, self.scores[row]));
            if z > entry.0 {
                *entry = (z, self.scores[row]);
            }
        }
        let mut ordered: Vec<_> = best.into_iter().collect();
        ordered.sort_by(|a, b| {
            let score = b.1.0.total_cmp(&a.1.0);
            if config.coreai().is_some() {
                score.then_with(|| self.files[&a.0].path.cmp(&self.files[&b.0].path))
            } else {
                score
            }
        });
        let (shown, weak): (Vec<_>, Vec<_>) =
            ordered.into_iter().partition(|(_, (z, _))| *z >= gate);
        let hit = |f: &Loaded, z: f64, cosine: f32, weak: bool| {
            let base = content_base(config, query, &f.path, f.mtime);
            Hit {
                path: f.path.clone(),
                title: if let Some(Some((start, end))) = clip_winners.get(&f.path) {
                    format!("{} [{start:.1}-{end:.1} s]", title(&f.path))
                } else {
                    title(&f.path)
                },
                kind: f.kind.clone(),
                source: "semantic".into(),
                rank: base + 4. * z,
                category: "meaning".into(),
                cosine: Some(cosine),
                evidence: z,
                base,
                weak,
                coverage: 0.,
            }
        };
        let mut hits: Vec<Hit> = shown
            .into_iter()
            .filter_map(|(file, score)| self.files.get(&file).map(|f| (f, score)))
            .take(60)
            .filter(|(f, _)| config.semantic_allowed(Path::new(&f.path)))
            .take(20)
            .map(|(f, (z, cosine))| hit(f, z, cosine, false))
            .collect();
        // Not checked against the scope here: a weak match shows only beside a keyword match, which was.
        hits.extend(
            weak.into_iter()
                .take(100)
                .filter_map(|(file, (z, cosine))| {
                    self.files.get(&file).map(|f| hit(f, z, cosine, true))
                }),
        );
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "SEMANTIC_TIMING reload_ms={:.2} encode_ms={:.2} score_ms={:.2} rank_ms={:.2} rows={}",
                t_reload.as_secs_f64() * 1e3,
                (t_encode - t_reload).as_secs_f64() * 1e3,
                (t_score - t_encode).as_secs_f64() * 1e3,
                (t0.elapsed() - t_score).as_secs_f64() * 1e3,
                self.rows()
            );
        }
        Ok(hits)
    }
}

/// This query's meaning scores, after DigUp's `Searcher.meaning`: each vector's cosine similarity minus the average of
/// its modality (text, image and audio vectors sit at different levels for the same query), in standard deviations of
/// all of them together. This model scores every file about 0.6 against any query, so the raw cosine says little;
/// how far a file stands out from the rest does. `scale` picks the rows the averages and deviation come from.
fn meaning(scores: &[f32], modality: &[u8], scale: impl Fn(usize) -> bool) -> Vec<f64> {
    let (mut sum, mut count) = ([0f64; 4], [0usize; 4]);
    let (mut all, mut total) = (0f64, 0usize);
    for (row, &score) in scores.iter().enumerate() {
        if scale(row) {
            sum[modality[row] as usize] += score as f64;
            count[modality[row] as usize] += 1;
            all += score as f64;
            total += 1;
        }
    }
    if total == 0 {
        return vec![f64::NEG_INFINITY; scores.len()];
    }
    // Small groups (< 20 vectors) take the average of all.
    let means: Vec<f64> = (0..4)
        .map(|m| {
            if count[m] >= 20 {
                sum[m] / count[m] as f64
            } else {
                all / total as f64
            }
        })
        .collect();
    let centered: Vec<f64> = scores
        .iter()
        .zip(modality)
        .map(|(&s, &m)| s as f64 - means[m as usize])
        .collect();
    let (mut mean, mut squares) = (0f64, 0f64);
    for (row, c) in centered.iter().enumerate() {
        if scale(row) {
            mean += c;
        }
    }
    mean /= total as f64;
    for (row, c) in centered.iter().enumerate() {
        if scale(row) {
            squares += (c - mean) * (c - mean);
        }
    }
    let deviation = (squares / total as f64).sqrt().max(0.02);
    centered.iter().map(|c| (c - mean) / deviation).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn active_catalog_overrides_only_explicit_coreai_and_generation_changes() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('embedding_generation','3'),('active_embedding_model','llama-vectors1');").unwrap();
        let mut config: Config = serde_json::from_value(json!({"home":"/sample","helper":"/sample/digup","index":"/sample/index","models":"/sample/models","embedding":{"engine":"coreai","model_key":"coreai-eg2-v1"}})).unwrap();
        assert_eq!(
            active_config(&db, &config)
                .unwrap()
                .coreai()
                .unwrap()
                .model_key
                .as_deref(),
            Some("llama-vectors1")
        );
        let selected = active_config(&db, &config).unwrap();
        assert_eq!(checked_coreai_model(&db, &selected).unwrap_err(), "unsupported Core AI model key");
        assert_eq!(model_generation(&db).unwrap(), 3);
        db.execute(
            "UPDATE meta SET value='coreai-eg2-v1' WHERE key='active_embedding_model'",
            [],
        )
        .unwrap();
        assert!(active_config(&db, &config).unwrap().coreai().is_some());
        config.embedding = None;
        assert!(active_config(&db, &config).unwrap().coreai().is_none());
        assert_eq!(checked_coreai_model(&db, &config).unwrap_err(), "Core AI embedding is not configured");
        db.execute(
            "UPDATE meta SET value='4' WHERE key='embedding_generation'",
            [],
        )
        .unwrap();
        assert_ne!(model_generation(&db).unwrap(), 3);
    }

    #[test]
    fn retained_catalog_observes_wal_activation_and_rollback_without_a_stale_snapshot() {
        let root = std::env::temp_dir().join(format!("p7-catalog-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let config: Config = serde_json::from_value(json!({
            "home":"/sample", "helper":"/sample/digup", "index":root, "models":"/sample/models",
            "embedding":{"engine":"coreai", "model_key":"coreai-eg2-v1"}
        }))
        .unwrap();
        let mut catalog = ModelCatalog::default();
        assert_eq!(catalog.generation(&config), None);
        let writer = Connection::open(root.join("index.sqlite")).unwrap();
        writer.execute_batch("PRAGMA journal_mode=WAL;
            CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);
            INSERT INTO meta VALUES('embedding_generation','1'),('active_embedding_model','coreai-eg2-v1');").unwrap();
        assert_eq!(catalog.generation(&config), Some(1));
        assert!(catalog.selected_config(&config).coreai().is_some());
        writer
            .execute_batch(
                "BEGIN IMMEDIATE;
            UPDATE meta SET value='2' WHERE key='embedding_generation';
            UPDATE meta SET value='llama-vectors1' WHERE key='active_embedding_model';",
            )
            .unwrap();
        assert_eq!(catalog.generation(&config), Some(1));
        writer.execute_batch("COMMIT").unwrap();
        assert_eq!(catalog.generation(&config), Some(2));
        assert_eq!(
            catalog
                .selected_config(&config)
                .coreai()
                .unwrap()
                .model_key
                .as_deref(),
            Some("llama-vectors1")
        );
        writer
            .execute_batch(
                "BEGIN IMMEDIATE;
            UPDATE meta SET value='3' WHERE key='embedding_generation';
            UPDATE meta SET value='coreai-eg2-v1' WHERE key='active_embedding_model'; COMMIT;",
            )
            .unwrap();
        assert_eq!(catalog.generation(&config), Some(3));
        assert!(catalog.selected_config(&config).coreai().is_some());
    }

    #[test]
    fn image_model_catalog_accepts_v1_and_preserves_coverage_checks() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE embedding_models(id INTEGER,key TEXT,build TEXT,state TEXT,storage TEXT,dim INTEGER,weights_sha256 TEXT);
            INSERT INTO embedding_models VALUES(1,'coreai-eg2-v1','test-build','complete','vectors',768,'197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79');").unwrap();
        let config: Config = serde_json::from_value(json!({"home":"/sample","helper":"/sample/digup","index":"/sample/index","models":"/sample/models",
            "embedding":{"engine":"coreai","model_key":"coreai-eg2-v1","image_vectors":"coreai"}})).unwrap();
        assert_eq!(
            checked_coreai_model(&db, &config).unwrap(),
            Some((1, "test-build".to_string()))
        );
        db.execute("UPDATE embedding_models SET state='building'", [])
            .unwrap();
        assert!(checked_coreai_model(&db, &config).is_err());
    }

    #[test]
    fn progressive_search_requires_the_normal_indexers_first_run_marker() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE embedding_models(id INTEGER,key TEXT,build TEXT,state TEXT,storage TEXT,dim INTEGER,weights_sha256 TEXT);
            INSERT INTO embedding_models VALUES(1,'coreai-eg2-v1','test','building','vectors',768,'197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79');").unwrap();
        let config: Config = serde_json::from_value(json!({"home":"/sample","helper":"/sample/digup","index":"/sample/index","models":"/sample/models",
            "embedding":{"engine":"coreai","model_key":"coreai-eg2-v1"}})).unwrap();
        assert!(checked_coreai_model(&db, &config).is_err());
        db.execute(
            "INSERT INTO meta VALUES('first_run_embedding_model','other')",
            [],
        )
        .unwrap();
        assert!(checked_coreai_model(&db, &config).is_err());
        db.execute("UPDATE meta SET value='coreai-eg2-v1'", [])
            .unwrap();
        assert!(checked_coreai_model(&db, &config).is_ok());
        db.execute("UPDATE embedding_models SET state='failed'", [])
            .unwrap();
        assert!(checked_coreai_model(&db, &config).is_err());
    }

    #[test]
    fn vector_sql_selects_the_requested_engine_and_modalities() {
        let audio_runtime =
            std::env::temp_dir().join(format!("swiftlight-audio-sql-{}", std::process::id()));
        std::fs::create_dir_all(audio_runtime.join("audio.aimodel")).unwrap();
        std::fs::create_dir_all(audio_runtime.join("audio-host")).unwrap();
        std::fs::write(
            audio_runtime.join("manifest.json"),
            r#"{"audio_identity":{}}"#,
        )
        .unwrap();
        std::fs::write(audio_runtime.join("audio.aimodel/main.mlirb"), b"model").unwrap();
        std::fs::write(audio_runtime.join("audio-host/identity.json"), b"{}").unwrap();
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE files(id INTEGER,info TEXT); CREATE TABLE segments(id INTEGER,file INTEGER,modality TEXT,kind TEXT,loc REAL,vec BLOB); CREATE TABLE vectors(model INTEGER,segment INTEGER,vec BLOB);
            INSERT INTO files VALUES(1,'{}');
            INSERT INTO segments VALUES(1,1,'text','chunk',1,X'01'),(2,1,'image','image',NULL,X'02'),(3,1,'text','chunk',2,X'03'),(4,1,'audio','audio',0,X'04');
            INSERT INTO vectors VALUES(7,1,X'07'),(8,3,X'08');").unwrap();
        let mut config: Config=serde_json::from_value(json!({"home":"/sample","helper":"/sample/digup","index":"/sample/unit-index","models":"/sample/models"})).unwrap();
        let read = |sql: String| -> Vec<Vec<u8>> {
            db.prepare(&sql)
                .unwrap()
                .query_map([], |r| r.get(4))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            read(vector_columns(&config, None, None)),
            vec![vec![1], vec![2], vec![3], vec![4]]
        );
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![2], vec![4]]
        );
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Text]);
        assert_eq!(
            read(vector_columns(&config, None, None)),
            vec![vec![1], vec![3]]
        );
        assert_eq!(read(vector_columns(&config, Some(7), None)), vec![vec![7]]);
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Image]);
        assert_eq!(read(vector_columns(&config, Some(7), None)), vec![vec![2]]);
        config.semantic_modalities = Some(vec![]);
        assert!(read(vector_columns(&config, None, None)).is_empty());
        config.semantic_modalities = None;
        config.embedding = Some(
            serde_json::from_value(
                json!({"engine":"coreai","image_vectors":"coreai","runtime":audio_runtime}),
            )
            .unwrap(),
        );
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![4]]
        );
        db.execute("INSERT INTO vectors VALUES(7,2,X'09')", [])
            .unwrap();
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![9], vec![4]]
        );
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Image]);
        assert_eq!(read(vector_columns(&config, Some(7), None)), vec![vec![9]]);
        config.semantic_modalities = None;
        config.embedding = Some(
            serde_json::from_value(
                json!({"engine":"coreai","audio_vectors":"coreai","runtime":audio_runtime}),
            )
            .unwrap(),
        );
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![2]]
        );
        db.execute("INSERT INTO vectors VALUES(7,4,X'0A')", [])
            .unwrap();
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![2], vec![10]]
        );
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Audio]);
        assert_eq!(read(vector_columns(&config, Some(7), None)), vec![vec![10]]);
        config.semantic_modalities = None;
        db.execute("ALTER TABLE segments ADD COLUMN loc_end REAL", [])
            .unwrap();
        db.execute("INSERT INTO segments(id,file,modality,kind,loc,loc_end) VALUES(5,1,'video','clip',0,14)",[]).unwrap();
        db.execute("INSERT INTO vectors VALUES(7,5,X'0B')", [])
            .unwrap();
        let before = vector_columns(&config, Some(7), None);
        assert!(!read(before.clone()).contains(&vec![11]));
        config.embedding.as_mut().unwrap().video_clip_vectors = false;
        assert_eq!(before, vector_columns(&config, Some(7), None));
        config.embedding.as_mut().unwrap().video_clip_vectors = true;
        assert_eq!(
            read(vector_columns(&config, Some(7), None)),
            vec![vec![7], vec![2], vec![10], vec![11]]
        );
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Video]);
        assert_eq!(read(vector_columns(&config, Some(7), None)), vec![vec![11]]);
        config.semantic_modalities = None;
        db.execute("INSERT INTO files VALUES(2,'{}')", []).unwrap();
        db.execute("INSERT INTO segments(id,file,modality,kind,loc,vec) VALUES(6,2,'text','chunk',0,X'0C')", []).unwrap();
        db.execute("INSERT INTO vectors VALUES(7,6,X'0D')", [])
            .unwrap();
        assert_eq!(
            read(vector_columns(&config, Some(7), Some(&[2]))),
            vec![vec![13]]
        );
        assert_eq!(
            read(vector_columns(&config, None, Some(&[2]))),
            vec![vec![12]]
        );
        assert!(read(vector_columns(&config, Some(7), Some(&[]))).is_empty());
        assert_eq!(
            read(vector_columns(&config, Some(7), Some(&[1]))),
            vec![vec![7], vec![2], vec![10], vec![11]]
        );
        let rows = |sql: String| {
            let mut stmt = db.prepare(&sql).unwrap();
            let columns = stmt.column_count();
            stmt.query_map([], |row| {
                (0..columns)
                    .map(|i| row.get::<_, rusqlite::types::Value>(i))
                    .collect::<rusqlite::Result<Vec<_>>>()
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
        };
        for image in ["legacy", "coreai"] {
            for audio in ["legacy", "coreai"] {
                for clips in [false, true] {
                    config.embedding = Some(
                        serde_json::from_value(json!({
                            "engine":"coreai", "image_vectors":image,
                            "audio_vectors":audio, "video_clip_vectors":clips
                        }))
                        .unwrap(),
                    );
                    for modalities in [
                        None,
                        Some(vec![crate::scope::SemanticModality::Text]),
                        Some(vec![]),
                    ] {
                        config.semantic_modalities = modalities;
                        assert_eq!(
                            rows(vector_columns(&config, Some(7), None)),
                            rows(vector_columns(&config, Some(7), Some(&[1, 2])))
                        );
                    }
                }
            }
        }
        assert!(
            serde_json::from_value::<crate::scope::EmbeddingConfig>(
                json!({"audio_vectors":"unknown"})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<crate::scope::EmbeddingConfig>(
                json!({"image_vectors":"unknown"})
            )
            .is_err()
        );
        std::fs::remove_dir_all(&audio_runtime).unwrap();
        config.semantic_modalities = Some(vec![crate::scope::SemanticModality::Audio]);
        assert!(!config.coreai_audio_installed());
        assert!(read(vector_columns(&config, Some(7), None)).is_empty());
        assert!(read(vector_columns(&config, None, None)).is_empty());
    }

    #[test]
    fn audio_package_transitions_reload_vectors_without_database_changes() {
        let root = std::env::temp_dir().join(format!("audio-reload-{}", std::process::id()));
        std::fs::create_dir_all(root.join("runtime/audio.aimodel")).unwrap();
        std::fs::create_dir_all(root.join("runtime/audio-host")).unwrap();
        std::fs::write(
            root.join("runtime/manifest.json"),
            r#"{"audio_identity":{}}"#,
        )
        .unwrap();
        std::fs::write(root.join("runtime/audio-host/identity.json"), b"{}").unwrap();
        let model = root.join("runtime/audio.aimodel/main.mlirb");
        std::fs::write(&model, b"fixture").unwrap();
        let db = Connection::open(root.join("index.sqlite")).unwrap();
        db.execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);
            INSERT INTO meta VALUES('embedding_generation','1'),('active_embedding_model','coreai-eg2-v1');
            CREATE TABLE embedding_models(id INTEGER,key TEXT,build TEXT,state TEXT,storage TEXT,dim INTEGER,weights_sha256 TEXT);
            INSERT INTO embedding_models VALUES(2,'coreai-eg2-v1','test','active','vectors',768,'197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79');
            CREATE TABLE files(id INTEGER,path TEXT,kind TEXT,indexed_at REAL,mtime REAL,state TEXT,info TEXT);
            CREATE TABLE segments(id INTEGER,file INTEGER,modality TEXT,kind TEXT,loc REAL,vec BLOB,excerpt TEXT);
            CREATE TABLE vectors(model INTEGER,segment INTEGER,vec BLOB);").unwrap();
        db.execute(
            "INSERT INTO files VALUES(1,?1,'audio',1,1,'done','{}')",
            [root.join("retained.wav").to_str().unwrap()],
        )
        .unwrap();
        let mut vector = vec![0u8; DIM * 2];
        vector[1] = 0x3c;
        db.execute("INSERT INTO segments(id,file,modality,kind,loc,vec) VALUES(1,1,'image','image',NULL,?1),(2,1,'audio','audio',0,?1)", [vector]).unwrap();
        let config: Config = serde_json::from_value(json!({
            "home":root, "helper":"/must-not-launch", "index":root, "models":root,
            "embedding":{"engine":"coreai", "runtime":root.join("runtime"), "model_key":"coreai-eg2-v1"}
        })).unwrap();
        let mut search = SemanticSearch::new();
        search.reload(&config).unwrap();
        assert_eq!(search.rows(), 2);
        assert!(search.encoder.is_none());
        let version = search.version;
        std::fs::remove_file(&model).unwrap();
        search.reload(&config).unwrap();
        assert_eq!(search.version, version);
        assert_eq!(
            search.rows(),
            1,
            "removed audio package must drop cached audio rows"
        );
        assert_eq!(search.row_modality, [1]);
        std::fs::write(&model, b"fixture").unwrap();
        search.reload(&config).unwrap();
        assert_eq!(search.version, version);
        assert_eq!(
            search.rows(),
            2,
            "new audio package must reload retained audio rows"
        );
        assert!(search.encoder.is_none());
        std::fs::remove_file(&model).unwrap();
        std::fs::write(root.join("runtime/manifest.json"),
            r#"{"storage_layout":"single-model-v2","audio_identity":{},"production_assets":[{"path":"EmbeddingGemma2.aimodel"}]}"#).unwrap();
        assert!(config.coreai_audio_installed(), "audio remains installed after single-source deletion");
        search.reload(&config).unwrap();
        assert_eq!(search.rows(), 2);
        drop(search);
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn tags_confirm_pictures_only_for_words_they_could_show() {
        let mut search = SemanticSearch::new();
        let picture = |path: &str, tags: &str| Loaded {
            path: path.into(),
            kind: "screenshot".into(),
            stamp: 0.,
            mtime: 0.,
            tags: tag_words(tags).collect(),
        };
        search.files.insert(1, picture("field.png", "blue, red"));
        search
            .files
            .insert(2, picture("mobile.png", "white, document, screenshot"));
        search
            .files
            .insert(3, picture("park.jpg", "green, outdoor, dogs, grass"));
        search
            .files
            .insert(4, picture("cafe.png", "brown, people, restaurant"));
        search.tag_vocabulary = search
            .files
            .values()
            .flat_map(|f| f.tags.iter().cloned())
            .collect();
        assert_eq!(search.confirmed("red and blue screenshot"), [1].into());
        assert_eq!(search.confirmed("Red Blue"), [1].into());
        assert_eq!(search.confirmed("photo of a dog"), [3].into());
        // "screenshot" is a kind of file, not something seen in one; "lab" is in no picture's tags.
        assert!(search.confirmed("screenshot").is_empty());
        assert!(
            search
                .confirmed("equipotential lines lab measurement")
                .is_empty()
        );
        assert!(search.confirmed("red and green").is_empty());
        assert!(search.confirmed("receipt from a restaurant").is_empty());
        assert_eq!(search.confirmed("people in a restaurant"), [4].into());
        assert_eq!(search.confirmed("dog on green grass outdoors"), [3].into());
    }

    #[test]
    fn eight_bit_scores_match_float_cosines() {
        let unit = |seed: u32| {
            let mut x = seed;
            let v: Vec<f32> = (0..DIM)
                .map(|_| {
                    x = x.wrapping_mul(1664525).wrapping_add(1013904223);
                    (x >> 8) as f32 / (1u32 << 24) as f32 - 0.5
                })
                .collect();
            let n = v.iter().map(|a| a * a).sum::<f32>().sqrt();
            v.into_iter().map(|a| a / n).collect::<Vec<_>>()
        };
        let query = unit(7);
        let rows: Vec<Vec<f32>> = (1..40).map(unit).collect();
        let mut codes = vec![];
        let scales: Vec<f32> = rows.iter().map(|r| quantize(r, &mut codes)).collect();
        let mut q = vec![];
        let qs = quantize(&query, &mut q);
        let mut dots = vec![0; rows.len()];
        dot_rows(&codes, &q, &mut dots);
        for (i, row) in rows.iter().enumerate() {
            let exact: f32 = row.iter().zip(&query).map(|(a, b)| a * b).sum();
            let approx = dots[i] as f32 * scales[i] * qs;
            assert!((exact - approx).abs() < 0.003, "{exact} {approx}");
        }
    }

    #[test]
    fn keyword_words_drop_stop_words_and_short_prefixes() {
        assert_eq!(
            keywords("growth rates of logs and the exponentials"),
            ["growth", "rates", "logs", "exponentials"]
        );
        assert_eq!(keywords("the who"), ["who"]);
        assert_eq!(keywords("to be or not"), ["to", "be", "or", "not"]);
        assert_eq!(keywords("Tax tax return"), ["tax", "return"]);
        assert_eq!(term("s"), "\"s\"");
        assert_eq!(term("tur"), "\"tur\"*");
    }

    #[test]
    fn meaning_centres_each_modality_and_ignores_unscaled_rows() {
        // Text sits higher than images for every query; the best image should stand out as far as the best text.
        let mut scores = vec![];
        let mut modality = vec![];
        for i in 0..40 {
            scores.push(0.60 + (i % 5) as f32 * 0.001);
            modality.push(0);
            scores.push(0.50 + (i % 5) as f32 * 0.001);
            modality.push(1);
        }
        scores.extend([0.70, 0.60, 0.99]);
        modality.extend([0, 1, 0]);
        let z = meaning(&scores, &modality, |row| row < 82);
        assert!((z[80] - z[81]).abs() < 0.01, "{} {}", z[80], z[81]);
        assert!(z[80] > 3., "{}", z[80]);
        // The last row is scored on the scale without moving it.
        assert!(z[82] > z[80]);
    }
}
