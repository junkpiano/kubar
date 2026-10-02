// swift-tools-version: 5.9
import PackageDescription

// KubarCore: platform-independent core (kubectl runner + parsing), no UI or Combine, so it builds on
// macOS, Linux and Windows. The `kubar` CLI depends on it; the macOS app (Kubar.xcodeproj) compiles
// the same Sources/KubarCore files directly, so keep new core files listed in both places.
let package = Package(
    name: "KubarCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KubarCore", targets: ["KubarCore"]),
        .executable(name: "kubar", targets: ["kubar"]),
    ],
    targets: [
        .executableTarget(name: "kubar", dependencies: ["KubarCore"], path: "Sources/kubar"),
        .target(name: "KubarCore"),
        .testTarget(name: "KubarCoreTests", dependencies: ["KubarCore"], path: "Tests/KubarCoreTests"),
    ]
)
