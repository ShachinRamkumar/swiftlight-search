import CZstd
import Foundation

public enum HostTableError: Error { case invalid(String) }

public enum HostTableZstd {
    public static func decode(_ frame: Data, size: Int) throws -> Data {
        guard size > 0, size <= 64 * 1024 * 1024 else { throw HostTableError.invalid("decoded size") }
        var output = Data(count: size)
        try frame.withUnsafeBytes { source in
            guard ZSTD_findFrameCompressedSize(source.baseAddress, source.count) == source.count,
                  ZSTD_getFrameContentSize(source.baseAddress, source.count) == UInt64(size) else {
                throw HostTableError.invalid("zstd frame size")
            }
            try output.withUnsafeMutableBytes { destination in
                let result = ZSTD_decompress(destination.baseAddress, destination.count, source.baseAddress, source.count)
                guard ZSTD_isError(result) == 0, result == size else { throw HostTableError.invalid("zstd decode/checksum") }
            }
        }
        return output
    }
}

/// Read-only mapping with a bounded LRU of decoded chunks. Each lookup also reuses chunks
/// within that call, including when the persistent cache is disabled for measurements.
public final class PackedRowTable {
    public let rows: Int
    public let columns: Int
    public let chunkRows: Int
    public let decodedSHA256: Data
    private let data: Data
    private let offsets: [Int]
    private let capacity: Int
    private let lock = NSLock()
    private final class Entry {
        let index: Int
        let data: Data
        weak var previous: Entry?
        var next: Entry?
        init(_ index: Int, _ data: Data) { self.index = index; self.data = data }
    }
    private var entries: [Int: Entry] = [:]
    private var oldest: Entry?
    private var newest: Entry?

    public init(url: URL, cacheBytes: Int = 64 * 1024 * 1024) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 64, data.prefix(8) == Data("SLHOST01".utf8) else { throw HostTableError.invalid("header") }
        func integer(_ offset: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian) }
        let rows = integer(16), columns = integer(20), chunkRows = integer(24), chunks = integer(28)
        guard integer(8) == 64, integer(12) == 1, (1...262144).contains(rows), (1...512).contains(columns),
              chunkRows == 64, chunks == (rows + chunkRows - 1) / chunkRows,
              data.count >= 64 + (2 * chunks + 1) * 8 else { throw HostTableError.invalid("shape/index") }
        var offsets: [Int] = []
        for i in 0..<(2 * chunks + 1) {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64 + i * 8, as: UInt64.self) }.littleEndian
            guard value <= UInt64(data.count) else { throw HostTableError.invalid("offset outside file") }
            offsets.append(Int(value))
        }
        guard offsets.first == 64 + offsets.count * 8, offsets.last == data.count,
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else { throw HostTableError.invalid("offset order") }
        self.data = data; self.rows = rows; self.columns = columns; self.chunkRows = chunkRows
        self.offsets = offsets; decodedSHA256 = data.subdata(in: 32..<64)
        capacity = max(0, cacheBytes) / (chunkRows * columns * 2)
    }

    private func touch(_ entry: Entry) {
        if newest === entry { return }
        if oldest === entry { oldest = entry.next }
        entry.previous?.next = entry.next
        entry.next?.previous = entry.previous
        entry.previous = newest; entry.next = nil
        newest?.next = entry
        newest = entry
        if oldest == nil { oldest = entry }
    }

    private func chunk(_ index: Int) throws -> Data {
        if let entry = entries[index] { touch(entry); return entry.data }
        let count = min(chunkRows, rows - index * chunkRows) * columns
        let hi = try HostTableZstd.decode(data.subdata(in: offsets[2 * index]..<offsets[2 * index + 1]), size: count)
        let lo = try HostTableZstd.decode(data.subdata(in: offsets[2 * index + 1]..<offsets[2 * index + 2]), size: count)
        var decoded = Data(count: count * 2)
        decoded.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            hi.withUnsafeBytes { (high: UnsafeRawBufferPointer) in
                lo.withUnsafeBytes { (low: UnsafeRawBufferPointer) in
                    for i in 0..<count { output[2 * i] = low[i]; output[2 * i + 1] = high[i] }
                }
            }
        }
        if capacity > 0 {
            let entry = Entry(index, decoded)
            entries[index] = entry; touch(entry)
            if entries.count > capacity, let evicted = oldest {
                oldest = evicted.next; oldest?.previous = nil; evicted.next = nil
                entries.removeValue(forKey: evicted.index)
            }
        }
        return decoded
    }

    public func gather(_ ids: [UInt32]) throws -> [UInt16] {
        guard ids.allSatisfy({ $0 < rows }) else { throw HostTableError.invalid("row outside table") }
        lock.lock(); defer { lock.unlock() }
        var chunks: [Int: Data] = [:]
        var output = [UInt16](repeating: 0, count: ids.count * columns)
        for (position, id) in ids.enumerated() {
            let index = Int(id) / chunkRows
            let decoded: Data
            if let found = chunks[index] { decoded = found }
            else { decoded = try chunk(index); chunks[index] = decoded }
            decoded.withUnsafeBytes { bytes in
                let start = Int(id) % chunkRows * columns * 2
                output.withUnsafeMutableBytes { destination in
                    destination.baseAddress!.advanced(by: position * columns * 2)
                        .copyMemory(from: bytes.baseAddress!.advanced(by: start), byteCount: columns * 2)
                }
            }
        }
        return output
    }

    public func clearCache() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); oldest = nil; newest = nil
    }
}
