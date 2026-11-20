import AppKit
import ServiceManagement

/// Opens Swiftlight when you log in. The installed app registers itself once; turning it off afterwards in
/// System Settings → General → Login Items is respected (it is not added again).
@MainActor enum LoginItem {
    private static let offeredKey = "loginItemRegistered"

    /// Whether this launch came from the login items rather than from you, so the pill stays hidden until summoned.
    static var launchedAtLogin = false

    /// Call from `applicationWillFinishLaunching`, while the launch Apple event is still current.
    static func noteLaunchEvent() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func registerOnce() {
        let environment = ProcessInfo.processInfo.environment
        // Test and verification instances run from the build folder; only the installed app belongs at login.
        guard environment["SPOTLIGHT_VERIFY"] == nil, environment["SPOTLIGHT_EXIT_AFTER"] == nil,
              Bundle.main.bundlePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path)
                || Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: offeredKey)
        } catch {
            NSLog("Swiftlight login item registration failed: %@", String(describing: error))
        }
    }
}
