import Foundation

@MainActor
final class KubarState: ObservableObject {
    @Published private(set) var contexts: [String] = []
    @Published private(set) var selectedContext: String?
    @Published private(set) var connectionStatus: ConnectionStatus = .idle
    @Published private(set) var loadError: String?
    @Published private(set) var namespaces: [String] = []
    @Published private(set) var selectedNamespace: String?
    @Published private(set) var deployments: [DeploymentInfo] = []
    @Published private(set) var selectedDeployment: String?
    @Published private(set) var pods: [PodInfo] = []
    @Published private(set) var nodes: [NodeInfo] = []

    private let defaults: UserDefaults
    private let selectedContextKey = "KubarSelectedContext"
    private var currentCheckToken = UUID()
    private var currentLoadToken = UUID()
    private var currentWorkloadToken = UUID()
    private var hasLoaded = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func resolveSelection(loadedContexts: [String], saved: String?, currentContext: String?) -> String? {
        if let saved, loadedContexts.contains(saved) { return saved }
        if let currentContext, loadedContexts.contains(currentContext) { return currentContext }
        return loadedContexts.first
    }

    /// Called each time the menu opens: full load the first time, afterwards a quiet refresh that keeps the user's selections.
    func onOpen() async {
        if hasLoaded {
            await refreshStatus(silent: true)
        } else {
            hasLoaded = true
            await load()
        }
    }

    func load() async {
        let token = UUID()
        currentLoadToken = token
        let result = await KubeContextStore.loadContexts()
        guard token == currentLoadToken else { return }
        switch result {
        case .binaryNotFound:
            loadError = "kubectl not found"
            contexts = []
        case .configLoadFailed(let message):
            loadError = "couldn't load kubeconfig: \(message)"
            contexts = []
        case .loaded(let loadedContexts, let currentContext):
            loadError = loadedContexts.isEmpty ? "No contexts found" : nil
            contexts = loadedContexts
            let saved = defaults.string(forKey: selectedContextKey)
            let resolved = Self.resolveSelection(loadedContexts: loadedContexts, saved: saved, currentContext: currentContext)
            selectedContext = resolved
            if let resolved {
                defaults.set(resolved, forKey: selectedContextKey)
            }
        }
        await refreshStatus()
    }

    func selectContext(_ name: String) async {
        guard contexts.contains(name) else { return }
        selectedContext = name
        defaults.set(name, forKey: selectedContextKey)
        await refreshStatus()
    }

    /// `silent` is for background polling: keep the current lists and status on screen while re-checking.
    func refreshStatus(silent: Bool = false) async {
        if !silent { clearResources() }
        guard let context = selectedContext else {
            connectionStatus = .idle
            return
        }
        let token = UUID()
        currentCheckToken = token
        if !silent { connectionStatus = .checking }
        let result = await KubectlRunner.run(arguments: ["--context", context, "version"])
        guard token == currentCheckToken else { return }
        switch result {
        case .binaryNotFound:
            connectionStatus = .checkFailed(message: "kubectl not found")
        case .timedOut:
            connectionStatus = .checkFailed(message: "timed out")
        case .completed(let exitCode, _, let stderr):
            connectionStatus = ConnectionStatusMapper.map(exitCode: exitCode, timedOut: false, stderr: stderr)
        }
        guard case .connected = connectionStatus else { clearResources(); return }
        // Best effort: a failing query (e.g. RBAC, no metrics-server) yields an empty list, which the UI hides.
        async let ns = Self.lines(context, ["get", "namespaces", "-o", "name"])
        async let top = Self.lines(context, ["top", "nodes", "--no-headers"])
        async let nodeJSON = Self.output(context, ["get", "nodes", "-o", "json"])
        let (nsLines, topLines, nodesOut) = await (ns, top, nodeJSON)
        guard token == currentCheckToken else { return }
        namespaces = nsLines.map { $0.replacingOccurrences(of: "namespace/", with: "") }
        // top nodes columns: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
        var usage: [String: NodeInfo.Usage] = [:]
        for line in topLines {
            let c = line.split(separator: " ")
            if c.count == 5, let cpuPct = Int(c[2].dropLast()), let memPct = Int(c[4].dropLast()) {
                usage[String(c[0])] = .init(cpu: String(c[1]), cpuPct: cpuPct, mem: String(c[3]), memPct: memPct)
            }
        }
        nodes = NodeInfo.parse(nodesOut, usage: usage)
        if let selectedNamespace, !namespaces.contains(selectedNamespace) { clearWorkloads() }
        // Restore the last selection for this context. Choosing "Select…" removes the saved value, so it isn't restored against the user's wish.
        if selectedNamespace == nil, let saved = defaults.string(forKey: Self.key("Namespace", context)), namespaces.contains(saved) {
            selectedNamespace = saved
            selectedDeployment = defaults.string(forKey: Self.key("Deployment", context))
        }
        await loadWorkloads(context)
    }

    func selectNamespace(_ name: String?) async {
        guard name != selectedNamespace else { return }
        clearWorkloads()
        selectedNamespace = name
        if let context = selectedContext {
            defaults.set(name, forKey: Self.key("Namespace", context))
            defaults.removeObject(forKey: Self.key("Deployment", context))
            await loadWorkloads(context)
        }
    }

    func selectDeployment(_ name: String?) async {
        guard name != selectedDeployment else { return }
        pods = []
        selectedDeployment = name
        if let context = selectedContext {
            defaults.set(name, forKey: Self.key("Deployment", context))
            await loadWorkloads(context)
        }
    }

    private static func key(_ kind: String, _ context: String) -> String { "KubarSelected\(kind):\(context)" }

    /// Deployments of the selected namespace, plus the pods of the selected deployment.
    private func loadWorkloads(_ context: String) async {
        guard let ns = selectedNamespace else { return }
        let token = UUID()
        currentWorkloadToken = token
        let selector = deployments.first { $0.name == selectedDeployment }?.selector
        async let depOut = Self.output(context, ["get", "deployments", "-n", ns, "-o", "json"])
        async let podOut = Self.podsJSON(context, ns, selector)
        let (depJSON, podJSON) = await (depOut, podOut)
        guard token == currentWorkloadToken, selectedContext == context, selectedNamespace == ns else { return }
        deployments = DeploymentInfo.parse(depJSON)
        if let selectedDeployment, !deployments.contains(where: { $0.name == selectedDeployment }) {
            self.selectedDeployment = nil
        }
        pods = selectedDeployment == nil ? [] : PodInfo.parse(podJSON)
        // A deployment picked just now has no selector loaded yet: fetch its pods once.
        if selector == nil, let dep = deployments.first(where: { $0.name == selectedDeployment }), let sel = dep.selector {
            let json = await Self.podsJSON(context, ns, sel)
            guard token == currentWorkloadToken else { return }
            pods = PodInfo.parse(json)
        }
    }

    private static func podsJSON(_ context: String, _ ns: String, _ selector: String?) async -> String {
        guard let selector else { return "" }
        return await output(context, ["get", "pods", "-n", ns, "-l", selector, "-o", "json"])
    }

    private func clearWorkloads() {
        selectedNamespace = nil
        deployments = []
        selectedDeployment = nil
        pods = []
    }

    private func clearResources() {
        namespaces = []
        nodes = []
        clearWorkloads()
    }

    static func output(_ context: String, _ args: [String]) async -> String {
        guard case .completed(0, let stdout, _) = await KubectlRunner.run(arguments: ["--context", context] + args) else { return "" }
        return stdout
    }

    private static func lines(_ context: String, _ args: [String]) async -> [String] {
        await output(context, args).split(separator: "\n").map(String.init)
    }
}
