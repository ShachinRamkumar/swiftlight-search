import CTokenizer
import DigUpKit
import Foundation
import HostTableCodec
import CryptoKit

@available(macOS 27, *)
public final class HFTokenizer {
    private var handle: UnsafeMutableRawPointer?

    public init(contentsOf url: URL) throws {
        let status: Int32
        if url.pathExtension == "zst" {
            let json = try HostTableZstd.decode(Data(contentsOf: url), size: 32170510)
            guard SHA256.hash(data: json).map({ String(format: "%02x", $0) }).joined() == "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4" else {
                throw WorkerError.failed("decoded tokenizer identity mismatch")
            }
            status = json.withUnsafeBytes { tok_load_json($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &handle) }
        } else {
            status = Array(url.path.utf8).withUnsafeBufferPointer { tok_load($0.baseAddress, $0.count, &handle) }
        }
        guard status == 0, handle != nil else { throw WorkerError.failed("tokenizer load status \(status): \(url.path)") }
    }

    deinit { close() }
    public func close() {
        if let handle { _ = tok_free(handle) }
        handle = nil
    }

    public func tokenize(_ text: String, limit: Int) throws -> [UInt32] {
        guard (2...2048).contains(limit), let handle else { throw WorkerError.failed("closed tokenizer or invalid limit") }
        let bytes = Array(text.utf8)
        var ids = [UInt32](repeating: 0, count: bytes.count + 8)
        var count = 0
        var status = bytes.withUnsafeBufferPointer { utf8 in
            ids.withUnsafeMutableBufferPointer {
                tok_encode(handle, utf8.baseAddress, utf8.count, 1, 1, $0.baseAddress, $0.count, &count)
            }
        }
        if status == 2 {
            ids = [UInt32](repeating: 0, count: count)
            status = bytes.withUnsafeBufferPointer { utf8 in
                ids.withUnsafeMutableBufferPointer {
                    tok_encode(handle, utf8.baseAddress, utf8.count, 1, 1, $0.baseAddress, $0.count, &count)
                }
            }
        }
        guard status == 0, count >= 2, count <= ids.count else {
            throw WorkerError.failed("tokenizer encode status \(status), count \(count)")
        }
        ids.removeLast(ids.count - count)
        guard ids.first == 2, ids.last == 1 else { throw WorkerError.failed("tokenizer BOS/EOS contract changed") }
        if ids.count > limit { ids = Array(ids.prefix(limit - 1)) + [1] }
        return ids
    }
}
