import AppKit
import Combine
import Carbon
import QuickLookUI

enum OpeningProbe {
    /// `SWIFTLIGHT_OPEN_TIMING=1` writes the same marks to stderr for scripts/measure-open.
    private static let timing = ProcessInfo.processInfo.environment["SWIFTLIGHT_OPEN_TIMING"] == "1"
    private static let verify = ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1"
    static func mark(_ phase: String, at timestamp: Double? = nil) {
        guard verify || timing else { return }
        let line = "OPENING_TIME \(phase) \(timestamp ?? ProcessInfo.processInfo.systemUptime)"
        if verify { print(line); fflush(stdout) }
        if timing { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }
}

struct SearchHit: Decodable, Identifiable, Equatable {
    let path: String
    let title: String
    let source: String
    let kind: String
    var id: String { path }
    /// Folder shown under the title: home abbreviated to ~, and deep paths shortened in the middle
    /// so the enclosing folder stays visible ("~/Documents/Projects/…/Reports").
    var location: String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
        let parts = display.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 5 else { return display }
        return (parts.prefix(3) + ["…"] + parts.suffix(2)).joined(separator: "/")
    }
    @MainActor var bundleIdentifier: String? { kind == "app" ? BundleIdentifiers.lookup(path) : nil }
}

/// Bundle(path:) reads Info.plist from disk; results are rebuilt on every keystroke.
@MainActor enum BundleIdentifiers {
    private static var cache: [String: String?] = [:]
    static func lookup(_ path: String) -> String? {
        if let known = cache[path] { return known }
        let identifier = Bundle(path: path)?.bundleIdentifier
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[path] = identifier
        return identifier
    }
}
struct BackendEvent: Decodable {
    let event: String
    let generation: UInt64?
    let hits: [SearchHit]?
    let selected: String?
    let path: String?
    let message: String?
    let phase: String?
    let folders: [String]?
    /// Every search has answered (names, keywords and meaning arrive in any order).
    let complete: Bool?
    let elapsed_ms: Double?
}

@MainActor final class LauncherModel: ObservableObject {
    @Published var accessFolders: [String] = []
    @Published var indexStatus = ""
    var reviewAccess: (() -> Void)?
    @Published var presented = false
    @Published var text = ""
    @Published var suggestion = ""
    @Published var hits: [SearchHit] = []
    @Published var selectedPath: String? { didSet { if selectedPath != oldValue { ResultOpening.prepare(selectedHit) } } }
    /// Arrow keys moved focus into the list. Until then no row is highlighted, though the top hit
    /// still completes inline and opens on Return; while browsing, Space previews the row.
    @Published var browsing = false
    @Published var searching = false
    @Published var resultsHeight: CGFloat = 0
    /// Shown in place of rows on the results surface.
    var resultsMessage: String { hits.isEmpty ? (searching ? "Searching…" : "No results") : "" }
    var pillHeight: CGFloat = 91
    var resultsChanged: (() -> Void)?
    var selectedHit: SearchHit? { hits.first { $0.path == selectedPath } }
    var highlightedPath: String? { browsing ? selectedPath : nil }
    var listedHits: ArraySlice<SearchHit> { hits.prefix(PresentationStage.maximumRows) }
    private(set) var generation: UInt64 = 0
    var dismiss: (() -> Void)?
    /// Opens a result and puts the pill away at once; set by the app delegate.
    var launch: ((ResultOpening.Target) -> Void)?
    private var pendingOpen = PendingOpen()
    private var backend: Process?
    private var input: FileHandle?
    private let inputQueue = DispatchQueue(label: "com.shachin.swiftlight.search-input", qos: .userInitiated)
    private var buffer = Data()
    private var stopping = false
    private var failures = 0
    private let log: FileHandle?
    private var supportReady = false
    private var awaitingResults = false

    init() {
        let support: URL
        do {
            let parent = ProcessInfo.processInfo.environment["SWIFTLIGHT_TEST_SUPPORT_PARENT"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            support = try SupportDirectory.prepare(parent: parent)
            supportReady = true
        } catch {
            NSLog("Swiftlight data migration failed; helpers will not start: %@", String(describing: error))
            log = nil
            return
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("launcher.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        log = try? FileHandle(forWritingTo: url)
        _ = try? log?.seekToEnd()
    }
    func start() {
        guard supportReady, backend == nil, !stopping else { return }
        let process = Process()
        let environment = ProcessInfo.processInfo.environment
        process.executableURL = environment["SPOTLIGHT_BACKEND"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Swiftlight Search")
        if let config = environment["SPOTLIGHT_CONFIG"] { process.arguments = ["--config", config] }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = log ?? FileHandle.standardError
        input = stdin.fileHandleForWriting
        buffer.removeAll()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backend = nil
                self.input = nil
                self.suggestion = ""
                if !self.stopping {
                    self.failures += 1
                    let delay = min(pow(2.0, Double(self.failures)), 30)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
                }
            }
        }
        do { try process.run(); backend = process; send(["op": "query", "generation": generation + 1, "text": text]); generation += 1 }
        catch { diagnostic("Backend launch failed: \(error)"); input = nil }
    }
    func query(_ value: String) {
        awaitingResults = true
        let wasBrowsing = browsing
        let wasEmpty = text.isEmpty
        let extendsQuery = !text.isEmpty && value.count > text.count && value.hasPrefix(text)
        text = value; generation += 1
        if browsing { browsing = false }
        let filtered = extendsQuery ? hits : (value.isEmpty ? [] : hits.filter { $0.source == "fsearch" && $0.title.localizedCaseInsensitiveContains(value) })
        let immediate = filtered.first { $0.source == "fsearch" && $0.title.localizedCaseInsensitiveContains(value) }
        let changed = hits != filtered || wasBrowsing || wasEmpty != value.isEmpty
        if hits != filtered { hits = filtered }
        if selectedPath != immediate?.path { selectedPath = immediate?.path }
        let nextSuggestion = selectedHit?.title ?? ""
        if suggestion != nextSuggestion { suggestion = nextSuggestion }
        if searching != !value.isEmpty { searching = !value.isEmpty }
        if changed { resultsChanged?() }
        send(["op": "query", "generation": generation, "text": value])
    }
    /// Down enters the list at the first row and walks it; Up from the first row returns to the field.
    func move(_ delta: Int) {
        let rows = listedHits
        guard !awaitingResults, !rows.isEmpty, browsing || delta > 0 else { return }
        let index = browsing ? (rows.firstIndex { $0.path == selectedPath } ?? 0) : -1
        let next = min(index + delta, rows.count - 1)
        if next >= 0 { highlight(rows[next].path); return }
        browsing = false
        selectedPath = rows.first?.path
        send(["op": "select", "generation": generation, "path": NSNull()])
    }
    func highlight(_ path: String) {
        guard !awaitingResults else { return }
        browsing = true
        selectedPath = path
        send(["op": "select", "generation": generation, "path": path])
    }
    func chooseAndOpen(_ path: String) {
        guard !awaitingResults, hits.contains(where: { $0.path == path }) else { return }
        selectedPath = path
        send(["op": "select", "generation": generation, "path": path])
        open()
    }
    /// Return. The selection shown is the backend's own for this query (or the row the arrows or a click chose), so
    /// it opens here without a round-trip; the backend records the open for ranking afterwards.
    func open() {
        guard pendingOpen.returnPressed(generation: generation, awaitingResults: awaitingResults) else { return }
        guard let hit = selectedHit else { return }
        let target = ResultOpening.target(for: hit)
        launch?(target)
        send(["op": "opened", "generation": generation, "path": target.path])
    }
    func clear() { query("") }
    /// Lets the backend warm the query model when the pill opens and pause indexing while it is up.
    func setActive(_ active: Bool) { send(["op": "active", "value": active]) }
    func panelOpened() { send(["op": "panel_opened"]) }
    func panelClosed() { send(["op": "panel_closed"]) }
    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        inputQueue.async { [log] in
            do { try input.write(contentsOf: data + Data([10])) }
            catch { try? log?.write(contentsOf: Data("Backend write failed: \(error)\n".utf8)) }
        }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(BackendEvent.self, from: line) else { continue }
            if event.event == "index-status" { indexStatus = event.message ?? ""; continue }
            if event.event == "access" { accessFolders = event.folders ?? []; continue }
            if event.event == "ready" { failures = 0 }
            if event.event == "diagnostic" || event.event == "fatal" { diagnostic(event.message ?? "Backend diagnostic") }
            guard event.generation == generation else { continue }
            if event.event == "results" || event.event == "progress" {
                if event.phase == "pending" && !text.isEmpty { continue }
                if event.hits != nil || event.complete == true { awaitingResults = false }
                let nextHits = event.hits ?? hits
                let changed = nextHits != hits || (browsing && selectedPath != event.selected)
                if nextHits != hits { hits = nextHits }
                if selectedPath != event.selected { selectedPath = event.selected }
                if browsing && !listedHits.contains(where: { $0.path == selectedPath }) { browsing = false }
                let nextSearching = !(event.complete ?? (event.phase == "semantic"))
                if searching != nextSearching { searching = nextSearching }
                if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" {
                    print("RESULTS \(event.phase ?? "") \(hits.count) \(selectedPath ?? "") \(event.elapsed_ms ?? 0)")
                    var record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    record["hits"] = hits.map { ["path": $0.path, "title": $0.title, "kind": $0.kind, "source": $0.source] }
                    print("RESULT_EVENT " + String(data: (try? JSONSerialization.data(withJSONObject: record)) ?? line, encoding: .utf8)!)
                    if event.phase == "semantic" { print("SEMANTIC_TIME \(generation) \(ProcessInfo.processInfo.systemUptime)") }
                    fflush(stdout)
                }
                if changed {
                    if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("RESULTS_RENDER \(generation)"); fflush(stdout) }
                    resultsChanged?()
                }
                if let hit = hits.first(where: { $0.path == event.selected }) {
                    let duplicates = hits.filter { $0.title == hit.title }.count
                    let value = duplicates > 1 ? hit.title + " · " + URL(fileURLWithPath: hit.path).deletingLastPathComponent().lastPathComponent : hit.title
                    if suggestion != value { suggestion = value }
                } else if !suggestion.isEmpty { suggestion = "" }
                if pendingOpen.resultsArrived(generation: generation, awaitingResults: awaitingResults) { open() }
            } else if event.event == "open", let path = event.path, let hit = hits.first(where: { $0.path == path }) {
                // Older protocol: the backend chose and asked the launcher to open.
                launch?(ResultOpening.target(for: hit))
            }
        }
    }
    private func diagnostic(_ message: String) { try? log?.write(contentsOf: Data((message + "\n").utf8)) }
    func stop() {
        stopping = true
        send(["op": "quit"])
        inputQueue.sync {}
        try? input?.close()
        guard let backend else { return }
        let pid = backend.processIdentifier
        // All helpers share the Rust child's owned group; no unrelated process is signalled.
        kill(-pid, SIGTERM)
        // A paused (SIGSTOP) indexing helper only acts on SIGTERM once continued.
        kill(-pid, SIGCONT)
        backend.terminate()
    }
}

final class FieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect { rect }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { .zero }
}
final class SearchField: NSSearchField {
    override class var cellClass: AnyClass? { get { FieldCell.self } set {} }
    override var allowsVibrancy: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { configureEditor() }
        return ok
    }
    override func scrollWheel(with event: NSEvent) {
        guard bounds.height > 30, let editor = currentEditor() as? NSTextView, let clip = editor.superview as? NSClipView else {
            super.scrollWheel(with: event)
            return
        }
        var proposed = clip.bounds
        proposed.origin.y -= event.scrollingDeltaY
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    }
    func configureEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = .labelColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.15), .foregroundColor: NSColor.labelColor]
        editor.writingToolsBehavior = .none
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 2
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = FieldView.paragraphStyle()
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font!, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
}

@MainActor final class FieldView: NSView, NSSearchFieldDelegate {
    let field = SearchField()
    let completion = SearchNativeUI.completionController()
    private let measurementStorage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(size: NSSize(width: 449, height: CGFloat.greatestFiniteMagnitude))
    private var completionKey = ""
    private var fieldWidth: CGFloat = 449
    private var visibleTextHeight: CGFloat = 30
    private var completionFits = false
    var model: LauncherModel
    static func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 30
        paragraph.maximumLineHeight = 30
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }
    init(model: LauncherModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 91))
        measurementContainer.lineFragmentPadding = 2
        measurementLayout.addTextContainer(measurementContainer)
        measurementStorage.addLayoutManager(measurementLayout)
        field.cell = FieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.font = .preferredFont(forTextStyle: .title1)
        field.textColor = .labelColor
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.placeholderAttributedString = NSAttributedString(string: "Search or Ask", attributes: [.font: field.font!, .foregroundColor: NSColor.placeholderTextColor])
        field.appearance = NSAppearance(named: .vibrantDark)
        field.wantsLayer = true
        field.layer?.compositingFilter = "plusL"
        field.setAccessibilityLabel("Search")
        completion.view.appearance = NSAppearance(named: .vibrantDark)
        completion.view.frame = NSRect(x: 36, y: 31, width: 449, height: 30)
        completion.view.setAccessibilityLabel("Suggested file")
        addSubview(completion.view)
        addSubview(field)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" {
            NotificationCenter.default.addObserver(self, selector: #selector(reportEditorGeometry), name: NSView.boundsDidChangeNotification, object: nil)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        if !model.presented && field.stringValue != model.text { field.stringValue = model.text }
        let hit = model.selectedHit
        let typedWidth = (model.text as NSString).size(withAttributes: [.font: field.font!]).width
        let wraps = typedWidth > (hit == nil ? 449 : 364) - 4 || model.text.contains("\n")
        fieldWidth = hit == nil || wraps ? 449 : min(max(typedWidth + 8, 30), 364)
        measurementContainer.containerSize = NSSize(width: fieldWidth, height: CGFloat.greatestFiniteMagnitude)
        measurementStorage.setAttributedString(NSAttributedString(string: model.text, attributes: [.font: field.font!, .paragraphStyle: Self.paragraphStyle()]))
        measurementLayout.ensureLayout(for: measurementContainer)
        var lineCount = 0
        measurementLayout.enumerateLineFragments(forGlyphRange: measurementLayout.glyphRange(for: measurementContainer)) { _, _, _, _, _ in lineCount += 1 }
        if measurementLayout.extraLineFragmentTextContainer === measurementContainer { lineCount += 1 }
        visibleTextHeight = CGFloat(min(5, max(1, lineCount))) * 30
        let pillHeight = max(91, visibleTextHeight + 36)
        if model.pillHeight != pillHeight {
            model.pillHeight = pillHeight
            model.resultsChanged?()
        }
        completionFits = hit != nil && !wraps && visibleTextHeight == 30
        updateCompletionVisibility()
        layoutEditor()
        field.configureEditor()
        reportEditorGeometry()
        let key = "\(model.text)|\(hit?.path ?? "")|\(model.browsing)"
        guard key != completionKey else { return }
        completionKey = key
        let item = hit.map { hit -> LauncherResultItem in
            let item = LauncherResultItem()
            item.identifier = hit.path
            item.title = hit.title
            item.completion = hit.title
            item.applicationBundleIdentifier = hit.bundleIdentifier
            item.application = hit.kind == "app"
            return item
        }
        SearchNativeUI.updateCompletionController(completion, query: NSAttributedString(string: model.text, attributes: [.font: field.font!, .foregroundColor: NSColor.clear]), selectedItem: item, focused: !model.browsing)
        completion.view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("FIELD_REFRESH \(model.text) \(hit?.path ?? "nil") field=\(field.frame) completion=\(completion.view.frame)"); fflush(stdout) }
    }
    override func layout() {
        super.layout()
        layoutEditor()
    }
    private func layoutEditor() {
        field.frame = NSRect(x: 36, y: ceil((bounds.height-visibleTextHeight)/2), width: fieldWidth, height: visibleTextHeight)
        completion.view.frame = NSRect(x: 36, y: bounds.height-61, width: 449, height: 30)
    }
    @objc private func selectionDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === field.currentEditor() else { return }
        updateCompletionVisibility()
    }
    private func updateCompletionVisibility() {
        let atEnd = (field.currentEditor() as? NSTextView).map { editor in
            let range = editor.selectedRange()
            return range.length == 0 && range.location == editor.string.utf16.count
        } ?? true
        completion.view.isHidden = !completionFits || !atEnd
    }
    @objc private func reportEditorGeometry() {
        guard ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" else { return }
        let editor = field.currentEditor() as? NSTextView
        let clip = editor?.superview as? NSClipView
        clip?.postsBoundsChangedNotifications = true
        let content = editor?.textContainer.flatMap { editor?.layoutManager?.usedRect(for: $0).height } ?? 30
        let caret = editor.map { field.convert(field.window!.convertFromScreen($0.firstRect(forCharacterRange: $0.selectedRange(), actualRange: nil)), from: nil) } ?? .zero
        print("EDITOR_GEOMETRY height=\(model.pillHeight) content=\(content) visible=\(visibleTextHeight) offset=\(clip?.bounds.minY ?? 0) length=\((editor?.string ?? field.stringValue).utf16.count) caret_x=\(field.frame.minX+caret.minX) caret_min_y=\(caret.minY) caret_max_y=\(caret.maxY)"); fflush(stdout)
        if let editor { print("EDITOR_CONTROL field_editor=\(editor.isFieldEditor) writing=\(editor.writingToolsBehavior.rawValue)"); fflush(stdout) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(field)
    }
    func controlTextDidBeginEditing(_ notification: Notification) { field.configureEditor() }
    func controlTextDidChange(_ notification: Notification) {
        let text = field.currentEditor()?.string ?? field.stringValue
        model.query(text)
        refresh()
        if let editor = field.currentEditor() as? NSTextView { editor.scrollRangeToVisible(editor.selectedRange()) }
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("INPUT_TEXT \(text)"); fflush(stdout) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch NSStringFromSelector(command) {
        case "insertNewline:":
            OpeningProbe.mark("return_key_event", at: NSApp.currentEvent?.timestamp)
            OpeningProbe.mark("return_handled")
            model.open(); return true
        case "moveDown:" where visibleTextHeight == 30: model.move(1); return true
        case "moveUp:" where visibleTextHeight == 30: model.move(-1); return true
        case "cancelOperation:": model.dismiss?(); return true
        default: return false
        }
    }
}
final class PresentationStage: NSView {
    let motionView = NSView()
    let pillSurface = NSView()
    let resultsSurface = NSView()
    let pill = GlassSurfaceView(kind: .pill, cornerRadius: 43)
    let results = GlassSurfaceView(kind: .results, cornerRadius: 37)
    let resultsMessage = NSTextField(labelWithString: "")
    let field: FieldView
    let nativeResults = SearchResultsController()
    let resultsContent = NSView()
    let accessButton = NSButton(title: "", target: nil, action: nil)
    private var subscriptions = Set<AnyCancellable>()
    private var nativeRefreshPending = false
    private var resultsWork: DispatchWorkItem?
    private var appliedResultsKey = ""
    private var appliedHits: [SearchHit] = []
    private var appliedSelection: String?
    private var hasAppliedResults = false
    /// Rows shown in the results list. About seven are visible; more only cost row construction.
    static let maximumRows = 12
    var pillFrame = NSRect.zero
    var resultsHeight: CGFloat { model.resultsHeight }
    let model: LauncherModel
    init(model: LauncherModel) {
        self.model = model
        field = FieldView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        motionView.wantsLayer = true
        motionView.clipsToBounds = false
        clipsToBounds = false
        pillSurface.wantsLayer = true
        resultsSurface.wantsLayer = true
        pillSurface.clipsToBounds = false
        resultsSurface.clipsToBounds = false
        pillSurface.addSubview(pill)
        pillSurface.addSubview(field)
        accessButton.isBordered = false
        accessButton.font = .systemFont(ofSize: 11)
        accessButton.contentTintColor = .secondaryLabelColor
        accessButton.target = self; accessButton.action = #selector(reviewAccess)
        accessButton.isHidden = true
        pillSurface.addSubview(accessButton)
        model.$accessFolders.combineLatest(model.$indexStatus).sink { [weak self] folders, status in
            self?.accessButton.title = folders.isEmpty ? status : FolderAccessFlow.message(folders) + " Review access…"
            self?.accessButton.isHidden = folders.isEmpty && status.isEmpty
            self?.accessButton.isEnabled = !folders.isEmpty
        }.store(in: &subscriptions)
        resultsSurface.addSubview(results)
        resultsMessage.font = .systemFont(ofSize: 16)
        resultsMessage.textColor = .secondaryLabelColor
        resultsMessage.appearance = NSAppearance(named: .darkAqua)
        resultsMessage.alignment = .center
        resultsSurface.addSubview(resultsMessage)
        resultsContent.wantsLayer = true
        resultsContent.layer?.cornerRadius = 37
        resultsContent.layer?.cornerCurve = .continuous
        resultsContent.layer?.masksToBounds = true
        resultsContent.addSubview(nativeResults.view)
        resultsSurface.addSubview(resultsContent)
        nativeResults.openItem = { [weak model] path in model?.chooseAndOpen(path) }
        motionView.addSubview(pillSurface)
        motionView.addSubview(resultsSurface)
        addSubview(motionView)
        results.isHidden = true
        model.objectWillChange.sink { [weak self] _ in
            self?.scheduleNativeUIRefresh()
        }.store(in: &subscriptions)
    }
    @objc private func reviewAccess() { model.reviewAccess?() }
    required init?(coder: NSCoder) { fatalError() }
    func placePill(_ frame: NSRect) {
        pillFrame = frame
        let extra = resultsHeight > 0 ? resultsHeight + 10 : 0
        let height = frame.height + extra
        motionView.frame = NSRect(x: frame.minX, y: frame.minY-extra, width: frame.width, height: height)
        pillSurface.frame = NSRect(x: 0, y: extra, width: frame.width, height: frame.height)
        pill.frame = pillSurface.bounds
        field.frame = pillSurface.bounds
        accessButton.frame = NSRect(x: 36, y: 4, width: 449, height: 18)
        resultsSurface.frame = NSRect(x: 0, y: 0, width: frame.width, height: resultsHeight)
        results.frame = resultsSurface.bounds
        let messageHeight = resultsMessage.intrinsicContentSize.height
        resultsMessage.frame = NSRect(x: 0, y: (resultsHeight - messageHeight) / 2, width: frame.width, height: messageHeight)
        resultsContent.frame = resultsSurface.bounds
        nativeResults.view.frame = resultsContent.bounds
        for surface in [pillSurface, resultsSurface] {
            guard let layer = surface.layer else { continue }
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: surface.frame.midX, y: surface.frame.midY)
        }
    }
    func updateResults(height: CGFloat) {
        if model.resultsHeight != height { model.resultsHeight = height }
        let appearing = height > 0 && resultsSurface.isHidden
        results.isHidden = height == 0
        resultsSurface.isHidden = height == 0
        if appearing { SpotlightMotion.fadeIn(resultsSurface.layer, duration: SpotlightMotion.resultsFade) }
        placePill(pillFrame)
        guard height > 0 else { window?.invalidateShadow(); return }
        results.layoutSubtreeIfNeeded()
        window?.invalidateShadow()
    }
    func refreshNativeUI() {
        field.refresh()
        let message = model.resultsMessage
        if resultsMessage.stringValue != message {
            resultsMessage.stringValue = message
            if resultsHeight > 0 { placePill(pillFrame) }
        }
        resultsMessage.isHidden = message.isEmpty
        // Each keystroke can produce three result sets (names, keywords, meaning). Coalesce rapid
        // updates briefly so the results list settles cleanly; selection changes apply immediately.
        let hits = model.hits.prefix(Self.maximumRows)
        let key = hits.map(\.path).joined(separator: "\n")
        if key == appliedResultsKey || hits.isEmpty {
            resultsWork?.cancel()
            resultsWork = nil
            applyResults()
            return
        }
        guard resultsWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.resultsWork = nil
            self?.applyResults()
        }
        resultsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SpotlightMotion.resultsCoalescing, execute: work)
    }
    private func applyResults() {
        let hits = Array(model.hits.prefix(Self.maximumRows))
        let selection = model.highlightedPath
        guard !hasAppliedResults || hits != appliedHits || selection != appliedSelection else { return }
        hasAppliedResults = true
        appliedHits = hits
        appliedSelection = selection
        appliedResultsKey = hits.map(\.path).joined(separator: "\n")
        nativeResults.view.isHidden = hits.isEmpty
        let items = hits.map { hit in
            let item = LauncherResultItem()
            item.identifier = hit.path
            item.title = hit.title
            item.subtitle = hit.kind == "app" ? "" : hit.location
            item.completion = hit.title
            item.applicationBundleIdentifier = hit.bundleIdentifier
            item.application = hit.kind == "app"
            return item
        }
        nativeResults.update(items, query: model.text, selectedIdentifier: selection)
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("NATIVE_RESULTS_APPLY \(hits.count)"); fflush(stdout) }
    }
    func scheduleNativeUIRefresh() {
        guard !nativeRefreshPending else { return }
        nativeRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nativeRefreshPending = false
            self.refreshNativeUI()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if pillFrame.contains(local) { return field.hitTest(convert(local, to: pillSurface)) }
        let resultFrame = NSRect(x: pillFrame.minX, y: pillFrame.minY-10-resultsHeight, width: 520, height: resultsHeight)
        if resultsHeight > 0, resultFrame.contains(local) { return resultsContent.hitTest(convert(local, to: resultsSurface)) }
        return nil
    }
}
final class FluidPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0,y: 0,width: 520,height: 91), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: 23); isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        titleVisibility = .hidden; titlebarAppearsTransparent = true; animationBehavior = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        isMovableByWindowBackground = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    let model = LauncherModel()
    var panel: FluidPanel!
    var stage: PresentationStage!
    var presentationToken = UUID()
    var hiding = false
    var clickMonitor: Any?
    var animationAssertions = Set<UUID>()
    var viewport = NSRect.zero
    var changingFrame = false
    var observers: [NSObjectProtocol] = []
    var appearanceWork: DispatchWorkItem?
    var status: NSStatusItem!
    let openingKeys = OpeningKeyBuffer()
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var subscriptions = Set<AnyCancellable>()
    var previewItems: [String] = []
    var previewIndexObservation: NSKeyValueObservation?
    var accessWindow: FolderAccessPanel?
    let accessModel = FolderAccessModel()
    var accessFlow = FolderAccessFlow()
    var panelPreparation: PanelOpenPreparation?
    func applicationWillFinishLaunching(_ notification: Notification) { LoginItem.noteLaunchEvent() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        LoginItem.registerOnce()
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Review folder access…", action: #selector(reviewFolderAccess), keyEquivalent: "")
        appMenu.addItem(withTitle: "Quit Swiftlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        model.dismiss = { [weak self] in self?.hide() }
        model.launch = { [weak self] target in self?.launch(target) }
        model.reviewAccess = { [weak self] in self?.reviewFolderAccess() }
        panel = FluidPanel()
        stage = PresentationStage(model: model)
        model.resultsChanged = { [weak self] in self?.updateResults() }
        panel.contentView = stage
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Swiftlight")
        status.button?.setAccessibilityLabel("Swiftlight")
        status.button?.target = self; status.button?.action = #selector(statusClicked)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            OpeningProbe.mark("hotkey", at: event.map { GetEventTime($0) })
            OpeningProbe.mark("handler")
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.toggle() }; return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        openingKeys.shouldCapture = { [weak self] in self.map { !$0.panel.isVisible || $0.hiding } ?? false }
        // A measurement or test instance running beside the installed launcher leaves Command-Space to it.
        if ProcessInfo.processInfo.environment["SWIFTLIGHT_NO_HOTKEY"] != "1" {
            openingKeys.install()
            let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), EventHotKeyID(signature: 0x53504653, id: 1), GetApplicationEventTarget(), 0, &hotKey)
            if result != noErr { NSLog("Command-Space unavailable: %d", result); openingKeys.stop() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { _ in OpeningProbe.mark("key_notification") })
        panelPreparation = PanelOpenPreparation(name: NSWindow.didBecomeKeyNotification, object: panel,
            isReady: { [weak self] in
                guard let self, self.panel.isVisible, !self.hiding,
                      let editor = self.stage.field.field.currentEditor() else { return false }
                return self.panel.firstResponder === editor
            }, notify: { [weak self] in
                OpeningProbe.mark("panel_opened")
                self?.model.panelOpened()
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.previewing else { self.hide(); return }
                // Quick Look takes key focus when it opens or is clicked; the pill stays up behind it.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !(NSApp.keyWindow is QLPreviewPanel), NSApp.keyWindow !== self.panel else { return }
                    self.hide()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                // Quick Look takes key focus once it has opened, and only then honours an item index.
                // Unless it was clicked, the field takes focus back so the caret stays lit and typing
                // goes to the query.
                guard let self, notification.object is QLPreviewPanel, self.panel.isVisible, !self.hiding else { return }
                self.syncPreview()
                if NSApp.currentEvent?.type != .leftMouseDown { self.panel.makeKey() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
        model.$selectedPath.combineLatest(model.$browsing).sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncPreview() }
        }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.changingFrame else { return }
                self.updateResults()
            }
        })
        prepareHiddenPanel()
        // At login the launcher starts quietly in the menu bar; launching it yourself opens the pill.
        model.start(); if !LoginItem.launchedAtLogin { show() }
        if !UserDefaults.standard.bool(forKey: "folderAccessExplained") {
            model.accessFolders = FolderAccessFlow.folders.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reviewFolderAccess() }
        }
        if let seconds = ProcessInfo.processInfo.environment["SPOTLIGHT_EXIT_AFTER"].flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) } }
    }
    @objc func reviewFolderAccess() {
        if let accessWindow { NSApp.activate(ignoringOtherApps: true); accessWindow.makeKeyAndOrderFront(nil); return }
        let window = FolderAccessPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Swiftlight folder access"
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isMovableByWindowBackground = true
        accessModel.phase = .intro
        accessModel.statuses = Dictionary(uniqueKeysWithValues: FolderAccessFlow.folders.map { ($0, .waiting) })
        accessModel.onContinue = { [weak self] in self?.requestFolderAccess() }
        accessModel.onClose = { [weak self] in self?.accessWindow?.close(); self?.accessWindow = nil }
        let card = FolderAccessView(model: accessModel)
        window.contentView = card
        window.setContentSize(card.fittingSize)
        accessWindow = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "folderAccessExplained")
    }
    func requestFolderAccess() {
        accessModel.phase = .asking
        for name in FolderAccessFlow.folders { accessModel.statuses[name] = .waiting }
        accessFlow.begin()
        requestNextFolder()
    }
    func requestNextFolder() {
        guard let name = accessFlow.current else {
            accessModel.phase = .finished
            return
        }
        accessModel.statuses[name] = .asking
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
        // This open belongs to the foreground app. No protected I/O runs in show(), toggle() or the Carbon handler.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let allowed = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.accessModel.statuses[name] = allowed ? .allowed : .denied
                self.accessFlow.complete(allowed: allowed)
                self.requestNextFolder()
            }
        }
    }
    func prepareHiddenPanel() {
        let screen = NSScreen.main!
        viewport = screen.visibleFrame
        let target = NSRect(x: screen.frame.midX-260, y: screen.frame.midY + 606 / 2 - 91, width: 520, height: 91)
        setBackingFrame(viewport, pill: target)
        stage.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(stage.field.field)
    }
    @objc func toggle() { if panel.isVisible && !hiding { hide() } else { show() } }
    /// When the pill hid itself last; see `statusClicked`.
    var hideStartedAt: TimeInterval = -.infinity
    /// The menu bar icon shows the pill or puts it away. Clicking the icon takes focus from the pill, which hides it
    /// just before this runs; without this check the click would immediately show it again.
    @objc func statusClicked() {
        if ProcessInfo.processInfo.systemUptime - hideStartedAt < 0.5 { return }
        toggle()
    }
    func show() {
        model.panelOpened()
        presentationToken = UUID()
        hiding = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main!
        viewport = screen.visibleFrame
        let target = NSRect(x: screen.frame.midX-260, y: screen.frame.midY + 606 / 2 - 91, width: 520, height: 91)
        animationAssertions.removeAll()
        setBackingFrame(viewport, pill: target)
        panel.makeKeyAndOrderFront(nil)
        OpeningProbe.mark("key")
        panel.makeFirstResponder(stage.field.field)
        // Preserve native app-menu and Quick Look ownership after the field already owns keys.
        OpeningProbe.mark("responder")
        NSApp.activate(ignoringOtherApps: true)
        openingKeys.release(to: panel) { [self] event in
            if handlePreviewKey(event) { return true }
            return event.modifierFlags.contains(.command) && NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        }
        stage.pillSurface.layer?.removeAllAnimations()
        stage.pillSurface.layer?.transform = CATransform3DIdentity
        stage.resultsSurface.layer?.removeAllAnimations()
        stage.resultsSurface.layer?.transform = CATransform3DIdentity
        PanelPresentation.resetWindow(panel)
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("PRESENTATION_FOCUS key=\(panel.isKeyWindow) active=\(NSApp.isActive) responder=\(String(describing: panel.firstResponder))"); fflush(stdout) }
        updateResults()
        stage.layoutSubtreeIfNeeded()
        OpeningProbe.mark("layout_complete")
        if !SpotlightMotion.reduceMotion {
            let assertion = beginAnimation()
            let group = SpotlightMotion.compress(PanelPresentation.scaleAnimation(forOpening: true, collapsed: stage.resultsHeight == 0), to: SpotlightMotion.open)
            let completion = DispatchGroup()
            completion.enter()
            completion.enter()
            CATransaction.begin()
            CATransaction.setCompletionBlock { completion.leave() }
            stage.pillSurface.layer?.add(group, forKey: "invocation")
            CATransaction.commit()
            PanelPresentation.animate(panel, opening: true, duration: SpotlightMotion.open) { completion.leave() }
            completion.notify(queue: .main) { [weak self] in self?.finishAnimation(assertion) }
        }
        model.presented = true
        model.setActive(true)
        normalizeBackingFrame()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.window is QLPreviewPanel, self.panel.isVisible, !self.hiding {
                    // Keys pressed after clicking into the preview still drive the pill.
                    self.panel.makeKey()
                    if !self.handlePreviewKey(event) { self.panel.sendEvent(event) }
                    return nil
                }
                guard event.window === self.panel else { return event }
                if event.type == .keyDown {
                    if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("KEY_EVENT \(event.characters ?? "") \(event.modifierFlags.rawValue)"); fflush(stdout) }
                    return self.handlePreviewKey(event) ? nil : event
                }
                if !self.stage.results.isHidden, let identifier = SearchNativeUI.resultIdentifier(atWindowPoint: event.locationInWindow, in: self.stage.resultsContent) {
                    self.model.chooseAndOpen(identifier)
                    return nil
                }
                let hit = self.stage.hitTest(event.locationInWindow)
                if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("MOUSE_HIT \(event.locationInWindow) \(hit.map { String(describing: type(of: $0)) } ?? "nil")"); fflush(stdout) }
                if hit == nil { self.hide(); return nil }
                return event
            }
        }
        logGeometry()
    }
    func updateResults() {
        guard panel.isVisible, !hiding else { return }
        if stage.pillFrame.height != model.pillHeight {
            let pill = globalPillFrame()
            let resized = NSRect(x: pill.minX, y: pill.maxY-model.pillHeight, width: pill.width, height: model.pillHeight)
            setBackingFrame(viewport, pill: resized)
        }
        let available = max(86, globalPillFrame().minY - viewport.minY - 22)
        let height = model.text.isEmpty ? 0 : min(max(86, CGFloat(min(model.hits.count, 7, PresentationStage.maximumRows))*62+24), available)
        // Most keystrokes keep the same height; resizing, relayout and shadow invalidation are then wasted.
        if height == stage.resultsHeight && stage.resultsSurface.isHidden == (height == 0) {
            normalizeBackingFrame()
            return
        }
        // The surface takes its new height at once: a growing list is readable the moment its rows exist.
        stage.updateResults(height: height)
        normalizeBackingFrame()
        logGeometry()
    }
    func setBackingFrame(_ frame: NSRect, pill: NSRect) {
        changingFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        stage.frame = NSRect(origin: .zero, size: frame.size)
        stage.placePill(pill.offsetBy(dx: -frame.minX, dy: -frame.minY))
        stage.layoutSubtreeIfNeeded()
        panel.contentView?.needsDisplay = true
        panel.viewsNeedDisplay = true
        panel.displayIfNeeded()
        CATransaction.commit()
        panel.invalidateShadow()
        changingFrame = false
    }
    func globalPillFrame() -> NSRect { stage.pillFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) }
    func beginAnimation() -> UUID {
        let assertion = UUID()
        animationAssertions.insert(assertion)
        setBackingFrame(viewport, pill: globalPillFrame())
        return assertion
    }
    func finishAnimation(_ assertion: UUID) {
        guard animationAssertions.remove(assertion) != nil else { return }
        normalizeBackingFrame()
    }
    func normalizeBackingFrame() {
        guard animationAssertions.isEmpty, panel.isVisible, !hiding else { return }
        let pill = globalPillFrame()
        let extra = stage.resultsHeight > 0 ? stage.resultsHeight + 10 : 0
        let frame = NSRect(x: pill.minX, y: pill.minY-extra, width: pill.width, height: pill.height+extra)
        setBackingFrame(frame, pill: pill)
        logGeometry()
    }
    func logGeometry() {
        guard ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" else { return }
        let pill = stage.pillFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        print("PRESENTATION_GEOMETRY \(pill.origin.x) \(pill.origin.y) \(pill.width) \(pill.height) \(stage.resultsHeight)"); fflush(stdout)

    }
    /// Opens a result. LaunchServices is asked first; the pill leaves the screen in the same turn, without a
    /// dismissal animation, so nothing of the launcher sits over the app as it comes forward.
    func launch(_ target: ResultOpening.Target) {
        if panel.isVisible, !hiding { panel.alphaValue = 0 }
        ResultOpening.open(target)
        hide(animated: false)
    }
    func hide(animated: Bool = true) {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        model.panelClosed()
        hideStartedAt = ProcessInfo.processInfo.systemUptime
        if previewing { QLPreviewPanel.shared().orderOut(nil) }
        let token = UUID()
        presentationToken = token
        if !animated {
            // Transparent at once (one WindowServer property change, well under a millisecond); ordering the key
            // panel out costs ~20 ms of focus handover, so it happens next turn, after the open is under way.
            panel.alphaValue = 0
            OpeningProbe.mark("panel_transparent")
            // Clearing the query and resetting the surfaces is bookkeeping; it runs after the open is under way.
            DispatchQueue.main.async { [weak self] in self?.finishHide(token) }
            return
        }
        let finish: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.finishHide(token) }
        }
        guard !SpotlightMotion.reduceMotion else { finish(); return }
        _ = beginAnimation()
        let collapsed = stage.resultsHeight == 0
        let animation = SpotlightMotion.compress(PanelPresentation.scaleAnimation(forOpening: false, collapsed: collapsed), to: SpotlightMotion.dismiss)
        let completion = DispatchGroup()
        completion.enter()
        completion.enter()
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion.leave() }
        stage.pillSurface.layer?.transform = CATransform3DMakeScale(1.12, collapsed ? 0.95 : 1.12, 1)
        stage.pillSurface.layer?.removeAnimation(forKey: "invocation")
        stage.pillSurface.layer?.add(animation, forKey: "dismissal")
        CATransaction.commit()
        if !collapsed {
            completion.enter()
            CATransaction.begin()
            CATransaction.setCompletionBlock { completion.leave() }
            stage.resultsSurface.layer?.transform = CATransform3DMakeScale(1.12, 1.12, 1)
            stage.resultsSurface.layer?.add(SpotlightMotion.compress(PanelPresentation.scaleAnimation(forOpening: false, collapsed: false), to: SpotlightMotion.dismiss), forKey: "dismissal")
            CATransaction.commit()
        }
        PanelPresentation.animate(panel, opening: false, duration: SpotlightMotion.dismiss) { completion.leave() }
        completion.notify(queue: .main, execute: finish)
    }
    private func finishHide(_ token: UUID) {
        guard presentationToken == token else { return }
        panel.orderOut(nil)
        OpeningProbe.mark("panel_ordered_out")
        stage.pillSurface.layer?.removeAllAnimations()
        stage.pillSurface.layer?.transform = CATransform3DIdentity
        stage.resultsSurface.layer?.removeAllAnimations()
        stage.resultsSurface.layer?.transform = CATransform3DIdentity
        model.presented = false
        model.setActive(false)
        model.clear()
        stage.updateResults(height: 0)
        animationAssertions.removeAll()
        hiding = false
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("PRESENTATION_HIDDEN"); fflush(stdout) }
    }
    var previewing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    /// Space toggles Quick Look for the highlighted row; Escape closes the preview before the pill.
    func handlePreviewKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Space where model.browsing:
            if previewing { QLPreviewPanel.shared().orderOut(nil) }
            else if let preview = QLPreviewPanel.shared() {
                preview.updateController()
                syncPreview(preview)
                preview.orderFront(nil)
                if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { print("PREVIEW_OPEN \(preview.frame) key=\(self.panel.isKeyWindow) index=\(preview.currentPreviewItemIndex)"); fflush(stdout) }
                }
            }
            return true
        case kVK_Escape where previewing:
            QLPreviewPanel.shared().orderOut(nil)
            return true
        default: return false
        }
    }
    /// Quick Look holds the listed rows, as Finder's does a selection, and the arrows only move its
    /// index. Quick Look sizes and places itself, as it does from Finder.
    func syncPreview(_ preview: QLPreviewPanel? = nil) {
        guard let preview = preview ?? (previewing ? QLPreviewPanel.shared() : nil) else { return }
        let rows = model.browsing ? model.listedHits.map(\.path) : []
        guard let index = rows.firstIndex(where: { $0 == model.selectedPath }) else { preview.orderOut(nil); return }
        if rows != previewItems {
            previewItems = rows
            preview.reloadData()
        }
        if preview.currentPreviewItemIndex != index { preview.currentPreviewItemIndex = index }
    }
    override func acceptsPreviewPanelControl(_ preview: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ preview: QLPreviewPanel!) {
        preview.dataSource = self
        preview.delegate = self
        preview.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        // Quick Look's own ‹ › buttons move the highlight with them.
        previewIndexObservation = preview.observe(\.currentPreviewItemIndex) { [weak self] preview, _ in
            DispatchQueue.main.async {
                guard let self, self.previewing, self.previewItems.indices.contains(preview.currentPreviewItemIndex) else { return }
                let path = self.previewItems[preview.currentPreviewItemIndex]
                if path != self.model.selectedPath { self.model.highlight(path) }
            }
        }
    }
    override func endPreviewPanelControl(_ preview: QLPreviewPanel!) {
        preview.dataSource = nil
        preview.delegate = nil
        previewItems = []
        previewIndexObservation = nil
    }
    func previewPanel(_ preview: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let path = item.previewItemURL?.path else { return .zero }
        let row = stage.nativeResults.screenFrame(forIdentifier: path)
        // The zoom starts from the row's icon, as Finder's does from a file icon.
        return row.isEmpty ? .zero : NSRect(x: row.minX + 24, y: row.midY - 20, width: 40, height: 40)
    }
    func previewPanel(_ preview: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        item.previewItemURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    func numberOfPreviewItems(in preview: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ preview: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems.indices.contains(index) ? NSURL(fileURLWithPath: previewItems[index]) : nil
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationWillTerminate(_ notification: Notification) { openingKeys.stop(); model.stop(); if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
}
@main enum SpotlightLauncher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
