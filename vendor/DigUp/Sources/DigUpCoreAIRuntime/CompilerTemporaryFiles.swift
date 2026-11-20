import Darwin
import Foundation

/// Records only this process's compiler regions. Never sweeps another client's MPSGraph files.
final class CompilerTemporaryFiles: @unchecked Sendable {
    struct File: Codable { let path: String; let inode: UInt64; let bytes: Int64 }
    struct Record: Codable { let pid: Int32; let namespace: String; var completed: Bool; var files: [File] }
    private let recordURL: URL
    private let queue = DispatchQueue(label: "swiftlight.compiler-temp")
    private let timer: DispatchSourceTimer
    private var record: Record
    private let root: URL

    static func temporaryRoot() -> URL {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        var bytes = [CChar](repeating: 0, count: count)
        _ = confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, count)
        return URL(fileURLWithPath: String(cString: bytes)).appendingPathComponent("com.apple.MetalPerformanceShadersGraph")
    }
    static func folder(_ directory: URL) -> URL { directory.deletingLastPathComponent().appendingPathComponent(".coreai-compiler-temp") }

    init(directory: URL) throws {
        root = Self.temporaryRoot()
        let folder = Self.folder(directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recordURL = folder.appendingPathComponent(UUID().uuidString + ".json")
        record = Record(pid: getpid(), namespace: RuntimeCacheIdentity.namespace, completed: false, files: [])
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.capture() }
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        timer.resume()
    }
    static func begin(directory: URL) throws -> CompilerTemporaryFiles { try CompilerTemporaryFiles(directory: directory) }

    private func capture() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var files: [File] = []
        for folder in folders where folder.lastPathComponent.hasPrefix("mpsgraph-\(record.pid)-") {
            var directoryInfo = stat()
            guard lstat(folder.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
                  let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in children where file.lastPathComponent.hasSuffix(".bc.mlir") {
                var info = stat()
                if lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                    files.append(File(path: file.path, inode: info.st_ino, bytes: info.st_size))
                }
            }
        }
        record.files = files
        try? JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    }
    func finish() throws {
        timer.cancel()
        try queue.sync {
            capture()
            record.completed = true
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        }
    }
    deinit { timer.cancel() }

    static func cleanup(directory: URL, root: URL = temporaryRoot()) throws {
        let folder = folder(directory)
        guard let records = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in records where url.pathExtension == "json" {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)),
                  record.namespace == RuntimeCacheIdentity.namespace,
                  record.completed || (kill(record.pid, 0) != 0 && errno == ESRCH) else { continue }
            for file in record.files {
                let path = URL(fileURLWithPath: file.path).standardizedFileURL
                guard path.deletingLastPathComponent().deletingLastPathComponent() == root.standardizedFileURL,
                      path.deletingLastPathComponent().lastPathComponent.hasPrefix("mpsgraph-\(record.pid)-"),
                      path.lastPathComponent.hasSuffix(".bc.mlir") else { continue }
                var parent = stat(), value = stat()
                guard lstat(path.deletingLastPathComponent().path, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR,
                      lstat(path.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
                      value.st_ino == file.inode, value.st_size >= file.bytes, value.st_uid == geteuid() else { continue }
                try FileManager.default.removeItem(at: path)
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
