// The popup window: what the macOS app shows in its menu bar popover, as Win32 common controls.
// It opens above the tray icon (or where you last moved it), stays open while you change the selections,
// and hides when it loses focus. Drag the coloured header to move it; drag the edges to resize it.
// It has no system frame (WM_NCCALCSIZE): the band reaches the top edge, and the edges resize via WM_NCHITTEST.
#if os(Windows)
import Foundation
import KubarCore
import WinSDK

/// Win32 values used here, spelled out: several are macros Swift doesn't import, or imports with awkward types.
enum W {
    static let popup: DWORD = 0x8000_0000, child: DWORD = 0x4000_0000, visible: DWORD = 0x1000_0000
    static let thickFrame: DWORD = 0x0004_0000, border: DWORD = 0x0080_0000, vscroll: DWORD = 0x0020_0000, hscroll: DWORD = 0x0010_0000
    static let tabstop: DWORD = 0x0001_0000, overlappedWindow: DWORD = 0x00CF_0000, clipChildren: DWORD = 0x0200_0000
    static let exToolWindow: DWORD = 0x80, exTopmost: DWORD = 0x8, exControlParent: DWORD = 0x1_0000
    static let ssNoPrefix: DWORD = 0x80
    static let cbsDropDownList: DWORD = 0x3
    static let cbAddString: UINT = 0x143, cbResetContent: UINT = 0x14B, cbSetCurSel: UINT = 0x14E, cbGetCurSel: UINT = 0x147
    static let cbnSelChange = 1
    static let lvsReport: DWORD = 0x1, lvsSingleSel: DWORD = 0x4, lvsShowSelAlways: DWORD = 0x8, lvsNoSortHeader: DWORD = 0x8000
    static let lvmFirst: UINT = 0x1000
    static let lvmDeleteAllItems = lvmFirst + 9, lvmGetNextItem = lvmFirst + 12, lvmSetColumnWidth = lvmFirst + 30
    static let lvmSetItemState = lvmFirst + 43
    static let lvmSetExtendedStyle = lvmFirst + 54, lvmInsertItem = lvmFirst + 77, lvmInsertColumn = lvmFirst + 97
    static let lvmSetItemText = lvmFirst + 116, lvmApproximateViewRect = lvmFirst + 64
    static let lvsExFullRowSelect: LPARAM = 0x20, lvsExDoubleBuffer: LPARAM = 0x1_0000
    static let nmDblClk = UINT(bitPattern: -3), nmCustomDraw = UINT(bitPattern: -12)
    static let esMultiline: DWORD = 0x4, esAutoVScroll: DWORD = 0x40, esAutoHScroll: DWORD = 0x80, esReadOnly: DWORD = 0x800
    static let emGetFirstVisibleLine: UINT = 0xCE, emLineScroll: UINT = 0xB6
}

enum Ctl: Int32 {
    case label = 0
    case namespaceLabel = 97, deploymentLabel = 98, title = 99, context = 100, hint, copy, nodesLabel, nodes, namespace, deployment, actions, podsLabel, pods, deletePod, refresh, quit
}

let actionRestart: Int32 = 201, actionDelete: Int32 = 202

var popup: HWND?
var controls: [Ctl: HWND] = [:]
/// What each combo item stands for (nil = "Select…"), and the labels and rows last shown, to skip unchanged updates.
var comboValues: [Ctl: [String?]] = [:]
var shownLabels: [Ctl: [String]] = [:]
var shownRows: [Ctl: [[String]]] = [:]
/// Text colour per row and column of each list (nil = default), drawn in NM_CUSTOMDRAW.
var shownColors: [Ctl: [[COLORREF?]]] = [:]
var shownText: [Ctl: String] = [:]
var shownPods: [String] = []
var hintCommand: String?
/// The header band's colour: blue when connected, red when the check failed, grey otherwise.
var headerColor: COLORREF = 0
/// The status at the right of the header band, drawn in WM_PAINT so the dot can have its own colour.
var statusText = "", statusDotColor: COLORREF = 0
/// A confirmation box takes the focus; don't hide the popup for that.
var modalOpen = false
var lastHidden = Date.distantPast
var font: HFONT?, boldFont: HFONT?, sectionFont: HFONT?, monoFont: HFONT?
var brushes: [COLORREF: HBRUSH] = [:]

let kubeBlue = rgb(50, 108, 229), failRed = rgb(200, 40, 40), idleGrey = rgb(120, 120, 120)
let okGreen = rgb(16, 140, 60), warnOrange = rgb(215, 120, 0), hintYellow = rgb(255, 246, 214)
let headerHeight: Int32 = 32  // the Context row starts at 38

func brush(_ color: COLORREF) -> HBRUSH? {
    if let b = brushes[color] { return b }
    let b = CreateSolidBrush(color)
    brushes[color] = b
    return b
}
let scale = Double(GetDpiForSystem()) / 96  // ponytail: system DPI; a monitor with a different scale gets scaled text, not re-layout

func px(_ v: Int32) -> Int32 { Int32((Double(v) * scale).rounded()) }
func rgb(_ r: DWORD, _ g: DWORD, _ b: DWORD) -> COLORREF { r | g << 8 | b << 16 }

@discardableResult
func send(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM = 0, _ lParam: LPARAM = 0) -> LRESULT {
    SendMessageW(hwnd, message, wParam, lParam)
}

@discardableResult
func send<T>(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ value: inout T) -> LRESULT {
    withUnsafeMutablePointer(to: &value) { SendMessageW(hwnd, message, wParam, LPARAM(Int(bitPattern: $0))) }
}

/// Runs `body` with a mutable NUL-terminated UTF-16 copy (for struct fields typed LPWSTR).
func withWide<R>(_ s: String, _ body: (UnsafeMutablePointer<WCHAR>) -> R) -> R {
    var chars = wide(s)
    return chars.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

func makeFont(_ points: Int32, bold: Bool = false, face: String = "Segoe UI") -> HFONT? {
    CreateFontW(-MulDiv(points, Int32(GetDpiForSystem()), 72), 0, 0, 0, bold ? 600 : 400, 0, 0, 0,
                1 /* DEFAULT_CHARSET */, 0, 0, 5 /* CLEARTYPE_QUALITY */, 0, wide(face))
}

// MARK: Building the window

@discardableResult
func add(_ id: Ctl, _ cls: String, _ text: String, _ style: DWORD, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
         font withFont: HFONT? = nil) -> HWND? {
    let hwnd = CreateWindowExW(0, wide(cls), wide(text), W.child | W.visible | style, px(x), px(y), px(w), px(h),
                               popup, HMENU(bitPattern: Int(id.rawValue)), instance, nil)
    send(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: withFont ?? font)), 1)
    if id != .label { controls[id] = hwnd }
    return hwnd
}

func addList(_ id: Ctl, _ y: Int32, _ h: Int32, columns: [(String, Int32)]) {
    let list = add(id, "SysListView32", "", W.border | W.tabstop | W.lvsReport | W.lvsSingleSel | W.lvsShowSelAlways | W.lvsNoSortHeader,
                   12, y, 536, h)
    send(list, W.lvmSetExtendedStyle, 0, W.lvsExFullRowSelect | W.lvsExDoubleBuffer)
    for (i, (title, width)) in columns.enumerated() {
        var column = LVCOLUMNW()
        column.mask = UINT(LVCF_TEXT | LVCF_WIDTH)
        column.cx = px(width)
        withWide(title) { column.pszText = $0; send(list, W.lvmInsertColumn, WPARAM(i), &column) }
    }
}

let popupWidth: Int32 = 560, popupHeight: Int32 = 526, minHeight: Int32 = 420

func createPopup() {
    var icc = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES))
    InitCommonControlsEx(&icc)
    font = makeFont(9); boldFont = makeFont(11, bold: true); sectionFont = makeFont(8, bold: true); monoFont = makeFont(9, face: "Consolas")

    for (name, proc) in [("KubarPopup", popupProc as WNDPROC), ("KubarDescribe", describeProc as WNDPROC)] {
        let cls = wide(name)
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = proc
        wc.hInstance = instance
        wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)  // repaint the header band across the new width when resized
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDC_ARROW
        cls.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress; RegisterClassExW(&wc) }
    }
    let size = windowSize(clientWidth: px(popupWidth), clientHeight: px(popupHeight))
    popup = CreateWindowExW(popupExStyle, wide("KubarPopup"), wide("Kubar"), popupStyle, 0, 0, size.cx, size.cy, nil, nil, instance, nil)

    let combo = W.cbsDropDownList | W.vscroll | W.tabstop
    add(.title, "STATIC", "Kubar", W.ssNoPrefix, 12, 4, 200, 24, font: boldFont)
    add(.label, "STATIC", "Context", 0, 12, 41, 84, 20)
    add(.context, "COMBOBOX", "", combo, 96, 38, 452, 300)
    add(.hint, "STATIC", "", W.ssNoPrefix, 12, 70, 452, 48)
    add(.copy, "BUTTON", "Copy fix", W.tabstop, 472, 70, 76, 26)
    add(.nodesLabel, "STATIC", "NODES", 0, 12, 124, 536, 18, font: sectionFont)
    addList(.nodes, 142, 112, columns: [("Node", 190), ("Roles · version", 150), ("CPU", 95), ("Memory", 95)])
    add(.namespaceLabel, "STATIC", "Namespace", 0, 12, 267, 84, 20)
    add(.namespace, "COMBOBOX", "", combo, 96, 264, 452, 300)
    add(.deploymentLabel, "STATIC", "Deployment", 0, 12, 297, 84, 20)
    add(.deployment, "COMBOBOX", "", combo, 96, 294, 360, 300)
    add(.actions, "BUTTON", "Actions…", W.tabstop, 464, 293, 84, 26)
    add(.podsLabel, "STATIC", "PODS", 0, 12, 330, 536, 18, font: sectionFont)
    addList(.pods, 348, 130, columns: [("Pod", 220), ("Status", 100), ("Ready", 50), ("Restarts", 60), ("Node", 100)])
    add(.deletePod, "BUTTON", "Delete pod…", W.tabstop, 12, 488, 130, 28)
    add(.refresh, "BUTTON", "Refresh", W.tabstop, 368, 488, 86, 28)
    add(.quit, "BUTTON", "Quit", W.tabstop, 462, 488, 86, 28)
    var client = RECT()
    GetClientRect(popup, &client)
    layout(client.right, client.bottom)
}

let popupStyle = W.popup | W.thickFrame | W.clipChildren
let popupExStyle = W.exToolWindow | W.exTopmost | W.exControlParent

/// The window size for a client area of this size: the same, since the popup draws no system frame.
func windowSize(clientWidth: Int32, clientHeight: Int32) -> SIZE { SIZE(cx: clientWidth, cy: clientHeight) }

/// Places the controls for a client area of `width` x `height` pixels: the nodes list is as tall as its rows
/// (1 to 5), everything stretches sideways, the pods list takes the rest of the height, and the bottom
/// buttons stay at the bottom.
func layout(_ width: Int32, _ height: Int32) {
    let m = px(12), right = width - m
    func place(_ id: Ctl, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) { MoveWindow(controls[id], x, y, w, h, true) }
    place(.context, px(96), px(38), right - px(96), px(300))
    // The hint area only takes room while there is a problem to explain.
    var top = px(70)
    let hasHint = shownText[.hint]?.isEmpty == false
    ShowWindow(controls[.hint], hasHint ? SW_SHOW : SW_HIDE)
    if hasHint {
        place(.hint, m, top, right - px(84) - m, px(48))
        place(.copy, right - px(76), top, px(76), px(26))
        top += px(54)
    }
    place(.nodesLabel, m, top, right - m, px(18))
    let rows = min(max(shownRows[.nodes]?.count ?? 1, 1), 5)
    let view = send(controls[.nodes], W.lvmApproximateViewRect, WPARAM(rows), LPARAM(0xFFFF_FFFF))  // header + rows
    let nodesHeight = Int32((view >> 16) & 0xFFFF) + px(4)
    place(.nodes, m, top + px(18), right - m, nodesHeight)
    let y = top + px(18) + nodesHeight + px(10)
    place(.namespaceLabel, m, y + px(3), px(84), px(20))
    place(.namespace, px(96), y, right - px(96), px(300))
    place(.deploymentLabel, m, y + px(33), px(84), px(20))
    place(.deployment, px(96), y + px(30), right - px(96) - px(92), px(300))
    place(.actions, right - px(84), y + px(29), px(84), px(26))
    place(.podsLabel, m, y + px(66), right - m, px(18))
    place(.pods, m, y + px(84), right - m, max(px(60), height - y - px(84) - px(48)))
    place(.deletePod, m, height - px(38), px(130), px(28))
    place(.refresh, right - px(180), height - px(38), px(86), px(28))
    place(.quit, right - px(86), height - px(38), px(86), px(28))
    // The first column takes the width the others don't use, keeping room for a vertical scroll bar, so the
    // columns always fit: no horizontal scroll bar, which would make the plain wheel scroll sideways.
    for (id, others) in [(Ctl.nodes, 150 + 95 + 95), (Ctl.pods, 100 + 50 + 60 + 100)] {
        var inside = RECT()
        GetClientRect(controls[id], &inside)
        let room = inside.right - px(Int32(others)) - GetSystemMetrics(SM_CXVSCROLL) - 1
        send(controls[id], W.lvmSetColumnWidth, 0, LPARAM(max(px(80), room)))
    }
}

// MARK: Remembering where it was moved

let frameKey = "KubarPopupFrame"

func savedFrame() -> RECT? {
    guard let v = UserDefaults.standard.array(forKey: frameKey) as? [Int], v.count == 4 else { return nil }
    return RECT(left: Int32(v[0]), top: Int32(v[1]), right: Int32(v[2]), bottom: Int32(v[3]))
}

func saveFrame() {
    var rect = RECT()
    GetWindowRect(popup, &rect)
    UserDefaults.standard.set([rect.left, rect.top, rect.right, rect.bottom].map(Int.init), forKey: frameKey)
}

func resetFrame() {
    UserDefaults.standard.removeObject(forKey: frameKey)
    hidePopup()
}

// MARK: Showing and hiding

func togglePopup() {
    guard let popup else { return }
    if IsWindowVisible(popup) { hidePopup(); return }
    // Clicking the icon while the popup is open first takes its focus away (which hides it); don't reopen.
    if Date().timeIntervalSince(lastHidden) < 0.3 { return }
    var cursor = POINT()
    GetCursorPos(&cursor)
    let saved = savedFrame()
    // The monitor it goes on: where it was left, or the one with the tray icon.
    let anchor = saved.map { POINT(x: $0.left, y: $0.top) } ?? cursor
    var info = MONITORINFO()
    info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    GetMonitorInfoW(MonitorFromPoint(anchor, DWORD(MONITOR_DEFAULTTONEAREST)), &info)
    let work = info.rcWork
    let size = windowSize(clientWidth: px(popupWidth), clientHeight: px(popupHeight))
    let w = min(saved.map { $0.right - $0.left } ?? size.cx, work.right - work.left)
    let h = min(saved.map { $0.bottom - $0.top } ?? size.cy, work.bottom - work.top)
    var x = cursor.x - w / 2
    // Above the icon when the taskbar is at the bottom, below it otherwise.
    var y = cursor.y - h - 12 >= work.top ? cursor.y - h - 12 : cursor.y + 12
    if let saved { x = saved.left; y = saved.top }
    x = min(max(x, work.left), work.right - w)  // keep it on screen, e.g. after a monitor was unplugged
    y = min(max(y, work.top), work.bottom - h)
    SetWindowPos(popup, HWND(bitPattern: -1) /* HWND_TOPMOST */, x, y, w, h, UINT(SWP_SHOWWINDOW))
    SetForegroundWindow(popup)
    updatePopup()
    model.refreshSoon()
}

func hidePopup() {
    guard let popup, IsWindowVisible(popup) else { return }
    ShowWindow(popup, SW_HIDE)
    lastHidden = Date()
}

func confirm(_ title: String, _ detail: String) -> Bool {
    let s = model.snapshot
    let text = "\(detail)\n\nContext: \(s.selectedContext ?? "?")\nNamespace: \(s.selectedNamespace ?? "?")"
    modalOpen = true
    defer { modalOpen = false }
    return MessageBoxW(popup, wide(text), wide(title), UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK
}

// MARK: Updating from the model

func setText(_ id: Ctl, _ text: String) {
    guard shownText[id] != text else { return }
    shownText[id] = text
    SetWindowTextW(controls[id], wide(text))
}

/// Refills a drop-down only when its items changed (refilling closes it), then selects `selected`.
func setCombo(_ id: Ctl, labels: [String], values: [String?], selected: String?) {
    let combo = controls[id]
    if shownLabels[id] != labels {
        shownLabels[id] = labels
        send(combo, W.cbResetContent)
        for label in labels { _ = wide(label).withUnsafeBufferPointer { send(combo, W.cbAddString, 0, LPARAM(Int(bitPattern: $0.baseAddress))) } }
    }
    comboValues[id] = values
    let index = values.firstIndex(of: selected) ?? 0
    if send(combo, W.cbGetCurSel) != index { send(combo, W.cbSetCurSel, WPARAM(index)) }
}

func selectedRow(_ id: Ctl) -> Int? {
    let index = send(controls[id], W.lvmGetNextItem, WPARAM.max /* -1: from the start */, 2 /* LVNI_SELECTED */)
    return index >= 0 ? Int(index) : nil
}

/// Refills a list only when its rows changed, keeping the row with the same first column selected.
func setRows(_ id: Ctl, _ rows: [[String]], colors: [[COLORREF?]]) {
    guard shownRows[id] != rows, let list = controls[id] else { return }
    let selectedKey = selectedRow(id).flatMap { shownRows[id]?[$0].first }
    let oldCount = shownRows[id]?.count
    shownRows[id] = rows
    shownColors[id] = colors
    send(list, UINT(WM_SETREDRAW), 0)
    send(list, W.lvmDeleteAllItems)
    for (i, row) in rows.enumerated() {
        var item = LVITEMW()
        item.mask = UINT(LVIF_TEXT)
        item.iItem = Int32(i)
        withWide(row[0]) { item.pszText = $0; send(list, W.lvmInsertItem, 0, &item) }
        for column in row.indices.dropFirst() {
            item.iSubItem = Int32(column)
            withWide(row[column]) { item.pszText = $0; send(list, W.lvmSetItemText, WPARAM(i), &item) }
        }
    }
    if let selectedKey, let i = rows.firstIndex(where: { $0.first == selectedKey }) {
        var item = LVITEMW()
        item.state = 3; item.stateMask = 3  // LVIS_SELECTED | LVIS_FOCUSED
        send(list, W.lvmSetItemState, WPARAM(i), &item)
    }
    send(list, UINT(WM_SETREDRAW), 1)
    if id == .nodes, oldCount != rows.count {  // the nodes list is sized to its rows
        var client = RECT()
        GetClientRect(popup, &client)
        layout(client.right, client.bottom)
    }
}

func updatePopup() {
    guard let popup, IsWindowVisible(popup) else { return }
    let s = model.snapshot

    var status = "Idle", problem = s.loadError, color = idleGrey, dot = rgb(225, 225, 225)
    if let error = s.loadError {
        status = error; color = failRed; dot = rgb(255, 214, 102)
    } else {
        switch s.status {
        case .idle: break
        case .checking: status = "Checking…"
        case .connected: status = "Connected"; color = kubeBlue; dot = rgb(90, 230, 130)
        case .checkFailed(let message): status = "Check failed"; color = failRed; dot = rgb(255, 214, 102); problem = message
        }
    }
    if (headerColor, statusText, statusDotColor) != (color, status, dot) {
        (headerColor, statusText, statusDotColor) = (color, status, dot)
        InvalidateRect(popup, nil, true)  // repaint the band, the status on it and the title label
    }
    setCombo(.context, labels: s.contexts.map { $0 == s.currentContext ? "\($0)  (current)" : $0 }, values: s.contexts, selected: s.selectedContext)

    let hint = problem.flatMap(ConnectionHint.suggest)
    hintCommand = hint?.command
    let hadHint = shownText[.hint]?.isEmpty == false
    setText(.hint, (problem.map { String($0.prefix(200)) } ?? "") + (hint.map { "\r\n💡 " + $0.text } ?? ""))
    if hadHint != (shownText[.hint]?.isEmpty == false) {  // the hint area appeared or went away: move things up or down
        var client = RECT()
        GetClientRect(popup, &client)
        layout(client.right, client.bottom)
    }
    ShowWindow(controls[.copy], hintCommand == nil ? SW_HIDE : SW_SHOW)

    setText(.nodesLabel, "NODES (\(s.nodes.count))")
    // Same thresholds as the macOS gauges.
    func load(_ percent: Int?) -> COLORREF? { percent.map { $0 >= 85 ? failRed : $0 >= 70 ? warnOrange : okGreen } }
    setRows(.nodes, s.nodes.map { n in
        [(n.ready ? "● " : "○ ") + n.name,
         n.roles == "<none>" ? n.version : "\(n.roles) · \(n.version)",
         n.usage.map { "\($0.cpu) · \($0.cpuPct)%" } ?? "-",
         n.usage.map { "\($0.mem) · \($0.memPct)%" } ?? "-"]
    }, colors: s.nodes.map { [$0.ready ? okGreen : failRed, nil, load($0.usage?.cpuPct), load($0.usage?.memPct)] })

    setCombo(.namespace, labels: ["Select… (\(s.namespaces.count))"] + s.namespaces, values: [nil] + s.namespaces, selected: s.selectedNamespace)
    EnableWindow(controls[.namespace], !s.namespaces.isEmpty)
    let deployments = s.deployments
    let first = s.selectedNamespace == nil ? "" : deployments.isEmpty ? "No deployments" : "Select… (\(deployments.count))"
    setCombo(.deployment, labels: [first] + deployments.map { "\($0.name)   \($0.ready)/\($0.desired) ready" },
             values: [nil] + deployments.map(\.name), selected: s.selectedDeployment)
    EnableWindow(controls[.deployment], !deployments.isEmpty)
    EnableWindow(controls[.actions], s.selectedDeployment != nil)

    setText(.podsLabel, s.selectedDeployment.map { "PODS OF \($0) (\(s.pods.count))" } ?? "PODS")
    shownPods = s.pods.map(\.name)
    setRows(.pods, s.pods.map { [($0.ok ? "● " : "○ ") + $0.name, $0.status, $0.ready, String($0.restarts), $0.node] },
            colors: s.pods.map { [$0.ok ? okGreen : warnOrange, $0.ok ? okGreen : warnOrange, nil, $0.restarts > 0 ? warnOrange : nil, nil] })
    EnableWindow(controls[.deletePod], !s.pods.isEmpty)
}

// MARK: Input

func command(_ id: Int32, _ code: Int) {
    let s = model.snapshot
    switch id {
    case Ctl.context.rawValue, Ctl.namespace.rawValue, Ctl.deployment.rawValue:
        guard code == W.cbnSelChange, let ctl = Ctl(rawValue: id), let values = comboValues[ctl] else { return }
        let index = Int(send(controls[ctl], W.cbGetCurSel))
        guard values.indices.contains(index) else { return }
        let value = values[index]
        switch ctl {
        case .context: if let value, value != s.selectedContext { model.selectContext(value) }
        case .namespace: if value != s.selectedNamespace { model.selectNamespace(value) }
        default: if value != s.selectedDeployment { model.selectDeployment(value) }
        }
    case Ctl.copy.rawValue:
        if let hintCommand { copyToClipboard(hintCommand) }
    case Ctl.actions.rawValue:
        var rect = RECT()
        GetWindowRect(controls[.actions], &rect)
        let menu = CreatePopupMenu()!
        defer { DestroyMenu(menu) }
        AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(actionRestart), wide("Restart…"))
        AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(actionDelete), wide("Delete…"))
        TrackPopupMenu(menu, 0, rect.left, rect.bottom, 0, popup, nil)  // the choice comes back as WM_COMMAND
    case actionRestart:
        guard let dep = s.selectedDeployment else { return }
        if confirm("Restart deployment \(dep)?", "Its pods are replaced one by one (rolling restart).") { model.perform(.restartDeployment(dep)) }
    case actionDelete:
        guard let dep = s.selectedDeployment else { return }
        if confirm("Delete deployment \(dep)?", "The deployment and all its pods are removed.") { model.perform(.deleteDeployment(dep)) }
    case Ctl.deletePod.rawValue:
        guard let row = selectedRow(.pods), shownPods.indices.contains(row) else {
            modalOpen = true
            MessageBoxW(popup, wide("Select a pod in the list first."), wide("Kubar"), UINT(MB_OK | MB_ICONINFORMATION))
            modalOpen = false
            return
        }
        let pod = shownPods[row]
        if confirm("Delete pod \(pod)?", "Its deployment creates a replacement, so this restarts the pod.") { model.perform(.deletePod(pod)) }
    case Ctl.refresh.rawValue:
        model.refreshSoon()
    case Ctl.quit.rawValue:
        quit()
    case 2:  // IDCANCEL: Esc
        hidePopup()
    default:
        break
    }
}

func popupProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case UINT(WM_COMMAND):
        command(Int32(wParam & 0xFFFF), Int((wParam >> 16) & 0xFFFF))
        return 0
    case UINT(WM_NOTIFY):
        let header = UnsafePointer<NMHDR>(bitPattern: Int(lParam))!.pointee
        if header.code == W.nmCustomDraw, let id = Ctl(rawValue: Int32(header.idFrom)), let colors = shownColors[id] {
            let draw = UnsafeMutablePointer<NMLVCUSTOMDRAW>(bitPattern: Int(lParam))!
            switch draw.pointee.nmcd.dwDrawStage {
            case 0x1, 0x1_0001: return 0x20  // CDDS_(ITEM)PREPAINT -> CDRF_NOTIFYITEMDRAW / NOTIFYSUBITEMDRAW
            case 0x3_0001:  // CDDS_ITEMPREPAINT | CDDS_SUBITEM: one cell
                let row = Int(draw.pointee.nmcd.dwItemSpec), column = Int(draw.pointee.iSubItem)
                draw.pointee.clrText = colors[safe: row]?[safe: column].flatMap { $0 } ?? GetSysColor(COLOR_WINDOWTEXT)
                return 0
            default: return 0
            }
        }
        if header.idFrom == UINT_PTR(Ctl.nodes.rawValue), header.code == W.nmDblClk,
           let row = selectedRow(.nodes), let name = model.snapshot.nodes[safe: row]?.name {
            openDescribe(name)
        }
        return 0
    case UINT(WM_ACTIVATE):
        if wParam & 0xFFFF == 0 /* WA_INACTIVE */ && !modalOpen { hidePopup() }
        return 0
    case UINT(WM_CTLCOLORSTATIC):
        let dc = HDC(bitPattern: UInt(wParam))
        let from = HWND(bitPattern: Int(lParam))
        SetBkMode(dc, 1)  // TRANSPARENT
        if from == controls[.title] {  // white on the header band
            SetTextColor(dc, rgb(255, 255, 255))
            return LRESULT(Int(bitPattern: brush(headerColor)))
        }
        if from == controls[.nodesLabel] || from == controls[.podsLabel] { SetTextColor(dc, kubeBlue) }
        if from == controls[.hint], shownText[.hint]?.isEmpty == false { return LRESULT(Int(bitPattern: brush(hintYellow))) }
        return LRESULT(Int(bitPattern: GetSysColorBrush(COLOR_WINDOW)))
    case UINT(WM_PAINT):
        var paint = PAINTSTRUCT()
        let dc = BeginPaint(hwnd, &paint)
        var client = RECT()
        GetClientRect(hwnd, &client)
        var band = RECT(left: 0, top: 0, right: client.right, bottom: px(headerHeight))
        FillRect(dc, &band, brush(headerColor))
        // Status, right-aligned on the band: "● Connected" with the dot in its own colour.
        SelectObject(dc, font)
        SetBkMode(dc, 1)  // TRANSPARENT
        let text = wide(statusText), dot = wide("● ")
        var textSize = SIZE(), dotSize = SIZE()
        GetTextExtentPoint32W(dc, text, Int32(text.count - 1), &textSize)
        GetTextExtentPoint32W(dc, dot, Int32(dot.count - 1), &dotSize)
        let x = client.right - px(12) - textSize.cx, y = (px(headerHeight) - textSize.cy) / 2
        SetTextColor(dc, statusDotColor)
        TextOutW(dc, x - dotSize.cx, y, dot, Int32(dot.count - 1))
        SetTextColor(dc, rgb(255, 255, 255))
        TextOutW(dc, x, y, text, Int32(text.count - 1))
        FrameRect(dc, &client, brush(rgb(170, 170, 170)))  // a thin outline in place of the frame
        EndPaint(hwnd, &paint)
        return 0
    case UINT(WM_NCCALCSIZE):
        return 0  // the whole window is client area: no system frame or white strip at the top
    case UINT(WM_NCHITTEST):
        // Edges resize, the header band moves the window like a title bar.
        var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
        ScreenToClient(hwnd, &point)
        var client = RECT()
        GetClientRect(hwnd, &client)
        let edge = px(6)
        let left = point.x < edge, right = point.x >= client.right - edge
        let top = point.y < edge, bottom = point.y >= client.bottom - edge
        switch (top, bottom, left, right) {
        case (true, _, true, _): return LRESULT(HTTOPLEFT)
        case (true, _, _, true): return LRESULT(HTTOPRIGHT)
        case (_, true, true, _): return LRESULT(HTBOTTOMLEFT)
        case (_, true, _, true): return LRESULT(HTBOTTOMRIGHT)
        case (true, _, _, _): return LRESULT(HTTOP)
        case (_, true, _, _): return LRESULT(HTBOTTOM)
        case (_, _, true, _): return LRESULT(HTLEFT)
        case (_, _, _, true): return LRESULT(HTRIGHT)
        default: return LRESULT(point.y < px(headerHeight) ? HTCAPTION : HTCLIENT)
        }
    case UINT(WM_SIZE):
        layout(Int32(lParam & 0xFFFF), Int32((lParam >> 16) & 0xFFFF))
        return 0
    case UINT(WM_GETMINMAXINFO):
        let size = windowSize(clientWidth: px(popupWidth), clientHeight: px(minHeight))
        UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam))!.pointee.ptMinTrackSize = POINT(x: size.cx, y: size.cy)
        return 0
    case 0x232:  // WM_EXITSIZEMOVE: remember where it was put
        saveFrame()
        return 0
    case UINT(WM_CLOSE):
        hidePopup()
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Node detail window

/// `kubectl describe node` in its own window, re-run every 10s like the macOS app; it keeps the scroll position.
let describeUpdated = UINT(WM_APP + 4)
let describeLock = NSLock()
var describeTexts: [Int: String] = [:]

func openDescribe(_ node: String) {
    guard let context = model.snapshot.selectedContext,
          let window = CreateWindowExW(0, wide("KubarDescribe"), wide("\(node) — \(context)"), W.overlappedWindow | W.visible,
                                       Int32(bitPattern: 0x8000_0000), 0, px(760), px(560), nil, nil, instance, nil) else { return }
    let edit = CreateWindowExW(0, wide("EDIT"), wide("Loading…"),
                               W.child | W.visible | W.vscroll | W.hscroll | W.esMultiline | W.esReadOnly | W.esAutoVScroll | W.esAutoHScroll,
                               0, 0, 0, 0, window, nil, instance, nil)
    send(edit, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: monoFont)), 1)
    var client = RECT()
    GetClientRect(window, &client)
    MoveWindow(edit, 0, 0, client.right, client.bottom, true)
    let key = Int(bitPattern: window)
    Task.detached {
        while IsWindow(HWND(bitPattern: key)) {
            let out = await KubeClient.output(context, ["describe", "node", node])
            if !out.isEmpty {  // keep the last good text if a refresh fails
                describeLock.lock(); describeTexts[key] = out.replacingOccurrences(of: "\n", with: "\r\n"); describeLock.unlock()
                PostMessageW(HWND(bitPattern: key), describeUpdated, 0, 0)
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}

func describeProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    let edit = GetWindow(hwnd, UINT(GW_CHILD))
    switch message {
    case UINT(WM_SIZE):
        MoveWindow(edit, 0, 0, Int32(lParam & 0xFFFF), Int32((lParam >> 16) & 0xFFFF), true)
        return 0
    case describeUpdated:
        describeLock.lock(); let text = describeTexts[Int(bitPattern: hwnd)]; describeLock.unlock()
        guard let text else { return 0 }
        let line = send(edit, W.emGetFirstVisibleLine)
        SetWindowTextW(edit, wide(text))
        send(edit, W.emLineScroll, 0, LPARAM(line))
        return 0
    case UINT(WM_DESTROY):
        describeLock.lock(); describeTexts[Int(bitPattern: hwnd)] = nil; describeLock.unlock()
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}
#endif
