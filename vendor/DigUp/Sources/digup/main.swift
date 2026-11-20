import DigUpKit
import DigUpCoreAIRuntime
import Foundation

// DigUp's developer CLI. Every command works on an explicit index folder, so tests never touch the real one.

#if !os(Windows)
signal(SIGPIPE, SIG_IGN)   // a dead worker must surface as an error, not kill us (Windows has no SIGPIPE)
#endif

let usage = """
    digup: search your files by meaning (DigUp developer CLI)
      digup coreai-cache-identity            verify the helper signing identity without loading models
      digup coreai-activate --index DIR --model coreai-eg2-v1
      digup compact-vector-pages --index DIR  stop search/indexing first; preserve every vector
      digup specialization-lock --runtime DIR --hold-ms N [--lock-timeout SECONDS] [--throw-under-lock]
      digup shadow-counts --index DIR
      digup coreai-gate-check --runtime DIR --inputs JSON-array-of-texts
      digup prepare-runtime --runtime DIR       prepare the single model during setup, with resumable cache probes
      digup verify-runtime --runtime DIR [--full | --asset text-query.aimodel]
                                              verify the runtime without loading models; --full forces all content hashes

      digup estimate <folder>... [--json]     what would be indexed, and how long the first pass takes
      digup status                            what's in the index
      digup speed                             this machine's speed next to the M4 Pro behind the estimates, and
                                              what indexing has measured here (costs.json in the index folder)
      digup prune-excluded --index DIR [--exclude DIR]...  remove excluded files and their indexed content
      digup index-service <folder>... [--once] [--sync-list paths.json] [--code-root DIR]... [--code-exclude DIR]... [--backfill] [--prune]
                          [--memory-limit MB] [--time-limit S] [--wait-for-sync]
                                              the app's indexing helper (JSON lines; see IndexService); it stops
                                              on a file whose reading passes the limits (see Watchdog)
      digup shadow-embed --index DIR --runtime DIR --model-key coreai-eg2-text-v1
                          [--limit N] [--only-segments FILE] [--modalities text,image,audio]
                          [--carry-from coreai-eg2-text-v1|/absolute/source-index-directory]
                                              coreai-eg2-v1 adds images and audio; stdin pause/resume/stop, EOF stops
      digup c1-check --inputs JSON --output JSON
                                              production-path C1 parity, decode, image and rebuild diagnostics
      digup shadow-inputs --index DIR --output FILE [--only-segments FILE] [--limit N]
                                              rebuild exact legacy document inputs for fidelity checks
      digup worker --text-only --runtime DIR [--engine coreai]
                                              Core AI query encoder as a process (JSON lines)

    Options:
      --index DIR          index folder (default: DigUp's Application Support folder; see `digup status`)
      --code               estimate, index or show the code index of these folders (code.sqlite in the index
                           folder): source files, their repos' docs and notebooks, minus what git ignores
      --kind K,K           screenshot, image, pdf, doc, audio, video
      --include-code       also index source code, notebooks, text data and project media
      --include-datasets   don't skip folders that look like datasets
      --exclude DIR        don't index this folder (repeatable)
      --exclude-ext EXT    don't index files with this extension (repeatable, or comma-separated: "heic,txt")
      --wait-for-sync      index-service: don't crawl on start; sync when told ("sync" or "sync <path>")
      --own-git-owner NAME your account on GitHub and the like (repeatable): other people's repositories, decompiled
                           apps and downloaded source archives are left out
      --skip-kind K,K      don't index these kinds at all (audio, video, ...); indexed ones leave on the next sync
      --reindex            drop vectors and embed everything again (after changing settings or model)
      --zgate Z            how far a meaning match must stand out (default 2.0)
      --word-weight W      bonus for containing all of the query's words (default 2.0, and for code see Searcher)
      --shot-tokens N      vision tokens per screenshot (default 280; 560 was 2× slower, no better on real shots)
      --code-stretch N     characters a stretch of code holds at most (default 1800; 1200 and 3600 lost on the evals)

    The model: EmbeddingGemma 2 on Apple Core AI. Install the verified runtime with
    Swiftlight's scripts/install-runtime.sh. Index with index-service; search through the launcher backend.
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Arguments: Sendable {
    var positional: [String] = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["--index", "--limit", "--kind", "-n", "--zgate", "--word-weight", "--new-limit",
                                      "--hold-ms", "--lock-timeout", "--inputs", "--asset", "--linger", "--shot-tokens", "--code-stretch", "--encoder-idle",
                                      "--memory-limit", "--time-limit", "--skip-kind", "--engine", "--runtime", "--model-key", "--model", "--sync-list", "--only-segments", "--modalities", "--carry-from", "--output"]
    static let repeated: Set<String> = ["--exclude", "--exclude-ext", "--code-root", "--code-exclude", "--own-git-owner"]

    init(_ raw: ArraySlice<String>) throws {
        var index = raw.startIndex
        while index < raw.endIndex {
            let argument = raw[index]
            if Self.valued.contains(argument) || Self.repeated.contains(argument) {
                guard index + 1 < raw.endIndex else { throw CLIError("\(argument) needs a value") }
                if Self.repeated.contains(argument) {
                    lists[argument, default: []].append(raw[index + 1])
                } else {
                    values[argument] = raw[index + 1]
                }
                index += 2
            } else if argument.hasPrefix("--") || argument == "-h" {
                flags.insert(argument)
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    var indexFolder: URL {
        guard let chosen = values["--index"] else { return AppPaths.defaultIndex.standardizedFileURL }
        return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// `--code`: the code index, not the main one.
    var code: Bool { flags.contains("--code") }

    func store() throws -> IndexStore {
        try IndexStore(directory: indexFolder, file: code ? IndexStore.codeFile : IndexStore.mainFile)
    }

    var options: IndexOptions {
        var options = IndexOptions()
        options.code = code
        options.includeCode = flags.contains("--include-code")
        options.includeDatasets = flags.contains("--include-datasets")
        options.excludedFolders = (lists["--exclude"] ?? []).map { Self.folderURL($0).path }
        options.excludedExtensions = IndexOptions.extensions((lists["--exclude-ext"] ?? []).joined(separator: ","))
        if let tokens = values["--shot-tokens"].flatMap(Int.init) { options.screenshotBudget = tokens }
        if let characters = values["--code-stretch"].flatMap(Int.init) { options.codeStretch = characters }
        options.ownGitOwners = Set((lists["--own-git-owner"] ?? []).map { $0.lowercased() })
        options.skippedKinds = Set((values["--skip-kind"] ?? "").split(separator: ",").compactMap {
            FileKind(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
        return options
    }

    func folders() throws -> [URL] {
        guard !positional.isEmpty else { throw CLIError("which folders? e.g. digup index ~/DigUpTestbed") }
        return try positional.map {
            let url = Self.folderURL($0)
            guard Self.isFolder(url) else { throw CLIError("not a folder: \($0)") }
            guard Self.isReadable(url) else { throw CLIError("can't read \($0) (macOS privacy settings?)") }
            return url
        }
    }

    static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The folder can be listed. One that macOS won't let us read (Files and Folders privacy) looks empty to a crawl,
    /// which must never be mistaken for "everything in it was deleted". (The first look may bring up macOS's prompt.)
    static func isReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Dev knobs for A/B runs in evals/.
    var zGate: Double { values["--zgate"].flatMap(Double.init) ?? 2.0 }
    var wordWeight: Double? { values["--word-weight"].flatMap(Double.init) }   // nil: the index's own (`Searcher`)

    func kinds() throws -> Set<FileKind>? {
        guard let list = values["--kind"] else { return nil }
        return Set(try list.split(separator: ",").map {
            guard let kind = FileKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) else {
                throw CLIError("unknown kind \($0); use screenshot, image, pdf, doc, audio, video")
            }
            return kind
        })
    }
}

// MARK: Formatting

let home = FileManager.default.homeDirectoryForCurrentUser.path
func tilde(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }
func number(_ value: Int) -> String { value.formatted(.number) }

func duration(_ seconds: Double) -> String {
    switch seconds {
    case ..<90: "\(Int(seconds.rounded())) s"
    case ..<5400: "\(Int((seconds / 60).rounded())) min"
    default: String(format: "%.1f h", seconds / 3600)
    }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%d:%02d", total / 60, total % 60)
}

func location(_ hit: SearchHit) -> String {
    switch hit.segment {
    case .page, .pageImage: hit.loc.map { "p. \(Int($0))" } ?? ""
    case .audio, .frame: hit.loc.map { "at \(clock($0))" + (hit.segment == .audio ? " (sound)" : "") } ?? ""
    case .chunk: hit.loc.map { "part \(Int($0))" } ?? ""
    case .lines: hit.loc.map { "lines \(Int($0))–\(Int(hit.locEnd ?? $0))" + (hit.focus.map { ", opens at \(Int($0))" } ?? "") } ?? ""
    case .cells: hit.loc.map { $0 == hit.locEnd ? "cell \(Int($0))" : "cells \(Int($0))–\(Int(hit.locEnd ?? $0))" } ?? ""
    case .ocr: "text in image"
    default: ""
    }
}

func skippedLine(_ skipped: [String: Int]) -> String {
    skipped.sorted { $0.value > $1.value }.map { "\(number($0.value)) \($0.key)" }.joined(separator: " · ")
}

// MARK: Commands

func estimate(_ args: Arguments) throws {
    guard !args.positional.isEmpty else { throw CLIError("which folders? e.g. digup estimate ~/Documents") }
    let options = args.options
    // What indexing costs on this machine: as measured by indexing here, kind by kind, once there's enough of it;
    // until then the M4 Pro's fixed costs, scaled by a second's speed check (done once and kept beside the index).
    var measured = MeasuredCosts.load(from: args.indexFolder)
    if measured.speed == nil, let speed = MeasuredCosts.Speed.measure() {
        measured.speed = speed
        MeasuredCosts.setSpeed(speed, in: args.indexFolder)
    }
    let costs = measured.costs
    var total = 0.0
    for folder in args.positional.map(Arguments.folderURL) {
        // One folder that isn't there or can't be read (a denied privacy prompt) mustn't sink the others.
        guard Arguments.isFolder(folder), Arguments.isReadable(folder) else {
            if args.flags.contains("--json") {
                emit(["folder": folder.path, "readable": false, "seconds": 0, "files": [String: Int](),
                      "pdf_pages": 0, "audio_seconds": 0, "video_seconds": 0])
            } else {
                print("\(tilde(folder.path))    can't read it (not there, or not allowed in macOS privacy settings)")
            }
            continue
        }
        let started = Date()
        let crawl = Crawler.crawl([folder], options: options)
        let parts = Estimator.estimates(bySubfolder: crawl.candidates, of: folder.path, options: options, costs: costs)
        let estimate = parts.values.reduce(Estimate(), +)
        // Biggest first; the app lists them under the folder, so that a long first pass can be cut down.
        let subfolders = parts.filter { $0.key != folder.path }.sorted {
            $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key
        }
        total += estimate.seconds
        if args.flags.contains("--json") {
            func files(_ estimate: Estimate) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: estimate.files.map { ($0.key.rawValue, $0.value) })
            }
            // One line per folder, as soon as it's done (the app's onboarding shows them as they come).
            emit(["folder": folder.path, "seconds": estimate.seconds, "readable": true, "files": files(estimate),
                  "pdf_pages": estimate.pdfPages, "pdf_pages_total": estimate.pdfPagesTotal,
                  "audio_seconds": estimate.audioSeconds, "video_seconds": estimate.videoSeconds,
                  "long_files": estimate.longFiles, "later_seconds": estimate.laterSeconds,
                  "code_stretches": estimate.codeStretches, "bytes": estimate.bytes,
                  "source_bytes": Dictionary(grouping: crawl.candidates, by: { $0.kind.rawValue })
                      .mapValues { $0.reduce(Int64(0)) { $0 + $1.size } },
                  "doc_chunks_total": crawl.candidates.filter { $0.kind == .doc }.reduce(0) {
                      $0 + max(1, min(options.maxChunks, Int($1.size / 1600)))
                  },
                  "skipped_files": crawl.skipped, "skipped_folders": crawl.skippedFolders,
                  "subfolders": subfolders.prefix(500).map {
                      ["folder": $0.key, "seconds": $0.value.seconds, "files": files($0.value),
                       "long_files": $0.value.longFiles, "later_seconds": $0.value.laterSeconds,
                       "bytes": $0.value.bytes] as [String: Any]
                  },
                  "skipped": crawl.skipped.values.reduce(0, +), "datasets": crawl.datasets.count,
                  "ms": Int(Date().timeIntervalSince(started) * 1000)])
            continue
        }
        var kinds: [String] = []
        for kind in FileKind.allCases {
            guard let count = estimate.files[kind], count > 0 else { continue }
            switch kind {
            case .pdf: kinds.append("\(number(count)) PDFs (\(number(estimate.pdfPagesTotal)) pages; \(number(estimate.pdfPages)) in the first pass)")
            case .audio: kinds.append("\(number(count)) audio (\(duration(estimate.audioSeconds)))")
            case .video: kinds.append("\(number(count)) video (\(duration(estimate.videoSeconds)))")
            case .code: kinds.append("\(number(count)) code \(count == 1 ? "file" : "files") "
                                     + "(\(number(estimate.codeStretches)) stretches)")
            default: kinds.append("\(number(count)) \(kind.rawValue)\(count == 1 ? "" : "s")")
            }
        }
        print("\(tilde(folder.path))    first index ≈ \(duration(estimate.seconds))"
              + (args.code ? ", index ≈ \(ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file))" : ""))
        print("  " + (kinds.isEmpty ? "nothing to index" : kinds.joined(separator: " · ")))
        if estimate.longFiles > 0 {
            print("  then the rest of \(number(estimate.longFiles)) long \(estimate.longFiles == 1 ? "file" : "files") "
                  + "≈ \(duration(estimate.laterSeconds))")
        }
        if !subfolders.isEmpty {
            print("  biggest subfolders: " + subfolders.prefix(5).map {
                "\(($0.key as NSString).lastPathComponent) ≈ \(duration($0.value.seconds))"
            }.joined(separator: " · ") + (subfolders.count > 5 ? " · \(subfolders.count - 5) more" : ""))
        }
        if !crawl.skipped.isEmpty { print("  skipped: " + skippedLine(crawl.skipped)) }
        if !crawl.skippedFolders.isEmpty { print("  folders not walked: " + skippedLine(crawl.skippedFolders)) }
        for (folder, count) in crawl.datasets.sorted(by: { $0.value > $1.value }) {
            print("  looks like a dataset (skipped): \(tilde(folder)) (\(number(count)) files)")
        }
        print(String(format: "  (looked at it in %.2f s)", Date().timeIntervalSince(started)))
    }
    if args.positional.count > 1, !args.flags.contains("--json") { print("all together ≈ \(duration(total))") }
}

func statesLine(_ states: [String: Int]) -> String {
    states.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
}

func status(_ args: Arguments) throws {
    let store = try args.store()
    let counts = try store.counts()
    print("index: \(tilde(store.file.path))")
    print("vectors: \(number(counts.vectors)) in \(number(counts.segments)) segments")
    for kind in FileKind.allCases {
        guard let states = counts.byKindAndState[kind.rawValue] else { continue }
        let total = states.values.reduce(0, +)
        print("  \(pad(kind.rawValue, 11)) \(lpad(number(total), 6))   " + statesLine(states))
    }
    if counts.unfinished > 0 {
        print("long files still being read: \(number(counts.unfinished)) (\(number(counts.left)) pages and chunks left)")
    }
    if let fingerprint = try store.meta("fingerprint") { print("built with: \(fingerprint)") }
    print("this digup: Core AI, coreai-eg2-v1")
    print("size: \(ByteCountFormatter.string(fromByteCount: IndexStore.size(of: store.file), countStyle: .file))")
}

/// The app's indexing helper: sync + index on request, JSON events out (IndexService.swift).
func indexService(_ args: Arguments) throws -> Int32 {
    guard #available(macOS 27, *) else { throw CLIError("index-service requires macOS 27") }
    let textOnly = args.flags.contains("--text-only")
    let runtime = try RuntimeDirectory(URL(fileURLWithPath: args.values["--runtime"] ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1").path))
    guard runtime.modelKey == (args.values["--model-key"] ?? "coreai-eg2-v1") else {
        throw CLIError("Core AI model key/runtime mismatch")
    }
    let model = SharedEmbedder(coreAIRuntime: runtime)
    func part(_ file: String, options: IndexOptions, roots: [URL]) throws -> IndexService.Part {
        let store = try IndexStore(directory: args.indexFolder, file: file)
        if textOnly { store.indexingKinds = [.doc, .code] }
        do {
            if runtime.assets.audioRevision == nil {
                store.indexingKinds = (store.indexingKinds ?? Set(FileKind.allCases)).subtracting([.audio])
            }
            let info = WorkerInfo(model: "google/embeddinggemma-2", revision: runtime.assets.revision,
                                  runtime: "coreai-ane", dtype: "fp16", dim: 768, textOnly: false, loadSeconds: nil)
            try store.useCoreAIModel(key: runtime.modelKey, info: info, weights: runtime.weightsSHA256,
                                    audioIdentity: runtime.assets.audioRevision, videoIdentity: runtime.assets.videoRevision)
        }
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { try model.embedder() })
        indexer.costsFolder = args.indexFolder   // what indexing costs here, for later estimates
        // A new app version may bring a new model: the index starts over by itself (keyword search on names goes on).
        indexer.resetOnModelChange = { indexed, now in
            emit(["event": "reindex", "from": indexed, "to": now, "code": options.code])
        }
        // A chosen folder that isn't there now (an unplugged drive) is skipped, not an error, and its files stay
        // indexed. With --prune, files under none of the given folders leave the index (the app passes all its folders).
        return IndexService.Part(store: store, indexer: indexer, roots: roots,
                                 keepOnly: args.flags.contains("--prune") ? roots : nil)
    }
    var codeOptions = args.options
    codeOptions.code = true
    codeOptions.excludedFolders = (args.lists["--code-exclude"] ?? []).map { Arguments.folderURL($0).path }
    let codeRoots = (args.lists["--code-root"] ?? []).map(Arguments.folderURL)
    // A file whose reading runs away ends this helper, noted for the next one (`Watchdog`).
    Watchdog(folder: args.indexFolder,
             memoryLimit: args.values["--memory-limit"].flatMap(UInt64.init).map { $0 << 20 } ?? Watchdog.defaultMemoryLimit,
             timeLimit: args.values["--time-limit"].flatMap(Double.init) ?? Watchdog.defaultTimeLimit).start()
    let service = IndexService(main: try part(IndexStore.mainFile, options: args.options,
                                              roots: args.positional.map(Arguments.folderURL)),
                               code: codeRoots.isEmpty ? nil : try part(IndexStore.codeFile, options: codeOptions,
                                                                        roots: codeRoots),
                               folder: args.indexFolder,
                               model: model,
                               modelReady: { true },
                               backfill: args.flags.contains("--backfill"),
                               newFilesLimit: args.values["--new-limit"].flatMap(Int.init) ?? 50,
                               linger: args.values["--linger"].flatMap(Double.init) ?? 60,
                               firstSync: !args.flags.contains("--wait-for-sync"),
                               initialPaths: try args.values["--sync-list"].map { try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: $0))) },
                               readsInput: !args.flags.contains("--once"))
    return service.serve()
}

/// `digup speed`: the speed check estimates start from, and what indexing has measured on this machine.
func speed(_ args: Arguments) {
    if let seconds = MeasuredCosts.Speed.measuredSeconds() {
        let speed = MeasuredCosts.Speed.compared(seconds)
        print(String(format: "20 float16 matrix multiplies (2048²) %.3f s · Vision on a made-up screenshot %.3f s",
                     seconds.multiplies, seconds.ocr))
        print(String(format: "next to the M4 Pro behind the fixed costs: the model's work ×%.2f, OCR ×%.2f (1 = as fast)",
                     speed.embedding, speed.ocr))
    } else {
        print("no speed check here (no Metal): the fixed costs stand in until indexing has measured this machine's")
    }
    let measured = MeasuredCosts.load(from: args.indexFolder)
    print("measured by indexing (\(tilde(MeasuredCosts.file(in: args.indexFolder).path))):"
          + (measured.tallies.isEmpty ? " nothing yet" : ""))
    for (name, tally) in measured.tallies.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %@ %.4f s each, over %.0f", name, tally.seconds / tally.units, tally.units))
    }
}

// MARK: Eval

struct EvalFile: Decodable {
    struct Query: Decodable {
        let q: String
        let expect: [String]   // paths relative to `base`; "path@6-12" also requires the hit to start in [6, 12) s
        let tag: String?
        let kind: String?
    }
    let base: String
    let queries: [Query]
}

// MARK: Main

RuntimeDiagnostics.mark("a_process_start")

do {
    let raw = CommandLine.arguments.dropFirst()
    guard let command = raw.first, command != "-h", command != "--help", command != "help" else {
        print(usage)
        exit(0)
    }
    let args = try Arguments(raw.dropFirst())
    if ["index-service", "worker"].contains(command)
        || command == "estimate" && args.flags.contains("--json") {
        ParentWatch.start()   // an app's helper goes when the app does
    }
    if let engine = args.values["--engine"], engine != "coreai" {
        throw CLIError("Swiftlight supports only --engine coreai")
    }
    switch command {
    case "coreai-cache-identity":
        try RuntimeCacheIdentity.requireProductionHelper()
        emit(["event": "cache_identity", "valid": true, "signing_identifier": RuntimeCacheIdentity.productionIdentifier,
              "namespace": RuntimeCacheIdentity.namespace])
    case "estimate": try estimate(args)
    case "status": try status(args)
    case "prune-excluded":
        let removed = try args.store().pruneExcluded(args.options.excludedFolders)
        print("pruned excluded files: \(removed)")
    case "compact-vector-pages":
        let result = try args.store().compactVectorPages()
        emit(["event": "vector_pages_compacted", "changed": result.changed,
              "page_size_before": result.pageSizeBefore, "page_size_after": result.pageSizeAfter,
              "bytes_before": result.bytesBefore, "bytes_after": result.bytesAfter])
    case "speed": speed(args)
    case "index-service": exit(try runIndexService(args))
    case "coreai-activate":
        let key = args.values["--model"] ?? args.values["--model-key"] ?? "coreai-eg2-v1"
        let generation = try args.store().activateModel(key: key, rollback: false)
        emit(["event": command, "model": key, "generation": generation])
    case "shadow-counts": try shadowCountsDiagnostic(args)
    case "specialization-lock": try specializationLockDiagnostic(args)
    case "coreai-gate-check": exit(try coreAIGateDiagnostic(args))
    case "prepare-runtime": exit(try prepareRuntime(args))
    case "verify-runtime":
        guard #available(macOS 27, *), let path = args.values["--runtime"] else {
            throw CLIError("verify-runtime needs macOS 27 and --runtime DIR")
        }
        let directory = URL(fileURLWithPath: path)
        if let asset = args.values["--asset"] {
            try RuntimeDirectory.verifyAssetForRecovery(directory.appendingPathComponent(asset), manifest: directory.appendingPathComponent("manifest.json"))
        } else {
            _ = try RuntimeDirectory(directory, fullVerify: args.flags.contains("--full"))
        }
        print("runtime verification passed")
    case "c1-check": exit(try c1Diagnostic(args))
    case "worker": exit(runWorkerService(args))
    case "shadow-embed": exit(try shadowEmbed(args))
    case "shadow-inputs": try shadowInputs(args)
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
