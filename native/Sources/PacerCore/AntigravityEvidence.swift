import Foundation
import SQLite3

enum AntigravityEvidence {
    private static let activityLifetime: TimeInterval = 15 * 60

    static func read(root: URL, files: any PlatformFileSystem, now: Date) -> HarnessActivity {
        let database = root.appendingPathComponent("conversation_summaries.db")
        let trajectoryDirectory = root.appendingPathComponent("conversations", isDirectory: true)
        let trajectories: [URL]
        let trajectoryFailure: HarnessSourceStatus?
        do {
            trajectories = try files.entries(in: trajectoryDirectory)
            trajectoryFailure = nil
        } catch {
            trajectories = []
            let error = error as NSError
            let missing = error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            trajectoryFailure = missing ? .missing : .unavailable
        }

        var recent: [UUID: Date] = [:]
        for file in trajectories {
            let name = file.lastPathComponent
            let base = name.hasSuffix(".db-wal") ? String(name.dropLast(4)) : name
            guard base.hasSuffix(".db"), let id = UUID(uuidString: String(base.dropLast(3))),
                  let meta = files.metadata(file), meta.isRegularFile, isRecent(meta.modified, at: now) else { continue }
            recent[id] = max(recent[id] ?? .distantPast, meta.modified)
        }

        // Antigravity's desktop versions can have a summaries DB with no
        // trajectory files yet. A quiet readable source is healthy either way.
        guard let metadata = files.metadata(database) else {
            if let trajectoryFailure { return .init(status: trajectoryFailure) }
            return .init(status: recent.isEmpty ? .idle : .ready)
        }
        guard metadata.isRegularFile,
              let activities = readActiveSessions(database, metadata: metadata, files: files, recent: recent, now: now) else {
            return .init(status: recent.isEmpty ? .unavailable : .ready)
        }
        return .init(activities: activities, status: activities.isEmpty && recent.isEmpty ? .idle : .ready)
    }

    private static func isRecent(_ date: Date, at now: Date) -> Bool {
        (-5...activityLifetime).contains(now.timeIntervalSince(date))
    }

    private static func readActiveSessions(_ database: URL, metadata: PlatformFileMetadata,
                                           files: any PlatformFileSystem, recent: [UUID: Date], now: Date) -> [SessionActivity]? {
        func hasJournal() -> Bool {
            ["-wal", "-journal"].contains { suffix in
                files.metadata(URL(fileURLWithPath: database.path + suffix)) != nil
            }
        }
        if !hasJournal() {
            // A closed WAL-mode database may have no sidecars. SQLite's normal
            // read-only open can still try to create them. Read a stable
            // checkpoint without taking that path, and retry normally if a
            // writer started or the file changed during the read.
            let reading = queryActiveSessions(database, immutable: true, recent: recent, now: now)
            if files.metadata(database) == metadata && !hasJournal() { return reading }
        }
        return queryActiveSessions(database, immutable: false, recent: recent, now: now)
    }

    private static func queryActiveSessions(_ database: URL, immutable: Bool, recent: [UUID: Date], now: Date) -> [SessionActivity]? {
        let location = immutable ? database.absoluteString + "?mode=ro&immutable=1" : database.path
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | (immutable ? SQLITE_OPEN_URI : 0)
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(location, &connection, flags, nil) == SQLITE_OK,
              let db = connection else { return nil }
        sqlite3_busy_timeout(db, 50)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK else { return nil }
        // Read only explicit activity and its freshness. Titles, workspace
        // paths, prompts and previews never enter Supervisor.
        let sql = """
        SELECT conversation_id, last_modified_time
        FROM conversation_summaries
        WHERE status IN ('CASCADE_RUN_STATUS_RUNNING', 'CASCADE_RUN_STATUS_BUSY')
          AND COALESCE(killed, 0) = 0
        ORDER BY last_modified_time DESC LIMIT 64
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        var activities: [SessionActivity] = []
        var seen = Set<UUID>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(statement) }
            guard let session = text(statement, column: 0), let id = UUID(uuidString: session) else { continue }
            let timestamp = text(statement, column: 1).flatMap {
                SessionActivity.parseDate($0.replacingOccurrences(of: " ", with: "T"))
            }
            let latest = max(timestamp ?? .distantPast, recent[id] ?? .distantPast)
            guard isRecent(latest, at: now), seen.insert(id).inserted else { continue }
            activities.append(.observedSession(provider: .antigravity, session: id.uuidString.lowercased(),
                                               stage: .working, at: min(latest, now)))
        }
        return result == SQLITE_DONE ? activities : nil
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, sqlite3_column_bytes(statement, column) <= 64,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
