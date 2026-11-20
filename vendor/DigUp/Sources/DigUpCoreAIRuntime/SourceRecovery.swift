import CoreAI
import CryptoKit
import Darwin
import DigUpKit
import Foundation

@available(macOS 27, *)
enum SourceRecovery {
    static let enabled = true
    static let releaseDownloadBaseURL: URL? = nil
    static var allowed: Bool { true }
    // There is deliberately no compiled-weight donor or offline source archive.
    static let hashes: [String: String] = [:]
    struct Pin: Codable { let bytes: Int; let sha256: String }
    struct Receipt: Codable { let manifestSHA256: String; let sourceDeleted: Bool }

    static func folder(directory: URL, manifest: Data) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(".coreai-recovery")
            .appendingPathComponent(QueryBootstrap.digest(manifest))
    }
    static func acceptsAbsentSource(directory: URL, manifest: Data) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(SingleModelSemanticIdentity.asset).path) else { return false }
        let receiptURL = folder(directory: directory, manifest: manifest).appendingPathComponent("receipt.json")
        guard let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt.sourceDeleted && receipt.manifestSHA256 == QueryBootstrap.digest(manifest)
    }
    static func fileHash(_ path: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            guard let data = try input.read(upToCount: 1 << 20), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func matches(_ path: URL, identity: Pin) -> Bool {
        var info = stat()
        guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == identity.bytes else { return false }
        return (try? fileHash(path)) == identity.sha256
    }
    struct RepairRecord: Codable {
        let namespace: String
        let osBuild: String
        let sourceHash: String
        let bookmark: Data
    }
    static func repairRecordURL(_ assets: CoreAIAssets, source: URL) throws -> URL {
        try QueryBootstrap.setupDirectory(assets).appendingPathComponent("repaired-" + source.lastPathComponent + ".json")
    }
    static func sourcePin(_ assets: CoreAIAssets, source: URL) throws -> String {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.manifest)) as! [String: Any]
        let files = manifest["files"] as! [String: String]
        let root = assets.directory.standardizedFileURL.path + "/"
        let path = source.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw WorkerError.failed("repair source outside runtime") }
        let suffix = String(path.dropFirst(root.count)) + "/main.mlirb"
        guard let value = files[suffix] else { throw WorkerError.failed("repair source is not bound by the manifest") }
        return value
    }
    static func cachedModel(_ assets: CoreAIAssets, source: URL, options: SpecializationOptions) throws -> AIModel? {
        if let data = try? Data(contentsOf: repairRecordURL(assets, source: source)),
           let record = try? JSONDecoder().decode(RepairRecord.self, from: data),
           record.namespace == RuntimeCacheIdentity.namespace, record.osBuild == RuntimeCacheIdentity.osBuild,
           record.sourceHash == (try sourcePin(assets, source: source)) {
            return try AIModel(resolvingBookmark: record.bookmark)
        }
        return try AIModelCache.default.model(for: source, options: options)
    }
    static func rememberRepair(_ assets: CoreAIAssets, source: URL, bookmark: Data) throws {
        let path = try repairRecordURL(assets, source: source)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = RepairRecord(namespace: RuntimeCacheIdentity.namespace, osBuild: RuntimeCacheIdentity.osBuild,
                                  sourceHash: try sourcePin(assets, source: source), bookmark: bookmark)
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
    }
    static func ensureSource(_ assets: CoreAIAssets) throws {
        let source = assets.directory.appendingPathComponent(SingleModelSemanticIdentity.asset)
        if FileManager.default.fileExists(atPath: source.path) { return }
        let manifest = try Data(contentsOf: assets.manifest)
        let root = folder(directory: assets.directory, manifest: manifest)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lease = try SpecializationLock(path: root.appendingPathComponent("source.lock"))
        defer { withExtendedLifetime(lease) {} }
        if FileManager.default.fileExists(atPath: source.path) { return }
        let record = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        guard let inventories = record["asset_inventory"] as? [String: [String: PinJSON]],
              let inventory = inventories[SingleModelSemanticIdentity.asset] else {
            throw WorkerError.failed("missing source download inventory")
        }
        let pins = try inventory.mapValues { value -> Pin in
            guard let bytes = value["bytes"] as? Int, let sha = value["sha256"] as? String else { throw WorkerError.failed("invalid source download pin") }
            return Pin(bytes: bytes, sha256: sha)
        }
        let required = UInt64(14 * 1024 * 1024 * 1024) + pins.values.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
        let info = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let free = (info[.systemFreeSize] as! NSNumber).uint64Value
        guard free >= required else { throw WorkerError.failed("specialization admission refused: free disk \(free) below \(required) bytes for source download") }
        var configured = record["source_download"] as? [String: [String: Any]] ?? [:]
        var allowFile = false
        if let base = ProcessInfo.processInfo.environment["SWIFTLIGHT_SOURCE_DOWNLOAD_BASE_URL"].flatMap(URL.init(string:)) ?? releaseDownloadBaseURL {
            #if SINGLE_MODEL_RESEARCH
            allowFile = ["org.swiftlight.storage.research.single-model", "org.swiftlight.storage.research.compile-speed"].contains(RuntimeCacheIdentity.namespace) && base.isFileURL
            #endif
            guard (base.scheme == "https" && base.host != nil) || allowFile else {
                throw WorkerError.failed("source download base URL must use HTTPS")
            }
            for name in pins.keys { configured[name] = ["url": base.appendingPathComponent(name).absoluteString] }
        }
        let stage = root.appendingPathComponent("downloading.aimodel")
        try downloadFiles(configured, pins: pins, destination: stage, allowFileURLs: allowFile)
        try FileManager.default.moveItem(at: stage, to: source)
        try RuntimeDirectory.verifyAssetForRecovery(source, manifest: assets.manifest)
    }
    private typealias PinJSON = [String: Any]

    static func removeVerifiedSource(_ assets: CoreAIAssets) throws {
        let source = assets.directory.appendingPathComponent(SingleModelSemanticIdentity.asset)
        let manifest = try Data(contentsOf: assets.manifest)
        let root = folder(directory: assets.directory, manifest: manifest)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lease = try SpecializationLock(path: root.appendingPathComponent("source.lock"))
        defer { withExtendedLifetime(lease) {} }
        // Setup writes this receipt only after fresh post-stub inference checks on every group.
        if FileManager.default.fileExists(atPath: source.path) {
            try RuntimeDirectory.verifyAssetForRecovery(source, manifest: assets.manifest)
            let receipt = Receipt(manifestSHA256: QueryBootstrap.digest(manifest), sourceDeleted: true)
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            try FileManager.default.removeItem(at: source)
        }
    }
    private final class DownloadResult: @unchecked Sendable {
        var result: Result<Void, Error>?
        let done = DispatchSemaphore(value: 0)
    }
    private final class HTTPSPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let limit: Int64
        let destination: URL
        let result: DownloadResult
        init(limit: Int64, destination: URL, result: DownloadResult) {
            self.limit = limit; self.destination = destination; self.result = result
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https" else { throw WorkerError.failed("source recovery download failed") }
                try FileManager.default.moveItem(at: location, to: destination)
                result.result = .success(())
            } catch { result.result = .failure(error) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { result.result = .failure(error) }
            if result.result == nil { result.result = .failure(WorkerError.failed("source recovery download did not finish")) }
            result.done.signal()
        }
    }


    static func downloadURLs(_ configured: [String: [String: Any]], files: Set<String>, allowFileURLs: Bool = false) throws -> [String: URL] {
        guard files == ["main.hash", "main.mlirb", "metadata.json"] else { throw WorkerError.failed("invalid source download file set") }
        var urls: [String: URL] = [:]
        for name in files {
            guard let text = configured[name]?["url"] as? String, let url = URL(string: text),
                  (url.scheme == "https" && url.host != nil) || (allowFileURLs && url.isFileURL) else {
                throw WorkerError.failed("pinned HTTPS source download URLs are not configured")
            }
            urls[name] = url
        }
        return urls
    }

    static func downloadFiles(_ configured: [String: [String: Any]], pins: [String: Pin], destination: URL,
                              allowFileURLs: Bool = false, attempts: Int = 3,
                              transport: ((URL, URL, Int) throws -> Void)? = nil) throws {
        let urls = try downloadURLs(configured, files: Set(pins.keys), allowFileURLs: allowFileURLs)
        guard attempts > 0, pins.values.allSatisfy({ $0.bytes > 0 && $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else {
            throw WorkerError.failed("invalid source download pins")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in pins.keys.sorted() {
            let pin = pins[name]!, target = destination.appendingPathComponent(name)
            if matches(target, identity: pin) { continue }
            for attempt in 1...attempts {
                let temporary = destination.appendingPathComponent(name + ".partial")
                try? FileManager.default.removeItem(at: temporary)
                do {
                    if let transport { try transport(urls[name]!, temporary, pin.bytes) }
                    else if allowFileURLs && urls[name]!.isFileURL { try FileManager.default.copyItem(at: urls[name]!, to: temporary) }
                    else {
                        let result = DownloadResult()
                        let policy = HTTPSPolicy(limit: Int64(pin.bytes), destination: temporary, result: result)
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.timeoutIntervalForRequest = 60
                        configuration.timeoutIntervalForResource = 600
                        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
                        defer { session.invalidateAndCancel() }
                        session.downloadTask(with: urls[name]!).resume()
                        result.done.wait()
                        try result.result!.get()
                    }
                    guard matches(temporary, identity: pin) else { throw WorkerError.failed("source download size/SHA-256 mismatch: \(name)") }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    break
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    if attempt == attempts { throw error }
                }
            }
        }
    }
}

@available(macOS 27, *)
extension RuntimeDirectory {
    public func restoreSourceFromDownload() throws {
        try RuntimeCacheIdentity.requireCacheOwner()
        try SourceRecovery.ensureSource(assets)
    }
}
