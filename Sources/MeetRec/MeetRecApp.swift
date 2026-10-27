import SwiftUI
import AppKit
import Combine

/// Native status item avoids MenuBarExtra scene-removal termination on newer
/// macOS (upstream PR #3). Keep bundle identity stable; no TCC-reset workaround.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = RecordingEngine()
    private let hotkeys = HotKeyManager()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscription: AnyCancellable?
    private var terminating = false
    private var relaunchRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.reset()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView(engine: engine))
        hotkeys.register(.optCmdR) { [weak self] in self?.engine.toggle() }
        hotkeys.register(.optCmdM) { [weak self] in self?.engine.micMuted.toggle() }
        hotkeys.register(.optCmdS) { [weak self] in self?.engine.systemMuted.toggle() }
        subscription = engine.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(requestRelaunch),
            name: ScreenRecordingPermission.relaunchNotification, object: nil)
        updateStatus()
        engine.recoverInterruptedRecordings()
        Task { @MainActor in
            await engine.waitForRecovery()
            try? await Task.sleep(for: .seconds(1))
            ScreenRecordingPermission.checkAtLaunch()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if engine.lastError != nil { symbol = "exclamationmark.circle.fill" }
        else if engine.isRecording { symbol = "record.circle.fill" }
        else if engine.isBusy { symbol = "hourglass" }
        else { symbol = "record.circle" }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetRec")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        if engine.isRecording {
            let seconds = Int(engine.elapsed)
            button.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
        } else { button.title = engine.lastError == nil ? "" : " Error" }
        button.toolTip = engine.lastError ?? "MeetRec — \(String(describing: engine.state))"
    }

    @objc private func requestRelaunch() {
        relaunchRequested = true
        NSApp.terminate(nil) // routes through deferred, recording-safe termination
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard engine.isBusy || engine.isRecording else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await engine.stopAsync()
            var shouldQuit = true
            if let error = engine.lastError {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Recording could not be saved completely"
                alert.informativeText = error
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Keep Open")
                shouldQuit = alert.runModal() == .alertFirstButtonReturn
            }
            if !shouldQuit { relaunchRequested = false; terminating = false }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard relaunchRequested else { return }
        // No shell: paths containing quotes, $(), backticks, etc. remain data.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do { try process.run() }
        catch { Log.write("relaunch failed: \(error.localizedDescription)") }
    }
}

@main
struct MeetRecApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
