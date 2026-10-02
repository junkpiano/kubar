// swift-tools-version: 5.9
import PackageDescription

// Platform-independent core (kubectl runner + parsing). Shares sources with the macOS app target,
// so the same files are built by Xcode (app) and SwiftPM (`swift test`, Windows/Linux).
// KubarState.swift is excluded: it uses Combine (@Published), which doesn't exist on Windows.
let package = Package(
    name: "KubarCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "KubarCore", path: "Kubar/Kubernetes", exclude: ["KubarState.swift"]),
        .testTarget(name: "KubarCoreTests", dependencies: ["KubarCore"], path: "Tests/KubarCoreTests"),
    ]
)
