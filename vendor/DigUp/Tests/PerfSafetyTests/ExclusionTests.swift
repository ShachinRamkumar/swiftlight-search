import XCTest
@testable import DigUpKit

final class ExclusionTests: XCTestCase {
    func testProtectedLibrariesAreRejectedBeforeWatcherWork() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for relative in ["Music/Music", "Movies/TV", "Pictures/Photo Booth Library",
                         "Pictures/Photos Library.photoslibrary", "Music/Library.musiclibrary",
                         "Movies/Library.tvlibrary", "Movies/iMovie Library.imovielibrary",
                         "Movies/iMovie Theater.theater", "Pictures/Lightroom Library.lrlibrary",
                         "Music/Logic Pro Library.bundle"] {
            let path = home + "/" + relative + "/note.txt"
            XCTAssertFalse(Rules.isWalked(path, root: home, home: home, excluded: []), relative)
        }
        XCTAssertTrue(Rules.isWalked(home + "/Music/Music notes/note.txt", root: home, home: home, excluded: []))
    }

    func testLibraryPackagesNeverEnterFullOrTargetedCrawlsAndArePruned() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("libraries-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let extensions = LibraryExclusions.packageExtensions.union(["xcodeproj", "xcworkspace"])
        var paths: [String] = []
        for ext in extensions {
            let folder = root.appendingPathComponent("Library." + ext)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let note = folder.appendingPathComponent("note.txt")
            try Data("private app data".utf8).write(to: note)
            paths.append(note.path)
        }
        let keep = root.appendingPathComponent("ordinary/keep.txt")
        try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ordinary searchable document".utf8).write(to: keep)
        let alias = root.appendingPathComponent("Library alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Library.photoslibrary"))
        XCTAssertTrue(Crawler.crawl([alias], options: IndexOptions()).candidates.isEmpty)
        let store = try IndexStore(directory: root.appendingPathComponent("index.noindex"))
        for path in paths {
            try store.db.run("INSERT INTO files(path,kind,size,mtime,inode,device) VALUES(?,'doc',0,0,0,0)", [.text(path)])
        }
        let indexer = try Indexer(store: store, options: IndexOptions()) { throw NSError(domain: "unused", code: 1) }
        defer { indexer.finish() }
        XCTAssertTrue(try store.files(under: [root.path]).isEmpty)
        XCTAssertEqual(try indexer.sync([root]).added, 1)
        XCTAssertEqual(try indexer.sync([root], paths: paths).added, 0)
        for path in paths {
            let package = URL(fileURLWithPath: path).deletingLastPathComponent()
            XCTAssertTrue(Crawler.crawl([package], options: IndexOptions()).candidates.isEmpty)
        }
        XCTAssertEqual(try store.files(under: [root.path]).map(\.path), [FolderSelection.realPath(keep.path)])
    }

    func testProtectedHomeNamesAndCaseDoNotMatchOrdinarySiblings() {
        let home = "/fixture/home"
        for relative in ["Music/Music", "Movies/TV", "Pictures/Photo Booth Library"] {
            XCTAssertTrue(LibraryExclusions.contains(home + "/" + relative, home: home))
            XCTAssertTrue(LibraryExclusions.contains(home + "/" + relative.uppercased() + "/child", home: home))
            XCTAssertFalse(LibraryExclusions.contains(home + "/" + relative + " backup/child", home: home))
        }
        XCTAssertTrue(LibraryExclusions.contains(home + "/Pictures/Test.PHOTOSLIBRARY/note.txt", home: home))
    }

    func testExclusionPrunesEveryVectorAndPendingFileBeforeEmbedding() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exclusions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "test", runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
        let model = try store.registerShadow(key: "coreai-eg2-v1", info: info, weightsSHA256: "test")
        let rev = IndexStore.contentRevision("test")
        let vector = Vectors.half([Float(1)] + [Float](repeating: 0, count: 767))
        for (offset, modality) in ["text", "image", "audio", "video"].enumerated() {
            let id = Int64(offset + 1)
            try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device) VALUES(?,?,'doc',0,0,0,0)", [.int(id), .text(root.path + "/excluded.photoslibrary/\(modality).txt")])
            try store.db.run("INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,?,'chunk',?,?)", [.int(id), .int(id), .text(modality), .blob(vector)])
            try store.db.run("INSERT INTO embedding_inputs VALUES(?,'test',?)", [.int(id), .blob(rev)])
            try store.db.run("INSERT INTO vectors VALUES(?,?,?,?,?)", [.int(model), .int(id), .blob(rev), .text(modality), .blob(vector)])
            try store.db.run("INSERT INTO embedding_failures VALUES(?,?,'source_changed',0)", [.int(model), .int(id)])
            try store.db.run("INSERT INTO fts(rowid,name,body) VALUES(?,'test','test')", [.int(id)])
        }
        try store.db.run("INSERT INTO files(path,kind,size,mtime,inode,device) VALUES(?,'doc',0,0,0,0)", [.text(root.path + "/excluded-sibling/keep.txt")])
        var options = IndexOptions()
        options.excludedFolders = []
        let indexer = try Indexer(store: store, options: options) { XCTFail("Excluded work reached embedder"); throw NSError(domain: "test", code: 1) }
        defer { indexer.finish() }
        for table in ["segments", "embedding_inputs", "vectors", "embedding_failures", "fts"] {
            var count: Int64 = -1
            try store.db.query("SELECT COUNT(*) FROM \(table)") { count = $0.int(0) }
            XCTAssertEqual(count, 0, table)
        }
        XCTAssertEqual(try store.files(under: [root.path]).map(\.path), [root.path + "/excluded-sibling/keep.txt"])
        XCTAssertEqual(try store.pruneExcluded(options.excludedFolders), 0)
    }

    func testFullAndWatcherSyncNeverAddExcludedRootsOrChildren() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exclusion-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let note = excluded.appendingPathComponent("note.txt")
        try Data("a searchable note".utf8).write(to: note)
        let store = try IndexStore(directory: root.appendingPathComponent("index.noindex"))
        var options = IndexOptions(); options.excludedFolders = [excluded.path]
        let indexer = try Indexer(store: store, options: options) { throw NSError(domain: "unused", code: 1) }
        defer { indexer.finish() }
        for roots in [[root], [excluded]] {
            XCTAssertEqual(try indexer.sync(roots).added, 0)
            XCTAssertEqual(try indexer.sync(roots, paths: [note.path, excluded.path]).added, 0)
        }
        // An exclusion also prunes rows inserted since startup, even if every watcher target is excluded.
        try store.db.run("INSERT INTO files(path,kind,size,mtime,inode,device) VALUES(?,'doc',0,0,0,0)", [.text(note.path)])
        XCTAssertEqual(try indexer.sync([root], paths: [note.path]).removed, 1)
        XCTAssertTrue(try store.files(under: [root.path]).isEmpty)
        XCTAssertFalse(Rules.isWalked(note.path, root: excluded.path, home: root.path, excluded: options.excludedFolders))
    }
}
