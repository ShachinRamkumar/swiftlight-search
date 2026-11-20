import Darwin
import DigUpKit
import Foundation

/// A shared dispatch gate for query and indexer processes. An executing ANE call cannot be interrupted.
final class InferencePriority: @unchecked Sendable {
    static let pauseIndexingWhilePanelOpen = true

    final class QueryAnnouncement {
        private let path: URL
        init(directory: URL) throws {
            let root = directory.deletingLastPathComponent().appendingPathComponent(".coreai-inference")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("query-\(getpid())-\(UUID().uuidString)")
            try Data().write(to: path, options: .atomic)
        }
        deinit { try? FileManager.default.removeItem(at: path) }
    }

    private let descriptor: Int32
    private let pending: URL?

    init(directory: URL, query: Bool) throws {
        let root = directory.deletingLastPathComponent().appendingPathComponent(".coreai-inference")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = query ? root.appendingPathComponent("query-\(getpid())-\(UUID().uuidString)") : nil
        if let marker { try Data().write(to: marker, options: .atomic) }
        let fd = open(root.appendingPathComponent("dispatch.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if let marker { try? FileManager.default.removeItem(at: marker) }
            throw WorkerError.failed("cannot open inference dispatch lock")
        }
        do {
            while true {
                guard flock(fd, LOCK_EX) == 0 else { throw WorkerError.failed("cannot acquire inference dispatch lock") }
                if query { break }
                if try !Self.queryPending(in: root) { break }
                _ = flock(fd, LOCK_UN)
                Thread.sleep(forTimeInterval: 0.002)
            }
        } catch {
            _ = flock(fd, LOCK_UN); Darwin.close(fd)
            if let marker { try? FileManager.default.removeItem(at: marker) }
            throw error
        }
        descriptor = fd; pending = marker
    }
    static func queryPending(in root: URL) throws -> Bool {
        var pending = false
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where path.lastPathComponent.hasPrefix("query-") {
            let parts = path.lastPathComponent.split(separator: "-")
            guard parts.count >= 3, let pid = Int32(parts[1]), pid > 0 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { pending = true }
            else if errno == ESRCH { try? FileManager.default.removeItem(at: path) }
        }
        return pending
    }
    deinit {
        if let pending { try? FileManager.default.removeItem(at: pending) }
        _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor)
    }
}
