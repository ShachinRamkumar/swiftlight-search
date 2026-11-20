import Accelerate
import DigUpKit
import Foundation

@available(macOS 27, *)
public final class AudioHostPrep {
    public struct Mel {
        public let features: [Float]
        public let mask: [Bool]
        public init(features: [Float], mask: [Bool]) { self.features=features; self.mask=mask }
        public var tokens: Int { stride(from: 0, to: mask.count, by: 4).filter { mask[$0] }.count }
    }
    public static let inputNames = ["features", "frame_mask", "keep", "additive", "positions"]
    private let window: [Float]
    private let bank: [Double]
    private let positions: HostTensor
    private let fft: vDSP_DFT_SetupD

    public init(folder: URL) throws {
        func read<T>(_ name: String, _: T.Type, count: Int) throws -> [T] {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard data.count == count*MemoryLayout<T>.stride else { throw WorkerError.failed("audio table size mismatch: \(name)") }
            return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
        }
        window = try read("window.f32", Float.self, count: 320)
        bank = try read("mel-bank.f64", Double.self, count: 257*128)
        let p = try read("positions.f32", Float.self, count: 1024*12)
        positions = HostTensor(shape: [1,1024,1,12], bits: p.map { Float16($0).bitPattern })
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, 512, .FORWARD) else { throw WorkerError.failed("audio FFT setup failed") }
        fft = setup
    }
    deinit { vDSP_DFT_DestroySetupD(fft) }

    public func mel(_ pcm: [Float]) throws -> Mel {
        guard !pcm.isEmpty, pcm.allSatisfy(\.isFinite) else { throw WorkerError.failed("expected finite nonempty mono PCM") }
        let samples = min(pcm.count,480000), padded = ((samples+127)/128)*128
        let frames = max(0,(padded-1)/160)
        var magnitude = [Double](repeating:0,count:frames*257)
        var real = [Double](repeating:0,count:512), imaginary = real, outputR = real, outputI = real
        var mask = [Bool](repeating:false,count:frames)
        for frame in 0..<frames {
            mask[frame] = frame*160+160 < samples
            if !mask[frame] { continue }
            for j in 0..<320 {
                let index = frame*160+j-160
                let product: Float = index >= 0 && index < samples ? pcm[index]*window[j] : 0
                real[j] = Double(product)
            }
            vDSP_DFT_ExecuteD(fft, real, imaginary, &outputR, &outputI)
            for k in 0..<257 { magnitude[frame*257+k] = hypot(outputR[k],outputI[k]) }
        }
        var bins = [Double](repeating:0,count:frames*128)
        if frames > 0 {
            cblas_dgemm(CblasRowMajor,CblasNoTrans,CblasNoTrans,Int32(frames),128,257,1,magnitude,257,bank,128,0,&bins,128)
        }
        var features = [Float](repeating:0,count:frames*128)
        for frame in 0..<frames where mask[frame] {
            for bin in 0..<128 { features[frame*128+bin] = Float(log(bins[frame*128+bin]+0.001)) }
        }
        guard features.allSatisfy(\.isFinite) else { throw WorkerError.failed("nonfinite log mel") }
        return Mel(features:features,mask:mask)
    }

    public func prepare(_ mel: Mel) throws -> [String:HostTensor] {
        guard mel.mask.count <= 3000, mel.features.count == mel.mask.count*128 else { throw WorkerError.failed("invalid mel shape") }
        var features = [UInt16](repeating:0,count:128*3000)
        var mask = [UInt16](repeating:0,count:3000)
        for frame in mel.mask.indices {
            mask[frame] = Float16(mel.mask[frame] ? 1 : 0).bitPattern
            for bin in 0..<128 { features[bin*3000+frame] = Float16(mel.features[frame*128+bin]).bitPattern }
        }
        var keep = [UInt16](repeating:0,count:12*750)
        var additive = [UInt16](repeating:Float16(-40000).bitPattern,count:12*750)
        for distance in 0..<12 { for q in 0..<750 {
            let key = q-(11-distance)
            if key >= 0, key*4 < mel.mask.count, mel.mask[key*4] {
                keep[distance*750+q] = Float16(1).bitPattern
                additive[distance*750+q] = 0
            }
        } }
        return ["features":HostTensor(shape:[1,128,1,3000],bits:features),"frame_mask":HostTensor(shape:[1,1,1,3000],bits:mask),
                "keep":HostTensor(shape:[1,12,1,750],bits:keep),"additive":HostTensor(shape:[1,12,1,750],bits:additive),"positions":positions]
    }

    public static func compose(_ soft: [UInt16], tokens n: Int, host: TextHostPrep) throws -> (inputs:[String:HostTensor],bucket:Int) {
        guard (0...750).contains(n), soft.count == 512*750 else { throw WorkerError.failed("invalid audio output") }
        let ids: [UInt32] = [2,256000]+[UInt32](repeating:258881,count:n)+[258883,1]
        let bucket = [256,512,1024].first { $0 >= n+4 }!
        var inputs = try host.prepare(ids,bucket:bucket), x = inputs["x"]!.bits
        for c in 0..<512 { for i in 0..<n { x[c*bucket+i+2] = soft[c*750+i] } }
        inputs["x"] = HostTensor(shape:[1,512,1,bucket],bits:x)
        return (inputs,bucket)
    }
}
