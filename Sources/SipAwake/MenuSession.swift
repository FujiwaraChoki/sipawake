import Darwin
import Foundation

struct MenuSession {
    let pid: Int32
    let id: UUID

    private let directory = URL(fileURLWithPath: "/var/db/sipawake-menu", isDirectory: true)
    private var statusFile: URL { directory.appendingPathComponent(id.uuidString) }

    var stopped: Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    func publish(deadline: Date) throws {
        if mkdir(directory.path, 0o755) != 0 && errno != EEXIST {
            throw CLIError("Cannot create the menu status directory.")
        }
        guard safeDirectory else {
            throw CLIError("The menu status directory is not owned by root or has unsafe permissions.")
        }
        try Data(String(deadline.timeIntervalSince1970).utf8).write(to: statusFile, options: .atomic)
        if chmod(statusFile.path, 0o644) != 0 {
            throw CLIError("Cannot publish the menu session status.")
        }
    }

    func clear() {
        guard safeDirectory else { return }
        try? FileManager.default.removeItem(at: statusFile)
    }

    private var safeDirectory: Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 &&
            info.st_mode & S_IFMT == S_IFDIR && info.st_uid == 0 && info.st_mode & 0o022 == 0
    }
}
