import Foundation
import SQLite3
import XCTest
@testable import PacerCore

final class SupervisorHarnessesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    func testCursorDoesNotKeepQuietTurnRunningOrInventAnOutcome() {
        let start = #"{"role":"user"}"#
        func activity(_ lines: [String], at date: Date) -> SessionActivity? {
            SupervisorLocalEvidence.cursorTurn(Data(lines.joined(separator: "\n").utf8),
                session: "fixture", identity: "file", offset: 0, modified: date, now: now)
        }
        XCTAssertEqual(activity([start], at: now)?.phase, .running)
        XCTAssertNil(activity([start], at: now.addingTimeInterval(-91)))
        XCTAssertEqual(activity([start, #"{"type":"turn_ended","status":"success"}"#], at: now)?.phase, .completed)
        XCTAssertNil(activity([start, #"{"type":"turn_ended","status":"unrecognized"}"#], at: now))
    }

    func testAntigravityDistinguishesQuietDataFromAMissingOrBrokenSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = TestFileSystem()
        XCTAssertEqual(AntigravityEvidence.read(root: root, files: files, now: now).status, .missing)

        let folder = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent(UUID().uuidString + ".db")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-901)], ofItemAtPath: file.path)
        let quiet = AntigravityEvidence.read(root: root, files: files, now: now)
        XCTAssertEqual(quiet.status, .idle)
        XCTAssertFalse(ModuleMonitoring.harness(quiet.status, detected: true, sessions: 0).needsUser)

        try "not SQLite".write(to: root.appendingPathComponent("conversation_summaries.db"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AntigravityEvidence.read(root: root, files: files, now: now).status, .unavailable)
    }

    func testAntigravityUsesExplicitFreshRunningStatesFromTheSummaryStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let database = root.appendingPathComponent("conversation_summaries.db")
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)

        let formatter = ISO8601DateFormatter()
        func stamp(_ secondsAgo: TimeInterval) -> String {
            formatter.string(from: now.addingTimeInterval(-secondsAgo))
                .replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: ".000000+00:00")
        }
        let active = UUID().uuidString.lowercased()
        let sql = """
        CREATE TABLE conversation_summaries (conversation_id TEXT, last_modified_time TEXT, status TEXT, killed INTEGER);
        INSERT INTO conversation_summaries VALUES
          ('\(active)', '\(stamp(10))', 'CASCADE_RUN_STATUS_RUNNING', 0),
          ('\(UUID().uuidString)', '\(stamp(901))', 'CASCADE_RUN_STATUS_BUSY', 0),
          ('\(UUID().uuidString)', '\(stamp(20))', 'CASCADE_RUN_STATUS_RUNNING', 1),
          ('\(UUID().uuidString)', '\(stamp(15))', 'CASCADE_RUN_STATUS_IDLE', 0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let listening = AntigravityEvidence.read(root: root, files: TestFileSystem(), now: now)
        XCTAssertEqual(listening.status, .ready)
        XCTAssertEqual(listening.activities.map(\.threadID), [active])
        XCTAssertEqual(listening.activities.first?.phase, .running)

        XCTAssertEqual(sqlite3_exec(db, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        db = nil

        let checkpoint = root.appendingPathComponent("checkpoint")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        let snapshot = checkpoint.appendingPathComponent(database.lastPathComponent)
        try FileManager.default.copyItem(at: database, to: snapshot)
        let idle = AntigravityEvidence.read(root: checkpoint, files: TestFileSystem(), now: now)
        XCTAssertEqual(idle.status, .idle)
        XCTAssertTrue(idle.activities.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
    }

    func testMuseFixturePercentagesUseNormalQuotaWindows() throws {
        let reading = try XCTUnwrap(MuseQuotaReader.parse("""
        Muse Code
        Five-hour window: 8% used (resets 2026-12-01T15:00:00Z)
        Weekly usage: 72% remaining
        """, at: now))
        XCTAssertEqual(QuotaDashboardPresentation.window(provider: .muse, snapshot: reading, period: .fiveHour)?.remainingPercent, 92)
        XCTAssertEqual(QuotaDashboardPresentation.window(provider: .muse, snapshot: reading, period: .weekly)?.remainingPercent, 72)
        XCTAssertNotNil(reading.windows.first?.resetsAt)
        XCTAssertNil(MuseQuotaReader.parse("Weekly: 150% used", at: now))
    }

    func testNewQuotaPropagatesOnAnExistingSourceAndKeepsItsOriginalTimestamp() throws {
        var sources = HarnessActivitySources()
        let folder = FileManager.default.temporaryDirectory
        sources.bind(.muse, home: folder, generation: 1)
        _ = sources.receive(.muse, snapshot: .init(status: .unavailable))
        let data = Data(#"{"observedAt":"2026-11-01T00:00:00Z","fiveHour":{"remainingPercent":38}}"#.utf8)
        let quota = try XCTUnwrap(MuseQuotaReader.manual(data, at: now))
        var observation = HarnessActivity(status: .ready)
        observation.quota = quota
        observation.quotaSource = .manual
        XCTAssertEqual(sources.receive(.muse, snapshot: observation)?.activity.quota, quota)
        XCTAssertEqual(sources[.muse]?.quotaSource, .manual)
        XCTAssertTrue(quota.isStale(at: now))
    }
}
