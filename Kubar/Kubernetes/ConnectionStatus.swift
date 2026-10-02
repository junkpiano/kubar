import Foundation

public enum ConnectionStatus: Equatable {
    case idle
    case checking
    case connected
    case checkFailed(message: String)
}

enum ConnectionStatusMapper {
    static func map(exitCode: Int32?, timedOut: Bool, stderr: String) -> ConnectionStatus {
        if timedOut {
            return .checkFailed(message: "timed out")
        }
        guard let exitCode else {
            return .checkFailed(message: "kubectl did not run")
        }
        if exitCode == 0 {
            return .connected
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .checkFailed(message: trimmed.isEmpty ? "exit code \(exitCode)" : trimmed)
    }
}

/// A plain-language fix for a known failure, with an optional command the user can copy.
public struct ConnectionHint: Equatable {
    public let text: String
    public let command: String?

    /// Matches on lowercased kubectl/gcloud error text. Add a case here to teach Kubar a new fix.
    public static func suggest(for message: String) -> ConnectionHint? {
        let m = message.lowercased()
        if m.contains("gcloud auth login") || m.contains("reauthentication failed") {
            return ConnectionHint(text: "Your Google Cloud login expired. Sign in again in a terminal, then refresh.", command: "gcloud auth login")
        }
        if m.contains("gke-gcloud-auth-plugin") && m.contains("not found") {
            return ConnectionHint(text: "The GKE auth plugin is missing. Install it, then refresh.", command: "gcloud components install gke-gcloud-auth-plugin")
        }
        if m == "kubectl not found" {
            #if os(Windows)
            return ConnectionHint(text: "kubectl isn't installed or isn't on PATH. Install it, then restart Kubar.", command: "choco install kubernetes-cli")
            #else
            return ConnectionHint(text: "kubectl isn't installed or isn't on PATH. Install it, then restart Kubar.", command: "brew install kubectl")
            #endif
        }
        if m.contains("unauthorized") || m.contains("must be logged in") {
            return ConnectionHint(text: "The cluster rejected your credentials. Sign in again with your cloud or identity provider, then refresh.", command: nil)
        }
        if ["timed out", "i/o timeout", "connection refused", "no such host", "unable to connect"].contains(where: m.contains) {
            return ConnectionHint(text: "Can't reach the cluster. Check your network or VPN and that the cluster is running, then refresh.", command: nil)
        }
        return nil
    }
}

#if DEBUG
enum ConnectionStatusSelfCheck {
    static func run() {
        assert(ConnectionStatusMapper.map(exitCode: 0, timedOut: false, stderr: "") == .connected)
        assert(ConnectionStatusMapper.map(exitCode: 1, timedOut: false, stderr: "Unable to connect to the server\n") == .checkFailed(message: "Unable to connect to the server"))
        assert(ConnectionStatusMapper.map(exitCode: 1, timedOut: false, stderr: "") == .checkFailed(message: "exit code 1"))
        assert(ConnectionStatusMapper.map(exitCode: nil, timedOut: true, stderr: "") == .checkFailed(message: "timed out"))
        print("ConnectionStatusSelfCheck passed")
    }
}
#endif
