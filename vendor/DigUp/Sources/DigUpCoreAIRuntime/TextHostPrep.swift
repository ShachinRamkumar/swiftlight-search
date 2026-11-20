import CryptoKit
import Darwin
import DigUpKit
import Foundation
import HostTableCodec

@available(macOS 27, *)
public enum TextRole: String, Codable, Sendable {
    case query, document
    public var limit: Int { self == .query ? 512 : 2048 }
}

@available(macOS 27, *)
public struct HostTensor: Sendable {
    public let shape: [Int]
    public let bits: [UInt16]
    public init(shape: [Int], bits: [UInt16]) { self.shape = shape; self.bits = bits }
    public var bytes: Data { bits.withUnsafeBytes { Data($0) } }
}

@available(macOS 27, *)
public final class TextHostPrep {
    public static let buckets = [32, 64, 128, 256, 512, 1024, 2048]
    public static let inputNames = ["x", "mask_global", "mask_local", "pool", "local_cos", "local_sin", "global_cos", "global_sin"]
    // Python math.sqrt(512), rounded once to float32. No runtime libm dependency.
    private static let scale = Float(bitPattern: 0x41b504f3)
    private let table: Data?
    private let packed: PackedRowTable?
    private let ropeFolder: URL
    private let ropeHashes: [String: String]
    private struct BucketCache {
        let globalMask: [UInt16]
        let localMask: [UInt16]
        let rope: [String: HostTensor]
    }
    private var cache: [Int: BucketCache] = [:]

    public init(tokenTable: URL, ropeTables: URL) throws {
        if tokenTable.pathExtension == "slht" {
            let decoded = try PackedRowTable(url: tokenTable)
            guard decoded.rows == 262144, decoded.columns == 512,
                  decoded.decodedSHA256.map({ String(format: "%02x", $0) }).joined() == "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877" else {
                throw WorkerError.failed("packed token table identity/shape mismatch")
            }
            packed = decoded; table = nil
        } else {
            let raw = try Data(contentsOf: tokenTable, options: .alwaysMapped)
            guard raw.count == 262144 * 512 * 2 else { throw WorkerError.failed("invalid BF16 token table") }
            table = raw; packed = nil
        }
        ropeFolder = ropeTables
        ropeHashes = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: ropeTables.appendingPathComponent("sha256.json")))
    }

    func releaseTransientBuffers() {
        cache.removeAll()
        packed?.clearCache()
    }

    public static func bucketFor(_ count: Int, role: TextRole) throws -> Int {
        let choices = role == .query ? [32, 64, 128, 256, 512] : [256, 512, 1024, 2048]
        guard count > 0, let bucket = choices.first(where: { count <= $0 }) else {
            throw WorkerError.failed("invalid token count \(count) for \(role)")
        }
        return bucket
    }

    private func bucketCache(_ s: Int) throws -> BucketCache {
        if let found = cache[s] { return found }
        let global = [UInt16](repeating: 0, count: s * s)
        var local = global
        let sentinel = Float16(-40000).bitPattern
        if s > 513 {
            for q in 0..<s {
                for k in 0..<s where abs(q - k) > 512 { local[q * s + k] = sentinel }
            }
        }
        var rope: [String: HostTensor] = [:]
        for (name, channels) in [("local_cos", 256), ("local_sin", 256), ("global_cos", 512), ("global_sin", 512)] {
            let file = "\(s)-\(name).f16"
            let url = ropeFolder.appendingPathComponent(file)
            let data: Data
            if FileManager.default.fileExists(atPath: url.path) {
                data = try Data(contentsOf: url)
            } else {
                let big = try Data(contentsOf: ropeFolder.appendingPathComponent("2048-\(name).f16"))
                guard big.count == channels * 2048 * 2 else { throw WorkerError.failed("invalid base RoPE table") }
                var prefix = Data(capacity: channels * s * 2)
                for channel in 0..<channels { prefix.append(big[(channel * 2048 * 2)..<(channel * 2048 * 2 + s * 2)]) }
                data = prefix
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == channels * s * 2, ropeHashes[file] == hash else {
                throw WorkerError.failed("RoPE size/hash mismatch: \(file)")
            }
            let bits = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            rope[name] = HostTensor(shape: [1, channels, 1, s], bits: bits)
        }
        let result = BucketCache(globalMask: global, localMask: local, rope: rope)
        cache[s] = result
        return result
    }

    public func prepare(_ ids: [UInt32], bucket s: Int) throws -> [String: HostTensor] {
        guard Self.buckets.contains(s), !ids.isEmpty, ids.count <= s, ids.allSatisfy({ $0 < 262144 }) else {
            throw WorkerError.failed("invalid host-prep IDs or bucket")
        }
        let shared = try bucketCache(s)
        let padded = ids + [UInt32](repeating: 0, count: s - ids.count)
        let gathered = try packed?.gather(padded)
        var x = [UInt16](repeating: 0, count: 512 * s)
        func fill(_ rows: UnsafeBufferPointer<UInt16>, gathered: Bool) {
            for position in 0..<s {
                let row = (gathered ? position : Int(padded[position])) * 512
                for channel in 0..<512 {
                    let value = Float(bitPattern: UInt32(rows[row + channel]) << 16) * Self.scale
                    x[channel * s + position] = Float16(value).bitPattern
                }
            }
        }
        if let gathered { gathered.withUnsafeBufferPointer { fill($0, gathered: true) } }
        else { table!.withUnsafeBytes { fill($0.bindMemory(to: UInt16.self), gathered: false) } }
        var global = shared.globalMask
        var local = shared.localMask
        if ids.count < s {
            let sentinel = Float16(-40000).bitPattern
            global.withUnsafeMutableBufferPointer { g in
                local.withUnsafeMutableBufferPointer { l in
                    for q in 0..<s {
                        g.baseAddress!.advanced(by: q * s + ids.count).update(repeating: sentinel, count: s - ids.count)
                        l.baseAddress!.advanced(by: q * s + ids.count).update(repeating: sentinel, count: s - ids.count)
                    }
                }
            }
        }
        var pool = [UInt16](repeating: 0, count: s)
        let weight = Float16(Float(1) / Float(ids.count)).bitPattern
        for i in ids.indices { pool[i] = weight }
        var result = shared.rope
        result["x"] = HostTensor(shape: [1, 512, 1, s], bits: x)
        result["mask_global"] = HostTensor(shape: [1, 1, s, s], bits: global)
        result["mask_local"] = HostTensor(shape: [1, 1, s, s], bits: local)
        result["pool"] = HostTensor(shape: [1, 1, 1, s], bits: pool)
        return result
    }

    public static func finalize(_ bits: [UInt16]) throws -> [Float] {
        guard bits.count == 768 else { throw WorkerError.failed("expected 768 output elements") }
        let values = bits.map { Float(Float16(bitPattern: $0)) }
        var squareSum: Float = 0
        for value in values { squareSum += value * value }
        let norm = squareSum.squareRoot()
        guard values.allSatisfy(\.isFinite), norm.isFinite, norm >= 1e-6 else {
            throw WorkerError.failed("nonfinite vector or pooled norm below 1e-6")
        }
        return values.map { $0 / norm }
    }
}
