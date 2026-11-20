import Darwin
import Foundation

/// Opt-in checkpoints on stderr; stdout remains the worker protocol.
public enum RuntimeDiagnostics {
    public static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public static func mark(_ point: String) {
        guard ProcessInfo.processInfo.environment["DIGUP_RUNTIME_DIAGNOSTICS"] == "1" else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let record: [String: Any] = ["point": point, "pid": getpid(),
            "thread_qos": Thread.current.qualityOfService.rawValue,
            "effective_qos": qos_class_self().rawValue,
            "nice": getpriority(PRIO_PROCESS, 0),
            "monotonic_s": ProcessInfo.processInfo.systemUptime, "task_info_status": status,
            "rss_bytes": info.resident_size, "phys_footprint_bytes": info.phys_footprint]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            FileHandle.standardError.write(Data("RUNTIME_DIAGNOSTIC ".utf8) + data + Data([10]))
        }
    }
}
