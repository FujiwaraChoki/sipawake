import Darwin
import Foundation
import XCTest
@testable import SipAwake

final class SessionTests: XCTestCase {
    func testDurationAndBatteryCutoff() throws {
        XCTAssertEqual(try parseDuration("2h"), 7_200)
        XCTAssertThrowsError(try parseDuration("25h"))
        XCTAssertThrowsError(try parseDuration("0m"))
        XCTAssertThrowsError(try parseDuration("9999999999999999999999999999999s"))
        let onBattery = try Battery(output: "Now drawing from 'Battery Power'\n -InternalBattery-0 15%; discharging")
        let onCharger = try Battery(output: "Now drawing from 'AC Power'\n -InternalBattery-0 15%; charging")
        XCTAssertTrue(onBattery.reached(15))
        XCTAssertFalse(onCharger.reached(15))
        XCTAssertThrowsError(try Battery(output: "Now drawing from 'Battery Power'"))
    }

    func testOnlyPresentProfileSettingsAndShorterDisplayTimer() {
        let plan = PowerProfiles(output: """
        Battery Power:
             lowpowermode 0
             displaysleep 1
             powernap 1
             lessbright 0
        AC Power:
             lowpowermode 1
             powernap 1
        """)
        XCTAssertEqual(plan.savings(extras: true).filter(\.needed).map(\.setting), [
            .power(.battery, "lowpowermode"),
            .power(.battery, "lessbright"),
            .power(.battery, "powernap")
        ])
        XCTAssertEqual(plan.savings(extras: false).map(\.setting), [
            .power(.battery, "lowpowermode"),
            .power(.charger, "lowpowermode")
        ])
    }

    func testReadsGlobalSleepOverrideWhenPresentAndAbsent() throws {
        XCTAssertEqual(try sleepOverride(from: "System-wide power settings:\n SleepDisabled 1\nCurrently in use:\n sleep 0"), 1)
        XCTAssertEqual(try sleepOverride(from: "Currently in use:\n sleep 0"), 0)
        XCTAssertThrowsError(try sleepOverride(from: ""))
    }

    func testRestoresSleepLastAndPreservesManualChanges() throws {
        try withSession { session, settings in
            let dim = Setting.brightness(UUID())
            let powerMode = Setting.power(.battery, "lowpowermode")
            settings.values = [(dim, 0.8), (powerMode, 0), (.sleepOverride, 0)]
            let plan = [
                Change(setting: dim, original: 0.8, target: 0.25),
                Change(setting: powerMode, original: 0, target: 1),
                Change(setting: .sleepOverride, original: 0, target: 1)
            ]

            var pending: [Change] = []
            for change in plan { try session.apply(change, changes: &pending) }
            XCTAssertEqual(try session.journal.load(), plan)
            try settings.write(dim, value: 0.45)
            settings.writes.removeAll()
            XCTAssertEqual(session.restore(&pending), [])
            XCTAssertEqual(settings.writes, [powerMode, .sleepOverride])
            XCTAssertEqual(try settings.read(dim), 0.45)
            XCTAssertEqual(try session.journal.load(), [])
        }
    }

    func testRecoveryRestoresAnOverrideEvenWhenAnEarlierWriteReportedFailure() throws {
        try withSession { session, settings in
            settings.values = [(.sleepOverride, 0)]
            settings.failAfterWrite = true
            var pending: [Change] = []
            XCTAssertThrowsError(try session.apply(
                Change(setting: .sleepOverride, original: 0, target: 1), changes: &pending
            ))
            XCTAssertEqual(try settings.read(.sleepOverride), 1)
            pending = try session.journal.load()
            XCTAssertEqual(pending.count, 1)
            settings.failAfterWrite = false
            XCTAssertEqual(session.restore(&pending), [])
            XCTAssertEqual(try settings.read(.sleepOverride), 0)
            XCTAssertEqual(try session.journal.load(), [])
        }
    }

    func testUnavailableDisplayDoesNotBlockRestoringSleep() throws {
        try withSession { session, settings in
            let dim = Setting.brightness(UUID())
            let brightness = Change(setting: dim, original: 0.8, target: 0.25)
            let lid = Change(setting: .sleepOverride, original: 0, target: 1)
            var pending = [brightness, lid]
            try session.journal.save(pending)
            settings.values = [(.sleepOverride, 1)]
            XCTAssertEqual(session.restore(&pending).count, 1)
            XCTAssertEqual(try settings.read(.sleepOverride), 0)
            XCTAssertEqual(try session.journal.load(), [brightness])
            settings.values.append((dim, 0.25))
            XCTAssertEqual(session.restore(&pending), [])
            XCTAssertEqual(try settings.read(dim), 0.8)
        }
    }

    func testExistingSleepOverrideIsPreservedAndSessionIsExclusive() throws {
        try withSession { session, settings in
            settings.values = [(.sleepOverride, 1)]
            var pending: [Change] = []
            try session.apply(Change(setting: .sleepOverride, original: 1, target: 1), changes: &pending)
            XCTAssertTrue(settings.writes.isEmpty)
            XCTAssertThrowsError(try session.journal.withLock {})
        }
    }

    func testStopSignalWakesTheSession() throws {
        let signals = StopSignals()
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        signals.wait(for: .seconds(2))
        XCTAssertEqual(signals.first, SIGTERM)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { signal(number, SIG_DFL) }
    }

    func testClosingMenuPipeEndsSessionOwner() throws {
        let pipe = Pipe()
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/cat")
        sentinel.standardInput = pipe
        sentinel.standardOutput = FileHandle.nullDevice
        try sentinel.run()
        let session = MenuSession(pid: sentinel.processIdentifier, id: UUID())
        XCTAssertFalse(session.stopped)
        try pipe.fileHandleForWriting.close()
        sentinel.waitUntilExit()
        XCTAssertTrue(session.stopped)
    }

    private func withSession(_ body: (Session, MockSettings) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = Journal(directory: folder)
        let settings = MockSettings()
        try journal.withLock {
            try body(Session(settings: settings, journal: journal, report: { _ in }), settings)
        }
    }
}

private final class MockSettings: Settings {
    var values: [(Setting, Double)] = []
    var writes: [Setting] = []
    var failAfterWrite = false

    func read(_ setting: Setting) throws -> Double {
        guard let row = values.first(where: { $0.0 == setting }) else { throw CLIError("Unavailable") }
        return row.1
    }

    func write(_ setting: Setting, value: Double) throws {
        writes.append(setting)
        values.removeAll { $0.0 == setting }
        values.append((setting, value))
        if failAfterWrite { throw CLIError("Failed after write") }
    }
}
