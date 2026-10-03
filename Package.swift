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
        .executable(name: "KubarTray", targets: ["KubarTray"]),
    ],
    targets: [
        .executableTarget(name: "kubar", dependencies: ["KubarCore"], path: "Sources/kubar"),
        // Windows tray app (Win32 via WinSDK). On other platforms it builds to a stub that says so.
        .executableTarget(
            name: "KubarTray", dependencies: ["KubarCore"], path: "Sources/KubarTray",
            resources: [.copy("kubar.ico")],
            linkerSettings: [
                .linkedLibrary("comctl32", .when(platforms: [.windows])),
                // A GUI program: no console window when started from Explorer or at sign-in. The manifest asks for
                // Common Controls v6, which gives the popup's lists, drop-downs and buttons the current Windows look.
                .unsafeFlags([
                    "-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup",
                    "-Xlinker", "/MANIFEST:EMBED",
                    "-Xlinker", "/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'",
                ], .when(platforms: [.windows])),
            ]
        ),
        .target(name: "KubarCore"),
        .testTarget(name: "KubarCoreTests", dependencies: ["KubarCore"], path: "Tests/KubarCoreTests"),
    ]
)
