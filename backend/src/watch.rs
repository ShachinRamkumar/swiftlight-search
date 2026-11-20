//! Home-folder changes from FSEvents, delivered in batches on a background queue.
//!
//! One stream over the home folder with a two-second latency: the callback runs at most every two seconds however
//! busy the disk is, where a zero-latency stream (notify's) woke the backend for each file written. Library, the
//! Trash and the busiest hidden folders are excluded at the source; they made up four fifths of the events and are
//! never indexed.
use std::{
    ffi::{CStr, c_char, c_void},
    path::{Path, PathBuf},
};

type CFIndex = isize;
type CFTypeRef = *const c_void;
type Handler = Box<dyn Fn(Option<&Path>) + Send + Sync>;

#[repr(C)]
struct CFArrayCallBacks {
    version: CFIndex,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}
#[repr(C)]
struct FSEventStreamContext {
    version: CFIndex,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}
type Callback =
    extern "C" fn(*const c_void, *mut c_void, usize, *mut c_void, *const u32, *const u64);

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeArrayCallBacks: CFArrayCallBacks;
    fn CFStringCreateWithBytes(
        alloc: CFTypeRef,
        bytes: *const u8,
        len: CFIndex,
        encoding: u32,
        external: u8,
    ) -> CFTypeRef;
    fn CFArrayCreate(
        alloc: CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        callbacks: *const CFArrayCallBacks,
    ) -> CFTypeRef;
    fn CFRelease(object: CFTypeRef);
}
#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn FSEventStreamCreate(
        alloc: CFTypeRef,
        callback: Callback,
        context: *const FSEventStreamContext,
        paths: CFTypeRef,
        since: u64,
        latency: f64,
        flags: u32,
    ) -> *mut c_void;
    fn FSEventStreamSetExclusionPaths(stream: *mut c_void, paths: CFTypeRef) -> u8;
    fn FSEventStreamSetDispatchQueue(stream: *mut c_void, queue: *mut c_void);
    fn FSEventStreamStart(stream: *mut c_void) -> u8;
    fn FSEventStreamStop(stream: *mut c_void);
    fn FSEventStreamInvalidate(stream: *mut c_void);
    fn FSEventStreamRelease(stream: *mut c_void);
}
unsafe extern "C" {
    fn dispatch_queue_attr_make_with_qos_class(
        attr: *mut c_void,
        qos: u32,
        priority: i32,
    ) -> *mut c_void;
    fn dispatch_queue_create(label: *const c_char, attr: *mut c_void) -> *mut c_void;
}

const UTF8: u32 = 0x0800_0100;
const SINCE_NOW: u64 = u64::MAX;
const FILE_EVENTS: u32 = 0x10;
const QOS_BACKGROUND: u32 = 0x09;
/// Seconds events gather before the callback runs.
const LATENCY: f64 = 2.0;
/// FSEvents excludes at most eight paths.
const MAX_EXCLUSIONS: usize = 8;
/// Hidden folders that apps and agents write to all day, in the order they're excluded after Library and the Trash.
const BUSY_HIDDEN: &[&str] = &[
    ".claude", ".codex", ".cache", ".npm", ".cargo", ".t3", ".local", ".rustup", ".vscode",
    ".cursor",
];
/// Events lost (dropped by the kernel or this process, or a subtree to rescan): only a full sync catches up.
const LOST: u32 = 0x1 | 0x2 | 0x4;
/// Events that change what a path holds or whether it exists; the rest (permissions, xattrs, Finder info) don't.
const CHANGED: u32 = 0x100 | 0x200 | 0x800 | 0x1000 | 0x0040_0000;

/// A running stream. The handler gets each changed path, or None when events were lost.
pub struct Watcher {
    stream: *mut c_void,
}
impl Watcher {
    pub fn start(
        home: &Path,
        handler: impl Fn(Option<&Path>) + Send + Sync + 'static,
    ) -> Option<Self> {
        Self::start_with_latency(home, LATENCY, handler)
    }
    pub fn start_with_latency(
        home: &Path,
        latency: f64,
        handler: impl Fn(Option<&Path>) + Send + Sync + 'static,
    ) -> Option<Self> {
        let mut excluded = vec![home.join("Library"), home.join(".Trash")];
        excluded.extend(
            BUSY_HIDDEN
                .iter()
                .map(|name| home.join(name))
                .filter(|p| p.is_dir()),
        );
        excluded.truncate(MAX_EXCLUSIONS);
        // The handler lives as long as the process: a callback may still be running on the queue as the stream is
        // invalidated, so it's never freed.
        let info = Box::into_raw(Box::new(Box::new(handler) as Handler));
        let context = FSEventStreamContext {
            version: 0,
            info: info.cast(),
            retain: std::ptr::null(),
            release: std::ptr::null(),
            copy_description: std::ptr::null(),
        };
        // Safety: every CF object made here is released here or owned by the stream; the stream is released in Drop.
        unsafe {
            let paths = paths_array(&[home.to_path_buf()]);
            let stream = FSEventStreamCreate(
                std::ptr::null(),
                callback,
                &context,
                paths,
                SINCE_NOW,
                latency,
                FILE_EVENTS,
            );
            CFRelease(paths);
            if stream.is_null() {
                return None;
            }
            let exclusions = paths_array(&excluded);
            FSEventStreamSetExclusionPaths(stream, exclusions);
            CFRelease(exclusions);
            let attr =
                dispatch_queue_attr_make_with_qos_class(std::ptr::null_mut(), QOS_BACKGROUND, 0);
            let queue = dispatch_queue_create(c"spotlight-fsearch.home-watch".as_ptr(), attr);
            FSEventStreamSetDispatchQueue(stream, queue);
            if FSEventStreamStart(stream) == 0 {
                FSEventStreamInvalidate(stream);
                FSEventStreamRelease(stream);
                return None;
            }
            Some(Self { stream })
        }
    }
}
impl Drop for Watcher {
    fn drop(&mut self) {
        // Safety: the stream was started in `start` and is released once.
        unsafe {
            FSEventStreamStop(self.stream);
            FSEventStreamInvalidate(self.stream);
            FSEventStreamRelease(self.stream);
        }
    }
}

/// A CFArray of CFStrings; the caller releases it.
unsafe fn paths_array(paths: &[PathBuf]) -> CFTypeRef {
    use std::os::unix::ffi::OsStrExt;
    unsafe {
        let strings: Vec<CFTypeRef> = paths
            .iter()
            .map(|p| {
                let bytes = p.as_os_str().as_bytes();
                CFStringCreateWithBytes(
                    std::ptr::null(),
                    bytes.as_ptr(),
                    bytes.len() as CFIndex,
                    UTF8,
                    0,
                )
            })
            .filter(|s| !s.is_null())
            .collect();
        let array = CFArrayCreate(
            std::ptr::null(),
            strings.as_ptr(),
            strings.len() as CFIndex,
            &raw const kCFTypeArrayCallBacks,
        );
        for s in strings {
            CFRelease(s);
        }
        array
    }
}

extern "C" fn callback(
    _stream: *const c_void,
    info: *mut c_void,
    count: usize,
    paths: *mut c_void,
    flags: *const u32,
    _ids: *const u64,
) {
    use std::os::unix::ffi::OsStrExt;
    // Safety: FSEvents passes `count` C strings and flags, and `info` is the handler boxed in `start`.
    unsafe {
        let handler = &*(info as *const Handler);
        let paths = paths as *const *const c_char;
        for i in 0..count {
            let flag = *flags.add(i);
            if flag & LOST != 0 {
                handler(None);
            } else if flag & CHANGED != 0 {
                let path = CStr::from_ptr(*paths.add(i));
                handler(Some(Path::new(std::ffi::OsStr::from_bytes(
                    path.to_bytes(),
                ))));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn index_changes_arrive_without_the_home_watch_batch_delay() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("index-watch-test-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("index.sqlite-wal");
        std::fs::write(&file, "before").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let wanted = file.clone();
        let watcher = Watcher::start_with_latency(&root, 0.0, move |path| {
            if path == Some(wanted.as_path()) {
                let _ = tx.send(());
            }
        })
        .expect("index stream");
        std::thread::sleep(std::time::Duration::from_millis(100));
        let started = std::time::Instant::now();
        std::fs::write(&file, "after").unwrap();
        rx.recv_timeout(std::time::Duration::from_millis(500))
            .expect("index notification within former poll interval");
        eprintln!("index notification latency: {:?}", started.elapsed());
        drop(watcher);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reports_changes_in_batches_and_nothing_from_excluded_folders() {
        let home = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("watch-test-{}", std::process::id()));
        std::fs::create_dir_all(home.join("Library/Caches")).unwrap();
        std::fs::create_dir_all(home.join("Documents")).unwrap();
        let seen = Arc::new(Mutex::new(vec![]));
        let record = seen.clone();
        let watcher = Watcher::start(&home, move |path| {
            record.lock().unwrap().push(path.map(Path::to_path_buf));
        })
        .expect("stream");
        std::thread::sleep(std::time::Duration::from_millis(300));
        std::fs::write(home.join("Documents/notes.md"), "x").unwrap();
        std::fs::write(home.join("Library/Caches/cache.db"), "x").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(
            (LATENCY * 1000.) as u64 + 1500,
        ));
        drop(watcher);
        let seen = seen.lock().unwrap();
        assert!(
            seen.contains(&Some(home.join("Documents/notes.md"))),
            "{seen:?}"
        );
        // The folder itself may show (it changed in the watched home); nothing inside it does.
        let inside = |p: &PathBuf| {
            p.strip_prefix(home.join("Library"))
                .is_ok_and(|rest| !rest.as_os_str().is_empty())
        };
        assert!(!seen.iter().flatten().any(inside), "{seen:?}");
        let _ = std::fs::remove_dir_all(&home);
    }
}
