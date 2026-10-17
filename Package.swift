// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jarvis",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
    ],
    targets: [
        .target(name: "JarvisCore"),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ],
    // D-2: language mode 5 so strict concurrency does not block older CLT builds.
    swiftLanguageModes: [.v5]
)
