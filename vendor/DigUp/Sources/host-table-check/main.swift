import CryptoKit
import DigUpCoreAIRuntime
import DigUpKit
import Foundation
import HostTableCodec

@available(macOS 27, *)
func check() throws {
    guard CommandLine.arguments.count == 4 else {
        throw HostTableError.invalid("usage: host-table-check SOURCE_RUNTIME PACKED_TABLES REPO")
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let packed = URL(fileURLWithPath: CommandLine.arguments[2])
    let repo = URL(fileURLWithPath: CommandLine.arguments[3])
    let raw = try Data(contentsOf: source.appendingPathComponent("token-table.bf16"), options: .alwaysMapped)
    let table = try PackedRowTable(url: packed.appendingPathComponent("token-table.slht"))
    var digest = SHA256()
    var chunkTimes: [Double] = []
    for start in stride(from: 0, to: table.rows, by: 64) {
        let began = DispatchTime.now().uptimeNanoseconds
        let rows = try table.gather((start..<min(start + 64, table.rows)).map(UInt32.init))
        chunkTimes.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
        rows.withUnsafeBytes { digest.update(bufferPointer: $0) }
    }
    guard Data(digest.finalize()) == table.decodedSHA256 else { throw HostTableError.invalid("Swift full decode hash differs") }
    let originalTokenizer = try HFTokenizer(contentsOf: source.appendingPathComponent("tokenizer.json"))
    let resources = try RuntimeDirectory.HostResourcePaths(directory: packed, compact: true).acquire()
    let tokenizer = resources.tokenizer
    defer { originalTokenizer.close() }
    let originalHost = try TextHostPrep(tokenTable: source.appendingPathComponent("token-table.bf16"), ropeTables: source.appendingPathComponent("rope-tables"))
    let host = resources.text
    for bucket in TextHostPrep.buckets {
        let ids: [UInt32] = [2, 0, 262143, 42, 1]
        let expected = try originalHost.prepare(ids, bucket: bucket)
        let actual = try host.prepare(ids, bucket: bucket)
        guard Set(expected.keys) == Set(actual.keys) else { throw HostTableError.invalid("host input names") }
        for name in expected.keys {
            guard expected[name]!.shape == actual[name]!.shape, expected[name]!.bits == actual[name]!.bits else {
                throw HostTableError.invalid("text host tensor differs: \(bucket)/\(name)")
            }
        }
    }
    let originalVision = try VisionHostPrep(folder: source.appendingPathComponent("vision-host"))
    let vision = try VisionHostPrep(folder: packed.appendingPathComponent("vision-host"))
    for budget in [70, 140, 280] {
        for (width, height) in [(96, 128), (budget * 48, 48), (48, budget * 48)] {
            let image = try RGBImage(width: width, height: height, pixels: (0..<(width * height * 3)).map { UInt8(truncatingIfNeeded: $0) })
            let expected = try originalVision.prepare(image, budget: budget)
            let actual = try vision.prepare(image, budget: budget)
            guard expected.tokens == actual.tokens else { throw HostTableError.invalid("vision token count") }
            for name in expected.inputs.keys {
                guard expected.inputs[name]!.bits == actual.inputs[name]!.bits else { throw HostTableError.invalid("vision tensor: \(name)") }
            }
        }
    }
    do { try VisionHostPrep.validateCoordinate(840); throw HostTableError.invalid("accepted coordinate 840") }
    catch let error as HostTableError { throw error }
    catch { /* The reachable-row guard must reject 840. */ }

    let queryTexts = ["red and blue screenshot", "quarterly storage report", "meeting notes",
        "invoice for the laptop", "photo of a mountain", "中文文档", "how does the cache recover after an OS update?",
        String(repeating: "storage model runtime cache query ", count: 15)]
    let queries = try queryTexts.map { text in
        let prompt = Prompts.query(text)
        let ids = try tokenizer.tokenize(prompt, limit: 128)
        guard ids == (try originalTokenizer.tokenize(prompt, limit: 128)) else { throw HostTableError.invalid("query tokenizer differs") }
        return ids
    }
    var documents: [[UInt32]] = []
    var files = try FileManager.default.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    let research = repo.appendingPathComponent("research")
    for folder in try FileManager.default.contentsOfDirectory(at: research, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
        let report = folder.appendingPathComponent("REPORT.md")
        if FileManager.default.fileExists(atPath: report.path) { files.append(report) }
    }
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        let prompt = "title: none | text: " + text
        let ids = try tokenizer.tokenize(prompt, limit: 2048)
        guard ids == (try originalTokenizer.tokenize(prompt, limit: 2048)) else { throw HostTableError.invalid("tokenizer differs") }
        if ids.count >= 512 { documents.append(ids) }
    }
    func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["median_ms": sorted[sorted.count / 2], "max_ms": sorted.last!]
    }
    func benchmark(_ sequences: [[UInt32]], cacheBytes: Int) throws -> [String: Double] {
        let reader = try PackedRowTable(url: packed.appendingPathComponent("token-table.slht"), cacheBytes: cacheBytes)
        if cacheBytes > 0 { for ids in sequences { _ = try reader.gather(ids) } }
        var times: [Double] = []
        for _ in 0..<3 {
            for ids in sequences {
                let start = DispatchTime.now().uptimeNanoseconds
                let actual = try reader.gather(ids)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                try raw.withUnsafeBytes { bytes in
                    let rows = bytes.bindMemory(to: UInt16.self)
                    for (i, id) in ids.enumerated() {
                        guard actual[(i * 512)..<((i + 1) * 512)].elementsEqual(rows[(Int(id) * 512)..<((Int(id) + 1) * 512)]) else {
                            throw HostTableError.invalid("lookup differs")
                        }
                    }
                }
            }
        }
        return stats(times)
    }
    let report: [String: Any] = ["swift_full_decode_exact": true, "text_host_buckets_exact": 7,
        "vision_host_cases_exact": 9, "tokenizer_exact": true, "coordinate_840_rejected": true,
        "chunk64_decode": stats(chunkTimes), "query_texts": queryTexts, "queries": queries.count, "documents": documents.count,
        "document_tokens_median": documents.map(\.count).sorted()[documents.count / 2],
        "query_uncached": try benchmark(queries, cacheBytes: 0),
        "query_cache64MiB": try benchmark(queries, cacheBytes: 64 * 1024 * 1024),
        "document_uncached": try benchmark(documents, cacheBytes: 0),
        "document_cache64MiB": try benchmark(documents, cacheBytes: 64 * 1024 * 1024)]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}

do {
    if #available(macOS 27, *) { try check() }
    else { throw HostTableError.invalid("macOS 27 required") }
} catch {
    FileHandle.standardError.write(Data("host-table-check: \(error)\n".utf8)); exit(1)
}
