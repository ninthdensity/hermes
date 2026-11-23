// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLib = "\(root)/core/target/release"
// Swift Testing lives outside the default search paths when only the Command Line Tools are installed.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Hermes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hermes", targets: ["Hermes"]),
    ],
    targets: [
        .systemLibrary(name: "CHermesCore", path: "Sources/CHermesCore"),
        .target(
            name: "HermesKit",
            dependencies: ["CHermesCore"],
            linkerSettings: [.unsafeFlags(["-L", rustLib])]
        ),
        .target(name: "HermesApp", dependencies: ["HermesKit"]),
        .executableTarget(name: "Hermes", dependencies: ["HermesApp"]),
        // Drives the real editor offscreen: typing, formatting, paste, undo, save/reopen, export,
        // and renders the window to PNGs. Run with `swift run HermesAppHarness <output-dir>`.
        .executableTarget(name: "HermesAppHarness", dependencies: ["HermesApp", "HermesKit"], path: "Tests/HermesAppHarness"),
        // An executable rather than a test target: `swift test` cannot discover Swift Testing
        // suites under the Command Line Tools alone. Run with `swift run HermesKitTests`.
        .executableTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit"],
            path: "Tests/HermesKitTests",
            swiftSettings: [.unsafeFlags([
                "-F", cltFrameworks,
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
