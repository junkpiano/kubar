// Kubar for Windows: a notification-area (tray) icon whose menu shows the same things as the macOS
// menu bar app, built on KubarCore and plain Win32 (WinSDK). Left or right click opens the menu.
#if os(Windows)
import Foundation
import KubarCore
import WinSDK

// MARK: Model

/// What the menu shows. Background tasks write it under `lock`; the UI thread reads a copy when the menu opens,
/// so the menu never waits on kubectl.
struct Snapshot {
    var contexts: [String] = []
    var currentContext: String?
    var selectedContext: String?
    var loadError: String?
    var status: ConnectionStatus = .idle
    var nodes: [NodeInfo] = []
    var namespaces: [String] = []
    var selectedNamespace: String?
    var deployments: [DeploymentInfo] = []
    var selectedDeployment: String?
    var pods: [PodInfo] = []
}

final class Model: @unchecked Sendable {
    private let lock = NSLock()
    private var state = Snapshot()
    /// Bumped on every selection change, so a refresh started before it doesn't overwrite newer choices.
    private var generation = 0
    private let defaults = UserDefaults.standard
    private static func key(_ kind: String, _ context: String) -> String { "KubarSelected\(kind):\(context)" }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func change(_ body: (inout Snapshot) -> Void) {
        lock.lock(); body(&state); lock.unlock()
        PostMessageW(window, UINT(WM_APP + 2), 0, 0)  // update the tooltip on the UI thread
    }

    private func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    @discardableResult
    func selectContext(_ name: String) -> Int {
        defaults.set(name, forKey: "KubarSelectedContext")
        change {
            $0.selectedContext = name
            $0.status = .checking
            $0.nodes = []; $0.namespaces = []
            $0.selectedNamespace = nil; $0.deployments = []; $0.selectedDeployment = nil; $0.pods = []
        }
        return refreshSoon(reselect: true)
    }

    @discardableResult
    func selectNamespace(_ name: String?) -> Int {
        guard let context = snapshot.selectedContext else { return 0 }
        defaults.set(name, forKey: Self.key("Namespace", context))
        defaults.removeObject(forKey: Self.key("Deployment", context))
        change { $0.selectedNamespace = name; $0.deployments = []; $0.selectedDeployment = nil; $0.pods = [] }
        return refreshSoon()
    }

    @discardableResult
    func selectDeployment(_ name: String?) -> Int {
        guard let context = snapshot.selectedContext else { return 0 }
        defaults.set(name, forKey: Self.key("Deployment", context))
        change { $0.selectedDeployment = name; $0.pods = [] }
        return refreshSoon()
    }

    /// Starts a refresh and returns its generation; when it ends, the window gets refreshDone with it.
    @discardableResult
    func refreshSoon(reselect: Bool = false) -> Int {
        let gen = bump()
        Task.detached {
            await self.refresh(gen, reselect: reselect)
            PostMessageW(window, refreshDone, WPARAM(gen), 0)
        }
        return gen
    }

    /// Reloads the contexts (cheap, and picks up kubeconfig edits), then checks the selected one and everything under it.
    private func refresh(_ gen: Int, reselect: Bool) async {
        var s = snapshot
        switch await KubeContextStore.loadContexts() {
        case .binaryNotFound: s.loadError = "kubectl not found"
        case .configLoadFailed(let message): s.loadError = "couldn't load kubeconfig: \(message)"
        case .loaded(let contexts, let current):
            s.loadError = contexts.isEmpty ? "No contexts found" : nil
            s.contexts = contexts
            s.currentContext = current
            let saved = defaults.string(forKey: "KubarSelectedContext")
            s.selectedContext = [s.selectedContext, saved, current].compactMap { $0 }.first(where: contexts.contains) ?? contexts.first
        }
        guard isCurrent(gen) else { return }
        change { [s] in $0.contexts = s.contexts; $0.currentContext = s.currentContext; $0.loadError = s.loadError; $0.selectedContext = s.selectedContext }
        guard let context = s.selectedContext, s.loadError == nil else { return }

        let status = await KubeClient.check(context)
        guard isCurrent(gen) else { return }
        guard case .connected = status else {
            change { $0.status = status; $0.nodes = []; $0.namespaces = []; $0.deployments = []; $0.pods = [] }
            return
        }
        async let nodeList = KubeClient.nodes(context)
        async let nsList = KubeClient.namespaces(context)
        let (nodes, namespaces) = await (nodeList, nsList)

        // Keep the namespace and deployment if they still exist; after a context switch, restore the saved ones.
        var namespace = s.selectedNamespace
        var deployment = s.selectedDeployment
        if reselect || (namespace == nil && s.namespaces.isEmpty) {
            namespace = defaults.string(forKey: Self.key("Namespace", context))
            deployment = defaults.string(forKey: Self.key("Deployment", context))
        }
        if let ns = namespace, !namespaces.contains(ns) { namespace = nil; deployment = nil }

        var deployments: [DeploymentInfo] = []
        var pods: [PodInfo] = []
        if let ns = namespace {
            deployments = await KubeClient.deployments(context, namespace: ns)
            if let dep = deployments.first(where: { $0.name == deployment }) {
                if let selector = dep.selector { pods = await KubeClient.pods(context, namespace: ns, selector: selector) }
            } else {
                deployment = nil
            }
        }
        guard isCurrent(gen) else { return }
        change {
            $0.status = status; $0.nodes = nodes; $0.namespaces = namespaces
            $0.selectedNamespace = namespace; $0.deployments = deployments
            $0.selectedDeployment = deployment; $0.pods = pods
        }
    }

    enum Action {
        case restartDeployment(String), deleteDeployment(String), deletePod(String)
    }

    /// Runs a change in the selected context and namespace, then refreshes. Shows an error box if it fails.
    func perform(_ action: Action) {
        let s = snapshot
        guard let context = s.selectedContext, let ns = s.selectedNamespace else { return }
        Task.detached {
            let error: String?
            switch action {
            case .restartDeployment(let name): error = await KubeClient.restartDeployment(context, namespace: ns, name: name)
            case .deleteDeployment(let name): error = await KubeClient.deleteDeployment(context, namespace: ns, name: name)
            case .deletePod(let name): error = await KubeClient.deletePod(context, namespace: ns, name: name)
            }
            if let error { _ = MessageBoxW(nil, wide(error), wide("Kubar: failed"), UINT(MB_OK | MB_ICONWARNING)) }
            self.refreshSoon()
        }
    }
}

// MARK: Win32 helpers

/// Splits text into menu lines of at most `width` characters at spaces, keeping the first `maxLines`
/// (menu items can't wrap on their own).
func wrap(_ text: String, width: Int = 80, maxLines: Int = 3) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in text.split(whereSeparator: \.isWhitespace) {
        if !line.isEmpty && line.count + 1 + word.count > width { lines.append(line); line = "" }
        line += (line.isEmpty ? "" : " ") + word
    }
    if !line.isEmpty { lines.append(line) }
    if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); lines[maxLines - 1] += " …" }
    return lines
}

/// A NUL-terminated UTF-16 copy for Win32 `LPCWSTR` parameters.
func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

func copyToClipboard(_ text: String) {
    let utf16 = wide(text)
    guard OpenClipboard(window) else { return }
    defer { CloseClipboard() }
    EmptyClipboard()
    let bytes = utf16.count * MemoryLayout<WCHAR>.size
    guard let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let dest = GlobalLock(handle) else { return }
    utf16.withUnsafeBytes { dest.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
    GlobalUnlock(handle)
    SetClipboardData(UINT(CF_UNICODETEXT), handle)
}

func confirm(_ title: String, _ detail: String) -> Bool {
    let s = model.snapshot
    let text = "\(detail)\n\nContext: \(s.selectedContext ?? "?")\nNamespace: \(s.selectedNamespace ?? "?")"
    return MessageBoxW(window, wide(text), wide(title), UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK
}

// MARK: Menu

/// Builds the popup menu from a snapshot; each clickable item gets an id mapped to what it does.
final class MenuBuilder {
    var actions: [UINT_PTR: () -> Void] = [:]
    private var nextID: UINT_PTR = 1

    func item(_ menu: HMENU, _ title: String, checked: Bool = false, disabled: Bool = false, _ action: (() -> Void)? = nil) {
        var flags = UINT(MF_STRING)
        if checked { flags |= UINT(MF_CHECKED) }
        if disabled { flags |= UINT(MF_GRAYED) }
        var id: UINT_PTR = 0
        if let action { id = nextID; nextID += 1; actions[id] = action }
        AppendMenuW(menu, flags, id, wide(title))
    }

    func submenu(_ menu: HMENU, _ title: String, disabled: Bool = false, _ fill: (HMENU) -> Void) {
        let sub = CreatePopupMenu()!
        fill(sub)
        AppendMenuW(menu, UINT(MF_POPUP) | (disabled ? UINT(MF_GRAYED) : 0), UINT_PTR(UInt(bitPattern: sub)), wide(title))
    }

    func separator(_ menu: HMENU) { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }

    func build(_ s: Snapshot) -> HMENU {
        let menu = CreatePopupMenu()!
        if let error = s.loadError {
            item(menu, "Kubar: \(error)", disabled: true)
            hint(menu, error)
        } else {
            let context = s.selectedContext ?? "-"
            switch s.status {
            case .idle: item(menu, "\(context): idle", disabled: true)
            case .checking: item(menu, "\(context): checking…", disabled: true)
            case .connected: item(menu, "● \(context): connected", disabled: true)
            case .checkFailed(let message):
                item(menu, "○ \(context): check failed", disabled: true)
                for line in wrap(message) { item(menu, "    " + line, disabled: true) }
                hint(menu, message)
            }
            separator(menu)
            submenu(menu, "Context") { sub in
                for c in s.contexts {
                    item(sub, c + (c == s.currentContext ? "  (current)" : ""), checked: c == s.selectedContext) { reopenAfter(model.selectContext(c)) }
                }
            }
            submenu(menu, "Nodes (\(s.nodes.count))", disabled: s.nodes.isEmpty) { sub in
                for n in s.nodes {
                    let usage = n.usage.map { "CPU \($0.cpu) \($0.cpuPct)%  ·  Mem \($0.mem) \($0.memPct)%" } ?? "metrics unavailable"
                    item(sub, "\(n.ready ? "●" : "○") \(n.name)\t\(usage)")
                }
            }
            workloads(menu, s)
        }
        separator(menu)
        item(menu, "Refresh") { model.refreshSoon() }
        item(menu, "Quit Kubar") { quit() }
        return menu
    }

    // Namespace -> deployment -> pods: each level narrows the one above, like the macOS app.
    private func workloads(_ menu: HMENU, _ s: Snapshot) {
        guard !s.namespaces.isEmpty else { return }
        separator(menu)
        submenu(menu, "Namespace: \(s.selectedNamespace ?? "select…")") { sub in
            item(sub, "None", checked: s.selectedNamespace == nil) { reopenAfter(model.selectNamespace(nil)) }
            for ns in s.namespaces { item(sub, ns, checked: ns == s.selectedNamespace) { reopenAfter(model.selectNamespace(ns)) } }
        }
        guard let ns = s.selectedNamespace else { return }
        guard !s.deployments.isEmpty else { item(menu, "No deployments in \(ns)", disabled: true); return }
        submenu(menu, "Deployment: \(s.selectedDeployment ?? "select…")") { sub in
            item(sub, "None", checked: s.selectedDeployment == nil) { reopenAfter(model.selectDeployment(nil)) }
            for d in s.deployments {
                item(sub, "\(d.name)\t\(d.ready)/\(d.desired) ready", checked: d.name == s.selectedDeployment) { reopenAfter(model.selectDeployment(d.name)) }
            }
        }
        guard let dep = s.selectedDeployment else { return }
        submenu(menu, "Pods of \(dep) (\(s.pods.count))", disabled: s.pods.isEmpty) { sub in
            for p in s.pods {
                submenu(sub, "\(p.ok ? "●" : "○") \(p.name)\t\(p.status) · \(p.ready) · \(p.restarts) restarts") { podMenu in
                    item(podMenu, "Node: \(p.node)", disabled: true)
                    item(podMenu, "Delete (restarts it)…") {
                        if confirm("Delete pod \(p.name)?", "Its deployment creates a replacement, so this restarts the pod.") { model.perform(.deletePod(p.name)) }
                    }
                }
            }
        }
        item(menu, "Restart \(dep)…") {
            if confirm("Restart deployment \(dep)?", "Its pods are replaced one by one (rolling restart).") { model.perform(.restartDeployment(dep)) }
        }
        item(menu, "Delete \(dep)…") {
            if confirm("Delete deployment \(dep)?", "The deployment and all its pods are removed.") { model.perform(.deleteDeployment(dep)) }
        }
    }

    private func hint(_ menu: HMENU, _ message: String) {
        guard let hint = ConnectionHint.suggest(for: message) else { return }
        item(menu, "💡 " + hint.text, disabled: true)
        if let command = hint.command { item(menu, "Copy: \(command)") { copyToClipboard(command) } }
    }
}

/// The open menu's actions; the chosen item arrives afterwards as WM_COMMAND with its id.
/// (TrackPopupMenu's TPM_RETURNCMD can't be used: Swift imports its BOOL result as Bool, losing the id.)
var menuActions: [UINT_PTR: () -> Void] = [:]

/// A Win32 menu always closes when an item is chosen. After picking a context, namespace or deployment,
/// open it again where it was once that choice has loaded, so drilling down doesn't mean clicking the icon each time.
var lastMenuPoint = POINT()
var pendingReopen: (gen: Int, deadline: Date)?

func reopenAfter(_ gen: Int) {
    pendingReopen = (gen, Date().addingTimeInterval(8))  // a slow cluster: don't pop up out of nowhere later
}

func showMenu(at fixedPoint: POINT? = nil) {
    let builder = MenuBuilder()
    let menu = builder.build(model.snapshot)
    defer { DestroyMenu(menu) }
    menuActions = builder.actions
    var point = POINT()
    if let fixedPoint { point = fixedPoint } else { GetCursorPos(&point) }
    lastMenuPoint = point
    SetForegroundWindow(window)  // otherwise the menu doesn't close when you click elsewhere
    TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
    PostMessageW(window, UINT(WM_NULL), 0, 0)
}

// MARK: Tray icon

let trayMessage = UINT(WM_APP + 1)
let refreshDone = UINT(WM_APP + 3)
let taskbarCreated = RegisterWindowMessageW(wide("TaskbarCreated"))

func trayIcon() -> HICON? {
    let size = GetSystemMetrics(SM_CXSMICON)
    if let path = Bundle.module.path(forResource: "kubar", ofType: "ico"),
       let handle = LoadImageW(nil, wide(path), UINT(IMAGE_ICON), size, size, UINT(LR_LOADFROMFILE)) {
        return HICON(OpaquePointer(handle))
    }
    return LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDI_APPLICATION
}

let icon = trayIcon()

func notifyIcon(_ message: DWORD) {
    var data = NOTIFYICONDATAW()
    data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    data.hWnd = window
    data.uID = 1
    data.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
    data.uCallbackMessage = trayMessage
    data.hIcon = icon
    let s = model.snapshot
    var tip = "Kubar"
    if let context = s.selectedContext {
        switch s.status {
        case .connected: tip += " · \(context): connected"
        case .checkFailed: tip += " · \(context): check failed"
        default: tip += " · \(context)"
        }
    }
    let chars = Array(tip.utf16.prefix(127)) + [0]  // szTip holds 128 WCHARs
    chars.withUnsafeBytes { src in withUnsafeMutableBytes(of: &data.szTip) { $0.copyMemory(from: src) } }
    Shell_NotifyIconW(message, &data)
}

func quit() {
    notifyIcon(DWORD(NIM_DELETE))
    PostQuitMessage(0)
}

func windowProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case trayMessage:
        let event = UINT(lParam & 0xFFFF)
        if event == UINT(WM_LBUTTONUP) || event == UINT(WM_RBUTTONUP) { showMenu() }
        return 0
    case UINT(WM_COMMAND):
        menuActions[UINT_PTR(wParam & 0xFFFF)]?()
        return 0
    case refreshDone:
        if let pending = pendingReopen, Int(wParam) >= pending.gen {  // or a newer refresh (the 10s poll) that replaced it
            pendingReopen = nil
            if Date() < pending.deadline { showMenu(at: lastMenuPoint) }
        }
        return 0
    case UINT(WM_APP + 2):
        notifyIcon(DWORD(NIM_MODIFY))
        return 0
    case taskbarCreated:  // Explorer restarted: put the icon back
        notifyIcon(DWORD(NIM_ADD))
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

// MARK: main

/// kubectl is a console program. Started from this GUI app, each run would get a new console, which
/// flashes a terminal window every 10s. Give this process one console without a window instead;
/// the kubectl runs share it. AllocConsoleWithOptions(NO_WINDOW) exists from Windows 11 24H2, so look
/// it up at run time; older Windows gets a normal console, hidden right away (one flash at startup).
func attachHiddenConsole() {
    typealias AllocWithOptions = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> HRESULT
    if let kernel32 = GetModuleHandleW(wide("kernel32.dll")),
       let proc = GetProcAddress(kernel32, "AllocConsoleWithOptions") {
        // ALLOC_CONSOLE_OPTIONS { mode = ALLOC_CONSOLE_MODE_NO_WINDOW (2), useShowWindow = FALSE, showWindow = 0 }
        var options: [Int32] = [2, 0, 0]
        if unsafeBitCast(proc, to: AllocWithOptions.self)(&options, nil) >= 0 { return }
    }
    if AllocConsole() { ShowWindow(GetConsoleWindow(), SW_HIDE) }
}

attachHiddenConsole()
SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))  // per-monitor v2: sharp menu text

let instance = GetModuleHandleW(nil)
let className = wide("KubarTray")
var windowClass = WNDCLASSEXW()
windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
windowClass.lpfnWndProc = windowProc
windowClass.hInstance = instance
className.withUnsafeBufferPointer { windowClass.lpszClassName = $0.baseAddress; RegisterClassExW(&windowClass) }
// A hidden window that only receives the tray icon's messages.
let window = CreateWindowExW(0, className, wide("Kubar"), 0, 0, 0, 0, 0, nil, nil, instance, nil)
let model = Model()

notifyIcon(DWORD(NIM_ADD))
model.refreshSoon(reselect: true)
// Watch mode: refresh every 10s in the background. ponytail: fixed poll, like the macOS app.
Task.detached {
    while true {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        model.refreshSoon()
    }
}

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {  // false on WM_QUIT
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
#else
print("KubarTray is the Windows tray app. On macOS, open Kubar.xcodeproj; elsewhere use the kubar CLI.")
#endif
