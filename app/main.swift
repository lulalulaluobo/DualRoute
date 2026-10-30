import AppKit
import Foundation
import ServiceManagement

private let statusPath = "/var/run/codex-ts-gateway-status.json"
private let controllerPath = "/Library/Application Support/CodexTailscaleGateway/control.py"
private let pythonPath = "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"

struct GatewayState {
    var status = "等待后台状态"
    var mode = ""
    var interface = "—"
    var lanIP = "192.168.2.123"
    var gateway = "192.168.2.1"
    var routeCount = 0
    var extraDirect: [String] = []
    var updatedAt: Date?
    var error: String?
    var present = false

    init(data: Data? = nil) {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return }
        present = true
        status = json["status"] as? String ?? status
        mode = json["mode"] as? String ?? ""
        interface = json["interface"] as? String ?? "—"
        lanIP = json["lan_ip"] as? String ?? lanIP
        gateway = json["gateway"] as? String ?? gateway
        routeCount = json["route_count"] as? Int ?? 0
        error = json["error"] as? String
        let config = json["config"] as? [String: Any] ?? [:]
        extraDirect = json["extra_direct"] as? [String] ?? config["extra_direct"] as? [String] ?? []
        if let stamp = json["updated_at"] as? String {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            updatedAt = format.date(from: stamp)
            if updatedAt == nil {
                format.formatOptions = [.withInternetDateTime]
                updatedAt = format.date(from: stamp)
            }
        }
    }

    var stale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 90 } ?? true }
    var modeTitle: String {
        mode == "split" ? "国内 IP 直连" : mode == "full" ? "全部走 Tailscale" : "尚未确认"
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

func routeTemplateImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 9, y: 2.5))
        path.line(to: NSPoint(x: 9, y: 6.5))
        path.curve(to: NSPoint(x: 3.5, y: 14.5), controlPoint1: NSPoint(x: 9, y: 10), controlPoint2: NSPoint(x: 3.5, y: 10.5))
        path.move(to: NSPoint(x: 9, y: 6.5))
        path.curve(to: NSPoint(x: 14.5, y: 14.5), controlPoint1: NSPoint(x: 9, y: 10), controlPoint2: NSPoint(x: 14.5, y: 10.5))
        for x in [3.5, 14.5] {
            path.move(to: NSPoint(x: x - 2, y: 12.5))
            path.line(to: NSPoint(x: x, y: 14.5))
            path.line(to: NSPoint(x: x + 2, y: 12.5))
        }
        path.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var state = GatewayState()
    private var busy = false
    private var actionText = ""
    private var settings: NSWindow?
    private var gatewayField: NSTextField?
    private var directEditor: NSTextView?
    private var saveButton: NSButton?
    private var operationLabel: NSTextField?
    private var launchCheckbox: NSButton?
    private let routeImage = routeTemplateImage()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func refresh() {
        state = GatewayState(data: try? Data(contentsOf: URL(fileURLWithPath: statusPath)))
        let caution = !state.present || state.stale || !(state.error ?? "").isEmpty
        item.button?.title = busy ? " 双径…" : " 双径"
        item.button?.image = busy || caution
            ? NSImage(systemSymbolName: busy ? "arrow.triangle.2.circlepath" : "network.badge.shield.half.filled", accessibilityDescription: "双径 · DualRoute")
            : routeImage
        item.button?.image?.isTemplate = true
        item.button?.toolTip = busy ? actionText : "双径 · \(state.modeTitle) · \(state.status)"
        rebuildMenu()
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
    }

    @discardableResult private func addAction(_ title: String, selector: Selector, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        row.target = self
        row.isEnabled = enabled
        menu.addItem(row)
        return row
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        addInfo("双径 · DualRoute", to: menu)
        addInfo(busy ? actionText : String(state.status.prefix(75)), to: menu)
        if state.stale { addInfo(state.present ? "⚠ 状态超过 90 秒未更新，请检查后台" : "⚠ 尚未读取到后台状态", to: menu) }
        if let error = state.error, !error.isEmpty { addInfo("错误：\(String(error.prefix(75)))", to: menu) }
        menu.addItem(.separator())
        addInfo("模式：\(state.modeTitle)", to: menu)
        addInfo("出口接口：\(state.interface)", to: menu)
        addInfo("设备网关（Mac）：\(state.lanIP)", to: menu)
        addInfo("国内直连网关：\(state.gateway)", to: menu)
        addInfo("直连网段：\(state.routeCount) 条", to: menu)
        if let updated = state.updatedAt {
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
            addInfo("后台更新：\(fmt.string(from: updated))", to: menu)
        }
        menu.addItem(.separator())
        let split = addAction("国内 IP 直连", selector: #selector(selectSplit), to: menu, enabled: !busy)
        split.state = state.mode == "split" ? .on : .off
        let full = addAction("全部走 Tailscale", selector: #selector(selectFull), to: menu, enabled: !busy)
        full.state = state.mode == "full" ? .on : .off
        addAction("立即检查修复…", selector: #selector(repair), to: menu, enabled: !busy)
        addAction("配置与额外直连规则…", selector: #selector(showSettings), to: menu, enabled: !busy)
        menu.addItem(.separator())
        addAction("打开 Tailscale", selector: #selector(openTailscale), to: menu)
        addAction("打开使用说明", selector: #selector(openGuide), to: menu)
        menu.addItem(.separator())
        addAction("退出菜单栏（保持网络转发）", selector: #selector(quit), to: menu, enabled: !busy)
        item.menu = menu
    }

    @objc private func selectSplit() { runController(["split"], title: "正在切换为国内 IP 直连…") }
    @objc private func selectFull() { runController(["full"], title: "正在切换为全部走 Tailscale…") }
    @objc private func repair() { runController(["refresh"], title: "正在检查并恢复网络规则…") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openTailscale() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
    }
    @objc private func openGuide() {
        guard let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") else {
            alert("说明文档未找到", "请重新安装完整的双径应用。"); return
        }
        if !NSWorkspace.shared.open(url) { alert("说明文档未找到", url.path) }
    }

    private func runController(_ arguments: [String], title: String) {
        guard !busy else { return }
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            alert("Python 运行环境不存在", "请按使用说明恢复 Python 路径或后台任务。"); return
        }
        busy = true; actionText = title
        saveButton?.isEnabled = false
        operationLabel?.stringValue = title + " 首次加载可能需要约 1–2 分钟。"
        refresh()
        let command = "cd /private/tmp && " + ([pythonPath, "-I", controllerPath] + arguments).map(shellQuote).joined(separator: " ")
        let source = "with timeout of 300 seconds\n do shell script " + appleQuote(command) + " with administrator privileges\nend timeout"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A separate osascript process keeps authentication and long routing work off the UI thread.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            var message = ""; var exitCode: Int32 = -1
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                exitCode = process.terminationStatus
                message = String(data: data, encoding: .utf8) ?? ""
            } catch { message = error.localizedDescription }
            let resultCode = exitCode, resultMessage = message
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.saveButton?.isEnabled = true
                self.operationLabel?.stringValue = resultCode == 0 ? "操作完成，后台状态已刷新。" : "操作未完成，请查看错误并检查后台状态。"
                self.refresh()
                if resultCode != 0 {
                    self.alert(resultMessage.contains("(-128)") ? "操作已取消" : "操作未完成", String(resultMessage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1800)))
                }
            }
        }
    }

    @objc private func showSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 485), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "双径 · 分流配置"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 485))
        window.contentView = view
        func label(_ text: String, _ y: CGFloat, height: CGFloat = 22, bold: Bool = false) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.frame = NSRect(x: 24, y: y, width: 502, height: height)
            f.font = bold ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 12)
            view.addSubview(f); return f
        }
        _ = label("国内 IPv4 直连 · 其余通过 Tailscale", 443, bold: true)
        _ = label("适用于 Mac 与以 Mac 为网关的局域网设备。默认中国大陆 IP 网段已内置；按 IP 判断，不保证所有国内域名都使用国内线路。", 395, height: 42)
        _ = label("家庭主路由网关", 366, bold: true)
        let gateway = NSTextField(string: state.gateway)
        gateway.frame = NSRect(x: 24, y: 332, width: 502, height: 26)
        gateway.placeholderString = "192.168.2.1"
        view.addSubview(gateway); gatewayField = gateway
        _ = label("额外直连 IPv4 网段（每行一条 CIDR）", 299, bold: true)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 159, width: 502, height: 133))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 488, height: 130))
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = state.extraDirect.joined(separator: "\n")
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.autoresizingMask = [.width]
        scroll.documentView = editor; view.addSubview(scroll); directEditor = editor
        _ = label("例：223.5.5.5/32。仅接受有效公网范围；保存时后台会校验。空白表示仅使用内置网段。", 122, height: 32)
        let login = NSButton(checkboxWithTitle: "登录时启动菜单栏应用", target: self, action: #selector(toggleLogin(_:)))
        login.frame = NSRect(x: 24, y: 89, width: 350, height: 24)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        view.addSubview(login); launchCheckbox = login
        operationLabel = label("修改配置会请求管理员认证；退出应用不会关闭后台转发。", 49, height: 30)
        operationLabel?.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存并应用", target: self, action: #selector(saveSettings))
        save.frame = NSRect(x: 403, y: 10, width: 126, height: 32)
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        view.addSubview(save); saveButton = save
        settings = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func validIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part).map { (0...255).contains($0) } == true
        }
    }

    @objc private func saveSettings() {
        let gateway = gatewayField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard validIPv4(gateway) else { alert("网关格式不正确", "请输入家庭主路由的 IPv4 地址，例如 192.168.2.1。"); return }
        let rows = (directEditor?.string ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard rows.count <= 256 else { alert("规则过多", "额外直连规则最多 256 条。"); return }
        for row in rows {
            let parts = row.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, validIPv4(String(parts[0])), let length = Int(parts[1]), (1...32).contains(length) else {
                alert("网段格式不正确", "请使用 IPv4/CIDR 格式，例如 223.5.5.5/32。\n错误内容：\(row)"); return
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["gateway": gateway, "extra_direct": rows])
            runController(["set-config", data.base64EncodedString()], title: "正在保存配置并应用规则…")
        } catch { alert("无法保存配置", error.localizedDescription) }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                operationLabel?.stringValue = "请在系统设置中允许该登录项。"
            }
        } catch { alert("无法修改登录启动", error.localizedDescription) }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func alert(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "好"); alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    let data = "{\"status\":\"正常\",\"mode\":\"split\",\"interface\":\"utun7\",\"lan_ip\":\"192.168.2.123\",\"gateway\":\"192.168.2.1\",\"route_count\":123,\"extra_direct\":[\"223.5.5.5/32\"],\"updated_at\":\"2026-10-30T03:25:00+00:00\"}".data(using: .utf8)!
    let parsed = GatewayState(data: data)
    precondition(parsed.present && parsed.mode == "split" && parsed.interface == "utun7" && parsed.routeCount == 123)
    precondition(parsed.extraDirect == ["223.5.5.5/32"] && parsed.updatedAt != nil)
    precondition(!GatewayState(data: Data("invalid".utf8)).present)
    precondition(shellQuote("a'b") == "'a'\\''b'")
    precondition(appleQuote("a\"b\\c") == "\"a\\\"b\\\\c\"")
    print("状态 JSON、缺失状态、命令转义检查通过。")
    exit(0)
}

if CommandLine.arguments.contains("--login-status") {
    print("loginStatus=\(SMAppService.mainApp.status.rawValue) bundle=\(Bundle.main.bundleURL.path)")
    exit(0)
}
if CommandLine.arguments.contains("--refresh-existing-login") {
    let service = SMAppService.mainApp
    guard service.status == .enabled else {
        print("未开启登录启动，保持原设置。")
        exit(0)
    }
    do {
        try service.unregister()
        try service.register()
        print("登录项已更新到：\(Bundle.main.bundleURL.path)，状态：\(service.status.rawValue)")
        exit(service.status == .enabled ? 0 : 1)
    } catch {
        fputs("登录项更新失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
