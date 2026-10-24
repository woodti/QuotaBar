import Foundation

public struct QuotaWindow: Codable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public func expired(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
}
public struct QuotaSnapshot: Codable, Identifiable {
    public var id: String
    public var name: String
    public var observedAt: Date
    public var windows: [QuotaWindow]
    public var planType: String?
    public var authStatus: String?
    public init(id: String, name: String, observedAt: Date = Date(), windows: [QuotaWindow], planType: String? = nil, authStatus: String? = nil) {
        self.id = id; self.name = name; self.observedAt = observedAt; self.windows = windows; self.planType = planType; self.authStatus = authStatus
    }
    public func stale(at now: Date = Date()) -> Bool { now.timeIntervalSince(observedAt) > 180 || observedAt > now.addingTimeInterval(60) }
    public func visibleRemaining(at now: Date = Date()) -> Double? {
        guard !stale(at: now) else { return nil }
        return windows.filter { !$0.expired(at: now) }.map(\.remaining).min()
    }
}
public enum QuotaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
public enum QuotaParser {
    public static func codex(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.message("Codex 返回了无法识别的数据") }
        let result = root["result"] as? [String: Any] ?? root
        if root["error"] != nil { throw QuotaError.message("无法读取 Codex 额度。请确认 Codex 已使用 ChatGPT 账户登录，再重试。") }
        let buckets: [(String, [String: Any])]
        if let all = result["rateLimitsByLimitId"] as? [String: [String: Any]], !all.isEmpty {
            buckets = all.sorted { a, b in a.key == "codex" ? b.key != "codex" : b.key == "codex" ? false : a.key < b.key }
        } else if let legacy = result["rateLimits"] as? [String: Any] { buckets = [("codex", legacy)] }
        else { throw QuotaError.message("当前账户未返回额度。API Key 账户不一定提供订阅剩余额度。") }
        var windows = [QuotaWindow]()
        for (key, bucket) in buckets {
            for slot in ["primary", "secondary"] {
                guard let w = bucket[slot] as? [String: Any], let used = number(w["usedPercent"]) else { continue }
                let minutes = number(w["windowDurationMins"])
                let duration: String
                if let m = minutes, m > 0 {
                    duration = m >= 1440 && m.truncatingRemainder(dividingBy: 1440) == 0 ? "\(Int(m / 1440)) 天" : m >= 60 && m.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(m / 60)) 小时" : "\(Int(m)) 分钟"
                } else { duration = slot == "primary" ? "主要额度" : "次要额度" }
                let prefix = buckets.count > 1 ? "\((bucket["limitName"] as? String) ?? key) · " : ""
                windows.append(QuotaWindow(id: "\(key).\(slot)", label: prefix + duration, usedPercent: used, resetsAt: number(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) }))
            }
        }
        guard !windows.isEmpty else { throw QuotaError.message("当前账户没有可显示的百分比额度窗口") }
        let planType = (result["rateLimits"] as? [String: Any])?["planType"] as? String
            ?? buckets.compactMap { $0.1["planType"] as? String }.first
            ?? (result["planType"] as? String)
        return QuotaSnapshot(id: "codex", name: "Codex", observedAt: now, windows: windows, planType: planType, authStatus: "authorized")
    }
    public static func claude(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.message("Claude 数据格式无效") }
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        let windows = [("five_hour", "5 小时"), ("seven_day", "7 天"), ("spend_limit", "支出上限")].compactMap { key, label -> QuotaWindow? in
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percentage"]) else { return nil }
            return QuotaWindow(id: key, label: label, usedPercent: used, resetsAt: number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) })
        }
        return QuotaSnapshot(id: "claude", name: "Claude", observedAt: now, windows: windows, authStatus: "local-sync")
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    public static func decodeSnapshot(_ data: Data) throws -> QuotaSnapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(QuotaSnapshot.self, from: data)
        guard !value.id.isEmpty, !value.name.isEmpty, value.windows.count <= 20,
              Set(value.windows.map(\.id)).count == value.windows.count,
              value.windows.allSatisfy({ $0.usedPercent.isFinite && !$0.id.isEmpty }) else { throw QuotaError.message("额度文件内容无效") }
        return value
    }
    public static func encode(_ snapshot: QuotaSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}
import CoreFoundation
