import Foundation

/// Return opens the selection the launcher already shows, with no backend round-trip. The one exception is Return
/// pressed before the current query's first results: that press is held and opens the selection those results
/// bring. Typing on makes a new query, so a held press for an earlier one never opens anything.
struct PendingOpen {
    private(set) var generation: UInt64?

    /// Whether Return opens now.
    mutating func returnPressed(generation: UInt64, awaitingResults: Bool) -> Bool {
        self.generation = awaitingResults ? generation : nil
        return !awaitingResults
    }

    /// Whether results that just arrived release a held Return.
    mutating func resultsArrived(generation: UInt64, awaitingResults: Bool) -> Bool {
        guard self.generation == generation, !awaitingResults else { return false }
        self.generation = nil
        return true
    }
}
