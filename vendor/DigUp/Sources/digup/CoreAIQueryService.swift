import DigUpKit
import DigUpCoreAIRuntime
import Foundation

func readinessLog(_ text: String) {
    let data = Data("[coreai-readiness] \(text)\n".utf8)
    FileHandle.standardError.write(data)
    let path = RuntimeReadiness.logURL.path
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    }
}

private final class SetupAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func failed(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
    func failure() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}

@available(macOS 27, *)
func coreAIQueryService(_ args: Arguments) throws -> Int32 {
    guard args.flags.contains("--text-only"), let path = args.values["--runtime"] else {
        throw CLIError("Core AI worker needs --text-only and --runtime DIR")
    }
    let runtime = try RuntimeDirectory(URL(fileURLWithPath: path))
    let functions = ["q32", "q64", "q128"]
    RuntimeReadiness.record(runtime, role: "query", status: "preparing", functions: functions)
    let readiness = PanelQueryEncoder(directory: runtime.directory, prepare: {
        do {
            if runtime.assets.names == ["EmbeddingGemma2.aimodel"] && !runtime.hasCompleteSetupCheckpoint {
                let attempt = SetupAttempt()
                let setup = Thread {
                    do { try runtime.prepareSingleModel { phase in readinessLog(phase.message) } }
                    catch { attempt.failed(error); readinessLog("Background model setup failed: \(error)") }
                }
                setup.qualityOfService = .utility
                setup.start()
                // Only text readiness blocks preparation; media groups continue on the setup thread.
                while true {
                    do {
                        if !runtime.hasPreparedQueryGroup && setup.isExecuting {
                            Thread.sleep(forTimeInterval: 0.1)
                            continue
                        }
                        let model = try runtime.embedder(.query)
                        RuntimeReadiness.record(runtime, role: "query", status: "ready", functions: ["q32", "q64", "q128"])
                        return model
                    } catch {
                        if !setup.isExecuting { throw attempt.failure() ?? error }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }
            let model = try runtime.embedder(.query)
            RuntimeReadiness.record(runtime, role: "query", status: "ready", functions: functions)
            return model
        } catch {
            RuntimeReadiness.record(runtime, role: "query", status: "failed", functions: functions, failure: String(describing: error))
            throw error
        }
    })
    readiness.open()
    let info: [String: Any] = ["model": "google/embeddinggemma-2", "revision": runtime.assets.revision,
        "runtime": "coreai-ane", "dtype": "fp16", "dim": 768, "text_only": true, "load_seconds": 0]
    emit(["ready": true, "status": "preparing", "info": info])
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let id = request["id"] ?? NSNull()
        switch request["op"] as? String {
        case "panel_opened": readiness.open()
        case "panel_closed": readiness.close()
        case "quit": readiness.close(); emit(["id": id, "ok": true]); return 0
        case "info": emit(["id": id, "ok": true, "info": info, "status": readiness.status])
        case "text":
            do {
                let inputs = request["inputs"] as? [String] ?? []
                if readiness.status == "failed" { readiness.open() }
                let encodingStarted = Date.timeIntervalSinceReferenceDate
                let vectors = try readiness.encode(inputs).flatMap { $0 }
                let encodeMilliseconds = (Date.timeIntervalSinceReferenceDate - encodingStarted) * 1000
                var response: [String: Any] = ["id": id, "ok": true, "dim": 768, "count": inputs.count,
                    "vectors": vectors.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString(),
                    "errors": inputs.map { _ in NSNull() }]
                if ProcessInfo.processInfo.environment["SPOTLIGHT_PROFILE"] != nil {
                    response["profile_encode_ms"] = encodeMilliseconds
                }
                emit(response)
            } catch { emit(["id": id, "ok": false, "error": String(describing: error)]) }
        default: emit(["id": id, "ok": false, "error": "Core AI query worker is text-only"])
        }
    }
    return 0
}
