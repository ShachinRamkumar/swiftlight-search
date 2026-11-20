import DigUpKit
import DigUpCoreAIRuntime
import Foundation
#if os(Windows)
import WinSDK
#endif

/// `digup index-service`: the app's indexing helper, one process per stretch of work.
///
/// Extraction (Vision OCR, ImageIO, PDFKit, AVFoundation) runs here and not in the app. Vision alone keeps ~100 MB
/// of models cached in whatever process ran OCR (measured: the app went from 16 to 93 MB after indexing 11
/// screenshots, and stayed there), and all of it goes back to the system when this process exits.
///
/// Protocol: one command per line on stdin, one JSON event per line on stdout.
///   stdin:  sync | sync <path> | sync code | stop | backfill on | backfill off      (EOF = stop)
///           ("sync <path>": only that changed file or folder of the main index; see `Indexer.sync`)
///   stdout: {"event": "missing" | "pruned" | "sync" | "file" | "rest" | "summary" | "waiting" | "idle" | "error" |
///            "exit", ...}; events about the code index say "code": true
///
/// The loop: sync, index what the sync just queued (if it's a few files: new files go first, on any power source),
/// then the backfill if allowed; then the code index the same way (`--code-root`: its own sync, asked for with
/// "sync code"; its folders are crawled with the first sync, so their counts show at once); then the rest of long
/// files (`Indexer.finishLongFiles`) under the same rules. This launcher's build finishes long files before the
/// backfill: a course book's later chapters matter more to it than a backlog's first pages. Between batches it yields to stop and to "backfill off" at
/// once, and to a new sync once indexing has had about as long as the last sync took (`yieldAt`). When it's done it
/// keeps a warm worker for `linger` seconds (screenshots come in bursts), then exits.
///
/// Before the model has downloaded it only syncs (file names are searchable at once), says it's "waiting", and exits.
/// Folders that aren't there (an unplugged drive) or can't be read are skipped, and what was indexed from them stays.
/// That's checked before every sync, not once: a drive ejected while this runs must not crawl as "all deleted".
final class IndexService: @unchecked Sendable {
    /// One index: its store, its indexer, its folders.
    struct Part {
        let store: IndexStore
        let indexer: Indexer
        /// The chosen folders, there or not.
        let roots: [URL]
        /// When set, files under none of these folders leave the index (folders taken out of the app).
        let keepOnly: [URL]?
        var code: Bool { store.file.lastPathComponent == IndexStore.codeFile }
    }

    private let main: Part
    /// The code index (`--code-root`), when there are code folders.
    private let code: Part?
    /// The index folder (where `Watchdog` leaves a note about a file it stopped on).
    private let folder: URL
    private let model: SharedEmbedder
    /// The last report of folders that aren't there or can't be read, by index (said again only when it changes).
    private let rootAccess = RootAccess()
    private var accessReports: [URL: RootAccess.State] = [:]
    private let modelReady: () -> Bool
    private let newFilesLimit: Int
    private let linger: Double
    private let readsInput: Bool

    private let lock = NSLock()
    private var syncRequested = true       // the first thing it does, unless the app says what to sync
    /// Changed files and folders to sync ("sync <path>"), when no full sync is asked for.
    private var syncFolders = Set<String>()
    private var codeSyncRequested = true
    private var stopRequested = false
    private var coreAIFailed = false
    private var lastProgress = Date.distantPast
    private var backfillAllowed: Bool
    /// A sync asked for while files are being indexed waits until then. A crawl of a big folder can take minutes, and
    /// a folder that keeps changing asks for the next one meanwhile: yielding at once, every pass went back to crawling
    /// before a single file was read. Indexing gets at least as long as the sync before it (2 s at the least).
    private var yieldAt = Date.distantPast
    private let wake = DispatchSemaphore(value: 0)

    init(main: Part, code: Part?, folder: URL, model: SharedEmbedder, modelReady: @escaping () -> Bool,
         backfill: Bool, newFilesLimit: Int, linger: Double, firstSync: Bool = true,
         initialPaths: [String]? = nil, readsInput: Bool = true) {
        self.main = main
        self.code = code
        self.folder = folder
        self.model = model
        self.modelReady = modelReady
        self.backfillAllowed = backfill
        self.newFilesLimit = newFilesLimit
        self.linger = linger
        self.syncRequested = initialPaths == nil && firstSync
        self.syncFolders = Set(initialPaths ?? [])
        self.firstSync = firstSync || initialPaths != nil
        self.readsInput = readsInput
    }
    private let firstSync: Bool

    /// A full or a partial sync is waiting (call with `lock` held).
    private var anySyncRequested: Bool { syncRequested || !syncFolders.isEmpty }

    private var parts: [Part] { [main] + (code.map { [$0] } ?? []) }

    /// Pending files past which long files are finished first.
    static let bigBacklog = 500

    func serve() -> Int32 {
        removeStaleScratchFolders()
        do {
            // A file an earlier helper had to stop on (`Watchdog`) isn't read again until it changes.
            if let stopped = StoppedFile.take(from: folder), let path = stopped.path {
                for part in parts {
                    guard try part.store.markStopped(path, why: stopped.why) else { continue }
                    emit(["event": "stopped", "path": path, "why": stopped.why, "code": part.code])
                }
            }
            let again = try main.store.readAgainOnce()   // what older indexes couldn't read: scans' words, SVGs
            if again > 0 { emit(["event": "rescan", "files": again]) }
            if let compacted = try main.store.compactIfSparse() {
                emit(["event": "compacted", "before": compacted.before, "after": compacted.after])
            }
            for part in parts {
                try part.indexer.checkModel()   // a new model: everything is queued again
                if let keepOnly = part.keepOnly {
                    let pruned = try part.store.prune(keepingUnder: keepOnly.map(\.path))
                    if pruned > 0 { emit(["event": "pruned", "files": pruned, "code": part.code]) }
                }
            }
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            finish()
            return 1
        }
        if readsInput { Thread.detachNewThread { [self] in readCommands() } }
        // Told what to sync (--wait-for-sync) and nothing left to read: the app's first command is on its way.
        if !firstSync, (try? main.store.pendingCount()) ?? 0 == 0, (try? main.store.unfinishedCount().files) ?? 0 == 0 {
            _ = wake.wait(timeout: .now() + 10)
        }
        var newFiles = Set<Int64>(), newCode = Set<Int64>()
        var codeCounted = code == nil
        while true {
            let mainHasWork = ((try? main.store.pendingCount()) ?? 0) > 0
                || ((try? main.store.unfinishedCount().files) ?? 0) > 0
            if let folders = lock.withLock({ () -> [String]?? in
                guard anySyncRequested, Date() >= yieldAt || !mainHasWork else { return nil }
                defer { syncRequested = false; syncFolders = [] }
                return syncRequested ? .some(nil) : .some(syncFolders.sorted())
            }) {
                sync(main, into: &newFiles, folders: folders)
            }
            // The code folders are crawled with the first sync, so their counts show from the start (a big first pass
            // of the main index takes hours); their files are read once the main index has nothing waiting, below.
            if !codeCounted, let code {
                codeCounted = true
                if lock.withLock({ () -> Bool in defer { codeSyncRequested = false }; return codeSyncRequested }) {
                    sync(code, into: &newCode)
                }
            }
            if lock.withLock({ stopRequested }) { break }
            guard modelReady() else {
                // Nothing to embed with yet; the app starts another helper once the download is done.
                emitCounts("waiting", ["for": "model"])
                break
            }
            if model.isPreparing {
                do {
                    try main.indexer.prepareKeywords(whilePreparing: { self.model.isPreparing },
                        shouldStop: { self.lock.withLock { self.stopRequested } }, onFile: { path in
                            emit(["event": "keyword_ready", "path": path])
                        })
                    emitCounts("preparing", ["for": "semantic models", "keyword_search": "ready"])
                } catch { emit(["event": "error", "message": "keyword preparation: \(error)"]) }
            }
            if !newFiles.isEmpty {
                guard run(main, only: newFiles) else { break }
                newFiles = left(main, of: newFiles)
                continue
            }
            // The rest of long PDFs and documents goes before a big backlog (days of files would hold a book's later
            // chapters back), after a small one (a few new or retried files get their first pages sooner).
            if lock.withLock({ backfillAllowed }), (try? main.store.pendingCount()) ?? 0 > Self.bigBacklog,
               (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                guard finishLongFiles() else { break }
                if lock.withLock({ anySyncRequested || codeSyncRequested }) { continue }
            }
            if (try? main.store.pendingCount()) ?? 0 > 0, lock.withLock({ backfillAllowed }) {
                guard run(main, only: nil) else { break }
                if lock.withLock({ anySyncRequested }) { continue }
            }
            // The code index once the main one has nothing waiting: its own sync (code changes come in a while after
            // they settle), what it just queued at once, the rest under the backfill's rules.
            if let code, (try? main.store.pendingCount()) ?? 1 == 0 || !lock.withLock({ backfillAllowed }) {
                if lock.withLock({ () -> Bool in defer { codeSyncRequested = false }; return codeSyncRequested }) {
                    sync(code, into: &newCode)
                }
                if !newCode.isEmpty {
                    guard run(code, only: newCode) else { break }
                    newCode = left(code, of: newCode)
                    continue
                }
                if (try? code.store.pendingCount()) ?? 0 > 0, lock.withLock({ backfillAllowed }) {
                    guard run(code, only: nil) else { break }
                    if lock.withLock({ anySyncRequested || codeSyncRequested }) { continue }
                }
            }
            // Pictures indexed before pictures had tags (`ImageTags`) get them once nothing new is waiting: a minute or
            // two for thousands, 100 at a time between syncs.
            if lock.withLock({ backfillAllowed }), (try? main.store.pendingCount()) ?? 1 == 0 {
                do {
                    let tagged = try main.indexer.tagOlderPictures(limit: 100)
                    if tagged > 0 {
                        emit(["event": "tagged", "files": tagged])
                        continue
                    }
                } catch {
                    emit(["event": "error", "message": "tagging pictures failed: \(error)"])
                }
            }
            // Once nothing is waiting: the rest of long PDFs and documents, the same way.
            if lock.withLock({ backfillAllowed }), (try? main.store.pendingCount()) ?? 1 == 0,
               (try? code?.store.pendingCount() ?? 0) ?? 1 == 0, (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                guard finishLongFiles() else { break }
                if lock.withLock({ anySyncRequested || codeSyncRequested }) { continue }
            }
            if code != nil, lock.withLock({ codeSyncRequested }) { continue }
            if lock.withLock({ anySyncRequested }) { continue }   // asked for while this pass ran
            emitCounts("idle")
            // Nothing warm to keep around: leave now. Else wait a little for more work.
            guard model.isRunning, waitForWork() else { break }
        }
        finish()
        emit(["event": "exit"])
        return coreAIFailed ? 1 : 0
    }

    private func finish() {
        for part in parts {
            part.indexer.finish()
            if let target = part.store.indexingModel {
                do {
                    let unfinished = try part.store.pendingCount() > 0 || part.store.unfinishedCount().files > 0
                    let complete = try !unfinished && part.store.finishShadowIfCovered(model: target)
                    emit(["event": "model_coverage", "model": target, "complete": complete, "code": part.code])
                } catch { emit(["event": "error", "message": "Core AI coverage: \(error)"]) }
            }
        }
        model.close()
        if model.preparationFailed { coreAIFailed = true }
    }

    /// New files a run stopped before (a sync or stop came first): kept for the next round. Done: anything still
    /// pending joins the backfill.
    private func left(_ part: Part, of files: Set<Int64>) -> Set<Int64> {
        let yielded = lock.withLock { anySyncRequested || stopRequested || (part.code && codeSyncRequested) }
        return yielded ? Set((try? part.store.pending(limit: nil, only: files).map(\.id)) ?? []) : []
    }

    /// Scratch folders ($TMPDIR/DigUp-<pid>) of indexing processes that are gone (killed mid-batch).
    private func removeStaleScratchFolders() {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] {
            guard name.hasPrefix("DigUp-"), let pid = Int32(name.dropFirst("DigUp-".count)),
                  pid != ProcessInfo.processInfo.processIdentifier, Self.isGone(pid) else { continue }
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    /// No process has this id now.
    private static func isGone(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return true }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        return GetExitCodeProcess(process, &code) && code != 259   // STILL_ACTIVE
        #else
        return kill(pid, 0) != 0 && errno == ESRCH
        #endif
    }

    /// A part's chosen folders that are there and readable right now; also what `pending` and the counts look at.
    private func availableRoots(_ part: Part) -> [URL] {
        var packages: [String: Bool] = [:]
        let safeRoots = part.roots.filter { !LibraryExclusions.containsPackage($0.path, cache: &packages) }
        let states = rootAccess.check(safeRoots)
        for root in safeRoots {
            let state = states[root]!
            if accessReports[root] != state {
                emit(["event": "access", "path": root.path, "state": state.rawValue,
                      "needs_access": state == .pending || state == .denied, "code": part.code])
                accessReports[root] = state
            }
        }
        let unavailable = safeRoots.filter { states[$0] != .ready }.map(\.path)
        let available = safeRoots.filter { states[$0] == .ready }
        part.store.scope = available.map(\.path)
        part.store.unavailableFolders = unavailable
        return available
    }

    private func sync(_ part: Part, into newFiles: inout Set<Int64>, folders: [String]? = nil) {
        let started = Date()
        defer {
            let took = Date().timeIntervalSince(started)
            lock.withLock { yieldAt = Date() + max(took, 2) }
        }
        do {
            let summary = try part.indexer.sync(availableRoots(part), paths: folders, unavailable: part.store.unavailableFolders)
            for (path, state) in summary.crawl.directoryAccess {
                let url = URL(fileURLWithPath: path)
                guard accessReports[url] != state else { continue }
                accessReports[url] = state
                emit(["event": "access", "path": path, "state": state.rawValue,
                      "needs_access": state == .pending || state == .denied, "code": part.code, "depth_check": true])
            }
            if summary.queued.count <= newFilesLimit { newFiles.formUnion(summary.queued) }
            emitCounts("sync", [
                "code": part.code,
                "new": newFiles.count,   // about to be indexed, whatever the power source
                "added": summary.added, "changed": summary.changed, "moved": summary.moved,
                "removed": summary.removed, "unchanged": summary.unchanged,
                "ms": Int(Date().timeIntervalSince(started) * 1000),
                "access_checks": summary.crawl.accessChecks,
                "access_ms": summary.crawl.accessSeconds * 1000,
                "paths": folders?.count ?? 0,   // 0: everything
                "started": started.timeIntervalSince1970,   // the app checks its sync request came before this
            ])
        } catch {
            emit(["event": "error", "message": "sync failed: \(error)", "code": part.code])
        }
    }

    /// Embeds a part's pending files (`only` some). False when indexing has to stop (the worker died, or the index was
    /// built with other settings).
    private func run(_ part: Part, only ids: Set<Int64>?) -> Bool {
        let started = Date()
        let isNew = ids != nil
        do {
            let states = try part.indexer.run(only: ids, shouldStop: { [self] in
                lock.withLock {
                    stopRequested || (!isNew && !backfillAllowed)
                        || Date() >= yieldAt && (anySyncRequested || part.code && codeSyncRequested)
                }
            }, onEvent: { event in
                emit(["event": "file", "new": isNew, "done": event.done, "total": event.total, "path": event.path,
                      "kind": event.kind.rawValue, "state": event.state, "seconds": event.seconds,
                      "note": event.note ?? "", "code": part.code])
                reportProgress(part, force: event.done == event.total)
            })
            if !states.isEmpty {
                emit(["event": "summary", "new": isNew, "states": states, "code": part.code,
                      "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
            return true
        } catch {
            if !lock.withLock({ stopRequested }) {
                emit(["event": "error", "message": "\(error)", "fatal": true, "code": part.code])
                if part.store.indexingModel != nil { coreAIFailed = true }
            }
            return false
        }
    }

    /// The rest of long files (`Indexer.finishLongFiles`), yielding as the backfill does. False when indexing has to
    /// stop.
    private func finishLongFiles() -> Bool {
        let started = Date()
        do {
            let states = try main.indexer.finishLongFiles(shouldStop: { [self] in
                lock.withLock {
                    stopRequested || !backfillAllowed
                        || Date() >= yieldAt && (anySyncRequested || codeSyncRequested && code != nil)
                }
            }, onStep: { step in
                emit(["event": "rest", "done": step.done, "total": step.total, "files": step.files, "path": step.path,
                      "kind": step.kind.rawValue, "state": step.state, "seconds": step.seconds, "note": step.note ?? ""])
                reportProgress(main, force: step.done == step.total)
            })
            if !states.isEmpty {
                emit(["event": "summary", "rest": true, "states": states,
                      "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
            return true
        } catch {
            if !lock.withLock({ stopRequested }) {
                emit(["event": "error", "message": "\(error)", "fatal": true])
                if main.store.indexingModel != nil { coreAIFailed = true }
            }
            return false
        }
    }

    /// Waits up to `linger` seconds for something to do. False: time's up, or told to stop.
    private func waitForWork() -> Bool {
        let deadline = DispatchTime.now() + linger
        while wake.wait(timeout: deadline) == .success {
            let (sync, codeSync, stop, backfill) = lock.withLock {
                (anySyncRequested, codeSyncRequested, stopRequested, backfillAllowed)
            }
            if stop { return false }
            if sync || codeSync && code != nil { return true }
            if backfill, parts.contains(where: { (try? $0.store.pendingCount()) ?? 0 > 0 })
                || (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                return true
            }
        }
        return false
    }

    private func readCommands() {
        while let line = readLine() {
            lock.withLock {
                let command = line.trimmingCharacters(in: .whitespaces)
                switch command {
                case "sync": syncRequested = true
                case _ where command.hasPrefix("sync /"): syncFolders.insert(String(command.dropFirst("sync ".count)))
                case "sync code": codeSyncRequested = true
                case "stop": stopRequested = true; model.control.command("stop")
                case "pause", "resume": model.control.command(command)
                case "backfill on": backfillAllowed = true
                case "backfill off": backfillAllowed = false
                default: break
                }
            }
            wake.signal()
        }
        lock.withLock { stopRequested = true }; model.control.command("stop")   // the app went away
        wake.signal()
    }

    /// An event with both indexes' counts: the main one's as they are, the code index's prefixed "code_".
    private func reportProgress(_ part: Part, force: Bool) {
        guard let model = part.store.indexingModel, force || Date().timeIntervalSince(lastProgress) >= 5 else { return }
        lastProgress = Date()
        do {
            var total = 0, finished = 0, semantic = 0
            try part.store.db.query("SELECT COUNT(*),SUM(state IN ('done','skipped','failed')) FROM files") {
                total = Int($0.int(0)); finished = Int($0.int(1))
            }
            try part.store.db.query("SELECT COUNT(DISTINCT s.file) FROM vectors v JOIN segments s ON s.id=v.segment WHERE v.model=?", [.int(model)]) { semantic = Int($0.int(0)) }
            let percent = total == 0 ? 100 : finished * 100 / total
            emitCounts("progress", ["percent": percent, "semantic_files": semantic,
                                   "semantic_percent": total == 0 ? 0 : semantic * 100 / total])
            readinessLog("Indexing \(percent)%. Semantic coverage: \(semantic) of \(total) files.")
        } catch { readinessLog("Progress unavailable: \(error)") }
    }

    private func emitCounts(_ event: String, _ extra: [String: Any] = [:]) {
        var fields = extra
        fields["event"] = event
        for part in parts {
            guard let counts = try? part.store.counts() else { continue }
            let prefix = part.code ? "code_" : ""
            var files = 0, searchable = 0, pending = 0
            for states in counts.byKindAndState.values {
                for (state, count) in states {
                    files += count
                    if state == "done" || state == "partial" { searchable += count }
                    if state == "pending" { pending += count }
                }
            }
            fields[prefix + "files"] = files
            fields[prefix + "searchable"] = searchable
            fields[prefix + "pending"] = pending
            fields[prefix + "vectors"] = counts.vectors
            if !part.code { fields["unfinished"] = counts.unfinished }   // long files with pages or chunks left to read
        }
        emit(fields)
    }
}

/// One model for both indexes, started when the first file needs it and closed when the helper is done. The indexers
/// get it as an `Embedder` whose `close` leaves it be, since the other may be using it.
final class SharedEmbedder: @unchecked Sendable {
    private let make: () throws -> any Embedder
    private var model: (any Embedder)?
    private let preparation = NSCondition()
    private var preparing = false
    private var preparationFailure: String?
    let control=ModelCallControl()

    init(_ make: @escaping () throws -> any Embedder) {
        self.make = make
    }

    @available(macOS 27, *)
    init(coreAIRuntime: RuntimeDirectory) {
        let functions = ["q32", "d256"]
        let control = self.control
        self.make = { try coreAIRuntime.embedder(.document, inferenceGate: { try control.waitForModelCall() }) }
        preparing = true
        readinessLog("Preparing models: query first, then documents. Media prepares when needed.")
        RuntimeReadiness.record(coreAIRuntime, role: "index", status: "preparing", functions: functions)
        Thread.detachNewThread { [self] in
            do {
                if coreAIRuntime.assets.names == ["EmbeddingGemma2.aimodel"] && !coreAIRuntime.hasCompleteSetupCheckpoint {
                    try coreAIRuntime.prepareSingleModel { phase in
                        emit(["event": "index-readiness", "state": "preparing", "phase": phase.rawValue, "message": phase.message])
                    }
                }
                let ready = try coreAIRuntime.embedder(.document, prepareQueryFirst: true, inferenceGate: { try control.waitForModelCall() })
                RuntimeReadiness.record(coreAIRuntime, role: "index", status: "ready", functions: functions)
                readinessLog("index ready")
                emit(["event": "index-readiness", "state": "ready"])
                preparation.lock(); model = ready; preparing = false
                preparation.broadcast(); preparation.unlock()
            } catch {
                RuntimeReadiness.record(coreAIRuntime, role: "index", status: "failed", functions: functions, failure: String(describing: error))
                readinessLog("index preparation failed: \(error)")
                emit(["event": "index-readiness", "state": "failed", "message": String(describing: error)])
                preparation.lock(); preparationFailure = String(describing: error); preparing = false
                preparation.broadcast(); preparation.unlock()
            }
        }
    }

    var isRunning: Bool {
        preparation.lock(); defer { preparation.unlock() }
        return preparing || model != nil
    }

    var isPreparing: Bool {
        preparation.lock(); defer { preparation.unlock() }
        return preparing
    }

    var preparationFailed: Bool {
        preparation.lock(); defer { preparation.unlock() }
        return preparationFailure != nil
    }

    func embedder() throws -> any Embedder {
        try control.waitForModelCall()
        preparation.lock()
        defer { preparation.unlock() }
        while preparing { preparation.wait() }
        if let preparationFailure { throw WorkerError.failed("Core AI index readiness failed: \(preparationFailure)") }
        if model == nil { model = try make() }
        return Kept(model!, control:control)
    }

    func close() {
        preparation.lock()
        defer { preparation.unlock() }
        while preparing { preparation.wait() }
        model?.close()
        model = nil
    }

    private final class Kept: VideoClipEmbedder {
        let model: any Embedder
        let control: ModelCallControl
        init(_ model: any Embedder, control: ModelCallControl) { self.model = model; self.control=control }
        var info: WorkerInfo { model.info }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { try control.waitForModelCall(); return try model.embedTexts(texts) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            try control.waitForModelCall(); return try model.embedImages(paths, budget: budget)
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] { try control.waitForModelCall(); return try model.embedAudio(paths) }
        func embedVideoFrames(_ frames: [RGBImage]) throws -> [Float] {
            try control.waitForModelCall()
            guard let video = model as? any VideoClipEmbedder else { throw WorkerError.failed("worker does not support clips") }
            return try video.embedVideoFrames(frames)
        }
        func close() {}
    }
}

/// One JSON object per line on stdout, written straight to the file descriptor (print() would buffer in a pipe).
/// The app may be gone by now (it quit while this helper lingered): a closed pipe is an error to ignore here, not the
/// exception that `write(_:)` raises, which used to crash the helper on its way out.
func emit(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data + [0x0A])
}

private final class IndexServiceResult: @unchecked Sendable { var value: Result<Int32, Error>? }
func runIndexService(_ args: Arguments) throws -> Int32 {
    let box = IndexServiceResult(), done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do { box.value = .success(try indexService(args)) }
        catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}
