import Foundation
import XCTest
@testable import DigUpKit

final class RootAccessTests: XCTestCase {
    func testShallowBlockedDirectoryPreservesRowsAndAllowsSiblingsAndRetries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shallow-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Level1/Level2")
        let good = root.appendingPathComponent("Other")
        for folder in [blocked, good] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let note = blocked.appendingPathComponent("keep.txt")
        try Data("preserve until readable".utf8).write(to: note)
        let store = try IndexStore(directory: root.appendingPathComponent("index.noindex"))
        let initial = try Indexer(store: store, options: IndexOptions()) { throw NSError(domain: "unused", code: 1) }
        XCTAssertEqual(try initial.sync([root]).added, 1)
        initial.finish()
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let canonical = URL(fileURLWithPath: FolderSelection.realPath(blocked.path))
        let access = RootAccess { folder in
            if folder == canonical { entered.signal(); release.wait() }
            return .ready
        }
        defer { release.signal() }
        let indexer = try Indexer(store: store, options: IndexOptions(), directoryAccess: access) { throw NSError(domain: "unused", code: 1) }
        defer { indexer.finish() }
        try fm.removeItem(at: note)
        try Data("accessible sibling".utf8).write(to: good.appendingPathComponent("new.txt"))
        let started = Date()
        let result = try indexer.sync([root])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.crawl.directoryAccess[canonical.path], .pending)
        XCTAssertEqual(entered.wait(timeout: .now()), .success)
        XCTAssertEqual(try store.files(under: [blocked.path]).count, 1)
        XCTAssertEqual(try store.pendingCount(), 1)
        // A direct watcher event cannot bypass the shallow ancestor's in-flight check.
        XCTAssertEqual(try indexer.sync([root], paths: [note.path]).removed, 0)
        XCTAssertEqual(entered.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(access.check([canonical])[canonical], .ready)
        XCTAssertEqual(try indexer.sync([root]).removed, 1)
    }

    func testDeniedDepthOneDirectoryIsSkippedWithoutProbingItsChildren() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("denied-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let child = root.appendingPathComponent("Denied")
        try fm.createDirectory(at: child.appendingPathComponent("Child"), withIntermediateDirectories: true)
        let real = FolderSelection.realPath(child.path)
        let access = RootAccess { folder in
            XCTAssertFalse(FolderSelection.isInside(folder.path, real))
            return folder.path == real ? .denied : .ready
        }
        let crawl = Crawler.crawl([root], options: IndexOptions(), access: access)
        XCTAssertEqual(crawl.directoryAccess[real], .denied)
        XCTAssertTrue(crawl.candidates.isEmpty)
    }

    func testBlockedRootDoesNotHoldOtherRootsOrMultiplyChecks() {
        let blocked = URL(fileURLWithPath: "/fixture/Documents")
        let good = URL(fileURLWithPath: "/fixture/Other")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let access = RootAccess(retry: 0) { root in
            if root == blocked { entered.signal(); release.wait() }
            return .ready
        }
        defer { release.signal() }
        let start = Date()
        let states = access.check([blocked, good], wait: 0.03)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(states[blocked], .pending)
        XCTAssertEqual(states[good], .ready)
        XCTAssertEqual(entered.wait(timeout: .now()), .success)
        for _ in 0..<3 { XCTAssertEqual(access.check([blocked], wait: 0)[blocked], .pending) }
        XCTAssertEqual(entered.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(access.check([good])[good], .ready)
    }

    func testReadDistinguishesMissingAndAccessibleScratch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("root-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(RootAccess.read(root), .missing)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(RootAccess.read(root), .ready)
    }

    func testDeniedIsReportedAndRetried() {
        final class Answer: @unchecked Sendable { var state: RootAccess.State = .denied }
        let answer = Answer(), root = URL(fileURLWithPath: "/fixture/Documents")
        let access = RootAccess(retry: 0) { _ in answer.state }
        XCTAssertEqual(access.check([root])[root], .denied)
        answer.state = .ready
        XCTAssertEqual(access.check([root])[root], .ready)
    }

    func testUnavailableChildPreservesRowsAndSkipsPendingAndTargetedWork() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("access-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Documents")
        let other = root.appendingPathComponent("Other")
        for folder in [blocked, other] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let note = blocked.appendingPathComponent("keep.txt")
        try Data("preserve this note".utf8).write(to: note)
        let store = try IndexStore(directory: root.appendingPathComponent("index.noindex"))
        let indexer = try Indexer(store: store, options: IndexOptions()) { XCTFail("unexpected model"); throw NSError(domain: "unused", code: 1) }
        defer { indexer.finish() }
        XCTAssertEqual(try indexer.sync([root]).added, 1)
        let before = try store.files(under: [blocked.path]).map(\.id)
        try fm.removeItem(at: note)
        try Data("accessible targeted note".utf8).write(to: other.appendingPathComponent("new.txt"))
        store.scope = [root.path]
        store.unavailableFolders = [blocked.path]
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertTrue(try store.pending(limit: nil).isEmpty)
        let full = try indexer.sync([root], unavailable: [blocked.path])
        XCTAssertEqual(full.removed, 0)
        XCTAssertEqual(full.added, 1)
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(try store.files(under: [blocked.path]).map(\.id), before)
        let targeted = try indexer.sync([root], paths: [note.path, other.path], unavailable: [blocked.path])
        XCTAssertEqual(targeted.removed, 0)
        XCTAssertEqual(try store.files(under: [blocked.path]).map(\.id), before)
        store.unavailableFolders = []
        XCTAssertEqual(try indexer.sync([root]).removed, 1)
    }
}
