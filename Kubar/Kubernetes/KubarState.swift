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

struct NodeInfo: Identifiable {
    let name: String
    let ready: Bool
    let roles: String
    let version: String
    let os: String
    let runtime: String
    let capacity: String
    let usage: Usage?
    var id: String { name }

    struct Usage {
        let cpu: String
        let cpuPct: Int
        let mem: String
        let memPct: Int
    }

    private static func gib(_ quantity: String?) -> String {
        guard let quantity else { return "?" }
        guard quantity.hasSuffix("Ki"), let ki = Double(quantity.dropLast(2)) else { return quantity }
        return String(format: "%.1f GiB", ki / 1_048_576)
    }

    private struct List: Decodable {
        struct Item: Decodable {
            struct Meta: Decodable { let name: String; let labels: [String: String]? }
            struct Status: Decodable {
                struct Condition: Decodable { let type: String; let status: String }
                struct Info: Decodable { let kubeletVersion: String; let osImage: String; let containerRuntimeVersion: String }
                let conditions: [Condition]?
                let nodeInfo: Info
                let capacity: [String: String]?
            }
            let metadata: Meta
            let status: Status
        }
        let items: [Item]
    }

    static func parse(_ json: String, usage: [String: Usage]) -> [NodeInfo] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.items.map { item in
            let prefix = "node-role.kubernetes.io/"
            let roles = (item.metadata.labels ?? [:]).keys
                .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
            let cap = item.status.capacity ?? [:]
            return NodeInfo(
                name: item.metadata.name,
                ready: item.status.conditions?.contains { $0.type == "Ready" && $0.status == "True" } ?? false,
                roles: roles.isEmpty ? "<none>" : roles.joined(separator: ","),
                version: item.status.nodeInfo.kubeletVersion,
                os: item.status.nodeInfo.osImage,
                runtime: item.status.nodeInfo.containerRuntimeVersion,
                capacity: "\(cap["cpu"] ?? "?") CPU · \(gib(cap["memory"]))",
                usage: usage[item.metadata.name]
            )
        }
    }
}

struct NodeRef: Codable, Hashable {
    let context: String
    let name: String
}

private struct K8sList<T: Decodable>: Decodable {
    let items: [T]
}

struct DeploymentInfo: Identifiable {
    let name: String
    let ready: Int
    let desired: Int
    /// Label selector for `kubectl -l`. ponytail: matchLabels only, matchExpressions are ignored.
    let selector: String?
    var id: String { name }

    private struct Item: Decodable {
        struct Meta: Decodable { let name: String }
        struct Spec: Decodable {
            struct Selector: Decodable { let matchLabels: [String: String]? }
            let replicas: Int?
            let selector: Selector?
        }
        struct Status: Decodable { let readyReplicas: Int? }
        let metadata: Meta
        let spec: Spec
        let status: Status?
    }

    static func parse(_ json: String) -> [DeploymentInfo] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode(K8sList<Item>.self, from: data) else { return [] }
        return list.items.map { item in
            let labels = item.spec.selector?.matchLabels ?? [:]
            return DeploymentInfo(
                name: item.metadata.name,
                ready: item.status?.readyReplicas ?? 0,
                desired: item.spec.replicas ?? 1,
                selector: labels.isEmpty ? nil : labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            )
        }
    }
}

struct PodInfo: Identifiable {
    let name: String
    let status: String
    let ready: String
    let restarts: Int
    let node: String
    let ok: Bool
    var id: String { name }

    private struct Item: Decodable {
        struct Meta: Decodable { let name: String; let deletionTimestamp: String? }
        struct Spec: Decodable { let nodeName: String? }
        struct Status: Decodable {
            struct Container: Decodable {
                struct State: Decodable {
                    struct Reason: Decodable { let reason: String? }
                    let waiting: Reason?
                    let terminated: Reason?
                }
                let ready: Bool
                let restartCount: Int
                let state: State?
            }
            let phase: String?
            let containerStatuses: [Container]?
        }
        let metadata: Meta
        let spec: Spec
        let status: Status?
    }

    static func parse(_ json: String) -> [PodInfo] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode(K8sList<Item>.self, from: data) else { return [] }
        return list.items.map { item in
            let containers = item.status?.containerStatuses ?? []
            let phase = item.status?.phase ?? "Unknown"
            let readyCount = containers.filter(\.ready).count
            let reason = containers.lazy.compactMap { $0.state?.waiting?.reason ?? $0.state?.terminated?.reason }.first
            return PodInfo(
                name: item.metadata.name,
                status: item.metadata.deletionTimestamp != nil ? "Terminating" : (reason ?? phase),
                ready: "\(readyCount)/\(containers.count)",
                restarts: containers.reduce(0) { $0 + $1.restartCount },
                node: item.spec.nodeName ?? "unscheduled",
                ok: item.metadata.deletionTimestamp == nil && (phase == "Succeeded" || (phase == "Running" && readyCount == containers.count))
            )
        }
    }
}
