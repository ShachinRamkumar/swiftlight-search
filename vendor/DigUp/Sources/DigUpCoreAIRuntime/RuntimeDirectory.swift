import CryptoKit
import Darwin
import DigUpKit
import Foundation

@available(macOS 27, *)
public struct RuntimeDirectory: Sendable {
    public static let modelKey = "coreai-eg2-text-v1"
    public let modelKey: String
    public let directory: URL
    public let assets: CoreAIAssets
    public let weightsSHA256: String

    private struct Manifest: Decodable {
        struct Checkpoint: Decodable { let model: String; let revision: String; let sha256: String }
        let verification_only: Bool?
        let storage_layout: String?
        let model_key: String
        let checkpoint: Checkpoint
        let files: [String: String]
    }
    private struct FileIdentity: Codable, Equatable {
        let size: Int64
        let st_mtime_ns: Int64
        let st_ino: UInt64
    }
    private struct Fingerprint: Codable {
        let manifest_sha256: String
        let files: [String: FileIdentity]
    }

    public init(_ directory: URL, fullVerify: Bool = false) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        _ = try Self.identity("manifest.json", in: directory)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.verification_only != true else { throw WorkerError.failed("verification-only runtime is restricted to the research verifier") }
        guard [Self.modelKey, "coreai-eg2-v1"].contains(manifest.model_key), manifest.checkpoint.model == "google/embeddinggemma-2",
              manifest.checkpoint.revision == "914f7f8",
              manifest.checkpoint.sha256 == "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79" else {
            throw WorkerError.failed("runtime manifest checkpoint/model identity mismatch: manifest.json")
        }
        let single = manifest.storage_layout == SingleModelSemanticIdentity.layout
        let sourceAbsent = try single && SourceRecovery.acceptsAbsentSource(directory: directory, manifest: manifestData)
        let presentFiles = manifest.files.filter { !sourceAbsent || !$0.key.hasPrefix(SingleModelSemanticIdentity.asset + "/") }
        let compact = single || manifest.storage_layout == "option-a-v1"
        let required = compact ? ["token-table.slht", "tokenizer.json.zst", "tokenizer_config.json", "rope-tables/sha256.json", "host-tables.json"]
            : ["token-table.bf16", "tokenizer.json", "tokenizer_config.json", "rope-tables/sha256.json"]
        guard required.allSatisfy({ manifest.files[$0] != nil }),
              (single ? [SingleModelSemanticIdentity.asset + "/"] : compact ? ["text.aimodel/"] : ["text-query.aimodel/", "text-doc.aimodel/"]).allSatisfy({ prefix in manifest.files.keys.contains { $0.hasPrefix(prefix) } }) else {
            throw WorkerError.failed("runtime manifest missing required file entries: manifest.json")
        }
        if manifest.model_key == "coreai-eg2-v1" {
            guard (compact ? ["position-table-840.bf16", "cos-841.f32", "sin-841.f32", "identity.json"] : ["position-table.bf16", "cos.f32", "sin.f32", "identity.json"]).allSatisfy({ manifest.files["vision-host/"+$0] != nil }),
                  manifest.files.keys.contains(where: { $0.hasPrefix(single ? SingleModelSemanticIdentity.asset + "/" : "vision.aimodel/") }) else {
                throw WorkerError.failed("runtime manifest missing vision files")
            }
        }
        var identities: [String: FileIdentity] = [:]
        for name in presentFiles.keys.sorted() { identities[name] = try Self.identity(name, in: directory) }
        RuntimeDiagnostics.mark("b_manifest_checks_without_hashing")
        let fingerprintURL = directory.appendingPathComponent("fingerprint.json")
        let fingerprint: Fingerprint? = try? {
            _ = try Self.identity("fingerprint.json", in: directory)
            return try JSONDecoder().decode(Fingerprint.self, from: Data(contentsOf: fingerprintURL))
        }()
        let manifestHash = Self.digest(manifestData)
        let receiptDirectory = directory.deletingLastPathComponent().appendingPathComponent(".coreai-verification")
        let receiptURL = receiptDirectory.appendingPathComponent(Self.digest(Data(directory.standardizedFileURL.path.utf8)) + ".json")
        let receipt = try? JSONDecoder().decode(Fingerprint.self, from: Data(contentsOf: receiptURL))
        let matches = [fingerprint, receipt].contains { $0?.files == identities && $0?.manifest_sha256 == manifestHash }
        if fullVerify || !matches {
            try Self.verifyContents(presentFiles, in: directory)
            var verified: [String: FileIdentity] = [:]
            for name in presentFiles.keys { verified[name] = try Self.identity(name, in: directory) }
            guard verified == identities else { throw WorkerError.failed("runtime changed during verification") }
            // Keep verified identities outside the immutable runtime, including after a safe inode replacement.
            do {
                try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(Fingerprint(manifest_sha256: manifestHash, files: verified)).write(to: receiptURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("[coreai-runtime] verification receipt write failed: \(error)\n".utf8))
            }
            if !fullVerify {
                FileHandle.standardError.write(Data("[coreai-runtime] fingerprint stale or unavailable; full verification passed\n".utf8))
            }
        } else {
            Self.verificationLog(mode: "fingerprint", files: 0, bytes: 0)
        }
        RuntimeDiagnostics.mark("c_after_hashing")
        self.directory = directory
        modelKey = manifest.model_key
        weightsSHA256 = manifest.checkpoint.sha256
        assets = try CoreAIAssets(directory: directory, manifest: manifestURL)
        var expectedAssets: Set<String> = single ? [SingleModelSemanticIdentity.asset] : compact ? ["text.aimodel", "vision.aimodel"] : manifest.model_key == Self.modelKey
            ? ["text-query.aimodel","text-doc.aimodel"] : ["text-query.aimodel","text-doc.aimodel","vision.aimodel"]
        if single || manifest.files.keys.contains(where: { $0.hasPrefix("audio.aimodel/") }) {
            guard ["window.f32", "mel-bank.f32", "mel-bank.f64", "positions.f32", "identity.json"].allSatisfy({ manifest.files["audio-host/"+$0] != nil }) else {
                throw WorkerError.failed("runtime manifest missing audio host files")
            }
            if !single { expectedAssets.insert("audio.aimodel") }
        }
        guard assets.names == expectedAssets else { throw WorkerError.failed("runtime asset set/model-key mismatch") }
        for relative in assets.functionAssets.values {
            guard manifest.files[relative + "/main.mlirb"] != nil,
                  manifest.files[relative + "/main.hash"] != nil,
                  manifest.files[relative + "/metadata.json"] != nil else {
                throw WorkerError.failed("function asset is not bound by the runtime manifest: \(relative)")
            }
        }
        try CompilerTemporaryFiles.cleanup(directory: directory)
        RuntimeDiagnostics.mark("d_after_CoreAIAssets")
    }

    public struct HostResourcePaths: Sendable {
        public let tokenizer: URL
        public let tokenTable: URL
        public let ropeTables: URL

        public init(directory: URL, compact: Bool) {
            tokenizer = directory.appendingPathComponent(compact ? "tokenizer.json.zst" : "tokenizer.json")
            tokenTable = directory.appendingPathComponent(compact ? "token-table.slht" : "token-table.bf16")
            ropeTables = directory.appendingPathComponent("rope-tables")
        }

        public func acquire() throws -> SharedHostResources {
            try SharedHostResources.acquire(tokenizer: tokenizer, table: tokenTable, rope: ropeTables)
        }
    }

    public var hostResourcePaths: HostResourcePaths {
        HostResourcePaths(directory: directory, compact: assets.names.contains("text.aimodel") || assets.names.contains(SingleModelSemanticIdentity.asset))
    }

    public func hostResources() throws -> SharedHostResources { try hostResourcePaths.acquire() }

    // This is also the exact guard used by the engine before any recovery cache mutation.
    // P2's reference manifest stores per-file digests inside production_assets; installed
    // runtimes store them at the top level. Both bind the existing production sources.
    public static func verifyAssetForRecovery(_ url: URL, manifest manifestURL: URL) throws {
        struct RecoveryManifest: Decodable {
            struct Asset: Decodable {
                struct File: Decodable { let path: String; let sha256: String }
                let path: String
                let files: [File]?
            }
            let files: [String: String]?
            let production_assets: [Asset]
        }
        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let path = url.standardizedFileURL.path
        let withinRuntime = path.hasPrefix(root.path + "/")
        let relative = withinRuntime ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
        let functions: Set<String> = ["q32","q64","q128","d256","d512","d1024","d2048","v630","v1260","v2520","a3000","query-rest","vision-rest"]
        let split = relative.hasPrefix("function-assets/") && functions.contains(url.deletingPathExtension().lastPathComponent)
            && relative == "function-assets/" + url.lastPathComponent
        guard ["EmbeddingGemma2.aimodel", "text.aimodel", "text-query.aimodel", "text-doc.aimodel", "vision.aimodel", "audio.aimodel"].contains(relative) || split else {
            throw WorkerError.failed("unexpected recovery asset: \(url.path)")
        }
        _ = try identity(manifestURL.lastPathComponent, in: manifestURL.deletingLastPathComponent())
        let manifest = try JSONDecoder().decode(RecoveryManifest.self, from: Data(contentsOf: manifestURL))
        let prefix = relative + "/"
        let files: [String: String]
        if let installed = manifest.files {
            guard withinRuntime else { throw WorkerError.failed("recovery asset outside runtime") }
            files = installed.filter { $0.key.hasPrefix(prefix) }
        } else {
            guard let asset = manifest.production_assets.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == url.lastPathComponent }),
                  let entries = asset.files else { throw WorkerError.failed("runtime manifest missing recovery files: \(url.lastPathComponent)") }
            files = Dictionary(uniqueKeysWithValues: entries.map { (prefix + $0.path, $0.sha256) })
        }
        guard !files.isEmpty else { throw WorkerError.failed("runtime manifest missing recovery files: \(url.lastPathComponent)") }
        try verifyContents(files, in: manifest.files == nil ? url.deletingLastPathComponent() : root)
    }

    private static func identity(_ name: String, in directory: URL) throws -> FileIdentity {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }), !name.utf8.contains(0) else {
            throw WorkerError.failed("invalid runtime manifest path: \(name)")
        }
        var url = directory
        var info = stat()
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == (index == parts.count - 1 ? S_IFREG : S_IFDIR) else {
                throw WorkerError.failed("runtime file missing or not regular: \(name)")
            }
        }
        return FileIdentity(size: info.st_size,
            st_mtime_ns: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            st_ino: info.st_ino)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyContents(_ files: [String: String], in directory: URL) throws {
        var total: UInt64 = 0
        for name in files.keys.sorted() {
            _ = try identity(name, in: directory)
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name)) }
            catch { throw WorkerError.failed("runtime file unreadable: \(name): \(error)") }
            defer { try? handle.close() }
            var hash = SHA256()
            while try autoreleasepool(invoking: {
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
                hash.update(data: data)
                total += UInt64(data.count)
                if ProcessInfo.processInfo.environment["DIGUP_VERIFY_CHUNK_DIAGNOSTICS"] == "1" {
                    RuntimeDiagnostics.mark("verification_chunk")
                }
                return true
            }) {}
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == files[name] else { throw WorkerError.failed("runtime SHA-256 mismatch: \(name)") }
        }
        verificationLog(mode: "full", files: files.count, bytes: total)
    }

    private static func verificationLog(mode: String, files: Int, bytes: UInt64) {
        guard ProcessInfo.processInfo.environment["DIGUP_RUNTIME_DIAGNOSTICS"] == "1" else { return }
        FileHandle.standardError.write(Data("RUNTIME_VERIFY mode=\(mode) content_files_hashed=\(files) content_bytes_hashed=\(bytes)\n".utf8))
    }

    public func embedder(_ role: TextRole, prepareQueryFirst: Bool = false,
                         inferenceGate: (@Sendable () throws -> Void)? = nil,
                         specializationObserver: (@Sendable (URL, SpecializationPhase) throws -> Void)? = nil) throws -> CoreAIEmbedder {
        try RuntimeCacheIdentity.requireCacheOwner()
        let hosts = hostResourcePaths
        return try CoreAIEmbedder(role: role, assets: assets, prepareQueryFirst: prepareQueryFirst,
            tokenizer: hosts.tokenizer, tokenTable: hosts.tokenTable, ropeTables: hosts.ropeTables, inferenceGate: inferenceGate, specializationObserver: specializationObserver)
    }
}
