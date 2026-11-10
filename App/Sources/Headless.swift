import Foundation
import TinyLLMKit
import UIKit

/// A benchmark nobody is watching.
///
/// The app's own UI needs a hand on the glass, which is fine for a demo and
/// useless for a measurement you want to repeat. With `-headless 1` the app
/// loads, runs the sweep and writes the whole report to stdout, so a run can
/// be driven from a shell and the numbers land somewhere other than a
/// screenshot.
enum Headless {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "headless")
            || ProcessInfo.processInfo.environment["TINYLLM_HEADLESS"] == "1"
    }

    static var runCount: Int {
        intOption("runs") ?? 12
    }

    /// Seconds to idle between two identical batches. Non-zero turns the run
    /// into the recovery experiment described in `run()`.
    static var cooldownSeconds: Int {
        intOption("cooldown") ?? 0
    }

    private static func intOption(_ key: String) -> Int? {
        if let raw = ProcessInfo.processInfo.environment["TINYLLM_" + key.uppercased()],
           let n = Int(raw), n > 0 { return n }
        let n = UserDefaults.standard.integer(forKey: key)
        return n > 0 ? n : nil
    }

    static func run() async {
        // A long sweep outlasts the default auto-lock. When the screen sleeps,
        // iOS suspends the app and drops the USB session, which killed two
        // runs before this line existed.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        let config = Runner.Config()
        let runner = Runner(config: config)
        say("device   \(DeviceInfo.model) · iOS \(DeviceInfo.systemVersion)")
        say("model    \(config.modelId)")
        say("runs     \(runCount)\(cooldownSeconds > 0 ? " ×2, \(cooldownSeconds)s idle between" : "")")
        say("thermal  \(ThermalState(ProcessInfo.processInfo.thermalState).rawValue) at start")

        do {
            var lastDecile = -1
            try await runner.load { fraction in
                let decile = Int(fraction * 10)
                if decile > lastDecile { lastDecile = decile; say("load     \(decile * 10)%") }
            }
            say("loaded")

            let first = try await batch(runner, label: cooldownSeconds > 0 ? "A" : "")
            emit(first, label: cooldownSeconds > 0 ? "A" : "")

            // The decisive experiment.
            //
            // Throughput falling over a batch has two explanations that look
            // identical from inside one batch: the device is throttling, or
            // this process is accumulating something. Idling and running the
            // identical batch again separates them. Recovery to the original
            // burst figure means the device; a second batch that opens where
            // the first one ended means the code, and the "throttling" was
            // never thermal at all.
            if cooldownSeconds > 0 {
                say("")
                say("idle     \(cooldownSeconds)s")
                try await Task.sleep(for: .seconds(cooldownSeconds))
                say("thermal  \(ThermalState(ProcessInfo.processInfo.thermalState).rawValue) after idle")
                let second = try await batch(runner, label: "B")
                emit(second, label: "B")

                say("")
                say(String(format: "A burst       %.2f tok/s", first.burstTokensPerSecond))
                say(String(format: "B burst       %.2f tok/s", second.burstTokensPerSecond))
                say(String(format: "recovery      %.0f%% of A's burst",
                           first.burstTokensPerSecond > 0
                           ? second.burstTokensPerSecond / first.burstTokensPerSecond * 100 : 0))
                say(String(format: "A sustained   %.2f tok/s", first.sustainedTokensPerSecond))
                say(String(format: "B sustained   %.2f tok/s", second.sustainedTokensPerSecond))
            }
            say("DONE")
        } catch {
            say("FAILED \(error.localizedDescription)")
        }
    }

    private static func batch(_ runner: Runner, label: String) async throws -> BenchmarkReport {
        let prefix = label.isEmpty ? "run" : "\(label) run"
        return try await runner.benchmark(
            prompt: "Explain in two sentences why the sky is blue.",
            runs: runCount
        ) { i, m in
            // Every run for a short sweep; every tenth once it gets long, so a
            // five-minute run does not bury the summary in scrollback.
            let n = i + 1
            guard runCount <= 20 || n == 1 || n % 10 == 0 || n == runCount else { return }
            say(String(format: "%@ %3d   %6.2f tok/s   ttft %6.1f ms   mem %5.0f MB   %@",
                       prefix, n, m.tokensPerSecond, m.timeToFirstTokenMs,
                       m.memoryFootprintMB, m.thermalState.rawValue))
        }
    }

    private static func emit(_ report: BenchmarkReport, label: String) {
        let tag = label.isEmpty ? "" : label + " "
        say("")
        say(String(format: "%@burst        %.2f tok/s", tag, report.burstTokensPerSecond))
        say(String(format: "%@sustained    %.2f tok/s", tag, report.sustainedTokensPerSecond))
        say(String(format: "%@retained     %.0f%%", tag, report.sustainedFraction * 100))
        say("\(tag)worst        \(report.worstThermalState.rawValue)")
        if let s = report.throttledAfterSeconds {
            say(String(format: "%@throttled    %.0f s (run %d)", tag, s, (report.throttledAfterRuns ?? 0) + 1))
        } else {
            say("\(tag)throttled    never above nominal")
        }
        say(String(format: "%@peak memory  %.0f MB", tag, report.peakMemoryMB))
        for warning in report.warnings { say("\(tag)WARNING      \(warning)") }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) {
            say("JSON-BEGIN \(label)")
            json.split(separator: "\n", omittingEmptySubsequences: false).forEach { say(String($0)) }
            say("JSON-END \(label)")
        }
    }

    /// stdout, flushed. `print` alone buffers when stdout is not a terminal,
    /// and a benchmark whose output arrives after it finishes cannot be watched.
    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data(("[bench] " + line + "\n").utf8))
    }
}
