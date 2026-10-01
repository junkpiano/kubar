import Foundation

enum KubeConfigModels {
    struct DecodedConfig: Equatable {
        let contexts: [String]
        let currentContext: String?
    }

    enum DecodeError: Error {
        case invalidJSON
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
        let view: ConfigView
        do {
            view = try JSONDecoder().decode(ConfigView.self, from: data)
        } catch {
            throw DecodeError.invalidJSON
        }
        return DecodedConfig(
            contexts: (view.contexts ?? []).map { $0.name },
            currentContext: view.currentContext
        )
    }
}

#if DEBUG
enum KubeConfigModelsSelfCheck {
    static func run() {
        let sample = """
        {
          "contexts": [
            { "name": "docker-desktop", "context": { "cluster": "docker-desktop", "user": "docker-desktop" } },
            { "name": "gke_my-project_us-central1_my-cluster", "context": { "cluster": "gke_my-project", "user": "gke_my-project" } }
          ],
          "current-context": "docker-desktop"
        }
        """.data(using: .utf8)!
        let decoded = try! KubeConfigModels.decodeContexts(from: sample)
        assert(decoded.contexts == ["docker-desktop", "gke_my-project_us-central1_my-cluster"])
        assert(decoded.currentContext == "docker-desktop")

        let empty = try! KubeConfigModels.decodeContexts(from: "{}".data(using: .utf8)!)
        assert(empty.contexts.isEmpty)
        assert(empty.currentContext == nil)

        var threw = false
        do {
            _ = try KubeConfigModels.decodeContexts(from: "not json".data(using: .utf8)!)
        } catch {
            threw = true
        }
        assert(threw, "expected decodeContexts to throw on invalid JSON")

        print("KubeConfigModelsSelfCheck passed")
    }
}
#endif
