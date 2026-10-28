import Foundation
import MLX
import StrimCore

// `strim benchbatchverify <model> <ctx> <B> [reps]`: forward cost of a batched verify pass.
//
// Prefills B sequences of length ctx, then for S in 1...5 times a pass that feeds S tokens
// per sequence through the batched layers (per-sequence attention caches, stacked GDN
// state). Rounds are interleaved over S so thermal / load drift hits every S equally.
// Cache grows by ~(warm + reps) * 15 tokens over the run (negligible vs ctx).
// Prints one `RESULT ctx B S ms` line per cell.

func runBatchVerify(_ args: [String]) {
    guard args.count >= 5, let ctx = Int(args[3]), let B = Int(args[4]), ctx >= 1, B >= 1 else {
        print("usage: strim benchbatchverify <model> <ctx> <B> [reps]")
        return
    }
    let reps = args.count >= 6 ? Int(args[5]) ?? 6 : 6
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let prompts: [[Int32]] = (0 ..< B).map { b in
            (0 ..< ctx).map { i in Int32((i * 7919 + b * 104_729 + 17) % 100_000 + 1) }
        }
        let cache = BatchedModelCache()
        let lg0 = try BatchModel.prefill(tokens: prompts, store: store, cache: cache)
        eval(lg0); Stream.gpu.synchronize()

        func pass(_ S: Int) throws -> Double {
            let ids = (0 ..< B * S).map { Int32(100 + $0 % 50) }
            let t0 = Date()
            var h = try store.embedding("language_model.model.embed_tokens",
                                        indices: MLXArray(ids).reshaped([B, S]))
            for i in 0 ..< 64 {
                h = try DecoderLayer.forwardBatched(h, store: store, layer: i, cache: cache)
            }
            let normed = try store.rmsNorm("language_model.model.norm", h)
            let lg = try store.linear("language_model.lm_head", normed)
            eval(lg); Stream.gpu.synchronize()
            return Date().timeIntervalSince(t0) * 1000
        }
        for S in 1 ... 5 { _ = try pass(S); _ = try pass(S) }
        var ms: [Int: [Double]] = [:]
        for _ in 0 ..< reps { for S in 1 ... 5 { ms[S, default: []].append(try pass(S)) } }
        for S in 1 ... 5 {
            let xs = ms[S]!.sorted()
            let med = xs[xs.count / 2]
            let mean = xs.reduce(0, +) / Double(xs.count)
            print(String(format: "RESULT ctx=%d B=%d S=%d median %.2f mean %.2f min %.2f ms/pass",
                         ctx, B, S, med, mean, xs[0]))
        }
    } catch {
        FileHandle.standardError.write(Data("benchbatchverify failed: \(error)\n".utf8))
        exit(1)
    }
}
