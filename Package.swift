// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoverCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CoverCore", targets: ["CoverCore"])],
    targets: [
        .target(name: "CoverCore"),
        .testTarget(name: "CoverCoreTests", dependencies: ["CoverCore"])
    ],
    swiftLanguageVersions: [.v5]
)
