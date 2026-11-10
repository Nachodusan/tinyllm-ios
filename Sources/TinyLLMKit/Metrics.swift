import Foundation

/// What one generation cost.
public struct GenerationMetrics: Codable, Sendable {
    /// Time until the first token is available to show the user.
    public let timeToFirstTokenMs: Double
    /// Generation speed, excluding prompt processing.
    public let tokensPerSecond: Double
    /// Prompt processing speed.
    public let promptTokensPerSecond: Double
    public let promptTokens: Int
    public let generatedTokens: Int
    public let wallClockMs: Double
    /// Resident memory at the end of the generation, in megabytes.
    public let memoryFootprintMB: Double
    /// Thermal pressure the OS reported *at the end* of this generation.
    public let thermalState: ThermalState
    /// Seconds since the benchmark started, so a run can be plotted over time.
    public let elapsedSinceStartS: Double
}

/// `ProcessInfo.ThermalState`, made Codable and ordered.
public enum ThermalState: String, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical, unknown

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .unknown: 4
        }
    }

    public static func < (a: ThermalState, b: ThermalState) -> Bool { a.rank < b.rank }
}

public enum Memory {
    /// Resident footprint of this process, in MB.
    ///
    /// `phys_footprint` rather than `resident_size`: it is the number iOS
    /// actually uses when deciding to kill you, which is the only one that
    /// matters on a phone.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}

/// Aggregate of a whole benchmark run.
public struct BenchmarkReport: Codable, Sendable {
    public let device: String
    public let systemVersion: String
    public let model: String
    public let loadSeconds: Double
    public let modelSizeMB: Double
    public let runs: [GenerationMetrics]
    public let startedAt: Date

    /// The number everyone quotes: the first generation on a cold, cool device.
    public var burstTokensPerSecond: Double { runs.first?.tokensPerSecond ?? 0 }

    /// What the device actually sustains, measured over the last third of the
    /// run — after the thermal headroom is gone.
    ///
    /// On a phone this is the honest number, and it is not the one in anyone's
    /// README. A model that generates 40 tok/s for twenty seconds and 22 tok/s
    /// thereafter is a 22 tok/s model for any real use.
    public var sustainedTokensPerSecond: Double {
        guard !runs.isEmpty else { return 0 }
        let tail = runs.suffix(max(1, runs.count / 3))
        return tail.map(\.tokensPerSecond).reduce(0, +) / Double(tail.count)
    }

    /// How much of the burst figure survives. 1.0 means no throttling.
    public var sustainedFraction: Double {
        guard burstTokensPerSecond > 0 else { return 0 }
        return sustainedTokensPerSecond / burstTokensPerSecond
    }

    public var peakMemoryMB: Double { runs.map(\.memoryFootprintMB).max() ?? 0 }

    public var worstThermalState: ThermalState { runs.map(\.thermalState).max() ?? .unknown }

    /// The generation at which thermal pressure first rose above nominal.
    public var throttledAfterRuns: Int? {
        runs.firstIndex { $0.thermalState > .nominal }
    }

    public var throttledAfterSeconds: Double? {
        guard let i = throttledAfterRuns else { return nil }
        return runs[i].elapsedSinceStartS
    }

    // MARK: - Is this report worth anything

    /// Mean throughput over a slice of the run.
    private func mean(_ range: Range<Int>) -> Double {
        let slice = runs[range.clamped(to: 0..<runs.count)]
        guard !slice.isEmpty else { return 0 }
        return slice.map(\.tokensPerSecond).reduce(0, +) / Double(slice.count)
    }

    /// Whether throughput had stopped falling by the time the run ended.
    ///
    /// Compares the last sixth of the run against the sixth before it. A run
    /// that is still declining has not found the device's floor, so
    /// `sustainedTokensPerSecond` is an upper bound on it rather than a
    /// measurement of it.
    public var reachedEquilibrium: Bool {
        guard runs.count >= 6 else { return false }
        let n = max(2, runs.count / 6)
        let before = mean((runs.count - 2 * n)..<(runs.count - n))
        let last = mean((runs.count - n)..<runs.count)
        guard before > 0 else { return false }
        return (before - last) / before < 0.02
    }

    /// Why this report might be lying, in its own words.
    ///
    /// Written after a twelve-run sweep on a phone that throttles hard
    /// reported `retained 86%` and `throttled: never`. Both figures were
    /// arithmetically correct and the conclusion they invited — that this
    /// device holds its throughput — was false. The run had simply ended
    /// before the phone got warm. A report that can be read that way has to
    /// say so itself, because the reader has no way to tell from the numbers.
    public var warnings: [String] {
        var w: [String] = []
        if !reachedEquilibrium {
            w.append("throughput was still falling when the run ended: "
                     + "sustained is an upper bound, not a measurement")
        }
        if worstThermalState == .nominal && !reachedEquilibrium {
            w.append("the run ended before the OS reported any thermal pressure, "
                     + "so \"never throttled\" here means \"not yet\"")
        }
        if runs.count < 30 {
            w.append("\(runs.count) runs is short of a thermal soak; "
                     + "on an iPhone 16 pressure first appeared at run 36")
        }
        return w
    }

    /// True when the headline figures can be quoted as they stand.
    public var isTrustworthy: Bool { warnings.isEmpty }
}
