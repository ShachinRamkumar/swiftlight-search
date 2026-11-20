import Foundation

public enum PCM16 {
    public static func decode(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i+2)) << 16 }
        func tag(_ i: Int) -> String { String(decoding: data[i..<i+4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE", Int(u32(4))+8 <= data.count else {
            throw WorkerError.failed("expected PCM16 WAV: \(url.path)")
        }
        var offset = 12, format = false, payload: Range<Int>?
        let end = Int(u32(4))+8
        while offset+8 <= end {
            let size = Int(u32(offset+4)), start = offset+8
            guard size <= end-start else { throw WorkerError.failed("truncated WAV chunk") }
            if tag(offset) == "fmt " {
                guard size >= 16, u16(start) == 1, u16(start+2) == 1, u32(start+4) == 16000,
                      u32(start+8) == 32000, u16(start+12) == 2, u16(start+14) == 16 else {
                    throw WorkerError.failed("expected uncompressed 16 kHz mono PCM16 WAV")
                }
                format = true
            } else if tag(offset) == "data", payload == nil { payload = start..<start+size }
            offset = start+size+(size & 1)
        }
        guard format, let payload, !payload.isEmpty, payload.count % 2 == 0 else {
            throw WorkerError.failed("missing or invalid PCM16 WAV data")
        }
        return stride(from: payload.lowerBound, to: payload.upperBound, by: 2).map {
            Float(Int16(bitPattern: u16($0))) / 32768
        }
    }
}
