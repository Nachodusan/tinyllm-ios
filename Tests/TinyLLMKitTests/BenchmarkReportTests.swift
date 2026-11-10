import XCTest
@testable import TinyLLMKit

/// Tests for the reporting, not for the model.
///
/// What a model generates is the model's business. What this package claims
/// about throughput, throttling and memory is its own, and that is what can
/// be wrong in a way nobody notices.
final class BenchmarkReportTests: XCTestCase {

    private func metrics(
        tps: Double, thermal: ThermalState = .nominal, memMB: Double = 400,
        elapsed: Double = 0
    ) -> GenerationMetrics {
        GenerationMetrics(
            timeToFirstTokenMs: 120, tokensPerSecond: tps, promptTokensPerSecond: 300,
            promptTokens: 20, generatedTokens: 128, wallClockMs: 3000,
            memoryFootprintMB: memMB, thermalState: thermal, elapsedSinceStartS: elapsed
        )
    }

    private func report(_ runs: [GenerationMetrics]) -> BenchmarkReport {
        BenchmarkReport(
            device: "iPhone17,3", systemVersion: "26.5", model: "test",
            loadSeconds: 2.0, modelSizeMB: 310, runs: runs, startedAt: Date()
        )
    }

    func testBurstIsTheFirstRun() {
        let r = report([metrics(tps: 40), metrics(tps: 30), metrics(tps: 22)])
        XCTAssertEqual(r.burstTokensPerSecond, 40)
    }

    func testSustainedUsesTheTailNotTheMean() {
        // The mean of 40/30/22 is 30.7, which no part of this run sustained.
        let r = report([metrics(tps: 40), metrics(tps: 30), metrics(tps: 22)])
        XCTAssertEqual(r.sustainedTokensPerSecond, 22, accuracy: 0.001)
    }

    func testSustainedFractionExposesThrottling() {
        let r = report([metrics(tps: 40), metrics(tps: 30), metrics(tps: 20)])
        XCTAssertEqual(r.sustainedFraction, 0.5, accuracy: 0.001)
    }

    func testNoThrottlingMeansFractionOfOne() {
        let r = report([metrics(tps: 30), metrics(tps: 30), metrics(tps: 30)])
        XCTAssertEqual(r.sustainedFraction, 1.0, accuracy: 0.001)
    }

    func testThrottlePointIsWhereThermalFirstRises() {
        let r = report([
            metrics(tps: 40, thermal: .nominal, elapsed: 0),
            metrics(tps: 38, thermal: .nominal, elapsed: 4),
            metrics(tps: 29, thermal: .fair, elapsed: 8),
            metrics(tps: 22, thermal: .serious, elapsed: 12),
        ])
        XCTAssertEqual(r.throttledAfterRuns, 2)
        XCTAssertEqual(r.throttledAfterSeconds, 8)
        XCTAssertEqual(r.worstThermalState, .serious)
    }

    func testNoThrottlePointWhenItStaysNominal() {
        let r = report([metrics(tps: 30), metrics(tps: 30)])
        XCTAssertNil(r.throttledAfterRuns)
        XCTAssertNil(r.throttledAfterSeconds)
    }

    func testThermalStatesAreOrdered() {
        XCTAssertTrue(ThermalState.nominal < .fair)
        XCTAssertTrue(ThermalState.fair < .serious)
        XCTAssertTrue(ThermalState.serious < .critical)
        XCTAssertEqual([ThermalState.fair, .nominal, .serious].max(), .serious)
    }

    func testPeakMemoryIsTheMaximumNotTheLast() {
        let r = report([metrics(tps: 30, memMB: 400), metrics(tps: 30, memMB: 980),
                        metrics(tps: 30, memMB: 520)])
        XCTAssertEqual(r.peakMemoryMB, 980)
    }

    func testAnEmptyRunReportsZeroesRatherThanCrashing() {
        let r = report([])
        XCTAssertEqual(r.burstTokensPerSecond, 0)
        XCTAssertEqual(r.sustainedTokensPerSecond, 0)
        XCTAssertEqual(r.sustainedFraction, 0)
        XCTAssertEqual(r.peakMemoryMB, 0)
    }

    func testSingleRunIsItsOwnSustainedFigure() {
        let r = report([metrics(tps: 33)])
        XCTAssertEqual(r.burstTokensPerSecond, 33)
        XCTAssertEqual(r.sustainedTokensPerSecond, 33)
        XCTAssertEqual(r.sustainedFraction, 1.0, accuracy: 0.001)
    }

    func testReportRoundTripsThroughJSON() throws {
        let r = report([metrics(tps: 40, thermal: .fair, elapsed: 4)])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(BenchmarkReport.self, from: data)
        XCTAssertEqual(back.runs.first?.thermalState, .fair)
        XCTAssertEqual(back.device, "iPhone17,3")
    }

    func testDeviceIdentifierIsTheHardwareOne() {
        // UIDevice.model only ever says "iPhone", which is useless in a report.
        XCTAssertFalse(DeviceInfo.model.isEmpty)
        XCTAssertNotEqual(DeviceInfo.model, "iPhone")
    }
}

/// Tests for the guard, against the runs that made it necessary.
///
/// The three fixtures in `evidence/` are real reports off an iPhone 16, not
/// hand-written. One of them is the twelve-run sweep whose cheerful numbers
/// are the reason `warnings` exists; a guard tested only against invented data
/// would not have caught it.
final class EquilibriumGuardTests: XCTestCase {

    private func fixture(_ name: String) throws -> BenchmarkReport {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TinyLLMKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("evidence/\(name).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
    }

    func testTheShortSweepIsNotTrusted() throws {
        let r = try fixture("iphone16-12runs")
        // Everything about it looks fine.
        XCTAssertEqual(r.worstThermalState, .nominal)
        XCTAssertNil(r.throttledAfterRuns)
        XCTAssertGreaterThan(r.sustainedFraction, 0.8)
        // And none of that should be quotable.
        XCTAssertFalse(r.isTrustworthy)
        XCTAssertFalse(r.reachedEquilibrium)
        XCTAssertEqual(r.warnings.count, 3)
    }

    func testTheSoakIsTrusted() throws {
        let r = try fixture("iphone16-soak-cold")
        XCTAssertTrue(r.reachedEquilibrium)
        XCTAssertTrue(r.isTrustworthy, "warnings: \(r.warnings)")
        XCTAssertEqual(r.worstThermalState, .serious)
        XCTAssertEqual(r.throttledAfterRuns, 35)   // run 36
    }

    func testThrottlingIsAlreadyUnderwayWhenTheOSAdmitsIt() throws {
        let r = try fixture("iphone16-soak-cold")
        let i = try XCTUnwrap(r.throttledAfterRuns)
        let atFirstWarning = r.runs[i].tokensPerSecond / r.burstTokensPerSecond
        // A quarter of the throughput was gone before `thermalState` moved.
        XCTAssertLessThan(atFirstWarning, 0.80)
        XCTAssertGreaterThan(atFirstWarning, 0.70)
    }

    func testRewarmedDeviceRecoversItsBurstButNotItsFloor() throws {
        let cold = try fixture("iphone16-soak-cold")
        let warm = try fixture("iphone16-soak-rewarmed")
        // Three minutes idle buys the burst figure back almost exactly, which
        // is what rules out accumulated state inside the process.
        XCTAssertGreaterThan(warm.burstTokensPerSecond / cold.burstTokensPerSecond, 0.97)
        // It does not buy back the sustained figure: starting warm costs more.
        XCTAssertLessThan(warm.sustainedTokensPerSecond, cold.sustainedTokensPerSecond)
    }

    func testMemoryIsFlatAcrossBothSoaks() throws {
        for name in ["iphone16-soak-cold", "iphone16-soak-rewarmed"] {
            let r = try fixture(name)
            let mem = r.runs.map(\.memoryFootprintMB)
            let spread = (mem.max() ?? 0) - (mem.min() ?? 0)
            // No leak: a growing footprint would be a second explanation for
            // the decay, and this is what excludes it.
            XCTAssertLessThan(spread, 30, "\(name) footprint moved \(spread) MB")
        }
    }

    func testStillFallingRunIsFlagged() {
        // Synthetic: a clean linear decline that never flattens.
        let runs = (0..<60).map { metrics(tps: 100 - Double($0)) }
        let r = report(runs)
        XCTAssertFalse(r.reachedEquilibrium)
        XCTAssertTrue(r.warnings.contains { $0.contains("still falling") })
    }

    func testFlatRunIsNotFlagged() {
        let runs = (0..<60).map { _ in metrics(tps: 70) }
        XCTAssertTrue(report(runs).reachedEquilibrium)
    }

    // Shared helpers, same shape as the suite above.
    private func metrics(tps: Double, thermal: ThermalState = .serious) -> GenerationMetrics {
        GenerationMetrics(
            timeToFirstTokenMs: 100, tokensPerSecond: tps, promptTokensPerSecond: 1400,
            promptTokens: 40, generatedTokens: 103, wallClockMs: 1000,
            memoryFootprintMB: 380, thermalState: thermal, elapsedSinceStartS: 0
        )
    }

    private func report(_ runs: [GenerationMetrics]) -> BenchmarkReport {
        BenchmarkReport(
            device: "iPhone17,3", systemVersion: "26.6.1", model: "test",
            loadSeconds: 1, modelSizeMB: 335, runs: runs, startedAt: Date()
        )
    }
}
