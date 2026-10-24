// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoverCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CoverCore", targets: ["CoverCore"])],
    targets: [
        .target(name: "CVorbis", exclude: ["vendor/LICENSE", "vendor/SOURCE.md"],
                sources: ["VorbisDecoder.c"], publicHeadersPath: "include"),
        .target(name: "CoverCore", dependencies: ["CVorbis"]),
        .testTarget(name: "CoverCoreTests", dependencies: ["CoverCore"], resources: [.copy("AudioFixtures")])
    ],
    swiftLanguageVersions: [.v5]
)
