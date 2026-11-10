import Foundation
import Observation
import TinyLLMKit

@MainActor
@Observable
final class BenchmarkModel {
    enum Phase {
        case idle
        case loading(progress: Double)
        case ready
        case benchmarking(done: Int, total: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: BenchmarkReport?
    private(set) var loadSeconds: Double = 0
    private(set) var modelSizeMB: Double = 0
    private(set) var exportURL: URL?
    var runCount: Int = 12

    // @Observable rewrites stored properties into computed ones, so these
    // have to opt out: `lazy` is not available on a computed property, and
    // the runner is not UI state anyway.
    @ObservationIgnored private let config = Runner.Config()
    @ObservationIgnored private let runner: Runner

    init() {
        runner = Runner(config: config)
    }

    var modelShortName: String { config.modelId.split(separator: "/").last.map(String.init) ?? config.modelId }

    var canBenchmark: Bool {
        if case .ready = phase { return true }
        return false
    }

    func load() {
        phase = .loading(progress: 0)
        Task {
            do {
                try await runner.load { fraction in
                    Task { @MainActor in self.phase = .loading(progress: fraction) }
                }
                let t = await runner.isLoaded
                guard t else { throw RunnerError.notLoaded }
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func runBenchmark() {
        let total = runCount
        phase = .benchmarking(done: 0, total: total)
        Task {
            do {
                let result = try await runner.benchmark(
                    prompt: "Explain in two sentences why the sky is blue.",
                    runs: total
                ) { index, _ in
                    Task { @MainActor in
                        self.phase = .benchmarking(done: index + 1, total: total)
                    }
                }
                report = result
                exportURL = try? Self.write(result)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private static func write(_ report: BenchmarkReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinyllm-\(report.device)-\(Int(Date().timeIntervalSince1970)).json")
        try encoder.encode(report).write(to: url)
        return url
    }
}
