import AppKit
import Carbon

/// A session tap owns only the opening gap. Normal typing goes through AppKit unchanged.
@MainActor final class OpeningKeyBuffer {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holding = false
    private var pending: [CGEvent] = []
    private var timeout: DispatchWorkItem?
    var shouldCapture: () -> Bool = { false }

    func install() {
        // Never request a new permission. Carbon remains available if permission was not granted.
        guard CGPreflightListenEventAccess() else { return }
        let mask = 1 << CGEventType.keyDown.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<OpeningKeyBuffer>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("OPENING_BUFFER installed"); fflush(stdout) }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            release(to: nil)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if event.flags.contains(.maskCommand), code == kVK_Tab {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, code == kVK_Space, event.flags.contains(.maskCommand), !event.flags.contains(.maskAlternate), !event.flags.contains(.maskControl), !event.flags.contains(.maskShift) {
            if shouldCapture(), !holding {
                holding = true
                pending.removeAll(keepingCapacity: true)
                // If Carbon registration ever fails, return captured events to their original app.
                let work = DispatchWorkItem { [weak self] in self?.release(to: nil) }
                timeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: work)
            }
            return Unmanaged.passUnretained(event)
        }
        guard holding else { return Unmanaged.passUnretained(event) }
        if let copy = event.copy() { pending.append(copy) }
        return nil
    }
    func release(to panel: NSPanel?, consuming: ((NSEvent) -> Bool)? = nil) {
        holding = false
        timeout?.cancel(); timeout = nil
        let events = pending
        pending.removeAll(keepingCapacity: true)
        if !events.isEmpty, ProcessInfo.processInfo.environment["SPOTLIGHT_VERIFY"] == "1" { print("OPENING_REPLAY count=\(events.count)"); fflush(stdout) }
        for event in events {
            if let panel, let converted = NSEvent(cgEvent: event),
               let native = NSEvent.keyEvent(with: .keyDown, location: converted.locationInWindow,
                   modifierFlags: converted.modifierFlags, timestamp: converted.timestamp,
                   windowNumber: panel.windowNumber, context: nil,
                   characters: converted.characters ?? "", charactersIgnoringModifiers: converted.charactersIgnoringModifiers ?? "",
                   isARepeat: converted.isARepeat, keyCode: converted.keyCode) {
                if consuming?(native) != true { panel.sendEvent(native) }
            } else {
                // Posting below this tap avoids recapture if the hotkey was not delivered.
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
    func stop() {
        release(to: nil)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}
