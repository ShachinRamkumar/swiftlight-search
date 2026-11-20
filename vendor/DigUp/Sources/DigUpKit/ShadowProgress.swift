import Foundation

/// Coverage snapshots are authoritative only at their checkpoint, never extrapolated.
public struct ShadowProgress {
    public typealias Counts = (done: Int, eligible: Int, failed: Int)
    private var counts: Counts = (0, 0, 0)
    private var checkpointProcessed: Int = 0
    private var checkpointTime: TimeInterval?
    public init() {}

    public mutating func snapshot(event: String, processed: Int, now: TimeInterval,
                                  count: () throws -> Counts) rethrows
        -> (counts: Counts, exact: Bool, age: TimeInterval) {
        let exact = checkpointTime == nil || event == "ready" || event == "summary"
            || processed - checkpointProcessed >= 64 || now - checkpointTime! >= 5
        if exact {
            counts = try count()
            checkpointProcessed = processed
            checkpointTime = now
        }
        return (counts, exact, max(0, now - checkpointTime!))
    }
}
