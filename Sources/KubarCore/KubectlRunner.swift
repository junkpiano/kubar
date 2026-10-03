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

    /// The PATH value. Windows names it `Path`, and environment keys are case-insensitive there but not in a Swift dictionary.
    static func pathVariable(_ environment: [String: String]) -> String? {
        environment["PATH"] ?? environment.first { $0.key.uppercased() == "PATH" }?.value
    }

    static func resolveBinaryPath(
        candidates: [String] = candidatePaths,
        pathEnvironment: String? = pathVariable(ProcessInfo.processInfo.environment),
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

    /// macOS GUI apps start with a minimal PATH (/usr/bin:/bin...), so kubectl's credential plugins
    /// (gcloud, aws, az...) can't be found. Append the usual install locations. Not used on Windows,
    /// where GUI apps get the full PATH.
    static func augmentedPath(_ current: String?, home: String = NSHomeDirectory()) -> String {
        let existing = (current ?? "").split(separator: ":").map(String.init)
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/google-cloud-sdk/bin", "\(home)/.local/bin"]
        return (existing + extras.filter { !existing.contains($0) }).joined(separator: ":")
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
        #if !os(Windows)  // on Windows, setting "PATH" would add a second, separate variable next to "Path"
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"])
        process.environment = environment
        #endif

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            func resume(_ result: Result) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }

            runners.submit {
                do {
                    try process.run()
                } catch {
                    resume(.binaryNotFound)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        #if os(Windows)
                        process.terminate()
                        #else
                        kill(process.processIdentifier, SIGKILL)
                        #endif
                        resume(.timedOut)
                    }
                }
                // Read both pipes to the end at the same time, so a full pipe never blocks kubectl.
                var stderrData = Data()
                let stderrRead = DispatchSemaphore(value: 0)
                readers.submit {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrRead.signal()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrRead.wait()
                process.waitUntilExit()
                resume(.completed(exitCode: process.terminationStatus,
                                  stdout: String(decoding: stdoutData, as: UTF8.self),
                                  stderr: String(decoding: stderrData, as: UTF8.self)))
            }
        }
    }

    // On Windows, Foundation leaves handles behind for Process use on threads that end: waitUntilExit's
    // run loop (an event and a timer) is never freed with its thread, and without waitUntilExit the
    // Process and its pipes are never freed at all (terminationHandler too; it also starts a Thread per
    // exit). So every Process call happens on a few threads that never end: runners start kubectl, read
    // stdout and wait; readers read stderr meanwhile. At most four kubectl run at once; more wait their turn.
    private static let runners = Workers(count: 4, name: "kubectl")
    private static let readers = Workers(count: 4, name: "kubectl stderr")
}

/// A fixed set of long-lived threads that run submitted jobs in order.
final class Workers: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    private let pending = DispatchSemaphore(value: 0)

    init(count: Int, name: String) {
        for i in 1...count {
            let thread = Thread { [self] in
                while true {
                    pending.wait()
                    lock.lock()
                    let job = jobs.removeFirst()
                    lock.unlock()
                    job()
                }
            }
            thread.name = "\(name) \(i)"
            thread.start()
        }
    }

    func submit(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
        pending.signal()
    }
}
