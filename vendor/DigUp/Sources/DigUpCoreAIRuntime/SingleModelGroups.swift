import CoreAI
import CryptoKit
import Darwin
import DigUpKit
import Foundation

@available(macOS 27, *)
enum SingleModelGroups {
    static let functions: [String: [String]] = [
        "query3": ["q32", "q64", "q128"],
        "doc4": ["d256", "d512", "d1024", "d2048"],
        "vision3": ["v630", "v1260", "v2520"],
        "audio1": ["a3000"],
    ]
    static let order = ["query3", "doc4", "vision3", "audio1"]
    static let recipeHashes: [String: String] = [
        "query3": "ca641a217029b5932bdaf576564502b18002f89e50f62110e55696bbf69e56a9",
        "doc4": "a2be7969407e8bd4121b604aeb00195edeafb8d570a9ef1cfe5ad390af893043",
        "vision3": "1ba8680bdd520d6971333af9392398f58de09f32abce5ee5746912ec895a671b",
        "audio1": "52013191d8894aee4b00721234654b0394eab6ce67f566971a73250fb573b553",
    ]

    struct Recipe: Decodable {
        let format: String
        let source_sha256: String
        let source_bytes: Int
        let functions: [String]
        let files: [String: QueryBootstrap.Recipe.File]
    }
    struct Record: Codable {
        let namespace: String
        let osBuild: String
        let architecture: String
        let group: String
        let generation: String
        let bookmark: Data
        let sourceHash: String
    }

    static func group(for function: String) throws -> String {
        guard let group = order.first(where: { functions[$0]!.contains(function) }) else {
            throw WorkerError.failed("unknown single model function: \(function)")
        }
        return group
    }

    static func recordURL(_ assets: CoreAIAssets, group: String) throws -> URL {
        try QueryBootstrap.setupDirectory(assets).appendingPathComponent(group + ".json")
    }

    static func read(_ assets: CoreAIAssets, group: String) throws -> Record? {
        guard let data = try? Data(contentsOf: recordURL(assets, group: group)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.namespace == RuntimeCacheIdentity.namespace, record.osBuild == RuntimeCacheIdentity.osBuild,
              record.architecture == AIModel.deviceArchitectureName, record.group == group else { return nil }
        return record
    }

    static func model(_ assets: CoreAIAssets, group: String) throws -> AIModel? {
        guard let record = try read(assets, group: group) else { return nil }
        return try AIModel(resolvingBookmark: record.bookmark)
    }

    static func materialize(_ assets: CoreAIAssets, group: String, destination: URL) throws -> String {
        guard let expected = recipeHashes[group] else { throw WorkerError.failed("unknown setup group") }
        let data = try Data(contentsOf: assets.directory.appendingPathComponent("group-" + group + ".json"))
        guard QueryBootstrap.digest(data) == expected else { throw WorkerError.failed("setup group recipe SHA-256 mismatch") }
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        guard recipe.format == "swiftlight-group-ranges-1", recipe.functions == functions[group] else {
            throw WorkerError.failed("setup group function set mismatch")
        }
        try QueryBootstrap.writeFiles(source: assets.directory.appendingPathComponent(SingleModelSemanticIdentity.asset + "/main.mlirb"),
            bytes: recipe.source_bytes, sha256: recipe.source_sha256, files: recipe.files, destination: destination)
        return try renewCompilerIdentity(destination)
    }

    /// MLIR's NUL-terminated producer label is diagnostic metadata. All IR and resource bytes stay unchanged.
    /// A fresh source hash bypasses a broken upper cache hit without deleting its tracked ANE program.
    static func renewCompilerIdentity(_ source: URL) throws -> String {
        let path = source.appendingPathComponent("main.mlirb")
        let file = try FileHandle(forUpdating: path)
        defer { try? file.close() }
        let header = try file.read(upToCount: 128) ?? Data()
        let prefix = Data([0x4d, 0x4c, 0xef, 0x52, 0x0d])
        guard header.starts(with: prefix), let end = header.dropFirst(5).firstIndex(of: 0), end > 5 else {
            throw WorkerError.failed("unsupported MLIR producer header; source retained")
        }
        let label = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(end - 5)
        guard label.utf8.count == end - 5 else { throw WorkerError.failed("invalid compiler identity label") }
        try file.seek(toOffset: 5)
        try file.write(contentsOf: Data(label.utf8))
        try file.synchronize()
        let hash = try SourceRecovery.fileHash(path)
        let bytes = stride(from: 0, to: hash.count, by: 2).map { offset -> UInt8 in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            return UInt8(hash[start..<hash.index(start, offsetBy: 2)], radix: 16)!
        }
        try Data(bytes).write(to: source.appendingPathComponent("main.hash"), options: .atomic)
        return hash
    }

    static func stubResources(bookmark: Data, sourceHash: String) throws {
        let object = try JSONSerialization.jsonObject(with: bookmark) as? [String: Any]
        guard let entry = object?["entryIdentifier"] as? [String: String],
              entry["modelHash"] == sourceHash, sourceHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let options = entry["optionsHash"], options.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            throw WorkerError.failed("unsupported Core AI bookmark storage layout; source retained")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/coreai-cache")
            .appendingPathComponent(RuntimeCacheIdentity.osBuild).appendingPathComponent(RuntimeCacheIdentity.namespace)
            .appendingPathComponent(sourceHash).appendingPathComponent(options)
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw WorkerError.failed("compiled group entry is unavailable")
        }
        var count = 0
        for case let path as URL in iterator {
            if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw WorkerError.failed("symlink in compiled group entry")
            }
            if path.lastPathComponent != "resources.bin" { continue }
            var info = stat()
            guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw WorkerError.failed("invalid compiled resource file") }
            let next = path.deletingLastPathComponent().appendingPathComponent("swiftlight-stub-" + UUID().uuidString)
            let fd = open(next.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw WorkerError.failed("cannot create sparse resource stub") }
            defer { Darwin.close(fd); try? FileManager.default.removeItem(at: next) }
            guard ftruncate(fd, info.st_size) == 0, fsync(fd) == 0, rename(next.path, path.path) == 0 else {
                throw WorkerError.failed("cannot publish sparse resource stub")
            }
            count += 1
        }
        guard count > 0 else { throw WorkerError.failed("compiled resource file not found") }
    }
}

@available(macOS 27, *)
extension SingleModelGroups {
    static func check(_ model: AIModel, group: String, directory: URL) async throws -> [String: String] {
        let hosts = RuntimeDirectory.HostResourcePaths(directory: directory, compact: true)
        let resources = try SharedHostResources.acquire(tokenizer: hosts.tokenizer, table: hosts.tokenTable, rope: hosts.ropeTables)
        var digests: [String: String] = [:]
        for name in functions[group]! {
            guard let function = try model.loadFunction(named: name) else { throw WorkerError.failed("setup function missing: \(name)") }
            let inputs: [String: HostTensor]
            if name == "a3000" {
                inputs = try resources.withAudio { audio, _ in try audio.prepare(audio.mel(Array(repeating: 0, count: 16000))) }
            } else if name.hasPrefix("v") {
                let image = try RGBImage(width: 48, height: 48, pixels: Array(repeating: 127, count: 48*48*3))
                inputs = try resources.withVision { vision, _ in try vision.prepare(image, budget: Int(name.dropFirst())!/9).inputs }
            } else {
                inputs = try resources.withText { _, host in try host.prepare([2,1], bucket: Int(name.dropFirst())!) }
            }
            var arrays: [String: NDArray] = [:]
            for (key, tensor) in inputs {
                guard case .ndArray(let descriptor) = function.descriptor.inputDescriptor(of: key),
                      descriptor.shape == tensor.shape, descriptor.scalarType == .float16 else { throw WorkerError.failed("setup input descriptor mismatch") }
                var array = NDArray(shape: tensor.shape, scalarType: .float16)
                array.mutableView(as: Float16.self).withUnsafeMutablePointer { pointer, _, _ in
                    tensor.bits.withUnsafeBytes { UnsafeMutableRawPointer(pointer).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                }
                arrays[key] = array
            }
            // Setup verification must finish even when an open panel is waiting for query readiness.
            let dispatch = try await Task.detached { try InferencePriority(directory: directory, query: true) }.value
            defer { withExtendedLifetime(dispatch) {} }
            var outputs = try await function.run(inputs: arrays)
            guard let output = outputs.remove("y")?.ndArray, output.scalarType == .float16 else { throw WorkerError.failed("setup FP16 output missing") }
            let shape = output.shape
            let bits: [UInt16] = output.view(as: Float16.self).withUnsafePointer { pointer, _, strides in
                (0..<shape.reduce(1, *)).map { index in
                    var remainder = index, offset = 0
                    for axis in shape.indices.reversed() { offset += (remainder % shape[axis])*strides[axis]; remainder /= shape[axis] }
                    return pointer[offset].bitPattern
                }
            }
            guard !bits.isEmpty, bits.allSatisfy({ Float16(bitPattern: $0).isFinite }) else { throw WorkerError.failed("nonfinite setup output: \(name)") }
            digests[name] = bits.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        return digests
    }
}
