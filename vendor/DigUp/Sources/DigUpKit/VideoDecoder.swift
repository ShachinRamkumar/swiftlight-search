@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

public struct VideoClipRange: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start=start; self.end=end }
}

public enum VideoDecoder {
    public static func schedule(duration: Double, hop: Double = 10, length: Double = 14) throws -> [VideoClipRange] {
        guard duration.isFinite, duration > 0, hop.isFinite, length.isFinite, hop > 0, hop <= length, length <= 14 else {
            throw WorkerError.failed("invalid video schedule")
        }
        var result: [VideoClipRange] = [], start = 0.0
        while true {
            let end=min(duration,start+length)
            result.append(VideoClipRange(start:start,end:end))
            if end >= duration { return result }
            start += hop
        }
    }

    public static func duration(_ url: URL) throws -> Double {
        try runBlocking { try await AVURLAsset(url:url).load(.duration).seconds }
    }

    public static func decode(_ url: URL, range: VideoClipRange) throws -> [RGBImage] {
        guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start, range.end-range.start <= 14 else {
            throw WorkerError.failed("invalid video range")
        }
        return try runBlocking {
            let asset=AVURLAsset(url:url)
            guard let track=try await asset.loadTracks(withMediaType:.video).first else { throw WorkerError.failed("video has no track") }
            let fps=Double(try await track.load(.nominalFrameRate))
            guard fps.isFinite, fps > 0 else { throw WorkerError.failed("video has no frame rate") }
            let transform=try await track.load(.preferredTransform)
            let matrix=[transform.a,transform.b,transform.c,transform.d].map { Int($0.rounded()) }
            let orientations=[[1,0,0,1]:1,[-1,0,0,1]:2,[-1,0,0,-1]:3,[1,0,0,-1]:4,[0,1,1,0]:5,[0,1,-1,0]:6,[0,-1,-1,0]:7,[0,-1,1,0]:8]
            guard let orientation=orientations[matrix] else { throw WorkerError.failed("unsupported video transform") }
            let reader=try AVAssetReader(asset:asset)
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData=false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? WorkerError.failed("video reader failed") }
            defer { reader.cancelReading() }
            let indices=(0..<max(1,Int(range.end-range.start))).map { Int(range.start*fps)+Int(Double($0)*fps) }
            func rgb(_ sample: CMSampleBuffer) throws -> RGBImage {
                guard let buffer=CMSampleBufferGetImageBuffer(sample) else { throw WorkerError.failed("video has no pixel buffer") }
                CVPixelBufferLockBaseAddress(buffer,.readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
                let w=CVPixelBufferGetWidth(buffer),h=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
                guard let base=CVPixelBufferGetBaseAddress(buffer) else { throw WorkerError.failed("empty video pixel buffer") }
                let bytes=base.assumingMemoryBound(to:UInt8.self)
                var pixels=[UInt8](repeating:0,count:w*h*3)
                for y in 0..<h { for x in 0..<w {
                    let at=y*stride+x*4,to=(y*w+x)*3
                    pixels[to]=bytes[at+2];pixels[to+1]=bytes[at+1];pixels[to+2]=bytes[at]
                } }
                return try ImageDecoder.orient(width:w,height:h,pixels:pixels,orientation:orientation)
            }
            var frames: [RGBImage]=[],native=0
            var lastSample: CMSampleBuffer?
            while let sample=output.copyNextSampleBuffer() {
                lastSample=sample
                if indices.contains(native) {
                    let frame=try rgb(sample)
                    for index in indices where index==native { frames.append(frame) }
                }
                if native >= indices.last! { break }
                native += 1
            }
            guard reader.status != .failed else { throw reader.error ?? WorkerError.failed("video decoding failed") }
            if frames.count < indices.count {
                guard let lastSample else { throw WorkerError.failed("empty video") }
                let last=try rgb(lastSample)
                while frames.count < indices.count { frames.append(last) }
            }
            return frames
        }
    }

}
