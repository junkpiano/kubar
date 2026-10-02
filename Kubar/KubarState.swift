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
        let status = await KubeClient.check(context)
        guard token == currentCheckToken else { return }
        connectionStatus = status
        guard case .connected = status else { clearResources(); return }
        async let nsList = KubeClient.namespaces(context)
        async let nodeList = KubeClient.nodes(context)
        let (fetchedNamespaces, fetchedNodes) = await (nsList, nodeList)
        guard token == currentCheckToken else { return }
        namespaces = fetchedNamespaces
        nodes = fetchedNodes
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

    enum WorkloadAction {
        case restartDeployment(String)
        case deleteDeployment(String)
        case deletePod(String)
    }

    /// Runs a change in the selected context/namespace, then refreshes. Returns an error message on failure.
    func perform(_ action: WorkloadAction) async -> String? {
        guard let context = selectedContext, let ns = selectedNamespace else { return "no namespace selected" }
        let error: String?
        switch action {
        case .restartDeployment(let name): error = await KubeClient.restartDeployment(context, namespace: ns, name: name)
        case .deleteDeployment(let name): error = await KubeClient.deleteDeployment(context, namespace: ns, name: name)
        case .deletePod(let name): error = await KubeClient.deletePod(context, namespace: ns, name: name)
        }
        await refreshStatus(silent: true)
        return error
    }

    private static func key(_ kind: String, _ context: String) -> String { "KubarSelected\(kind):\(context)" }

    /// Deployments of the selected namespace, plus the pods of the selected deployment.
    private func loadWorkloads(_ context: String) async {
        guard let ns = selectedNamespace else { return }
        let token = UUID()
        currentWorkloadToken = token
        let selector = deployments.first { $0.name == selectedDeployment }?.selector
        async let depList = KubeClient.deployments(context, namespace: ns)
        async let podList = Self.pods(context, ns, selector)
        let (fetchedDeployments, fetchedPods) = await (depList, podList)
        guard token == currentWorkloadToken, selectedContext == context, selectedNamespace == ns else { return }
        deployments = fetchedDeployments
        if let selectedDeployment, !deployments.contains(where: { $0.name == selectedDeployment }) {
            self.selectedDeployment = nil
        }
        pods = selectedDeployment == nil ? [] : fetchedPods
        // A deployment picked just now has no selector loaded yet: fetch its pods once.
        if selector == nil, let dep = deployments.first(where: { $0.name == selectedDeployment }), let sel = dep.selector {
            let fetched = await KubeClient.pods(context, namespace: ns, selector: sel)
            guard token == currentWorkloadToken else { return }
            pods = fetched
        }
    }

    private static func pods(_ context: String, _ ns: String, _ selector: String?) async -> [PodInfo] {
        guard let selector else { return [] }
        return await KubeClient.pods(context, namespace: ns, selector: selector)
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
}

struct NodeRef: Codable, Hashable {
    let context: String
    let name: String
}
