import Darwin
import Foundation

struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Profile: String, CaseIterable, Codable {
    case battery = "Battery Power"
    case charger = "AC Power"

    var flag: String { self == .battery ? "-b" : "-c" }
}

enum Setting: Codable, Equatable, CustomStringConvertible {
    case sleepOverride
    case power(Profile, String)
    case brightness(UUID)

    var description: String {
        switch self {
        case .sleepOverride: return "system sleep override"
        case let .power(profile, key): return "\(key) (\(profile.rawValue))"
        case .brightness: return "built-in display brightness"
        }
    }

    func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        if case .brightness = self { return abs(lhs - rhs) < 0.015 }
        return lhs == rhs
    }
}

struct Change: Codable, Equatable {
    let setting: Setting
    let original: Double
    let target: Double

    var needed: Bool { !setting.matches(original, target) }
}

protocol Settings {
    func read(_ setting: Setting) throws -> Double
    func write(_ setting: Setting, value: Double) throws
}

struct Session {
    let settings: any Settings
    let journal: Journal
    var report: (String) -> Void

    func apply(_ change: Change, changes: inout [Change]) throws {
        guard change.needed else { return }
        let current = try settings.read(change.setting)
        guard change.setting.matches(current, change.original) else {
            throw CLIError("\(change.setting) changed during setup. Run the session again.")
        }

        // Record the original before the system write, even if that write reports failure.
        try journal.save(changes + [change])
        changes.append(change)
        try settings.write(change.setting, value: change.target)
        guard try change.setting.matches(settings.read(change.setting), change.target) else {
            throw CLIError("macOS did not apply \(change.setting).")
        }
    }

    func restore(_ changes: inout [Change]) -> [String] {
        var errors: [String] = []
        // Re-enabling system sleep can suspend us with the lid closed.
        let reversed = Array(changes.reversed())
        let ordered = reversed.filter { $0.setting != .sleepOverride } +
            reversed.filter { $0.setting == .sleepOverride }
        for change in ordered {
            do {
                let current = try settings.read(change.setting)
                if change.setting.matches(current, change.original) {
                    // The change was never applied, or it was already reverted.
                } else if change.setting.matches(current, change.target) {
                    try settings.write(change.setting, value: change.original)
                    guard try change.setting.matches(settings.read(change.setting), change.original) else {
                        throw CLIError("macOS did not restore the previous value.")
                    }
                } else {
                    report("Keeping the current \(change.setting) because it changed during the session.")
                }

                let remaining = changes.filter { $0.setting != change.setting }
                try journal.save(remaining)
                changes = remaining
            } catch {
                errors.append("\(change.setting) — \(error.localizedDescription)")
            }
        }
        return errors
    }
}

struct Journal {
    let directory: URL
    private var state: URL { directory.appendingPathComponent("session.json") }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw CLIError("Cannot create \(directory.path) — \(String(cString: strerror(errno))).")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw CLIError("Expected a private state directory owned by the session user at \(directory.path).")
        }

        let lock = open(directory.appendingPathComponent("lock").path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CLIError("Cannot open the session lock.") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK {
                throw CLIError("Another SipAwake session is active. Stop it with Ctrl-C in its terminal.")
            }
            throw CLIError("Cannot acquire the session lock.")
        }
        return try operation()
    }

    func load() throws -> [Change] {
        do {
            let data = try Data(contentsOf: state)
            return try JSONDecoder().decode([Change].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    func save(_ changes: [Change]) throws {
        if changes.isEmpty {
            do { try FileManager.default.removeItem(at: state) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        } else {
            try JSONEncoder().encode(changes).write(to: state, options: .atomic)
        }
    }
}

final class StopSignals {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sipawake.signals")
    private var sources: [any DispatchSourceSignal] = []
    private var received: Int32?
    private let wake = DispatchSemaphore(value: 0)

    init() {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.received == nil { self.received = number }
                self.lock.unlock()
                self.wake.signal()
            }
            let ready = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { ready.signal() }
            source.resume()
            ready.wait()
            sources.append(source)
        }
    }

    func wait(for duration: Duration) {
        let remaining = duration.components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        _ = wake.wait(timeout: .now() + max(0, seconds))
    }

    var first: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}
