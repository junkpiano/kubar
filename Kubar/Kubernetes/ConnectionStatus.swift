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
