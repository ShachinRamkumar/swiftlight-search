import DigUpCoreAIRuntime
import Foundation

private final class SetupExitStatus: @unchecked Sendable { var status: Int32 = 1 }

func prepareRuntime(_ args: Arguments) throws -> Int32 {
    guard let path = args.values["--runtime"] else { throw CLIError("prepare-runtime requires --runtime DIR") }
    let result = SetupExitStatus(), done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { done.signal() }
        do {
            guard #available(macOS 27, *) else { throw CLIError("Core AI requires macOS 27") }
            let runtime = try RuntimeDirectory(URL(fileURLWithPath: path), fullVerify: true)
            try runtime.prepareSingleModel(deleteSourceAfterCompile: args.flags.contains("--delete-source-after-compile")) { phase in
                emit(["event": "model-setup", "phase": phase.rawValue, "message": phase.message])
            }
            result.status = 0
        } catch { emit(["event": "error", "message": String(describing: error), "fatal": true]) }
    }
    done.wait()
    return result.status
}
