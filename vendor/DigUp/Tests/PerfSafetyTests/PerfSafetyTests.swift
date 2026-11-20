import XCTest
import DigUpKit
import DigUpCoreAIRuntime

final class PerfSafetyTests: XCTestCase {
    func testCoverageCadenceAndExactEndAfterExternalDeletion() throws {
        var progress = ShadowProgress(), calls = 0, actual = 100
        func count() -> ShadowProgress.Counts { calls += 1; return (actual, 500, 48) }
        XCTAssertTrue(progress.snapshot(event:"ready", processed:0, now:0, count:count).exact)
        for row in 1...63 {
            actual += 1
            let snapshot = progress.snapshot(event:"progress", processed:row, now:Double(row)/100, count:count)
            XCTAssertFalse(snapshot.exact)
            XCTAssertEqual(snapshot.counts.done, 100)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(progress.snapshot(event:"progress", processed:64, now:0.64, count:count).exact)
        XCTAssertTrue(progress.snapshot(event:"progress", processed:65, now:5.64, count:count).exact)
        actual -= 7 // A concurrent writer makes local estimates wrong.
        let final = progress.snapshot(event:"summary", processed:65, now:5.65, count:count)
        XCTAssertTrue(final.exact)
        XCTAssertEqual(final.counts.done, actual)
        XCTAssertEqual(final.counts.failed, 48)
        XCTAssertEqual(final.age, 0)
        XCTAssertEqual(calls, 4)
    }

    func testAdmissionRefusalsAndWarningRecovery() throws {
        var clock: TimeInterval = 0, compiled = false
        func attempt(disk: Int64, pressure: SpecializationAdmission.Pressure) throws {
            try SpecializationAdmission.check(freeDisk:{disk}, pressure:{pressure}, now:{clock}, sleep:{clock += $0})
            compiled = true
        }
        XCTAssertThrowsError(try attempt(disk:7_999_999_999,pressure:.normal))
        XCTAssertThrowsError(try attempt(disk:9_000_000_000,pressure:.critical))
        XCTAssertThrowsError(try attempt(disk:9_000_000_000,pressure:.warning))
        XCTAssertEqual(clock, 30)
        XCTAssertFalse(compiled)
        var pressureCalls = 0
        try SpecializationAdmission.check(freeDisk:{9_000_000_000}, pressure:{
            pressureCalls += 1; return pressureCalls < 3 ? .warning : .normal
        }, now:{clock}, sleep:{clock += $0})
        XCTAssertEqual(pressureCalls, 3)
        try SpecializationAdmission.check(minimumDisk:10_000_000_000,allowWarning:true,freeDisk:{10_000_000_000},pressure:{.warning})
        XCTAssertThrowsError(try SpecializationAdmission.check(minimumDisk:10_000_000_000,allowWarning:true,freeDisk:{9_999_999_999},pressure:{.warning}))
    }

    func testLockTimeoutThrowReleaseAndReprobeSkipsRepair() throws {
        let path = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("perf-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:path) }
        var holder: SpecializationLock? = try SpecializationLock(path:path)
        var clock: TimeInterval = 0
        XCTAssertThrowsError(try SpecializationLock(path:path, timeout:0.5, now:{clock}, sleep:{clock += $0}, log:{_ in}))
        XCTAssertEqual(clock, 0.5)
        withExtendedLifetime(holder) {}
        holder = nil
        enum FakeError: Error { case failed }
        XCTAssertThrowsError(try SpecializationLock.acquireAndReprobe(path:path, log:{_ in}, reprobe:{ () throws -> Int? in throw FakeError.failed }))
        var repairs = 0
        let probe = try SpecializationLock.acquireAndReprobe(path:path, log:{_ in}, reprobe:{42})
        defer { withExtendedLifetime(probe.lease) {} }
        let value: Int
        if let cached = probe.cached { value = cached } else { repairs += 1; value = 0 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(repairs, 0)
    }

    func testGatedFakeLoopPauseResumeAndStopNoPartialReturn() throws {
        let control = ModelCallControl()
        let first = expectation(description:"first fake inference starts")
        let second = expectation(description:"second fake inference starts")
        let finished = expectation(description:"stopped batch throws")
        let paused = DispatchSemaphore(value:0), resumed = DispatchSemaphore(value:0)
        let secondStarted = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            do {
                var results: [Int] = []
                for item in 1...4 {
                    let prepared = item
                    try control.waitForModelCall()
                    if item == 1 {
                        first.fulfill()
                        paused.wait()
                    }
                    if item == 2 { secondStarted.signal(); second.fulfill(); resumed.wait() }
                    results.append(prepared)
                }
                XCTFail("stopped batch returned partial/full output: \(results)")
            } catch { XCTAssertTrue(control.isStopped) }
            finished.fulfill()
        }
        wait(for:[first],timeout:2)
        control.command("pause")
        paused.signal()
        XCTAssertEqual(secondStarted.wait(timeout:.now()+0.15), .timedOut)
        control.command("resume")
        wait(for:[second],timeout:2)
        control.command("stop")
        resumed.signal()
        wait(for:[finished],timeout:2)
        XCTAssertThrowsError(try control.waitForModelCall())
    }
}
