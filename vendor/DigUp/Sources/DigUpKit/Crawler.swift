import Foundation

/// A file the crawler decided to index.
public struct Candidate: Sendable {
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
}

public struct CrawlReport: Sendable {
    public var candidates: [Candidate] = []
    public var skipped: [String: Int] = [:]          // reason → files
    public var skippedFolders: [String: Int] = [:]   // reason → folders not walked into
    public var directoryAccess: [String: RootAccess.State] = [:]
    public var accessChecks = 0
    public var accessSeconds: Double = 0
    public var datasets: [String: Int] = [:]         // folder → files skipped as a dataset
}

/// Walks the chosen folders and applies `Rules`. Reads metadata only, never file contents (except the 600-byte
/// sniff that tells a real MPEG-TS video from a TypeScript file).
///
/// For the code index (`IndexOptions.code`) it walks the code folders instead: code files only (`Rules.classifyCode`),
/// in a git repo only those git keeps (`GitFiles`), and none in vendored or built folders.
public enum Crawler {
    /// `chosen`: when `roots` are changed folders inside the chosen ones (a partial sync), the chosen folders. A folder
    /// inside a code project or a dataset is then treated as it is in a full crawl.
    public static func crawl(_ roots: [URL], options: IndexOptions, chosen: [URL]? = nil,
                             access: RootAccess = RootAccess()) -> CrawlReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let keys = FileSystem.crawlKeys
        var report = CrawlReport()
        var projectRoots = Set<String>()
        var repos = GitRepos()
        var found: [Candidate] = []
        var packages: [String: Bool] = [:]
        var foundPaths = Set<String>()   // a folder inside another root would be walked twice
        let rootPaths = Set((chosen ?? roots).map { $0.standardizedFileURL.path })

        func readable(_ url: URL) -> Bool {
            let started = Date()
            let state = access.check([url])[url]!
            report.accessChecks += 1
            report.accessSeconds += Date().timeIntervalSince(started)
            report.directoryAccess[url.path] = state
            if state != .ready {
                report.skippedFolders["access " + state.rawValue, default: 0] += 1
            }
            return state == .ready
        }

        for root in roots.map({ $0.standardizedFileURL }) {
            if LibraryExclusions.containsPackage(root.path, cache: &packages) { continue }
            let allSkips = options.excludedFolders.flatMap { [$0, FolderSelection.realPath($0)] }
            let realRoot = FolderSelection.realPath(root.path)
            if allSkips.contains(where: { root.path == $0 || FolderSelection.isInside(root.path, $0)
                || realRoot == $0 || FolderSelection.isInside(realRoot, $0) }) { continue }
            if LibraryExclusions.containsPackage(realRoot, cache: &packages) { continue }
            if !Self.shallowDirectories(to: root, roots: chosen ?? roots).allSatisfy(readable) { continue }
            if options.code || options.includeCode {
                repos.enterRoot(root.path)
            } else if Rules.isProjectRoot(root.path) || Self.insideProject(root.path, chosen: chosen) {
                // The walk reports real paths (/private/tmp where the root says /tmp).
                projectRoots.formUnion([root.path, FolderSelection.realPath(root.path)])
            }
            // The walk reports real paths (/private/var, where the root says /var).
            let real = FolderSelection.realPath(root.path)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root.path) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            #if os(Windows)
            guard let walker = FileSystem.walk(root, keys: keys) else { continue }
            #else
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in true }) else { continue }
            #endif
            func visit(_ url: URL) {
                if LibraryExclusions.contains(url.path) {
                    walker.skipDescendants()
                    report.skipped["app or media-library bundle", default: 0] += 1
                    return
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { walker.skipDescendants(); return }
                let isPackage = FileSystem.isPackage(url, values)
                if values?.isDirectory == true, !isPackage {
                    if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                    } else if walker.level <= 2 && !readable(url) {
                        walker.skipDescendants()
                    } else if let reason = (options.code || options.includeCode)
                        ? Rules.codeSkipReason(forFolder: url)
                        : Rules.foreignReason(forFolder: url, owners: options.ownGitOwners) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                    } else if options.code || options.includeCode {
                        repos.enter(url.path)
                    } else if Rules.isProjectRoot(url.path) {
                        projectRoots.insert(url.path)
                    }
                    return
                }
                if isPackage {
                    walker.skipDescendants()   // macOS's enumerator never enters one; elsewhere it would
                    report.skipped["app or bundle", default: 0] += 1
                    return
                }
                let classification = options.code ? Rules.classifyCode(url, options: options)
                    : Rules.classify(url, values: values, options: options)
                switch classification {
                case .ignore:
                    report.skipped["other type", default: 0] += 1
                case .skip(let reason):
                    report.skipped[reason, default: 0] += 1
                case .index(let kind):
                    if options.skippedKinds.contains(kind) {
                        report.skipped["\(kind.rawValue) turned off", default: 0] += 1
                        return
                    }
                    guard let info = FileSystem.info(of: url.path), info.isRegular else {
                        report.skipped["link or special file", default: 0] += 1
                        return
                    }
                    // Reading a dataless placeholder (iCloud "Optimize Mac Storage", File Providers) downloads it.
                    if info.dataless || FileSystem.isInCloud(values) {
                        report.skipped["in the cloud, not downloaded", default: 0] += 1
                        return
                    }
                    if kind == .code {
                        // Too big to be written by hand; a notebook's file holds its outputs too.
                        let limit = url.pathExtension.lowercased() == "ipynb" ? options.maxNotebookBytes
                            : options.maxCodeBytes
                        if info.size > limit {
                            report.skipped["too big to be written by hand", default: 0] += 1
                            return
                        }
                        if repos.ignores(url.path) {
                            report.skipped["ignored by git", default: 0] += 1
                            return
                        }
                    }
                    guard foundPaths.insert(url.path).inserted else { return }
                    found.append(Candidate(path: url.path, kind: kind, size: info.size, mtime: info.mtime,
                                           inode: info.inode, device: info.device))
                }
            }

            // URL resource values are autoreleased; draining per file keeps a big walk from piling them up (the app
            // crawls on a background queue whose pool only drains when the whole sync is done).
            while let url = autoreleasepool(invoking: { walker.nextObject() as? URL }) {
                autoreleasepool {
                    visit(url)
                }
            }
        }

        // The default crawl avoids project assets. Including code also enables supported media in projects.
        var inProject: [String: Bool] = [:]
        func isInProject(_ folder: String) -> Bool {
            if let known = inProject[folder] { return known }
            let parent = (folder as NSString).deletingLastPathComponent
            let answer = projectRoots.contains(folder) || (parent != folder && parent.count > 1 && isInProject(parent))
            inProject[folder] = answer
            return answer
        }
        var kept: [Candidate] = []
        for file in found {
            if !options.code, !options.includeCode, ![.doc, .pdf, .screenshot].contains(file.kind), isInProject((file.path as NSString).deletingLastPathComponent) {
                report.skipped["inside a code project", default: 0] += 1
            } else {
                kept.append(file)
            }
        }

        if !options.includeDatasets, !options.code {
            let datasets = Rules.datasetFolders(kept.map {
                (($0.path as NSString).deletingLastPathComponent,
                 (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension, $0.kind)
            }, roots: rootPaths)
            if !datasets.isEmpty {
                report.datasets = datasets
                kept.removeAll { file in
                    let skip = datasets[(file.path as NSString).deletingLastPathComponent] != nil
                        && [.image, .audio, .video].contains(file.kind)
                    if skip { report.skipped["dataset", default: 0] += 1 }
                    return skip
                }
            }
        }
        report.candidates = kept
        return report
    }
}

extension Crawler {
    static func shallowDirectories(to directory: URL, roots: [URL]) -> [URL] {
        let directory = URL(fileURLWithPath: FolderSelection.realPath(directory.standardizedFileURL.path))
        guard let root = roots.map({ URL(fileURLWithPath: FolderSelection.realPath($0.standardizedFileURL.path)) })
            .filter({ directory.path == $0.path || FolderSelection.isInside(directory.path, $0.path) })
            .max(by: { $0.path.count < $1.path.count }) else { return [directory] }
        var result = [root], current = root
        for component in directory.path.dropFirst(root.path.count).split(separator: "/").prefix(2) {
            current.appendPathComponent(String(component))
            result.append(current)
        }
        if result.last != directory { result.append(directory) }
        return result
    }

    public enum Alone { case index(Candidate), folder, skip }

    /// A changed file of a partial sync, looked at alone: documents, PDFs and screenshots are indexed wherever they
    /// are (no project or dataset rule leaves them out), so their own facts decide. Other kinds need their folder's
    /// crawl (`.folder`), as does everything when code is indexed (git decides there).
    public static func alone(_ path: String, options: IndexOptions) -> Alone {
        if LibraryExclusions.contains(path) { return .skip }
        if options.code || options.includeCode { return .folder }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: Set(FileSystem.crawlKeys))
        guard case .index(let kind) = Rules.classify(url, values: values, options: options),
              !options.skippedKinds.contains(kind) else { return .skip }
        guard [.doc, .pdf, .screenshot].contains(kind) else { return .folder }
        guard let info = FileSystem.info(of: path), info.isRegular, !info.dataless, !FileSystem.isInCloud(values)
        else { return .skip }
        return .index(Candidate(path: path, kind: kind, size: info.size, mtime: info.mtime, inode: info.inode,
                                device: info.device))
    }

    /// Whether a folder of a partial crawl is inside a code project below its chosen folder.
    static func insideProject(_ path: String, chosen: [URL]?) -> Bool {
        guard let root = chosen?.map(\.standardizedFileURL.path)
            .filter({ FolderSelection.isInside(path, $0) }).max(by: { $0.count < $1.count }) else { return false }
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count >= root.count, folder.hasPrefix(root) {
            if Rules.isProjectRoot(folder) { return true }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder else { break }
            folder = parent
        }
        return false
    }
}

/// The git repos a code crawl walks through, and the files each keeps (`GitFiles`): a file git ignores (a build, an
/// environment, data, a secret listed in .gitignore) isn't code search's to read. A folder that isn't in a repo, or a
/// Mac without git, has no list: everything there counts.
struct GitRepos {
    /// Repo folder → the files git keeps in it (paths relative to it), or nil when git couldn't say.
    private var files: [String: Set<String>?] = [:]
    /// Folder → the repo it's in (nil: none), as the walk found them.
    private var repoOf: [String: String?] = [:]

    /// A chosen folder: a repo itself, or inside one (a repo's subfolder chosen on its own).
    mutating func enterRoot(_ path: String) {
        var folder = path
        while true {
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                files[folder] = GitFiles.list(folder)
                repoOf[path] = folder
                return
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, parent.count > 1 else { break }
            folder = parent
        }
        repoOf[path] = .some(nil)
    }

    /// A folder the walk goes into: a repo of its own when it has a .git folder (a submodule's or a worktree's .git
    /// file keeps it out of the walk: `Rules.codeSkipReason`).
    mutating func enter(_ path: String) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), isFolder.boolValue {
            files[path] = GitFiles.list(path)
            repoOf[path] = path
        }
    }

    /// The repo `folder` is in, from the closest folder the walk has seen.
    private mutating func repo(of folder: String) -> String? {
        if let known = repoOf[folder] { return known }
        let parent = (folder as NSString).deletingLastPathComponent
        let answer = parent != folder && parent.count > 1 ? repo(of: parent) : nil
        repoOf[folder] = answer
        return answer
    }

    /// Whether git ignores the file at `path` (in a repo whose files git listed).
    mutating func ignores(_ path: String) -> Bool {
        guard let repo = repo(of: (path as NSString).deletingLastPathComponent), let kept = files[repo] ?? nil
        else { return false }
        return !kept.contains(String(path.dropFirst(repo.count + 1)))
    }
}

/// The files git keeps in a repo: tracked ones, and new ones its .gitignore doesn't leave out.
enum GitFiles {
    /// Paths relative to `repo`, or nil when git can't say (no git, not a repo, an error). The git is `FileSystem.git`.
    static func list(_ repo: String) -> Set<String>? {
        guard let git = FileSystem.git else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        // Reading only: never wait for, or take, the repo's lock (an editor's git may be busy in it).
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }
}
