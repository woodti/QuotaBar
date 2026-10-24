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
    func openProviders() {
        do { try LocalStore.prepare(); NSWorkspace.shared.open(LocalStore.providersURL) }
        catch { notice = error.localizedDescription }
    }
    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { notice = "请在系统设置 → 通用 → 登录项中允许 QuotaBar。" }
        } catch { notice = "登录项设置失败：\(error.localizedDescription)" }
    }
}
