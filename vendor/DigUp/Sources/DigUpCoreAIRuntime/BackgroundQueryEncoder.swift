import DigUpKit
import Foundation

/// One serialized encoder, prepared and repaired outside the request thread.
public final class BackgroundQueryEncoder: @unchecked Sendable {
    public enum Status: String { case preparing, ready, failed }
    private let condition = NSCondition()
    private let log: @Sendable (String) -> Void
    private let requestBudget: TimeInterval
    private let prepareModel: @Sendable () throws -> any Embedder
    private let now: @Sendable () -> TimeInterval
    private let freeDisk: @Sendable () -> UInt64?
    private var embedder: (any Embedder)?
    private var busy = true
    private var result: (inputs: [String], vectors: [[Float]])?
    private var failure: String?
    private var retry = ModelPreparationRetry()

    public init(requestBudget: TimeInterval = 0.05,
                prepare: @escaping @Sendable () throws -> any Embedder,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                freeDisk: @escaping @Sendable () -> UInt64? = {
                    let info = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
                    return (info?[.systemFreeSize] as? NSNumber)?.uint64Value
                },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
        self.requestBudget = requestBudget
        self.prepareModel = prepare; self.now = now; self.freeDisk = freeDisk
        beginPreparation()
    }

    private func beginPreparation() {
        let preparation = Thread { [self] in
            log("query preparation started in background")
            embedder?.close()
            do {
                let model = try prepareModel()
                condition.lock()
                embedder = model; busy = false; retry = ModelPreparationRetry()
                condition.broadcast(); condition.unlock()
                log("query ready")
            } catch {
                condition.lock()
                embedder = nil; failure = String(describing: error); busy = false
                retry.failed(failure!, now: now())
                condition.broadcast(); condition.unlock()
                log("query preparation failed: \(error)")
            }
        }
        preparation.qualityOfService = .userInitiated
        preparation.start()
    }

    public func encode(_ inputs: [String]) throws -> [[Float]] {
        condition.lock()
        defer { condition.unlock() }
        if let result, result.inputs == inputs { return result.vectors }
        if let failure {
            if retry.canRetry(now: now(), freeBytes: freeDisk()) {
                busy = true; self.failure = nil; result = nil
                beginPreparation()
                throw WorkerError.failed("coreai readiness pending")
            }
            throw WorkerError.failed("coreai readiness failed: \(failure)")
        }
        guard !busy, embedder != nil else { throw WorkerError.failed("coreai readiness pending") }
        busy = true; result = nil
        let encoding = Thread { [self] in
            let completed: Result<[[Float]], Error>
            do { completed = .success(try self.embedder!.embedTexts(inputs)) }
            catch { completed = .failure(error) }
            condition.lock()
            switch completed {
            case .success(let vectors): result = (inputs, vectors)
            case .failure(let error) where error is ModelSetupPending: break
            case .failure(let error):
                failure = String(describing: error)
                retry.failed(failure!, now: now())
            }
            busy = false; condition.broadcast(); condition.unlock()
            if case .failure(let error) = completed, !(error is ModelSetupPending) { log("query failed: \(error)") }
        }
        encoding.qualityOfService = .userInitiated
        encoding.start()
        let deadline = Date().addingTimeInterval(requestBudget)
        while busy, condition.wait(until: deadline) {}
        if let result, result.inputs == inputs { return result.vectors }
        if let failure { throw WorkerError.failed("coreai readiness failed: \(failure)") }
        throw WorkerError.failed("coreai readiness pending")
    }

    public var status: Status {
        condition.lock(); defer { condition.unlock() }
        return failure != nil ? .failed : (busy ? .preparing : .ready)
    }

    deinit { embedder?.close() }
}
