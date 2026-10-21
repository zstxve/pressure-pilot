import Foundation

struct StatsEntry: Codable, Equatable {
    enum Kind: String, Codable { case sample, freeze, quit, forceQuit, leak, episode }

    var time = Date()
    var kind: Kind
    // sample: one per minute
    var warnSeconds: Int?
    var criticalSeconds: Int?
    var used: UInt64?
    var swap: UInt64?
    // freeze / quit / forceQuit / leak
    var app: String?
    var footprint: UInt64?
    var automatic: Bool?
    // episode: one stretch of critical pressure, written when it ends
    var duration: Int?
    var actions: Int?
}

/// What the last days looked like, and whether stepping in made red phases shorter.
struct StatsSummary {
    var warnSeconds = 0
    var criticalSeconds = 0
    var interventions = 0
    var automatic = 0
    var freedByQuit: UInt64 = 0
    var episodesWithAction: [Int] = []  // durations in seconds
    var episodesWithoutAction: [Int] = []

    init(_ entries: [StatsEntry] = []) {
        for entry in entries { add(entry) }
    }

    mutating func add(_ entry: StatsEntry) {
        switch entry.kind {
        case .sample:
            warnSeconds += entry.warnSeconds ?? 0
            criticalSeconds += entry.criticalSeconds ?? 0
        case .freeze, .quit:
            interventions += 1
            if entry.automatic == true { automatic += 1 }
            if entry.kind == .quit { freedByQuit += entry.footprint ?? 0 }
        case .forceQuit, .leak:
            break  // a force quit follows a quit that was already counted
        case .episode:
            if (entry.actions ?? 0) > 0 {
                episodesWithAction.append(entry.duration ?? 0)
            } else {
                episodesWithoutAction.append(entry.duration ?? 0)
            }
        }
    }

    static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
}

/// Appends entries as JSON Lines, readable with any text editor or `jq`.
final class StatsLog {
    let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PressurePilot/stats.jsonl")) {
        self.url = url
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func append(_ entry: StatsEntry) {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Entries newer than `since`. Entries older than `keep` are dropped from the file on the way.
    func load(since: Date, keep: TimeInterval = 30 * 86400) -> [StatsEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n").compactMap { try? decoder.decode(StatsEntry.self, from: Data($0.utf8)) }
        let cutoff = Date().addingTimeInterval(-keep)
        let kept = all.filter { $0.time > cutoff }
        if kept.count < all.count {
            let lines = kept.compactMap { try? encoder.encode($0) }.map { $0 + Data([0x0A]) }
            try? lines.reduce(Data(), +).write(to: url, options: .atomic)
        }
        return kept.filter { $0.time > since }
    }
}
