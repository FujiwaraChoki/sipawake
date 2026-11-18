import ColorSync
import CoreGraphics
import Darwin
import Foundation

struct Battery {
    let onBattery: Bool
    let percent: Int?

    init(output: String) throws {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Now drawing from 'Battery Power'") {
            onBattery = true
        } else if text.hasPrefix("Now drawing from 'AC Power'") || text.hasPrefix("Now drawing from 'UPS Power'") {
            onBattery = false
        } else {
            throw CLIError("Cannot determine the current power source.")
        }
        let batteries = text.split(separator: "\n").filter { $0.contains("InternalBattery") }
        let percentages = batteries.compactMap { line -> Int? in
            guard let range = line.range(of: #"[0-9]+%"#, options: .regularExpression),
                  let value = Int(line[range].dropLast()), (0...100).contains(value) else { return nil }
            return value
        }
        percent = percentages.min()
        if onBattery && percent == nil { throw CLIError("Cannot read the battery charge.") }
    }

    func reached(_ cutoff: Int) -> Bool {
        onBattery && percent.map { $0 <= cutoff } == true
    }
}

struct PowerProfiles {
    let values: [Profile: [String: Int]]

    init(output: String) {
        var profile: Profile?
        var values: [Profile: [String: Int]] = [:]
        for line in output.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.hasSuffix(":") {
                profile = Profile(rawValue: String(row.dropLast()))
            } else if let profile {
                let fields = row.split(whereSeparator: \.isWhitespace)
                if fields.count == 2, let value = Int(fields[1]) {
                    values[profile, default: [:]][String(fields[0])] = value
                }
            }
        }
        self.values = values
    }

    func savings(extras: Bool) -> [Change] {
        var changes: [Change] = []
        for profile in Profile.allCases {
            guard let settings = values[profile] else { continue }
            func add(_ key: String, _ target: Int) {
                guard let original = settings[key] else { return }
                changes.append(Change(setting: .power(profile, key), original: Double(original), target: Double(target)))
            }
            add("lowpowermode", 1)
            guard extras, profile == .battery else { continue }
            add("lessbright", 1)
            add("powernap", 0)
            if let idle = settings["displaysleep"], idle == 0 || idle > 2 {
                add("displaysleep", 2)
            }
        }
        return changes
    }
}

func sleepOverride(from output: String) throws -> Double {
    let line = output.split(separator: "\n").first {
        $0.split(whereSeparator: \.isWhitespace).first == "SleepDisabled"
    }
    guard let line else {
        guard output.contains("Currently in use:") else {
            throw CLIError("Cannot read the system sleep override.")
        }
        // pmset omits SleepDisabled when it is off on some macOS versions.
        return 0
    }
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, let value = Double(fields[1]), value == 0 || value == 1 else {
        throw CLIError("Unrecognized SleepDisabled value in pmset output.")
    }
    return value
}

struct MacPower: Settings {
    func pmset(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let details = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("pmset \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)). \(details)")
        }
        return text
    }

    func read(_ setting: Setting) throws -> Double {
        switch setting {
        case .sleepOverride:
            return try sleepOverride(from: pmset(["-g"]))
        case let .power(profile, key):
            let profiles = try PowerProfiles(output: pmset(["-g", "custom"]))
            guard let value = profiles.values[profile]?[key] else {
                throw CLIError("The current value of \(setting) is unavailable.")
            }
            return Double(value)
        case let .brightness(uuid):
            return try DisplayBrightness.value(for: uuid)
        }
    }

    func write(_ setting: Setting, value: Double) throws {
        switch setting {
        case .sleepOverride:
            _ = try pmset(["-a", "disablesleep", String(Int(value))])
        case let .power(profile, key):
            _ = try pmset([profile.flag, key, String(Int(value))])
        case let .brightness(uuid):
            try DisplayBrightness.set(value, for: uuid)
        }
    }
}

enum DisplayBrightness {
    typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL
    )
    private static let getter = framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: Setter.self) }

    private static func builtInDisplay() -> (CGDirectDisplayID, UUID)? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &count) == .success,
              let display = displayIDs.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid),
              let identifier = UUID(uuidString: uuidString as String) else { return nil }
        return (display, identifier)
    }

    static func readChange(cap: Int) throws -> Change? {
        guard getter != nil, setter != nil, let (_, uuid) = builtInDisplay() else { return nil }
        let original = try value(for: uuid)
        return Change(setting: .brightness(uuid), original: original, target: min(original, Double(cap) / 100))
    }

    private static func displayID(for uuid: UUID) -> CGDirectDisplayID? {
        guard let cfUUID = CFUUIDCreateFromString(nil, uuid.uuidString as CFString) else { return nil }
        let display = CGDisplayGetDisplayIDFromUUID(cfUUID)
        if display != kCGNullDirectDisplay, CGDisplayIsBuiltin(display) != 0 { return display }
        if let (online, identifier) = builtInDisplay(), identifier == uuid { return online }
        return nil
    }

    static func value(for uuid: UUID) throws -> Double {
        guard let getter, let display = displayID(for: uuid) else {
            throw CLIError("The built-in display is unavailable. Open the lid and retry restoration.")
        }
        var value: Float = 0
        guard getter(display, &value) == 0, (0...1).contains(value) else {
            throw CLIError("macOS did not return the built-in display brightness.")
        }
        return Double(value)
    }

    static func set(_ value: Double, for uuid: UUID) throws {
        guard let setter, let display = displayID(for: uuid),
              setter(display, Float(value)) == 0 else {
            throw CLIError("macOS could not set the built-in display brightness.")
        }
    }
}
