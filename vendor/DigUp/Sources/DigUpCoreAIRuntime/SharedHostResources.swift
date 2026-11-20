import Foundation

@available(macOS 27, *)
public final class SharedHostResources {
    private final class Weak {
        weak var value: SharedHostResources?
        init(_ value: SharedHostResources) { self.value=value }
    }
    private static let registryLock=NSLock()
    nonisolated(unsafe) private static var registry: [String:Weak]=[:]
    private let lock=NSRecursiveLock()
    public let tokenizer: HFTokenizer
    public let text: TextHostPrep
    private let visionFolder: URL
    private var visionHost: VisionHostPrep?
    private var audioHost: AudioHostPrep?

    private init(tokenizer: URL, table: URL, rope: URL) throws {
        RuntimeDiagnostics.mark("tokenizer_load_begin")
        self.tokenizer=try HFTokenizer(contentsOf:tokenizer)
        RuntimeDiagnostics.mark("tokenizer_load_ready")
        text=try TextHostPrep(tokenTable:table,ropeTables:rope)
        RuntimeDiagnostics.mark("text_host_ready")
        visionFolder=table.deletingLastPathComponent().appendingPathComponent("vision-host")
    }
    deinit { tokenizer.close() }

    public static func acquire(tokenizer: URL, table: URL, rope: URL) throws -> SharedHostResources {
        registryLock.lock(); defer { registryLock.unlock() }
        let key=[tokenizer,table,rope].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.joined(separator:"\n")
        if let found=registry[key]?.value { return found }
        let value=try SharedHostResources(tokenizer:tokenizer,table:table,rope:rope)
        registry[key]=Weak(value)
        registry=registry.filter { $0.value.value != nil }
        return value
    }
    public func withText<T>(_ body: (HFTokenizer,TextHostPrep) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(tokenizer,text)
    }
    public func withVision<T>(_ body: (VisionHostPrep,TextHostPrep) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if visionHost == nil { visionHost=try VisionHostPrep(folder:visionFolder) }
        return try body(visionHost!,text)
    }
    public func withAudio<T>(_ body: (AudioHostPrep,TextHostPrep) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if audioHost == nil { audioHost=try AudioHostPrep(folder:visionFolder.deletingLastPathComponent().appendingPathComponent("audio-host")) }
        return try body(audioHost!,text)
    }

}
