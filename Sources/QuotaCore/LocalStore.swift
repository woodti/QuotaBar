import Foundation
public enum LocalStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuotaBar", isDirectory: true)
    }
    public static var claudeURL: URL { directory.appendingPathComponent("claude.json") }
    public static var providersURL: URL { directory.appendingPathComponent("Providers", isDirectory: true) }
    public static var historyURL: URL { directory.appendingPathComponent("history.json") }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: providersURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func readHistory() throws -> [QuotaHistorySample] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let size = try historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw QuotaError.message("历史数据超过 5 MB") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QuotaHistorySample].self, from: Data(contentsOf: historyURL)).suffix(5_000).sorted { $0.date < $1.date }
    }
    public static func writeHistory(_ history: [QuotaHistorySample]) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history.suffix(5_000)).write(to: historyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    public static func read(_ url: URL) throws -> QuotaSnapshot {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_000_000 else { throw QuotaError.message("额度文件超过 1 MB") }
        return try QuotaParser.decodeSnapshot(Data(contentsOf: url))
    }
    public static func writeClaude(_ input: Data) throws -> QuotaSnapshot {
        let snapshot = try QuotaParser.claude(input)
        try prepare()
        try QuotaParser.encode(snapshot).write(to: claudeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeURL.path)
        return snapshot
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// User invokes this from the setup button. Preserve existing status-line output by forwarding original stdin.
    public static func installClaudeBridge(executable: String, settingsURL: URL? = nil) throws -> String {
        let configHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let url = settingsURL ?? configHome.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings: [String: Any] = [:]
        var original: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            original = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: original!) as? [String: Any] else { throw QuotaError.message("Claude 设置格式无效，未修改文件") }
            settings = parsed
        }
        var status = settings["statusLine"] as? [String: Any] ?? [:]
        let oldCommand = status["command"] as? String
        if oldCommand?.contains("--claude-statusline") == true { return "Claude 已接入。开始一次 Claude Code 对话后即可显示额度。" }
        if settings["statusLine"] != nil && status["type"] as? String != "command" { throw QuotaError.message("现有 Claude 状态栏不是命令类型，请手动配置；设置未修改。") }
        var command = shellQuote(executable) + " --claude-statusline"
        if let old = oldCommand, !old.isEmpty { command += " --forward " + shellQuote(Data(old.utf8).base64EncodedString()) }
        status["type"] = "command"; status["command"] = command; settings["statusLine"] = status
        if let original {
            let backup = url.appendingPathExtension("quotabar-backup-\(UUID().uuidString)")
            try original.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return "Claude 已接入，原设置已备份。开始一次 Claude Code 对话后，额度将自动同步。请保持应用的安装位置不变。"
    }
}
