import Foundation

@main struct PendingOpenTests {
    static func main() {
        var pending = PendingOpen()
        precondition(pending.returnPressed(generation: 3, awaitingResults: false), "Return with results shown opens at once")
        precondition(pending.generation == nil)
        precondition(!pending.resultsArrived(generation: 3, awaitingResults: false), "Nothing is held after an immediate open")

        precondition(!pending.returnPressed(generation: 4, awaitingResults: true), "Return before results waits for them")
        precondition(!pending.resultsArrived(generation: 4, awaitingResults: true), "A pending-only event does not release it")
        precondition(pending.resultsArrived(generation: 4, awaitingResults: false), "The query's results release it")
        precondition(!pending.resultsArrived(generation: 4, awaitingResults: false), "It opens once")

        precondition(!pending.returnPressed(generation: 5, awaitingResults: true))
        precondition(!pending.resultsArrived(generation: 6, awaitingResults: false), "Typing on drops a held Return")
        precondition(pending.returnPressed(generation: 6, awaitingResults: false), "A later Return still opens")
        precondition(pending.generation == nil)
        print("{\"passed\":true,\"immediate\":true,\"held_until_results\":true,\"opens_once\":true,\"stale_dropped\":true}")
    }
}
