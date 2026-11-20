//! How hard the Mac is already working. When it is hot or saturated (fans up, every core busy), the embedding model
//! stays unloaded: searches answer by name and by indexed words only, and indexing waits for it to calm down.

use std::ffi::c_void;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicI32, Ordering};

/// `kOSThermalNotificationPressureLevelName` (OSThermalNotification.h): 0 nominal, 1 moderate, 2 heavy, 3 trapping,
/// 4 sleeping. The same value backs `ProcessInfo.thermalState`.
const THERMAL_PRESSURE: &std::ffi::CStr = c"com.apple.system.thermalpressurelevel";

/// Public GCD memory-pressure flags from `<dispatch/source.h>`.
const DISPATCH_MEMORYPRESSURE_NORMAL: usize = 0x01;
const DISPATCH_MEMORYPRESSURE_WARN: usize = 0x02;
const DISPATCH_MEMORYPRESSURE_CRITICAL: usize = 0x04;
const DISPATCH_MEMORYPRESSURE_ALL: usize =
    DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL;
const QOS_CLASS_UTILITY: isize = 0x11;

unsafe extern "C" {
    fn notify_register_check(name: *const libc::c_char, token: *mut libc::c_int) -> u32;
    fn notify_get_state(token: libc::c_int, state: *mut u64) -> u32;
    static _dispatch_source_type_memorypressure: c_void;
    fn dispatch_get_global_queue(identifier: isize, flags: usize) -> *mut c_void;
    fn dispatch_source_create(
        kind: *const c_void,
        handle: usize,
        mask: usize,
        queue: *mut c_void,
    ) -> *mut c_void;
    fn dispatch_set_context(object: *mut c_void, context: *mut c_void);
    fn dispatch_source_set_event_handler_f(
        source: *mut c_void,
        handler: extern "C" fn(*mut c_void),
    );
    fn dispatch_source_get_data(source: *mut c_void) -> usize;
    fn dispatch_resume(object: *mut c_void);
    fn mach_port_deallocate(task: libc::mach_port_t, name: libc::mach_port_t) -> libc::kern_return_t;
}

#[derive(Clone, Copy, Debug)]
pub struct Load {
    /// 0 nominal … 4 sleeping.
    pub thermal: u64,
    /// macOS memory pressure: 1 normal, 2 warning, 4 critical.
    pub memory: i32,
    /// One-minute load average.
    pub load: f64,
    pub cpus: f64,
}

impl Load {
    pub fn now() -> Self {
        if let Some(forced) = std::env::var_os("SWIFTLIGHT_FORCE_BUSY") {
            let busy = forced != "0";
            return Load { thermal: busy as u64, memory: 1, load: 0., cpus: 1. };
        }
        let mut average = [0f64; 3];
        let load = if unsafe { libc::getloadavg(average.as_mut_ptr(), 3) } >= 1 { average[0] } else { 0. };
        Load { thermal: thermal_pressure(), memory: memory_pressure(), load, cpus: cpus() }
    }

    /// Why the query model should not start now, if it shouldn't: the Mac is warm enough that macOS is managing its
    /// temperature, every core has work queued, or memory is critically short. Memory warning alone doesn't count:
    /// on an 8 GB Mac it is the everyday state, and it would turn meaning search off most of the time.
    pub fn query_model_blocked(&self) -> Option<String> {
        if self.thermal >= 1 {
            Some(format!("thermal pressure {}", self.thermal))
        } else if self.memory >= 4 {
            Some(format!("memory pressure {}", self.memory))
        } else if self.load >= self.cpus {
            Some(format!("load {:.1} on {} cores", self.load, self.cpus))
        } else {
            None
        }
    }

    /// Why an indexing pass should not start now. Memory warning alone still allows indexing (it is throttled and
    /// watched separately); critical memory pressure is handled by the indexer itself.
    pub fn indexing_blocked(&self) -> Option<String> {
        if self.thermal >= 1 {
            Some(format!("thermal pressure {}", self.thermal))
        } else if self.load >= self.cpus {
            Some(format!("load {:.1} on {} cores", self.load, self.cpus))
        } else {
            None
        }
    }

    /// Whether a running indexing pass should stop. Only heavy thermal pressure counts: the pass raises the load
    /// average itself, and stopping on that would only restart it a minute later.
    pub fn indexing_must_stop(&self) -> bool {
        self.thermal >= 2
    }
}

fn thermal_pressure() -> u64 {
    static TOKEN: OnceLock<Option<libc::c_int>> = OnceLock::new();
    let token = *TOKEN.get_or_init(|| {
        let mut token = 0;
        (unsafe { notify_register_check(THERMAL_PRESSURE.as_ptr(), &mut token) } == 0).then_some(token)
    });
    let Some(token) = token else { return 0 };
    let mut state = 0u64;
    if unsafe { notify_get_state(token, &mut state) } == 0 { state } else { 0 }
}

static MEMORY_PRESSURE_LEVEL: AtomicI32 = AtomicI32::new(DISPATCH_MEMORYPRESSURE_NORMAL as i32);

extern "C" fn on_memory_pressure(source: *mut c_void) {
    let flags = unsafe { dispatch_source_get_data(source) };
    let level = if flags & DISPATCH_MEMORYPRESSURE_CRITICAL != 0 {
        DISPATCH_MEMORYPRESSURE_CRITICAL as i32
    } else if flags & DISPATCH_MEMORYPRESSURE_WARN != 0 {
        DISPATCH_MEMORYPRESSURE_WARN as i32
    } else {
        DISPATCH_MEMORYPRESSURE_NORMAL as i32
    };
    MEMORY_PRESSURE_LEVEL.store(level, Ordering::Relaxed);
}

/// Start the public GCD memory-pressure monitor eagerly at startup so OS transitions are observed early.
pub fn init_memory_monitor() {
    static MONITOR: OnceLock<()> = OnceLock::new();
    MONITOR.get_or_init(|| unsafe {
        let queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        let source = dispatch_source_create(
            &raw const _dispatch_source_type_memorypressure,
            0,
            DISPATCH_MEMORYPRESSURE_ALL,
            queue,
        );
        if !source.is_null() {
            dispatch_set_context(source, source);
            dispatch_source_set_event_handler_f(source, on_memory_pressure);
            dispatch_resume(source);
        }
    });
}

/// Synchronous memory-pressure estimate via public Mach `host_statistics64` + `hw.memsize`,
/// accounting for both reclaimable page headroom and VM compressor occupancy (deallocating the host port).
fn synchronous_vm_pressure() -> i32 {
    let mut total_bytes: u64 = 0;
    let mut total_size = std::mem::size_of::<u64>();
    let got_total = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut total_bytes).cast(),
            &mut total_size,
            std::ptr::null_mut(),
            0,
        )
    };
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if got_total != 0 || total_bytes == 0 || page_size <= 0 {
        return DISPATCH_MEMORYPRESSURE_NORMAL as i32;
    }

    let mut vm: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = (std::mem::size_of::<libc::vm_statistics64>()
        / std::mem::size_of::<libc::integer_t>()) as libc::mach_msg_type_number_t;
    #[allow(deprecated)]
    let host = unsafe { libc::mach_host_self() };
    let got_vm = unsafe {
        let status = libc::host_statistics64(
            host,
            libc::HOST_VM_INFO64,
            (&raw mut vm).cast::<libc::integer_t>(),
            &mut count,
        );
        #[allow(deprecated)]
        mach_port_deallocate(libc::mach_task_self(), host);
        status
    };
    if got_vm != libc::KERN_SUCCESS {
        return DISPATCH_MEMORYPRESSURE_NORMAL as i32;
    }

    let total_pages = (total_bytes / page_size as u64).max(1) as f64;
    // `free_count` already includes `speculative_count` in Mach `vm_statistics64`.
    let reclaimable_pages = u64::from(vm.free_count)
        .saturating_add(u64::from(vm.purgeable_count))
        .saturating_add(u64::from(vm.external_page_count)) as f64;
    let unavailable_pages = u64::from(vm.wire_count)
        .saturating_add(u64::from(vm.compressor_page_count)) as f64;
    let reclaimable_pct = (reclaimable_pages / total_pages) * 100.0;
    let compressor_pct = (f64::from(vm.compressor_page_count) / total_pages) * 100.0;
    let headroom_pct = ((total_pages - unavailable_pages).max(0.0) / total_pages) * 100.0;

    if reclaimable_pct < 8.0 || compressor_pct >= 60.0 || headroom_pct < 12.0 {
        DISPATCH_MEMORYPRESSURE_CRITICAL as i32
    } else if reclaimable_pct < 16.0 || compressor_pct >= 45.0 || headroom_pct < 25.0 {
        DISPATCH_MEMORYPRESSURE_WARN as i32
    } else {
        DISPATCH_MEMORYPRESSURE_NORMAL as i32
    }
}

/// macOS memory pressure combining public GCD `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`
/// and synchronous Mach `host_statistics64` sampling: 1 normal, 2 warning, 4 critical.
pub fn memory_pressure() -> i32 {
    init_memory_monitor();
    MEMORY_PRESSURE_LEVEL
        .load(Ordering::Relaxed)
        .max(synchronous_vm_pressure())
}

fn cpus() -> f64 {
    std::thread::available_parallelism().map_or(8, |n| n.get()) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(thermal: u64, memory: i32, load: f64) -> Load {
        Load { thermal, memory, load, cpus: 8. }
    }

    #[test]
    fn a_calm_mac_loads_the_model_and_indexes() {
        let calm = load(0, 1, 2.5);
        assert!(calm.query_model_blocked().is_none());
        assert!(calm.indexing_blocked().is_none());
        assert!(!calm.indexing_must_stop());
    }

    #[test]
    fn heat_or_saturation_keeps_the_model_unloaded() {
        assert!(load(1, 1, 0.).query_model_blocked().is_some());
        assert!(load(0, 4, 0.).query_model_blocked().is_some());
        assert!(load(0, 2, 0.).query_model_blocked().is_none());
        assert!(load(0, 1, 9.).query_model_blocked().is_some());
        assert!(load(1, 1, 0.).indexing_blocked().is_some());
        assert!(load(0, 1, 9.).indexing_blocked().is_some());
        // Memory warning still lets indexing run, as before.
        assert!(load(0, 2, 0.).indexing_blocked().is_none());
    }

    #[test]
    fn only_heavy_heat_stops_a_running_pass() {
        assert!(!load(1, 1, 12.).indexing_must_stop());
        assert!(load(2, 1, 0.).indexing_must_stop());
    }

    #[test]
    fn the_live_reading_is_sane() {
        let now = Load::now();
        assert!(now.thermal <= 4 && now.cpus >= 1. && now.load >= 0.);
        assert!(matches!(now.memory, 1 | 2 | 4));
    }
}
