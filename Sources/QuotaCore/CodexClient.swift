import Foundation
import Darwin

/// A short-lived read-only app-server connection. No threads or model requests are created.
public enum CodexClient {
    public static func executable(override: String = "") -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        let candidates = override.isEmpty ? env + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"] : [override]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func fetch(path: String = "", timeout: TimeInterval = 20) throws -> QuotaSnapshot {
        guard let executable = executable(override: path) else { throw QuotaError.message("找不到 Codex。请先安装并登录 Codex CLI，或在设置中选择可执行文件。") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let until = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(id: Int) throws -> Data {
            let fd = output.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if obj["id"] as? Int == id { return line }
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 && errno != EINTR { throw QuotaError.message("Codex 连接中断") }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = read(fd, &bytes, bytes.count)
                    guard count > 0 else { throw QuotaError.message("Codex 已退出，请检查版本和登录状态") }
                    buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count < 2_000_000 else { throw QuotaError.message("Codex 返回的数据过大") }
                }
            }
            throw QuotaError.message("Codex 请求超时。稍后自动重试。")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "quotabar", "title": "QuotaBar", "version": "0.1.0"]]])
        let initialized = try response(id: 1)
        if let root = try JSONSerialization.jsonObject(with: initialized) as? [String: Any], root["error"] != nil { throw QuotaError.message("Codex 初始化失败，请升级 Codex CLI") }
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        return try QuotaParser.codex(response(id: 2))
    }
}
