import Darwin
import DigUpCoreAIRuntime
import Foundation

@available(macOS 27, *)
func auditSpecialization(_ url: URL, phase: SpecializationPhase, logs: String) throws {
    let asset: String
    switch url.lastPathComponent {
    case "text.aimodel": asset = "text"
    case "text-query.aimodel": asset = "query"
    case "text-doc.aimodel": asset = "document"
    default: throw CheckError("unexpected specialization asset: \(url.path)")
    }
    let directory = URL(fileURLWithPath: logs)
    let fd = open(directory.appendingPathComponent("r3-specializations.lock").path, O_CREAT | O_RDWR, 0o600)
    try require(fd >= 0, "cannot open specialization audit lock")
    defer { Darwin.close(fd) }
    try require(flock(fd, LOCK_EX) == 0, "cannot lock specialization audit")
    defer { _ = flock(fd, LOCK_UN) }
    var sizes: [String: String] = [:]
    for root in [NSHomeDirectory() + "/Library/Caches/coreai-cache", NSHomeDirectory() + "/Library/Application Support/coreai-cache"] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", root]; process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "cache measurement failed: \(root)")
        sizes[root] = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: logs)
    let free = (attributes[.systemFreeSize] as! NSNumber).int64Value
    let budgetURL = directory.appendingPathComponent("r3-specializations.json")
    var budget = (try? load([String: Int].self, budgetURL)) ?? ["query": 0, "document": 0]
    if phase == .begin {
        try require(free >= 9_900_000_000, "insufficient disk headroom for specialization")
        try require(budget[asset, default: 0] < 4, "round 3 \(asset) specialization budget exhausted")
        budget[asset, default: 0] += 1
        try JSONEncoder().encode(budget).write(to: budgetURL, options: .atomic)
    }
    let record: [String: Any] = ["phase": String(describing: phase), "asset": asset, "url": url.path,
                               "pid": getpid(), "time": Date().timeIntervalSince1970,
                               "cache_du_kib": sizes, "disk_free_bytes": free, "budget": budget]
    let path = directory.appendingPathComponent("r3-cache-transitions.jsonl")
    if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
}
