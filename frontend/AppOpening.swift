import AppKit

/// Opens a result the moment Return is pressed. The launcher already knows what is selected (the backend confirmed
/// it for this query), so nothing waits on the backend, on a dismissal animation or on bookkeeping: LaunchServices
/// is asked first, the pill is gone in the same run-loop turn, and ranking history is written afterwards.
@MainActor enum ResultOpening {
    /// A result's open request, resolved ahead of Return while it is selected.
    struct Target: Equatable {
        let path: String
        let url: URL
        let application: Bool
        let bundleIdentifier: String?
    }
    private static var prepared: Target?

    /// Called whenever the selection changes: resolves the URL and bundle identifier now so Return does no
    /// Info.plist read or URL construction.
    static func prepare(_ hit: SearchHit?) {
        guard let hit else { prepared = nil; return }
        guard prepared?.path != hit.path else { return }
        prepared = Target(path: hit.path, url: URL(fileURLWithPath: hit.path), application: hit.kind == "app", bundleIdentifier: hit.bundleIdentifier)
    }

    static func target(for hit: SearchHit) -> Target {
        if let prepared, prepared.path == hit.path { return prepared }
        prepare(hit)
        return prepared!
    }

    /// Asks LaunchServices to open the target. Returns at once; LaunchServices launches or activates on its own
    /// threads. `addsToRecentItems` stays on (turning it off measured no faster) and activation is not yielded first
    /// (also no faster).
    static func open(_ target: Target) {
        OpeningProbe.mark("launch_request")
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" {
            print("OPEN_SELECTED \(target.path)"); fflush(stdout)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let report: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            if let error { NSLog("Swiftlight could not open %@: %@", target.path, String(describing: error)) }
        }
        guard target.application else {
            NSWorkspace.shared.open(target.url, configuration: configuration, completionHandler: report)
            return
        }
        // An app that is already running comes forward directly: measured 4 ms to activation, against 21 ms through
        // LaunchServices. The LaunchServices open still follows, as from the Dock, so a hidden app unhides and one
        // with no windows opens one.
        if let identifier = target.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { !$0.isTerminated }) {
            running.activate(from: NSRunningApplication.current, options: [])
            OpeningProbe.mark("activated_running")
        }
        NSWorkspace.shared.openApplication(at: target.url, configuration: configuration, completionHandler: report)
        OpeningProbe.mark("launch_requested")
    }
}
