import Foundation

@main struct PanelOpenTests {
    @MainActor static func main() {
        let center = NotificationCenter()
        let name = Notification.Name("panel-open-test")
        let panel = NSObject()
        var visible = true
        var focused = false
        var delivered = 0
        let observer = PanelOpenPreparation(center: center, name: name, object: panel,
            isReady: { visible && focused }, notify: { delivered += 1 })
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        center.post(name: name, object: panel)
        precondition(delivered == 0, "Opening notification must return before delivery")
        focused = true
        drain()
        precondition(delivered == 1, "Delivery must check focus after the opening returns")
        focused = false
        center.post(name: name, object: panel)
        drain()
        precondition(delivered == 1, "Unfocused fields must not prepare")
        focused = true
        center.post(name: name, object: panel)
        visible = false
        drain()
        precondition(delivered == 1, "A panel hidden before delivery must not prepare")
        visible = true
        center.post(name: name, object: panel)
        precondition(delivered == 1)
        drain()
        precondition(delivered == 2, "Reopening must notify again after idle release")
        center.post(name: name, object: NSObject())
        drain()
        precondition(delivered == 2, "Another window must not prepare")
        withExtendedLifetime(observer) {}
        print("PASS: deferred delivery, focus, hiding, reopening and unrelated windows")
    }
}
