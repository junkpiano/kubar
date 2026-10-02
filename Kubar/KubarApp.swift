import AppKit
import SwiftUI

@main
struct KubarApp: App {
    @StateObject private var state = KubarState()
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        KubeConfigModelsSelfCheck.run()
        ConnectionStatusSelfCheck.run()
        KubectlRunnerSelfCheck.run()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kubar")
                    .font(.headline)

                if let loadError = state.loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let hint = ConnectionHint.suggest(for: loadError) { hintView(hint) }
                } else {
                    labeled("Context") { Picker("Context", selection: Binding(
                        get: { state.selectedContext ?? "" },
                        set: { newValue in
                            Task { await state.selectContext(newValue) }
                        }
                    )) {
                        ForEach(state.contexts, id: \.self) { context in
                            Text(context).tag(context)
                        }
                    }
                    .labelsHidden() }

                    statusView

                    header("Nodes (\(state.nodes.count))")
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.nodes) { node in
                                Button {
                                    guard let context = state.selectedContext else { return }
                                    openWindow(value: NodeRef(context: context, name: node.name))
                                    NSApp.activate(ignoringOtherApps: true)
                                } label: {
                                    nodeCard(node)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(state.nodes.count) * 64, 256))

                    workloadViews
                }

                Divider()

                Button("Refresh Status") {
                    Task { await state.refreshStatus(silent: true) }
                }

                Button("Quit Kubar") {
                    NSApp.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 580)
            .task {
                await state.onOpen()
            }
            .task {
                // Watch mode: poll while the view is alive. ponytail: fixed 10s poll, swap for `kubectl get -w` streams if latency matters.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    await state.refreshStatus(silent: true)
                }
            }
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Node", for: NodeRef.self) { $ref in
            if let ref { NodeDetailView(ref: ref) }
        }
        .defaultSize(width: 760, height: 560)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }

    private func gauge(_ label: String, _ value: String, _ percent: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            ProgressView(value: Double(min(percent, 100)), total: 100)
                .tint(percent >= 85 ? .red : percent >= 70 ? .orange : .green)
                .frame(width: 110)
            Text("\(value) · \(percent)%")
        }
    }

    private func nodeCard(_ node: NodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(node.ready ? "●" : "○") \(node.name)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(node.ready ? .green : .red)
                Spacer()
                Text(node.roles == "<none>" ? node.version : "\(node.roles) · \(node.version)")
                    .foregroundStyle(.secondary)
            }
            if let usage = node.usage {
                HStack(spacing: 20) {
                    gauge("CPU", usage.cpu, usage.cpuPct)
                    gauge("Mem", usage.mem, usage.memPct)
                }
            } else {
                Text("metrics unavailable").foregroundStyle(.secondary)
            }
            Text("\(node.capacity) · \(node.os) · \(node.runtime)")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    // Context -> namespace -> deployment -> pods: each level narrows the one above.
    @ViewBuilder
    private var workloadViews: some View {
        if !state.namespaces.isEmpty {
            header("Workloads")
            labeled("Namespace") {
                Picker("Namespace", selection: Binding(
                    get: { state.selectedNamespace },
                    set: { value in Task { await state.selectNamespace(value) } }
                )) {
                    Text("Select… (\(state.namespaces.count))").tag(String?.none)
                    ForEach(state.namespaces, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
            }
        }
        if let namespace = state.selectedNamespace {
            labeled("Deployment") {
                if state.deployments.isEmpty {
                    Text("No deployments in \(namespace)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Picker("Deployment", selection: Binding(
                            get: { state.selectedDeployment },
                            set: { value in Task { await state.selectDeployment(value) } }
                        )) {
                            Text("Select… (\(state.deployments.count))").tag(String?.none)
                            ForEach(state.deployments) { Text("\($0.name)   \($0.ready)/\($0.desired) ready").tag(Optional($0.name)) }
                        }
                        .labelsHidden()
                        if let name = state.selectedDeployment {
                            Menu {
                                Button("Restart…") {
                                    confirmAndRun(.restartDeployment(name), title: "Restart deployment \(name)?",
                                                  detail: "Its pods are replaced one by one (rolling restart).", button: "Restart", destructive: false)
                                }
                                Button("Delete…", role: .destructive) {
                                    confirmAndRun(.deleteDeployment(name), title: "Delete deployment \(name)?",
                                                  detail: "The deployment and all its pods are removed.", button: "Delete", destructive: true)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Deployment actions")
                        }
                    }
                }
            }
        }
        if let deployment = state.selectedDeployment {
            header("Pods of \(deployment) (\(state.pods.count))")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(state.pods) { pod in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pod.name)
                                    .font(.callout.weight(.semibold))
                                (Text("\(pod.ok ? "●" : "○") \(pod.status)").foregroundColor(pod.ok ? .green : .orange)
                                    + Text("  ·  \(pod.ready) ready  ·  \(pod.restarts) restarts  ·  node \(pod.node)").foregroundColor(.secondary))
                                    .font(.caption)
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                confirmAndRun(.deletePod(pod.name), title: "Delete pod \(pod.name)?",
                                              detail: "Its deployment creates a replacement, so this restarts the pod.", button: "Delete", destructive: true)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete pod (restarts it)")
                        }
                        .frame(height: 38, alignment: .topLeading)
                        .textSelection(.enabled)
                    }
                }
            }
            .frame(height: min(CGFloat(max(state.pods.count, 1)) * 38, 228))
        }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Check failed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let hint = ConnectionHint.suggest(for: message) { hintView(hint) }
            }
        }
    }

    /// Asks for confirmation (showing the context and namespace, since this changes the cluster), then runs the action.
    private func confirmAndRun(_ action: KubarState.WorkloadAction, title: String, detail: String, button: String, destructive: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(detail)\n\nContext: \(state.selectedContext ?? "?")\nNamespace: \(state.selectedNamespace ?? "?")"
        alert.alertStyle = destructive ? .critical : .warning
        let confirm = alert.addButton(withTitle: button)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard let error = await state.perform(action) else { return }
            let failure = NSAlert()
            failure.messageText = "\(button) failed"
            failure.informativeText = error
            failure.alertStyle = .warning
            failure.runModal()
        }
    }

    private func hintView(_ hint: ConnectionHint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("💡 \(hint.text)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let command = hint.command {
                HStack {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct NodeDetailView: View {
    let ref: NodeRef
    @State private var text = "Loading…"

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle("\(ref.name) — \(ref.context)")
        .task {
            // Watch mode: re-describe every 10s; keep the last good text if a refresh fails.
            while !Task.isCancelled {
                let out = await KubeClient.output(ref.context, ["describe", "node", ref.name])
                if !out.isEmpty { text = out } else if text == "Loading…" { text = "Couldn't describe node (timed out or forbidden)" }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
