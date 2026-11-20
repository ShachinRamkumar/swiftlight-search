import CoreAI
import Darwin
import DigUpCoreAIRuntime
import Foundation

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return code == KERN_SUCCESS ? info.phys_footprint : 0
}
func systemWired() -> UInt64 {
    var info = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    return code == KERN_SUCCESS ? UInt64(info.wire_count) * UInt64(sysconf(_SC_PAGESIZE)) : 0
}
func emit(_ value: [String: Any]) {
    var value = value
    value["system_wired_bytes"] = systemWired()
    value["uptime"] = ProcessInfo.processInfo.systemUptime
    value["time"] = Date().timeIntervalSince1970
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
func ms(_ start: Date) -> Double { Date().timeIntervalSince(start)*1000 }

func waitForIndexDispatch(_ runtime: URL) throws {
    let path = runtime.deletingLastPathComponent().appendingPathComponent(".coreai-inference/dispatch.lock")
    let descriptor = open(path.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw NSError(domain: "dispatch lock missing", code: 5) }
    defer { Darwin.close(descriptor) }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return }
            throw NSError(domain: "dispatch lock probe failed", code: 6)
        }
        _ = flock(descriptor, LOCK_UN)
        Thread.sleep(forTimeInterval: 0.001)
    }
    throw NSError(domain: "index dispatch did not begin", code: 7)
}

@available(macOS 27, *)
private final class IndexCall: @unchecked Sendable {
    let model: CoreAIEmbedder
    var error: Error?
    init(_ model: CoreAIEmbedder) { self.model = model }
}

@available(macOS 27, *)
@main struct Lifecycle {
    static func main() async {
        do { try await Task.detached(priority: .userInitiated) { try run() }.value }
        catch { emit(["error": String(describing: error)]); exit(1) }
    }
    static func run() throws {
        guard ["org.swiftlight.storage.research.single-model", "org.swiftlight.storage.research.compile-speed"].contains(Bundle.main.bundleIdentifier ?? "") else { throw NSError(domain: "wrong research identity", code: 1) }
        let args = CommandLine.arguments
        let runtime = try RuntimeDirectory(URL(fileURLWithPath: args[2]))
        switch args[1] {
        case "download":
            try runtime.restoreSourceFromDownload()
            emit(["phase": "downloaded-and-verified", "footprint": footprint()])
        case "setup":
            try runtime.prepareSingleModel(forceRepair: true) { emit(["phase": $0.rawValue, "footprint": footprint()]) }
        case "panel":
            let query = PanelQueryEncoder(directory: runtime.directory, prepare: { try runtime.embedder(.query) }, log: { emit(["phase": $0, "footprint": footprint()]) })
            emit(["phase": "closed-initial", "footprint": footprint()])
            for round in 0..<3 {
                let open = Date(); query.open()
                while query.status == "preparing" { Thread.sleep(forTimeInterval: 0.001) }
                emit(["phase": "open-ready", "round": round, "ms": ms(open), "footprint": footprint(), "status": query.status])
                let first = Date(); let result = try query.encode(["task: search result | query: research fixture"])
                emit(["phase": "first-query", "round": round, "ms": ms(first), "hotkey_to_result_ms": ms(open), "elements": result.first?.count ?? 0, "footprint": footprint()])
                query.close(); Thread.sleep(forTimeInterval: 0.2)
                emit(["phase": "closed", "round": round, "footprint": footprint(), "status": query.status])
            }
            let typed = Date(); query.open()
            Thread.sleep(forTimeInterval: 0.1)
            _ = try query.encode(["task: search result | query: typed fixture"])
            emit(["phase": "typed-result", "typing_delay_ms": 100, "hotkey_to_result_ms": ms(typed), "footprint": footprint()])
            query.close()
            for cycle in 0..<20 {
                query.open(); Thread.sleep(forTimeInterval: 0.005); query.close(); Thread.sleep(forTimeInterval: 0.005)
                emit(["phase": "rapid-cycle", "cycle": cycle, "status": query.status, "footprint": footprint()])
            }
            query.open(); _ = try query.encode(["task: search result | query: final fixture"]); query.close()
            Thread.sleep(forTimeInterval: 0.2)
            emit(["phase": "rapid-complete", "status": query.status, "footprint": footprint()])
            Thread.sleep(forTimeInterval: 2)
            emit(["phase": "closed-settled", "status": query.status, "footprint": footprint()])
        case "priority":
            let query = PanelQueryEncoder(directory: runtime.directory, prepare: { try runtime.embedder(.query) })
            query.open(); _ = try query.encode(["task: search result | query: warm fixture"]); query.close()
            let entered = DispatchSemaphore(value: 0)
            let index = IndexCall(try runtime.embedder(.document, inferenceGate: { entered.signal() }))
            defer { index.model.close(); query.close() }
            let function = args[3]
            try index.model.warmFunction(function)
            while entered.wait(timeout: .now()) == .success {}
            // Open after dispatch to measure the unavoidable remainder of an existing call.
            let inflightDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                defer { inflightDone.signal() }
                do { try index.model.warmFunction(function) } catch { index.error = error }
            }
            guard entered.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "index did not begin", code: 3) }
            try waitForIndexDispatch(runtime.directory)
            let opening = Date(); query.open()
            _ = try query.encode(["task: search result | query: in flight fixture"])
            emit(["phase": "query-inflight-on-open", "function": function, "ms": ms(opening)])
            inflightDone.wait()
            if let error = index.error { throw error }
            for round in 0..<10 {
                let idle = Date(); _ = try query.encode(["task: search result | query: idle fixture \(round)"])
                let idleMS = ms(idle)
                let done = DispatchSemaphore(value: 0)
                index.error = nil
                emit(["phase": "panel-index-attempt", "round": round])
                Thread.detachNewThread {
                    defer { done.signal() }
                    do { try index.model.warmFunction(function) } catch { index.error = error }
                }
                guard entered.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "index attempt did not begin", code: 3) }
                Thread.sleep(forTimeInterval: 0.05)
                let busy = Date(); _ = try query.encode(["task: search result | query: busy fixture \(round)"])
                let busyMS = ms(busy)
                guard done.wait(timeout: .now()) == .timedOut else { throw NSError(domain: "index completed while panel open", code: 8) }
                emit(["phase": "panel-closing", "round": round])
                query.close()
                guard done.wait(timeout: .now() + 15) == .success else { throw NSError(domain: "index did not resume on close", code: 9) }
                if let error = index.error { throw error }
                emit(["phase": "query-priority", "function": function, "round": round, "idle_ms": idleMS, "indexing_ms": busyMS,
                      "index_paused_until_close": true])
                query.open(); _ = try query.encode(["task: search result | query: reopened fixture"])
            }
        case "index":
            let query = PanelQueryEncoder(directory: runtime.directory, prepare: { try runtime.embedder(.query) }, log: { emit(["phase": $0, "footprint": footprint()]) })
            query.open(); _ = try query.encode(["task: search result | query: warm fixture"]); query.close()
            let index = try runtime.embedder(.document, prepareQueryFirst: true, inferenceGate: { emit(["phase": "index-before-load", "footprint": footprint()]) })
            for name in args.dropFirst(3) {
                let started = Date()
                try index.warmFunction(name)
                emit(["phase": "index-after-call", "function": name, "ms": ms(started), "loaded_assets": try index.loadedAssets(), "footprint": footprint()])
                Thread.sleep(forTimeInterval: 0.1)
                emit(["phase": "index-after-unload", "function": name, "footprint": footprint()])
            }
            index.close(); query.close()
            emit(["phase": "all-unloaded", "footprint": footprint()])
        default: throw NSError(domain: "unknown operation", code: 2)
        }
    }
}
