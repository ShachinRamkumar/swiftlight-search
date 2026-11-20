import CoreAI
import CryptoKit
import DigUpKit
import Foundation

public enum ModelSetupPhase: String, Codable, Sendable {
    case verifyingSource, preparingQueries, specializing, loadingQueries, loadingDocuments, loadingVision, loadingAudio, ready
    public var message: String {
        switch self {
        case .verifyingSource: "Checking search model"
        case .preparingQueries, .loadingQueries: "Preparing query search"
        case .loadingDocuments: "Queries are ready. Preparing documents"
        case .specializing, .loadingVision: "Text search is ready. Preparing images"
        case .loadingAudio: "Text and image search are ready. Preparing audio"
        case .ready: ""
        }
    }
}

@available(macOS 27, *)
extension RuntimeDirectory {
    public var hasCompleteSetupCheckpoint: Bool { QueryBootstrap.ready(assets) }

    public var hasPreparedQueryGroup: Bool {
        (try? SingleModelGroups.read(assets, group: "query3")) != nil
    }

    public func prepareSingleModel(deleteSourceAfterCompile: Bool = true, forceRepair: Bool = false,
                                   progress: (ModelSetupPhase) -> Void = { _ in }) throws {
        guard assets.names == [SingleModelSemanticIdentity.asset] else { throw WorkerError.failed("setup requires the single model runtime") }
        try RuntimeCacheIdentity.requireCacheOwner()
        let folder = try QueryBootstrap.setupDirectory(assets)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lease = try SpecializationLock(path: folder.appendingPathComponent("groups.lock"), timeout: 3600)
        defer { withExtendedLifetime(lease) {} }
        if !forceRepair && QueryBootstrap.ready(assets) {
            if deleteSourceAfterCompile { try SourceRecovery.removeVerifiedSource(assets) }
            progress(.ready)
            return
        }
        try CompilerTemporaryFiles.cleanup(directory: directory)
        var completed: [SingleModelGroups.Record] = []
        for group in SingleModelGroups.order {
            progress(group == "query3" ? .preparingQueries : group == "doc4" ? .loadingDocuments : group == "vision3" ? .loadingVision : .loadingAudio)
            if let record = try SingleModelGroups.read(assets, group: group),
               let model = try? AIModel(resolvingBookmark: record.bookmark),
               let answers = try? coreAIBlocking({ try await SingleModelGroups.check(model, group: group, directory: directory) }) {
                let knownURL = folder.appendingPathComponent(group + "-known-answers.json")
                let known = (try? Data(contentsOf: knownURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                if known == nil || known == answers {
                    if known == nil { try JSONEncoder().encode(answers).write(to: knownURL, options: .atomic) }
                    completed.append(record)
                    continue
                }
            }
            progress(.verifyingSource)
            try SourceRecovery.ensureSource(assets)
            let generation = UUID().uuidString
            let source = folder.appendingPathComponent(generation).appendingPathComponent(group + ".aimodel")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let sourceHash = try SingleModelGroups.materialize(assets, group: group, destination: source)
            let compileLock = try SpecializationLock(path: SpecializationLock.path(runtime: directory), timeout: 3600)
            defer { withExtendedLifetime(compileLock) {} }
            try SpecializationAdmission.check(minimumDisk: Int64(group == "audio1" ? 18 : group == "vision3" ? 17 : group == "query3" ? 15 : 16) * 1024 * 1024 * 1024, allowWarning: true, freeDisk: {
                let info = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
                return (info[.systemFreeSize] as! NSNumber).int64Value
            })
            let tracker = try CompilerTemporaryFiles.begin(directory: directory)
            let model: AIModel
            do {
                model = try coreAIBlocking {
                    try await AIModel.specialize(contentsOf: source, options: SpecializationOptions(preferredComputeUnitKind: .neuralEngine), cachePolicy: .persistent)
                }
                try tracker.finish()
            } catch { try? tracker.finish(); throw error }
            let before = try coreAIBlocking { try await SingleModelGroups.check(model, group: group, directory: directory) }
            let record = SingleModelGroups.Record(namespace: RuntimeCacheIdentity.namespace, osBuild: RuntimeCacheIdentity.osBuild,
                architecture: AIModel.deviceArchitectureName, group: group, generation: generation,
                bookmark: model.bookmarkData, sourceHash: sourceHash)
            // Publish a verified group immediately. Query search can run while later groups compile.
            try JSONEncoder().encode(before).write(to: folder.appendingPathComponent(group + "-known-answers.json"), options: .atomic)
            try JSONEncoder().encode(record).write(to: SingleModelGroups.recordURL(assets, group: group), options: .atomic)
            completed.append(record)
        }
        // Stub only after every group has completed real inference. Reopen each bookmark after replacement.
        for record in completed {
            try SingleModelGroups.stubResources(bookmark: record.bookmark, sourceHash: record.sourceHash)
            guard let model = try AIModel(resolvingBookmark: record.bookmark) else { throw WorkerError.failed("stubbed group bookmark unavailable") }
            let after = try coreAIBlocking { try await SingleModelGroups.check(model, group: record.group, directory: directory) }
            let knownURL = folder.appendingPathComponent(record.group + "-known-answers.json")
            let before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: knownURL))
            guard before == after else { throw WorkerError.failed("stub changed output bits: \(record.group)") }
        }
        if deleteSourceAfterCompile { try SourceRecovery.removeVerifiedSource(assets) }
        try QueryBootstrap.markReady(assets)
        progress(.ready)
    }
}
