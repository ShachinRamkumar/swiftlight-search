import Foundation

/// Serializes background repairs inside a process. SpecializationLock also
/// serializes worker and index-service repairs across processes.
actor CompilationCoordinator {
    static let shared = CompilationCoordinator()
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if occupied {
            await withCheckedContinuation { waiting.append($0) }
        } else { occupied = true }
    }

    func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().resume() }
    }
}
