// swift-tools-version: 6.2
import PackageDescription
// Swiftlight uses Core AI only; upstream LlamaRuntime/CLlama sources are intentionally not targets.
let vendor = "\(Context.packageDirectory)/Vendor"
let package = Package(name: "SpotlightModelRuntime", platforms: [.macOS("27.0")], products: [.executable(name: "digup", targets: ["digup"]), .library(name: "DigUpCoreAIRuntime", targets: ["DigUpCoreAIRuntime"]), .executable(name: "coreai-check", targets: ["coreai-check"]), .executable(name: "host-table-check", targets: ["host-table-check"]), .executable(name: "option-a-host-fixtures", targets: ["option-a-host-fixtures"]), .executable(name: "option-a-device-verify", targets: ["option-a-device-verify"])], targets: [
 .target(name: "DigUpKit", dependencies: ["CJPEG"], exclude: ["ModelFiles.swift", "FileFetcher.swift"]),
 .systemLibrary(name: "CTokenizer", path: "Sources/CTokenizer"),
 .target(name: "CJPEG", cSettings: [.unsafeFlags(["-I\(vendor)/libjpeg-turbo/include"])], linkerSettings: [.unsafeFlags(["\(vendor)/libjpeg-turbo/lib/libjpeg.a"])]),
 .target(name: "CZstd", exclude: ["README.md", "LICENSE"]),
 .target(name: "HostTableCodec", dependencies: ["CZstd"]),
 .target(name: "DigUpCoreAIRuntime", dependencies: ["DigUpKit", "CTokenizer", "HostTableCodec"], linkerSettings: [.unsafeFlags(["-L\(vendor)/hf-tokenizer/target/release"])]),
 .target(name: "OptionAVerificationSupport", dependencies: ["DigUpCoreAIRuntime", "DigUpKit"]),
 .executableTarget(name: "single-model-lifecycle", dependencies: ["DigUpCoreAIRuntime", "DigUpKit"]),
 .executableTarget(name: "option-a-host-fixtures", dependencies: ["OptionAVerificationSupport", "DigUpCoreAIRuntime", "DigUpKit"]),
 .executableTarget(name: "option-a-device-verify", dependencies: ["OptionAVerificationSupport", "DigUpCoreAIRuntime", "DigUpKit"]),
 .executableTarget(name: "host-table-check", dependencies: ["DigUpCoreAIRuntime", "HostTableCodec", "DigUpKit"]),
 .executableTarget(name: "coreai-check", dependencies: ["DigUpCoreAIRuntime", "CTokenizer"]),
 .executableTarget(name: "digup", dependencies: ["DigUpKit", "DigUpCoreAIRuntime"], exclude: ["DownloadModel.swift", "SearchService.swift"]),
 .testTarget(name: "PerfSafetyTests", dependencies: ["DigUpKit", "DigUpCoreAIRuntime", "HostTableCodec"])
])
