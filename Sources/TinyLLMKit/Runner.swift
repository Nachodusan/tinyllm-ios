import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Loads a quantised model and generates from it, recording what it cost.
public actor Runner {
    public struct Config: Sendable {
        /// A model id on the Hugging Face hub, already quantised for MLX.
        public var modelId: String
        /// Hard ceiling on generated tokens per call.
        public var maxTokens: Int
        /// Cap on MLX's GPU buffer cache. Left unbounded, a phone will grow
        /// the cache until iOS kills the app for memory.
        public var gpuCacheLimitMB: Int

        public init(
            modelId: String = "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            maxTokens: Int = 128,
            gpuCacheLimitMB: Int = 48
        ) {
            self.modelId = modelId
            self.maxTokens = maxTokens
            self.gpuCacheLimitMB = gpuCacheLimitMB
        }
    }

    public enum LoadState: Sendable {
        case idle
        case loading(progress: Double)
        case ready(loadSeconds: Double, sizeMB: Double)
        case failed(String)
    }

    private let config: Config
    private var container: ModelContainer?
    private var loadSeconds: Double = 0
    private var modelSizeMB: Double = 0
    private var startedAt: Date?

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Loading

    public func load(onProgress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        guard container == nil else { return }
        MLX.GPU.set(cacheLimit: config.gpuCacheLimitMB * 1024 * 1024)

        let t0 = CFAbsoluteTimeGetCurrent()
        let before = Memory.footprintMB()
        let configuration = ModelConfiguration(id: config.modelId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            onProgress(progress.fractionCompleted)
        }
        self.container = container
        self.loadSeconds = CFAbsoluteTimeGetCurrent() - t0
        self.modelSizeMB = max(0, Memory.footprintMB() - before)
    }

    // MARK: - Generation

    /// Generate once, and report what it cost.
    public func generate(prompt: String) async throws -> (text: String, metrics: GenerationMetrics) {
        guard let container else { throw RunnerError.notLoaded }
        if startedAt == nil { startedAt = Date() }

        let wallStart = CFAbsoluteTimeGetCurrent()
        // A reference box rather than a captured var: the token callback runs
        // on the generation's own thread, and mutating a captured local from
        // there is an error under Swift 6 concurrency.
        let firstToken = FirstTokenClock()

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]])
            )
            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.0),
                context: context
            ) { tokens in
                if !tokens.isEmpty { firstToken.markIfUnset() }
                return tokens.count >= self.config.maxTokens ? .stop : .more
            }
        }

        let wallEnd = CFAbsoluteTimeGetCurrent()
        let ttft = ((firstToken.value ?? wallEnd) - wallStart) * 1000

        let metrics = GenerationMetrics(
            timeToFirstTokenMs: ttft,
            tokensPerSecond: result.tokensPerSecond,
            promptTokensPerSecond: result.promptTokensPerSecond,
            promptTokens: result.promptTokens.count,
            generatedTokens: result.tokens.count,
            wallClockMs: (wallEnd - wallStart) * 1000,
            memoryFootprintMB: Memory.footprintMB(),
            thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
            elapsedSinceStartS: Date().timeIntervalSince(startedAt ?? Date())
        )
        return (result.output, metrics)
    }

    // MARK: - Benchmark

    /// Run the same prompt repeatedly and watch what the device does to you.
    ///
    /// Back to back, with no pause, on purpose. Pausing between generations
    /// lets the phone cool and produces a number it cannot hold under load,
    /// which is how most on-device figures get published.
    public func benchmark(
        prompt: String,
        runs: Int,
        onRun: @Sendable @escaping (Int, GenerationMetrics) -> Void = { _, _ in }
    ) async throws -> BenchmarkReport {
        guard container != nil else { throw RunnerError.notLoaded }
        startedAt = Date()
        var collected: [GenerationMetrics] = []

        for i in 0..<runs {
            let (_, metrics) = try await generate(prompt: prompt)
            collected.append(metrics)
            onRun(i, metrics)
        }

        return BenchmarkReport(
            device: DeviceInfo.model,
            systemVersion: DeviceInfo.systemVersion,
            model: config.modelId,
            loadSeconds: loadSeconds,
            modelSizeMB: modelSizeMB,
            runs: collected,
            startedAt: startedAt ?? Date()
        )
    }

    public var isLoaded: Bool { container != nil }
}

/// Records when the first token appeared, once, from whichever thread the
/// generation loop happens to call back on.
private final class FirstTokenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: CFAbsoluteTime?

    func markIfUnset() {
        lock.lock()
        defer { lock.unlock() }
        if stamp == nil { stamp = CFAbsoluteTimeGetCurrent() }
    }

    var value: CFAbsoluteTime? {
        lock.lock()
        defer { lock.unlock() }
        return stamp
    }
}

public enum RunnerError: LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The model has not been loaded yet."
        }
    }
}

public enum DeviceInfo {
    /// The hardware identifier, e.g. `iPhone17,3`. `UIDevice.model` only ever
    /// says "iPhone", which is useless in a benchmark report.
    public static var model: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "unknown" : machine
    }

    public static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
