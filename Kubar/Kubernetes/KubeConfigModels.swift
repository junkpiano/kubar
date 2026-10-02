import Foundation

enum KubeConfigModels {
    struct DecodedConfig: Equatable {
        let contexts: [String]
        let currentContext: String?
    }

    private struct ConfigView: Decodable {
        struct NamedContext: Decodable {
            let name: String
        }

        let contexts: [NamedContext]?
        let currentContext: String?

        private enum CodingKeys: String, CodingKey {
            case contexts
            case currentContext = "current-context"
        }
    }

    static func decodeContexts(from data: Data) throws -> DecodedConfig {
        let view = try JSONDecoder().decode(ConfigView.self, from: data)
        return DecodedConfig(
            contexts: (view.contexts ?? []).map { $0.name },
            currentContext: view.currentContext
        )
    }
}
