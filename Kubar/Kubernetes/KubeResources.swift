import Foundation

public struct NodeInfo: Identifiable {
    public let name: String
    public let ready: Bool
    public let roles: String
    public let version: String
    public let os: String
    public let runtime: String
    public let capacity: String
    public let usage: Usage?
    public var id: String { name }

    public struct Usage {
        public let cpu: String
        public let cpuPct: Int
        public let mem: String
        public let memPct: Int
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

public struct DeploymentInfo: Identifiable {
    public let name: String
    public let ready: Int
    public let desired: Int
    /// Label selector for `kubectl -l`. ponytail: matchLabels only, matchExpressions are ignored.
    public let selector: String?
    public var id: String { name }

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

public struct PodInfo: Identifiable {
    public let name: String
    public let status: String
    public let ready: String
    public let restarts: Int
    public let node: String
    public let ok: Bool
    public var id: String { name }

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
