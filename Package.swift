// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AILimit", platforms: [.macOS(.v14)], products: [.library(name: "AILimitShared", targets: ["AILimitShared"]), .library(name: "AILimitCore", targets: ["AILimitCore"])], targets: [.target(name: "AILimitShared"), .target(name: "AILimitCore", dependencies: ["AILimitShared"]), .testTarget(name: "AILimitCoreTests", dependencies: ["AILimitCore", "AILimitShared"], resources: [.copy("Fixtures")])], swiftLanguageModes: [.v6])
