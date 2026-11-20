import CryptoKit
import Darwin
import Foundation

/// Opt-in diagnostics for image host CPU and byte identity. Inactive in normal use.
@available(macOS 27, *)
public enum ImageCPUProfile {
    private static let destination = ProcessInfo.processInfo.environment["P4_OPT_PROFILE"]
    private static let identities = ProcessInfo.processInfo.environment["P4_OPT_IDENTITIES"]
    private static let lock = NSLock()

    public static func begin() -> Double {
        guard destination != nil else { return 0 }
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1e6
            + Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1e6
    }

    public static func end(_ stage: String, _ start: Double) {
        guard let destination else { return }
        append(["stage": stage, "cpu_s": begin() - start], to: destination)
    }

    public static func identify(_ inputs: [String: HostTensor]) {
        guard let identities else { return }
        let hashes = inputs.mapValues { tensor in
            tensor.bits.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        append(["inputs": hashes], to: identities)
    }

    public static func identify(_ vector: [Float]) {
        guard let identities else { return }
        let bits = vector.map { Float16($0).bitPattern }
        let hash = bits.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        append(["final_fp16": hash], to: identities)
    }

    private static func append(_ record: [String: Any], to path: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
        } catch { fatalError("image diagnostic write failed: \(error)") }
    }
}
