import Foundation

/// One in-flight check per root. A TCC open can wait indefinitely; it never owns the sync thread.
public final class RootAccess: @unchecked Sendable {
    public enum State: String, Sendable { case ready, pending, denied, missing }
    private struct Check { var state: State; var checked: Date }
    private let condition = NSCondition()
    private var checks: [URL: Check] = [:]
    private let probe: @Sendable (URL) -> State
    private let retry: TimeInterval

    public init(retry: TimeInterval = 30, probe: @escaping @Sendable (URL) -> State = RootAccess.read) {
        self.retry = retry
        self.probe = probe
    }

    public static func read(_ root: URL) -> State {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return .ready
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .denied
        }
    }

    public func check(_ roots: [URL], wait: TimeInterval = 0.15) -> [URL: State] {
        condition.lock()
        for root in roots {
            if let old = checks[root], old.state == .pending || Date().timeIntervalSince(old.checked) < retry { continue }
            checks[root] = Check(state: .pending, checked: Date())
            Thread.detachNewThread { [self] in
                let result = probe(root)
                condition.lock()
                checks[root] = Check(state: result, checked: Date())
                condition.broadcast()
                condition.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(wait)
        while roots.contains(where: { checks[$0]?.state == .pending }), condition.wait(until: deadline) {}
        let result = Dictionary(uniqueKeysWithValues: roots.map { ($0, checks[$0]!.state) })
        condition.unlock()
        return result
    }
}
