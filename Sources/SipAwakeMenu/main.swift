import AppKit
import Foundation

private final class MenuController: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var runner: Process?
    private var stopPipe: FileHandle?
    private var sessionID: UUID?
    private var timer: Timer?
    private var stopping = false
    private var quitting = false
    private var lastMessage = "Ready"
    private var deadline: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.menu = menu
        menu.autoenablesItems = false
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func add(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
        return entry
    }

    private func refresh() {
        var title = lastMessage
        var symbol = "cup.and.saucer"
        let active = runner != nil
        if active {
            if stopping {
                title = "Restoring settings…"
            } else if let sessionID {
                let path = "/var/db/sipawake-menu/\(sessionID.uuidString)"
                if let raw = try? String(contentsOfFile: path, encoding: .utf8), let time = Double(raw), time.isFinite {
                    deadline = Date(timeIntervalSince1970: time)
                    let seconds = Int(min(86_400, max(0, ceil(time - Date().timeIntervalSince1970))))
                    title = String(format: "Awake · %d:%02d remaining", seconds / 60, seconds % 60)
                    symbol = "cup.and.saucer.fill"
                } else {
                    title = deadline == nil ? "Waiting for authorization or setup…" : "Restoring settings…"
                }
            } else {
                title = "Restoring settings…"
            }
        }

        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SipAwake")
        item.button?.toolTip = "SipAwake · \(title)"
        // Keep the menu stable while it is tracking the pointer.
        if menu.items.isEmpty || menu.items.first?.representedObject as? String != menuMode {
            configureMenu(title: title)
        } else {
            menu.items.first?.title = title
        }
    }

    private var menuMode: String { runner == nil ? "idle" : stopping ? "stopping" : sessionID == nil ? "restore" : "session" }

    private func configureMenu(title: String) {
        menu.removeAllItems()
        add(title, enabled: false).representedObject = menuMode
        menu.addItem(.separator())
        if runner == nil {
            for (label, duration) in [("30 minutes", "30m"), ("1 hour", "1h"), ("2 hours", "2h"), ("4 hours", "4h")] {
                add("Stay Awake for \(label)", action: #selector(start(_:))).representedObject = duration
            }
            menu.addItem(.separator())
            _ = add("Restore Saved Settings…", action: #selector(restore))
        } else if sessionID != nil {
            _ = add("End Session", action: #selector(stop), enabled: !stopping)
        }
        _ = add("Quit SipAwake", action: #selector(quit))
    }

    @objc private func start(_ sender: NSMenuItem) {
        guard runner == nil, let duration = sender.representedObject as? String else { return }
        let pipe = Pipe()
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/cat")
        sentinel.standardInput = pipe
        sentinel.standardOutput = FileHandle.nullDevice
        sentinel.standardError = FileHandle.nullDevice
        do {
            try sentinel.run()
            let id = UUID()
            sessionID = id
            stopPipe = pipe.fileHandleForWriting
            try runElevated(["--for", duration, "--menu-session", String(sentinel.processIdentifier), id.uuidString])
        } catch {
            closeStopPipe()
            sessionID = nil
            show(error.localizedDescription)
        }
    }

    @objc private func restore() {
        guard runner == nil else { return }
        do { try runElevated(["restore"]) }
        catch { show(error.localizedDescription) }
    }

    @objc private func stop() {
        guard sessionID != nil, !stopping else { return }
        stopping = true
        closeStopPipe()
        refresh()
    }

    private func closeStopPipe() {
        try? stopPipe?.close()
        stopPipe = nil
    }

    @objc private func quit() {
        if runner == nil {
            NSApp.terminate(nil)
        } else {
            quitting = true
            stop()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runner != nil else { return .terminateNow }
        // Closing the pipe also stops an elevated session after an unexpected app exit.
        closeStopPipe()
        return .terminateNow
    }

    private func runElevated(_ arguments: [String]) throws {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sipawake").path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            throw NSError(domain: "SipAwake", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled sipawake CLI is missing. Reinstall SipAwake from the disk image."])
        }

        let script = """
        on run argv
            set commandLine to "exec"
            repeat with argument in argv
                set commandLine to commandLine & " " & quoted form of (contents of argument)
            end repeat
            with timeout of 86520 seconds
                do shell script commandLine with administrator privileges
            end timeout
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", cli] + arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { self?.finished(status: process.terminationStatus, result: result) }
        }
        try process.run()
        runner = process
        refresh()
    }

    private func finished(status: Int32, result: String) {
        closeStopPipe()
        runner = nil
        sessionID = nil
        stopping = false
        deadline = nil
        if status == 0 {
            lastMessage = result.contains("Battery reached") ? "Ended at battery cutoff" : "Settings cleanup complete"
        } else if result.contains("(-128)") {
            lastMessage = "Authorization cancelled"
        } else {
            lastMessage = "Session could not complete"
            show(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        refresh()
        if quitting { NSApp.terminate(nil) }
    }

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SipAwake"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
private let controller = MenuController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
