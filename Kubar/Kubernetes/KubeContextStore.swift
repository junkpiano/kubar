import Foundation

public enum KubeContextStore {
    public enum LoadResult {
        case binaryNotFound
        case configLoadFailed(message: String)
        case loaded(contexts: [String], currentContext: String?)
    }

    public static func loadContexts() async -> LoadResult {
        switch await KubectlRunner.run(arguments: ["config", "view", "-o", "json"]) {
        case .binaryNotFound:
            return .binaryNotFound
        case .timedOut:
            return .configLoadFailed(message: "timed out")
        case .completed(let exitCode, let stdout, let stderr):
            guard exitCode == 0 else {
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .configLoadFailed(message: trimmed.isEmpty ? "exit code \(exitCode)" : trimmed)
            }
            guard let data = stdout.data(using: .utf8),
                  let decoded = try? KubeConfigModels.decodeContexts(from: data) else {
                return .configLoadFailed(message: "couldn't parse kubeconfig")
            }
            return .loaded(contexts: decoded.contexts, currentContext: decoded.currentContext)
        }
    }
}
