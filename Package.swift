// swift-tools-version:6.0
// Build the app with ./build.sh (wraps `swift build` into Leftovers.app and installs it).
// Run the tests with `swift test`.
import PackageDescription

let package = Package(
    name: "Leftovers",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updating from GitHub releases (https://sparkle-project.org); see tools/sparkle.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(name: "Leftovers", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Leftovers",
                          // Run straight from .build too (Sparkle.framework sits next to the binary there).
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
        .testTarget(name: "LeftoversTests", dependencies: ["Leftovers"], path: "Tests/LeftoversTests"),
    ],
    swiftLanguageModes: [.v5]
)
