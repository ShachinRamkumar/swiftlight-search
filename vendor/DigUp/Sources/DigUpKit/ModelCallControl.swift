import Foundation

/// Cooperative suspension at model-call boundaries. Repeated pause commands renew the lease.
public final class ModelCallControl: @unchecked Sendable {
    private let condition=NSCondition()
    private var until: TimeInterval=0
    private var stopped=false
    public init() {}

    public func command(_ command: String) {
        condition.lock()
        defer { condition.unlock() }
        switch command {
        case "pause": until=ProcessInfo.processInfo.systemUptime+60
        case "resume": until=0
        case "stop": stopped=true
        default: return
        }
        condition.broadcast()
    }

    public func waitForModelCall() throws {
        condition.lock()
        defer { condition.unlock() }
        while !stopped {
            let left=until-ProcessInfo.processInfo.systemUptime
            if left<=0 { return }
            _=condition.wait(until:Date().addingTimeInterval(min(left,0.5)))
        }
        throw WorkerError.died("stop requested")
    }
    public var isStopped: Bool {
        condition.lock();defer { condition.unlock() };return stopped
    }
}
