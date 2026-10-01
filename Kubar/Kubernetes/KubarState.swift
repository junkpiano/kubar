import Foundation

@MainActor
final class KubarState: ObservableObject {
    @Published private(set) var contexts: [String] = []
    @Published private(set) var selectedContext: String?
    @Published private(set) var connectionStatus: ConnectionStatus = .idle
    @Published private(set) var loadError: String?

    private let defaults: UserDefaults
    private let selectedContextKey = "KubarSelectedContext"
    private var currentCheckToken = UUID()
    private var currentLoadToken = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func resolveSelection(loadedContexts: [String], saved: String?, currentContext: String?) -> String? {
        if let saved, loadedContexts.contains(saved) { return saved }
        if let currentContext, loadedContexts.contains(currentContext) { return currentContext }
        return loadedContexts.first
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

    func refreshStatus() async {
        guard let context = selectedContext else {
            connectionStatus = .idle
            return
        }
        let token = UUID()
        currentCheckToken = token
        connectionStatus = .checking
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
    }
}
