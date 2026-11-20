import CryptoKit
import DigUpCoreAIRuntime
import DigUpKit
import Foundation

public struct VerificationError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum OptionAVerification {
    #if SINGLE_MODEL_RESEARCH
    public static let namespace = "org.swiftlight.storage.research.single-model"
    #else
    public static let namespace = "org.swiftlight.storage.research.option-a"
    #endif
    public static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftlight-research/option-a") }
    public static func confined(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = self.root.standardizedFileURL.resolvingSymlinksInPath()
        let single = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftlight-research/single-model").resolvingSymlinksInPath()
        guard (path.path.hasPrefix(root.path + "/") || path.path.hasPrefix(single.path + "/")),
              !path.path.contains("/Library/Application Support/Swiftlight/") else { throw VerificationError("path outside option A research: \(url.path)") }
        return path
    }
    public static func space(_ extra: Int64 = 0) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let free = (attributes[.systemFreeSize] as! NSNumber).int64Value
        guard free >= 14 * 1024 * 1024 * 1024 + extra else { throw VerificationError("14 GiB disk floor reached") }
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    public static func save<T: Encodable>(_ value: T, _ url: URL) throws {
        let url = try confined(url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public struct SavedTensor: Codable, Sendable {
    public let shape: [Int]
    public let path: String
    public let sha256: String
    public init(shape: [Int], path: String, sha256: String) { self.shape = shape; self.path = path; self.sha256 = sha256 }
}

public struct SavedFixture: Codable, Sendable {
    public let id: String
    public let family: String
    public let function: String
    public let inputs: [String: SavedTensor]
    public let bucket: Int?
    public let budget: Int?
    public let softTokens: Int?
    public let storedVector: String?
    public init(id: String, family: String, function: String, inputs: [String: SavedTensor], bucket: Int? = nil,
                budget: Int? = nil, softTokens: Int? = nil, storedVector: String? = nil) {
        self.id=id; self.family=family; self.function=function; self.inputs=inputs; self.bucket=bucket
        self.budget=budget; self.softTokens=softTokens; self.storedVector=storedVector
    }
}

public struct SavedFixtures: Codable, Sendable {
    public let cases: [SavedFixture]
    public let hostInputsExact: Bool
    public let originalManifestSHA256: String
    public let stagingManifestSHA256: String
    public init(cases: [SavedFixture], originalManifestSHA256: String, stagingManifestSHA256: String) {
        self.cases=cases; hostInputsExact=true; self.originalManifestSHA256=originalManifestSHA256; self.stagingManifestSHA256=stagingManifestSHA256
    }
}

@available(macOS 27, *)
public func saveInputs(_ inputs: [String: HostTensor], reference: [String: HostTensor], folder: URL) throws -> [String: SavedTensor] {
    let folder = try OptionAVerification.confined(folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard Set(inputs.keys) == Set(reference.keys) else { throw VerificationError("host input names differ") }
    var result: [String: SavedTensor] = [:]
    for name in inputs.keys.sorted() {
        let value=inputs[name]!, expected=reference[name]!
        guard value.shape == expected.shape, value.bits == expected.bits else { throw VerificationError("host input bits differ: \(name)") }
        let url=folder.appendingPathComponent(name + ".f16"), data=value.bytes
        try data.write(to: url)
        result[name]=SavedTensor(shape:value.shape,path:url.path,sha256:OptionAVerification.hash(data))
    }
    return result
}

@available(macOS 27, *)
public func loadInputs(_ fixture: SavedFixture) throws -> [String: HostTensor] {
    var result: [String: HostTensor] = [:]
    for (name, tensor) in fixture.inputs {
        let url=try OptionAVerification.confined(URL(fileURLWithPath:tensor.path)), data=try Data(contentsOf:url)
        guard data.count == tensor.shape.reduce(1, *) * 2, OptionAVerification.hash(data) == tensor.sha256 else { throw VerificationError("fixture input hash/size: \(name)") }
        result[name]=HostTensor(shape:tensor.shape,bits:data.withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) })
    }
    return result
}
