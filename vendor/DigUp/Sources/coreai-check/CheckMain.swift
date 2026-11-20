import CTokenizer
import Darwin
import Foundation
import DigUpCoreAIRuntime

@available(macOS 27, *)
struct Configuration: Decodable {
    let index: String
    let inputsFile: String?
    let tokenizer: String
    let tokenTable: String
    let ropeTables: String
    let assets: String
    let manifest: String
    let scratch: String
    let logs: String
    let representatives: [String: String]
    var scratchURL: URL { URL(fileURLWithPath: scratch) }
    func embedder(_ role: TextRole) throws -> CoreAIEmbedder {
        let root = URL(fileURLWithPath: assets)
        let model = try CoreAIAssets(directory: root, manifest: URL(fileURLWithPath: manifest))
        let directory = logs
        let callback: @Sendable (URL, SpecializationPhase) throws -> Void = { url, phase in
            try auditSpecialization(url, phase: phase, logs: directory)
        }
        let observer = ProcessInfo.processInfo.environment["P3B_SPECIALIZATION_AUDIT"] == "1" ? callback : nil
        if model.names.contains("text.aimodel") || FileManager.default.fileExists(atPath: assets + "/p2-manifest.json") {
            return try RuntimeDirectory(URL(fileURLWithPath: assets)).embedder(role, specializationObserver: observer)
        }
        return try CoreAIEmbedder(role: role,
            assets: CoreAIAssets(directory: URL(fileURLWithPath: assets), manifest: URL(fileURLWithPath: manifest)),
            tokenizer: URL(fileURLWithPath: tokenizer), tokenTable: URL(fileURLWithPath: tokenTable),
            ropeTables: URL(fileURLWithPath: ropeTables), log: URL(fileURLWithPath: logs).appendingPathComponent("runtime.log"),
            specializationObserver: observer)
    }
    func host() throws -> TextHostPrep {
        try TextHostPrep(tokenTable: URL(fileURLWithPath: tokenTable), ropeTables: URL(fileURLWithPath: ropeTables))
    }
    func memory() throws -> Any {
        let p = Process(); let pipe = Pipe()
        if let customPython = ProcessInfo.processInfo.environment["SWIFTLIGHT_PYTHON"], !customPython.isEmpty {
            p.executableURL = URL(fileURLWithPath: customPython)
            p.arguments = ["-E", "-s", "-B", logs+"/memory_probe.py", String(getpid())]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-E", "-s", "-B", logs+"/memory_probe.py", String(getpid())]
        }
        p.standardOutput = pipe
        try p.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CheckError("memory probe failed") }
        return try JSONSerialization.jsonObject(with: bytes)
    }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckError(message) }
}
func load<T: Decodable>(_ type: T.Type, _ path: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: path))
}
func jsonValue<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted(); let index = Double(sorted.count - 1) * p
    let lower = Int(index); let upper = min(lower+1, sorted.count-1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
}
func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, aa = 0.0, bb = 0.0
    for (x,y) in zip(a,b) { dot += Double(x)*Double(y); aa += Double(x)*Double(x); bb += Double(y)*Double(y) }
    return dot / (aa*bb).squareRoot()
}
func save(_ value: [String: Any], _ path: URL) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: path, options: .atomic)
}

@available(macOS 27, *)
struct TokenCase: Decodable { let id: String; let text: String; let ids512: [UInt32]; let ids2048: [UInt32]; let group: String }
@available(macOS 27, *)
struct HostCase: Decodable {
    struct Input: Decodable { let shape: [Int]; let file: String; let sha256: String }
    let id: String; let fixture: String; let function: String; let bucket: Int; let ids: [UInt32]
    let inputs: [String: Input]; let output: String
}
@available(macOS 27, *)
struct GoldenCase: Decodable { let id: String; let text: String; let role: TextRole; let unit: [Float]; let ids: [UInt32]; let bucket: Int }

@available(macOS 27, *)
func checkTokenizer(_ config: Configuration) throws -> [String: Any] {
    let tokenizer = try HFTokenizer(contentsOf: URL(fileURLWithPath: config.tokenizer))
    let cases = try load([TokenCase].self, config.scratchURL.appendingPathComponent("tokenizer.json"))
    for c in cases {
        for (limit, expected) in [(512,c.ids512),(2048,c.ids2048)] {
            let ids = try tokenizer.tokenize(c.text, limit: limit)
            try require(ids == expected, "token IDs differ: \(c.id), limit \(limit), expected \(expected.prefix(24)), got \(ids.prefix(24))")
        }
    }
    var handle: UnsafeMutableRawPointer?
    let status = Array(config.tokenizer.utf8).withUnsafeBufferPointer { tok_load($0.baseAddress, $0.count, &handle) }
    try require(status == 0, "FFI load failed")
    defer { _ = tok_free(handle) }
    var count = 99
    let invalid: [UInt8] = [0xff,0xc0,0xaf]
    let bad = invalid.withUnsafeBufferPointer { tok_encode(handle,$0.baseAddress,$0.count,1,1,nil,0,&count) }
    try require(bad == 1 && count == 0, "invalid UTF-8 boundary")
    let capacity = tok_encode(handle,nil,0,1,1,nil,0,&count)
    try require(capacity == 2 && count == 2, "capacity query / null empty input")
    try require(tok_encode(nil,nil,0,1,1,nil,0,&count) == 1, "null handle accepted")
    try require(tok_encode(handle,nil,1,1,1,nil,0,&count) == 1, "null nonempty input accepted")
    var empty = [UInt32](repeating: 9, count: 2)
    let emptyStatus = empty.withUnsafeMutableBufferPointer { tok_encode(handle,nil,0,1,1,$0.baseAddress,$0.count,&count) }
    try require(emptyStatus == 0 && empty == [2,1], "empty input BOS/EOS")
    return ["passed":true,"golden":cases.filter{$0.group=="golden"}.count,"fuzz":cases.filter{$0.group=="fuzz"}.count,
            "limits":[512,2048],"comparisons":cases.count*2,"ffi_boundary_checks":5]
}

@available(macOS 27, *)
func checkHost(_ config: Configuration) throws -> [String: Any] {
    let host = try config.host()
    let cases = try load([HostCase].self, config.scratchURL.appendingPathComponent("host-cases.json"))
    var comparisons = 0
    for c in cases {
        let inputs = try host.prepare(c.ids,bucket:c.bucket)
        for name in TextHostPrep.inputNames {
            let expected = try Data(contentsOf: URL(fileURLWithPath:c.inputs[name]!.file))
            let tensor = inputs[name]!
            if tensor.bytes != expected || tensor.shape != c.inputs[name]!.shape {
                let actual = tensor.bytes
                let first = zip(actual,expected).enumerated().first(where:{$0.element.0 != $0.element.1})?.offset
                throw CheckError("host bytes differ: \(c.id) \(name), first byte \(String(describing:first)), sizes \(actual.count)/\(expected.count)")
            }
            comparisons += 1
        }
    }
    for role in [TextRole.query,.document] {
        for n in 1...role.limit {
            let choices = role == .query ? [32,64,128,256,512] : [256,512,1024,2048]
            try require(try TextHostPrep.bucketFor(n,role:role) == choices.first(where:{n <= $0})!, "bucket selection mismatch")
        }
    }
    for bits in [[UInt16](repeating:0,count:768),[UInt16](repeating:Float16.infinity.bitPattern,count:768),
                 [UInt16](repeating:Float16.nan.bitPattern,count:768),[UInt16](repeating:Float16.leastNonzeroMagnitude.bitPattern,count:768).enumerated().map{$0.offset == 0 ? $0.element : 0}] {
        do { _ = try TextHostPrep.finalize(bits); throw CheckError("invalid vector accepted") }
        catch let error as CheckError { throw error } catch {}
    }
    return ["passed":true,"cases":cases.count,"tensors":comparisons,"buckets":Array(Set(cases.map(\.bucket))).sorted(),"bucket_boundary_checks":2560,"finalize_rejection_checks":4]
}

@available(macOS 27, *)
func checkRuntime(_ config: Configuration) throws -> [String: Any] {
    let host = try config.host()
    let cases = try load([HostCase].self,config.scratchURL.appendingPathComponent("host-cases.json"))
    var count = 0
    for role in [TextRole.query,.document] {
        let embedder = try config.embedder(role)
        defer { embedder.close() }
        for c in cases where (c.bucket<=128) == (role == .query) {
            let inputs = try host.prepare(c.ids,bucket:c.bucket)
            let raw = try embedder.rawOutput(inputs,bucket:c.bucket)
            let actual = raw.withUnsafeBytes { Data($0) }
            let expected = try Data(contentsOf: URL(fileURLWithPath:c.output))
            try require(actual == expected,"runtime output bytes differ: \(c.id)")
            count += 1
        }
    }
    return ["passed":true,"cases":count,"bytes_per_vector":1536]
}

@available(macOS 27, *)
func checkGolden(_ config: Configuration) throws -> [String: Any] {
    let cases = try load([GoldenCase].self,config.scratchURL.appendingPathComponent("golden.json"))
    var values: [[String:Any]] = []; var cosines: [Double] = []
    for role in [TextRole.query,.document] {
        let embedder = try config.embedder(role)
        defer { embedder.close() }
        try require(try embedder.loadedAssets() == [role == .query ? "text-query" : "text-doc"],"initial asset selection")
        for c in cases where c.role == role {
            let unit = try embedder.embedTexts([c.text])[0]
            let cos = cosine(unit,c.unit)
            try require(unit.count==768 && unit.allSatisfy(\.isFinite) && cos.isFinite && cos>=0.9999,"golden accuracy failed: \(c.id), \(cos)")
            values.append(["id":c.id,"cosine":cos,"bucket":embedder.lastTimings[0].bucket]);cosines.append(cos)
        }
        if role == .query { try require(try embedder.loadedAssets() == ["text-doc","text-query"],"long-query document asset did not load lazily") }
        do { _ = try embedder.embedImages([],budget:140); throw CheckError("images accepted") }
        catch let e as CheckError { throw e } catch {}
        do { _ = try embedder.embedAudio([]); throw CheckError("audio accepted") }
        catch let e as CheckError { throw e } catch {}
        embedder.close();embedder.close()
        do { _ = try embedder.embedTexts(["closed"]); throw CheckError("closed embedder accepted input") }
        catch let e as CheckError { throw e } catch {}
    }
    return ["passed":true,"count":values.count,"min_cosine":cosines.min()!,"median_cosine":percentile(cosines,0.5),"fixtures":values,"lazy_asset_check":true]
}

@available(macOS 27, *)
func checkRecovery(_ config: Configuration, doubleOnly: Bool = false) throws -> [String: Any] {
    let embedder = try config.embedder(.query)
    defer { embedder.close() }
    let text = config.representatives["q32"]!
    let baseline = try embedder.embedTexts([text])
    if doubleOnly {
        try embedder.injectFunctionLoadFailures(2)
        let start = Date()
        var message: String?
        do { _ = try embedder.embedTexts([text]) } catch { message = String(describing: error) }
        try require(message?.contains("load_function failed:") == true && message?.contains("specialization/retry failed:") == true,
                    "double failure did not propagate both errors")
        return ["passed": true, "double_failure_seconds": Date().timeIntervalSince(start), "double_error": message!]
    }
    try embedder.injectFunctionLoadFailures(1)
    let start = Date()
    let recovered = try embedder.embedTexts([text])
    let single = Date().timeIntervalSince(start)
    try require(baseline == recovered,"recovery changed vector")
    try embedder.injectFunctionLoadFailures(2)
    let doubleStart = Date()
    var doubleError: String?
    do { _ = try embedder.embedTexts([text]) }
    catch { doubleError = String(describing:error) }
    let doubleSeconds = Date().timeIntervalSince(doubleStart)
    try require(doubleError?.contains("load_function failed:") == true && doubleError?.contains("specialization/retry failed:") == true,"double failure did not propagate both errors")
    return ["passed":true,"single_recovery_seconds":single,"double_failure_seconds":doubleSeconds,"double_error":doubleError!,"bit_identical_after_recovery":true]
}

@available(macOS 27, *)
func performance(_ config: Configuration, role: TextRole) throws -> [String: Any] {
    let before = try config.memory()
    let start = Date();let embedder = try config.embedder(role);let initSeconds=Date().timeIntervalSince(start)
    defer { embedder.close() }
    let afterInit = try config.memory()
    var records: [[String:Any]] = []
    for name in (role == .query ? ["q64"] : ["d256","d512","d1024","d2048"]) {
        let text = config.representatives[name]!
        for _ in 0..<2 { _ = try embedder.embedTexts([text]) }
        var timings: [EmbeddingTiming] = []
        for _ in 0..<20 {
            let output = try embedder.embedTexts([text])[0]
            try require(output.allSatisfy(\.isFinite),"performance nonfinite output")
            try require(embedder.lastTimings[0].bucket == Int(name.dropFirst())!,"performance fixture used wrong bucket: \(name)")
            timings.append(embedder.lastTimings[0])
        }
        var summary: [String:Any] = [:]
        for (key,values) in [("tokenize",timings.map(\.tokenizeMS)),("prep",timings.map(\.prepMS)),("model",timings.map(\.modelMS)),
                             ("finalize",timings.map(\.finalizeMS)),("total",timings.map(\.totalMS)),
                             ("host",timings.map{$0.tokenizeMS+$0.prepMS+$0.finalizeMS})] {
            summary[key] = ["median_ms":percentile(values,0.5),"p90_ms":percentile(values,0.9)]
        }
        records.append(["function":name,"calls":20,"summary":summary,"samples":try jsonValue(timings)])
    }
    return ["passed":true,"role":role.rawValue,"init_seconds":initSeconds,"warmup_seconds":embedder.warmupSeconds,"model_load_seconds":embedder.modelLoadSeconds,
            "worker_info":try jsonValue(embedder.info),"before":before,"after_init":afterInit,"after_runs":try config.memory(),"functions":records]
}

@available(macOS 27, *)
func contention(_ config: Configuration, role: TextRole, rendezvous: String) throws -> [String:Any] {
    let folder = URL(fileURLWithPath:rendezvous)
    let embedder = try config.embedder(role)
    defer { embedder.close() }
    let names = role == .query ? ["q64"] : ["d512","d2048"]
    for name in names { _ = try embedder.embedTexts([config.representatives[name]!]) }
    try Data(String(getpid()).utf8).write(to:folder.appendingPathComponent(role.rawValue+".ready"))
    let deadline=Date().addingTimeInterval(180)
    while !FileManager.default.fileExists(atPath:folder.appendingPathComponent("go").path) {
        try require(Date()<deadline,"contention rendezvous timeout");Thread.sleep(forTimeInterval:0.01)
    }
    var samples: [[String:Any]] = []
    if role == .query {
        while !FileManager.default.fileExists(atPath:folder.appendingPathComponent("done").path) {
            try require(Date()<deadline,"contention query timeout")
            let start=Date().timeIntervalSince1970
            let output=try embedder.embedTexts([config.representatives["q64"]!])[0]
            try require(output.allSatisfy(\.isFinite),"contention nonfinite query")
            samples.append(["function":"q64","start":start,"end":Date().timeIntervalSince1970,"ms":embedder.lastTimings[0].totalMS])
        }
    } else {
        for name in names {
            for _ in 0..<20 {
                let start=Date().timeIntervalSince1970
                let output=try embedder.embedTexts([config.representatives[name]!])[0]
                try require(output.allSatisfy(\.isFinite),"contention nonfinite document")
                samples.append(["function":name,"start":start,"end":Date().timeIntervalSince1970,"ms":embedder.lastTimings[0].totalMS])
            }
        }
        try Data().write(to:folder.appendingPathComponent("done"))
    }
    return ["passed":true,"role":role.rawValue,"samples":samples,"after_runs":try config.memory()]
}

@main
struct CheckMain {
    static func main() async {
        let arguments=CommandLine.arguments
        guard arguments.count>=4 else {
            print("usage: coreai-check <tokenizer|host|runtime|golden|recovery|performance-query|performance-document|contention-query|contention-document> <config.json> <result.json> [rendezvous-directory]")
            exit(2)
        }
        let status = await Task.detached { () -> Int32 in
            let output=URL(fileURLWithPath:arguments[3]);let mode=arguments[1]
            do {
                guard #available(macOS 27, *) else { throw CheckError("macOS 27 required") }
                let config=try load(Configuration.self,URL(fileURLWithPath:arguments[2]))
                let result: [String:Any]
                switch mode {
                case "probe-query": result=try await probeCache(config,role:.query)
                case "probe-document": result=try await probeCache(config,role:.document)
                case "reset-document-cache": result=try await resetDocumentCache(config)
                case "direct-documents": result=try directDocuments(config)
                case "input-recovery": result=try checkInputRecovery(config)
                case "shadow-race": result=try checkShadowRace(config)
                case "storage": result=try checkStorage(config)
                case "tokenizer": result=try checkTokenizer(config)
                case "host": result=try checkHost(config)
                case "runtime": result=try checkRuntime(config)
                case "golden": result=try checkGolden(config)
                case "recovery": result=try checkRecovery(config)
                case "recovery-double": result=try checkRecovery(config,doubleOnly:true)
                case "performance-query": result=try performance(config,role:.query)
                case "performance-document": result=try performance(config,role:.document)
                case "contention-query", "contention-document":
                    guard arguments.count==5 else { throw CheckError("rendezvous directory required") }
                    result=try contention(config,role:mode=="contention-query" ? .query : .document,rendezvous:arguments[4])
                default: throw CheckError("unknown mode \(mode)")
                }
                try save(result.merging(["mode":mode]){$1},output)
                if result["passed"] as? Bool == false {
                    print("\(mode) failed: \(result)")
                    return 1
                }
                print("\(mode) passed")
                return 0
            } catch {
                try? save(["mode":mode,"passed":false,"error":String(describing:error)],output)
                FileHandle.standardError.write(Data("\(mode) failed: \(error)\n".utf8))
                return 1
            }
        }.value
        exit(status)
    }
}
