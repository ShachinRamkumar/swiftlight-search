import Darwin
import DigUpKit
@testable import DigUpCoreAIRuntime
import XCTest

private final class CallOrder: @unchecked Sendable {
    let lock = NSLock()
    var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class SingleModelSchedulingTests: XCTestCase {
    func testPendingQueryOvertakesQueuedIndexDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inference-priority-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        var running: InferencePriority? = try InferencePriority(directory: runtime, query: false)
        XCTAssertNotNil(running)
        let order = CallOrder()
        let query = expectation(description: "query dispatched")
        let index = expectation(description: "index dispatched")
        DispatchQueue.global().async {
            do {
                let lease = try InferencePriority(directory: runtime, query: false)
                order.append("index")
                withExtendedLifetime(lease) {}
            } catch { XCTFail(String(describing: error)) }
            index.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lease = try InferencePriority(directory: runtime, query: true)
                order.append("query")
                withExtendedLifetime(lease) {}
            } catch { XCTFail(String(describing: error)) }
            query.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while try !InferencePriority.queryPending(in: root.appendingPathComponent(".coreai-inference")), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(try InferencePriority.queryPending(in: root.appendingPathComponent(".coreai-inference")))
        running = nil
        wait(for: [query, index], timeout: 3)
        XCTAssertEqual(order.read(), ["query", "index"])
    }

    func testOpenPanelHoldsIndexingBetweenQueriesAndCloseResumesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-dispatch-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        // Preparation failure must not let indexing steal the panel's dispatch window.
        let panel = PanelQueryEncoder(directory: runtime, prepare: { throw WorkerError.failed("fixture unavailable") })
        panel.open()
        XCTAssertThrowsError(try panel.encode(["fixture"]))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            do {
                let lease = try InferencePriority(directory: runtime, query: false)
                withExtendedLifetime(lease) {}
            } catch { XCTFail(String(describing: error)) }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        do {
            let query = try InferencePriority(directory: runtime, query: true)
            withExtendedLifetime(query) {}
        }
        panel.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(try InferencePriority.queryPending(in: root.appendingPathComponent(".coreai-inference")))
    }

    func testPanelPauseLetsInflightCallFinishAndResumesAfterLastPanelCloses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-overlap-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        var running: InferencePriority? = try InferencePriority(directory: runtime, query: false)
        XCTAssertNotNil(running)
        var panel: InferencePriority.QueryAnnouncement? = try InferencePriority.QueryAnnouncement(directory: runtime)
        var otherPanel: InferencePriority.QueryAnnouncement? = try InferencePriority.QueryAnnouncement(directory: runtime)
        XCTAssertNotNil(panel); XCTAssertNotNil(otherPanel)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let lease = try InferencePriority(directory: runtime, query: false)
                withExtendedLifetime(lease) {}
            } catch { XCTFail(String(describing: error)) }
            finished.signal()
        }
        running = nil
        panel = nil
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        otherPanel = nil
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    @available(macOS 27, *)
    func testCompilerIdentityChangesOnlyDiagnosticProducerAndHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compiler-identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x4d,0x4c,0xef,0x52,0x0d]) + Data("MLIR22.0.0git\0unchanged IR and weights".utf8)
        let file = root.appendingPathComponent("main.mlirb")
        try bytes.write(to: file)
        let first = try SingleModelGroups.renewCompilerIdentity(root)
        let changed = try Data(contentsOf: file)
        XCTAssertEqual(changed.count, bytes.count)
        XCTAssertEqual(changed.prefix(5), bytes.prefix(5))
        XCTAssertEqual(changed.dropFirst(18), bytes.dropFirst(18))
        XCTAssertEqual(first, QueryBootstrap.digest(changed))
        XCTAssertNotEqual(try SingleModelGroups.renewCompilerIdentity(root), first)
        try Data("not MLIR".utf8).write(to: file)
        XCTAssertThrowsError(try SingleModelGroups.renewCompilerIdentity(root))
    }

    func testTempCleanupDeletesOnlyRecordedCompletedRegionsWithMatchingInodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compiler-cleanup-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        let temporary = root.appendingPathComponent("temp")
        let own = temporary.appendingPathComponent("mpsgraph-\(getpid())-test/region.bc.mlir")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("owned region".utf8).write(to: own)
        var info = stat(); XCTAssertEqual(lstat(own.path, &info), 0)
        let registry = CompilerTemporaryFiles.folder(runtime)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let record = CompilerTemporaryFiles.Record(pid: getpid(), namespace: RuntimeCacheIdentity.namespace, completed: false,
            files: [.init(path: own.path, inode: info.st_ino, bytes: info.st_size)])
        let path = registry.appendingPathComponent("record.json")
        try JSONEncoder().encode(record).write(to: path)
        try CompilerTemporaryFiles.cleanup(directory: runtime, root: temporary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
        var completed = record; completed.completed = true
        try JSONEncoder().encode(completed).write(to: path)
        let unrelated = own.deletingLastPathComponent().appendingPathComponent("untracked.bc.mlir")
        try Data("another compiler".utf8).write(to: unrelated)
        try CompilerTemporaryFiles.cleanup(directory: runtime, root: temporary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
