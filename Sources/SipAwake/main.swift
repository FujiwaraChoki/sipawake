import Darwin
import Foundation

let usage = """
SipAwake — keep your Mac awake with the lid closed for a timed session.

Usage
  sudo sipawake --for <duration> [--brightness <percent> | --no-dim]
                [--min-battery <percent>] [--no-extras]
  sipawake --for <duration> --dry-run [options]
  sudo sipawake restore

Duration accepts seconds, minutes or hours, such as 30s, 45m or 2h (up to 24h).
Defaults: cap built-in brightness at 25%, stop at 15% while on battery,
enable Low Power Mode, and apply supported battery-only savings.
Press Ctrl-C to end the session early.
"""

struct Options {
    var seconds: Int?
    var brightness: Int? = 25
    var cutoff = 15
    var extras = true
    var dryRun = false

    init(_ arguments: [String]) throws {
        var args = arguments[...]
        var seen: Set<String> = []
        while let flag = args.popFirst() {
            guard seen.insert(flag).inserted else { throw CLIError("Duplicate option \(flag).") }
            switch flag {
            case "--for":
                guard let duration = args.popFirst() else { throw CLIError("Provide a duration after --for.") }
                seconds = try parseDuration(duration)
            case "--brightness":
                brightness = try percentage(args.popFirst(), for: flag)
            case "--no-dim":
                brightness = nil
            case "--min-battery":
                cutoff = try percentage(args.popFirst(), for: flag)
            case "--no-extras":
                extras = false
            case "--dry-run":
                dryRun = true
            default:
                throw CLIError("Unknown option \(flag). Run sipawake --help for usage.")
            }
        }
        guard seconds != nil else { throw CLIError("Provide a duration with --for, for example --for 45m.") }
        guard !seen.contains("--brightness") || !seen.contains("--no-dim") else {
            throw CLIError("Choose either --brightness or --no-dim.")
        }
    }

    private func percentage(_ text: String?, for option: String) throws -> Int {
        guard let text, let value = Int(text), (1...100).contains(value) else {
            throw CLIError("\(option) requires an integer from 1 to 100.")
        }
        return value
    }
}

func parseDuration(_ text: String) throws -> Int {
    let units: [Character: Int] = ["s": 1, "m": 60, "h": 3_600]
    guard let suffix = text.last, let multiplier = units[suffix],
          let count = Int(text.dropLast()), (1...(86_400 / multiplier)).contains(count) else {
        throw CLIError("Duration must be between 1s and 24h. Use a whole number followed by s, m or h.")
    }
    return count * multiplier
}

func status(_ text: String) {
    print(text)
    fflush(stdout)
}

func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func plan(_ options: Options, on power: MacPower) throws -> [Change] {
    let profiles = try PowerProfiles(output: power.pmset(["-g", "custom"]))
    guard !profiles.values.isEmpty else { throw CLIError("Cannot read the Mac’s power profiles.") }
    var changes = profiles.savings(extras: options.extras)
    if !changes.contains(where: {
        if case .power(_, "lowpowermode") = $0.setting { return true }
        return false
    }) {
        note("Low Power Mode is unavailable on this Mac.")
    }
    if let cap = options.brightness {
        do {
            if let change = try DisplayBrightness.readChange(cap: cap) {
                changes.insert(change, at: 0)
            } else {
                note("Built-in display brightness is unavailable. Continuing with power settings.")
            }
        } catch {
            note("Skipping display dimming. \(error.localizedDescription)")
        }
    }
    let previous = try power.read(.sleepOverride)
    if previous == 1 {
        note("System sleep is already disabled. SipAwake will preserve that existing setting.")
    }
    changes.append(Change(setting: .sleepOverride, original: previous, target: 1))
    return changes
}

func ensureBattery(_ options: Options, on power: MacPower) throws {
    let battery = try Battery(output: power.pmset(["-g", "batt"]))
    guard !battery.reached(options.cutoff) else {
        throw CLIError("Battery is at \(battery.percent ?? options.cutoff)%. The cutoff is \(options.cutoff)%.")
    }
}

func runSession(_ options: Options, seconds: Int, power: MacPower, session: Session) throws -> Int32 {
    let signals = StopSignals()
    var changes = try session.journal.load()
    if !changes.isEmpty {
        status("Recovering settings from the previous session.")
        try requireRestored(session.restore(&changes))
    }
    try ensureBattery(options, on: power)
    let planned = try plan(options, on: power)
    var failure: Error?
    var reason = "Timer elapsed."

    do {
        for change in planned {
            if signals.first != nil { break }
            try session.apply(change, changes: &changes)
        }
        if signals.first == nil {
            status("SipAwake active for \(seconds)s. You can close the lid. Press Ctrl-C to stop.")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(seconds))
            while signals.first == nil && clock.now < deadline {
                let battery = try Battery(output: power.pmset(["-g", "batt"]))
                if battery.reached(options.cutoff) {
                    reason = "Battery reached the \(options.cutoff)% cutoff."
                    break
                }
                signals.wait(for: min(.seconds(5), clock.now.duration(to: deadline)))
            }
        }
    } catch {
        failure = error
    }

    if signals.first != nil { reason = "Session interrupted." }
    if failure == nil { status(reason) }
    let errors = session.restore(&changes)
    if let failure, !errors.isEmpty { note(failure.localizedDescription) }
    try requireRestored(errors)
    if let failure { throw failure }
    status("Session ended. Settings cleanup complete.")
    return signals.first.map { 128 + $0 } ?? 0
}

func requireRestored(_ errors: [String]) throws {
    guard errors.isEmpty else {
        throw CLIError(
            errors.joined(separator: "\n") +
            "\nSome settings are still saved for recovery. Open the lid and run sudo sipawake restore."
        )
    }
}

func cli(_ args: [String]) throws -> Int32 {
    if args.isEmpty || args == ["--help"] || args == ["-h"] {
        print(usage)
        return 0
    }
    let power = MacPower()
    let journal = Journal(directory: URL(fileURLWithPath: "/var/db/sipawake", isDirectory: true))
    let session = Session(settings: power, journal: journal, report: note)

    if args == ["restore"] {
        guard geteuid() == 0 else { throw CLIError("Run sudo sipawake restore to restore saved settings.") }
        let signals = StopSignals()
        return try withExtendedLifetime(signals) {
            try journal.withLock {
                var changes = try journal.load()
                if changes.isEmpty {
                    status("No SipAwake settings to restore.")
                } else {
                    try requireRestored(session.restore(&changes))
                    status("Settings cleanup complete.")
                }
                return 0
            }
        }
    }

    let options = try Options(args)
    guard let seconds = options.seconds else { throw CLIError("A duration is required.") }
    if options.dryRun {
        let planned = try plan(options, on: power)
        status("Preview for \(seconds)s with a \(options.cutoff)% battery cutoff")
        for change in planned {
            status("  \(change.setting)  \(change.original) → \(change.target)")
        }
        try ensureBattery(options, on: power)
        return 0
    }
    guard geteuid() == 0 else {
        throw CLIError("Run the compiled sipawake executable with sudo to allow closed-lid operation.")
    }
    return try journal.withLock {
        try runSession(options, seconds: seconds, power: power, session: session)
    }
}

do {
    exit(try cli(Array(CommandLine.arguments.dropFirst())))
} catch {
    note("sipawake — \(error.localizedDescription)")
    exit(1)
}
