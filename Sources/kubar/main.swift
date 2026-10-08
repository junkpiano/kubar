import Foundation
import KubarCore

let usage = """
Usage: kubar [options] [command]

Commands:
  (none)         connection status and nodes
  contexts       list kubeconfig contexts
  status         check the connection
  nodes          nodes with CPU/memory usage
  namespaces     list namespaces
  deployments    list deployments        (-n <namespace>)
  pods           pods of a namespace     (-n <namespace> [-d <deployment>])

Options:
  -c, --context <name>      kubeconfig context (default: current context)
  -n, --namespace <name>
  -d, --deployment <name>
  -w, --watch               refresh every 10s until interrupted
  -h, --help
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("kubar: \(message)\n".utf8))
    exit(code)
}

func table(_ rows: [[String]]) -> String {
    guard let columns = rows.first?.count else { return "" }
    let widths = (0..<columns).map { c in rows.map { $0[c].count }.max() ?? 0 }
    return rows.map { row in
        row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
}

// MARK: arguments

struct Options {
    var context: String?
    var namespace: String?
    var deployment: String?
    var watch = false
    var command: String?
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        func value() -> String {
            guard let v = args.popFirst() else { fail("\(arg) needs a value", code: 2) }
            return v
        }
        switch arg {
        case "-c", "--context": o.context = value()
        case "-n", "--namespace": o.namespace = value()
        case "-d", "--deployment": o.deployment = value()
        case "-w", "--watch": o.watch = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") || o.command != nil { fail("unexpected argument '\(arg)'\n\n\(usage)", code: 2) }
            o.command = arg
        }
    }
    return o
}

let options = parseOptions()

// MARK: commands

/// Returns the text to print and whether the command succeeded.
func run(_ options: Options) async -> (String, Bool) {
    switch await KubeContextStore.loadContexts() {
    case .binaryNotFound: return ("kubectl not found", false)
    case .configLoadFailed(let message): return ("couldn't load kubeconfig: \(message)", false)
    case .loaded(let contexts, let current):
        if options.command == "contexts" {
            return (contexts.map { ($0 == current ? "* " : "  ") + $0 }.joined(separator: "\n"), true)
        }
        guard let ctx = options.context ?? current ?? contexts.first else { return ("No contexts found", false) }
        guard contexts.contains(ctx) else { return ("unknown context '\(ctx)'", false) }
        return await runCommand(options, ctx)
    }
}

func runCommand(_ options: Options, _ ctx: String) async -> (String, Bool) {
    let status = await KubeClient.check(ctx)
    var statusLine = "\(ctx): Connected"
    if case .checkFailed(let message) = status { statusLine = "\(ctx): Check failed: \(message)" }
    guard case .connected = status else {
        var text = statusLine
        if case .checkFailed(let message) = status, let hint = ConnectionHint.suggest(for: message) {
            text += "\n\nHint: \(hint.text)" + (hint.command.map { "\n  $ \($0)" } ?? "")
        }
        return (text, false)
    }

    let command = options.command
    switch command {
    case "status":
        return (statusLine, true)
    case nil, "nodes":
        let nodes = await KubeClient.nodes(ctx)
        var rows = [["NODE", "STATUS", "ROLES", "VERSION", "CPU", "MEMORY", "CAPACITY"]]
        for n in nodes {
            rows.append([n.name, n.ready ? "Ready" : "NotReady", n.roles, n.version,
                         n.usage.map { "\($0.cpu) (\($0.cpuPct)%)" } ?? "-",
                         n.usage.map { "\($0.mem) (\($0.memPct)%)" } ?? "-",
                         n.capacity])
        }
        return ((command == nil ? statusLine + "\n\n" : "") + (nodes.isEmpty ? "No nodes" : table(rows)), true)
    case "namespaces":
        return ((await KubeClient.namespaces(ctx)).joined(separator: "\n"), true)
    case "deployments":
        guard let namespace = options.namespace else { fail("deployments needs -n <namespace>", code: 2) }
        let deployments = await KubeClient.deployments(ctx, namespace: namespace)
        if deployments.isEmpty { return ("No deployments in \(namespace)", true) }
        return (table([["DEPLOYMENT", "READY"]] + deployments.map { [$0.name, "\($0.ready)/\($0.desired)"] }), true)
    case "pods":
        guard let namespace = options.namespace else { fail("pods needs -n <namespace>", code: 2) }
        var selector: String?
        if let deployment = options.deployment {
            let deployments = await KubeClient.deployments(ctx, namespace: namespace)
            guard let found = deployments.first(where: { $0.name == deployment }) else {
                return ("deployment '\(deployment)' not found in \(namespace)", false)
            }
            guard let sel = found.selector else { return ("deployment '\(deployment)' has no matchLabels selector", false) }
            selector = sel
        }
        let pods = await KubeClient.pods(ctx, namespace: namespace, selector: selector)
        if pods.isEmpty { return ("No pods", true) }
        return (table([["POD", "STATUS", "READY", "RESTARTS", "NODE"]]
            + pods.map { [$0.name, $0.status, $0.ready, String($0.restarts), $0.node] }), true)
    default:
        fail("unknown command '\(command ?? "")'\n\n\(usage)", code: 2)
    }
}

// MARK: main

var ok = true
repeat {
    let (text, success) = await run(options)
    ok = success
    if options.watch { print("\u{1B}[H\u{1B}[2J", terminator: "") }
    print(text)
    if options.watch { try? await Task.sleep(nanoseconds: 10_000_000_000) }
} while options.watch
exit(ok ? 0 : 1)
