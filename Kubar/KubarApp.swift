import AppKit
import SwiftUI

@main
struct KubarApp: App {
    @StateObject private var state = KubarState()

    init() {
        #if DEBUG
        KubeConfigModelsSelfCheck.run()
        ConnectionStatusSelfCheck.run()
        KubectlRunnerSelfCheck.run()
        #endif
    }

    var body: some Scene {
        MenuBarExtra("Kubar", systemImage: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kubar")
                    .font(.headline)

                if let loadError = state.loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Context", selection: Binding(
                        get: { state.selectedContext ?? "" },
                        set: { newValue in
                            Task { await state.selectContext(newValue) }
                        }
                    )) {
                        ForEach(state.contexts, id: \.self) { context in
                            Text(context).tag(context)
                        }
                    }
                    .labelsHidden()

                    statusView
                }

                Divider()

                Button("Refresh Status") {
                    Task { await state.refreshStatus() }
                }

                Button("Quit Kubar") {
                    NSApp.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 260)
            .task {
                await state.load()
            }
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.connectionStatus {
        case .idle:
            Text("Idle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .checking:
            Text("Checking…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .connected:
            Text("Connected")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .checkFailed(let message):
            Text("Check failed: \(message)")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }
}
