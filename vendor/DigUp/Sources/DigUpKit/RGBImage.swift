import Foundation
import ImageIO
import CJPEG

public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              width * height <= 100_000_000, pixels.count == width * height * 3 else {
            throw WorkerError.failed("invalid RGB image dimensions/bytes")
        }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum ImageDecoder {
    public static func decode(_ url: URL) throws -> RGBImage {
        let data = try Data(contentsOf:url, options:.mappedIfSafe)
        if data.starts(with:[0xff,0xd8]) {
            var pixels: UnsafeMutablePointer<UInt8>?
            var width: Int32=0, height: Int32=0
            var message=[CChar](repeating:0,count:256)
            let ok=data.withUnsafeBytes { bytes in
                digup_jpeg_decode(bytes.bindMemory(to:UInt8.self).baseAddress, data.count,
                                  &pixels, &width, &height, &message, message.count)
            }
            guard ok != 0, let pixels else { throw WorkerError.failed("JPEG decode: \(String(cString:message))") }
            defer { digup_jpeg_free(pixels) }
            let source=CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary)
            let properties=source.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [CFString:Any] }
            return try orient(width:Int(width),height:Int(height),pixels:Array(UnsafeBufferPointer(start:pixels,count:Int(width)*Int(height)*3)),
                              orientation:properties?[kCGImagePropertyOrientation] as? Int ?? 1)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              let bytes = image.dataProvider?.data else { throw WorkerError.failed("unreadable image: \(url.path)") }
        // Read the provider directly. A CGContext draw would color-convert and premultiply alpha.
        let w = image.width, h = image.height, bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        guard w > 0, h > 0, w * h <= 100_000_000, [1,2,4,8,16].contains(bpc), let space = image.colorSpace else {
            throw WorkerError.failed("unsupported decoded image layout")
        }
        let raw = CFDataGetBytePtr(bytes)!
        let length = CFDataGetLength(bytes)
        guard length >= image.bytesPerRow * h else { throw WorkerError.failed("short image provider") }
        let alpha = image.alphaInfo
        guard alpha != .premultipliedFirst && alpha != .premultipliedLast else {
            throw WorkerError.failed("ImageIO returned premultiplied samples; straight RGB required")
        }
        let first = alpha == .first || alpha == .noneSkipFirst
        let little = image.bitmapInfo.contains(.byteOrder32Little) || image.bitmapInfo.contains(.byteOrder16Little)
        func sample(_ x: Int, _ y: Int, _ channel: Int) -> Int {
            let bit = x * bpp + channel * bpc
            let offset = y * image.bytesPerRow + bit / 8
            if bpc == 16 {
                return little ? Int(raw[offset]) | Int(raw[offset+1]) << 8 : Int(raw[offset]) << 8 | Int(raw[offset+1])
            }
            return (Int(raw[offset]) >> (8-bpc-bit%8)) & ((1 << bpc)-1)
        }
        let palette = space.model == .indexed ? (space.colorTable ?? []) : []
        var pixels = [UInt8](repeating:0,count:w*h*3)
        if bpc == 8 && space.model == .rgb {
            let c = first ? 1 : 0
            let red = little && bpp == 32 ? 3-c : c
            let green = little && bpp == 32 ? 2-c : c+1
            let blue = little && bpp == 32 ? 1-c : c+2
            let stride = bpp / 8
            pixels.withUnsafeMutableBufferPointer { destination in
                for y in 0..<h {
                    let sourceRow = raw.advanced(by: y * image.bytesPerRow)
                    let targetRow = destination.baseAddress!.advanced(by: y * w * 3)
                    for x in 0..<w {
                        targetRow[x*3] = sourceRow[x*stride+red]
                        targetRow[x*3+1] = sourceRow[x*stride+green]
                        targetRow[x*3+2] = sourceRow[x*stride+blue]
                    }
                }
            }
        } else if bpc == 8 && space.model == .monochrome {
            let channel = first ? 1 : 0, stride = bpp / 8
            pixels.withUnsafeMutableBufferPointer { destination in
                for y in 0..<h {
                    let sourceRow = raw.advanced(by: y * image.bytesPerRow)
                    let targetRow = destination.baseAddress!.advanced(by: y * w * 3)
                    for x in 0..<w {
                        let value = sourceRow[x*stride+channel]
                        targetRow[x*3] = value
                        targetRow[x*3+1] = value
                        targetRow[x*3+2] = value
                    }
                }
            }
        } else {
            for y in 0..<h {
                for x in 0..<w {
                    let offset = (y*w+x)*3
                    let channels: [Int]
                    switch space.model {
                    case .rgb:
                        let c = first ? 1 : 0
                        channels = (c..<c+3).map { channel in
                            let physical = little && bpc == 8 && bpp == 32 ? 3-channel : channel
                            let v = sample(x,y,physical)
                            return bpc == 16 ? v >> 8 : v
                        }
                    case .monochrome:
                        let value = sample(x,y,first ? 1 : 0)
                        let v = bpc == 16 ? min(value,255) : value * 255 / ((1 << bpc)-1)
                        channels = [v,v,v]
                    case .indexed:
                        let i = sample(x,y,0)*3
                        guard i+2 < palette.count else { throw WorkerError.failed("invalid palette index") }
                        channels = (i..<i+3).map { Int(palette[$0]) }
                    case .cmyk:
                        guard bpc == 8 else { throw WorkerError.failed("unsupported CMYK depth") }
                        let k = sample(x,y,3)
                        channels = (0..<3).map { ((255-sample(x,y,$0))*(255-k)+127)/255 }
                    default: throw WorkerError.failed("unsupported image color model")
                    }
                    for c in 0..<3 { pixels[offset+c] = UInt8(channels[c]) }
                }
            }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
        return try orient(width:w,height:h,pixels:pixels,orientation:properties?[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    static func orient(width w: Int, height h: Int, pixels: [UInt8], orientation: Int) throws -> RGBImage {
        if !(2...8).contains(orientation) {
            return try RGBImage(width:w,height:h,pixels:pixels)
        }
        let swap = orientation >= 5 && orientation <= 8
        let ow = swap ? h : w, oh = swap ? w : h
        var oriented = [UInt8](repeating:0,count:pixels.count)
        for y in 0..<h {
            for x in 0..<w {
                let target: (Int,Int)
                switch orientation {
                case 2: target = (w-1-x,y)
                case 3: target = (w-1-x,h-1-y)
                case 4: target = (x,h-1-y)
                case 5: target = (y,x)
                case 6: target = (h-1-y,x)
                case 7: target = (h-1-y,w-1-x)
                case 8: target = (y,w-1-x)
                default: target = (x,y)
                }
                for c in 0..<3 { oriented[(target.1*ow+target.0)*3+c] = pixels[(y*w+x)*3+c] }
            }
        }
        return try RGBImage(width:ow,height:oh,pixels:oriented)
    }

}
