import XCTest
import DigUpKit
@testable import DigUpCoreAIRuntime

private final class QueryFixture: Embedder, @unchecked Sendable {
    let barrier: DispatchSemaphore?
    let checkPriority: Bool
    init(barrier: DispatchSemaphore? = nil, checkPriority: Bool = false) {
        self.barrier = barrier; self.checkPriority = checkPriority
    }
    var info: WorkerInfo { WorkerInfo(model: "fake", revision: "fake", runtime: "fake", dtype: "fp32", dim: 768, textOnly: true, loadSeconds: nil) }
    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        if checkPriority { XCTAssertEqual(Thread.current.qualityOfService, .userInitiated) }
        if texts == ["slow"] { barrier?.wait() }
        if texts == ["long-during-setup"] { throw ModelSetupPending() }
        return texts.map { _ in [1] + [Float](repeating: 0, count: 767) }
    }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { [] }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { [] }
    func close() {}
}

private final class PreparationState: @unchecked Sendable {
    let lock = NSLock()
    var time: TimeInterval = 0
    var free: UInt64 = 2_000_000_000
    var attempts = 0
    func make() throws -> any Embedder {
        let attempt = lock.withLock { attempts += 1; return attempts }
        if attempt == 1 { throw WorkerError.failed("specialization admission refused: free disk 2000000000 below 9000000000 bytes") }
        return QueryFixture()
    }
}

final class BackgroundQueryTests: XCTestCase {
    func testLowDiskFailureRetainsOneWorkerAndRecoversAfterSpaceReturns() throws {
        let state = PreparationState()
        let encoder = BackgroundQueryEncoder(requestBudget: 1, prepare: { try state.make() },
            now: { state.lock.withLock { state.time } }, freeDisk: { state.lock.withLock { state.free } })
        let end = Date().addingTimeInterval(2)
        while encoder.status == .preparing, Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(encoder.status, .failed)
        state.lock.withLock { state.time = 10_000 }
        for _ in 0..<187 { XCTAssertThrowsError(try encoder.encode(["short"])) }
        XCTAssertEqual(state.lock.withLock { state.attempts }, 1)
        state.lock.withLock { state.free = 9_000_000_000 }
        XCTAssertThrowsError(try encoder.encode(["short"]))
        try ready(encoder)
        XCTAssertEqual(try encoder.encode(["short"]).first?.first, 1)
        XCTAssertEqual(state.lock.withLock { state.attempts }, 2)
    }
    func testUnavailableLongQueryDuringSetupDoesNotDisableShortQueries() throws {
        let encoder = BackgroundQueryEncoder(requestBudget: 1, prepare: { QueryFixture() })
        try ready(encoder)
        XCTAssertThrowsError(try encoder.encode(["long-during-setup"])) { error in
            XCTAssertTrue(String(describing: error).contains("readiness pending"))
        }
        XCTAssertEqual(encoder.status, .ready)
        XCTAssertEqual(try encoder.encode(["short"]).first?.first, 1)
    }
    func testPreparationAndEncodingUseInteractiveWorkPriority() throws {
        let encoder = BackgroundQueryEncoder(requestBudget: 1, prepare: {
            XCTAssertEqual(Thread.current.qualityOfService, .userInitiated)
            return QueryFixture(checkPriority: true)
        })
        try ready(encoder)
        XCTAssertEqual(try encoder.encode(["priority"]).first?.first, 1)
    }
    private func ready(_ encoder: BackgroundQueryEncoder) throws {
        let end = Date().addingTimeInterval(2)
        while encoder.status == .preparing, Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(encoder.status, .ready)
    }
    func testPreparationReturnsPendingWithoutWaitingForTheModel() throws {
        let barrier = DispatchSemaphore(value: 0)
        let encoder = BackgroundQueryEncoder(prepare: { barrier.wait(); return QueryFixture() })
        let start = Date()
        XCTAssertThrowsError(try encoder.encode(["short"])) { XCTAssertTrue(String(describing: $0).contains("readiness pending")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        barrier.signal(); try ready(encoder)
        XCTAssertEqual(try encoder.encode(["short"]).first?.first, 1)
    }
    func testLazyRecoveryKeepsAllRequestsWithinTheWaitBudget() throws {
        let barrier = DispatchSemaphore(value: 0)
        let encoder = BackgroundQueryEncoder(requestBudget: 0.01, prepare: { QueryFixture(barrier: barrier) })
        try ready(encoder)
        var start = Date()
        XCTAssertThrowsError(try encoder.encode(["slow"]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        start = Date()
        XCTAssertThrowsError(try encoder.encode(["short"]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        barrier.signal(); try ready(encoder)
        XCTAssertEqual(try encoder.encode(["slow"]).first?.first, 1)
        XCTAssertEqual(try encoder.encode(["short"]).first?.first, 1)
    }
    func testFailedPreparationRemainsAnExplicitFailure() throws {
        let encoder = BackgroundQueryEncoder(prepare: { throw WorkerError.failed("fixture failure") })
        let end = Date().addingTimeInterval(2)
        while encoder.status == .preparing, Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(encoder.status, .failed)
        for _ in 0..<3 {
            XCTAssertThrowsError(try encoder.encode(["short"])) { XCTAssertTrue(String(describing: $0).contains("fixture failure")) }
        }
    }
}
