import DigUpKit
import Foundation

@available(macOS 27, *)
public final class VisionHostPrep {
    public static let inputNames = ["pixels", "position_rows", "mask", "cos", "sin", "pool"]
    private let positionRows: Int
    private let positions: Data
    private let cos: Data
    private let sin: Data

    public init(folder: URL) throws {
        let compact = FileManager.default.fileExists(atPath: folder.appendingPathComponent("position-table-840.bf16").path)
        positionRows = compact ? 840 : 10240
        positions = try Data(contentsOf: folder.appendingPathComponent(compact ? "position-table-840.bf16" : "position-table.bf16"), options: .mappedIfSafe)
        cos = try Data(contentsOf: folder.appendingPathComponent(compact ? "cos-841.f32" : "cos.f32"), options: .mappedIfSafe)
        sin = try Data(contentsOf: folder.appendingPathComponent(compact ? "sin-841.f32" : "sin.f32"), options: .mappedIfSafe)
        guard positions.count == 2 * positionRows * 768 * 2, cos.count == (positionRows + 1) * 16 * 4, sin.count == cos.count else {
            throw WorkerError.failed("vision host table size mismatch")
        }
    }

    public static func validateCoordinate(_ coordinate: Int) throws {
        guard (-1..<840).contains(coordinate) else { throw WorkerError.failed("vision coordinate \(coordinate) exceeds the 840-row bound") }
    }

    public static func decode(_ url: URL) throws -> RGBImage {
        try ImageDecoder.decode(url)
    }

    public static func target(height h: Int, width w: Int, budget: Int) throws -> (Int,Int) {
        guard [70,140,280].contains(budget), h > 0, w > 0 else { throw WorkerError.failed("unsupported image dimensions/budget: \(budget)") }
        let factor = (Double(budget*9*256)/Double(h*w)).squareRoot()
        var th = Int(floor(factor*Double(h)/48))*48
        var tw = Int(floor(factor*Double(w)/48))*48
        guard th != 0 || tw != 0 else { throw WorkerError.failed("image too thin to embed") }
        if th == 0 { th=48; tw=min((w/h)*48,budget*48) }
        else if tw == 0 { tw=48; th=min((h/w)*48,budget*48) }
        guard th*tw <= budget*9*256 else { throw WorkerError.failed("image resize exceeds budget") }
        return (th,tw)
    }

    private static func coefficients(_ source: Int, _ target: Int) -> ([(Int,[Int64])],Int) {
        let scale=Double(source)/Double(target), filterScale=max(scale,1)
        let support=2*filterScale
        var rows: [(Int,[Double])] = [], maximum=0.0
        for i in 0..<target {
            let center=scale*(Double(i)+0.5)
            let start=max(Int(center-support+0.5),0), end=min(Int(center+support+0.5),source)
            var weights: [Double]=[], total=0.0
            for j in start..<end {
                let x=abs((Double(j)-center+0.5)/filterScale)
                let weight = x < 1 ? ((1.5*x-2.5)*x)*x+1 : (x < 2 ? ((-0.5*x+2.5)*x-4)*x+2 : 0)
                weights.append(weight); total += weight
            }
            if total != 0 { weights=weights.map { $0/total } }
            maximum=max(maximum,weights.max() ?? 0)
            rows.append((start,weights))
        }
        var precision=0
        while precision < 22 {
            if Int(0.5+maximum*Double(1 << (precision+1))) >= 32768 { break }
            precision += 1
        }
        return (rows.map { start,weights in
            (start,weights.map { Int64($0*Double(1 << precision)+($0 < 0 ? -0.5 : 0.5)) })
        },precision)
    }

    public static func resize(_ image: RGBImage, height: Int, width: Int) throws -> RGBImage {
        var bytes=image.pixels, w=image.width, h=image.height
        if width != w {
            let (rows,q)=coefficients(w,width)
            var result=[UInt8](repeating:0,count:h*width*3)
            bytes.withUnsafeBufferPointer { source in
                result.withUnsafeMutableBufferPointer { destination in
                    for y in 0..<h { for x in 0..<width {
                        let (start, weights) = rows[x]
                        var red: Int64 = 1 << (q-1), green = red, blue = red
                        weights.withUnsafeBufferPointer { taps in
                            let row = source.baseAddress!.advanced(by: (y*w+start)*3)
                            for j in 0..<taps.count {
                                let weight = taps[j], offset = j*3
                                red += Int64(row[offset])*weight
                                green += Int64(row[offset+1])*weight
                                blue += Int64(row[offset+2])*weight
                            }
                        }
                        let offset = (y*width+x)*3
                        destination[offset] = UInt8(clamping:red >> q)
                        destination[offset+1] = UInt8(clamping:green >> q)
                        destination[offset+2] = UInt8(clamping:blue >> q)
                    } }
                }
            }
            bytes=result; w=width
        }
        if height != h {
            let (rows,q)=coefficients(h,height)
            var result=[UInt8](repeating:0,count:height*w*3)
            bytes.withUnsafeBufferPointer { source in
                result.withUnsafeMutableBufferPointer { destination in
                    let base = source.baseAddress!
                    for y in 0..<height {
                        let (start, weights) = rows[y]
                        weights.withUnsafeBufferPointer { taps in
                            for x in 0..<w {
                                var red: Int64 = 1 << (q-1), green = red, blue = red
                                for j in 0..<taps.count {
                                    let offset = ((start+j)*w+x)*3, weight = taps[j]
                                    red += Int64(base[offset])*weight
                                    green += Int64(base[offset+1])*weight
                                    blue += Int64(base[offset+2])*weight
                                }
                                let offset = (y*w+x)*3
                                destination[offset] = UInt8(clamping:red >> q)
                                destination[offset+1] = UInt8(clamping:green >> q)
                                destination[offset+2] = UInt8(clamping:blue >> q)
                            }
                        }
                    }
                }
            }
            bytes=result; h=height
        }
        return try RGBImage(width:w,height:h,pixels:bytes)
    }

    public func prepare(_ image: RGBImage, budget: Int) throws -> (inputs:[String:HostTensor],tokens:Int) {
        let (h,w)=try Self.target(height:image.height,width:image.width,budget:budget)
        let resizeStart=ImageCPUProfile.begin()
        let resized=try Self.resize(image,height:h,width:w)
        ImageCPUProfile.end("resize",resizeStart)
        let buildStart=ImageCPUProfile.begin()
        let p=budget*9, ph=h/16, pw=w/16, valid=ph*pw
        var pixels=[UInt16](repeating:0,count:768*p), pos=pixels
        var mask=[UInt16](repeating:Float16(-40000).bitPattern,count:p)
        var cosine=[UInt16](repeating:0,count:64*p), sine=cosine
        var pool=[UInt16](repeating:0,count:p*budget)
        try Self.validateCoordinate(pw - 1)
        try Self.validateCoordinate((valid - 1) / pw)
        positions.withUnsafeBytes { positionBytes in
            cos.withUnsafeBytes { cosBytes in
                sin.withUnsafeBytes { sinBytes in
                    let table=positionBytes.bindMemory(to:UInt16.self)
                    let ct=cosBytes.bindMemory(to:Float.self), st=sinBytes.bindMemory(to:Float.self)
                    for patch in 0..<p {
                        let x=patch < valid ? patch%pw : -1, y=patch < valid ? patch/pw : -1
                        for channel in 0..<64 {
                            let axis=channel/32, c=channel%16, coordinate=axis == 0 ? x : y
                            cosine[channel*p+patch]=Float16(ct[(coordinate+1)*16+c]).bitPattern
                            sine[channel*p+patch]=Float16(st[(coordinate+1)*16+c]).bitPattern
                        }
                        if patch >= valid { continue }
                        mask[patch]=0
                        pool[patch*budget+x/3+(pw/3)*(y/3)]=Float16(Float(1)/9).bitPattern
                        for channel in 0..<768 {
                            let pixel=channel/3, c=channel%3
                            let v=resized.pixels[((y*16+pixel/16)*w+x*16+pixel%16)*3+c]
                            pixels[channel*p+patch]=Float16(Float(v)*Float(1.0/255.0)).bitPattern
                            let a=Float(bitPattern:UInt32(table[x*768+channel]) << 16)
                            let b=Float(bitPattern:UInt32(table[(positionRows+y)*768+channel]) << 16)
                            pos[channel*p+patch]=Float16(a+b).bitPattern
                        }
                    }
                }
            }
        }
        ImageCPUProfile.end("patchify_positions_rope_mask_pool",buildStart)
        return (["pixels":HostTensor(shape:[1,768,1,p],bits:pixels), "position_rows":HostTensor(shape:[1,768,1,p],bits:pos),
                 "mask":HostTensor(shape:[1,1,1,p],bits:mask), "cos":HostTensor(shape:[1,64,1,p],bits:cosine),
                 "sin":HostTensor(shape:[1,64,1,p],bits:sine), "pool":HostTensor(shape:[p,budget],bits:pool)],valid/9)
    }

    public static func compose(_ soft: [UInt16], tokens n: Int, budget: Int, host: TextHostPrep) throws -> (inputs:[String:HostTensor],bucket:Int) {
        guard [70,140,280].contains(budget), n > 0, n <= budget, soft.count == 512*budget else { throw WorkerError.failed("invalid vision output") }
        let ids: [UInt32]=[2,255999]+[UInt32](repeating:258880,count:n)+[258882,1]
        let bucket = [128,256,512].first { $0 >= n+4 }!
        var inputs=try host.prepare(ids,bucket:bucket)
        var x=inputs["x"]!.bits
        for c in 0..<512 { for i in 0..<n { x[c*bucket+i+2]=soft[c*budget+i] } }
        inputs["x"]=HostTensor(shape:[1,512,1,bucket],bits:x)
        return (inputs,bucket)
    }
}
