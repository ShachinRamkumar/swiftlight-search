import DigUpCoreAIRuntime
import DigUpKit
import Foundation

// The lock diagnostic never loads a model. All real diagnostics run through digup.
func specializationLockDiagnostic(_ args: Arguments) throws {
    guard let runtime = args.values["--runtime"], let raw = args.values["--hold-ms"],
          let hold = Double(raw), hold >= 0, hold <= 60000 else {
        throw CLIError("specialization-lock needs --runtime DIR --hold-ms 0...60000 [--lock-timeout SECONDS]")
    }
    let path = SpecializationLock.path(runtime: URL(fileURLWithPath: runtime))
    let timeout = args.values["--lock-timeout"].flatMap(Double.init) ?? 600
    guard timeout >= 0, timeout <= 600 else { throw CLIError("invalid --lock-timeout") }
    emit(["event":"lock_attempt", "time":Date().timeIntervalSince1970, "path":path.path])
    let lock = try SpecializationLock(path: path, timeout: timeout)
    defer { withExtendedLifetime(lock) {} }
    emit(["event":"lock_acquired", "time":Date().timeIntervalSince1970])
    Thread.sleep(forTimeInterval: hold / 1000)
    if args.flags.contains("--throw-under-lock") { throw CLIError("diagnostic throw under lock") }
    emit(["event":"lock_releasing", "time":Date().timeIntervalSince1970])
}

private final class GateTrace: @unchecked Sendable {
    let control = ModelCallControl()
    var calls = 0
    func gate() throws {
        try control.waitForModelCall()
        calls += 1
        emit(["event":"inference_start", "call":calls, "time":Date().timeIntervalSince1970])
    }
}

func coreAIGateDiagnostic(_ args: Arguments) throws -> Int32 {
    guard let runtime = args.values["--runtime"], let file = args.values["--inputs"] else {
        throw CLIError("coreai-gate-check needs --runtime DIR --inputs JSON-array-of-texts")
    }
    let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath:file)))
    guard texts.count >= 4 else { throw CLIError("need at least four texts") }
    let trace = GateTrace()
    Thread.detachNewThread {
        while let command = readLine() {
            trace.control.command(command)
            emit(["event":"command", "command":command, "time":Date().timeIntervalSince1970])
        }
        trace.control.command("stop")
    }
    let result = DiagnosticResult(), done = DispatchSemaphore(value:0)
    Thread.detachNewThread {
        defer { done.signal() }
        do {
            guard #available(macOS 27, *) else { throw CLIError("requires macOS 27") }
            let embedder = try RuntimeDirectory(URL(fileURLWithPath:runtime)).embedder(.document, inferenceGate: { try trace.gate() })
            defer { embedder.close() }
            trace.control.command("pause")
            emit(["event":"batch_ready", "warmup_calls":trace.calls, "time":Date().timeIntervalSince1970])
            do {
                let vectors = try embedder.embedTexts(texts)
                emit(["event":"batch_result", "vectors":vectors.count, "buckets":embedder.lastTimings.map(\.bucket)])
            } catch {
                if !trace.control.isStopped { throw error }
                emit(["event":"batch_stopped", "returned_vectors":0, "message":"\(error)"])
            }
            result.status = 0
        } catch { emit(["event":"error", "message":"\(error)"]); result.status = 1 }
    }
    done.wait()
    return result.status
}
private final class DiagnosticResult: @unchecked Sendable { var status: Int32 = 1 }

func shadowCountsDiagnostic(_ args: Arguments) throws {
    guard args.values["--index"] != nil else { throw CLIError("shadow-counts needs explicit --index DIR") }
    let store = try args.store()
    var model: Int64?
    try store.db.query("SELECT id FROM embedding_models WHERE key='coreai-eg2-text-v1'") { model = $0.int(0) }
    guard let model else { throw CLIError("missing Core AI shadow model") }
    for _ in 0..<20 {
        let started = ProcessInfo.processInfo.systemUptime
        let counts = try store.shadowCounts(model:model)
        emit(["event":"counts", "ms":(ProcessInfo.processInfo.systemUptime-started)*1000,
              "done":counts.done, "eligible":counts.eligible, "failed":counts.failed])
    }
}
