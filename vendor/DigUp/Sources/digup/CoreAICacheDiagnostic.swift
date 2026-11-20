import CoreAI
import DigUpCoreAIRuntime
import Foundation

@available(macOS 27, *)
func cacheDiagnostic(_ config: [String: Any]) throws -> [String: Any] {
    try RuntimeCacheIdentity.requireDiagnosticHelper()
    guard config["mode"] as? String == "cache-probe" else { throw CLIError("unknown cache diagnostic") }
    let url = URL(fileURLWithPath: config["asset"] as! String)
    let start = Date(), options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    var loaded = false, failure: String?
    do {
        if let model = try AIModelCache.default.model(for: url, options: options) {
            loaded = try model.loadFunction(named: "q32") != nil
        }
    } catch { failure = String(describing: error) }
    var result: [String: Any] = ["operation": "cache-probe", "loaded": loaded,
        "seconds": Date().timeIntervalSince(start), "namespace": RuntimeCacheIdentity.namespace,
        "signing_identifier": try RuntimeCacheIdentity.signingIdentifier()]
    if let failure { result["failure"] = failure }
    return result
}
