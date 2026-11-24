import Foundation
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
