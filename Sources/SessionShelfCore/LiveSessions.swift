import Darwin
import Foundation

enum LiveSessions {
    static let reason = "実行中のセッション"

    static func claudeSessionStems(
        home: URL,
        fileManager: FileManager,
        isAlive: (Int32) -> Bool,
        startedAt: (Int32) -> Date?
    ) -> Set<String> {
        let directory = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var stems: Set<String> = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["sessionId"] as? String,
                  !sessionID.isEmpty,
                  let pid = intValue(object["pid"]),
                  isAlive(pid),
                  startMatches(object["procStart"] as? String, pid: pid, startedAt: startedAt)
            else { continue }
            stems.insert(sessionID.lowercased())
        }
        return stems
    }

    static func ompProjectPaths(
        home: URL,
        fileManager: FileManager,
        isAlive: (Int32) -> Bool
    ) -> Set<String> {
        let daemons = home.appendingPathComponent(".omp/run/daemons", isDirectory: true)
        guard let daemonURLs = try? fileManager.contentsOfDirectory(at: daemons, includingPropertiesForKeys: nil) else {
            return []
        }
        var projects: Set<String> = []
        for daemon in daemonURLs {
            let clients = daemon.appendingPathComponent("clients", isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(at: clients, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = intValue(object["pid"]),
                      isAlive(pid),
                      let project = object["projectDir"] as? String,
                      !project.isEmpty
                else { continue }
                projects.insert(canonicalPath(project))
            }
        }
        return projects
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    static func startedAt(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    private static func intValue(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber { return number.int32Value }
        if let int = value as? Int { return Int32(int) }
        return nil
    }

    private static func startMatches(_ procStart: String?, pid: Int32, startedAt: (Int32) -> Date?) -> Bool {
        guard let procStart, !procStart.isEmpty else { return true }
        guard let expected = parseProcStart(procStart), let actual = startedAt(pid) else { return true }
        return abs(actual.timeIntervalSince(expected)) <= 5
    }

    private static func parseProcStart(_ text: String) -> Date? {
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}
