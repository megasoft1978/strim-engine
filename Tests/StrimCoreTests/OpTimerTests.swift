import Foundation
import MLX
import Testing
@testable import StrimCore

private final class BundleMarker {}

/// MLX array creation initialises Metal, which needs the SwiftPM metallib bundle that ships inside the
/// test bundle (same registration as CausalTests). Tests that touch MLXArray are skipped when it is absent.
private let metalReady: Bool = {
    let b = Bundle(for: BundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
    let lib = b.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    return FileManager.default.fileExists(atPath: lib.path)
}()

/// OpTimer bookkeeping (no MLX needed) and the timed-region core (CPU device, needs the metallib bundle).
@Suite(.serialized)
struct OpTimerTests {
    @Test func flagParsing() {
        #expect(!OpTimer.parseFlag(nil))
        #expect(!OpTimer.parseFlag(""))
        #expect(!OpTimer.parseFlag("0"))
        #expect(!OpTimer.parseFlag("off"))
        #expect(OpTimer.parseFlag("1"))
        #expect(OpTimer.parseFlag("true"))
    }

    @Test(.enabled(if: metalReady)) func offByDefaultInTests() {
        // The test environment does not set STRIM_OPTIME, so the marked layers run the plain body.
        if ProcessInfo.processInfo.environment["STRIM_OPTIME"] == nil { #expect(!OpTimer.on) }
        var ran = 0
        _ = OpTimer.time("never", flops: { ran += 1; return 1 }(), inputs: { ran += 1; return [] }()) {
            MLXArray([1, 2, 3])
        }
        // autoclosure arguments are not evaluated when off
        if !OpTimer.on { #expect(ran == 0) }
    }

    @Test func accumulatesAndSubtractsFence() {
        OpTimer.reset()
        OpTimer.fenceNs = 1_000_000          // 1 ms per call
        OpTimer.recordRegion("gdn.rec", ns: 5_000_000, ctx: "main", flops: 2e12, bytes: 1e9)
        OpTimer.recordRegion("gdn.rec", ns: 5_000_000, ctx: "main", flops: 2e12, bytes: 1e9)
        OpTimer.recordRegion("mlp.down", ns: 3_000_000, ctx: "main")
        let rows = OpTimer.rows()
        #expect(rows.count == 2)
        #expect(rows[0].name == "gdn.rec" && rows[0].calls == 2)
        #expect(abs(rows[0].rawMs - 10) < 1e-9)
        #expect(abs(rows[0].netMs - 8) < 1e-9)
        #expect(abs(rows[0].tflops - 4e12 / 8e-3 / 1e12) < 1e-6)
        #expect(OpTimer.rawNs(ctx: "main") == 13_000_000)
        let text = OpTimer.report(wallSeconds: 0.014, tokens: 100, plainSeconds: 0.010)
        #expect(text.contains("gdn.rec"))
        #expect(text.contains("main/gdn"))
        #expect(text.contains("GFLOP/token"))
        OpTimer.reset()
        OpTimer.fenceNs = 0
        #expect(OpTimer.rows().isEmpty)
    }

    @Test(.enabled(if: metalReady)) func timedRegionEvaluatesAndRecords() {
        Device.withDefaultDevice(.cpu) {
            OpTimer.reset()
            let x = MLXArray([1, 2, 3, 4] as [Float])
            let out = OpTimer.timedSlow("unit.add", 4, 32, [x]) { [x + 1, x * 2] }
            #expect(out[0].asArray(Float.self) == [2, 3, 4, 5])
            #expect(out[1].asArray(Float.self) == [2, 4, 6, 8])
            let rows = OpTimer.rows()
            #expect(rows.count == 1 && rows[0].calls == 1 && rows[0].flops == 4)
            OpTimer.reset()
        }
    }

    @Test(.enabled(if: metalReady)) func calibrateGivesPositiveFence() {
        Device.withDefaultDevice(.cpu) {
            let before = OpTimer.fenceNs
            let f = OpTimer.calibrate(iterations: 20)
            #expect(f > 0)
            OpTimer.fenceNs = before
        }
    }
}
