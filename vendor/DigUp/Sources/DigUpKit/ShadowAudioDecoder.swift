#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation

/// A single full-track read for shadow inputs. The indexer's streaming extractor stays unchanged.
enum ShadowAudioDecoder {
    static func decode(_ url: URL) async throws -> [Int16] {
        let asset=AVURLAsset(url:url)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else { throw ExtractError.unreadable("no audio track") }
        let reader=try AVAssetReader(asset:asset)
        // A finite range flushes AAC's last trimmed packet consistently on macOS 27.
        reader.timeRange = try await track.load(.timeRange)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[
            AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,
            AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,
            AVLinearPCMIsNonInterleaved:false,
        ])
        output.alwaysCopiesSampleData=true
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExtractError.unreadable("can't read audio") }
        var samples=[Int16]()
        while let buffer=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(buffer) else { throw ExtractError.unreadable("missing PCM block") }
            let bytes=CMBlockBufferGetDataLength(block)
            guard bytes%2==0 else { throw ExtractError.unreadable("partial PCM sample") }
            var chunk=[Int16](repeating:0,count:bytes/2)
            let status=chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!) }
            guard status==kCMBlockBufferNoErr else { throw ExtractError.unreadable("can't copy PCM block") }
            samples.append(contentsOf:chunk)
        }
        guard reader.status == .completed else { throw reader.error ?? ExtractError.unreadable("incomplete audio decode") }
        return samples
    }
}
#endif
