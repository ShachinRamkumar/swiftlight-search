import AppKit
import QuartzCore

/// Every transition in the launcher. Short enough that nothing waits on one: the pill is usable the moment it
/// starts to appear, and opening a result never waits for a dismissal.
@MainActor enum SpotlightMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The pill growing in and the window fading up.
    static let open: CFTimeInterval = 0.12
    /// Escape or a click away: the pill swells and fades.
    static let dismiss: CFTimeInterval = 0.1
    /// The results surface appearing below the pill. Its height changes snap.
    static let resultsFade: CFTimeInterval = 0.08
    /// A folder's status icon changing on the access card.
    static let status: CFTimeInterval = 0.12
    /// A changed result list waits briefly for the other searches before rows are rebuilt.
    static let resultsCoalescing = DispatchTimeInterval.milliseconds(20)

    /// Compresses a Core Animation group to `duration`, preserving its spring curve.
    static func compress(_ group: CAAnimationGroup, to duration: CFTimeInterval) -> CAAnimationGroup {
        if group.duration > duration { group.speed = Float(group.duration / duration) }
        return group
    }

    static func fadeIn(_ layer: CALayer?, duration: CFTimeInterval) {
        guard let layer, !reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
    }
}
