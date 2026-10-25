import SwiftUI
import Charts
import QuotaCore

struct DashboardView: View {
    @ObservedObject var store: Store
    private let mint = Color(red: 0.23, green: 0.78, blue: 0.65)
    private let orange = Color(red: 0.94, green: 0.55, blue: 0.27)
    private var codex: QuotaSnapshot? { store.snapshots.first(where: { $0.id == "codex" }) }
    private var points: [QuotaHistorySample] { store.history.filter { $0.provider == "codex" }.sorted { $0.date < $1.date } }
    private var windowIDs: [String] { Array(Set(points.map(\.windowID))).sorted() }
    private var latestByWindow: [String: QuotaHistorySample] {
        Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id in points.last(where: { $0.windowID == id }).map { (id, $0) } })
    }
    private var burn: (amount: Double, days: Double) {
        guard let first = points.first, let last = points.last, last.date > first.date else { return (0, 0) }
        return (max(0, first.remaining - last.remaining), last.date.timeIntervalSince(first.date) / 86_400)
    }
    private var forecast: String {
        guard burn.amount > 0, burn.days > 0, let value = points.last?.remaining else { return "继续积累数据后，这里会给出节奏建议。" }
        let daily = burn.amount / burn.days
        guard daily > 0 else { return "近期额度使用很平稳。" }
        let days = max(0, (value - 20) / daily)
        return days < 1 ? "当前消耗速度较快，建议减少长上下文任务或切换到更轻量的模型。" : "按近 \(max(1, Int(burn.days.rounded()))) 天的节奏，约 \(Int(days.rounded())) 天后会接近 20% 剩余。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("使用看板").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("本地历史 · 只记录额度快照，不记录提示词和代码").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("近 30 天").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: Capsule())
            }
            if let codex {
                HStack(spacing: 8) {
                    Text(codex.planType.map(planDisplay) ?? "Codex").font(.system(size: 11, weight: .semibold)).foregroundStyle(mint)
                    if codex.authStatus == "authorized" { Label("已授权", systemImage: "checkmark.shield.fill").font(.system(size: 10)).foregroundStyle(.green) }
                    Spacer()
                    Text("数据点 \(points.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 9) {
                metric("当前最低剩余", value: codex?.visibleRemaining(at: store.now).map { "\(Int($0))%" } ?? "—", tint: mint)
                metric("近段消耗", value: burn.amount > 0 ? "\(Int(burn.amount.rounded()))%" : "—", tint: orange)
                metric("观测跨度", value: burn.days > 0 ? "\(max(1, Int(burn.days.rounded()))) 天" : "刚开始", tint: Color.blue)
            }
            panel(title: "剩余趋势") {
                if points.isEmpty { empty("开始使用后，额度趋势会出现在这里。") }
                else {
                    Chart {
                        ForEach(points.suffix(240)) { point in
                            LineMark(x: .value("时间", point.date), y: .value("剩余", point.remaining), series: .value("窗口", point.windowID))
                                .foregroundStyle(by: .value("窗口", point.label))
                                .interpolationMethod(.catmullRom)
                        }
                        RuleMark(y: .value("警戒线", 20)).foregroundStyle(.red.opacity(0.35)).lineStyle(StrokeStyle(dash: [4, 4]))
                    }.chartYScale(domain: 0...100).chartYAxis { AxisMarks(position: .leading) }.chartLegend(position: .bottom, alignment: .leading).frame(height: 155)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                panel(title: "窗口对比") {
                    if latestByWindow.isEmpty { empty("暂无窗口") }
                    else {
                        Chart(Array(latestByWindow.values)) { point in
                            BarMark(x: .value("剩余", point.remaining), y: .value("窗口", point.label)).foregroundStyle(point.remaining <= 20 ? .red : mint).cornerRadius(4)
                        }.chartXScale(domain: 0...100).chartXAxis { AxisMarks(values: [0, 50, 100]) }.chartYAxis { AxisMarks(position: .leading) }.frame(height: CGFloat(max(100, latestByWindow.count * 42)))
                    }
                }
                panel(title: "重置节奏") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(latestByWindow.values)) { point in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.label).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text(resetText(point.resetsAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if latestByWindow.isEmpty { empty("暂无重置时间") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            panel(title: "使用建议") {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text(forecast).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("趋势是根据本机记录的额度快照计算的估算，不是服务方账单；服务返回窗口变化时，历史曲线会保留原始观测。").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
    private func metric(_ title: String, value: String, tint: Color) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(11).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)) }
    private func panel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); content() }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) }
    private func empty(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 55, alignment: .center) }
    private func resetText(_ date: Date?) -> String { guard let date else { return "服务未提供" }; let minutes = Int(ceil(date.timeIntervalSince(store.now) / 60)); if minutes <= 0 { return "等待确认" }; return minutes >= 1440 ? "\(minutes / 1440) 天后" : minutes >= 60 ? "\(minutes / 60) 小时后" : "\(minutes) 分钟后" }
    private func planDisplay(_ raw: String) -> String { switch raw.lowercased() { case "free", "basic": return "基础版"; case "pro": return "Pro"; case "prolite": return "Pro（服务标记：Pro Lite）"; case "plus": return "Plus"; default: return raw.uppercased() } }
}
