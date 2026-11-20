import Foundation

/// No filesystem access here. Only the foreground Continue action starts a request.
struct FolderAccessFlow {
    static let folders = ["Documents", "Desktop", "Downloads"]
    private(set) var remaining: [String] = []
    private(set) var current: String?
    private(set) var denied: [String] = []

    mutating func begin() {
        guard current == nil else { return }
        remaining = Self.folders
        denied = []
        advance()
    }
    mutating func complete(allowed: Bool) {
        guard let current else { return }
        if !allowed { denied.append(current) }
        advance()
    }
    private mutating func advance() {
        current = remaining.isEmpty ? nil : remaining.removeFirst()
    }
    static func message(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return "Search needs access to " + paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") + "."
    }
}
