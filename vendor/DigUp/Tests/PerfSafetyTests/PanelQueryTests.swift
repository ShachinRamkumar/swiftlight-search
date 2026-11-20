import DigUpKit
@testable import DigUpCoreAIRuntime
import XCTest

private final class PanelFixtureState: @unchecked Sendable {
    let lock = NSLock()
    let loading = DispatchSemaphore(value: 0)
    let queryStarted = DispatchSemaphore(value: 0)
    let queryRelease = DispatchSemaphore(value: 0)
    var preparations = 0
    var releases = 0
    var resumes = 0
    func counts() -> (Int, Int) { lock.withLock { (preparations, releases) } }
}
private final class PanelFixture: Embedder {
    let state: PanelFixtureState
    init(_ state: PanelFixtureState) { self.state = state }
    var info: WorkerInfo { WorkerInfo(model: "fixture", revision: "fixture", runtime: "fixture", dtype: "fp16", dim: 768, textOnly: true, loadSeconds: nil) }
    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        if texts == ["in-flight"] { state.queryStarted.signal(); state.queryRelease.wait() }
        return [[1] + Array(repeating: 0, count: 767)]
    }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { [] }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { [] }
    func close() { state.lock.withLock { state.releases += 1 } }
}
private final class ReusablePanelFixture: PanelQueryProgram {
    let state: PanelFixtureState
    init(_ state: PanelFixtureState) { self.state = state }
    var info: WorkerInfo { PanelFixture(state).info }
    func loadQueryProgram() throws { state.lock.withLock { state.resumes += 1 } }
    func unloadQueryProgram() { state.lock.withLock { state.releases += 1 } }
    func embedTexts(_ texts: [String]) throws -> [[Float]] { [[1] + Array(repeating: 0, count: 767)] }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { [] }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { [] }
    func close() {}
}
final class PanelQueryTests: XCTestCase {
    func testTerminalPreparationFailureDoesNotRetryOnEveryKeystroke() throws {
        let state = PanelFixtureState()
        let panel = PanelQueryEncoder {
            state.lock.withLock { state.preparations += 1 }
            throw WorkerError.failed("download unavailable")
        }
        panel.open()
        XCTAssertThrowsError(try panel.encode(["typed"]))
        for _ in 0..<20 { panel.open(); XCTAssertThrowsError(try panel.encode(["typed"])) }
        XCTAssertEqual(state.counts().0, 1)
        XCTAssertEqual(panel.status, "failed")
    }

    func testReopeningReusesCPUStateAndLoadsTheProgramAgain() throws {
        let state = PanelFixtureState()
        let panel = PanelQueryEncoder {
            state.lock.withLock { state.preparations += 1 }
            return ReusablePanelFixture(state)
        }
        for _ in 0..<20 {
            panel.open()
            XCTAssertEqual(try panel.encode(["typed"]).first?.count, 768)
            panel.close()
            XCTAssertEqual(panel.status, "closed")
        }
        XCTAssertEqual(state.counts().0, 1)
        XCTAssertEqual(state.lock.withLock { state.resumes }, 19)
        XCTAssertEqual(state.counts().1, 20)
    }
    func testTwentyRapidCyclesReuseOneInflightLoadAndFirstQueryWaits() throws {
        let state = PanelFixtureState()
        let panel = PanelQueryEncoder {
            state.lock.withLock { state.preparations += 1 }
            state.loading.wait()
            return PanelFixture(state)
        }
        for _ in 0..<20 { panel.open(); panel.close() }
        panel.open()
        let completed = expectation(description: "semantic result waits for opening")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try panel.encode(["typed"]).first?.count, 768) }
            catch { XCTFail(String(describing: error)) }
            completed.fulfill()
        }
        XCTAssertEqual(panel.status, "preparing")
        state.loading.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(state.counts().0, 1)
        panel.close()
        XCTAssertEqual(state.counts().1, 1)
        XCTAssertEqual(panel.status, "closed")
    }
    func testCloseWaitsForActiveQueryAndReopenReusesLoadedModel() throws {
        let state = PanelFixtureState()
        let panel = PanelQueryEncoder { state.lock.withLock { state.preparations += 1 }; return PanelFixture(state) }
        panel.open(); _ = try panel.encode(["warm"])
        let completed = expectation(description: "last active query")
        DispatchQueue.global().async {
            do { _ = try panel.encode(["in-flight"]) } catch { XCTFail(String(describing: error)) }
            completed.fulfill()
        }
        XCTAssertEqual(state.queryStarted.wait(timeout: .now() + 2), .success)
        panel.close()
        XCTAssertEqual(state.counts().1, 0)
        panel.open()
        state.queryRelease.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(state.counts().0, 1)
        XCTAssertEqual(state.counts().1, 0)
        panel.close()
        XCTAssertEqual(state.counts().1, 1)
    }
}
