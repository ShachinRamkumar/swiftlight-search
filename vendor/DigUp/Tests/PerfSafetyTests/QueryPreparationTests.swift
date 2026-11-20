import XCTest
import DigUpKit
@testable import DigUpCoreAIRuntime

private final class PreparedQueryFixture: Embedder, @unchecked Sendable {
    var info: WorkerInfo { WorkerInfo(model: "fake", revision: "fake", runtime: "fake", dtype: "fp32", dim: 768, textOnly: true, loadSeconds: nil) }
    func embedTexts(_ texts: [String]) throws -> [[Float]] { texts.map { _ in [1] + [Float](repeating: 0, count: 767) } }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { [] }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { [] }
    func close() {}
}

final class QueryPreparationTests: XCTestCase {
    @available(macOS 27, *)
    func testFunctionsStartBeforeHostPreparationCompletes() throws {
        let functionsStarted = DispatchSemaphore(value: 0)
        let hostFinished = DispatchSemaphore(value: 0)
        let encoder = BackgroundQueryEncoder(prepare: {
            let (host, _) = try prepareQueryResources(host: {
                XCTAssertEqual(functionsStarted.wait(timeout: .now() + 1), .success)
                hostFinished.signal()
                return PreparedQueryFixture()
            }, functions: {
                functionsStarted.signal()
                XCTAssertEqual(hostFinished.wait(timeout: .now() + 1), .success)
                return 0
            })
            return host
        })
        let end = Date().addingTimeInterval(3)
        while encoder.status == .preparing, Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(encoder.status, .ready)
    }

    @available(macOS 27, *)
    func testHostFailureDrainsFunctionPreparationBeforeReturning() throws {
        let functionsFinished = DispatchSemaphore(value: 0)
        let encoder = BackgroundQueryEncoder(prepare: {
            do {
                let (host, _) = try prepareQueryResources(host: { () throws -> PreparedQueryFixture in
                    throw WorkerError.failed("host fixture failed")
                }, functions: {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    functionsFinished.signal()
                    return 0.02
                })
                return host
            } catch {
                XCTAssertEqual(functionsFinished.wait(timeout: .now()), .success)
                throw error
            }
        })
        let end = Date().addingTimeInterval(3)
        while encoder.status == .preparing, Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(encoder.status, .failed)
    }
}
