import Foundation

struct ModelPreparationRetry: Sendable {
    private(set) var attempts = 0
    private(set) var retryAt: TimeInterval = 0
    private(set) var minimumFreeBytes: UInt64?

    mutating func failed(_ message: String, now: TimeInterval) {
        attempts += 1
        retryAt = now + min(60 * pow(2, Double(min(attempts-1, 3))), 300)
        minimumFreeBytes = nil
        if let range = message.range(of: "specialization admission refused: free disk "),
           let floor = message[range.upperBound...].components(separatedBy: " below ").dropFirst().first?
            .split(separator: " ").first {
            minimumFreeBytes = UInt64(floor)
        }
    }

    func canRetry(now: TimeInterval, freeBytes: UInt64?) -> Bool {
        guard now >= retryAt else { return false }
        if let minimumFreeBytes { return freeBytes.map { $0 >= minimumFreeBytes } ?? false }
        return true
    }
}
