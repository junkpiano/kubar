import AppKit
import SwiftUI

@main
struct KubarApp: App {
    var body: some Scene {
        MenuBarExtra("Kubar", systemImage: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kubar is running")
                    .font(.headline)

                Text("Basic macOS menu bar app in Swift.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Button("Refresh Status") {
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("Quit Kubar") {
                    NSApp.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 220)
        }
        .menuBarExtraStyle(.window)
    }
}
