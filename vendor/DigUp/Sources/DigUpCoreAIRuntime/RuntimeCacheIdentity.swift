import DigUpKit
import Darwin
import Foundation
import Security

public enum RuntimeCacheIdentity {
    public static let osBuild: String = {
        var size = 256
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.operatingSystemVersionString }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    static func matchesCurrentOS(build: String?, legacyVersion: String?) -> Bool {
        if let build { return build == osBuild }
        return legacyVersion == ProcessInfo.processInfo.operatingSystemVersionString
    }
    public static let productionIdentifier = "com.shachin.swiftlight.indexer"
    public static let productionNamespace = "com.shachin.swiftlight.indexer"
    public static let diagnosticIdentifier = "com.shachin.swiftlight.validation"

    public static var namespace: String {
        Bundle.main.bundleIdentifier ?? URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    }

    public static func requireCacheOwner() throws {
        let identifier = try signingIdentifier()
        try validateOwner(identifier: identifier, namespace: namespace,
                          testNamespace: ProcessInfo.processInfo.environment["DIGUP_COREAI_TEST_NAMESPACE"])
    }

    public static func validateOwner(identifier: String, namespace: String, testNamespace: String? = nil) throws {
        #if SINGLE_MODEL_RESEARCH
        if ["org.swiftlight.storage.research.single-model", "org.swiftlight.storage.research.compile-speed"].contains(identifier), namespace == identifier { return }
        #endif
        let isolatedTest = identifier == productionIdentifier && namespace == testNamespace
            && namespace.hasPrefix(productionNamespace + ".test.")
        guard (identifier == productionIdentifier && namespace == productionNamespace)
            || (identifier == diagnosticIdentifier && namespace == diagnosticIdentifier) || isolatedTest else {
            throw WorkerError.failed("Core AI cache owner mismatch: signer=\(identifier), namespace=\(namespace)")
        }
    }

    public static func validate(_ identifier: String) throws {
        guard identifier == productionIdentifier else {
            throw WorkerError.failed("Core AI cache identity mismatch: expected \(productionIdentifier), got \(identifier); install the signed helper before preparing models")
        }
    }

    public static func requireProductionHelper() throws {
        try validate(signingIdentifier())
        guard namespace == productionNamespace else {
            throw WorkerError.failed("Core AI production namespace mismatch: \(namespace)")
        }
    }

    public static func requireDiagnosticHelper() throws {
        try requireCacheOwner()
        guard try signingIdentifier() == diagnosticIdentifier else {
            throw WorkerError.failed("Core AI diagnostics require the separately signed validation helper")
        }
    }

    public static func signingIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            throw WorkerError.failed("cannot inspect Core AI helper signing identity")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw WorkerError.failed("cannot inspect Core AI helper static signing identity")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any], let identifier = fields[kSecCodeInfoIdentifier as String] as? String else {
            throw WorkerError.failed("Core AI helper has no signing identity")
        }
        return identifier
    }
}
