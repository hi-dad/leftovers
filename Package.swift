// swift-tools-version:6.0
// Build the app with ./build.sh (wraps `swift build` into Leftovers.app and installs it).
// Run the tests with `swift test`.
import PackageDescription

let package = Package(
    name: "Leftovers",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Leftovers", path: "Sources/Leftovers"),
        .testTarget(name: "LeftoversTests", dependencies: ["Leftovers"], path: "Tests/LeftoversTests"),
    ],
    swiftLanguageModes: [.v5]
)
