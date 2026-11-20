import Foundation

@main struct AccessFlowCheck {
    static func main() {
        var flow = FolderAccessFlow()
        precondition(flow.current == nil && flow.remaining.isEmpty)
        flow.complete(allowed: false)
        precondition(flow.denied.isEmpty)
        flow.begin()
        precondition(flow.current == "Documents")
        flow.begin()
        flow.complete(allowed: false)
        precondition(flow.current == "Desktop" && flow.denied == ["Documents"])
        flow.complete(allowed: true)
        precondition(flow.current == "Downloads")
        flow.complete(allowed: true)
        precondition(flow.current == nil && flow.denied == ["Documents"])
        flow.begin()
        precondition(flow.current == "Documents" && flow.denied.isEmpty)
        precondition(FolderAccessFlow.message([]).isEmpty)
        precondition(FolderAccessFlow.message(["/fixture/Documents"]) == "Search needs access to Documents.")
        print("{\"passed\":true,\"foreground_action_required\":true,\"order\":[\"Documents\",\"Desktop\",\"Downloads\"],\"denial_continues\":true,\"retry\":true}")
    }
}
