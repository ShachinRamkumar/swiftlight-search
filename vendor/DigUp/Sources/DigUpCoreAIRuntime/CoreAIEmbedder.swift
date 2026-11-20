import CoreAI
import CryptoKit
import DigUpKit
import Foundation

@available(macOS 27, *)
public enum SpecializationPhase: Sendable { case begin, success, failure }

@available(macOS 27, *)
public struct CoreAIAssets: Sendable {
    public let directory: URL
    public static let optionASemanticRevision = "c004e85fc60e610d69de5684ae30f5e80bf091aa11ff59ad9257ed63e3ae4799"
    public let revision: String
    public let audioRevision: String?
    public let videoRevision: String?
    public let manifest: URL
    public let names: Set<String>
    public let functionAssets: [String: String]

    public init(directory: URL, manifest: URL) throws {
        try self.init(directory: directory, manifest: manifest, approvedMergedTextSHA256: OptionASemanticIdentity.approvedMergedTextPackageSHA256)
    }

    init(directory: URL, manifest: URL, approvedMergedTextSHA256: String?, approvedSingleModelSHA256: String? = SingleModelSemanticIdentity.approvedPackageSHA256) throws {
        struct Manifest: Decodable {
            struct Asset: Decodable { let path: String; let sha256: String }
            struct Checkpoint: Decodable { let sha256: String }
            struct Vision: Decodable {
                struct Host: Decodable { let host_sha256: String; let spec_sha256: String; let files: [String:String] }
                let asset_sha256: String
                let stage_b_manifest_sha256: String
                let host: Host
            }
            let verification_only: Bool?
            let storage_layout: String?
            let semantic_revision: String?
            let production_assets: [Asset]
            let checkpoint: Checkpoint
            let vision_identity: Vision?
            let audio_identity: Vision?
            let video_identity: String?
            let function_assets: [String: String]?
        }
        let data = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        guard data.verification_only != true else { throw WorkerError.failed("verification-only runtime cannot register production vectors") }
        let names = Set(data.production_assets.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let single = names.contains(SingleModelSemanticIdentity.asset)
        let merged = names.contains("text.aimodel")
        guard names.count == data.production_assets.count,
              (single ? Set([SingleModelSemanticIdentity.asset]) : merged ? Set(["text.aimodel", "vision.aimodel"]) : Set(["text-query.aimodel", "text-doc.aimodel"])).isSubset(of: names),
              names.isSubset(of: [SingleModelSemanticIdentity.asset, "text.aimodel", "text-query.aimodel", "text-doc.aimodel", "vision.aimodel", "audio.aimodel"]) else {
            throw WorkerError.failed("expected P2 query and document manifest entries")
        }
        if single {
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            try SingleModelSemanticIdentity.validate(record, approved: approvedSingleModelSHA256)
            guard names == [SingleModelSemanticIdentity.asset], (data.function_assets ?? [:]).isEmpty else {
                throw WorkerError.failed("single model runtime must contain exactly one model and no function partitions")
            }
        }
        if merged {
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            try OptionASemanticIdentity.validate(record, approvedTextSHA256: approvedMergedTextSHA256)
            guard data.storage_layout == "option-a-v1", data.semantic_revision == Self.optionASemanticRevision,
                  data.checkpoint.sha256 == "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79",
                  !names.contains("text-query.aimodel"), !names.contains("text-doc.aimodel"),
                  (data.function_assets ?? [:]).isEmpty else { throw WorkerError.failed("invalid option A semantic identity/layout") }
        }
        functionAssets = data.function_assets ?? [:]
        let functions: Set<String> = ["q32","q64","q128","d256","d512","d1024","d2048","v630","v1260","v2520","a3000"]
        guard functionAssets.allSatisfy({ functions.contains($0.key) &&
            ($0.value == "function-assets/" + $0.key + ".aimodel"
             || (["q64", "q128"].contains($0.key) && $0.value == "function-assets/query-rest.aimodel")
             || (["v630", "v2520"].contains($0.key) && $0.value == "function-assets/vision-rest.aimodel")) }) else {
            throw WorkerError.failed("invalid function asset mapping")
        }
        self.directory = directory
        self.names = names
        self.manifest = manifest
        var components = [data.checkpoint.sha256] + data.production_assets.filter { !$0.path.hasSuffix("audio.aimodel") }.map(\.sha256).sorted()
            + ["p3a-bf16-fp32scale-shipped-rope-v1"]
        if single || names.contains("vision.aimodel") {
            guard let vision=data.vision_identity else { throw WorkerError.failed("missing vision host identity") }
            components += [vision.asset_sha256,vision.stage_b_manifest_sha256,vision.host.host_sha256,vision.host.spec_sha256]
            for name in vision.host.files.keys.sorted() { components += [name,vision.host.files[name]!] }
        }
        if single || names.contains("audio.aimodel") {
            guard let audio = data.audio_identity else { throw WorkerError.failed("missing audio host identity") }
            let audioParts = [audio.asset_sha256, audio.stage_b_manifest_sha256, audio.host.host_sha256, audio.host.spec_sha256]
                + audio.host.files.keys.sorted().flatMap { [$0, audio.host.files[$0]!] }
            audioRevision = SHA256.hash(data: Data(audioParts.joined(separator: ":").utf8)).map { String(format: "%02x", $0) }.joined()
        } else { audioRevision = nil }
        videoRevision = data.video_identity
        let identity = components.joined(separator: ":")
        revision = (single || merged) ? Self.optionASemanticRevision : SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func sourceAsset(for name: String) throws -> String {
        guard Set(["q32","q64","q128","d256","d512","d1024","d2048","v630","v1260","v2520","a3000"]).contains(name) else {
            throw WorkerError.failed("unknown model function: \(name)")
        }
        if names.contains(SingleModelSemanticIdentity.asset) {
            return SingleModelSemanticIdentity.asset
        }
        let logical = name.hasPrefix("a") ? "audio.aimodel" : name.hasPrefix("v") ? "vision.aimodel" :
            names.contains("text.aimodel") ? "text.aimodel" : name.hasPrefix("q") ? "text-query.aimodel" : "text-doc.aimodel"
        guard names.contains(logical) else { throw WorkerError.failed("runtime has no asset: \(logical)") }
        return functionAssets[name] ?? logical
    }

}

@available(macOS 27, *)
private final class BlockingResult<T: Sendable>: @unchecked Sendable {
    var value: Result<T, Error>?
}

@available(macOS 27, *)
func coreAIBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    guard !Thread.isMainThread else { throw WorkerError.failed("CoreAIEmbedder requires a dedicated worker thread") }
    let box = BlockingResult<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await operation()) }
        catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

@available(macOS 27, *)
func prepareQueryResources<Host>(host: () throws -> Host,
    functions: @escaping @Sendable () async throws -> TimeInterval) throws -> (Host, TimeInterval) {
    let priming = Task.detached(priority: .userInitiated, operation: functions)
    do {
        let resources = try host()
        return (resources, try coreAIBlocking { try await priming.value })
    } catch {
        _ = try? coreAIBlocking { try await priming.value }
        throw error
    }
}

@available(macOS 27, *)
private actor CoreAIEngine {
    private struct MissingSpecialization: Error, CustomStringConvertible {
        let description = "no cached specialization"
    }
    private struct Slot {
        let model: AIModel
        var functions: [String: InferenceFunction] = [:]
    }
    private let assets: CoreAIAssets
    private let queryOnly: Bool
    private let log: URL?
    private let inferenceGate: (@Sendable () throws -> Void)?
    private let specializationObserver: (@Sendable (URL, SpecializationPhase) throws -> Void)?
    private var slots: [String: Slot] = [:]
    private var preparingFullModel = false
    private var fullModelRetry = ModelPreparationRetry()
    private var injectedFailures = 0
    private var idleGeneration: [String:UInt64] = [:]
    private var lastMediaUse: [String:TimeInterval] = [:]
    private func releaseMedia(_ asset: String, generation: UInt64) {
        guard generation == idleGeneration[asset] else { return }
        slots.removeValue(forKey: asset)
        line("\(asset) released after 30 s idle")
    }

    init(assets: CoreAIAssets, queryOnly: Bool, log: URL?, inferenceGate: (@Sendable () throws -> Void)?, specializationObserver: (@Sendable (URL, SpecializationPhase) throws -> Void)?) {
        self.assets = assets; self.queryOnly = queryOnly; self.log = log ?? RuntimeReadiness.logURL; self.inferenceGate = inferenceGate; self.specializationObserver = specializationObserver
    }
    func injectLoadFailures(_ count: Int) { injectedFailures = count }
    func close() { autoreleasepool { slots.removeAll() } }
    func singleModelBookmark() throws -> Data {
        guard let record = try SingleModelGroups.read(assets, group: "query3") else {
            throw WorkerError.failed("query group is not ready")
        }
        return record.bookmark
    }
    private func releaseAfterInference(_ name: String) {
        guard assets.names == [SingleModelSemanticIdentity.asset], let group = try? SingleModelGroups.group(for: name) else { return }
        if group != "query3" || !queryOnly { autoreleasepool { slots = slots.filter { !$0.key.hasPrefix(group + "-") } } }
    }

    func loadedAssets() -> [String] {
        releaseExpiredMedia()
        return slots.keys.sorted()
    }
    private func releaseExpiredMedia() {
        for (asset,used) in lastMediaUse where ProcessInfo.processInfo.systemUptime-used >= 30 {
            slots.removeValue(forKey:asset)
        }
    }
    func prime(role: TextRole, queryFirst: Bool) async throws {
        if queryFirst && assets.names != [SingleModelSemanticIdentity.asset] {
            _ = try await function("q32")
            RuntimeDiagnostics.mark("first_run_query_partition_ready")
            line("Query model ready. Preparing document model.")
        }
        for name in role == .query ? ["q32"] : ["d256"] {
            _ = try await function(name)
        }
    }

    func prepare(_ names: [String]) async throws {
        for name in names {
            _ = try await function(name)
            if name.hasPrefix("v") || name.hasPrefix("a") { scheduleMediaRelease(name) }
        }
    }

    private func scheduleMediaRelease(_ name: String) {
        guard !assets.names.contains(SingleModelSemanticIdentity.asset) else { return }
        guard let relative = try? assets.sourceAsset(for: name) else { return }
        let asset = String(relative.dropLast(".aimodel".count))
        idleGeneration[asset, default: 0] += 1
        let generation = idleGeneration[asset]!
        lastMediaUse[asset] = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            Task.detached { [weak self] in await self?.releaseMedia(asset, generation: generation) }
        }
    }

    private func line(_ text: String) {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let bytes = Data("[coreai-ane] \(clock.string(from: Date())) \(text)\n".utf8)
        guard let log else { FileHandle.standardError.write(bytes); return }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        }
    }

    private func loadFunction(_ model: AIModel, name: String) throws -> InferenceFunction {
        if injectedFailures > 0 {
            injectedFailures -= 1
            throw WorkerError.failed("injected load_function failure")
        }
        guard let fn = try autoreleasepool(invoking: { try model.loadFunction(named: name) }) else { throw WorkerError.failed("missing function \(name)") }
        return fn
    }

    private func prepareFunction(_ name: String, asset: String, url: URL,
                                 options: SpecializationOptions, recovering: Bool) async throws -> InferenceFunction {
        // Keep model temporaries in this frame so they are released before recovery deletes the entry.
        if slots[asset] == nil {
            if !recovering {
                let started = Date()
                if let model = try SourceRecovery.cachedModel(assets, source: url, options: options) {
                    slots[asset] = Slot(model: model)
                    line("\(asset) cache hit in \(Date().timeIntervalSince(started)) s")
                } else {
                    line("\(asset) cache miss in \(Date().timeIntervalSince(started)) s")
                    throw MissingSpecialization()
                }
            }
            if slots[asset] == nil {
                let started = Date()
                line("\(asset) specialize begin persistent ANE")
                // Persistent retains the Core AI package. The external ANE program can
                // still become unavailable, as the Stage 0 controlled purge demonstrated.
                try specializationObserver?(url, .begin)
                let model: AIModel
                do {
                    model = try await AIModel.specialize(contentsOf: url, options: options, cachePolicy: .persistent)
                } catch {
                    try specializationObserver?(url, .failure)
                    throw error
                }
                try specializationObserver?(url, .success)
                slots[asset] = Slot(model: model)
                line("\(asset) specialize finished in \(Date().timeIntervalSince(started)) s")
            }
        }
        let started = Date()
        let fn = try loadFunction(slots[asset]!.model, name: name)
        slots[asset]!.functions[name] = fn
        line("\(name) load_function finished in \(Date().timeIntervalSince(started)) s")
        return fn
    }

    private func cachedFunction(_ name: String, asset: String, url: URL,
                                     options: SpecializationOptions) throws -> InferenceFunction? {
        guard let model = try SourceRecovery.cachedModel(assets, source: url, options: options) else { return nil }
        slots[asset] = Slot(model: model)
        let fn = try loadFunction(model, name: name)
        slots[asset]!.functions[name] = fn
        return fn
    }

    private func function(_ name: String) async throws -> InferenceFunction {
        releaseExpiredMedia()
        let relative = try assets.sourceAsset(for: name)
        if assets.names == [SingleModelSemanticIdentity.asset] {
            let group = try SingleModelGroups.group(for: name)
            do {
                guard let record = try SingleModelGroups.read(assets, group: group) else { throw ModelSetupPending() }
                let key = group + "-" + record.generation
                if let found = slots[key]?.functions[name] { return found }
                guard let model = try autoreleasepool(invoking: { try AIModel(resolvingBookmark: record.bookmark) }) else { throw ModelSetupPending() }
                let fn = try loadFunction(model, name: name)
                slots = slots.filter { !$0.key.hasPrefix(group + "-") || $0.key == key }
                if slots[key] == nil { slots[key] = Slot(model: model) }
                slots[key]!.functions[name] = fn
                return fn
            } catch {
                QueryBootstrap.invalidate(assets)
                scheduleFullPreparation()
                throw ModelSetupPending()
            }
        }
        let asset = String(relative.dropLast(".aimodel".count))
        return try await function(name, asset: asset, url: assets.directory.appendingPathComponent(relative), manifest: assets.manifest)
    }

    private func scheduleFullPreparation() {
        let disk = try? FileManager.default.attributesOfFileSystem(forPath: assets.directory.path)
        let free = (disk?[.systemFreeSize] as? NSNumber)?.uint64Value
        guard !preparingFullModel, fullModelRetry.canRetry(now: ProcessInfo.processInfo.systemUptime, freeBytes: free) else { return }
        preparingFullModel = true
        let directory = assets.directory
        Task.detached { [self] in
            let failure: String?
            do { try RuntimeDirectory(directory).prepareSingleModel(forceRepair: true); failure = nil }
            catch { failure = String(describing: error); await line("background single model recovery failed: \(error)") }
            await preparationFinished(failure)
        }
    }

    private func preparationFinished(_ failure: String?) {
        preparingFullModel = false
        if let failure { fullModelRetry.failed(failure, now: ProcessInfo.processInfo.systemUptime) }
        else { fullModelRetry = ModelPreparationRetry() }
    }

    private func function(_ name: String, asset: String, url: URL, manifest: URL) async throws -> InferenceFunction {
        if let found = slots[asset]?.functions[name] { return found }
        let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        let firstError: String
        let cacheMissing: Bool
        do {
            return try await prepareFunction(name, asset: asset, url: url, options: options, recovering: false)
        } catch {
            firstError = String(describing: error)
            cacheMissing = error is MissingSpecialization
        }
        let started = Date()
        line("\(name) load_function failed: \(firstError); recovery begin")
        slots.removeValue(forKey: asset)
        await CompilationCoordinator.shared.acquire()
        defer { Task { await CompilationCoordinator.shared.release() } }
        do {
            var deleteStale = !cacheMissing
            let probe = try SpecializationLock.acquireAndReprobe(path: SpecializationLock.path(runtime: assets.directory),
                timeout: assets.names == [SingleModelSemanticIdentity.asset] ? 1800 : 600, log: line) {
                // Release every handle under the lock, including before the fresh cache probe.
                slots.removeValue(forKey: asset)
                line("\(asset) released model and all functions in \(Date().timeIntervalSince(started)) s")
                do {
                    return try cachedFunction(name, asset: asset, url: url, options: options)
                } catch {
                    deleteStale = true
                    slots.removeValue(forKey: asset)
                    line("\(name) locked cache re-probe failed: \(error)")
                    return nil
                }
            }
            defer { withExtendedLifetime(probe.lease) {} }
            if let fn = probe.cached {
                line("\(name) locked cache re-probe succeeded; skipping repair")
                return fn
            }
            do {
                try SpecializationAdmission.check(runtime: assets.directory)
                try RuntimeDirectory.verifyAssetForRecovery(url, manifest: manifest)
                line("\(asset) recovery source verification passed")
                var repairURL = url
                if deleteStale {
                    let folder = assets.directory.deletingLastPathComponent().appendingPathComponent(".coreai-repair-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    repairURL = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: repairURL)
                    _ = try SingleModelGroups.renewCompilerIdentity(repairURL)
                }
                defer { if repairURL != url { try? FileManager.default.removeItem(at: repairURL.deletingLastPathComponent()) } }
                let fn = try await prepareFunction(name, asset: asset, url: repairURL, options: options, recovering: true)
                if repairURL != url, let model = slots[asset]?.model { try SourceRecovery.rememberRepair(assets, source: url, bookmark: model.bookmarkData) }
                line("\(name) recovery succeeded in \(Date().timeIntervalSince(started)) s")
                return fn
            } catch {
                slots.removeValue(forKey: asset)
                throw error
            }
        } catch {
            let second = String(describing: error)
            line("\(name) recovery failed after \(Date().timeIntervalSince(started)) s: \(second)")
            throw WorkerError.failed("load_function failed: \(firstError); specialization/retry failed: \(second)")
        }
    }

    func run(_ inputs: [String: HostTensor], name: String) async throws -> [UInt16] {
        try inferenceGate?()
        let profilePrefix = name.hasPrefix("a") ? "audio" : (name.hasPrefix("v") ? "vision" : "text")
        let loadStart = ImageCPUProfile.begin()
        let fn = try await function(name)
        defer { releaseAfterInference(name) }
        ImageCPUProfile.end(profilePrefix + "_function", loadStart)
        let inputStart = ImageCPUProfile.begin()
        var arrays: [String: NDArray] = [:]
        for (name, tensor) in inputs {
            guard case .ndArray(let descriptor) = fn.descriptor.inputDescriptor(of: name),
                  descriptor.scalarType == .float16, descriptor.shape == tensor.shape else {
                throw WorkerError.failed("input descriptor mismatch: \(name)")
            }
            var array = NDArray(shape: tensor.shape, scalarType: .float16)
            array.mutableView(as: Float16.self).withUnsafeMutablePointer { pointer, _, _ in
                pointer.withMemoryRebound(to: UInt16.self, capacity: tensor.bits.count) { bits in
                    tensor.bits.withUnsafeBufferPointer { bits.update(from: $0.baseAddress!, count: $0.count) }
                }
            }
            arrays[name] = array
        }
        ImageCPUProfile.end(profilePrefix + "_input_arrays", inputStart)
        let trace = ProcessInfo.processInfo.environment["DIGUP_COREAI_INFERENCE_TRACE"] == "1"
        func traceCall(_ phase: String) {
            guard trace else { return }
            let record: [String: Any] = ["event": phase, "function": name, "time": Date().timeIntervalSince1970, "phys_footprint": RuntimeDiagnostics.physicalFootprint()]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                FileHandle.standardError.write(Data("COREAI_INFERENCE ".utf8) + data + Data([10]))
            }
        }
        let directory = assets.directory, isQuery = queryOnly
        let dispatch = try await Task.detached(priority: isQuery ? .userInitiated : .utility) {
            try InferencePriority(directory: directory, query: isQuery)
        }.value
        defer { withExtendedLifetime(dispatch) {} }
        traceCall("model_start")
        let callStart = ImageCPUProfile.begin()
        var outputs = try await fn.run(inputs: arrays)
        ImageCPUProfile.end(profilePrefix + "_call_host", callStart)
        let outputStart = ImageCPUProfile.begin()
        defer { ImageCPUProfile.end(profilePrefix + "_output", outputStart) }
        traceCall("model_end")
        guard let value = outputs.remove("y"), let array = value.ndArray,
              array.shape == (name.hasPrefix("a") ? [1,512,1,750] : (name.hasPrefix("v") ? [1,512,1,Int(name.dropFirst())!/9] : [1,768])), array.scalarType == .float16 else {
            throw WorkerError.failed("output descriptor mismatch")
        }
        if name.hasPrefix("v") || name.hasPrefix("a") {
            let count = name.hasPrefix("a") ? 750 : Int(name.dropFirst())!/9
            let bits=array.view(as:Float16.self).withUnsafePointer { pointer,_,strides in
                (0..<512).flatMap { c in (0..<count).map { pointer[c*strides[1]+$0*strides[3]].bitPattern } }
            }
            scheduleMediaRelease(name)
            return bits
        }
        return array.view(as: Float16.self).withUnsafePointer { pointer, _, strides in
            (0..<768).map { pointer[$0 * strides[1]].bitPattern }
        }
    }
}

@available(macOS 27, *)
public struct EmbeddingTiming: Codable, Sendable {
    public let tokenizeMS: Double
    public let prepMS: Double
    public let modelMS: Double
    public let finalizeMS: Double
    public let totalMS: Double
    public let bucket: Int
}

@available(macOS 27, *)
public final class CoreAIEmbedder: VideoClipEmbedder, PanelQueryProgram {
    public private(set) var info: WorkerInfo
    public private(set) var lastTimings: [EmbeddingTiming] = []
    public private(set) var lastVideoTimings: [VideoEmbeddingTiming] = []
    public private(set) var lastAudioTimings: [AudioEmbeddingTiming] = []
    public private(set) var warmupSeconds: Double = 0
    public private(set) var modelLoadSeconds: Double = 0
    public let role: TextRole
    private var resources: SharedHostResources?
    private let engine: CoreAIEngine
    private let engineAssetsDirectory: URL
    private var closed = false

    public init(role: TextRole, assets: CoreAIAssets, prepareQueryFirst: Bool = false, tokenizer: URL, tokenTable: URL,
                ropeTables: URL, log: URL? = nil,
                inferenceGate: (@Sendable () throws -> Void)? = nil,
                specializationObserver: (@Sendable (URL, SpecializationPhase) throws -> Void)? = nil) throws {
        try RuntimeCacheIdentity.requireCacheOwner()
        guard !Thread.isMainThread else { throw WorkerError.failed("CoreAIEmbedder requires a dedicated worker thread") }
        let announcement = role == .query ? try InferencePriority.QueryAnnouncement(directory: assets.directory) : nil
        defer { withExtendedLifetime(announcement) {} }
        let start = Date()
        self.role = role
        engineAssetsDirectory = assets.directory
        let engine = CoreAIEngine(assets: assets, queryOnly: role == .query, log: log, inferenceGate: inferenceGate,
                              specializationObserver: specializationObserver ?? SpecializationAudit.fromEnvironment())
        self.engine = engine
        info = WorkerInfo(model: "google/embeddinggemma-2", revision: assets.revision,
                          runtime: "coreai-ane", dtype: "fp16", dim: 768,
                          textOnly: role == .query || !(assets.names.contains("vision.aimodel") || assets.names.contains(SingleModelSemanticIdentity.asset)), loadSeconds: nil)
        let host = {
            RuntimeDiagnostics.mark("query_host_begin")
            let resources = try SharedHostResources.acquire(tokenizer:tokenizer,table:tokenTable,rope:ropeTables)
            RuntimeDiagnostics.mark("query_host_ready")
            return resources
        }
        let functions: @Sendable () async throws -> TimeInterval = {
            let began = Date()
            try await engine.prime(role: role, queryFirst: prepareQueryFirst)
            RuntimeDiagnostics.mark("query_functions_ready")
            return Date().timeIntervalSince(began)
        }
        let prepared: (SharedHostResources, TimeInterval)
        do {
            if role == .query {
                prepared = try prepareQueryResources(host: host, functions: functions)
            } else {
                prepared = (try host(), try coreAIBlocking(functions))
            }
        } catch {
            _ = try? coreAIBlocking { await engine.close() }
            throw error
        }
        resources = prepared.0
        modelLoadSeconds = prepared.1
        do {
            let warmStart = Date()
            let text = role == .query ? Prompts.query("warm up") : Prompts.document(title: nil, text: "warm up")
            for _ in 0..<2 { _ = try embedTexts([text]) }
            if role == .query {
                let ids = try prepared.0.withText { tokenizer, _ in try tokenizer.tokenize(text, limit: 64) }
                for bucket in [64, 128] {
                    let inputs = try prepared.0.withText { _, host in try host.prepare(ids, bucket: bucket) }
                    _ = try rawOutput(inputs, bucket: bucket)
                }
            }
            warmupSeconds = Date().timeIntervalSince(warmStart)
        } catch { close(); throw error }
        info = WorkerInfo(model: info.model, revision: info.revision, runtime: info.runtime, dtype: info.dtype,
                          dim: 768, textOnly: info.textOnly, loadSeconds: Date().timeIntervalSince(start))
    }

    public func loadQueryProgram() throws {
        guard role == .query, !closed else { throw WorkerError.failed("query program requires an open query encoder") }
        let announcement = try InferencePriority.QueryAnnouncement(directory: engineAssetsDirectory)
        defer { withExtendedLifetime(announcement) {} }
        try prepareFunctions(["q32", "q64", "q128"])
        for name in ["q32", "q64", "q128"] { try warmFunction(name) }
    }
    public func unloadQueryProgram() {
        guard role == .query else { return }
        let engine = engine
        _ = try? coreAIBlocking { await engine.close() }
        resources?.withText { _, host in host.releaseTransientBuffers() }
    }

    deinit { close() }
    public func close() {
        guard !closed else { return }
        closed = true
        let engine = engine
        if Thread.isMainThread { Task.detached { await engine.close() } }
        else { _ = try? coreAIBlocking { await engine.close() } }
        resources = nil
    }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        guard !closed, let resources else { throw WorkerError.failed("CoreAIEmbedder is closed") }
        guard !Thread.isMainThread else { throw WorkerError.failed("CoreAIEmbedder requires a dedicated worker thread") }
        let announcement = role == .query ? try InferencePriority.QueryAnnouncement(directory: engineAssetsDirectory) : nil
        defer { withExtendedLifetime(announcement) {} }
        lastTimings = []
        var vectors: [[Float]] = []
        for text in texts {
            let start = Date()
            let ids = try resources.withText { tokenizer,_ in try tokenizer.tokenize(text,limit:role.limit) }
            let tokenized = Date()
            let bucket = try TextHostPrep.bucketFor(ids.count, role: role)
            let inputs = try resources.withText { _,host in try host.prepare(ids,bucket:bucket) }
            let prepared = Date()
            let raw = try rawOutput(inputs, bucket: bucket)
            let ran = Date()
            vectors.append(try TextHostPrep.finalize(raw))
            let end = Date()
            lastTimings.append(EmbeddingTiming(tokenizeMS: tokenized.timeIntervalSince(start) * 1000,
                prepMS: prepared.timeIntervalSince(tokenized) * 1000, modelMS: ran.timeIntervalSince(prepared) * 1000,
                finalizeMS: end.timeIntervalSince(ran) * 1000, totalMS: end.timeIntervalSince(start) * 1000, bucket: bucket))
        }
        return vectors
    }

    public func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        guard role == .document else { throw WorkerError.failed("Core AI query worker is text-only") }
        guard [70,140,280].contains(budget) else { throw WorkerError.failed("unsupported Core AI image budget: \(budget)") }
        guard !closed, let resources else { throw WorkerError.failed("CoreAIEmbedder is closed") }
        guard !Thread.isMainThread else { throw WorkerError.failed("CoreAIEmbedder requires a dedicated worker thread") }
        lastTimings=[]
        return try paths.map { path in
            let started=Date()
            let prepared: (inputs:[String:HostTensor],tokens:Int)
            do { prepared=try resources.withVision { vision,_ in
                let decodeStart=ImageCPUProfile.begin()
                let decoded=try VisionHostPrep.decode(URL(fileURLWithPath:path))
                ImageCPUProfile.end("decode",decodeStart)
                return try vision.prepare(decoded,budget:budget)
            } }
            catch { return Embedding(vector:nil,error:String(describing:error)) }
            ImageCPUProfile.identify(prepared.inputs)
            let prepEnd=Date(), engine=engine
            let soft=try coreAIBlocking { try await engine.run(prepared.inputs,name:"v"+String(budget*9)) }
            let composeStart=ImageCPUProfile.begin()
            let composed=try resources.withVision { _,host in try VisionHostPrep.compose(soft,tokens:prepared.tokens,budget:budget,host:host) }
            ImageCPUProfile.end("text_composition",composeStart)
            let raw=try rawOutput(composed.inputs,bucket:composed.bucket)
            let modelEnd=Date()
            let l2Start=ImageCPUProfile.begin()
            let vector=try TextHostPrep.finalize(raw)
            ImageCPUProfile.end("l2",l2Start)
            ImageCPUProfile.identify(vector)
            let end=Date()
            lastTimings.append(EmbeddingTiming(tokenizeMS:0,prepMS:prepEnd.timeIntervalSince(started)*1000,
                modelMS:modelEnd.timeIntervalSince(prepEnd)*1000,finalizeMS:end.timeIntervalSince(modelEnd)*1000,
                totalMS:end.timeIntervalSince(started)*1000,bucket:budget*9))
            return Embedding(vector:vector,error:nil)
        }
    }
    public func embedAudio(_ paths: [String]) throws -> [Embedding] {
        guard role == .document else { throw WorkerError.failed("Core AI query worker is text-only") }
        guard !closed, let resources else { throw WorkerError.failed("CoreAIEmbedder is closed") }
        guard !Thread.isMainThread else { throw WorkerError.failed("CoreAIEmbedder requires a dedicated worker thread") }
        lastTimings=[];lastAudioTimings=[]
        return try paths.map { path in
            let start=Date()
            let prepared: ([String:HostTensor],Int)
            do {
                let pcm=try PCM16.decode(URL(fileURLWithPath:path))
                prepared=try resources.withAudio { audio,_ in
                    let mel=try audio.mel(pcm)
                    guard mel.tokens>0 else { throw WorkerError.failed("audio has zero soft tokens; skipped") }
                    return (try audio.prepare(mel),mel.tokens)
                }
            } catch { return Embedding(vector:nil,error:String(describing:error)) }
            let prepEnd=Date()
            let soft=try audioOutput(prepared.0)
            let audioEnd=Date()
            let composed=try resources.withAudio { _,host in try AudioHostPrep.compose(soft,tokens:prepared.1,host:host) }
            let composeEnd=Date()
            let raw=try rawOutput(composed.inputs,bucket:composed.bucket)
            let textEnd=Date()
            let vector=try TextHostPrep.finalize(raw),end=Date()
            lastAudioTimings.append(AudioEmbeddingTiming(prepMS:prepEnd.timeIntervalSince(start)*1000,
                audioMS:audioEnd.timeIntervalSince(prepEnd)*1000,compositionMS:composeEnd.timeIntervalSince(audioEnd)*1000,
                textMS:textEnd.timeIntervalSince(composeEnd)*1000,finalizeMS:end.timeIntervalSince(textEnd)*1000,
                totalMS:end.timeIntervalSince(start)*1000,tokens:prepared.1,textBucket:composed.bucket))
            lastTimings.append(EmbeddingTiming(tokenizeMS:0,prepMS:prepEnd.timeIntervalSince(start)*1000,
                modelMS:textEnd.timeIntervalSince(prepEnd)*1000,finalizeMS:end.timeIntervalSince(textEnd)*1000,
                totalMS:end.timeIntervalSince(start)*1000,bucket:3000))
            RuntimeDiagnostics.mark("audio_embedded")
            return Embedding(vector:vector,error:nil)
        }
    }

    public func embedVideoClips(_ url: URL, schedule: [VideoClipRange]? = nil) throws -> [[Float]] {
        let ranges = try schedule ?? VideoHostPrep.schedule(duration: VideoHostPrep.duration(url))
        lastVideoTimings = []
        return try ranges.map { range in
            let begin = Date()
            let frames = try VideoHostPrep.decode(url, range: range)
            let decoded = Date()
            let vector = try embedVideoFrames(frames)
            let end = Date()
            lastVideoTimings.append(VideoEmbeddingTiming(start:range.start,end:range.end,frames:frames.count,
                decodeMS:decoded.timeIntervalSince(begin)*1000,modelMS:end.timeIntervalSince(decoded)*1000,
                totalMS:end.timeIntervalSince(begin)*1000))
            return vector
        }
    }

    public func embedVideoFrames(_ frames: [RGBImage]) throws -> [Float] {
        guard !closed, role == .document, let resources, !Thread.isMainThread else { throw WorkerError.failed("closed or query video embedder") }
        guard (1...14).contains(frames.count) else { throw WorkerError.failed("invalid video frame count") }
        var soft: [[UInt16]] = [], counts: [Int] = []
        for frame in frames {
            let prepared = try resources.withVision { vision,_ in try vision.prepare(frame,budget:140) }
            let engine = engine
            let bits = try coreAIBlocking { try await engine.run(prepared.inputs,name:"v1260") }
            guard bits.allSatisfy({ Float16(bitPattern:$0).isFinite }) else { throw WorkerError.failed("nonfinite video soft tokens") }
            soft.append(bits); counts.append(prepared.tokens)
        }
        let text = try resources.withText { _,host in try VideoHostPrep.compose(soft,counts:counts,host:host) }
        return try TextHostPrep.finalize(rawOutput(text.inputs,bucket:text.bucket))
    }

    // Diagnostic entry points use the production engine and its bounded recovery path.
    public func rawOutput(_ inputs: [String: HostTensor], bucket: Int) throws -> [UInt16] {
        guard !closed, TextHostPrep.buckets.contains(bucket), role == .document || bucket <= 512 else {
            throw WorkerError.failed("closed embedder or invalid bucket")
        }
        let name = (bucket <= 128 ? "q" : "d") + String(bucket)
        let engine = engine
        return try coreAIBlocking { try await engine.run(inputs, name: name) }
    }
    public func audioOutput(_ inputs: [String:HostTensor]) throws -> [UInt16] {
        guard !closed, role == .document else { throw WorkerError.failed("closed or query embedder") }
        let engine=engine
        let bits=try coreAIBlocking { try await engine.run(inputs,name:"a3000") }
        guard bits.allSatisfy({ Float16(bitPattern:$0).isFinite }) else { throw WorkerError.failed("nonfinite audio soft tokens") }
        return bits
    }
    public func injectFunctionLoadFailures(_ count: Int) throws {
        guard !closed, (0...2).contains(count) else { throw WorkerError.failed("invalid failure injection") }
        let engine = engine
        try coreAIBlocking { await engine.close(); await engine.injectLoadFailures(count) }
    }
    public func loadedAssets() throws -> [String] {
        let engine = engine
        return try coreAIBlocking { await engine.loadedAssets() }
    }

    public func warmFunction(_ name: String) throws {
        guard !closed, let resources else { throw WorkerError.failed("closed embedder") }
        let inputs: [String: HostTensor]
        if name.hasPrefix("v"), let count = Int(name.dropFirst()) {
            let image = try RGBImage(width:48,height:48,pixels:Array(repeating:127,count:48*48*3))
            inputs = try resources.withVision { vision,_ in try vision.prepare(image,budget:count/9).inputs }
        } else if name == "a3000" {
            inputs = try resources.withAudio { audio, _ in try audio.prepare(audio.mel(Array(repeating: 0, count: 16000))) }
        } else if let count = Int(name.dropFirst()), (name.hasPrefix("q") || name.hasPrefix("d")) {
            inputs = try resources.withText { _,host in try host.prepare([2,1],bucket:count) }
        } else { throw WorkerError.failed("unsupported setup function: \(name)") }
        let engine = engine
        let bits = try coreAIBlocking { try await engine.run(inputs,name:name) }
        guard bits.allSatisfy({ Float16(bitPattern:$0).isFinite }) else { throw WorkerError.failed("nonfinite setup output: \(name)") }
    }

    public func specializationBookmark() throws -> Data {
        let engine = engine
        return try coreAIBlocking { try await engine.singleModelBookmark() }
    }

    public func prepareFunctions(_ names: [String]) throws {
        let engine = engine
        try coreAIBlocking { try await engine.prepare(names) }
    }
}

@available(macOS 27, *)
public struct AudioEmbeddingTiming: Codable, Sendable {
    public let prepMS: Double
    public let audioMS: Double
    public let compositionMS: Double
    public let textMS: Double
    public let finalizeMS: Double
    public let totalMS: Double
    public let tokens: Int
    public let textBucket: Int
}
