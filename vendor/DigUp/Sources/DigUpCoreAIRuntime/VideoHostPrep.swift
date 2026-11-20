import DigUpKit
import Foundation

@available(macOS 27, *)
public enum VideoHostPrep {
    public static func schedule(duration: Double, hop: Double = 10, length: Double = 14) throws -> [VideoClipRange] { try VideoDecoder.schedule(duration:duration,hop:hop,length:length) }
    public static func duration(_ url: URL) throws -> Double { try VideoDecoder.duration(url) }
    public static func decode(_ url: URL, range: VideoClipRange) throws -> [RGBImage] { try VideoDecoder.decode(url,range:range) }

    public static func compose(_ soft: [[UInt16]], counts: [Int], host: TextHostPrep) throws -> (inputs:[String:HostTensor],bucket:Int) {
        guard (1...14).contains(soft.count), soft.count == counts.count,
              counts.allSatisfy({ (1...140).contains($0) }), soft.allSatisfy({ $0.count == 512*140 }) else {
            throw WorkerError.failed("invalid video soft tokens")
        }
        var ids: [UInt32] = [2]
        for n in counts { ids += [255999]+[UInt32](repeating:258884,count:n)+[258882] }
        ids.append(1)
        let bucket=try TextHostPrep.bucketFor(ids.count,role:.document)
        var inputs=try host.prepare(ids,bucket:bucket),x=inputs["x"]!.bits,offset=1
        for (bits,n) in zip(soft,counts) {
            for c in 0..<512 { for i in 0..<n { x[c*bucket+offset+1+i]=bits[c*140+i] } }
            offset += n+2
        }
        inputs["x"]=HostTensor(shape:[1,512,1,bucket],bits:x)
        return (inputs,bucket)
    }
}

public struct VideoEmbeddingTiming: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let frames: Int
    public let decodeMS: Double
    public let modelMS: Double
    public let totalMS: Double
}
