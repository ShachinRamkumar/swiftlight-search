import Darwin
import Foundation

public enum RuntimeReadiness {
    public static var logURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let production = home.appendingPathComponent("Library/Application Support/Swiftlight")
        let research = RuntimeCacheIdentity.namespace.hasPrefix("org.swiftlight.storage.research.")
        if let path = ProcessInfo.processInfo.environment["DIGUP_COREAI_LOG"] {
            let url = URL(fileURLWithPath: path)
            if !research || !url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(production.path + "/") { return url }
        }
        if research { return home.appendingPathComponent(".swiftlight-research/" + RuntimeCacheIdentity.namespace + ".log") }
        return production.appendingPathComponent("launcher.log")
    }

    @available(macOS 27, *)
    public static func record(_ runtime: RuntimeDirectory, role: String, status: String,
                              functions: [String], failure: String? = nil) {
        do {
            try RuntimeCacheIdentity.requireCacheOwner()
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime.assets.manifest)) as! [String: Any]
            var state: [String: Any] = ["pid": getpid(), "role": role, "status": status,
                "signing_identifier": try RuntimeCacheIdentity.signingIdentifier(), "namespace": RuntimeCacheIdentity.namespace,
                "os_build": RuntimeCacheIdentity.osBuild, "runtime": runtime.directory.path,
                "source_hashes": manifest["files"] ?? [:], "function_assets": runtime.assets.functionAssets,
                "functions": functions, "options": ["preferredComputeUnitKind": "neuralEngine", "cachePolicy": "persistent"],
                "updated": Date().timeIntervalSince1970]
            if let failure { state["failure"] = failure }
            let directory = runtime.directory.deletingLastPathComponent().appendingPathComponent(".coreai-readiness")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(
                to: directory.appendingPathComponent("\(getpid())-\(role).json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[coreai-readiness] state write failed: \(error)\n".utf8))
        }
    }
}
