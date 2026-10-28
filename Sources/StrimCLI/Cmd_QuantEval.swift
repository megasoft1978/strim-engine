import Foundation
import MLX
import StrimCore

// Teacher-forced quantization comparison.
//   strim quanteval ref <model> <out.bin> <window> <label=ids.txt> [<label=ids.txt> ...]
//       Runs the reference model over fixed windows of the comma-separated token-id files, stores per position the
//       top-K (K=256) log-probs, its own NLL of the actual next token, plus 4 greedy 64-token continuations per
//       label (prompt = 256 tokens at offset 1500 + 3000*i) scored the same way ("gen" windows).
//   strim quanteval cmp <model> <ref.bin>
//       Re-runs the same token sequences on a candidate model and prints per label: KL(ref||cand) over the ref top-K
//       (tail mass not included), top-1 agreement, ref and candidate perplexity, and for the gen windows the
//       greedy-token agreement and max |delta log-prob| over the ref top-K.
// Windows are independent (fresh cache each), so long-context drift is only probed up to the window length.

private let topK = 256

private struct Win {
    var label: String
    var gen: Bool
    var promptLen: Int
    var tokens: [Int32]
    var idx: [Int32] = []     // (n-1) * topK
    var lp: [Float] = []      // (n-1) * topK
    var nll: [Float] = []     // (n-1)
}

private func scoreWindow(_ tokens: [Int32], store: WeightStore, ref: Win?) throws
    -> (idx: [Int32], lp: [Float], nll: [Float], kl: [Float], top1: [Bool], dmax: [Float], tail: [Float]) {
    let r = try QwenModel.forwardAll(tokens: tokens, store: store, cache: ModelCache())
    let n = tokens.count - 1
    var idxOut: [Int32] = [], lpOut: [Float] = [], nllOut: [Float] = []
    var kl: [Float] = [], top1: [Bool] = [], dmax: [Float] = [], tail: [Float] = []
    let step = 256
    var p = 0
    while p < n {
        let e = min(n, p + step)
        let lg = r.logits[0, p ..< e, 0...].asType(.float32)
        let logp = lg - lg.logSumExp(axis: -1, keepDims: true)
        let tgt = MLXArray(Array(tokens[(p + 1) ... e])).reshaped([e - p, 1])
        let picked = takeAlong(logp, tgt, axis: -1).reshaped([e - p])
        if let ref {
            let ri = MLXArray(Array(ref.idx[(p * topK) ..< (e * topK)])).reshaped([e - p, topK])
            let rl = MLXArray(Array(ref.lp[(p * topK) ..< (e * topK)])).reshaped([e - p, topK])
            let q = takeAlong(logp, ri, axis: -1)
            let pr = exp(rl)
            let k = (pr * (rl - q)).sum(axis: -1)
            let d = abs(rl - q).max(axis: -1)
            let am = argMax(logp, axis: -1)
            let t = pr.sum(axis: -1)
            eval(picked, k, d, am, t)
            kl += k.asArray(Float.self); dmax += d.asArray(Float.self); tail += t.asArray(Float.self).map { 1 - $0 }
            nllOut += picked.asArray(Float.self).map { -$0 }
            let amv = am.asArray(Int32.self)
            for j in 0 ..< (e - p) { top1.append(amv[j] == ref.idx[(p + j) * topK]) }
        } else {
            let part = argPartition(-logp, kth: topK - 1, axis: -1)[0..., 0 ..< topK]
            let pl = takeAlong(logp, part, axis: -1)
            let order = argSort(-pl, axis: -1)
            let si = takeAlong(part, order, axis: -1)
            let sl = takeAlong(pl, order, axis: -1)
            eval(picked, si, sl)
            idxOut += si.asArray(Int32.self); lpOut += sl.asArray(Float.self)
            nllOut += picked.asArray(Float.self).map { -$0 }
        }
        p = e
    }
    return (idxOut, lpOut, nllOut, kl, top1, dmax, tail)
}

private func put(_ d: inout Data, _ v: Int32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
private func putArr<T>(_ d: inout Data, _ a: [T]) { a.withUnsafeBytes { d.append(contentsOf: $0) } }

private func writeRef(_ wins: [Win], to path: String) throws {
    var d = Data()
    put(&d, Int32(wins.count))
    for w in wins {
        let lb = Array(w.label.utf8)
        put(&d, Int32(lb.count)); d.append(contentsOf: lb)
        put(&d, w.gen ? 1 : 0); put(&d, Int32(w.promptLen)); put(&d, Int32(w.tokens.count))
        putArr(&d, w.tokens); putArr(&d, w.idx); putArr(&d, w.lp); putArr(&d, w.nll)
    }
    try d.write(to: URL(fileURLWithPath: path))
}

private func readRef(_ path: String) throws -> [Win] {
    let d = try Data(contentsOf: URL(fileURLWithPath: path))
    var o = 0
    func i32() -> Int32 { let v = d.subdata(in: o ..< o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }; o += 4; return v }
    func arr<T>(_ n: Int, _: T.Type) -> [T] {
        let sz = n * MemoryLayout<T>.stride
        let a = d.subdata(in: o ..< o + sz).withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
        o += sz; return a
    }
    var wins: [Win] = []
    for _ in 0 ..< Int(i32()) {
        let ln = Int(i32()); let label = String(decoding: d.subdata(in: o ..< o + ln), as: UTF8.self); o += ln
        let gen = i32() == 1; let pl = Int(i32()); let n = Int(i32())
        var w = Win(label: label, gen: gen, promptLen: pl, tokens: arr(n, Int32.self))
        w.idx = arr((n - 1) * topK, Int32.self); w.lp = arr((n - 1) * topK, Float.self); w.nll = arr(n - 1, Float.self)
        wins.append(w)
    }
    return wins
}

/// `strim quanteval bits [N=17408] [K=5120]`: synthetic quantized-matmul speed per bit width / group size (decode M=1,
/// verify M=4, prefill M=1024); 8 rotating weight copies so the weights are not cache-resident. Indicative only.
private func runQuantBits(_ args: [String]) {
    let N = args.count > 3 ? Int(args[3]) ?? 17408 : 17408
    let K = args.count > 4 ? Int(args[4]) ?? 5120 : 5120
    print("# bits group M ms/call GB/s(weights) TFLOPS   (N=\(N) K=\(K))")
    for (bits, g) in [(2, 64), (2, 128), (3, 64), (3, 128), (4, 64), (4, 128), (5, 64), (6, 64), (8, 64)] {
        var ws: [(MLXArray, MLXArray, MLXArray)] = []
        for _ in 0 ..< 8 {
            let w = MLXRandom.normal([N, K]).asType(.bfloat16)
            let (wq, sc, bi0) = quantized(w, groupSize: g, bits: bits)
            let bi = bi0!
            eval(wq, sc, bi); ws.append((wq, sc, bi))
        }
        let bytes = Double(ws[0].0.nbytes + ws[0].1.nbytes + ws[0].2.nbytes)
        for M in [1, 4, 1024] {
            let x = MLXRandom.normal([1, M, K]).asType(.bfloat16); eval(x)
            func once() {
                var outs: [MLXArray] = []
                for i in 0 ..< 16 {
                    let w = ws[i % 8]
                    outs.append(quantizedMatmul(x, w.0, scales: w.1, biases: w.2, transpose: true, groupSize: g, bits: bits))
                }
                eval(outs)
            }
            once()
            var best = Double.infinity
            for _ in 0 ..< 5 { let t0 = Date(); once(); best = min(best, Date().timeIntervalSince(t0) * 1000 / 16) }
            print(String(format: "%d g%d M=%d  %.3f ms  %.0f GB/s  %.1f TFLOPS", bits, g, M, best,
                         bytes / best / 1e6, 2.0 * Double(M) * Double(N) * Double(K) / best / 1e9))
        }
    }
}

func runQuantEval(_ args: [String]) {
    if args.count >= 3, args[2] == "bits" { runQuantBits(args); return }
    let usage = "usage: strim quanteval ref <model> <out.bin> <window> <label=ids.txt>... | strim quanteval cmp <model> <ref.bin>"
    guard args.count >= 5 else { print(usage); return }
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        if args[2] == "ref" {
            guard args.count >= 7, let win = Int(args[5]) else { print(usage); return }
            var wins: [Win] = []
            for spec in args[6...] {
                let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { print(usage); return }
                let raw = try String(contentsOfFile: parts[1], encoding: .utf8)
                let ids = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int32($0) }
                var s = 0
                while s + win <= ids.count {
                    wins.append(Win(label: parts[0], gen: false, promptLen: 0, tokens: Array(ids[s ..< s + win])))
                    s += win
                }
                for i in 0 ..< 4 where 1500 + 3000 * i + 256 <= ids.count {
                    let pr = Array(ids[(1500 + 3000 * i) ..< (1500 + 3000 * i + 256)])
                    let full = try QwenModel.generate(prompt: pr, maxTokens: 64, store: store)
                    wins.append(Win(label: parts[0], gen: true, promptLen: 256, tokens: full))
                }
            }
            for k in wins.indices {
                let s = try scoreWindow(wins[k].tokens, store: store, ref: nil)
                wins[k].idx = s.idx; wins[k].lp = s.lp; wins[k].nll = s.nll
                print("ref window \(k + 1)/\(wins.count) \(wins[k].label)\(wins[k].gen ? " gen" : "")")
            }
            try writeRef(wins, to: args[4])
            print("wrote \(args[4]): \(wins.count) windows")
        } else if args[2] == "cmp" {
            let wins = try readRef(args[4])
            struct Acc { var n = 0; var kl = 0.0; var top1 = 0; var nllC = 0.0; var nllR = 0.0; var tail = 0.0; var dmax: Float = 0; var klMax: Float = 0 }
            var acc: [String: Acc] = [:]
            for (k, w) in wins.enumerated() {
                let s = try scoreWindow(w.tokens, store: store, ref: w)
                let from = w.gen ? w.promptLen - 1 : 0
                var a = acc[w.label + (w.gen ? " gen64" : " text")] ?? Acc()
                for j in from ..< s.kl.count {
                    a.n += 1; a.kl += Double(s.kl[j]); a.top1 += s.top1[j] ? 1 : 0
                    a.nllC += Double(s.nll[j]); a.nllR += Double(w.nll[j]); a.tail += Double(s.tail[j])
                    a.dmax = max(a.dmax, s.dmax[j]); a.klMax = max(a.klMax, s.kl[j])
                }
                acc[w.label + (w.gen ? " gen64" : " text")] = a
                FileHandle.standardError.write(Data("cmp window \(k + 1)/\(wins.count)\n".utf8))
            }
            print("set | positions | meanKL | maxKL | top1 | ppl_ref | ppl_cand | tailmass | max|dlogp|")
            for key in acc.keys.sorted() {
                let a = acc[key]!; let n = Double(a.n)
                print(String(format: "%@ | %d | %.5f | %.3f | %.4f | %.4f | %.4f | %.5f | %.3f", key, a.n, a.kl / n, a.klMax,
                             Double(a.top1) / n, exp(a.nllR / n), exp(a.nllC / n), a.tail / n, a.dmax))
            }
        } else { print(usage) }
    } catch {
        FileHandle.standardError.write(Data("quanteval failed: \(error)\n".utf8)); exit(1)
    }
}
