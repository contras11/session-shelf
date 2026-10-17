import Darwin
import Foundation

/// SQLiteへの書き込みはせず、検証済みの公式CLIに削除を委譲します。
enum OpenCodeSessionDeletion {
    static func delete(sessionID: String, database: URL, expectedUpdated: Date, executables: [URL], timeout: TimeInterval, validateDatabase: () throws -> Void) throws {
        guard !sessionID.isEmpty, !sessionID.hasPrefix("-") else { throw SessionShelfError.protectedItem("OpenCodeセッションIDが不正です") }
        try validateDatabase()
        let format = try OpenCodeDatabase(database).format
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SessionShelfError.unreadable("OpenCode公式CLIが見つかりません")
        }
        let version = try run(executable, arguments: ["--version"], database: database, timeout: timeout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = version.wholeMatch(of: #/(?:opencode\s+v?)?([0-9]+)\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?/#),
              Int(match.output.1) == format.rawValue else {
            throw SessionShelfError.protectedItem("OpenCode CLIとDBの形式が一致しません。OpenCodeで移行を完了してから再読み込みしてください")
        }
        // バージョン確認中にも元データは変わるため、CLI起動直前に開き直します。
        try validateDatabase()
        let db = try OpenCodeDatabase(database)
        guard db.format == format else { throw SessionShelfError.storageItemChanged }
        let id = OpenCodeDatabase.quoted(sessionID)
        guard let row = try db.rows("SELECT \(db.sessionColumns) FROM \(format.sessionTable) WHERE id=\(id)").first else {
            throw SessionShelfError.unreadable("OpenCodeセッションが見つかりません")
        }
        guard let updated = OpenCodeDatabase.date(row["time_updated"]), abs(updated.timeIntervalSince(expectedUpdated)) < 0.001 else {
            throw SessionShelfError.storageItemChanged
        }
        if let reason = OpenCodeDatabase.protectionReason(row) { throw SessionShelfError.protectedItem(reason) }
        guard try db.rows("SELECT id FROM \(format.sessionTable) WHERE parent_id=\(id) LIMIT 1").isEmpty else {
            throw SessionShelfError.protectedItem("子セッションが残っているため、親を完全に削除できません。再読み込みしてください")
        }
        let arguments = ["session", "delete"] + (format == .v2 ? ["--standalone"] : []) + [sessionID]
        try validateDatabase()
        _ = try run(executable, arguments: arguments, database: database, timeout: timeout)
    }

    private static func run(_ executable: URL, arguments: [String], database: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = database.deletingLastPathComponent().deletingLastPathComponent().path
        environment["OPENCODE_DB"] = database.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }
        for handle in handles {
            let descriptor = handle.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                throw SessionShelfError.unreadable("OpenCode CLIの出力を安全に読み取れません")
            }
        }
        var output = Data(), errors = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        try process.run()
        while process.isRunning {
            drain(stdout.fileHandleForReading, into: &output)
            drain(stderr.fileHandleForReading, into: &errors)
            if ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw SessionShelfError.unreadable("OpenCode CLIが応答しないため削除を中止しました")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drain(stdout.fileHandleForReading, into: &output)
        drain(stderr.fileHandleForReading, into: &errors)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let snippet = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = snippet.isEmpty ? "" : ": \(String(snippet.suffix(180)))"
            throw SessionShelfError.unreadable("OpenCode CLIが削除に失敗しました\(detail)")
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func drain(_ handle: FileHandle, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // 出力し続けるCLIでもタイムアウト判定へ戻り、保持するログ量も制限します。
        for _ in 0..<32 {
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 16_384 { data.removeFirst(data.count - 16_384) }
        }
    }
}
