// Audio and video on macOS: AVFoundation decodes, CoreGraphics hashes frames. Platform/Portable does the same with
// ffmpeg for Linux and Windows.
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

extension AudioExtractor {
    /// Decodes audio (a file, or a video's soundtrack) to 16 kHz mono and writes `window`-second WAV pieces `hop`
    /// seconds apart, skipping silent ones. One model input ignores anything past 30 s, so windows stay ≤ 30 s.
    /// A finite full-track read fixes AAC tail trimming; slices use exact sample indices.
    static func windows(of url: URL, window: Double, hop: Double, minimum: Double = 2, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return ([], 0) }
        let duration = try await asset.load(.duration).seconds
        _ = track
        let samples = try await ShadowAudioDecoder.decode(url)
        let windowSamples = Int(window * sampleRate), hopSamples = Int(hop * sampleRate)
        guard windowSamples > 0, hopSamples > 0, hopSamples <= windowSamples else {
            throw ExtractError.unreadable("invalid audio window schedule")
        }
        var offset = 0, pieces: [MediaPiece] = []
        func emit(_ end: Int) throws {
            let slice = samples[offset..<end]
            guard rms(slice) > 0.003 else { return }
            let out = folder.appendingPathComponent(UUID().uuidString + ".wav")
            try writeWAV(slice, to: out)
            pieces.append(MediaPiece(path: out.path, start: Double(offset) / sampleRate,
                                     end: Double(end) / sampleRate))
        }
        while samples.count - offset >= windowSamples {
            try emit(offset + windowSamples)
            offset += hopSamples
        }
        let alreadyCovered = offset == 0 ? 0 : windowSamples - hopSamples
        if samples.count - offset - alreadyCovered >= Int(minimum * sampleRate) { try emit(samples.count) }
        return (pieces, duration.isFinite ? duration : Double(samples.count) / sampleRate)
    }
}

extension VideoExtractor {
    /// Samples a frame every `interval` seconds and keeps one per shot: a frame that looks like the previous kept one
    /// (8×8 average hash within 4 bits) only extends it. Screen recordings and lectures shrink a lot.
    /// Google's Video Moments Finder also matches queries against per-frame vectors.
    static func keyframes(of url: URL, every interval: Double, maxPixel: Int, maxFrames: Int = 1200, to folder: URL)
        async throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        else { return ([], duration.isFinite ? duration : 0, hasAudio) }

        let step = max(interval, duration / Double(maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = stride(from: min(0.5, duration / 2), to: duration, by: step).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }

        var frames: [MediaPiece] = []
        var lastHash: UInt64?
        for await result in generator.images(for: times) {
            guard case let .success(_, image, actualTime) = result else { continue }
            let hash = averageHash(image)
            if let lastHash, (hash ^ lastHash).nonzeroBitCount <= 4 { continue }
            lastHash = hash
            let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
            try ImageExtractor.write(image, to: out, png: false)
            frames.append(MediaPiece(path: out.path, start: max(0, actualTime.seconds), end: duration))
        }
        // Each kept frame stands for the stretch until the next kept frame.
        for index in frames.indices.dropLast() { frames[index].end = frames[index + 1].start }
        return (frames, duration, hasAudio)
    }

    /// The frame shown at `seconds`, its long side at most `pixels`, as a JPEG for a preview.
    static func frame(at seconds: Double, of url: URL, pixels: Int, to out: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try ImageExtractor.write(image, to: out, png: false)
    }

    static func averageHash(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (index, pixel) in pixels.enumerated() where Int(pixel) > mean { hash |= 1 << UInt64(index) }
        return hash
    }
}

extension MediaInfo {
    /// Duration from the file itself, for when Spotlight hasn't indexed it yet.
    static func duration(of url: URL) -> Double? {
        let seconds = try? runBlocking { try await AVURLAsset(url: url).load(.duration).seconds }
        return seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}
#endif
