use crate::{
    Config,
    load::{Load, memory_pressure},
    watch::Watcher,
};
use std::{
    collections::BTreeSet,
    fs::OpenOptions,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicI32, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Default)]
struct AccessStatus {
    needs: BTreeSet<String>,
}
impl AccessStatus {
    fn observe(&mut self, event: &serde_json::Value) -> Option<serde_json::Value> {
        if event["event"] != "access" {
            return None;
        }
        let path = event["path"].as_str()?;
        match event["state"].as_str()? {
            "pending" | "denied" => {
                self.needs.insert(path.to_owned());
            }
            "ready" | "missing" => {
                self.needs.remove(path);
            }
            _ => return None,
        }
        Some(serde_json::json!({"event":"access", "folders":self.needs}))
    }
    fn retry_due(&self, elapsed: Duration) -> bool {
        !self.needs.is_empty() && elapsed >= Duration::from_secs(30)
    }
}

#[derive(Default)]
struct RestartBackoff {
    failures: u32,
    retry_at: Option<Instant>,
    disk_floor: Option<u64>,
}
impl RestartBackoff {
    fn observe(&mut self, event: &serde_json::Value) -> Option<serde_json::Value> {
        if event["event"] != "index-readiness" {
            return None;
        }
        let message = match event["state"].as_str()? {
            "preparing" => event["message"].as_str().unwrap_or("Preparing search"),
            "ready" => {
                *self = Self::default();
                ""
            }
            "failed" => {
                self.disk_floor = event["message"]
                    .as_str()
                    .and_then(|s| s.split_once("specialization admission refused: free disk "))
                    .and_then(|(_, s)| s.split_once(" below "))
                    .and_then(|(_, s)| s.split_whitespace().next())
                    .and_then(|s| s.parse().ok());
                if self.disk_floor.is_some() {
                    "Free up disk space to finish preparing search"
                } else {
                    "Search preparation failed. Retrying…"
                }
            }
            _ => return None,
        };
        Some(serde_json::json!({"event":"index-status", "message":message}))
    }
    fn failed(&mut self, now: Instant) {
        self.failures = self.failures.saturating_add(1);
        let seconds = (60u64 << self.failures.saturating_sub(1).min(3)).min(300);
        self.retry_at = Some(now + Duration::from_secs(seconds));
    }
    fn delay(&mut self, now: Instant, free_disk: Option<u64>) -> Option<Duration> {
        let at = self.retry_at?;
        if now < at {
            return Some(at - now);
        }
        if let Some(floor) = self.disk_floor {
            if free_disk.is_none_or(|free| free < floor) {
                self.retry_at = Some(now + Duration::from_secs(30));
                return Some(Duration::from_secs(30));
            }
            self.disk_floor = None;
        }
        self.retry_at = None;
        None
    }
}

fn free_disk(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stats = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::statfs(path.as_ptr(), stats.as_mut_ptr()) } != 0 {
        return None;
    }
    let stats = unsafe { stats.assume_init() };
    Some(stats.f_bavail.saturating_mul(stats.f_bsize as u64))
}

/// Lets the coordinator pause the indexing helper while the pill is in use.
#[derive(Default)]
pub struct Control {
    pid: AtomicI32,
    paused: AtomicBool,
    since: Mutex<Option<Instant>>,
    cooperative: bool,
    session: Mutex<PauseSchedule>,
    input: Mutex<Option<ChildStdin>>,
    wake_epoch: Mutex<u64>,
    changed: Condvar,
}
/// A pill left open must not stall indexing indefinitely.
const MAX_PAUSE: Duration = Duration::from_secs(120);
#[derive(Default)]
struct PauseSchedule {
    resume_at: Option<Instant>,
}
impl PauseSchedule {
    fn active(&mut self, active: bool, now: Instant) -> Option<&'static str> {
        if active {
            self.query(now)
        } else {
            self.resume_at = Some(now + Duration::from_millis(1500));
            None
        }
    }
    fn query(&mut self, now: Instant) -> Option<&'static str> {
        self.resume_at = Some(now + Duration::from_millis(1500));
        Some("pause")
    }
    fn tick(&mut self, now: Instant) -> Option<&'static str> {
        if self.resume_at.is_some_and(|at| now >= at) {
            self.resume_at = None;
            return Some("resume");
        }
        None
    }
}
impl Control {
    pub fn next_deadline(&self) -> Option<Instant> {
        if self.cooperative {
            self.session.lock().unwrap().resume_at
        } else {
            None
        }
    }
    pub fn wake(&self) {
        *self.wake_epoch.lock().unwrap() += 1;
        self.changed.notify_all();
    }
    fn wait(&self, epoch: u64, duration: Duration) {
        let guard = self.wake_epoch.lock().unwrap();
        let _guard = self
            .changed
            .wait_timeout_while(guard, duration, |current| *current == epoch)
            .unwrap();
    }
    pub fn new(cooperative: bool) -> Self {
        Self {
            cooperative,
            ..Self::default()
        }
    }
    fn command(&self, command: Option<&str>) {
        if let Some(command) = command {
            self.paused.store(command == "pause", Ordering::Release);
            if let Some(input) = self.input.lock().unwrap().as_mut() {
                let _ = writeln!(input, "{command}").and_then(|_| input.flush());
            }
            self.wake();
        }
    }
    pub fn active(&self, active: bool) {
        if !self.cooperative {
            self.set_paused(active);
            return;
        }
        let command = self.session.lock().unwrap().active(active, Instant::now());
        self.command(command);
    }
    pub fn query(&self) {
        if self.cooperative {
            let command = self.session.lock().unwrap().query(Instant::now());
            self.command(command);
        }
    }
    pub fn tick(&self) {
        if self.cooperative {
            let command = self.session.lock().unwrap().tick(Instant::now());
            self.command(command);
        }
    }
    pub fn set_paused(&self, paused: bool) {
        if self.cooperative {
            *self.session.lock().unwrap() = PauseSchedule::default();
            self.command(Some(if paused { "pause" } else { "resume" }));
            return;
        }
        self.paused.store(paused, Ordering::Release);
        *self.since.lock().unwrap() = paused.then(Instant::now);
        self.signal();
        self.wake();
    }
    fn signal(&self) {
        if self.cooperative {
            self.command(Some(if self.paused.load(Ordering::Acquire) {
                "pause"
            } else {
                "resume"
            }));
            return;
        }
        let pid = self.pid.load(Ordering::Acquire);
        if pid > 0 {
            // SIGSTOP keeps the helper's model and progress; SIGCONT resumes it where it was.
            let paused = self.paused.load(Ordering::Acquire);
            unsafe {
                libc::kill(pid, if paused { libc::SIGSTOP } else { libc::SIGCONT });
            }
        }
    }
    fn expire(&self) {
        if self.cooperative {
            self.tick();
            return;
        }
        let expired = self
            .since
            .lock()
            .unwrap()
            .is_some_and(|since| since.elapsed() > MAX_PAUSE);
        if expired {
            self.set_paused(false);
        }
    }
    fn adopt(&self, child: &mut Child) {
        let pid = child.id() as i32;
        if self.cooperative {
            *self.input.lock().unwrap() = child.stdin.take();
        }
        // Background policy: efficiency cores and throttled disk I/O, so indexing never competes
        // with the launcher or the foreground app.
        unsafe {
            libc::setpriority(
                libc::PRIO_DARWIN_PROCESS,
                pid as libc::id_t,
                libc::PRIO_DARWIN_BG,
            );
        }
        self.pid.store(pid, Ordering::Release);
        self.signal();
    }
    fn send(&self, child: &mut Child, commands: &[String]) -> bool {
        if !self.cooperative {
            return send(child, commands);
        }
        let mut input = self.input.lock().unwrap();
        let Some(input) = input.as_mut() else {
            return false;
        };
        commands.iter().all(|c| writeln!(input, "{c}").is_ok()) && input.flush().is_ok()
    }
    fn release(&self) {
        if self.cooperative {
            self.command(Some("resume"));
            self.pid.store(0, Ordering::Release);
            return;
        }
        let pid = self.pid.swap(0, Ordering::AcqRel);
        if pid > 0 {
            unsafe {
                libc::kill(pid, libc::SIGCONT);
            }
        }
    }
}

/// Whether a pass should wait because the Mac is hot or saturated; logs when that starts and ends.
fn busy_report(held_back: &mut Option<String>) -> bool {
    let reason = Load::now().indexing_blocked();
    match (&reason, &*held_back) {
        (Some(r), None) => eprintln!("indexing waits: {r}"),
        (None, Some(_)) => eprintln!("indexing may run again"),
        _ => (),
    }
    *held_back = reason;
    held_back.is_some()
}

fn can_index(level: i32) -> bool {
    level < 4
}

/// File types the helper never indexes with code, audio and video turned off. Changes to them (agents writing source,
/// logs and JSON all day) can't change the index, so they don't ask for a sync.
const NOT_INDEXED: &[&str] = &[
    // Source code and data (DigUp's code and data types).
    "py",
    "pyi",
    "pyc",
    "ipynb",
    "c",
    "h",
    "cc",
    "cpp",
    "cxx",
    "hpp",
    "hh",
    "m",
    "mm",
    "swift",
    "ts",
    "tsx",
    "mts",
    "cts",
    "js",
    "jsx",
    "mjs",
    "cjs",
    "go",
    "rs",
    "java",
    "kt",
    "kts",
    "scala",
    "rb",
    "php",
    "cs",
    "fs",
    "sh",
    "bash",
    "zsh",
    "fish",
    "ps1",
    "lua",
    "pl",
    "r",
    "jl",
    "dart",
    "sql",
    "vue",
    "svelte",
    "css",
    "scss",
    "sass",
    "less",
    "json",
    "jsonl",
    "yaml",
    "yml",
    "toml",
    "xml",
    "plist",
    "gradle",
    "cmake",
    "mk",
    "lock",
    "log",
    "csv",
    "tsv",
    "ini",
    "cfg",
    "conf",
    "proto",
    "graphql",
    "tf",
    "nix",
    "zig",
    "hs",
    "ex",
    "exs",
    "erl",
    "clj",
    "elm",
    "ml",
    "vim",
    "el",
    "asm",
    "metal",
    "glsl",
    "hlsl",
    "wgsl",
    "cu",
    "o",
    "a",
    "dylib",
    "so",
    "class",
    "jar",
    "map",
    "wasm",
    // Audio and video.
    "mp3",
    "m4a",
    "m4b",
    "aac",
    "wav",
    "aif",
    "aiff",
    "flac",
    "ogg",
    "opus",
    "caf",
    "wma",
    "amr",
    "mp4",
    "m4v",
    "mov",
    "avi",
    "mkv",
    "webm",
    "wmv",
    "flv",
    "mpg",
    "mpeg",
    "3gp",
    "m2ts",
    // Databases, temporary and partial files.
    "db",
    "sqlite",
    "sqlite3",
    "sqlite-wal",
    "sqlite-shm",
    "db-wal",
    "db-shm",
    "journal",
    "tmp",
    "temp",
    "swp",
    "part",
    "crdownload",
    "download",
    "pid",
    "sock",
];

/// Whether a change the home watcher saw can change the index: a path the helper walks, of a type it reads (or a
/// folder, or a file it types by content).
fn indexable_change(config: &Config, path: &Path) -> bool {
    config.semantic_lexical(path)
        && path
            .extension()
            .and_then(|e| e.to_str())
            .is_none_or(|ext| !NOT_INDEXED.contains(&ext.to_lowercase().as_str()))
        && !path.to_string_lossy().contains('\n')
}

/// What the helper should sync next: everything, or the files and folders the watcher saw change.
#[derive(Default)]
struct Changes {
    full: bool,
    paths: BTreeSet<PathBuf>,
}
/// More changed paths than this at once (a folder of thousands copied in): one full sync costs less.
const MAX_PATHS: usize = 512;
impl Changes {
    fn add(&mut self, path: PathBuf) {
        if !self.full {
            self.paths.insert(path);
            if self.paths.len() > MAX_PATHS {
                self.everything();
            }
        }
    }
    fn everything(&mut self) {
        self.full = true;
        self.paths.clear();
    }
    fn is_empty(&self) -> bool {
        !self.full && self.paths.is_empty()
    }
    /// The helper's commands for these changes ("sync", or "sync <path>" each), leaving none.
    fn take(&mut self) -> Vec<String> {
        let commands = if self.full {
            vec!["sync".into()]
        } else {
            self.paths
                .iter()
                .map(|p| format!("sync {}", p.display()))
                .collect()
        };
        *self = Self::default();
        commands
    }
    fn restore(&mut self, commands: &[String]) {
        for command in commands {
            match command.strip_prefix("sync ") {
                Some(path) => self.add(path.into()),
                None => self.everything(),
            }
        }
    }
}

/// Your accounts on public git hosts, from GitHub CLI's login and git's `github.user`: the helper leaves other
/// people's repositories out (READMEs of cloned projects crowded meaning search).
pub fn own_git_owners(home: &Path) -> BTreeSet<String> {
    let mut owners = BTreeSet::new();
    if let Ok(hosts) = std::fs::read_to_string(home.join(".config/gh/hosts.yml")) {
        for line in hosts.lines() {
            if let Some(user) = line.trim().strip_prefix("user:") {
                owners.insert(user.trim().trim_matches(['"', '\'']).to_string());
            }
        }
    }
    if let Ok(out) = Command::new("/usr/bin/git")
        .args(["config", "--global", "--get", "github.user"])
        .env("HOME", home)
        .stderr(Stdio::null())
        .output()
    {
        let user = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !user.is_empty() {
            owners.insert(user);
        }
    }
    owners.retain(|o| !o.is_empty());
    owners
}

/// Sends `commands` to the helper; false when its input is gone.
fn send(child: &mut Child, commands: &[String]) -> bool {
    let Some(input) = child.stdin.as_mut() else {
        return false;
    };
    commands.iter().all(|c| writeln!(input, "{c}").is_ok()) && input.flush().is_ok()
}

fn skipped_kinds(config: &Config) -> String {
    let media = config.embedding.as_ref();
    [
        ("audio", media.is_some_and(|e| e.index_audio)),
        ("video", media.is_some_and(|e| e.index_video)),
    ]
    .into_iter()
    .filter_map(|(kind, enabled)| (!enabled).then_some(kind))
    .collect::<Vec<_>>()
    .join(",")
}

pub fn supervise(config: Config, stop: Arc<AtomicBool>, control: Arc<Control>) {
    #[cfg(test)]
    if config.helper != std::path::Path::new("/bin/cat") {
        return;
    }
    // The first helper syncs everything: files may have changed while the launcher wasn't running.
    let changes = Arc::new(Mutex::new(Changes {
        full: true,
        ..Changes::default()
    }));
    let seen = changes.clone();
    let wake = control.clone();
    let scope = config.clone();
    let watcher = Watcher::start(&config.home, move |path| {
        match path {
            Some(path) if indexable_change(&scope, path) => {
                seen.lock().unwrap().add(path.into());
                wake.wake();
            }
            Some(_) => (),
            // Events were dropped: only a full sync is sure to catch up.
            None => {
                seen.lock().unwrap().everything();
                wake.wake();
            }
        }
    });
    if watcher.is_none() {
        eprintln!("home watcher: FSEvents stream could not start");
    }
    let owners = own_git_owners(&config.home);
    let mut started = Instant::now() - Duration::from_secs(180);
    let mut full_sync = Instant::now();
    // A helper the watchdog ended (or that died) left work behind: the next one starts soon and syncs nothing.
    let mut resume = false;
    // Why the last pass was held back because the Mac was busy, so the log says so once.
    let mut held_back: Option<String> = None;
    let access = Arc::new(Mutex::new(AccessStatus::default()));
    let mut access_retry = Instant::now();
    let retry = Arc::new(Mutex::new(RestartBackoff::default()));
    while !stop.load(Ordering::Acquire) {
        let epoch = *control.wake_epoch.lock().unwrap();
        let selected_config = crate::semantic::indexing_config(&config);
        let config = &selected_config;
        // A periodic full sync catches what events can't say: a folder becoming readable, a missed event.
        if full_sync.elapsed() > Duration::from_secs(3600) {
            changes.lock().unwrap().everything();
            full_sync = Instant::now();
        }
        if access.lock().unwrap().retry_due(access_retry.elapsed()) {
            changes.lock().unwrap().everything();
            access_retry = Instant::now();
        }
        control.expire();
        let retry_delay = {
            let mut retry = retry.lock().unwrap();
            let now = Instant::now();
            let disk = if retry.disk_floor.is_some() && retry.retry_at.is_some_and(|at| now >= at) {
                free_disk(&config.coreai_runtime())
            } else {
                None
            };
            retry.delay(now, disk)
        };
        if let Some(delay) = retry_delay {
            control.wait(epoch, delay);
            continue;
        }
        let changed = !changes.lock().unwrap().is_empty();
        // Changes wait a little to arrive together; a helper that stopped on a file is replaced at once.
        let wait = if resume {
            Duration::ZERO
        } else if changed {
            Duration::from_secs(60)
        } else {
            Duration::from_secs(5)
        };
        if !(changed || resume)
            || control.paused.load(Ordering::Acquire)
            || !can_index(memory_pressure())
            || busy_report(&mut held_back)
            || started.elapsed() < wait
            || !config.helper.exists()
            || !config.models_installed()
        {
            // Nothing waits on a quicker look: changes gather for a minute before a helper starts.
            let delay = if changed || resume {
                Duration::from_secs(1)
            } else {
                let hourly = Duration::from_secs(3600).saturating_sub(full_sync.elapsed());
                if access.lock().unwrap().needs.is_empty() {
                    hourly
                } else {
                    hourly.min(Duration::from_secs(30).saturating_sub(access_retry.elapsed()))
                }
            };
            control.wait(epoch, delay);
            continue;
        }
        resume = false;
        started = Instant::now();
        let log = match OpenOptions::new()
            .create(true)
            .append(true)
            .open(config.index.join("indexing.jsonl"))
        {
            Ok(l) => l,
            Err(e) => {
                eprintln!("index log: {e}");
                continue;
            }
        };
        let error_log = match OpenOptions::new()
            .create(true)
            .append(true)
            .open(config.index.join("indexing-runtime.log"))
        {
            Ok(l) => l,
            Err(_) => continue,
        };
        let mut cmd = Command::new(&config.helper);
        cmd.arg("index-service");
        if let Some(coreai) = config.coreai() {
            cmd.args(["--engine", "coreai", "--runtime"])
                .arg(config.coreai_runtime());
            cmd.env(
                "DIGUP_COREAI_LOG",
                config
                    .index
                    .parent()
                    .unwrap_or(&config.index)
                    .join("launcher.log"),
            );
            cmd.arg("--model-key")
                .arg(coreai.model_key.as_deref().unwrap_or("coreai-eg2-v1"));
        }
        for root in config
            .file_roots()
            .iter()
            .chain(std::iter::once(&config.home))
            .filter(|p| p.exists())
        {
            cmd.arg(root);
        }
        // Documents, PDFs, screenshots and pictures. Code is left to editors and FSearch's name search (it was half
        // the vectors and most of the noise), and audio and video took minutes of model time a file.
        let skipped = skipped_kinds(config);
        cmd.args(["--index"])
            .arg(&config.index)
            .arg("--skip-kind")
            .arg(skipped)
            .args([
                "--wait-for-sync",
                "--backfill",
                "--prune",
                "--linger",
                "0",
                "--new-limit",
                "25",
                // Running time (time paused while the pill is open doesn't count), DigUp's own default: at background
                // priority one step of a scanned course PDF, rendered and read by OCR, took over 5 minutes.
                "--time-limit",
                "900",
            ]);
        cmd.args(["--memory-limit", "1536"]);
        for exclude in &config.excluded {
            cmd.arg("--exclude").arg(exclude);
        }
        for owner in &owners {
            cmd.arg("--own-git-owner").arg(owner);
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(error_log);
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("index helper: {e}");
                retry.lock().unwrap().failed(Instant::now());
                resume = true;
                continue;
            }
        };
        let output = child.stdout.take().unwrap();
        let access_status = access.clone();
        let readiness = retry.clone();
        let mut reader = Some(std::thread::spawn(move || {
            let mut log = log;
            for line in BufReader::new(output).lines().map_while(Result::ok) {
                let _ = writeln!(log, "{line}");
                if let Ok(event) = serde_json::from_str(&line) {
                    if let Some(status) = readiness.lock().unwrap().observe(&event) {
                        crate::emit(status);
                    }
                    if let Some(status) = access_status.lock().unwrap().observe(&event) {
                        crate::emit(status);
                    }
                }
            }
        }));
        control.adopt(&mut child);
        let mut sent = changes.lock().unwrap().take();
        eprintln!("index helper started: {} sync commands", sent.len());
        control.send(&mut child, &sent);
        let mut synced = Instant::now();
        while !stop.load(Ordering::Acquire) {
            if access.lock().unwrap().retry_due(access_retry.elapsed()) {
                changes.lock().unwrap().everything();
                access_retry = Instant::now();
            }
            control.expire();
            let hot = Load::now().indexing_must_stop();
            if !can_index(memory_pressure()) || hot {
                eprintln!(
                    "index helper stopped: {}",
                    if hot { "heavy thermal pressure" } else { "critical memory pressure" }
                );
                control.release();
                control.send(&mut child, &["stop".into()]);
                for _ in 0..20 {
                    if child.try_wait().ok().flatten().is_some() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                let _ = child.kill();
                let _ = child.wait();
                resume = true;
                break;
            }
            if synced.elapsed() > Duration::from_secs(30) && !changes.lock().unwrap().is_empty() {
                sent = changes.lock().unwrap().take();
                if !control.send(&mut child, &sent) {
                    changes.lock().unwrap().restore(&sent);
                }
                synced = Instant::now();
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    if let Some(reader) = reader.take() {
                        let _ = reader.join();
                    }
                    if !status.success() {
                        eprintln!("index helper exited: {status}");
                        // Read readiness before recording the exit: a late ready event must
                        // not reset the failure count for this failed process.
                        let mut retry = retry.lock().unwrap();
                        retry.failed(Instant::now());
                        eprintln!(
                            "index helper retry in {} s",
                            retry
                                .retry_at
                                .unwrap()
                                .saturating_duration_since(Instant::now())
                                .as_secs_f64()
                        );
                        resume = true;
                    }
                    // Commands sent as it was leaving may not have been read.
                    if synced.elapsed() < Duration::from_secs(10) {
                        changes.lock().unwrap().restore(&sent);
                    }
                    break;
                }
                Err(e) => {
                    eprintln!("index helper wait: {e}");
                    break;
                }
                _ => std::thread::sleep(Duration::from_secs(1)),
            }
        }
        control.release();
        if stop.load(Ordering::Acquire) {
            control.send(&mut child, &["stop".into()]);
            for _ in 0..10 {
                if child.try_wait().ok().flatten().is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(reader) = reader {
            let _ = reader.join();
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn missing_audio_package_preserves_audio_discovery() {
        let config: super::Config = serde_json::from_value(serde_json::json!({
            "home":"/sample", "helper":"/unused", "index":"/sample/index", "models":"/sample/models",
            "embedding":{"engine":"coreai", "index_audio":true, "runtime":"/missing-audio-runtime"}
        })).unwrap();
        assert!(!config.coreai_audio_installed());
        assert!(
            !super::skipped_kinds(&config)
                .split(',')
                .any(|kind| kind == "audio")
        );
    }

    #[test]
    fn readiness_restart_backoff_doubles_caps_and_resets_only_when_ready() {
        let now = Instant::now();
        let mut retry = RestartBackoff::default();
        for seconds in [60, 120, 240, 300, 300] {
            retry.failed(now);
            assert_eq!(retry.delay(now, None), Some(Duration::from_secs(seconds)));
            assert_eq!(retry.delay(now + Duration::from_secs(seconds), None), None);
        }
        retry.observe(&serde_json::json!({"event":"index-readiness", "state":"preparing"}));
        retry.failed(now);
        assert_eq!(retry.delay(now, None), Some(Duration::from_secs(300)));
        assert_eq!(
            retry
                .observe(&serde_json::json!({"event":"index-readiness", "state":"ready"}))
                .unwrap()["message"],
            ""
        );
        retry.failed(now);
        assert_eq!(retry.delay(now, None), Some(Duration::from_secs(60)));
    }

    #[test]
    fn setup_progress_reaches_the_existing_status_message_without_resetting_retry() {
        let mut retry = RestartBackoff::default();
        retry.failed(Instant::now());
        let status = retry.observe(&serde_json::json!({"event":"index-readiness", "state":"preparing", "phase":"specializing", "message":"Preparing search for this Mac"})).unwrap();
        assert_eq!(status["event"], "index-status");
        assert_eq!(status["message"], "Preparing search for this Mac");
        assert_eq!(retry.failures, 1);
    }

    #[test]
    fn disk_refusal_waits_without_restarting_and_resumes_after_space_is_freed() {
        let now = Instant::now();
        let mut retry = RestartBackoff::default();
        let event = retry.observe(&serde_json::json!({"event":"index-readiness", "state":"failed", "message":"worker error: specialization admission refused: free disk 7220000000 below 9000000000 bytes"})).unwrap();
        assert_eq!(event["event"], "index-status");
        assert_eq!(
            event["message"],
            "Free up disk space to finish preparing search"
        );
        retry.failed(now);
        let due = now + Duration::from_secs(60);
        assert_eq!(
            retry.delay(due, Some(8_999_999_999)),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            retry.delay(due + Duration::from_secs(30), None),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            retry.delay(due + Duration::from_secs(60), Some(9_000_000_000)),
            None
        );
        assert!(retry.disk_floor.is_none());
        assert_eq!(
            retry
                .observe(&serde_json::json!({"event":"index-readiness", "state":"ready"}))
                .unwrap()["message"],
            ""
        );
    }

    #[test]
    fn low_disk_does_not_repeat_the_187_attempt_query_repair_loop() {
        let start = Instant::now();
        let mut retry = RestartBackoff::default();
        retry.observe(&serde_json::json!({"event":"index-readiness", "state":"failed", "message":"specialization admission refused: free disk 2000000000 below 9000000000 bytes"}));
        retry.failed(start);
        for poll in 0..187 {
            let now = start + Duration::from_secs(60 + poll * 30);
            assert_eq!(
                retry.delay(now, Some(2_000_000_000)),
                Some(Duration::from_secs(30))
            );
        }
        assert_eq!(retry.failures, 1);
        assert_eq!(
            retry.delay(
                start + Duration::from_secs(60 + 187 * 30),
                Some(9_000_000_000)
            ),
            None
        );
    }

    #[test]
    fn generic_readiness_failure_and_normal_events_do_not_claim_disk_is_low() {
        let mut retry = RestartBackoff::default();
        assert!(
            retry
                .observe(&serde_json::json!({"event":"file"}))
                .is_none()
        );
        let status = retry.observe(&serde_json::json!({"event":"index-readiness", "state":"failed", "message":"nilError"})).unwrap();
        assert_eq!(status["message"], "Search preparation failed. Retrying…");
        assert!(retry.disk_floor.is_none());
    }

    #[test]
    fn idle_control_has_no_periodic_deadline_and_resumes_once() {
        use super::*;
        let control = Control::new(true);
        assert!(control.next_deadline().is_none());
        control.query();
        let deadline = control.next_deadline().unwrap();
        assert_eq!(
            control.session.lock().unwrap().tick(deadline),
            Some("resume")
        );
        assert!(control.next_deadline().is_none());
    }
    #[test]
    fn access_status_reports_pending_and_denied_and_clears_after_grant() {
        use super::AccessStatus;
        use std::time::Duration;
        let mut status = AccessStatus::default();
        assert!(
            status
                .observe(&serde_json::json!({"event":"file"}))
                .is_none()
        );
        for state in ["pending", "denied"] {
            let event = status
                .observe(
                    &serde_json::json!({"event":"access", "path":"/home/Documents", "state":state}),
                )
                .unwrap();
            assert_eq!(event["folders"], serde_json::json!(["/home/Documents"]));
            assert!(!status.retry_due(Duration::from_secs(29)));
            assert!(status.retry_due(Duration::from_secs(30)));
        }
        let event = status
            .observe(
                &serde_json::json!({"event":"access", "path":"/home/Documents", "state":"ready"}),
            )
            .unwrap();
        assert_eq!(event["folders"], serde_json::json!([]));
        assert!(!status.retry_due(Duration::from_secs(3600)));
    }

    #[test]
    fn idle_open_panel_does_not_hold_first_run_indexing() {
        let start = Instant::now();
        let mut schedule = PauseSchedule::default();
        assert_eq!(schedule.active(true, start), Some("pause"));
        assert_eq!(schedule.tick(start + Duration::from_millis(1499)), None);
        assert_eq!(
            schedule.tick(start + Duration::from_millis(1500)),
            Some("resume")
        );
        assert_eq!(schedule.tick(start + Duration::from_secs(25)), None);
    }

    use super::*;

    fn config() -> Config {
        Config {
            home: "/Users/me".into(),
            helper: "/x/digup".into(),
            index: "/Users/me/Library/Application Support/SpotlightFSearch/Index".into(),
            auto_index: true,
            embedding: None,
            semantic_modalities: None,
            excluded: vec![],
            root_cache: Default::default(),
        }
    }

    #[test]
    fn each_query_extends_the_typing_grace() {
        let start = Instant::now();
        let mut schedule = PauseSchedule::default();
        assert_eq!(schedule.active(true, start), Some("pause"));
        assert_eq!(
            schedule.query(start + Duration::from_secs(1)),
            Some("pause")
        );
        assert_eq!(schedule.tick(start + Duration::from_millis(2499)), None);
        assert_eq!(
            schedule.tick(start + Duration::from_millis(2500)),
            Some("resume")
        );
        assert_eq!(
            schedule.query(start + Duration::from_secs(3)),
            Some("pause")
        );
        assert_eq!(schedule.active(false, start + Duration::from_secs(4)), None);
        assert_eq!(schedule.tick(start + Duration::from_millis(5499)), None);
        assert_eq!(
            schedule.tick(start + Duration::from_millis(5500)),
            Some("resume")
        );
        assert_eq!(schedule.tick(start + Duration::from_secs(25)), None);
    }

    #[test]
    fn stub_helper_receives_pause_on_active_and_each_query_and_then_resume() {
        use std::io::{BufRead, BufReader};
        let mut child = Command::new("/bin/cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let control = Control::new(true);
        control.adopt(&mut child);
        control.active(true);
        control.query();
        assert_eq!(
            control
                .session
                .lock()
                .unwrap()
                .active(false, Instant::now()),
            None
        );
        let action = control
            .session
            .lock()
            .unwrap()
            .tick(Instant::now() + Duration::from_millis(1501));
        control.command(action);
        let mut commands = vec![];
        for _ in 0..4 {
            let mut line = String::new();
            output.read_line(&mut line).unwrap();
            commands.push(line.trim().to_string());
        }
        assert_eq!(commands, ["resume", "pause", "pause", "resume"]);
        control.release();
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[test]
    fn only_changes_the_helper_could_index_ask_for_a_sync() {
        let c = config();
        assert!(indexable_change(
            &c,
            Path::new("/Users/me/Documents/notes.md")
        ));
        assert!(indexable_change(
            &c,
            Path::new("/Users/me/Desktop/Screenshot.png")
        ));
        assert!(indexable_change(
            &c,
            Path::new("/Users/me/Documents/New Folder")
        ));
        assert!(!indexable_change(
            &c,
            Path::new("/Users/me/Workspace/output/app/main.swift")
        ));
        assert!(!indexable_change(
            &c,
            Path::new("/Users/me/Documents/data/sources.json")
        ));
        assert!(!indexable_change(&c, Path::new("/Users/me/Music/song.mp3")));
        assert!(!indexable_change(
            &c,
            Path::new("/Users/me/.cache/notes.md")
        ));
        assert!(!indexable_change(
            &c,
            Path::new(
                "/Users/me/Library/Application Support/SpotlightFSearch/Index/index.sqlite-wal"
            )
        ));
        assert!(!indexable_change(
            &c,
            Path::new("/Users/me/repo/node_modules/a/readme.md")
        ));
    }

    #[test]
    fn watcher_ignores_protected_libraries_and_packages() {
        let c = config();
        for relative in [
            "Music/Music/note.txt",
            "Movies/TV/note.txt",
            "Pictures/Photo Booth Library/note.txt",
            "Pictures/Test.photoslibrary/note.txt",
            "Music/Test.musiclibrary/note.txt",
            "Movies/Test.tvlibrary/note.txt",
            "Movies/Test.imovielibrary/note.txt",
            "Movies/Test.theater/note.txt",
            "Pictures/Test.lrlibrary/note.txt",
            "Music/Test.bundle/note.txt",
            "Pictures/Test.PHOTOSLIBRARY/note.txt",
        ] {
            assert!(!indexable_change(&c, &c.home.join(relative)), "{relative}");
        }
        assert!(indexable_change(
            &c,
            &c.home.join("Music/Music notes/note.txt")
        ));
        assert!(c.fast_candidate(std::path::Path::new("/Applications/Notes.app")));
    }

    #[test]
    fn watcher_ignores_excluded_paths_but_keeps_siblings() {
        let mut c = config();
        c.excluded = vec!["/Users/me/Workspace/tmp".into()];
        assert!(!indexable_change(
            &c,
            Path::new("/Users/me/Workspace/tmp/note.md")
        ));
        assert!(!indexable_change(&c, Path::new("/Users/me/Workspace/tmp")));
        assert!(indexable_change(
            &c,
            Path::new("/Users/me/Workspace/tmp-sibling/note.md")
        ));
    }

    #[test]
    fn many_changes_become_one_full_sync() {
        let mut changes = Changes::default();
        changes.add("/Users/me/a.md".into());
        changes.add("/Users/me/a.md".into());
        assert_eq!(changes.take(), vec!["sync /Users/me/a.md".to_string()]);
        assert!(changes.is_empty());
        for i in 0..=MAX_PATHS {
            changes.add(format!("/Users/me/{i}.md").into());
        }
        let commands = changes.take();
        assert_eq!(commands, vec!["sync".to_string()]);
        changes.restore(&commands);
        assert!(changes.full);
    }

    #[test]
    fn warning_allows_visual_work_and_critical_stops() {
        assert!(can_index(1));
        assert!(can_index(2));
        assert!(!can_index(4));
    }
}
