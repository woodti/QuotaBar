import XCTest
@testable import QuotaCore
final class QuotaCoreTests: XCTestCase {
    func testMultipleBucketsAndLegacyFallback() throws {
        let data = Data(#"{"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1900000000}},"other":{"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}}"#.utf8)
        let s = try QuotaParser.codex(data)
        XCTAssertEqual(s.windows.count, 2); XCTAssertEqual(s.windows[0].remaining, 75)
        XCTAssertTrue(s.windows[1].label.contains("7 天"))
        XCTAssertEqual(s.planType, "pro"); XCTAssertEqual(s.authStatus, "authorized")
        let fallback = try QuotaParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":0}}}"#.utf8))
        XCTAssertEqual(fallback.windows[0].remaining, 100)
    }
    func testUnknownIsNotZeroAndClamp() throws {
        XCTAssertThrowsError(try QuotaParser.codex(Data(#"{"rateLimits":{"primary":{}}}"#.utf8)))
        XCTAssertThrowsError(try QuotaParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":true}}}"#.utf8)))
        XCTAssertEqual(QuotaWindow(id: "a", label: "a", usedPercent: 110).remaining, 0)
        XCTAssertEqual(QuotaWindow(id: "b", label: "b", usedPercent: -10).remaining, 100)
        XCTAssertThrowsError(try QuotaParser.codex(Data(#"{"error":{"message":"secret should never surface"}}"#.utf8)))
    }
    func testClaudeIndependentWindowsAndMissing() throws {
        let s = try QuotaParser.claude(Data(#"{"rate_limits":{"seven_day":{"used_percentage":31.5,"resets_at":1900000000}}}"#.utf8))
        XCTAssertEqual(s.windows.count, 1); XCTAssertEqual(s.windows[0].remaining, 68.5)
        XCTAssertTrue(try QuotaParser.claude(Data("{}".utf8)).windows.isEmpty)
        let encoded = String(decoding: try QuotaParser.encode(s), as: UTF8.self)
        XCTAssertFalse(encoded.contains("session_id"))
    }
    func testClaudeEmptyStatuslineDoesNotEraseCachedQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("claude.json")
        let snapshot = try QuotaParser.claude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":17.5}}}"#.utf8))
        try QuotaParser.encode(snapshot).write(to: original, options: .atomic)
        _ = try LocalStore.writeClaude(Data("{}".utf8), storageURL: original)
        let cached = try QuotaParser.decodeSnapshot(Data(contentsOf: original))
        XCTAssertEqual(cached.windows.first?.remaining, 82.5)
    }
    func testClaudeStatuslineWithoutRateLimitsKeepsCachedQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("claude.json")
        let snapshot = try QuotaParser.claude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#.utf8))
        try QuotaParser.encode(snapshot).write(to: original, options: .atomic)
        _ = try LocalStore.writeClaude(Data(#"{"model":{"id":"claude"}}"#.utf8), storageURL: original)
        let cached = try QuotaParser.decodeSnapshot(Data(contentsOf: original))
        XCTAssertEqual(cached.windows.first?.remaining, 58)
    }
    func testExpiredAndStaleNeverPretendToReset() {
        let now = Date()
        let expired = QuotaWindow(id: "a", label: "a", usedPercent: 80, resetsAt: now.addingTimeInterval(-1))
        var snapshot = QuotaSnapshot(id: "c", name: "c", observedAt: now, windows: [expired])
        XCTAssertNil(snapshot.visibleRemaining(at: now))
        snapshot.windows[0].resetsAt = now.addingTimeInterval(500)
        XCTAssertEqual(snapshot.visibleRemaining(at: now), 20)
        XCTAssertNil(snapshot.visibleRemaining(at: now.addingTimeInterval(181)))
    }
    func testBridgePreservesAndBacksUpConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark","statusLine":{"type":"command","command":"cat | custom-status","padding":2}}"#.utf8)
        try original.write(to: settings)
        _ = try LocalStore.installClaudeBridge(executable: "/Applications/Quota Bar.app/Contents/MacOS/QuotaBar", settingsURL: settings)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        let status = parsed["statusLine"] as! [String: Any]
        XCTAssertEqual(status["padding"] as? Int, 2)
        XCTAssertTrue((status["command"] as! String).contains(Data("cat | custom-status".utf8).base64EncodedString()))
        _ = try LocalStore.installClaudeBridge(executable: "/tmp/another", settingsURL: settings)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: files.first { $0.lastPathComponent.contains("quotabar-backup-") }!), original)
    }
    func testInvalidCustomSnapshot() throws {
        let s = QuotaSnapshot(id: "custom", name: "Test", windows: [QuotaWindow(id: "a", label: "a", usedPercent: 20)])
        XCTAssertEqual(try QuotaParser.decodeSnapshot(QuotaParser.encode(s)).windows, s.windows)
        var duplicate = s; duplicate.windows.append(s.windows[0])
        XCTAssertThrowsError(try QuotaParser.decodeSnapshot(QuotaParser.encode(duplicate)))
    }
    func testRPCHandshakeAndTimeout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        read first
        printf '%s\\n' '{"id":1,"result":{}}'
        read second
        read third
        printf '%s\\n' '{"method":"notification"}' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42}}}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(try CodexClient.fetch(path: executable.path, timeout: 2).windows[0].remaining, 58)
        try "#!/bin/sh\nread first\nread second\n".write(to: executable, atomically: true, encoding: .utf8)
        let start = Date()
        XCTAssertThrowsError(try CodexClient.fetch(path: executable.path, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
