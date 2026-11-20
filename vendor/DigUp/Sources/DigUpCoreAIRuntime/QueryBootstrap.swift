import CoreAI
import CryptoKit
import Darwin
import DigUpKit
import Foundation

struct ModelSetupPending: Error {}

@available(macOS 27, *)
enum QueryBootstrap {
    static let recipeName = "bootstrap-q32.json"
    static let recipeSHA256 = "6c0c3d6be14117f4ce1d83b7483446283580022ecd30b02c51d44be4b19b4153"

    struct Recipe: Decodable {
        struct File: Decodable {
            struct Segment: Decodable { let literal: String?; let offset: Int?; let bytes: Int? }
            let bytes: Int
            let sha256: String
            let segments: [Segment]
        }
        let format: String
        let source_sha256: String
        let source_bytes: Int
        let function: String
        let files: [String: File]
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func setupDirectory(_ assets: CoreAIAssets) throws -> URL {
        let hash = digest(try Data(contentsOf: assets.manifest))
        return assets.directory.deletingLastPathComponent().appendingPathComponent(".coreai-setup").appendingPathComponent(hash)
    }

    static func ready(_ assets: CoreAIAssets) -> Bool {
        generation(assets) != nil
    }

    static func generation(_ assets: CoreAIAssets) -> String? {
        guard let folder = try? setupDirectory(assets),
              let data = try? Data(contentsOf: folder.appendingPathComponent("ready.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              record["namespace"] == RuntimeCacheIdentity.namespace,
              RuntimeCacheIdentity.matchesCurrentOS(build: record["os_build"], legacyVersion: record["os_version"]) else { return nil }
        return record["generation"] ?? "legacy"
    }

    static func markReady(_ assets: CoreAIAssets, replaceGeneration: Bool = false) throws {
        let existing = replaceGeneration ? nil : generation(assets)
        let folder = try setupDirectory(assets)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = ["namespace": RuntimeCacheIdentity.namespace, "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                      "os_build": RuntimeCacheIdentity.osBuild, "generation": existing ?? UUID().uuidString]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("ready.json"), options: .atomic)
    }

    static func invalidate(_ assets: CoreAIAssets) {
        if let folder = try? setupDirectory(assets) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("ready.json"))
        }
    }

    static func materializeRecipe(_ recipe: Recipe, source: URL, destination: URL) throws {
        guard recipe.format == "swiftlight-bootstrap-ranges-1", recipe.function == "q32", recipe.source_bytes > 0,
              recipe.files.values.allSatisfy({ $0.bytes > 0 }),
              Set(recipe.files.keys) == ["main.hash", "main.mlirb", "metadata.json"] else {
            throw WorkerError.failed("invalid query bootstrap recipe")
        }
        try writeFiles(source: source, bytes: recipe.source_bytes, sha256: recipe.source_sha256, files: recipe.files, destination: destination)
    }

    static func writeFiles(source: URL, bytes: Int, sha256: String, files: [String: Recipe.File], destination: URL) throws {
        guard bytes > 0, Set(files.keys) == ["main.hash", "main.mlirb", "metadata.json"],
              files.values.allSatisfy({ $0.bytes > 0 }), !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkerError.failed("invalid model reconstruction destination or files")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.seekToEnd() == UInt64(bytes) else { throw WorkerError.failed("model reconstruction source size mismatch") }
        try input.seek(toOffset: 0)
        var sourceHash = SHA256()
        while try autoreleasepool(invoking: {
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            sourceHash.update(data: chunk)
            return true
        }) {}
        guard sourceHash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw WorkerError.failed("model reconstruction source SHA-256 mismatch")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, file) in files {
            let path = destination.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw WorkerError.failed("cannot create query bootstrap file") }
            let output = try FileHandle(forWritingTo: path)
            defer { try? output.close() }
            var hash = SHA256(), written = 0
            func write(_ bytes: Data) throws {
                guard written <= file.bytes, bytes.count <= file.bytes-written else { throw WorkerError.failed("query bootstrap file exceeds pin") }
                try output.write(contentsOf: bytes)
                hash.update(data: bytes); written += bytes.count
            }
            for segment in file.segments {
                if let literal = segment.literal {
                    guard segment.offset == nil, segment.bytes == nil, let data = Data(base64Encoded: literal) else { throw WorkerError.failed("invalid query bootstrap literal") }
                    try write(data)
                } else {
                    guard let offset = segment.offset, let count = segment.bytes, offset >= 0, count > 0,
                          offset <= bytes, count <= bytes-offset else { throw WorkerError.failed("invalid model reconstruction range") }
                    try input.seek(toOffset: UInt64(offset))
                    var remaining = count
                    while remaining > 0 {
                        try autoreleasepool {
                            guard let chunk = try input.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { throw WorkerError.failed("truncated setup group source") }
                            try write(chunk); remaining -= chunk.count
                        }
                    }
                }
            }
            guard written == file.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw WorkerError.failed("query bootstrap output SHA-256 mismatch")
            }
            try output.synchronize()
        }
    }


}

@available(macOS 27, *)
extension RuntimeDirectory {
    public static func materializeSetupQuery(source: URL, recipe: URL, destination: URL) throws {
        let data = try Data(contentsOf: recipe)
        guard QueryBootstrap.digest(data) == QueryBootstrap.recipeSHA256 else {
            throw WorkerError.failed("query bootstrap recipe SHA-256 mismatch")
        }
        try QueryBootstrap.materializeRecipe(JSONDecoder().decode(QueryBootstrap.Recipe.self, from: data), source: source, destination: destination)
    }
}
