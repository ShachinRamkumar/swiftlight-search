import Foundation

/// These checks must precede directory reads, including for explicit roots and watcher targets.
public enum LibraryExclusions {
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary",
        "migratedphotolibrary", "aplibrary", "tvlibrary", "imovielibrary", "theater", "lrlibrary"
    ]

    public static func contains(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let path = (path as NSString).standardizingPath
        let home = (home as NSString).standardizingPath.lowercased()
        let lower = path.lowercased()
        for relative in ["Library", "Music/Music", "Movies/TV", "Pictures/Photo Booth Library"] {
            let folder = home + "/" + relative.lowercased()
            if lower == folder || lower.hasPrefix(folder + "/") { return true }
        }
        return path.split(separator: "/").contains {
            packageExtensions.contains((String($0) as NSString).pathExtension.lowercased())
        }
    }

    /// Catch packages registered by macOS as well as the library suffixes above. Cache shared ancestors per pass.
    public static func containsPackage(_ path: String, cache: inout [String: Bool]) -> Bool {
        if contains(path) || contains(FolderSelection.realPath(path)) { return true }
        var folder = (path as NSString).standardizingPath
        var ancestors: [String] = []
        while folder.count > 1 {
            ancestors.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for folder in ancestors.reversed() {
            if let known = cache[folder] {
                if known { return true }
                continue
            }
            let url = URL(fileURLWithPath: folder)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let package = values?.isDirectory == true && values?.isPackage == true
            cache[folder] = package
            if package { return true }
        }
        return false
    }
}
