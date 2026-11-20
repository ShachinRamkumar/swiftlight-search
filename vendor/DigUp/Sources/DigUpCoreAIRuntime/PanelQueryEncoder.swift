import Darwin
import DigUpKit
import Foundation

public protocol PanelQueryProgram: Embedder {
    func loadQueryProgram() throws
    func unloadQueryProgram()
}

/// CPU tokenization state can be reused. Models and functions belong to the visible panel.
public final class PanelQueryEncoder: @unchecked Sendable {
    private let condition = NSCondition()
    private let log: @Sendable (String) -> Void
    private let prepare: @Sendable () throws -> any Embedder
    private let directory: URL?
    private var panelAnnouncement: InferencePriority.QueryAnnouncement?
    private var visible = false
    private var preparing = false
    private var programReady = false
    private var active = 0
    private var model: (any Embedder)?
    private var failure: Error?
    private var retry = ModelPreparationRetry()

    public init(directory: URL? = nil, prepare: @escaping @Sendable () throws -> any Embedder,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.directory = directory; self.prepare = prepare; self.log = log
    }

    public func open() {
        condition.lock(); defer { condition.unlock() }
        if InferencePriority.pauseIndexingWhilePanelOpen, panelAnnouncement == nil, let directory {
            do { panelAnnouncement = try InferencePriority.QueryAnnouncement(directory: directory) }
            catch { failure = error; return }
        }
        visible = true
        guard !programReady, !preparing else { return }
        if let failure, !(failure is ModelSetupPending) {
            let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = (disk?[.systemFreeSize] as? NSNumber)?.uint64Value
            guard retry.canRetry(now: ProcessInfo.processInfo.systemUptime, freeBytes: free) else { return }
        }
        preparing = true; failure = nil
        log("query_load_started")
        let thread = Thread { [self] in
            let result: Result<any Embedder, Error> = Result {
                try autoreleasepool {
                    condition.lock()
                    let existing = model as? any PanelQueryProgram
                    condition.unlock()
                    if let existing { try existing.loadQueryProgram(); return existing }
                    return try prepare()
                }
            }
            condition.lock()
            preparing = false
            switch result {
            case .success(let loaded):
                model = loaded; programReady = true; retry = ModelPreparationRetry()
                if visible { log("query_group_ready") } else { unload() }
            case .failure(let error):
                failure = error
                if !(error is ModelSetupPending) { retry.failed(String(describing: error), now: ProcessInfo.processInfo.systemUptime) }
            }
            condition.broadcast(); condition.unlock()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func unload() {
        autoreleasepool {
            if let reusable = model as? any PanelQueryProgram { reusable.unloadQueryProgram() }
            else { model?.close(); model = nil }
        }
        programReady = false
        _ = malloc_zone_pressure_relief(nil, 0)
        log("query_group_unloaded")
    }

    public func close() {
        condition.lock(); defer { condition.unlock() }
        visible = false
        panelAnnouncement = nil
        if active == 0 && !preparing { unload() }
        condition.broadcast()
    }

    public func encode(_ inputs: [String]) throws -> [[Float]] {
        condition.lock()
        while (preparing || active > 0) && visible { condition.wait() }
        if let failure {
            condition.unlock()
            if failure is ModelSetupPending { throw WorkerError.failed("coreai readiness pending") }
            throw failure
        }
        guard visible, programReady, let loaded = model else {
            condition.unlock(); throw WorkerError.failed("query panel is closed")
        }
        active += 1; condition.unlock()
        defer {
            condition.lock(); active -= 1
            if !visible && active == 0 { unload() }
            condition.broadcast(); condition.unlock()
        }
        do { return try loaded.embedTexts(inputs) }
        catch is ModelSetupPending { throw WorkerError.failed("coreai readiness pending") }
    }

    public var status: String {
        condition.lock(); defer { condition.unlock() }
        return failure != nil ? "failed" : (preparing ? "preparing" : (programReady ? "ready" : "closed"))
    }
    deinit { model?.close() }
}
