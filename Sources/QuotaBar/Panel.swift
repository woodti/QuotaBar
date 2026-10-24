import SwiftUI
import AppKit
import QuotaCore

struct Panel: View {
    @ObservedObject var store: Store
    private let mint = Color(red: 0.23, green: 0.78, blue: 0.65)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .semibold)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("QuotaBar").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(store.demo ? "界面预览 · 示例数据" : "AI 额度，一眼掌握").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                }.buttonStyle(.plain).disabled(store.refreshing || store.demo).help("刷新 Codex 额度")
                Button { store.dashboard.toggle(); store.settings = false } label: { Image(systemName: store.dashboard ? "xmark" : "chart.xyaxis.line").font(.system(size: 14)) }.buttonStyle(.plain).padding(.leading, 8).help(store.dashboard ? "返回额度" : "使用看板")
                Button { store.settings.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14)) }.buttonStyle(.plain).padding(.leading, 8).help("设置")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text(store.settings ? "偏好设置" : store.dashboard ? "使用看板" : "剩余额度").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !store.settings { Circle().fill(mint).frame(width: 5, height: 5); Text(store.refreshing ? "正在更新" : "自动同步").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    if store.settings { preferences }
                    else if store.dashboard { DashboardView(store: store) }
                    else {
                        if store.snapshots.isEmpty && store.codexError == nil && store.localError == nil {
                            welcomeCard
                        }
                        ForEach(store.snapshots) { snapshot in card(snapshot) }
                        if let error = store.codexError { errorCard(error) }
                        if !store.snapshots.contains(where: { $0.id == "claude" }) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("连接 Claude", systemImage: "sparkle").font(.system(size: 13, weight: .semibold))
                                Text("通过 Claude Code 状态栏同步额度。接入时备份设置，并保留原有状态栏输出。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("接入 Claude Code") { store.connectClaude() }.controlSize(.small)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let error = store.localError { message("本地数据提示", error, icon: "doc.badge.ellipsis") }
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                            Text("Codex 每 \(Int(store.interval)) 秒刷新；Claude 随使用同步。超过 3 分钟的数据标记为旧数据。").fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 2)
                    }
                    if let notice = store.notice {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Button("知道了") { store.notice = nil }.controlSize(.mini)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(16)
            }.frame(maxHeight: 580)
            Divider()
            HStack {
                Label("本地运行 · 无遥测", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 380, height: 680).background(Color(nsColor: .windowBackgroundColor))
    }
    private func card(_ snapshot: QuotaSnapshot) -> some View {
        let stale = snapshot.stale(at: store.now) || (snapshot.id == "codex" && store.codexError != nil)
        let accent = snapshot.id == "claude" ? Color(red: 0.83, green: 0.54, blue: 0.36) : mint
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Text(snapshot.id == "codex" ? ">_" : snapshot.id == "claude" ? "✳" : "◇")
                    .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                    .frame(width: 30, height: 30).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(snapshot.id == "codex" ? "账户额度" : snapshot.id == "claude" ? "Claude Code 同步" : "本地数据源").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(stale ? "旧数据" : "已同步").font(.system(size: 9, weight: .medium)).foregroundStyle(stale ? Color.orange : accent).padding(.horizontal, 7).padding(.vertical, 4).background((stale ? Color.orange : accent).opacity(0.1), in: Capsule())
            }
            if snapshot.id == "codex", snapshot.planType != nil || snapshot.authStatus != nil {
                HStack(spacing: 7) {
                    if let plan = snapshot.planType {
                        Text(planDisplay(plan)).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent).padding(.horizontal, 8).padding(.vertical, 4).background(accent.opacity(0.1), in: Capsule())
                    }
                    if snapshot.authStatus == "authorized" {
                        Label("已授权", systemImage: "checkmark.shield.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            if snapshot.windows.isEmpty {
                Text("暂未收到额度。请在支持额度的 Claude Code 订阅账户中完成一次对话。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows) { window in
                let expired = window.expired(at: store.now)
                let color = stale || expired ? Color.secondary : window.remaining <= 10 ? Color.red : window.remaining <= 25 ? Color.orange : accent
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        Spacer()
                        if expired { Text("待更新").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                        else {
                            Text("\(Int(window.remaining.rounded(.down)))").font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("% 剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(color.opacity(0.12))
                            Capsule().fill(color).frame(width: expired ? 0 : geometry.size.width * window.remaining / 100)
                        }
                    }.frame(height: 5).accessibilityLabel("\(window.label) 剩余 \(Int(window.remaining))%")
                    Text(resetText(window)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(window.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? "未提供重置时间")
                }
            }
            Text("更新于 \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))\(stale ? " · 等待新数据" : "")").font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.05), lineWidth: 1))
    }
    private func resetText(_ window: QuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "服务未提供重置时间" }
        let seconds = reset.timeIntervalSince(store.now)
        guard seconds > 0 else { return "已到重置时间，等待服务确认" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }
    private func planDisplay(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free", "basic": return "基础版"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return raw.uppercased()
        }
    }
    private func message(_ title: String, _ body: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
            Text(body).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("菜单栏显示", selection: $store.display) {
                Text("Codex").tag("codex"); Text("Claude").tag("claude"); Text("两者").tag("all")
            }
            Text("菜单栏显示所有有效窗口中最少的剩余比例。无数据、读取失败或数据过期时显示 —。").font(.system(size: 10)).foregroundStyle(.secondary)
            Picker("Codex 刷新", selection: $store.interval) {
                Text("30 秒").tag(30.0); Text("1 分钟").tag(60.0); Text("2 分钟").tag(120.0)
            }
            Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
            Divider()
            Text("Codex 路径").font(.system(size: 12, weight: .semibold))
            Text(store.codexPath.isEmpty ? "自动查找已安装的 Codex" : store.codexPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
            HStack { Button("选择文件…") { store.chooseCodex() }; Button("恢复自动查找") { store.codexPath = ""; store.refresh() } }.controlSize(.small)
            Divider()
            Text("Claude Code 状态").font(.system(size: 12, weight: .semibold))
            if store.claudeBridgeInstalled {
                Label(store.snapshots.contains(where: { $0.id == "claude" && !$0.windows.isEmpty }) ? "已接入，额度已同步" : "已接入，等待一次 Claude 对话", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 11))
                Text("Claude 只有在首次 API 响应后才会提供额度字段。完成一次对话后，QuotaBar 会自动更新。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("尚未接入", systemImage: "circle").foregroundStyle(.secondary).font(.system(size: 11))
            }
            Button(store.claudeBridgeInstalled ? "重新接入 Claude Code" : "接入 Claude Code") { store.connectClaude() }.controlSize(.small)
            Divider()
            Text("添加其他服务").font(.system(size: 12, weight: .semibold))
            Text("将符合 QuotaBar 格式的 JSON 文件写入数据源文件夹。程序每 2 秒读取一次；适配器负责获取数据并更新 observedAt。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("打开数据源文件夹") { store.openProviders() }.controlSize(.small)
            Button("查看最新版本和更新说明") { store.openLatestRelease() }.controlSize(.small)
            Text("QuotaBar 0.2.4 · MIT 开源许可").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 12))
    }
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("先连接你的额度账户", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
            Text("QuotaBar 会读取本机 Codex 登录状态，不会上传提示词、代码或会话内容。先完成 Codex 登录，再点击刷新即可。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("打开设置") { store.settings = true }.controlSize(.small)
                Button("立即刷新") { store.refresh() }.controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            message("Codex 暂时不可用", error, icon: "exclamationmark.arrow.triangle.2.circlepath")
            HStack(spacing: 8) {
                Button("打开设置") { store.settings = true }.controlSize(.small)
                Button("重试") { store.refresh() }.controlSize(.small)
                Button("复制诊断信息") { store.copyDiagnostics() }.controlSize(.small)
                Button("提交问题") { store.openFeedback() }.controlSize(.small)
            }
        }
    }
}
