import Foundation

/// Read-only kubectl queries shared by the menu bar app and the CLI.
/// Every query is best effort: a failure (RBAC, no metrics-server, timeout) yields an empty result.
public enum KubeClient {
    public static func output(_ context: String, _ args: [String]) async -> String {
        guard case .completed(0, let stdout, _) = await KubectlRunner.run(arguments: ["--context", context] + args) else { return "" }
        return stdout
    }

    private static func lines(_ context: String, _ args: [String]) async -> [String] {
        await output(context, args).split(separator: "\n").map(String.init)
    }

    public static func check(_ context: String) async -> ConnectionStatus {
        switch await KubectlRunner.run(arguments: ["--context", context, "version"]) {
        case .binaryNotFound:
            return .checkFailed(message: "kubectl not found")
        case .timedOut:
            return .checkFailed(message: "timed out")
        case .completed(let exitCode, _, let stderr):
            return ConnectionStatusMapper.map(exitCode: exitCode, timedOut: false, stderr: stderr)
        }
    }

    public static func namespaces(_ context: String) async -> [String] {
        await lines(context, ["get", "namespaces", "-o", "name"]).map { $0.replacingOccurrences(of: "namespace/", with: "") }
    }

    public static func nodes(_ context: String) async -> [NodeInfo] {
        async let top = lines(context, ["top", "nodes", "--no-headers"])
        async let json = output(context, ["get", "nodes", "-o", "json"])
        // top nodes columns: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
        var usage: [String: NodeInfo.Usage] = [:]
        for line in await top {
            let c = line.split(separator: " ")
            if c.count == 5, let cpuPct = Int(c[2].dropLast()), let memPct = Int(c[4].dropLast()) {
                usage[String(c[0])] = .init(cpu: String(c[1]), cpuPct: cpuPct, mem: String(c[3]), memPct: memPct)
            }
        }
        return NodeInfo.parse(await json, usage: usage)
    }

    public static func deployments(_ context: String, namespace: String) async -> [DeploymentInfo] {
        DeploymentInfo.parse(await output(context, ["get", "deployments", "-n", namespace, "-o", "json"]))
    }

    public static func pods(_ context: String, namespace: String, selector: String) async -> [PodInfo] {
        PodInfo.parse(await output(context, ["get", "pods", "-n", namespace, "-l", selector, "-o", "json"]))
    }

    // MARK: Actions that change the cluster

    /// Runs a kubectl command that modifies the cluster. Returns nil on success, otherwise the error text.
    public static func perform(_ context: String, _ args: [String]) async -> String? {
        switch await KubectlRunner.run(arguments: ["--context", context] + args, timeout: 20) {
        case .binaryNotFound: return "kubectl not found"
        case .timedOut: return "timed out"
        case .completed(0, _, _): return nil
        case .completed(let exitCode, _, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "exit code \(exitCode)" : trimmed
        }
    }

    /// Rolling restart; pods are replaced gradually.
    public static func restartDeployment(_ context: String, namespace: String, name: String) async -> String? {
        await perform(context, ["rollout", "restart", "deployment/\(name)", "-n", namespace])
    }

    public static func deleteDeployment(_ context: String, namespace: String, name: String) async -> String? {
        await perform(context, ["delete", "deployment", name, "-n", namespace, "--wait=false"])
    }

    /// A pod owned by a deployment is recreated by its ReplicaSet, so this doubles as "restart pod".
    public static func deletePod(_ context: String, namespace: String, name: String) async -> String? {
        await perform(context, ["delete", "pod", name, "-n", namespace, "--wait=false"])
    }
}
