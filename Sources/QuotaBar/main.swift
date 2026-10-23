import AppKit
import SwiftUI
import Combine
import QuotaCore

let args = CommandLine.arguments
if args.contains("--claude-statusline") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let snapshot = try? LocalStore.writeClaude(data)
    if let index = args.firstIndex(of: "--forward"), args.indices.contains(index + 1),
       let bytes = Data(base64Encoded: args[index + 1]), let command = String(data: bytes, encoding: .utf8) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardInput = pipe; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        do { try process.run(); try pipe.fileHandleForWriting.write(contentsOf: data); try pipe.fileHandleForWriting.close(); process.waitUntilExit() } catch { }
    } else if let snapshot, !snapshot.windows.isEmpty {
        print(snapshot.windows.map { "\($0.label): \(Int($0.remaining))% 剩余" }.joined(separator: " · "))
    } else { print("Claude · 等待额度") }
    exit(0)
}
if args.contains("--check-codex") {
    do { let snapshot = try CodexClient.fetch(); print(String(decoding: try QuotaParser.encode(snapshot), as: UTF8.self)); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    var store: Store!
    var subscriptions = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = Store(demo: args.contains("--demo") || args.contains("--render-preview"))
        let panel = Panel(store: store)
        if let index = args.firstIndex(of: "--render-preview"), args.indices.contains(index + 1) {
            let host = NSHostingView(rootView: panel)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 680)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.display(); host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[index + 1]))
                }
                NSApp.terminate(nil)
            }
            return
        }
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.behavior = .transient
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "QuotaBar 剩余额度")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(toggle)
            button.toolTip = "QuotaBar · 各窗口最少剩余额度"
        }
        store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.item.button?.title = self?.store.menuTitle ?? "QuotaBar" }
        }.store(in: &subscriptions)
        item.button?.title = store.menuTitle
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc func wake() { store.refresh() }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { NSApp.activate(ignoringOtherApps: true); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
