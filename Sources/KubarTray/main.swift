// Kubar for Windows: a notification-area (tray) icon that opens a popup window with the same things as the
// macOS menu bar app, built on KubarCore and plain Win32 (WinSDK). Left click opens the popup (Popup.swift);
// right click shows Refresh and Quit.
#if os(Windows)
import Foundation
import KubarCore
import WinSDK

// MARK: Model

/// What the popup shows. Background tasks write it under `lock`; the UI thread reads a copy,
/// so the window never waits on kubectl.
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
        PostMessageW(window, stateChanged, 0, 0)  // update the tooltip and popup on the UI thread
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

    func selectContext(_ name: String) {
        defaults.set(name, forKey: "KubarSelectedContext")
        change {
            $0.selectedContext = name
            $0.status = .checking
            $0.nodes = []; $0.namespaces = []
            $0.selectedNamespace = nil; $0.deployments = []; $0.selectedDeployment = nil; $0.pods = []
        }
        refreshSoon(reselect: true)
    }

    func selectNamespace(_ name: String?) {
        guard let context = snapshot.selectedContext else { return }
        defaults.set(name, forKey: Self.key("Namespace", context))
        defaults.removeObject(forKey: Self.key("Deployment", context))
        change { $0.selectedNamespace = name; $0.deployments = []; $0.selectedDeployment = nil; $0.pods = [] }
        refreshSoon()
    }

    func selectDeployment(_ name: String?) {
        guard let context = snapshot.selectedContext else { return }
        defaults.set(name, forKey: Self.key("Deployment", context))
        change { $0.selectedDeployment = name; $0.pods = [] }
        refreshSoon()
    }

    func refreshSoon(reselect: Bool = false) {
        let gen = bump()
        Task.detached { await self.refresh(gen, reselect: reselect) }
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
                pods = await KubeClient.pods(context, namespace: ns)
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

// MARK: Tray icon

let trayMessage = UINT(WM_APP + 1)
let stateChanged = UINT(WM_APP + 2)
let taskbarCreated = RegisterWindowMessageW(wide("TaskbarCreated"))
let menuRefresh: UINT_PTR = 1, menuQuit: UINT_PTR = 2, menuResetPosition: UINT_PTR = 3

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
    let chars = Array(statusLine(model.snapshot).utf16.prefix(127)) + [0]  // szTip holds 128 WCHARs
    chars.withUnsafeBytes { src in withUnsafeMutableBytes(of: &data.szTip) { $0.copyMemory(from: src) } }
    Shell_NotifyIconW(message, &data)
}

/// The tray tooltip, e.g. "Kubar · my-cluster: connected".
func statusLine(_ s: Snapshot) -> String {
    guard let context = s.selectedContext, s.loadError == nil else { return "Kubar" }
    switch s.status {
    case .connected: return "Kubar · \(context): connected"
    case .checkFailed: return "Kubar · \(context): check failed"
    case .checking: return "Kubar · \(context): checking…"
    case .idle: return "Kubar · \(context)"
    }
}

func showTrayMenu() {
    let menu = CreatePopupMenu()!
    defer { DestroyMenu(menu) }
    AppendMenuW(menu, UINT(MF_STRING), menuRefresh, wide("Refresh"))
    AppendMenuW(menu, UINT(MF_STRING) | (savedFrame() == nil ? UINT(MF_GRAYED) : 0), menuResetPosition, wide("Reset window position"))
    AppendMenuW(menu, UINT(MF_STRING), menuQuit, wide("Quit Kubar"))
    var point = POINT()
    GetCursorPos(&point)
    SetForegroundWindow(window)  // otherwise the menu doesn't close when you click elsewhere
    TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)  // the choice arrives as WM_COMMAND
    PostMessageW(window, UINT(WM_NULL), 0, 0)
}

func quit() {
    notifyIcon(DWORD(NIM_DELETE))
    PostQuitMessage(0)
}

func windowProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case trayMessage:
        switch UINT(lParam & 0xFFFF) {
        case UINT(WM_LBUTTONUP): togglePopup()
        case UINT(WM_RBUTTONUP): showTrayMenu()
        default: break
        }
        return 0
    case UINT(WM_COMMAND):
        switch UINT_PTR(wParam & 0xFFFF) {
        case menuRefresh: model.refreshSoon()
        case menuQuit: quit()
        case menuResetPosition: resetFrame()
        default: break
        }
        return 0
    case stateChanged:
        notifyIcon(DWORD(NIM_MODIFY))
        updatePopup()
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
SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))  // per-monitor v2: sharp text

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

createPopup()
notifyIcon(DWORD(NIM_ADD))
model.refreshSoon(reselect: true)
// Watch mode: refresh every 10s while the popup is open, like the macOS app. While it's closed nothing
// runs kubectl (opening it refreshes at once), so the tooltip shows the status from the last time it was open.
Task.detached {
    while true {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        if IsWindowVisible(popup) { model.refreshSoon() }
    }
}

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {  // false on WM_QUIT
    // Shift+wheel scrolls sideways (the list and text controls only know the plain wheel).
    if msg.message == UINT(WM_MOUSEWHEEL), GetKeyState(Int32(VK_SHIFT)) < 0 {
        let delta = Int16(truncatingIfNeeded: (msg.wParam >> 16) & 0xFFFF)
        for _ in 0..<3 { SendMessageW(msg.hwnd, UINT(WM_HSCROLL), delta > 0 ? 0 /* SB_LINELEFT */ : 1 /* SB_LINERIGHT */, 0) }
        continue
    }
    // Tab and arrow keys between the popup's controls.
    if let popup, IsDialogMessageW(popup, &msg) { continue }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
#else
print("KubarTray is the Windows tray app. On macOS, open Kubar.xcodeproj; elsewhere use the kubar CLI.")
#endif
