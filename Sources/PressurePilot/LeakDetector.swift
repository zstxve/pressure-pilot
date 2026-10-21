enum LeakDetector {
    static let maxSamples = 120  // two hours at one sample per minute
    static let minSamples = 60

    /// Takes one footprint sample per minute. Flags a leak when the memory floor (lowest value,
    /// so spikes and GC sawtooth don't count) rises in every quarter of the window by at least
    /// 500 MB and 30 % overall. Returns the growth per hour, or nil if it looks healthy.
    static func growthPerHour(_ samples: [UInt64]) -> UInt64? {
        guard samples.count >= minSamples else { return nil }
        let quarter = samples.count / 4
        let window = Array(samples.suffix(quarter * 4))
        let floors = (0..<4).map { window[$0 * quarter ..< ($0 + 1) * quarter].min()! }
        guard zip(floors, floors.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }

        let growth = floors[3] - floors[0]
        guard growth >= 500 << 20, growth * 10 >= floors[0] * 3 else { return nil }
        let hours = Double(quarter * 3) / 60  // distance between first and last quarter
        return UInt64(Double(growth) / hours)
    }
}
