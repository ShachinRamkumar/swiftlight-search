import AppKit

/// Borderless panels refuse key status by default; onboarding needs it for its buttons and Return.
final class FolderAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class FolderAccessModel {
    enum Status { case waiting, asking, allowed, denied }
    enum Phase { case intro, asking, finished }
    var phase = Phase.intro { didSet { if phase != oldValue { changed() } } }
    var statuses = Dictionary(uniqueKeysWithValues: FolderAccessFlow.folders.map { ($0, Status.waiting) }) { didSet { if statuses != oldValue { changed() } } }
    var onContinue: () -> Void = {}
    var onClose: () -> Void = {}
    /// The card redraws from the model when it changes.
    var changed: () -> Void = {}
    var denied: [String] { FolderAccessFlow.folders.filter { statuses[$0] == .denied } }
}

/// The folder-access card: one Liquid Glass surface, like the search pill, with each folder's answer shown as it
/// arrives.
@MainActor final class FolderAccessView: NSView {
    private let model: FolderAccessModel
    private let card = GlassSurfaceView(kind: .card, cornerRadius: 30)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let notNow = NSButton(title: "Not Now", target: nil, action: nil)
    private let settings = NSButton(title: "Open Settings", target: nil, action: nil)
    private let primary = NSButton(title: "Continue", target: nil, action: nil)
    private var statusViews: [String: FolderStatusView] = [:]

    init(model: FolderAccessModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = AccentBadge(symbol: "magnifyingglass")
        let title = NSTextField(labelWithString: "Let Swiftlight search your files")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 420 - 48 - 46 - 14
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 3
        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 14

        let rows = NSStackView(views: FolderAccessFlow.folders.map { name in
            let status = FolderStatusView()
            statusViews[name] = status
            return FolderRow(name: name, symbol: Self.symbols[name] ?? "folder", status: status)
        })
        rows.orientation = .vertical; rows.spacing = 6
        for row in rows.arrangedSubviews { row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }

        for button in [notNow, settings, primary] {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                button.bezelStyle = .glass
            } else {
                button.bezelStyle = .rounded
            }
            #else
            button.bezelStyle = .rounded
            #endif
            button.controlSize = .large
            button.target = self
        }
        notNow.action = #selector(close); notNow.keyEquivalent = "\u{1b}"
        settings.action = #selector(openSettings)
        primary.action = #selector(primaryAction); primary.keyEquivalent = "\r"
        primary.bezelColor = .controlAccentColor
        primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 72 + 28).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [notNow, settings, spacer, primary])
        buttons.orientation = .horizontal; buttons.spacing = 10

        let content = NSStackView(views: [header, rows, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [rows, buttons] { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true }

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 420),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        model.changed = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        subtitle.stringValue = switch model.phase {
        case .intro: "Click Continue, then Allow in each macOS prompt. Folders you skip stay out of search."
        case .asking: "Answer the macOS prompt. Search keeps working while you decide."
        case .finished where model.denied.isEmpty: "All set. Search covers every folder below."
        case .finished: "Turn on Swiftlight in Files and Folders, then try again. Other folders stay searchable."
        }
        primary.title = switch model.phase {
        case .intro, .asking: "Continue"
        case .finished: model.denied.isEmpty ? "Done" : "Try Again"
        }
        primary.isEnabled = model.phase != .asking
        notNow.isHidden = model.phase != .intro
        settings.isHidden = !(model.phase == .finished && !model.denied.isEmpty)
        for (name, view) in statusViews { view.status = model.statuses[name] ?? .waiting }
    }

    @objc private func close() { model.onClose() }
    @objc private func openSettings() {
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: settingsURL, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func primaryAction() {
        if model.phase == .finished, model.denied.isEmpty { model.onClose() } else { model.onContinue() }
    }

    private static let symbols = ["Documents": "doc.text", "Desktop": "menubar.dock.rectangle", "Downloads": "arrow.down.circle"]
}

/// The white glyph on an accent-colored circle at the top of the card.
private final class AccentBadge: NSView {
    private let gradient = CAGradientLayer()
    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.cornerRadius = 23
        layer?.addSublayer(gradient)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold))!)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 46), heightAnchor.constraint(equalToConstant: 46),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); gradient.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // SwiftUI's Color.accentColor.gradient, sampled: the accent lifted about 27% toward white at the top and 6% at
        // the bottom. The layer is not flipped, so the first color is the bottom one.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            func lifted(_ amount: CGFloat) -> CGColor {
                CGColor(srgbRed: accent.redComponent + (1 - accent.redComponent) * amount, green: accent.greenComponent + (1 - accent.greenComponent) * amount,
                        blue: accent.blueComponent + (1 - accent.blueComponent) * amount, alpha: 1)
            }
            gradient.colors = [lifted(0.06), lifted(0.27)]
        }
    }
}

/// One folder on the card: its symbol, name and the answer to its prompt.
private final class FolderRow: NSView {
    init(name: String, symbol: String, status: FolderStatusView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        for view in [icon, label, status] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), icon.widthAnchor.constraint(equalToConstant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 20), status.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // SwiftUI's `.quaternary.opacity(0.6)` fill.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(NSColor.quaternaryLabelColor.alphaComponent * 0.6).cgColor
        }
    }
}

/// Waiting, asking (a spinner), allowed or denied; a change cross-fades.
private final class FolderStatusView: NSView {
    private let image = NSImageView()
    private let spinner = NSProgressIndicator()
    var status: FolderAccessModel.Status = .waiting {
        didSet {
            guard status != oldValue else { return }
            if !SpotlightMotion.reduceMotion {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = SpotlightMotion.status
                layer?.add(fade, forKey: "status")
            }
            apply()
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [image, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: centerXAnchor), view.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func apply() {
        let (symbol, color): (String?, NSColor) = switch status {
        case .waiting: ("circle.dotted", .tertiaryLabelColor)
        case .asking: (nil, .clear)
        case .allowed: ("checkmark.circle.fill", .systemGreen)
        case .denied: ("exclamationmark.circle.fill", .systemOrange)
        }
        image.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        image.contentTintColor = color
        image.isHidden = symbol == nil
        if status == .asking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let label = switch status { case .waiting: "Waiting"; case .asking: "Asking"; case .allowed: "Allowed"; case .denied: "Not allowed" }
        setAccessibilityLabel(label)
    }
}
