import AppKit
import SwiftUI
import ServiceManagement
import QuotaCore

@MainActor final class Store: ObservableObject {
    @Published var snapshots: [QuotaSnapshot] = []
    @Published var codexError: String?
    @Published var localError: String?
    @Published var refreshing = false
    @Published var settings = false
    @Published var dashboard = false
    @Published var notice: String?
    @Published var now = Date()
    @Published var history: [QuotaHistorySample] = []
    @Published var interval: Double = UserDefaults.standard.double(forKey: "interval") == 0 ? 60 : UserDefaults.standard.double(forKey: "interval") {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
    }
    @Published var display = UserDefaults.standard.string(forKey: "display") ?? "codex" {
        didSet { UserDefaults.standard.set(display, forKey: "display") }
    }
    @Published var codexPath = UserDefaults.standard.string(forKey: "codexPath") ?? "" {
        didSet { UserDefaults.standard.set(codexPath, forKey: "codexPath") }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            snapshots = [QuotaSnapshot(id: "codex", name: "Codex", windows: [QuotaWindow(id: "5h", label: "5 小时", usedPercent: 28, resetsAt: Date().addingTimeInterval(7920)), QuotaWindow(id: "7d", label: "7 天", usedPercent: 46, resetsAt: Date().addingTimeInterval(280000))]), QuotaSnapshot(id: "claude", name: "Claude", windows: [QuotaWindow(id: "5h", label: "5 小时", usedPercent: 16, resetsAt: Date().addingTimeInterval(12500)), QuotaWindow(id: "7d", label: "7 天", usedPercent: 37, resetsAt: Date().addingTimeInterval(410000))])]
            history = demoHistory()
            return
        }
        history = (try? LocalStore.readHistory()) ?? []
        readLocal(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date(); self.readLocal()
                if self.now.timeIntervalSince(self.lastAttempt) >= self.interval { self.refresh() }
            }
        }
    }
    var menuTitle: String {
        let ids = display == "all" ? ["codex", "claude"] : [display]
        return ids.map { id in
            let value = (id == "codex" && codexError != nil) ? nil : snapshots.first(where: { $0.id == id })?.visibleRemaining(at: now)
            return (id == "codex" ? "CX " : "CL ") + (value.map { "\(Int($0.rounded(.down)))%" } ?? "—")
        }.joined(separator: "  ")
    }
    var claudeBridgeInstalled: Bool {
        let configHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let url = configHome.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = settings["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return command.contains("--claude-statusline")
    }
    func refresh() {
        guard !refreshing, !demo else { return }
        refreshing = true; lastAttempt = Date(); let path = codexPath
        Task {
            let result = await Task.detached { Result { try CodexClient.fetch(path: path) } }.value
            switch result {
            case .success(let snapshot):
                snapshots.removeAll { $0.id == "codex" }; snapshots.insert(snapshot, at: 0); codexError = nil
                record(snapshot)
            case .failure(let error): codexError = error.localizedDescription
            }
            refreshing = false; now = Date(); readLocal()
        }
    }
    func readLocal() {
        guard !demo else { return }
        var local: [QuotaSnapshot] = []; var issues: [String] = []
        if FileManager.default.fileExists(atPath: LocalStore.claudeURL.path) {
            do { var s = try LocalStore.read(LocalStore.claudeURL); s.id = "claude"; s.name = "Claude"; local.append(s) }
            catch { issues.append("Claude 缓存读取失败") }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: LocalStore.providersURL, includingPropertiesForKeys: nil) {
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(20) {
                do {
                    var s = try LocalStore.read(file); s.id = "custom:" + file.lastPathComponent; local.append(s)
                } catch { issues.append("\(file.lastPathComponent)：格式无效") }
            }
        }
        snapshots = snapshots.filter { $0.id == "codex" } + local
        local.forEach { record($0) }
        localError = issues.isEmpty ? nil : issues.joined(separator: "\n")
    }
    private func record(_ snapshot: QuotaSnapshot) {
        let now = Date()
        let fresh = snapshot.windows.filter { window in !history.contains { $0.provider == snapshot.id && $0.windowID == window.id && now.timeIntervalSince($0.date) < 240 } }
        guard !fresh.isEmpty else { return }
        history.append(contentsOf: fresh.map { QuotaHistorySample(date: now, provider: snapshot.id, windowID: $0.id, label: $0.label, remaining: $0.remaining, resetsAt: $0.resetsAt) })
        history = history.filter { $0.date > now.addingTimeInterval(-30 * 86_400) }.suffix(5_000)
        try? LocalStore.writeHistory(history)
    }
    private func demoHistory() -> [QuotaHistorySample] {
        let now = Date(); return stride(from: 6, through: 0, by: -1).flatMap { day in
            [QuotaHistorySample(date: now.addingTimeInterval(Double(-day) * 86_400), provider: "codex", windowID: "7d", label: "7 天", remaining: min(100, 48 + Double(6 - day) * 7), resetsAt: now.addingTimeInterval(280_000))]
        }
    }
    func connectClaude() {
        guard let executable = Bundle.main.executablePath else { return }
        do { notice = try LocalStore.installClaudeBridge(executable: executable) }
        catch { notice = error.localizedDescription }
    }
    func chooseCodex() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = "选择 Codex 可执行文件"
        if panel.runModal() == .OK, let url = panel.url { codexPath = url.path; refresh() }
    }
    func copyDiagnostics() {
        let selectedPath = codexPath.isEmpty ? "自动查找" : URL(fileURLWithPath: codexPath).lastPathComponent
        let detected = CodexClient.executable(override: codexPath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未找到"
        let snapshotSummary = snapshots.map { "\($0.id):\($0.windows.count) 个窗口" }.joined(separator: ", ")
        let text = [
            "QuotaBar 0.2.5",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Codex 路径：\(selectedPath)",
            "检测到 Codex：\(detected)",
            "刷新间隔：\(Int(interval)) 秒",
            "已有数据：\(snapshotSummary.isEmpty ? "无" : snapshotSummary)",
            "错误：\(codexError ?? "无")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "诊断信息已复制。提交问题时请确认其中没有你不想公开的本地路径。"
    }
    func openProviders() {
        do { try LocalStore.prepare(); NSWorkspace.shared.open(LocalStore.providersURL) }
        catch { notice = error.localizedDescription }
    }
    func openLatestRelease() {
        guard let url = URL(string: "https://github.com/woodti/QuotaBar/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }
    func openFeedback() {
        guard let url = URL(string: "https://github.com/woodti/QuotaBar/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }
    func runSelfCheck() {
        let codex = CodexClient.executable(override: codexPath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未找到"
        let codexSnapshot = snapshots.first(where: { $0.id == "codex" })
        let codexAccount = codexError.map { "读取失败：\($0)" } ?? (codexSnapshot?.authStatus == "authorized" ? "已登录并读到额度" : codex == "未找到" ? "尚未检查" : "已找到程序，等待额度")
        var lines = ["连接检查", "Codex 程序：\(codex)", "Codex 账户：\(codexAccount)", "Claude statusLine：\(claudeBridgeInstalled ? "已接入" : "未接入")"]
        if let data = try? Data(contentsOf: LocalStore.claudeURL),
           let snapshot = try? QuotaParser.decodeSnapshot(data), !snapshot.windows.isEmpty {
            lines.append("Claude 额度：已收到 \(snapshot.windows.count) 个窗口")
        } else {
            lines.append("Claude 额度：等待一次 Claude Code 对话")
        }
        lines.append("下一步：Codex 未找到时选择可执行文件；Claude 等待额度时完成一次对话。")
        notice = lines.joined(separator: "\n")
    }
    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { notice = "请在系统设置 → 通用 → 登录项中允许 QuotaBar。" }
        } catch { notice = "登录项设置失败：\(error.localizedDescription)" }
    }
}
