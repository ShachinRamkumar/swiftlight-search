mod fast;
mod indexing;
mod load;
mod scope;
mod semantic;
mod watch;

use scope::Config;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::{HashMap, hash_map::Entry},
    io::{BufRead, Write},
    path::Path,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const QOS_CLASS_USER_INITIATED: u32 = 0x19;
const MEANING_PAUSE: Duration = Duration::from_millis(25);

fn meaning_pause(text: &str, started: Instant, previous: Option<&Job>) -> Duration {
    if text.ends_with(char::is_whitespace) {
        return Duration::ZERO;
    }
    if let Some(previous) = previous {
        let interval = started.saturating_duration_since(previous.started);
        if text.len() > previous.text.len()
            && text.starts_with(&previous.text)
            && interval < Duration::from_millis(80)
        {
            return MEANING_PAUSE.max(interval.mul_f64(1.1).min(Duration::from_millis(32)));
        }
    }
    MEANING_PAUSE
}

unsafe extern "C" {
    fn pthread_set_qos_class_self_np(class: u32, relative_priority: i32) -> i32;
}

fn interactive_priority() {
    let status = unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) };
    if status != 0 {
        eprintln!("search QoS request failed: {status}");
    }
}
/// How far a file's meaning rises, in deviations, when its content also holds every word of the query: the words
/// confirm it, as a picture's tags do (`semantic::CONFIRMED_LIFT`). Counting them as evidence of their own let notes
/// that merely mention "divide", "conquer" and "lecture" pass the lecture itself.
const KEYWORD_LIFT: f64 = 1.0;
/// How much a file found by name rises when its content was found too.
const NAME_AND_CONTENT: f64 = 10.;

#[derive(Clone, Debug, Default, Serialize)]
pub struct Hit {
    pub path: String,
    pub title: String,
    pub kind: String,
    pub source: String,
    pub rank: f64,
    pub category: String,
    pub cosine: Option<f32>,
    /// What a content hit stands on, in deviations of meaning (`semantic::meaning`): how far meaning set the file
    /// apart, or what finding its words stands for.
    #[serde(skip)]
    pub evidence: f64,
    /// A content hit's rank at no evidence (`semantic::content_base`).
    #[serde(skip)]
    pub base: f64,
    /// Seen but not shown on its own: meaning below its gate, or words missing from a long query. The other signal
    /// finding the same file shows it, unless that one is weak too.
    #[serde(skip)]
    pub weak: bool,
    /// For a keyword hit: the share of the query's words the file holds.
    #[serde(skip)]
    pub coverage: f64,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Query {
        generation: u64,
        text: String,
    },
    Cycle {
        generation: u64,
        delta: i32,
    },
    Open {
        generation: u64,
    },
    /// The launcher opened this result itself; record it for ranking. Nothing is emitted.
    Opened {
        #[allow(dead_code)]
        generation: u64,
        path: String,
    },
    /// Pins a listed result; no path releases the pin so the top hit is selected again.
    Select {
        generation: u64,
        path: Option<String>,
    },
    /// The pill was shown (true) or hidden (false).
    Active {
        value: bool,
    },
    PanelOpened,
    PanelClosed,
    Status,
    Quit,
}
#[derive(Clone)]
struct Job {
    generation: u64,
    text: String,
    started: Instant,
    /// Load the query model and vectors ahead of typing; produces no results.
    warm: bool,
}
#[derive(Default)]
struct Pending {
    query: Option<Job>,
    preparation: Option<Job>,
}
#[derive(Default)]
struct Mailbox {
    pending: Mutex<Pending>,
    wake: Condvar,
    prepare_on_query: bool,
    panel_visible: AtomicBool,
    visibility_changed: AtomicBool,
}
impl Mailbox {
    fn set_panel_visible(&self, visible: bool) {
        self.panel_visible.store(visible, Ordering::Release);
        self.visibility_changed.store(true, Ordering::Release);
        if !visible {
            let mut slot = self.pending.lock().unwrap();
            slot.preparation = None;
            slot.query = None;
        }
        self.wake.notify_one();
    }
    fn set(&self, job: Job) {
        let mut slot = self.pending.lock().unwrap();
        if self.prepare_on_query {
            let mut preparation = job.clone();
            preparation.warm = true;
            slot.preparation.get_or_insert(preparation);
        }
        slot.query = Some(job);
        self.wake.notify_one();
    }
    /// Preparation coalesces separately from the latest replaceable query.
    fn offer(&self, job: Job) {
        let mut slot = self.pending.lock().unwrap();
        slot.query.get_or_insert(job);
        self.wake.notify_one();
    }
    fn prepare(&self, job: Job) {
        self.pending.lock().unwrap().preparation.get_or_insert(job);
        self.wake.notify_one();
    }
    fn take(&self, stop: &AtomicBool, limit: Option<Duration>) -> Option<Job> {
        let deadline = limit.map(|l| Instant::now() + l);
        let mut slot = self.pending.lock().unwrap();
        while slot.query.is_none()
            && slot.preparation.is_none()
            && !stop.load(Ordering::Acquire)
            && !self.visibility_changed.load(Ordering::Acquire)
        {
            match deadline {
                None => slot = self.wake.wait(slot).unwrap(),
                Some(deadline) => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        break;
                    }
                    slot = self.wake.wait_timeout(slot, left).unwrap().0;
                }
            }
        }
        slot.preparation.take().or_else(|| slot.query.take())
    }
    fn idle(&self) -> bool {
        let slot = self.pending.lock().unwrap();
        slot.query.is_none() && slot.preparation.is_none()
    }
    /// Preparation never supersedes a query waiting out its typing pause.
    fn newer_before(&self, stop: &AtomicBool, deadline: Instant) -> bool {
        let mut slot = self.pending.lock().unwrap();
        while slot.query.is_none() && !stop.load(Ordering::Acquire) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            slot = self.wake.wait_timeout(slot, left).unwrap().0;
        }
        slot.query.is_some()
    }
}
#[derive(Clone, Copy, PartialEq, Debug)]
enum Source {
    Names,
    Keyword,
    Meaning,
}
impl Source {
    fn phase(self) -> &'static str {
        match self {
            Source::Names => "fast",
            Source::Keyword => "keyword",
            Source::Meaning => "semantic",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Source::Names => "fsearch",
            Source::Keyword => "keyword",
            Source::Meaning => "semantic",
        }
    }
}
enum Message {
    ModelChanged,
    Input(Request),
    Error(String),
    Found {
        job: Job,
        source: Source,
        hits: Vec<Hit>,
        error: Option<String>,
        model_generation: Option<i64>,
    },
}
fn emit(value: Value) -> bool {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    writeln!(out, "{value}").and_then(|_| out.flush()).is_ok()
}
/// What the latest query has found so far, by source.
#[derive(Default)]
struct Found {
    names: Vec<Hit>,
    keyword: Vec<Hit>,
    meaning: Vec<Hit>,
    /// Sources that have answered, one bit each: the list is final once all three have, in whatever order.
    answered: u8,
}
impl Found {
    fn clear(&mut self) {
        self.names.clear();
        self.keyword.clear();
        self.meaning.clear();
        self.answered = 0;
    }
    fn complete(&self) -> bool {
        self.answered == 0b111
    }
    /// A single word that matches no file name or indexed text is almost always a typo or nonsense. Its
    /// nearest-neighbour meaning matches score in the same cosine range as genuine ones, so they are shown only
    /// alongside a literal match or for queries of two or more words.
    #[cfg(test)]
    fn merged(&self, text: &str) -> Vec<Hit> {
        self.merged_for(text, false)
    }
    fn merged_for(&self, text: &str, deterministic: bool) -> Vec<Hit> {
        let literal = !self.names.is_empty() || self.keyword.iter().any(|h| !h.weak);
        let meaning: &[Hit] = if literal || text.split_whitespace().count() >= 2 {
            &self.meaning
        } else {
            &[]
        };
        merge_ordered(&self.names, &self.keyword, meaning, deterministic)
    }
}
/// One list from the three searches. A file found by meaning and by its words is one content hit: its meaning, lifted
/// by the share of the words it holds (`KEYWORD_LIFT`). A weak match of either kind shows beside a strong one of the
/// other, or beside a weak one when the two together pass the meaning gate (a long query in other words than the file
/// uses: its meaning stands 4.0–4.3 out, its words are two thirds there); a file found by its words alone sits just
/// below the gate (`semantic::keyword`). A file found by
/// name and by content keeps the better rank and rises a little.
#[cfg(test)]
fn merge(names: &[Hit], keyword: &[Hit], meaning: &[Hit]) -> Vec<Hit> {
    merge_ordered(names, keyword, meaning, false)
}
fn merge_ordered(names: &[Hit], keyword: &[Hit], meaning: &[Hit], deterministic: bool) -> Vec<Hit> {
    // Meaning and keyword hits come from the same index, so the same file has the same path in both.
    let mut by_path: HashMap<&str, (Option<&Hit>, Option<&Hit>)> = HashMap::new();
    for hit in meaning {
        let entry = by_path.entry(&hit.path).or_default();
        if entry.0.is_none_or(|old| old.evidence < hit.evidence) {
            entry.0 = Some(hit);
        }
    }
    for hit in keyword {
        let entry = by_path.entry(&hit.path).or_default();
        if entry.1.is_none_or(|old| old.evidence < hit.evidence) {
            entry.1 = Some(hit);
        }
    }
    let mut content = vec![];
    for (meant, worded) in by_path.into_values() {
        let shown = match (meant, worded) {
            (Some(m), Some(k))
                if !(m.weak && k.weak)
                    || m.evidence + KEYWORD_LIFT * k.coverage >= semantic::Z_GATE =>
            {
                let lifted = m.evidence + KEYWORD_LIFT * k.coverage;
                let evidence = if k.weak {
                    lifted
                } else {
                    lifted.max(k.evidence)
                };
                Some(Hit {
                    rank: m.base + 4. * evidence,
                    evidence,
                    weak: false,
                    ..m.clone()
                })
            }
            (Some(h), None) | (None, Some(h)) if !h.weak => Some(h.clone()),
            _ => None,
        };
        content.extend(shown);
    }
    if deterministic {
        let mut tied: HashMap<(String, u64), Hit> = HashMap::new();
        for hit in &content {
            let key = (identity(&hit.path), hit.rank.to_bits());
            let canonical = tied.entry(key).or_insert_with(|| hit.clone());
            if hit.path < canonical.path {
                *canonical = hit.clone();
            }
        }
        for hit in &mut content {
            *hit = tied[&(identity(&hit.path), hit.rank.to_bits())].clone();
        }
    }
    let mut unique: HashMap<String, Hit> = HashMap::new();
    for hit in names {
        let key = identity(&hit.path);
        if unique.get(&key).is_none_or(|old| old.rank < hit.rank) {
            unique.insert(key, hit.clone());
        }
    }
    for hit in content {
        match unique.entry(identity(&hit.path)) {
            Entry::Occupied(mut named) => {
                let named = named.get_mut();
                if hit.rank > named.rank {
                    *named = hit;
                }
                named.rank += NAME_AND_CONTENT;
            }
            Entry::Vacant(slot) => {
                slot.insert(hit);
            }
        }
    }
    let mut hits: Vec<_> = unique.into_values().collect();
    sort(&mut hits);
    let mut hits = collapse_copies(hits);
    sort(&mut hits);
    hits.truncate(20);
    hits
}
fn sort(hits: &mut [Hit]) {
    hits.sort_by(|a, b| {
        b.rank
            .total_cmp(&a.rank)
            .then_with(|| a.title.len().cmp(&b.title.len()))
            .then_with(|| a.path.cmp(&b.path))
    });
}
/// Content found by meaning or keywords often comes back once per copy: a course PDF with its extracted .txt and .json
/// beside it, or a backup folder holding the same file. One row stands for the group: the most original format, then
/// the better-ranked one, at the group's best rank. Name matches never fold into each other, since a search by name
/// may be after one particular copy.
fn collapse_copies(hits: Vec<Hit>) -> Vec<Hit> {
    let content = |hit: &Hit| matches!(hit.category.as_str(), "meaning" | "content");
    let mut kept: Vec<Hit> = vec![];
    for hit in hits {
        let copy = kept
            .iter()
            .position(|other| (content(&hit) || content(other)) && copies(&hit.path, &other.path));
        match copy {
            None => kept.push(hit),
            Some(i) => {
                let rank = kept[i].rank.max(hit.rank);
                if originality(&hit.path) > originality(&kept[i].path) {
                    kept[i] = hit;
                }
                kept[i].rank = rank;
            }
        }
    }
    kept
}
/// The same file twice: the same name and size anywhere, or the same name before the extension in the same or a
/// neighbouring folder (resources/ beside resources/text/, extracted/ and the like).
fn copies(a: &str, b: &str) -> bool {
    let (a, b) = (Path::new(a), Path::new(b));
    if a.file_name() == b.file_name() {
        return file_size(a).is_some_and(|size| Some(size) == file_size(b));
    }
    let stem = |p: &Path| p.file_stem().map(|s| s.to_string_lossy().to_lowercase());
    if stem(a).is_none_or(|s| s.chars().count() < 4) || stem(a) != stem(b) {
        return false;
    }
    let (da, db) = (a.parent(), b.parent());
    da == db
        || da.and_then(Path::parent) == db
        || db.and_then(Path::parent) == da
        || da.and_then(Path::parent) == db.and_then(Path::parent)
}
fn file_size(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.len())
}
/// Which copy of a document to show: what someone made or received over text pulled out of it.
fn originality(path: &str) -> u8 {
    let ext = Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "json" | "jsonl" | "csv" | "tsv" | "xml" => 0,
        "txt" | "text" => 1,
        "md" | "markdown" | "html" | "htm" => 2,
        _ => 3,
    }
}
thread_local! {
    static IDENTITIES: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
    static LAST_RESULTS: RefCell<Option<(u64, Value)>> = const { RefCell::new(None) };
}
/// Canonical path used to merge the same file found by name and by content. Cached: results are
/// re-merged on every phase, cycle and selection, and canonicalize costs filesystem calls.
fn identity(path: &str) -> String {
    IDENTITIES.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(found) = cache.get(path) {
            return found.clone();
        }
        if cache.len() > 4096 {
            cache.clear();
        }
        let canonical = std::fs::canonicalize(path)
            .unwrap_or_else(|_| path.into())
            .to_string_lossy()
            .into_owned();
        cache.insert(path.into(), canonical.clone());
        canonical
    })
}
fn results(
    query: (u64, &str),
    hits: &[Hit],
    selected: &mut Option<String>,
    pinned: bool,
    phase: &str,
    complete: bool,
    elapsed: Duration,
) -> bool {
    let chosen = selected.as_ref().map(|s| identity(s));
    if pinned && let Some(hit) = hits.iter().find(|h| Some(identity(&h.path)) == chosen) {
        *selected = Some(hit.path.clone());
    } else {
        *selected = hits.first().map(|h| h.path.clone());
    }
    let list = json!(hits);
    let unchanged = LAST_RESULTS.with(|last| {
        let mut last = last.borrow_mut();
        if phase == "pending" {
            return true;
        }
        let unchanged = last
            .as_ref()
            .is_some_and(|(generation, previous)| *generation == query.0 && *previous == list);
        *last = Some((query.0, list.clone()));
        unchanged
    });
    let mut event = json!({"event":if unchanged {"progress"} else {"results"},"generation":query.0,"text":query.1,"phase":phase,"complete":complete,"selected":selected,"elapsed_ms":elapsed.as_secs_f64()*1000.});
    if !unchanged {
        event["hits"] = list;
    }
    emit(event)
}
/// Whether a worker's job is still the one to answer.
#[derive(Clone)]
struct Current {
    latest: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
    generation: u64,
}
impl Current {
    fn get(&self) -> bool {
        self.latest.load(Ordering::Acquire) == self.generation && !self.stop.load(Ordering::Acquire)
    }
}
fn worker(
    source: Source,
    config: Config,
    mailbox: Arc<Mailbox>,
    stop: Arc<AtomicBool>,
    latest: Arc<AtomicU64>,
    tx: mpsc::Sender<Message>,
) {
    interactive_priority();
    let mut names = fast::FastSearch::new();
    let mut keywords = semantic::Keyword::default();
    let mut meaning = semantic::SemanticSearch::new();
    let mut pending: Option<Job> = None;
    let mut preparation_reported: Option<u64> = None;
    let mut previous_query: Option<Job> = None;
    // Set while the query model is held back because the Mac is busy, so the log says so once, not per keystroke.
    let mut held_back: Option<String> = None;
    let mut model_blocked = |meaning: &semantic::SemanticSearch| -> bool {
        if meaning.holds_model() {
            return false;
        }
        let reason = load::Load::now().query_model_blocked();
        match (&reason, &held_back) {
            (Some(r), None) => {
                eprintln!("query model held back: {r}; searching names and words only")
            }
            (None, Some(_)) => eprintln!("query model allowed again"),
            _ => (),
        }
        held_back = reason;
        held_back.is_some()
    };
    while !stop.load(Ordering::Acquire) {
        if source == Source::Meaning
            && mailbox.visibility_changed.swap(false, Ordering::AcqRel)
            && !mailbox.panel_visible.load(Ordering::Acquire)
        {
            meaning.panel_closed();
            pending = None;
        }
        // The query model's residency follows the panel: loaded on open, released on close.
        let Some(job) = pending.take().or_else(|| mailbox.take(&stop, None)) else {
            continue;
        };
        if job.warm {
            match source {
                Source::Meaning => {
                    if (config.coreai().is_some() || !meaning.holds_model())
                        && !model_blocked(&meaning)
                        && let Err(e) = meaning.prewarm(&config, None)
                    {
                        eprintln!("semantic prewarm: {e}");
                    }
                }
                Source::Names => names.warm(&config),
                Source::Keyword => (),
            }
            continue;
        }
        let current = Current {
            latest: latest.clone(),
            stop: stop.clone(),
            generation: job.generation,
        };
        if job.text.trim().is_empty() || !current.get() {
            continue;
        }
        if source == Source::Meaning {
            // A busy Mac answers by names and words alone: meaning answers with nothing rather than load the model.
            if job.text.trim().chars().count() > 2 && model_blocked(&meaning) {
                let found = Message::Found {
                    job,
                    source,
                    hits: vec![],
                    error: None,
                    model_generation: None,
                };
                if tx.send(found).is_err() {
                    break;
                }
                continue;
            }
            if !meaning.holds_model()
                && job.text.trim().chars().count() > 2
                && let Err(e) = meaning.prewarm(&config, Some(&job.text))
            {
                eprintln!("semantic prewarm: {e}");
            }
            let pause = meaning_pause(&job.text, job.started, previous_query.as_ref());
            previous_query = Some(job.clone());
            let pause_started = Instant::now();
            if mailbox.newer_before(&stop, job.started + pause) {
                continue;
            }
            if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
                eprintln!(
                    "SEMANTIC_DEBOUNCE pause_ms={:.2} waited_ms={:.2} since_key_ms={:.2}",
                    pause.as_secs_f64() * 1e3,
                    pause_started.elapsed().as_secs_f64() * 1e3,
                    job.started.elapsed().as_secs_f64() * 1e3
                );
            }
        }
        if !current.get() {
            continue;
        }
        let check = current.clone();
        let result = match source {
            Source::Names => names.search(&config, &job.text, move || check.get()),
            Source::Keyword => keywords.search(&config, &job.text, move || check.get()),
            Source::Meaning if job.text.trim().chars().count() <= 2 => Ok(vec![]),
            Source::Meaning => meaning.search(&config, &job.text, move || check.get()),
        };
        if !current.get() {
            continue;
        }
        let preparing = source == Source::Meaning
            && result
                .as_ref()
                .err()
                .is_some_and(|e| e.contains("coreai readiness pending"));
        let retry = preparing.then(|| job.clone());
        let silent = preparing && preparation_reported == Some(job.generation);
        preparation_reported = preparing.then_some(job.generation);
        let (hits, error) = match result {
            Ok(h) => (h, None),
            Err(e) => (vec![], Some(e)),
        };
        let model_generation = (source == Source::Meaning
            && config.coreai().is_some()
            && job.text.trim().chars().count() > 2)
            .then(|| meaning.generation());
        if !silent
            && tx
                .send(Message::Found {
                    job,
                    source,
                    hits,
                    error,
                    model_generation,
                })
                .is_err()
        {
            break;
        }
        if let Some(job) = retry {
            let interval = if job.started.elapsed() < Duration::from_secs(1) {
                25
            } else {
                250
            };
            if !mailbox.newer_before(&stop, Instant::now() + Duration::from_millis(interval))
                && current.get()
            {
                pending = Some(job);
            }
        }
        if source == Source::Names && mailbox.idle() {
            names.maintain(&config);
        }
    }
}
fn prepare_on_open(config: &Config, mailbox: &Mailbox, generation: u64) {
    if config.coreai().is_some() {
        mailbox.prepare(Job {
            generation,
            text: String::new(),
            started: Instant::now(),
            warm: true,
        });
    }
}

fn run() -> Result<(), String> {
    interactive_priority();
    load::init_memory_monitor();
    let config = Config::load()?;
    if !config.home.is_absolute() || !config.index.is_absolute() {
        return Err("configuration paths must be absolute".into());
    }
    std::fs::create_dir_all(&config.index).map_err(|e| e.to_string())?;
    // The UI can terminate this owned process group, including model/index helpers.
    unsafe {
        libc::setpgid(0, 0);
    }
    let stop = Arc::new(AtomicBool::new(false));
    let latest = Arc::new(AtomicU64::new(0));
    let (tx, rx) = mpsc::channel();
    let model_watch = std::cell::OnceCell::new();
    let input = tx.clone();
    let newest_input = latest.clone();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let parsed = line.map_err(|e| e.to_string()).and_then(|s| {
                if s.len() > 16384 {
                    Err("request too large".into())
                } else {
                    serde_json::from_str::<Request>(&s).map_err(|e| e.to_string())
                }
            });
            let message = match parsed {
                Ok(r) => {
                    if let Request::Query { generation, text } = &r
                        && text.len() <= 4096
                    {
                        newest_input.fetch_max(*generation, Ordering::AcqRel);
                    }
                    Message::Input(r)
                }
                Err(e) => Message::Error(e),
            };
            if input.send(message).is_err() {
                return;
            }
        }
        let _ = input.send(Message::Input(Request::Quit));
    });
    let mut threads = vec![];
    let mut mailboxes = vec![];
    // Each search has its own thread, so a slow one never holds back another: names answer in milliseconds whatever
    // the keyword index or the model is doing.
    for source in [Source::Names, Source::Keyword, Source::Meaning] {
        let mailbox = Arc::new(Mailbox {
            prepare_on_query: source == Source::Meaning && config.coreai().is_some(),
            ..Mailbox::default()
        });
        mailboxes.push(mailbox.clone());
        let (config, stop, latest, tx) = (config.clone(), stop.clone(), latest.clone(), tx.clone());
        threads.push(
            std::thread::Builder::new()
                .name(source.label().into())
                .spawn(move || worker(source, config, mailbox, stop, latest, tx))
                .map_err(|e| e.to_string())?,
        );
    }
    let (names_box, meaning_box) = (mailboxes[0].clone(), mailboxes[2].clone());
    // The app list and open history cost one FSearch query each (110 ms cold): read them now, so even the first
    // keystroke after launch finds them. The query model waits for the panel (it holds 300 MB).
    names_box.offer(Job {
        generation: 0,
        text: String::new(),
        started: Instant::now(),
        warm: true,
    });
    let indexer = Arc::new(indexing::Control::new(config.cooperative_pause()));
    if config.auto_index {
        let scope = config.clone();
        let stopped = stop.clone();
        let control = indexer.clone();
        threads.push(std::thread::spawn(move || {
            indexing::supervise(scope, stopped, control)
        }));
    }
    emit(
        json!({"event":"ready","backend":"rust","model":"google/embeddinggemma-2","scope":"visible home files","auto_index":config.auto_index}),
    );
    let mut generation = 0;
    let mut text = String::new();
    let mut found = Found::default();
    let mut selected: Option<String> = None;
    let mut pinned = false;
    let mut started = Instant::now();
    let mut active = false;
    let mut catalog = semantic::ModelCatalog::default();
    let mut observed_model_generation = catalog.generation(&config);
    loop {
        let message = match indexer.next_deadline() {
            Some(deadline) => {
                match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                    Ok(message) => message,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        indexer.tick();
                        continue;
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            None => match rx.recv() {
                Ok(message) => message,
                Err(_) => break,
            },
        };
        indexer.tick();
        if matches!(message, Message::ModelChanged) && active && !text.is_empty() {
            let now = catalog.generation(&config);
            if now.is_some() && now != observed_model_generation {
                observed_model_generation = now;
                found.meaning.clear();
                found.answered &= !(1 << Source::Meaning as u8);
                meaning_box.offer(Job {
                    generation,
                    text: text.clone(),
                    started,
                    warm: false,
                });
                if !results(
                    (generation, &text),
                    &found.merged_for(&text, catalog.selected_config(&config).coreai().is_some()),
                    &mut selected,
                    pinned,
                    "semantic",
                    false,
                    started.elapsed(),
                ) {
                    break;
                }
            }
        }
        match message {
            Message::Input(Request::Quit) => break,
            Message::Input(Request::Status) => {
                emit(
                    json!({"event":"status","generation":generation,"text":text,"selected":selected,"models_installed":catalog.selected_config(&config).models_installed(),"index_exists":config.index.join("index.sqlite").exists()}),
                );
            }
            Message::Input(Request::Query {
                generation: g,
                text: q,
            }) => {
                if g <= generation || q.len() > 4096 {
                    continue;
                }
                indexer.query();
                generation = g;
                text = q;
                started = Instant::now();
                observed_model_generation = catalog.generation(&config);
                if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
                    eprintln!(
                        "QUERY_DISPATCH metadata_ms={:.3}",
                        started.elapsed().as_secs_f64() * 1e3
                    );
                }
                selected = None;
                pinned = false;
                found.clear();
                latest.fetch_max(g, Ordering::AcqRel);
                let job = Job {
                    generation: g,
                    text: text.clone(),
                    started,
                    warm: false,
                };
                for mailbox in &mailboxes {
                    mailbox.set(job.clone());
                }
                if !results(
                    (g, &text),
                    &[],
                    &mut selected,
                    false,
                    "pending",
                    false,
                    Duration::ZERO,
                ) {
                    break;
                }
            }
            Message::Input(Request::Active { value }) => {
                // While the pill is up the indexer yields the CPU, GPU and disk to search.
                indexer.active(value);
                active = value;
                if !value && config.coreai().is_some() {
                    meaning_box.set_panel_visible(false);
                }
                if value {
                    let warm = Job {
                        generation,
                        text: String::new(),
                        started: Instant::now(),
                        warm: true,
                    };
                    names_box.offer(warm.clone());
                    if config.coreai().is_none() {
                        meaning_box.offer(warm);
                    }
                }
            }
            Message::Input(Request::PanelOpened) => {
                meaning_box.set_panel_visible(true);
                prepare_on_open(&config, &meaning_box, generation);
            }
            Message::Input(Request::PanelClosed) => {
                meaning_box.set_panel_visible(false);
            }
            Message::Input(Request::Cycle {
                generation: g,
                delta,
            }) if g == generation => {
                let hits =
                    found.merged_for(&text, catalog.selected_config(&config).coreai().is_some());
                if !hits.is_empty() {
                    let index = hits
                        .iter()
                        .position(|h| Some(&h.path) == selected.as_ref())
                        .unwrap_or(0) as i64;
                    selected = Some(
                        hits[(index + delta as i64).rem_euclid(hits.len() as i64) as usize]
                            .path
                            .clone(),
                    );
                    pinned = true;
                    if !results(
                        (g, &text),
                        &hits,
                        &mut selected,
                        true,
                        "selected",
                        found.complete(),
                        started.elapsed(),
                    ) {
                        break;
                    }
                }
            }
            Message::Input(Request::Select {
                generation: g,
                path,
            }) if g == generation => {
                let hits =
                    found.merged_for(&text, catalog.selected_config(&config).coreai().is_some());
                let listed = path
                    .as_ref()
                    .is_none_or(|path| hits.iter().any(|hit| &hit.path == path));
                if listed {
                    pinned = path.is_some();
                    selected = path;
                    if !results(
                        (g, &text),
                        &hits,
                        &mut selected,
                        pinned,
                        "selected",
                        found.complete(),
                        started.elapsed(),
                    ) {
                        break;
                    }
                }
            }
            Message::Input(Request::Open { generation: g }) if g == generation => {
                if let Some(path) = selected.as_ref() {
                    if config.fast_allowed(Path::new(path))
                        || config.semantic_allowed(Path::new(path))
                    {
                        if !emit(json!({"event":"open","generation":g,"path":path})) {
                            break;
                        }
                        // Verification runs suppress the actual open; they must not train ranking.
                        if std::env::var_os("SPOTLIGHT_VERIFY").is_none_or(|v| v != "1") {
                            let (config, path) = (config.clone(), path.clone());
                            std::thread::spawn(move || fast::notify_open(&config, &path));
                        }
                    } else {
                        emit(
                            json!({"event":"diagnostic","message":"selected file moved or left the approved scope"}),
                        );
                    }
                }
            }
            Message::Input(Request::Opened { path, .. }) => {
                // The open already happened in the launcher, whatever query is current by now; only paths in scope
                // train ranking, and verification runs never do.
                if (config.fast_allowed(Path::new(&path)) || config.semantic_allowed(Path::new(&path)))
                    && std::env::var_os("SPOTLIGHT_VERIFY").is_none_or(|v| v != "1")
                {
                    let config = config.clone();
                    std::thread::spawn(move || fast::notify_open(&config, &path));
                }
            }
            Message::Found {
                job,
                source,
                mut hits,
                mut error,
                model_generation,
            } if job.generation == generation => {
                let received = Instant::now();
                if model_generation.is_some_and(|g| catalog.generation(&config) != Some(g)) {
                    hits.clear();
                    let retry = error
                        .as_ref()
                        .is_none_or(|e| e.contains("embedding generation changed"));
                    if error.is_none() {
                        error = Some("embedding generation changed; late result rejected".into());
                    }
                    if source == Source::Meaning && retry {
                        meaning_box.offer(job.clone());
                    }
                }
                let validated = Instant::now();
                let semantic_succeeded = error.is_none();
                if let Some(error) = error {
                    eprintln!("{}: {error}", source.label());
                    emit(
                        json!({"event":"diagnostic","generation":generation,"source":source.label(),"message":error}),
                    );
                }
                match source {
                    Source::Names => found.names = hits,
                    Source::Keyword => found.keyword = hits,
                    Source::Meaning => found.meaning = hits,
                }
                found.answered |= 1 << source as u8;
                let merged =
                    found.merged_for(&text, catalog.selected_config(&config).coreai().is_some());
                let waiting_for_keyword = source == Source::Names
                    && merged.is_empty()
                    && found.answered & (1 << Source::Keyword as u8) == 0;
                let fused = Instant::now();
                if waiting_for_keyword {
                    emit(
                        json!({"event":"progress","generation":generation,"text":text,"phase":source.phase(),"complete":false,"selected":selected,"elapsed_ms":started.elapsed().as_secs_f64()*1000.}),
                    );
                    continue;
                }
                if !results(
                    (generation, &text),
                    &merged,
                    &mut selected,
                    pinned,
                    source.phase(),
                    found.complete(),
                    started.elapsed(),
                ) {
                    break;
                }
                if source == Source::Meaning && model_generation.is_some() && semantic_succeeded {
                    model_watch.get_or_init(|| {
                        let watch_started = Instant::now();
                        let changes = tx.clone();
                        let watcher =
                            watch::Watcher::start_with_latency(&config.index, 0.0, move |path| {
                                if path.is_none_or(|p| {
                                    matches!(
                                        p.file_name().and_then(|n| n.to_str()),
                                        Some("index.sqlite" | "index.sqlite-wal")
                                    )
                                }) {
                                    let _ = changes.send(Message::ModelChanged);
                                }
                            });
                        // Recheck once after subscribing so changes between delivery and setup are not missed.
                        let _ = tx.send(Message::ModelChanged);
                        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
                            eprintln!(
                                "INDEX_WATCH after_semantic=true setup_ms={:.3}",
                                watch_started.elapsed().as_secs_f64() * 1e3
                            );
                        }
                        watcher
                    });
                }
                if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
                    eprintln!(
                        "COORDINATOR_TIMING source={} validate_ms={:.3} fusion_ms={:.3} publish_ms={:.3}",
                        source.label(),
                        (validated - received).as_secs_f64() * 1e3,
                        (fused - validated).as_secs_f64() * 1e3,
                        fused.elapsed().as_secs_f64() * 1e3
                    );
                }
            }
            Message::Error(error) => {
                emit(json!({"event":"diagnostic","message":error}));
            }
            _ => (),
        }
    }
    indexer.set_paused(false);
    stop.store(true, Ordering::Release);
    indexer.wake();
    latest.store(u64::MAX, Ordering::Release);
    for mailbox in &mailboxes {
        mailbox.wake.notify_all();
    }
    for thread in threads {
        let _ = thread.join();
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        emit(json!({"event":"fatal","message":error}));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn meaning_debounces_letters_and_runs_at_word_boundaries() {
        let now = Instant::now();
        assert_eq!(
            meaning_pause("a query", now, None),
            Duration::from_millis(25)
        );
        assert_eq!(meaning_pause("a query ", now, None), Duration::ZERO);
        assert_eq!(meaning_pause("a query\t", now, None), Duration::ZERO);
        let previous = Job {
            generation: 1,
            text: "a quer".into(),
            started: now,
            warm: false,
        };
        assert_eq!(
            meaning_pause("a query", now + Duration::from_millis(35), Some(&previous)),
            Duration::from_millis(32)
        );
        assert_eq!(
            meaning_pause("a query", now + Duration::from_millis(100), Some(&previous)),
            Duration::from_millis(25)
        );
        assert_eq!(
            meaning_pause(
                "other query",
                now + Duration::from_millis(35),
                Some(&previous)
            ),
            Duration::from_millis(25)
        );
    }

    #[test]
    fn short_prefixes_finish_without_opening_a_model_or_index() {
        let mailbox = Arc::new(Mailbox::default());
        let stopped = Arc::new(AtomicBool::new(false));
        let latest = Arc::new(AtomicU64::new(1));
        let (tx, rx) = mpsc::channel();
        let (m, s, l) = (mailbox.clone(), stopped.clone(), latest.clone());
        let thread = std::thread::spawn(move || {
            worker(Source::Meaning, engine_config("coreai"), m, s, l, tx)
        });
        for (generation, text) in [(1, "a"), (2, "é字")] {
            latest.store(generation, Ordering::Release);
            mailbox.set(Job {
                generation,
                text: text.into(),
                started: Instant::now(),
                warm: false,
            });
            match rx.recv_timeout(Duration::from_secs(2)).unwrap() {
                Message::Found {
                    hits,
                    error,
                    model_generation,
                    ..
                } => {
                    assert!(hits.is_empty());
                    assert!(error.is_none());
                    assert!(model_generation.is_none());
                }
                _ => panic!("expected short-prefix completion"),
            }
        }
        stopped.store(true, Ordering::Release);
        mailbox.wake.notify_all();
        thread.join().unwrap();
    }

    #[test]
    fn panel_close_clears_queued_work_and_wakes_the_meaning_worker() {
        let mailbox = Mailbox::default();
        mailbox.set_panel_visible(true);
        mailbox.prepare(Job {
            generation: 1,
            text: String::new(),
            started: Instant::now(),
            warm: true,
        });
        mailbox.set(Job {
            generation: 1,
            text: "queued".into(),
            started: Instant::now(),
            warm: false,
        });
        mailbox.set_panel_visible(false);
        assert!(mailbox.idle());
        assert!(mailbox.visibility_changed.load(Ordering::Acquire));
        assert!(!mailbox.panel_visible.load(Ordering::Acquire));
        let stopped = AtomicBool::new(false);
        assert!(mailbox.take(&stopped, None).is_none());
        mailbox.set_panel_visible(true);
        assert!(mailbox.panel_visible.load(Ordering::Acquire));
    }

    #[test]
    fn mailbox_supersedes_work_before_the_encode_deadline() {
        let mailbox = Mailbox::default();
        for generation in 1..=3 {
            mailbox.set(Job {
                generation,
                text: format!("query {generation}"),
                started: Instant::now(),
                warm: false,
            });
        }
        let stopped = AtomicBool::new(false);
        assert!(mailbox.newer_before(&stopped, Instant::now() + MEANING_PAUSE));
        assert_eq!(
            mailbox
                .take(&stopped, Some(Duration::ZERO))
                .unwrap()
                .generation,
            3
        );
    }
    fn engine_config(engine: &str) -> Config {
        serde_json::from_value(json!({
            "home":"/tmp", "helper":"/tmp/helper", "index":"/tmp/index",
            "models":"/tmp/models", "embedding":{"engine":engine}
        }))
        .unwrap()
    }


    #[test]
    fn opened_reports_the_path_the_launcher_opened() {
        let request: Request = serde_json::from_str(
            r#"{"op":"opened","generation":7,"path":"/Applications/Safari.app"}"#,
        )
        .unwrap();
        assert!(matches!(
            request,
            Request::Opened { generation: 7, ref path } if path == "/Applications/Safari.app"
        ));
        assert!(serde_json::from_str::<Request>(r#"{"op":"opened","generation":7}"#).is_err());
        assert!(matches!(
            serde_json::from_str::<Request>(r#"{"op":"open","generation":7}"#).unwrap(),
            Request::Open { generation: 7 }
        ));
    }

    #[test]
    fn panel_opened_prepares_only_coreai_and_keeps_pending_queries() {
        assert!(matches!(
            serde_json::from_str::<Request>(r#"{"op":"panel_opened"}"#).unwrap(),
            Request::PanelOpened
        ));
        let mailbox = Mailbox::default();
        let mut disabled = engine_config("coreai");
        disabled.embedding = None;
        prepare_on_open(&disabled, &mailbox, 1);
        assert!(mailbox.idle());
        prepare_on_open(&engine_config("coreai"), &mailbox, 2);
        let warm = mailbox
            .take(&AtomicBool::new(false), Some(Duration::ZERO))
            .unwrap();
        assert!(warm.warm);
        assert_eq!(warm.generation, 2);
        mailbox.set(Job {
            generation: 3,
            text: "typed query".into(),
            started: Instant::now(),
            warm: false,
        });
        prepare_on_open(&engine_config("coreai"), &mailbox, 2);
        assert!(
            mailbox
                .take(&AtomicBool::new(false), Some(Duration::ZERO))
                .unwrap()
                .warm
        );
        let query = mailbox
            .take(&AtomicBool::new(false), Some(Duration::ZERO))
            .unwrap();
        assert!(!query.warm);
        assert_eq!(query.text, "typed query");
        prepare_on_open(&engine_config("coreai"), &mailbox, 4);
        prepare_on_open(&engine_config("coreai"), &mailbox, 4);
        assert!(
            mailbox
                .take(&AtomicBool::new(false), Some(Duration::ZERO))
                .unwrap()
                .warm
        );
        assert!(mailbox.idle());
    }

    #[test]
    fn every_coreai_keystroke_prepares_before_the_query() {
        let mailbox = Mailbox {
            prepare_on_query: true,
            ..Mailbox::default()
        };
        let stopped = AtomicBool::new(false);
        for (i, text) in ["", "a", "é字", " ", "a "].iter().enumerate() {
            // Emptying the mailbox represents the next cold/released worker cycle.
            mailbox.set(Job {
                generation: i as u64,
                text: text.to_string(),
                started: Instant::now(),
                warm: false,
            });
            assert!(mailbox.take(&stopped, Some(Duration::ZERO)).unwrap().warm);
            let query = mailbox.take(&stopped, Some(Duration::ZERO)).unwrap();
            assert!(!query.warm);
            assert_eq!(query.text, *text);
            assert!(mailbox.idle());
        }
    }

    #[test]
    fn preparation_coalesces_without_losing_the_latest_query() {
        let mailbox = Mailbox {
            prepare_on_query: true,
            ..Mailbox::default()
        };
        for generation in 1..=100 {
            mailbox.set(Job {
                generation,
                text: "a".repeat(generation as usize),
                started: Instant::now(),
                warm: false,
            });
            prepare_on_open(&engine_config("coreai"), &mailbox, generation);
        }
        let stopped = AtomicBool::new(false);
        assert!(mailbox.take(&stopped, Some(Duration::ZERO)).unwrap().warm);
        assert_eq!(
            mailbox
                .take(&stopped, Some(Duration::ZERO))
                .unwrap()
                .generation,
            100
        );
        assert!(mailbox.idle());
    }

    #[test]
    fn preparing_does_not_cancel_a_debounced_query() {
        let mailbox = Mailbox::default();
        prepare_on_open(&engine_config("coreai"), &mailbox, 1);
        assert!(!mailbox.newer_before(&AtomicBool::new(false), Instant::now()));
        assert!(
            mailbox
                .take(&AtomicBool::new(false), Some(Duration::ZERO))
                .unwrap()
                .warm
        );
    }

    #[test]
    fn names_keep_their_original_warm_mailbox_policy() {
        let mailbox = Mailbox::default();
        mailbox.offer(Job {
            generation: 0,
            text: String::new(),
            started: Instant::now(),
            warm: true,
        });
        mailbox.set(Job {
            generation: 1,
            text: "a".into(),
            started: Instant::now(),
            warm: false,
        });
        assert!(
            !mailbox
                .take(&AtomicBool::new(false), Some(Duration::ZERO))
                .unwrap()
                .warm
        );
        assert!(mailbox.idle());
    }

    #[test]
    fn preparation_survives_queries_in_either_mailbox_order() {
        for panel_first in [true, false] {
            let mailbox = Mailbox::default();
            let query = Job {
                generation: 1,
                text: "a".into(),
                started: Instant::now(),
                warm: false,
            };
            if panel_first {
                prepare_on_open(&engine_config("coreai"), &mailbox, 0);
            }
            mailbox.set(query);
            if !panel_first {
                prepare_on_open(&engine_config("coreai"), &mailbox, 0);
            }
            let stopped = AtomicBool::new(false);
            assert!(
                mailbox.take(&stopped, Some(Duration::ZERO)).unwrap().warm,
                "panel preparation must precede a queued query in either order"
            );
            assert_eq!(
                mailbox.take(&stopped, Some(Duration::ZERO)).unwrap().text,
                "a"
            );
            assert!(mailbox.take(&stopped, Some(Duration::ZERO)).is_none());
        }
    }

    fn hit(path: &str, rank: f64) -> Hit {
        Hit {
            path: path.into(),
            title: path.into(),
            kind: "file".into(),
            source: "test".into(),
            rank,
            category: "test".into(),
            ..Hit::default()
        }
    }
    fn content(path: &str, rank: f64) -> Hit {
        Hit {
            category: "meaning".into(),
            evidence: (rank - 270.) / 4.,
            base: 270.,
            ..hit(path, rank)
        }
    }
    fn words(path: &str, coverage: f64) -> Hit {
        let evidence = 4.2;
        Hit {
            category: "content".into(),
            evidence,
            base: 270.,
            weak: coverage < 1.,
            coverage,
            ..hit(path, 270. + 4. * evidence)
        }
    }
    #[test]
    fn coreai_tied_aliases_choose_the_same_path_without_changing_scores() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!(
            "p7-duplicates-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let source = root.join("original.pdf");
        std::fs::write(&source, b"same bytes").unwrap();
        let paths: Vec<_> = ["z.pdf", "a.pdf", "m.pdf"]
            .iter()
            .map(|name| {
                let path = root.join(name);
                symlink(&source, &path).unwrap();
                path.to_string_lossy().into_owned()
            })
            .collect();
        for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [0, 2, 1]] {
            let input: Vec<_> = order.iter().map(|i| content(&paths[*i], 300.)).collect();
            let result = merge_ordered(&[], &[], &input, true);
            assert_eq!(result.len(), 1);
            assert_eq!(result[0].path, paths[1]);
            assert_eq!(result[0].rank, 320.);
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn lone_unmatched_word_hides_meaning_noise() {
        let mut found = Found {
            meaning: vec![content("noise", 300.)],
            ..Found::default()
        };
        assert!(found.merged("zqxjvw").is_empty());
        assert_eq!(found.merged("red screenshot").len(), 1);
        found.names = vec![hit("a", 1.)];
        assert_eq!(found.merged("zqxjvw").len(), 2);
    }
    #[test]
    fn extracted_copies_fold_into_the_original_document() {
        let hits = merge(
            &[],
            &[],
            &[
                content("/c/resources/text/ch13-tidal.txt", 340.),
                content("/c/resources/ch13-tidal.pdf", 320.),
                content("/c/resources/extracted/ch13-tidal.json", 330.),
                content("/c/other/notes/ch13-tidal.md", 310.),
            ],
        );
        let paths: Vec<_> = hits.iter().map(|h| (h.path.as_str(), h.rank)).collect();
        assert_eq!(
            paths,
            vec![
                ("/c/resources/ch13-tidal.pdf", 340.),
                ("/c/other/notes/ch13-tidal.md", 310.)
            ]
        );
    }
    #[test]
    fn name_matches_keep_every_copy() {
        let hits = merge(
            &[
                hit("/a/x/report.pdf", 400.),
                hit("/a/x/text/report.txt", 390.),
            ],
            &[],
            &[],
        );
        assert_eq!(hits.len(), 2);
    }
    #[test]
    fn strongest_duplicate_wins_without_erasing_other_backend() {
        let hits = merge(
            &[hit("a", 500.), hit("b", 250.)],
            &[],
            &[content("a", 320.), content("c", 330.)],
        );
        assert_eq!(
            hits.iter().map(|h| h.path.as_str()).collect::<Vec<_>>(),
            vec!["a", "c", "b"]
        );
        assert_eq!(hits[0].rank, 500. + NAME_AND_CONTENT);
    }
    #[test]
    fn words_lift_meaning_and_rank_alone_below_it() {
        let hits = merge(
            &[],
            &[words("both", 1.), words("words", 1.)],
            &[
                content("both", 270. + 4. * 6.),
                content("meaning", 270. + 4. * 6.5),
            ],
        );
        assert_eq!(
            hits.iter().map(|h| h.path.as_str()).collect::<Vec<_>>(),
            vec!["both", "meaning", "words"]
        );
        assert_eq!(hits[0].evidence, 6. + KEYWORD_LIFT);
    }
    #[test]
    fn weak_matches_show_beside_a_strong_one_or_together_past_the_gate() {
        let weak = |path: &str| Hit {
            weak: true,
            ..content(path, 270. + 4. * 3.8)
        };
        let hits = merge(
            &[],
            &[
                words("near", 1.),
                words("both weak", 0.75),
                words("both weak, short", 0.6),
                words("partial", 0.75),
                words("strong meaning", 0.75),
            ],
            &[
                weak("near"),
                weak("both weak"),
                weak("both weak, short"),
                weak("alone"),
                content("strong meaning", 270. + 4. * 5.),
            ],
        );
        let mut paths: Vec<_> = hits.iter().map(|h| h.path.as_str()).collect();
        paths.sort();
        // 3.8 + 0.75 passes the 4.5 gate; 3.8 + 0.6 doesn't.
        assert_eq!(paths, vec!["both weak", "near", "strong meaning"]);
        assert!((hits.iter().find(|h| h.path == "near").unwrap().evidence - 4.8).abs() < 1e-9);
    }
}
