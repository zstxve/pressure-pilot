import XCTest
@testable import PressurePilot

final class StatsTests: XCTestCase {
    func testSummaryCountsTimeActionsAndEpisodes() {
        let summary = StatsSummary([
            StatsEntry(kind: .sample, warnSeconds: 30, criticalSeconds: 10),
            StatsEntry(kind: .sample, warnSeconds: 30, criticalSeconds: 10),
            StatsEntry(kind: .freeze, app: "Discord", footprint: 800 << 20, automatic: true),
            StatsEntry(kind: .quit, app: "Spotify", footprint: 1 << 30, automatic: false),
            StatsEntry(kind: .forceQuit, app: "Spotify", footprint: 1 << 30, automatic: true),
            StatsEntry(kind: .episode, duration: 40, actions: 2),
            StatsEntry(kind: .episode, duration: 60, actions: 1),
            StatsEntry(kind: .episode, duration: 300, actions: 0),
        ])
        XCTAssertEqual(summary.warnSeconds, 60)
        XCTAssertEqual(summary.criticalSeconds, 20)
        XCTAssertEqual(summary.interventions, 2)  // the force quit belongs to the quit before it
        XCTAssertEqual(summary.automatic, 1)
        XCTAssertEqual(summary.freedByQuit, 1 << 30)
        XCTAssertEqual(StatsSummary.average(summary.episodesWithAction), 50)
        XCTAssertEqual(StatsSummary.average(summary.episodesWithoutAction), 300)
    }

    func testLogRoundTripAndPruning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = StatsLog(url: dir.appendingPathComponent("stats.jsonl"))

        let old = StatsEntry(time: Date().addingTimeInterval(-40 * 86400), kind: .sample, warnSeconds: 5)
        let lastMonth = StatsEntry(time: Date().addingTimeInterval(-10 * 86400), kind: .sample, warnSeconds: 7)
        let recent = StatsEntry(kind: .freeze, app: "Discord", footprint: 123, automatic: true)
        [old, lastMonth, recent].forEach(log.append)

        let loaded = log.load(since: Date().addingTimeInterval(-7 * 86400))
        XCTAssertEqual(loaded.map(\.kind), [.freeze])
        XCTAssertEqual(loaded.first?.app, "Discord")

        // The 40-day-old entry is gone from the file, the 10-day-old one is kept.
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}
