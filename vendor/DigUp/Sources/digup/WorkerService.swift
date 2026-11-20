import DigUpKit
import Foundation
import DigUpCoreAIRuntime

/// Swiftlight's Core AI query encoder. Model calls block only on its dedicated thread.
func workerService(_ args: Arguments) -> Int32 {
    do {
        guard #available(macOS 27, *) else { throw CLIError("Core AI requires macOS 27") }
        return try coreAIQueryService(args)
    } catch {
        emit(["ready": false, "error": "\(error)"])
        return 1
    }
}

private final class WorkerExit: @unchecked Sendable { var status: Int32 = 1 }
func runWorkerService(_ args: Arguments) -> Int32 {
    let result = WorkerExit(), done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { result.status = workerService(args); done.signal() }
    done.wait()
    return result.status
}
