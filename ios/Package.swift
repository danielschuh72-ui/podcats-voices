// swift-tools-version:5.9
// Only for checking the Foundation-only part (Podcats/Core) off a Mac: `swift test`.
// The app itself is built from project.yml (XcodeGen); Xcode does not use this file.
import PackageDescription

let package = Package(
    name: "PodcatsCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PodcatsCore", path: "Podcats/Core"),
        .testTarget(name: "PodcatsCoreTests", dependencies: ["PodcatsCore"], path: "CoreTests", resources: [.copy("fixtures")]),
    ]
)
