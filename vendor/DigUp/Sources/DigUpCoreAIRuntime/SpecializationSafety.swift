import Darwin
import DigUpKit
import Dispatch
import Foundation

/// One lock for all assets in a runtime, outside its immutable manifest directory.
public final class SpecializationLock {
    private let fd: Int32
    public static func path(runtime: URL) -> URL {
        runtime.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(".coreai-specialize.lock")
    }

    public init(path: URL, timeout: TimeInterval = 600,
                now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) throws {
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkerError.failed("cannot open specialization lock: \(path.path), errno=\(errno)") }
        let started = now()
        var waiting = false
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw WorkerError.failed("cannot acquire specialization lock, errno=\(errno)")
                }
                if !waiting { log("specialization lock waiting begin path=\(path.path)"); waiting = true }
                guard now() - started < timeout else {
                    throw WorkerError.failed("specialization lock timed out after \(timeout) s: \(path.path)")
                }
                sleep(min(0.25, max(0, timeout - (now() - started))))
            }
        } catch {
            if waiting { log("specialization lock waiting end failed after \(now() - started) s") }
            Darwin.close(descriptor)
            throw error
        }
        if waiting { log("specialization lock waiting end acquired after \(now() - started) s") }
        fd = descriptor
    }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }

    /// The caller retains the returned lease through verification, repair and validation.
    public static func acquireAndReprobe<T>(path: URL, timeout: TimeInterval = 600,
                                            log: (String) -> Void,
                                            reprobe: () throws -> T?) throws -> (lease: SpecializationLock, cached: T?) {
        let lease = try SpecializationLock(path: path, timeout: timeout, log: log)
        return (lease, try reprobe())
    }
}

public enum SpecializationAdmission {
    public enum Pressure: Int, Sendable, Comparable {
        case normal = 1
        case warning = 2
        case critical = 4

        public static func < (lhs: Pressure, rhs: Pressure) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private final class MemoryPressureMonitor: @unchecked Sendable {
        static let shared = MemoryPressureMonitor()
        private let lock = NSLock()
        private var current: Pressure = .normal
        private let source: DispatchSourceMemoryPressure

        private init() {
            let queue = DispatchQueue(label: "com.shachin.swiftlight.memory-pressure", qos: .utility)
            let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
            self.source = monitor
            monitor.setEventHandler { [weak self] in
                guard let self else { return }
                let event = self.source.data
                let next: Pressure
                if event.contains(.critical) {
                    next = .critical
                } else if event.contains(.warning) {
                    next = .warning
                } else {
                    next = .normal
                }
                self.lock.lock()
                self.current = next
                self.lock.unlock()
            }
            monitor.resume()
        }

        func level() -> Pressure {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    /// Public macOS system-wide free memory percentage via documented `/usr/bin/memory_pressure` (no private flags),
    /// matching macOS's own pressure calculation including VM compressor headroom.
    public static func freeMemoryPercent() throws -> Double {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        process.arguments = []
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let last = text.components(separatedBy: "free percentage:").last,
              let value = Double(last.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) else {
            throw WorkerError.failed("cannot read system-wide free memory percentage")
        }
        return value
    }

    /// Synchronous Mach VM compressor & headroom pressure check (always releasing the Mach host send right).
    private static func machHeadroomPressure() throws -> Pressure {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else {
            throw WorkerError.failed("cannot read physical memory size")
        }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            throw WorkerError.failed("cannot read Mach VM page size")
        }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status: kern_return_t = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw WorkerError.failed("cannot read Mach VM statistics, status=\(status)")
        }
        let totalPages = max(1.0, total / Double(pageSize))
        // `free_count` already includes `speculative_count` in Mach `vm_statistics64`.
        let reclaimablePages = Double(UInt64(vm.free_count) + UInt64(vm.purgeable_count) + UInt64(vm.external_page_count))
        let unavailablePages = Double(UInt64(vm.wire_count) + UInt64(vm.compressor_page_count))
        let reclaimablePct = (reclaimablePages / totalPages) * 100.0
        let compressorPct = (Double(vm.compressor_page_count) / totalPages) * 100.0
        let headroomPct = (max(0.0, totalPages - unavailablePages) / totalPages) * 100.0
        if reclaimablePct < 8.0 || compressorPct >= 60.0 || headroomPct < 12.0 {
            return .critical
        }
        if reclaimablePct < 16.0 || compressorPct >= 45.0 || headroomPct < 25.0 {
            return .warning
        }
        return .normal
    }

    public static func kernelPressure() throws -> Pressure {
        let asyncLevel = MemoryPressureMonitor.shared.level()
        let machLevel = try machHeadroomPressure()
        let freePct = try freeMemoryPercent()
        let freeLevel: Pressure = freePct < 12.0 ? .critical : (freePct < 25.0 ? .warning : .normal)
        return max(asyncLevel, max(machLevel, freeLevel))
    }

    public static func check(minimumDisk: Int64 = 8_000_000_000,
                             warningTimeout: TimeInterval = 30,
                             allowWarning: Bool = false,
                             freeDisk: () throws -> Int64,
                             pressure: () throws -> Pressure = kernelPressure,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let started = now()
        while true {
            let free = try freeDisk()
            guard free >= minimumDisk else {
                throw WorkerError.failed("specialization admission refused: free disk \(free) below \(minimumDisk) bytes")
            }
            switch try pressure() {
            case .normal: return
            case .critical: throw WorkerError.failed("specialization admission refused: critical memory pressure")
            case .warning:
                if allowWarning { return }
                guard now() - started < warningTimeout else {
                    throw WorkerError.failed("specialization admission refused: warning memory pressure for \(warningTimeout) s")
                }
                sleep(min(0.25, max(0, warningTimeout - (now() - started))))
            }
        }
    }

    public static func check(runtime: URL) throws {
        let raw = ProcessInfo.processInfo.environment["DIGUP_COREAI_MIN_FREE_DISK_BYTES"] ?? "8000000000"
        guard let minimum = Int64(raw), minimum >= 0 else {
            throw WorkerError.failed("invalid DIGUP_COREAI_MIN_FREE_DISK_BYTES: \(raw)")
        }
        let visionRuntime = runtime.lastPathComponent == "coreai-eg2-v1"
        func checkDiskAndPressure() throws {
        try check(minimumDisk: visionRuntime ? max(minimum,9_000_000_000) : minimum, allowWarning: visionRuntime, freeDisk: {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: runtime.path)
            guard let free = attributes[.systemFreeSize] as? NSNumber else {
                throw WorkerError.failed("cannot read free disk for specialization admission")
            }
            return free.int64Value
        })
        }
        try checkDiskAndPressure()
        if visionRuntime {
            let started = ProcessInfo.processInfo.systemUptime
            while true {
                let value = try freeMemoryPercent()
                if value >= 25 { break }
                guard value >= 12, ProcessInfo.processInfo.systemUptime - started < 1800 else {
                    throw WorkerError.failed("specialization admission refused: free memory below 25%")
                }
                FileHandle.standardError.write(Data(String(format: "specialization admission waiting: free memory %.1f%%\n", value).utf8))
                Thread.sleep(forTimeInterval: 30)
                try checkDiskAndPressure()
            }
        }
    }
}
