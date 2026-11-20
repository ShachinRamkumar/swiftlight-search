import Foundation
import Darwin

/// The frontend migrates before opening its log or starting any helper.
enum SupportDirectory {
    static func prepare(parent: URL) throws -> URL {
        let fm = FileManager.default
        let destination = parent.appendingPathComponent("Swiftlight", isDirectory: true)
        let legacy = parent.appendingPathComponent("SpotlightFSearch", isDirectory: true)
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) {
            // RENAME_EXCL prevents a concurrent first launch from replacing a destination.
            // Unlike moveItem, this cannot fall back to a cross-volume copy and delete.
            let result = legacy.path.withCString { source in
                destination.path.withCString { target in
                    renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_EXCL))
                }
            }
            if result != 0 {
                let code = errno
                guard code == EEXIST || (code == ENOENT && fm.fileExists(atPath: destination.path)) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
            } else {
                let log = destination.appendingPathComponent("launcher.log")
                if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("Swiftlight migrated data directory: \(legacy.path) -> \(destination.path)\n".utf8))
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }
}
