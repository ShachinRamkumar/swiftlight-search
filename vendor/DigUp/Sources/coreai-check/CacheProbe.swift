import CoreAI
import DigUpCoreAIRuntime
import Foundation

@available(macOS 27, *)
func resetDocumentCache(_ config: Configuration) async throws -> [String: Any] {
    let assets = try CoreAIAssets(directory: URL(fileURLWithPath: config.assets), manifest: URL(fileURLWithPath: config.manifest))
    let merged = assets.names.contains("text.aimodel")
    let budgetKey = merged ? "text" : "document"
    let url = URL(fileURLWithPath: config.assets).appendingPathComponent(merged ? "text.aimodel" : "text-doc.aimodel")
    let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    let budgetURL = URL(fileURLWithPath: config.logs).appendingPathComponent("r3-specializations.json")
    var budget = (try? load([String: Int].self, budgetURL)) ?? ["query": 0, "document": 0]
    try require(budget[budgetKey, default: 0] < 4, "round 3 document specialization budget exhausted")
    let roots = [NSHomeDirectory() + "/Library/Caches/coreai-cache",
                 NSHomeDirectory() + "/Library/Application Support/coreai-cache"]
    func snapshot(_ phase: String) throws -> [String: Any] {
        var sizes: [String: String] = [:]
        for root in roots {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk", root]; process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try require(process.terminationStatus == 0, "cache size measurement failed")
            sizes[root] = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: config.logs)
        let free = (attributes[.systemFreeSize] as! NSNumber).int64Value
        let record: [String: Any] = ["phase": phase, "asset": url.deletingPathExtension().lastPathComponent, "time": Date().timeIntervalSince1970,
                                     "cache_du_kib": sizes, "disk_free_bytes": free]
        let logURL = URL(fileURLWithPath: config.logs).appendingPathComponent("r3-cache-transitions.jsonl")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        return record
    }
    let initial = try snapshot("before-delete")
    try require((initial["disk_free_bytes"] as! Int64) >= 9_900_000_000, "insufficient disk headroom for specialization")
    let started = Date()
    try AIModelCache.default.deleteEntry(for: url, options: options)
    let deletionSeconds = Date().timeIntervalSince(started)
    let before = try snapshot("before-specialize")
    budget[budgetKey, default: 0] += 1
    try JSONEncoder().encode(budget).write(to: budgetURL, options: .atomic)
    let specializeStarted = Date()
    do {
        let model = try await AIModel.specialize(contentsOf: url, options: options, cachePolicy: .persistent)
        let seconds = Date().timeIntervalSince(specializeStarted)
        let after = try snapshot("after-specialize")
        withExtendedLifetime(model) {}
        return ["passed": true, "asset": url.deletingPathExtension().lastPathComponent, "deletions": 1, "specializations": 1,
                "delete_s": deletionSeconds, "specialize_s": seconds, "cache_before": before, "cache_after": after]
    } catch {
        _ = try? snapshot("specialize-failed")
        throw error
    }
}

@available(macOS 27, *)
func probeCache(_ config: Configuration, role: TextRole) async throws -> [String: Any] {
    let asset = role == .query ? "text-query" : "text-doc"
    let names = role == .query ? ["q32", "q64", "q128"] : ["d256", "d512", "d1024", "d2048"]
    let url = URL(fileURLWithPath: config.assets).appendingPathComponent(asset + ".aimodel")
    let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    let started = Date()
    var stage = "cache-lookup"
    var function = ""
    var records: [[String: Any]] = []
    var result: [String: Any] = ["asset": asset, "url": url.path, "recovery_enabled": false,
                               "probe_version": "round3-v2", "specializations": 0, "deletions": 0]
    do {
        // A diagnostic must not turn a miss or a stale entry into a specialization.
        guard let model = try AIModelCache.default.model(for: url, options: options) else {
            return result.merging(["passed": false, "status": "no-entry", "stage": stage,
                                   "elapsed_s": Date().timeIntervalSince(started)]) { $1 }
        }
        result["lookup_s"] = Date().timeIntervalSince(started)
        let host = try config.host()
        let cases = try load([HostCase].self, config.scratchURL.appendingPathComponent("host-cases.json"))
        for name in names {
            function = name
            stage = "load-function"
            let loadStarted = Date()
            guard let fn = try model.loadFunction(named: name) else { throw CheckError("missing function \(name)") }
            let loadSeconds = Date().timeIntervalSince(loadStarted)
            stage = "inference"
            guard let fixture = cases.first(where: { $0.function == name }) else { throw CheckError("no fixture for \(name)") }
            let tensors = try host.prepare(fixture.ids, bucket: fixture.bucket)
            var arrays: [String: NDArray] = [:]
            for (input, tensor) in tensors {
                guard case .ndArray(let descriptor) = fn.descriptor.inputDescriptor(of: input),
                      descriptor.scalarType == .float16, descriptor.shape == tensor.shape else {
                    throw CheckError("input descriptor mismatch: \(input)")
                }
                var array = NDArray(shape: tensor.shape, scalarType: .float16)
                array.mutableView(as: Float16.self).withUnsafeMutablePointer { pointer, _, _ in
                    pointer.withMemoryRebound(to: UInt16.self, capacity: tensor.bits.count) { bits in
                        tensor.bits.withUnsafeBufferPointer { bits.update(from: $0.baseAddress!, count: $0.count) }
                    }
                }
                arrays[input] = array
            }
            let inferenceStarted = Date()
            var outputs = try await fn.run(inputs: arrays)
            let inferenceSeconds = Date().timeIntervalSince(inferenceStarted)
            guard let output = outputs.remove("y")?.ndArray,
                  output.shape == [1, 768], output.scalarType == .float16 else { throw CheckError("invalid output") }
            let raw = output.view(as: Float16.self).withUnsafePointer { pointer, _, strides in
                (0..<768).map { pointer[$0 * strides[1]].bitPattern }
            }
            _ = try TextHostPrep.finalize(raw)
            let actual = raw.withUnsafeBytes { Data($0) }
            try require(actual == Data(contentsOf: URL(fileURLWithPath: fixture.output)), "probe output bytes differ: \(name)")
            records.append(["function": name, "load_s": loadSeconds, "inference_s": inferenceSeconds,
                            "byte_identical": true, "fixture": fixture.id])
        }
        result.merge(["passed": true, "status": "ok"]) { $1 }
    } catch {
        result.merge(["passed": false, "status": "failed", "stage": stage,
                      "failing_function": function, "error": String(describing: error)]) { $1 }
    }
    result["functions"] = records
    result["elapsed_s"] = Date().timeIntervalSince(started)
    return result
}
