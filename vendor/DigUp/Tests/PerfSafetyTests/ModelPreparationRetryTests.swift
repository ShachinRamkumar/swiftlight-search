@testable import DigUpCoreAIRuntime
import XCTest

final class ModelPreparationRetryTests: XCTestCase {
    func test187QueriesCannotRepeatARepairWhileDiskAdmissionStillFails() {
        var retry = ModelPreparationRetry()
        retry.failed("worker error: specialization admission refused: free disk 2000000000 below 9000000000 bytes", now: 0)
        for query in 0..<187 {
            XCTAssertFalse(retry.canRetry(now: Double(query)*30+5, freeBytes: 8_999_999_999))
        }
        XCTAssertEqual(retry.attempts, 1)
        XCTAssertFalse(retry.canRetry(now: 10_000, freeBytes: nil))
        XCTAssertTrue(retry.canRetry(now: 10_000, freeBytes: 9_000_000_000))
    }

    func testOtherFailuresBackOffToFiveMinutes() {
        var retry = ModelPreparationRetry()
        var now = 0.0
        for delay in [60.0,120,240,300,300] {
            retry.failed("nilError", now: now)
            XCTAssertFalse(retry.canRetry(now: now+delay-0.1, freeBytes: nil))
            XCTAssertTrue(retry.canRetry(now: now+delay, freeBytes: nil))
            now += delay
        }
    }
}
