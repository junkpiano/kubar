import Foundation

enum KubectlRunner {
    static let candidatePaths = [
        "/opt/homebrew/bin/kubectl",
        "/usr/local/bin/kubectl",
        "/usr/bin/kubectl",
    ]

    static func resolveBinaryPath(
        candidates: [String] = candidatePaths,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for candidate in candidates where fileExists(candidate) {
            return candidate
        }
        guard let pathEnvironment else { return nil }
        for directory in pathEnvironment.split(separator: ":") {
            let candidate = "\(directory)/kubectl"
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
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
                    kill(process.processIdentifier, SIGKILL)
                    resume(.timedOut)
                }
            }
        }
    }
}

#if DEBUG
enum KubectlRunnerSelfCheck {
    static func run() {
        let found = KubectlRunner.resolveBinaryPath(
            candidates: ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"],
            pathEnvironment: nil,
            fileExists: { $0 == "/usr/local/bin/kubectl" }
        )
        assert(found == "/usr/local/bin/kubectl")

        let viaPath = KubectlRunner.resolveBinaryPath(
            candidates: [],
            pathEnvironment: "/usr/bin:/custom/bin",
            fileExists: { $0 == "/custom/bin/kubectl" }
        )
        assert(viaPath == "/custom/bin/kubectl")

        let missing = KubectlRunner.resolveBinaryPath(
            candidates: ["/opt/homebrew/bin/kubectl"],
            pathEnvironment: "/usr/bin",
            fileExists: { _ in false }
        )
        assert(missing == nil)

        print("KubectlRunnerSelfCheck passed")
    }
}
#endif
