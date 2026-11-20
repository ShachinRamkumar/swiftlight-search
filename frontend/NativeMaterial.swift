import AppKit
import SwiftUI

/// A translucent surface filling its bounds using public macOS material APIs.
/// Uses SwiftUI Liquid Glass on macOS 26+ when built with the macOS 26 SDK,
/// and falls back to AppKit's NSVisualEffectView on earlier macOS versions.
final class GlassSurfaceView: NSView {
    enum Kind {
        case pill
        case results
        case card
    }

    private let contentView: NSView

    init(kind: Kind, cornerRadius: CGFloat) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let host = NSHostingView(rootView: PublicGlassShape(
                cornerRadius: cornerRadius,
                clipped: kind == .results,
                darkScheme: kind != .card
            ))
            host.sizingOptions = []
            contentView = host
        } else {
            contentView = Self.makeVisualEffectView(kind: kind, cornerRadius: cornerRadius)
        }
        #else
        contentView = Self.makeVisualEffectView(kind: kind, cornerRadius: cornerRadius)
        #endif
        super.init(frame: .zero)
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }

    private static func makeVisualEffectView(kind: Kind, cornerRadius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = kind == .card ? .popover : .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        if kind != .card {
            effect.appearance = NSAppearance(named: .vibrantDark)
        }
        return effect
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private struct PublicGlassShape: View {
    let cornerRadius: CGFloat
    let clipped: Bool
    let darkScheme: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = GlassEffectContainer(spacing: 100) {
            Color.clear.glassEffect(.regular, in: shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Group {
            if clipped { surface.clipShape(shape) } else { surface }
        }
        .transformEnvironment(\.colorScheme) { scheme in
            if darkScheme { scheme = .dark }
        }
        .ignoresSafeArea()
    }
}
#endif
