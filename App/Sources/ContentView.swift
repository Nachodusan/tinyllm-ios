import SwiftUI
import TinyLLMKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = BenchmarkModel()

    var body: some View {
        NavigationStack {
            List {
                Section("model") {
                    LabeledContent("id", value: model.modelShortName)
                    LabeledContent("device", value: DeviceInfo.model)
                    switch model.phase {
                    case .idle:
                        Button("Load model") { model.load() }
                    case .loading(let progress):
                        ProgressView(value: progress) {
                            Text("downloading \(Int(progress * 100))%")
                        }
                    case .ready:
                        LabeledContent("load", value: String(format: "%.1f s", model.loadSeconds))
                        LabeledContent("weights", value: String(format: "%.0f MB", model.modelSizeMB))
                    case .benchmarking(let done, let total):
                        ProgressView(value: Double(done), total: Double(total)) {
                            Text("run \(done) of \(total)")
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).font(.callout)
                    }
                }

                if model.canBenchmark {
                    Section {
                        Stepper("\(model.runCount) runs, back to back",
                                value: $model.runCount, in: 3...60, step: 1)
                        Button("Run benchmark") { model.runBenchmark() }
                    } footer: {
                        Text("No pause between generations. Pausing lets the phone "
                             + "cool and produces a number it cannot hold under load.")
                    }
                }

                if let report = model.report {
                    if !report.warnings.isEmpty {
                        Section {
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } header: {
                            Text("read these first")
                        }
                    }

                    Section("throughput") {
                        Row("burst", String(format: "%.1f tok/s", report.burstTokensPerSecond),
                            detail: "first run, cool device")
                        Row("sustained", String(format: "%.1f tok/s", report.sustainedTokensPerSecond),
                            detail: "last third of the run",
                            emphasis: true)
                        Row("retained", String(format: "%.0f%%", report.sustainedFraction * 100),
                            detail: report.reachedEquilibrium
                                ? "of the burst figure"
                                : "of the burst figure, still falling")
                    }

                    Section("thermal") {
                        Row("worst state", report.worstThermalState.rawValue.capitalized)
                        if let seconds = report.throttledAfterSeconds {
                            Row("throttled after", String(format: "%.0f s", seconds),
                                detail: "run \((report.throttledAfterRuns ?? 0) + 1)")
                        } else {
                            Row("throttled after", "never", detail: "stayed nominal")
                        }
                    }

                    Section("per run") {
                        ThroughputChart(runs: report.runs)
                            .frame(height: 120)
                            .listRowInsets(.init(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }

                    Section("cost") {
                        Row("peak memory", String(format: "%.0f MB", report.peakMemoryMB))
                        Row("time to first token",
                            String(format: "%.0f ms", report.runs.map(\.timeToFirstTokenMs).reduce(0, +)
                                   / Double(max(1, report.runs.count))),
                            detail: "mean")
                        ShareLink(item: model.exportURL ?? URL(fileURLWithPath: "/dev/null")) {
                            Label("Export report as JSON", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.exportURL == nil)
                    }
                }
            }
            .navigationTitle("TinyLLM")
        }
    }
}

private struct Row: View {
    let label: String
    let value: String
    var detail: String? = nil
    var emphasis: Bool = false

    init(_ label: String, _ value: String, detail: String? = nil, emphasis: Bool = false) {
        self.label = label
        self.value = value
        self.detail = detail
        self.emphasis = emphasis
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .font(emphasis ? .title3.bold().monospacedDigit() : .body.monospacedDigit())
                .foregroundStyle(emphasis ? Color.primary : .secondary)
        }
    }
}

/// Throughput over the run. The shape is the point: a flat line means the
/// device held, a decay means it did not.
private struct ThroughputChart: View {
    let runs: [GenerationMetrics]

    var body: some View {
        GeometryReader { geo in
            let values = runs.map(\.tokensPerSecond)
            let maxV = (values.max() ?? 1) * 1.1
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0

            ZStack(alignment: .topLeading) {
                Path { path in
                    for (i, v) in values.enumerated() {
                        let p = CGPoint(x: CGFloat(i) * step,
                                        y: geo.size.height * (1 - CGFloat(v / maxV)))
                        i == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2)

                ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
                    if run.thermalState > .nominal {
                        Circle()
                            .fill(run.thermalState >= .serious ? Color.red : Color.orange)
                            .frame(width: 6, height: 6)
                            .position(x: CGFloat(i) * step,
                                      y: geo.size.height * (1 - CGFloat(run.tokensPerSecond / maxV)))
                    }
                }
            }
        }
    }
}
