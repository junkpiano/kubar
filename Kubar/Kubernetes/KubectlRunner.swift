import Foundation

enum KubectlRunner {
    #if os(Windows)
    static let candidatePaths: [String] = []
    static let pathSeparator: Character = ";"
    static let binaryName = "kubectl.exe"
    #else
    static let candidatePaths = [
        "/opt/homebrew/bin/kubectl",
        "/usr/local/bin/kubectl",
        "/usr/bin/kubectl",
    ]
    static let pathSeparator: Character = ":"
    static let binaryName = "kubectl"
    #endif

    static func resolveBinaryPath(
        candidates: [String] = candidatePaths,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for candidate in candidates where fileExists(candidate) {
            return candidate
        }
        guard let pathEnvironment else { return nil }
        for directory in pathEnvironment.split(separator: pathSeparator) {
            let candidate = "\(directory)/\(binaryName)"
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// GUI apps start with a minimal PATH (/usr/bin:/bin...), so kubectl's credential plugins
    /// (gcloud, aws, az...) can't be found. Append the usual install locations. No-op on Windows.
    static func augmentedPath(_ current: String?, home: String = NSHomeDirectory()) -> String {
        #if os(Windows)
        return current ?? ""
        #else
        let existing = (current ?? "").split(separator: ":").map(String.init)
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/google-cloud-sdk/bin", "\(home)/.local/bin"]
        return (existing + extras.filter { !existing.contains($0) }).joined(separator: ":")
        #endif
    }

    enum Result {
        case binaryNotFound
        case completed(exitCode: Int32, stdout: String, stderr: String)
        case timedOut
    }

    static func run(arguments: [String], timeout: TimeInterval = 5) async -> Result {
        guard let binaryPath = resolveBinaryPath() else {
            return .binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"])
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var resumed = false

            func resume(_ result: Result) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                lock.lock(); stdoutData.append(chunk); lock.unlock()
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                lock.lock(); stderrData.append(chunk); lock.unlock()
            }

            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                stdoutData.append(remainingOut)
                stderrData.append(remainingErr)
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()
                resume(.completed(exitCode: process.terminationStatus, stdout: out, stderr: err))
            }

            do {
                try process.run()
            } catch {
                resume(.binaryNotFound)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    #if os(Windows)
                    process.terminate()
                    #else
                    kill(process.processIdentifier, SIGKILL)
                    #endif
                    resume(.timedOut)
                }
            }
        }
    }
}
