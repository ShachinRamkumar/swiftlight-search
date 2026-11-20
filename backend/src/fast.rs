use crate::{Config, Hit};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, HashMap},
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

/// How long what's known about a folder (`Clones`) is reused: a clone made a minute ago shows up after this.
const CLONES_TTL: Duration = Duration::from_secs(300);

/// Folders holding other people's projects, the way the indexing helper leaves them out (DigUp's
/// `Rules.foreignReason`): a git checkout whose origin on GitHub, GitLab, Bitbucket or Codeberg belongs to someone
/// else, a decompiled app, a downloaded `owner__repo` source archive under sources, repos or research. Name search
/// leaves out what's inside them ("confirmation" found a cloned app's test snapshots); FSearch itself, which agents
/// use too, still lists everything.
struct Clones {
    owners: &'static BTreeSet<String>,
    /// Whether each folder is foreign, and since when that's known.
    folders: HashMap<PathBuf, (bool, Instant)>,
}
/// Your git accounts, lowercase, read once: `git config` costs a process launch.
fn owners(home: &Path) -> &'static BTreeSet<String> {
    static OWNERS: std::sync::OnceLock<BTreeSet<String>> = std::sync::OnceLock::new();
    OWNERS.get_or_init(|| {
        crate::indexing::own_git_owners(home)
            .into_iter()
            .map(|o| o.to_lowercase())
            .collect()
    })
}
impl Clones {
    fn new(home: &Path) -> Self {
        Self {
            owners: owners(home),
            folders: HashMap::new(),
        }
    }
    /// Whether `path` is inside such a folder (the folder itself still shows: its name was searched for).
    fn contain(&mut self, path: &Path) -> bool {
        if self.owners.is_empty() {
            return false;
        }
        if self.folders.len() > 50_000 {
            self.folders.clear();
        }
        path.ancestors().skip(1).any(|folder| {
            if let Some(&(known, since)) = self.folders.get(folder)
                && since.elapsed() < CLONES_TTL
            {
                return known;
            }
            let foreign = foreign_folder(folder, self.owners);
            self.folders
                .insert(folder.to_path_buf(), (foreign, Instant::now()));
            foreign
        })
    }
}

fn foreign_folder(folder: &Path, owners: &BTreeSet<String>) -> bool {
    let name = folder
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    if name == "decompiled" || name.ends_with("-decompiled") || name == "jadx" {
        return true;
    }
    let parent = folder
        .parent()
        .and_then(Path::file_name)
        .map(|n| n.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if ["sources", "repos", "research"].contains(&parent.as_str()) && source_archive(&name) {
        return true;
    }
    std::fs::read_to_string(folder.join(".git/config"))
        .ok()
        .and_then(|config| public_owner(&config))
        .is_some_and(|owner| !owners.contains(&owner.to_lowercase()))
}

/// `owner__repo`: `^[A-Za-z0-9][A-Za-z0-9-]*__[A-Za-z0-9._-]+$`.
fn source_archive(name: &str) -> bool {
    let Some((owner, repo)) = name.split_once("__") else {
        return false;
    };
    owner.starts_with(|c: char| c.is_ascii_alphanumeric())
        && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        && !repo.is_empty()
        && repo
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// The account owning a checkout's origin (else its first remote) on a public host; None for no remote or another host.
fn public_owner(config: &str) -> Option<String> {
    let (mut remote, mut origin, mut first) = (None, None, None);
    for line in config.lines().map(str::trim) {
        if line.starts_with('[') {
            remote = line.starts_with("[remote ").then_some(line);
            continue;
        }
        let (Some(section), Some(value)) = (remote, line.strip_prefix("url")) else {
            continue;
        };
        let Some(value) = value.trim_start().strip_prefix('=') else {
            continue;
        };
        let value = value.trim();
        if section == "[remote \"origin\"]" {
            origin = Some(value);
        }
        first.get_or_insert(value);
    }
    let address = origin.or(first)?;
    ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]
        .iter()
        .find_map(|host| {
            let rest = &address[address.find(host)? + host.len()..];
            let rest = rest.trim_start_matches([':', '/']);
            let (owner, _) = rest.split_once('/')?;
            (!owner.is_empty()).then(|| owner.to_string())
        })
}

/// How long FSearch's list of recently opened items is reused between searches. An open through the launcher marks
/// it stale at once (`FRECENT_STALE`); agents' opens show up within this.
const FRECENT_TTL: Duration = Duration::from_secs(30);
/// Set after the launcher tells FSearch about an open, so the next search reads the new frecency.
static FRECENT_STALE: AtomicBool = AtomicBool::new(false);
/// How long the list of installed apps is reused: an app installed a minute ago shows up after this.
const APPS_TTL: Duration = Duration::from_secs(60);
/// Matches asked of FSearch per folder. FSearch orders by its own score, which favours short code filenames; a wide
/// window lets `rank` surface documents that sit past the first few hundred matches.
const FILE_LIMIT: usize = 400;

/// One FSearch reply, read straight into types: a 400-hit reply parses several times faster than through `Value`.
#[derive(Deserialize)]
struct Reply {
    ok: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    hits: Vec<Found>,
}
#[derive(Deserialize)]
struct Found {
    path: String,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    mtime: Option<i64>,
    #[serde(default)]
    score: Option<f64>,
}

/// An installed app, with the forms of its name that `app_match` compares.
struct App {
    path: String,
    title: String,
    /// The name in lowercase, its words, and their first letters ("visual studio code", "vsc").
    lower: String,
    words: Vec<String>,
    initials: String,
}
impl App {
    fn new(path: String) -> Self {
        let title = app_title(&path);
        let lower = title.to_lowercase();
        let words: Vec<String> = lower
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(String::from)
            .collect();
        let initials = words.iter().filter_map(|w| w.chars().next()).collect();
        Self {
            path,
            title,
            lower,
            words,
            initials,
        }
    }
}
fn app_title(path: &str) -> String {
    Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .trim_end_matches(".app")
        .to_string()
}

pub struct FastSearch {
    socket: Option<BufReader<UnixStream>>,
    /// FSearch frecency (opens that halve every two weeks) by path.
    frecent: HashMap<String, f64>,
    frecent_at: Option<Instant>,
    clones: Option<Clones>,
    apps: Vec<App>,
    apps_at: Option<Instant>,
    /// A refresh running on its own thread and connection, installed by the next search.
    refreshing: Option<mpsc::Receiver<Refreshed>>,
}
/// What a background refresh read; None where it read nothing or failed (the old list stays).
struct Refreshed {
    frecent: Option<HashMap<String, f64>>,
    apps: Option<Vec<App>>,
}
impl FastSearch {
    pub fn new() -> Self {
        Self {
            socket: None,
            frecent: HashMap::new(),
            frecent_at: None,
            clones: None,
            apps: vec![],
            apps_at: None,
            refreshing: None,
        }
    }
    /// Reads what search reuses (frecency, the apps, which folders are clones) when the pill opens, so the first
    /// keystroke doesn't wait for it.
    pub fn warm(&mut self, config: &Config) {
        self.load_missing(config);
        self.maintain(config);
        self.clones.get_or_insert_with(|| Clones::new(&config.home));
    }
    /// Refreshes whatever has grown old on another thread: on this one, a refresh just before a keystroke held it
    /// up to 170 ms.
    pub fn maintain(&mut self, config: &Config) {
        self.install();
        if self.refreshing.is_some() {
            return;
        }
        let frecent = FRECENT_STALE.swap(false, Ordering::AcqRel)
            || self
                .frecent_at
                .is_some_and(|at| at.elapsed() >= FRECENT_TTL);
        let apps = self.apps_at.is_some_and(|at| at.elapsed() >= APPS_TTL);
        if !frecent && !apps {
            return;
        }
        let now = Some(Instant::now());
        if frecent {
            self.frecent_at = now;
        }
        if apps {
            self.apps_at = now;
        }
        let (tx, rx) = mpsc::channel();
        let config = config.clone();
        let spawned = std::thread::Builder::new()
            .name("names-refresh".into())
            .spawn(move || {
                let mut socket = None;
                let _ = tx.send(Refreshed {
                    frecent: frecent
                        .then(|| read_frecent(&mut socket, &config))
                        .flatten(),
                    apps: apps.then(|| read_apps(&mut socket, &config)).flatten(),
                });
            });
        if spawned.is_ok() {
            self.refreshing = Some(rx);
        }
    }
    /// Takes a finished background refresh.
    fn install(&mut self) {
        let Some(rx) = &self.refreshing else { return };
        match rx.try_recv() {
            Ok(refreshed) => {
                if let Some(frecent) = refreshed.frecent {
                    self.frecent = frecent;
                }
                if let Some(apps) = refreshed.apps {
                    self.apps = apps;
                }
                self.refreshing = None;
            }
            Err(mpsc::TryRecvError::Disconnected) => self.refreshing = None,
            Err(mpsc::TryRecvError::Empty) => (),
        }
    }
    /// Frecency and the apps, here and now if they were never read (the first search after launch).
    fn load_missing(&mut self, config: &Config) {
        if self.frecent_at.is_none() {
            self.frecent_at = Some(Instant::now());
            self.frecent = read_frecent(&mut self.socket, config).unwrap_or_default();
        }
        if self.apps_at.is_none() {
            self.apps_at = Some(Instant::now());
            if let Some(apps) = read_apps(&mut self.socket, config) {
                self.apps = apps;
            }
        }
    }
    fn exchange(&mut self, config: &Config, requests: &[Value]) -> Result<Vec<String>, String> {
        exchange(&mut self.socket, config, requests)
    }
    pub fn search(
        &mut self,
        config: &Config,
        query: &str,
        current: impl Fn() -> bool,
    ) -> Result<Vec<Hit>, String> {
        // Ordinary text only: the launcher never exposes FSearch's command/filter grammar.
        let literal: String = query
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || "._-".contains(c) {
                    c
                } else {
                    ' '
                }
            })
            .collect();
        let literal = literal
            .split_whitespace()
            .take(8)
            .collect::<Vec<_>>()
            .join(" ");
        if literal.is_empty() || !current() {
            return Ok(vec![]);
        }
        let started = Instant::now();
        self.install();
        self.load_missing(config);
        // One request per folder: FSearch keeps a folder's entries together in its index, so a scoped search reads
        // only them, where a path filter over the whole disk tested millions of names ("s" took 180 ms, now 4).
        let roots = config.file_roots();
        let requests: Vec<Value> = roots
            .iter()
            .map(|root| json!({"op":"search","q":literal,"in":root,"limit":FILE_LIMIT}))
            .collect();
        let lines = self.exchange(config, &requests)?;
        let request_time = started.elapsed();
        let mut found = vec![];
        let mut failure = None;
        for line in &lines {
            match serde_json::from_str::<Reply>(line) {
                Ok(reply) if reply.ok => found.extend(reply.hits),
                Ok(reply) => failure = reply.error.or(Some("FSearch unavailable".into())),
                Err(e) => failure = Some(e.to_string()),
            }
        }
        if found.is_empty()
            && let Some(error) = failure
        {
            return Err(error);
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64);
        let lower = literal.to_lowercase();
        let mut hits = vec![];
        for app in &self.apps {
            let Some((rank, category)) = app_match(app, &lower) else {
                continue;
            };
            let rank = rank
                + kind_adjustment(&app.title, &literal, true, false)
                + frecency_boost(self.frecent.get(&app.path).copied().unwrap_or(0.));
            hits.push(Hit {
                path: app.path.clone(),
                title: app.title.clone(),
                kind: "app".into(),
                source: "fsearch".into(),
                rank,
                category: category.into(),
                ..Hit::default()
            });
        }
        let clones = self.clones.get_or_insert_with(|| Clones::new(&config.home));
        for (i, h) in found.into_iter().enumerate() {
            if i % 64 == 0 && !current() {
                return Ok(vec![]);
            }
            let path = Path::new(&h.path);
            if !config.fast_candidate(path) || clones.contain(path) {
                continue;
            }
            let dir = h.kind.as_deref() == Some("dir");
            let title = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            let relative = roots
                .iter()
                .find_map(|root| path.strip_prefix(root).ok())
                .unwrap_or(path);
            let (rank, category) = name_rank(&title, &lower, false);
            let rank = rank
                + kind_adjustment(&title, &literal, false, dir)
                + location_adjustment(relative)
                + recency_adjustment(h.mtime, now, false)
                + frecency_boost(self.frecent.get(&h.path).copied().unwrap_or(0.))
                + h.score.unwrap_or(0.).clamp(0., 1000.) / 10000.;
            hits.push(Hit {
                kind: h.kind.unwrap_or_else(|| "file".into()),
                path: h.path,
                title,
                source: "fsearch".into(),
                rank,
                category: category.into(),
                ..Hit::default()
            });
        }
        hits.sort_by(|a, b| {
            b.rank
                .total_cmp(&a.rank)
                .then_with(|| a.title.len().cmp(&b.title.len()))
                .then_with(|| a.path.cmp(&b.path))
        });
        let hits = hits
            .into_iter()
            .filter(|h| config.fast_allowed(Path::new(&h.path)))
            .take(20)
            .collect();
        if std::env::var_os("SPOTLIGHT_PROFILE").is_some() {
            eprintln!(
                "FSEARCH_TIMING request_ms={:.2} total_ms={:.2}",
                request_time.as_secs_f64() * 1000.,
                started.elapsed().as_secs_f64() * 1000.
            );
        }
        Ok(hits)
    }
}
/// FSearch 0.2's `recent` list: what was opened lately, best first. Older daemons lack it, so a failure leaves
/// ranking as it was.
fn read_frecent(
    socket: &mut Option<BufReader<UnixStream>>,
    config: &Config,
) -> Option<HashMap<String, f64>> {
    let line = exchange(socket, config, &[json!({"op":"recent","limit":512})])
        .ok()?
        .pop()?;
    let reply = serde_json::from_str::<Reply>(&line).ok()?;
    Some(
        reply
            .hits
            .into_iter()
            .filter_map(|h| Some((h.path, h.score? / 100.)))
            .collect(),
    )
}
/// The apps in the application folders, from FSearch's index (about a hundred, 3 ms warm, 110 ms cold), matched here
/// on each keystroke: a fuzzy app search across the whole index took up to 60 ms for a sentence.
fn read_apps(socket: &mut Option<BufReader<UnixStream>>, config: &Config) -> Option<Vec<App>> {
    let roots: Vec<_> = config.app_roots().iter().map(|p| escape(p)).collect();
    let pattern = format!("^(?:{})/.*\\.app$", roots.join("|"));
    let request = json!({"op":"search","q":"","type":"app","path":pattern,"limit":5000});
    let line = exchange(socket, config, &[request]).ok()?.pop()?;
    let reply = serde_json::from_str::<Reply>(&line).ok().filter(|r| r.ok)?;
    Some(
        reply
            .hits
            .into_iter()
            .filter(|h| config.fast_candidate(Path::new(&h.path)))
            .map(|h| App::new(h.path))
            .collect(),
    )
}
/// Sends `requests` together and returns their reply lines in order: FSearch answers one connection's lines in turn,
/// so the folders' searches don't each wait a round trip. A failed connection is dropped and made again next time.
fn exchange(
    socket: &mut Option<BufReader<UnixStream>>,
    config: &Config,
    requests: &[Value],
) -> Result<Vec<String>, String> {
    if socket.is_none() {
        let test_socket = (std::env::var("SPOTLIGHT_VERIFY").as_deref() == Ok("1"))
            .then(|| std::env::var_os("SPOTLIGHT_VERIFY_NAMES_SOCKET"))
            .flatten();
        let path = test_socket.map(PathBuf::from).unwrap_or_else(|| {
            config
                .home
                .join("Library/Application Support/FSearch/fsearch.sock")
        });
        let stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .map_err(|e| e.to_string())?;
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .map_err(|e| e.to_string())?;
        *socket = Some(BufReader::new(stream));
    }
    let connection = socket.as_mut().unwrap();
    let result = (|| {
        let mut batch = String::new();
        for request in requests {
            batch.push_str(&request.to_string());
            batch.push('\n');
        }
        connection
            .get_mut()
            .write_all(batch.as_bytes())
            .map_err(|e| e.to_string())?;
        let mut lines = Vec::with_capacity(requests.len());
        for _ in requests {
            let mut line = String::new();
            if connection.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                return Err("FSearch closed the connection".to_string());
            }
            lines.push(line);
        }
        Ok(lines)
    })();
    if result.is_err() {
        *socket = None;
    }
    result
}
fn escape(path: &Path) -> String {
    path.to_string_lossy()
        .chars()
        .fold(String::new(), |mut s, c| {
            if "\\.+*?[^]$(){}|".contains(c) {
                s.push('\\');
            }
            s.push(c);
            s
        })
}
/// How well an app's name answers `query` (lowercase), in `name_rank`'s tiers, plus what a launcher is asked for that
/// FSearch's fuzzy matching gave before: every word starting a word of the name ("studio code"), initials ("vsc"),
/// letters in order ("sfri") and one typo ("safri").
fn app_match(app: &App, query: &str) -> Option<(f64, &'static str)> {
    let (rank, category) = name_rank(&app.title, query, true);
    if category != "fuzzy" {
        return Some((rank, category));
    }
    let asked: Vec<&str> = query.split_whitespace().collect();
    let joined: String = asked.concat();
    if asked.len() > 1
        && asked
            .iter()
            .all(|q| app.words.iter().any(|w| w.starts_with(q)))
    {
        return Some((395., "word"));
    }
    if joined.chars().count() >= 2 && app.initials.starts_with(&joined) {
        return Some((390., "word"));
    }
    let letters: String = app.lower.chars().filter(|c| c.is_alphanumeric()).collect();
    if joined.chars().count() >= 3 && in_order(&letters, &joined) {
        return Some((270., "fuzzy"));
    }
    if joined.chars().count() >= 4 && app.words.iter().any(|w| one_typo(w, &joined)) {
        return Some((265., "fuzzy"));
    }
    None
}
/// Whether `wanted`'s letters appear in `name` in order, starting at its first letter or a word's.
fn in_order(name: &str, wanted: &str) -> bool {
    let mut letters = wanted.chars();
    let mut next = letters.next();
    let mut first = true;
    for c in name.chars() {
        if Some(c) == next {
            if first && !name.starts_with(c) {
                return false;
            }
            first = false;
            next = letters.next();
            if next.is_none() {
                return true;
            }
        }
    }
    false
}
/// Whether `query` is one edit (a letter wrong, missing, extra, or two swapped) from the start of `word`.
fn one_typo(word: &str, query: &str) -> bool {
    let (w, q): (Vec<char>, Vec<char>) = (word.chars().collect(), query.chars().collect());
    [q.len().saturating_sub(1), q.len(), q.len() + 1]
        .into_iter()
        .filter(|&n| n > 0 && n <= w.len())
        .any(|n| edits(&w[..n], &q) <= 1)
}
/// Optimal string alignment distance.
fn edits(a: &[char], b: &[char]) -> usize {
    let mut rows = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in rows.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in rows[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            rows[i][j] = (rows[i - 1][j] + 1)
                .min(rows[i][j - 1] + 1)
                .min(rows[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                rows[i][j] = rows[i][j].min(rows[i - 2][j - 2] + 1);
            }
        }
    }
    rows[a.len()][b.len()]
}
fn name_rank(title: &str, query: &str, app: bool) -> (f64, &'static str) {
    let name = title.to_lowercase();
    let q = query;
    // A query word that starts a word in the name ("resume" in "Jane Doe Resume.pdf").
    let word_start = name
        .match_indices(q)
        .any(|(i, _)| i > 0 && !name[..i].chars().last().is_some_and(char::is_alphanumeric));
    if name == q
        || Path::new(&name)
            .file_stem()
            .is_some_and(|s| s.to_string_lossy() == q)
    {
        (if app { 500. } else { 450. }, "exact")
    } else if name.starts_with(q) {
        (if app { 430. } else { 400. }, "prefix")
    } else if word_start {
        (if app { 400. } else { 375. }, "word")
    } else if name.contains(q) {
        (if app { 380. } else { 340. }, "substring")
    } else {
        (if app { 270. } else { 250. }, "fuzzy")
    }
}

fn extension(title: &str) -> String {
    Path::new(title)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

/// Documents and apps are what a launcher is for; source code and generated data rarely are.
/// A query that names an extension ("main.rs") opts out of the code penalty.
fn kind_adjustment(title: &str, query: &str, app: bool, dir: bool) -> f64 {
    if app {
        return 40.;
    }
    if dir {
        return 10.;
    }
    let ext = extension(title);
    const DOCUMENTS: &[&str] = &[
        "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "csv", "ppt",
        "pptx", "txt", "md", "rtf", "rtfd", "odt", "ods", "odp", "epub", "png", "jpg", "jpeg",
        "heic", "gif", "tiff", "webp", "mov", "mp4", "m4a", "mp3", "wav", "zip", "dmg", "pkg",
    ];
    const CODE: &[&str] = &[
        "rs", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "kt", "kts", "java", "c",
        "cc", "cpp", "h", "hpp", "m", "mm", "go", "rb", "php", "cs", "scala", "sh", "zsh", "bash",
        "lua", "sql", "json", "yaml", "yml", "toml", "xml", "plist", "gradle", "cmake", "vue",
        "svelte", "css", "scss", "less", "html", "htm", "ipynb", "proto", "graphql",
    ];
    const GENERATED: &[&str] = &[
        "snap", "pyc", "pyo", "o", "a", "class", "jar", "map", "lock", "log", "db", "sqlite",
        "sqlite3", "wal", "shm", "tmp", "cache", "d", "dsym", "pdb", "obj",
    ];
    let names_extension = query.contains('.');
    if DOCUMENTS.contains(&ext.as_str()) {
        25.
    } else if GENERATED.contains(&ext.as_str()) && !names_extension {
        -160.
    } else if CODE.contains(&ext.as_str()) && !names_extension {
        -90.
    } else {
        0.
    }
}

/// Files buried in cloned repositories, research dumps and build trees rank below files a person filed.
pub fn location_adjustment(relative: &Path) -> f64 {
    const NOISY: &[&str] = &[
        "src",
        "source",
        "sources",
        "lib",
        "libs",
        "test",
        "tests",
        "spec",
        "specs",
        "__tests__",
        "__snapshots__",
        "snapshots",
        "fixtures",
        "examples",
        "example",
        "third_party",
        "thirdparty",
        "deps",
        "packages",
        "assets",
        "generated",
        "gen",
        "research",
        "output",
        "outputs",
        "tmp",
        "temp",
        "cache",
        "logs",
        "internal",
        "pkg",
        "cmd",
        "scripts",
    ];
    let folders: Vec<String> = relative
        .parent()
        .into_iter()
        .flat_map(|p| p.components())
        .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
        .collect();
    let noisy = folders
        .iter()
        .filter(|f| NOISY.contains(&f.as_str()) || f.ends_with("-source") || f.ends_with("-main"))
        .count() as f64;
    let depth = folders.len().saturating_sub(1) as f64;
    -(noisy * 25.).min(125.) - (depth * 3.).min(45.)
}

/// FSearch's own lift for a frecency score: one open about +8, five +21, at most +40. Name tiers
/// are 25–50 apart, so habitually opened items move up within and across nearby tiers.
fn frecency_boost(score: f64) -> f64 {
    if score > 0. {
        (12. * score.ln_1p()).min(40.)
    } else {
        0.
    }
}

/// Tells FSearch the launcher opened `path`, so it ranks higher in later searches. Uses its own
/// short connection: the search worker's socket belongs to that thread.
pub fn notify_open(config: &Config, path: &str) {
    let socket = config
        .home
        .join("Library/Application Support/FSearch/fsearch.sock");
    let Ok(mut stream) = UnixStream::connect(socket) else {
        return;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    if writeln!(stream, "{}", json!({"op":"open","path":path})).is_ok() {
        let _ = BufReader::new(stream).read_line(&mut String::new());
    }
    FRECENT_STALE.store(true, Ordering::Release);
}

fn recency_adjustment(mtime: Option<i64>, now: i64, app: bool) -> f64 {
    let Some(mtime) = mtime else { return 0. };
    if app {
        return 0.;
    }
    let days = (now - mtime).max(0) as f64 / 86400.;
    if days < 7. {
        20.
    } else if days < 30. {
        10.
    } else if days < 365. {
        0.
    } else {
        -5.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frecency_matches_fsearch_scale() {
        assert_eq!(frecency_boost(0.), 0.);
        assert!((frecency_boost(1.) - 8.3).abs() < 0.1);
        assert!((frecency_boost(5.) - 21.5).abs() < 0.1);
        assert_eq!(frecency_boost(1000.), 40.);
    }
    fn score(title: &str, relative: &str, query: &str) -> f64 {
        let (base, _) = name_rank(title, &query.to_lowercase(), false);
        base + kind_adjustment(title, query, false, false)
            + location_adjustment(Path::new(relative))
    }
    #[test]
    fn filed_documents_outrank_code_in_cloned_repositories() {
        let resume = score(
            "Jane Doe Resume.pdf",
            "Career/Jane Doe Resume.pdf",
            "resume",
        );
        let code = score(
            "resume.rs",
            "Projects/tools/research/sample-repo/core/src/control/resume.rs",
            "resume",
        );
        assert!(resume > code, "{resume} <= {code}");
    }
    #[test]
    fn origin_owner_comes_from_public_hosts_only() {
        let config = "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = git@github.com:me/x.git\n[remote \"origin\"]\n\turl = https://github.com/instructure/canvas-android.git\n";
        assert_eq!(public_owner(config).as_deref(), Some("instructure"));
        assert_eq!(
            public_owner("[remote \"a\"]\n url = git@gitlab.com:Group/repo.git").as_deref(),
            Some("Group")
        );
        assert_eq!(
            public_owner("[remote \"origin\"]\n url = ssh://pi.local/srv/repo.git"),
            None
        );
        assert_eq!(public_owner("[core]\n bare = true"), None);
        assert!(source_archive("usa-reddragon__goestools"));
        assert!(!source_archive("__x") && !source_archive("notes") && !source_archive("a__b c"));
    }
    #[test]
    fn clones_hide_their_files_but_not_themselves_or_your_repos() {
        let root = std::env::temp_dir().join(format!("clones-{}", std::process::id()));
        let git = |repo: &str, url: &str| {
            std::fs::create_dir_all(root.join(repo).join(".git")).unwrap();
            std::fs::write(
                root.join(repo).join(".git/config"),
                format!("[remote \"origin\"]\n\turl = {url}\n"),
            )
            .unwrap();
        };
        git("theirs", "https://github.com/instructure/canvas-ios.git");
        git("mine", "git@github.com:JaneDoe/thing.git");
        std::fs::create_dir_all(root.join("research/usa-reddragon__goestools/src")).unwrap();
        std::fs::create_dir_all(root.join("app-decompiled/res")).unwrap();
        let mine: &'static BTreeSet<String> = Box::leak(Box::new(["janedoe".to_string()].into()));
        let mut clones = Clones {
            owners: mine,
            folders: HashMap::new(),
        };
        assert!(clones.contain(&root.join("theirs/Tests/__Snapshots__/confirmation.snap")));
        assert!(!clones.contain(&root.join("theirs")));
        assert!(!clones.contain(&root.join("mine/docs/confirmation.md")));
        assert!(clones.contain(&root.join("research/usa-reddragon__goestools/src/main.cc")));
        assert!(clones.contain(&root.join("app-decompiled/res/layout.xml")));
        assert!(!clones.contain(&root.join("notes/confirmation.pdf")));
        let nobody_owners: &'static BTreeSet<String> = Box::leak(Box::default());
        let mut nobody = Clones {
            owners: nobody_owners,
            folders: HashMap::new(),
        };
        assert!(!nobody.contain(&root.join("theirs/README.md")));
        let _ = std::fs::remove_dir_all(&root);
    }
    #[test]
    fn apps_match_words_initials_order_and_one_typo() {
        let app = |path: &str| App::new(path.into());
        let code = app("/Applications/Visual Studio Code.app");
        let safari = app("/Applications/Safari.app");
        let settings = app("/System/Applications/System Settings.app");
        assert_eq!(app_match(&safari, "safari").map(|m| m.1), Some("exact"));
        assert_eq!(app_match(&safari, "saf").map(|m| m.1), Some("prefix"));
        assert_eq!(app_match(&code, "studio code").map(|m| m.1), Some("word"));
        assert_eq!(app_match(&code, "code studio").map(|m| m.1), Some("word"));
        assert_eq!(app_match(&code, "vsc").map(|m| m.1), Some("word"));
        assert_eq!(app_match(&settings, "settings").map(|m| m.1), Some("word"));
        assert_eq!(app_match(&safari, "sfri").map(|m| m.1), Some("fuzzy"));
        assert_eq!(app_match(&safari, "safri").map(|m| m.1), Some("fuzzy"));
        assert_eq!(app_match(&safari, "sfaari").map(|m| m.1), Some("fuzzy"));
        assert!(app_match(&safari, "photo of a dog").is_none());
        assert!(app_match(&settings, "tidal").is_none());
        assert!(app_match(&safari, "ari").is_some_and(|m| m.1 == "substring"));
        assert!(app_match(&safari, "fr").is_none());
    }
    #[test]
    fn naming_an_extension_keeps_code_reachable() {
        assert!(
            score("main.rs", "proj/main.rs", "main.rs") > score("main.rs", "proj/main.rs", "main")
        );
    }
}
