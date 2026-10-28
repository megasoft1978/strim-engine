import Foundation
import Metal
import MLX
import MLXRandom
import StrimCore

// `strim benchtensormicro [probe|fp16] [M=...] [reps]`: feasibility microbench for Metal 4 tensor ops
// (MetalPerformancePrimitives matmul2d) compiled at runtime through the plain Metal API (no MLX
// internals). `probe` only compiles + dispatches one tiny matmul and checks the result; `fp16` times
// y[M,N] = x[M,K] * W[N,K]^T in fp16 (tensor-op kernel vs MLX matmul) on the real Qwen shapes.

private func tensorKernelSource(mt: Int, nt: Int, sg: Int, relaxed: Bool, ta: String = "half", tw: String = "half", tc: String = "half") -> String {
    """
    #include <metal_stdlib>
    #include <metal_tensor>
    #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
    using namespace metal;
    using namespace mpp::tensor_ops;
    kernel void tmm(device \(ta)* Ap [[buffer(0)]], device \(tw)* Wp [[buffer(1)]], device \(tc)* Cp [[buffer(2)]],
                    constant uint& M [[buffer(3)]], constant uint& N [[buffer(4)]], constant uint& K [[buffer(5)]],
                    uint2 tgid [[threadgroup_position_in_grid]]) {
        auto A = tensor<device \(ta), dextents<int32_t, 2>, tensor_inline>(Ap, dextents<int32_t, 2>((int)K, (int)M));
        auto W = tensor<device \(tw), dextents<int32_t, 2>, tensor_inline>(Wp, dextents<int32_t, 2>((int)K, (int)N));
        auto C = tensor<device \(tc), dextents<int32_t, 2>, tensor_inline>(Cp, dextents<int32_t, 2>((int)N, (int)M));
        constexpr auto desc = matmul2d_descriptor(\(mt), \(nt), static_cast<int>(dynamic_extent), false, true, \(relaxed ? "true" : "false"));
        matmul2d<desc, execution_simdgroups<\(sg)>> op;
        auto mA = A.slice(0, tgid.y * \(mt));
        auto mW = W.slice(0, tgid.x * \(nt));
        auto mC = C.slice(tgid.x * \(nt), tgid.y * \(mt));
        op.run(mA, mW, mC);
    }
    """
}

@available(macOS 26.0, *)
private final class TensorMM {
    let dev: MTLDevice, q: MTLCommandQueue, pso: MTLComputePipelineState
    let mt: Int, nt: Int, sg: Int
    init?(mt: Int, nt: Int, sg: Int, relaxed: Bool, verbose: Bool = true, ta: String = "half", tw: String = "half", tc: String = "half") {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        dev = d; self.q = q; self.mt = mt; self.nt = nt; self.sg = sg
        let opts = MTLCompileOptions()
        opts.languageVersion = .version4_0
        do {
            let lib = try d.makeLibrary(source: tensorKernelSource(mt: mt, nt: nt, sg: sg, relaxed: relaxed, ta: ta, tw: tw, tc: tc), options: opts)
            pso = try d.makeComputePipelineState(function: lib.makeFunction(name: "tmm")!)
        } catch {
            if verbose { print("COMPILE_FAIL mt=\(mt) nt=\(nt) sg=\(sg): \(error)") }
            return nil
        }
    }
    func encode(_ enc: MTLComputeCommandEncoder, a: MTLBuffer, w: MTLBuffer, c: MTLBuffer, M: Int, N: Int, K: Int) {
        enc.setComputePipelineState(pso)
        enc.setBuffer(a, offset: 0, index: 0); enc.setBuffer(w, offset: 0, index: 1); enc.setBuffer(c, offset: 0, index: 2)
        var m = UInt32(M), n = UInt32(N), k = UInt32(K)
        enc.setBytes(&m, length: 4, index: 3); enc.setBytes(&n, length: 4, index: 4); enc.setBytes(&k, length: 4, index: 5)
        enc.dispatchThreadgroups(MTLSize(width: (N + nt - 1) / nt, height: (M + mt - 1) / mt, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: pso.threadExecutionWidth * sg, height: 1, depth: 1))
    }
    /// Per-dispatch GPU ms: `reps` dispatches rotating over `ws`, one command buffer, min of `trials`.
    func time(a: MTLBuffer, ws: [MTLBuffer], c: MTLBuffer, M: Int, N: Int, K: Int, reps: Int, trials: Int) -> Double {
        var best = Double.infinity
        for _ in 0 ..< trials {
            let cb = q.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder(dispatchType: .serial)!
            for r in 0 ..< reps { encode(enc, a: a, w: ws[r % ws.count], c: c, M: M, N: N, K: K) }
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(reps))
        }
        return best
    }
}

private func halfBuffer(_ dev: MTLDevice, count: Int, seed: UInt64) -> MTLBuffer {
    let b = dev.makeBuffer(length: count * 2, options: .storageModeShared)!
    let p = b.contents().bindMemory(to: Float16.self, capacity: count)
    var s = seed &* 6364136223846793005 &+ 1442695040888963407
    for i in 0 ..< count {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        p[i] = Float16(Float(Int64(bitPattern: s >> 11) % 2001 - 1000) / 4000.0)
    }
    return b
}

func runTensorMicro(_ args: [String]) {
    if #available(macOS 26.0, *) { runTensorMicro26(args) } else { print("needs macOS 26+") }
}

@available(macOS 26.0, *)
private func runTensorMicro26(_ args: [String]) {
    let mode = args.count >= 3 ? args[2] : "probe"
    guard let dev = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return }
    print("device: \(dev.name) os: \(ProcessInfo.processInfo.operatingSystemVersionString) apple10=\(dev.supportsFamily(MTLGPUFamily(rawValue: 1010) ?? .apple9))")
    if mode == "probe" {
        // tiny correctness probe: M=64,N=64,K=128
        for (mt, nt, sg) in [(64, 32, 4), (32, 32, 4), (16, 32, 4), (16, 64, 4), (8, 32, 4)] {
            guard let t = TensorMM(mt: mt, nt: nt, sg: sg, relaxed: false) else { continue }
            let M = 64, N = 64, K = 128
            let a = halfBuffer(dev, count: M * K, seed: 1), w = halfBuffer(dev, count: N * K, seed: 2)
            let c = dev.makeBuffer(length: M * N * 2, options: .storageModeShared)!
            let cb = t.q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!
            t.encode(e, a: a, w: w, c: c, M: M, N: N, K: K); e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let ap = a.contents().bindMemory(to: Float16.self, capacity: M * K)
            let wp = w.contents().bindMemory(to: Float16.self, capacity: N * K)
            let cp = c.contents().bindMemory(to: Float16.self, capacity: M * N)
            var maxErr: Float = 0
            for i in 0 ..< M { for j in 0 ..< N {
                var s: Float = 0; for k in 0 ..< K { s += Float(ap[i * K + k]) * Float(wp[j * K + k]) }
                maxErr = max(maxErr, abs(s - Float(cp[i * N + j])))
            } }
            print("PROBE mt=\(mt) nt=\(nt) sg=\(sg) status=\(cb.status.rawValue) err=\(cb.error.map { "\($0)" } ?? "none") maxAbsErr=\(maxErr) c[0]=\(cp[0])")
        }
        return
    }
    if mode == "w4a8" { runW4A8Bench(args); return }
    if mode == "int8" { runInt8Micro(dev, args); return }
    if mode == "dq" { runDQMicro(dev, args); return }
    // fp16 throughput: tensor-op vs MLX matmul on real shapes
    let Ms = args.count >= 4 ? args[3].split(separator: ",").compactMap { Int($0) } : [8, 16, 32, 1024]
    let reps = args.count >= 5 ? Int(args[4]) ?? 20 : 20
    let shapes: [(String, Int, Int)] = [("gate+up", 5120, 34816), ("down", 17408, 5120), ("attn14336", 5120, 14336), ("proj16384", 5120, 16384)]
    let configs: [(Int, Int, Int)] = [(8, 32, 4), (16, 32, 4), (16, 64, 4), (32, 32, 4), (32, 64, 4), (64, 32, 4), (64, 64, 4), (64, 128, 4), (128, 64, 4), (128, 128, 4), (64, 64, 2), (128, 64, 8), (128, 32, 4), (256, 64, 4), (64, 256, 4), (128, 64, 2), (128, 64, 16), (256, 32, 4), (256, 128, 8)]
    var kernels: [TensorMM] = []
    for c in configs { if let t = TensorMM(mt: c.0, nt: c.1, sg: c.2, relaxed: false, verbose: true) { kernels.append(t) } }
    for (name, K, N) in shapes {
        let nbuf = max(2, Int(1.2e9 / Double(K * N * 2)))
        let ws = (0 ..< nbuf).map { halfBuffer(dev, count: K * N, seed: UInt64($0 + 10)) }
        // MLX copies (share nothing; same data not needed for timing)
        let mws = (0 ..< nbuf).map { _ in MLXRandom.normal([N, K]).asType(.float16) }
        eval(mws)
        for M in Ms {
            let a = halfBuffer(dev, count: M * K, seed: 3)
            let c = dev.makeBuffer(length: M * N * 2, options: .storageModeShared)!
            let flops = 2.0 * Double(M) * Double(N) * Double(K)
            let bytes = Double(N * K * 2)
            // MLX
            let x = MLXRandom.normal([M, K]).asType(.float16); eval(x)
            var mlxBest = Double.infinity
            for trial in 0 ..< 4 {
                let t0 = Date()
                var outs: [MLXArray] = []
                for r in 0 ..< reps { outs.append(matmul(x, mws[r % nbuf].T)) }
                eval(outs)
                if trial > 0 { mlxBest = min(mlxBest, Date().timeIntervalSince(t0) * 1000 / Double(reps)) }
            }
            print(String(format: "RES %@ M=%d MLX_fp16 %.4f ms %.1f TF/s %.0f GB/s", name as NSString, M, mlxBest, flops / (mlxBest * 1e-3) / 1e12, bytes / (mlxBest * 1e-3) / 1e9))
            for t in kernels {
                if t.mt > max(M, 8) * 2 && t.mt > 64 { continue }
                _ = t.time(a: a, ws: ws, c: c, M: M, N: N, K: K, reps: 3, trials: 1)
                let ms = t.time(a: a, ws: ws, c: c, M: M, N: N, K: K, reps: reps, trials: 4)
                print(String(format: "RES %@ M=%d TENSOR mt=%d nt=%d sg=%d %.4f ms %.1f TF/s %.0f GB/s x%.2f_vs_MLX", name as NSString, M, t.mt, t.nt, t.sg, ms, flops / (ms * 1e-3) / 1e12, bytes / (ms * 1e-3) / 1e9, mlxBest / ms))
            }
        }
    }
}

// MARK: int8 vs fp16 tensor-op throughput (M=1024)

@available(macOS 26.0, *)
private func runInt8Micro(_ dev: MTLDevice, _ args: [String]) {
    let M = 1024, reps = 20
    let shapes: [(String, Int, Int)] = [("gate+up", 5120, 34816), ("down", 17408, 5120)]
    let tiles: [(Int, Int, Int)] = [(64, 64, 4), (128, 64, 4), (64, 128, 4), (128, 128, 4), (128, 128, 8), (64, 64, 2)]
    // (label, A type, W type, C type, A bytes, W bytes, C bytes)
    let types: [(String, String, String, String, Int, Int, Int)] = [
        ("fp16xfp16->fp16", "half", "half", "half", 2, 2, 2),
        ("int8xint8->int32", "int8_t", "int8_t", "int", 1, 1, 4),
        ("fp16xint8->fp16", "half", "int8_t", "half", 2, 1, 2),
    ]
    for (name, K, N) in shapes {
        for ty in types {
            let wBytes = K * N * ty.5
            let nbuf = max(2, Int(1.2e9 / Double(wBytes)))
            let ws = (0 ..< nbuf).map { i -> MTLBuffer in
                let b = dev.makeBuffer(length: wBytes, options: .storageModeShared)!
                let p = b.contents().bindMemory(to: UInt8.self, capacity: wBytes)
                var s = UInt64(i + 7) &* 6364136223846793005
                for j in stride(from: 0, to: wBytes, by: 997) { s = s &* 6364136223846793005 &+ 1442695040888963407; p[j] = UInt8(truncatingIfNeeded: s >> 40) & 0x3F }
                if ty.5 == 2 { memset(p, 0x1E, wBytes) }  // ~0.0078 fp16 pattern (0x1E1E), avoids inf/nan
                return b
            }
            let a = dev.makeBuffer(length: M * K * ty.4, options: .storageModeShared)!
            if ty.4 == 2 { memset(a.contents(), 0x1E, M * K * 2) } else { memset(a.contents(), 3, M * K) }
            let c = dev.makeBuffer(length: M * N * ty.6, options: .storageModeShared)!
            let flops = 2.0 * Double(M) * Double(N) * Double(K)
            var best = (Double.infinity, "")
            for t in tiles {
                guard let k = TensorMM(mt: t.0, nt: t.1, sg: t.2, relaxed: false, verbose: true, ta: ty.1, tw: ty.2, tc: ty.3) else { continue }
                _ = k.time(a: a, ws: ws, c: c, M: M, N: N, K: K, reps: 3, trials: 1)
                let ms = k.time(a: a, ws: ws, c: c, M: M, N: N, K: K, reps: reps, trials: 4)
                print(String(format: "INT8 %@ %@ tile=%dx%d sg=%d %.4f ms %.1f TOPS", name as NSString, ty.0 as NSString, t.0, t.1, t.2, ms, flops / (ms * 1e-3) / 1e12))
                if ms < best.0 { best = (ms, "\(t.0)x\(t.1) sg\(t.2)") }
            }
            print(String(format: "BEST %@ %@ %.4f ms %.1f TOPS (%@)", name as NSString, ty.0 as NSString, best.0, flops / (best.0 * 1e-3) / 1e12, best.1 as NSString))
        }
    }
}

// MARK: dequant-in-tile proxy (4-bit g64 affine, MLX packing) at small M

@available(macOS 26.0, *)
private func runDQMicro(_ dev: MTLDevice, _ args: [String]) {
    let K = 5120, N = 34816
    let Ms = args.count >= 4 ? args[3].split(separator: ",").compactMap { Int($0) } : [8, 16]
    let nbuf = 8, reps = 24
    let w = MLXRandom.normal([N, K]).asType(.float16)
    let (wq0, sc0, bi0) = quantized(w, groupSize: 64, bits: 4)
    let bi1 = bi0!
    eval(wq0, sc0, bi1)
    // distinct MLX copies for rotation
    var qs: [(MLXArray, MLXArray, MLXArray)] = []
    for i in 0 ..< nbuf {
        let d = MLXArray(Int32(i)).asType(.uint32) * MLXArray(UInt32(0))
        qs.append((wq0 + d, sc0 + MLXArray(Float16(0)), bi1 + MLXArray(Float16(0))))
    }
    for q in qs { eval(q.0, q.1, q.2) }
    func buf(_ a: MLXArray) -> MTLBuffer {
        let raw = a.asData(access: .noCopy)
        return raw.data.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: raw.data.count, options: .storageModeShared)! }
    }
    let wb = qs.map { buf($0.0) }, sb = qs.map { buf($0.1) }, bb = qs.map { buf($0.2) }
    print("packed: w \(wq0.shape) \(wq0.dtype) scales \(sc0.shape) \(sc0.dtype)")
    let bytes = Double(N * K) * (0.5 + 4.0 / 64.0)
    let q = dev.makeCommandQueue()!
    for M in Ms {
        let x = MLXRandom.normal([M, K]).asType(.float16); eval(x)
        // MLX chained-serial: x_{i+1} = (x_i @ W_i)[:, :K]
        var mlxBest = Double.infinity
        for trial in 0 ..< 5 {
            var cur = x
            let t0 = Date()
            for r in 0 ..< reps {
                let y = quantizedMatmul(cur, qs[r % nbuf].0, scales: qs[r % nbuf].1, biases: qs[r % nbuf].2, transpose: true, groupSize: 64, bits: 4)
                cur = y[0..., 0 ..< K]
            }
            eval(cur)
            if trial > 0 { mlxBest = min(mlxBest, Date().timeIntervalSince(t0) * 1000 / Double(reps)) }
        }
        print(String(format: "DQ M=%d MLX_qmm %.4f ms %.0f GB/s", M, mlxBest, bytes / (mlxBest * 1e-3) / 1e9))
        let ref = quantizedMatmul(x, qs[0].0, scales: qs[0].1, biases: qs[0].2, transpose: true, groupSize: 64, bits: 4)
        eval(ref)
        let xb = buf(x)
        let cb = dev.makeBuffer(length: M * N * 2, options: .storageModeShared)!
        let cfgs: [(mt: Int, nt: Int, kt: Int)] = [(16, 16, 256), (16, 16, 128), (16, 16, 512), (32, 16, 256), (16, 32, 64), (32, 32, 128), (16, 8, 256)]
        for cf in cfgs {
            let opts = MTLCompileOptions(); opts.languageVersion = .version4_0
            let src = dqSource(mt: cf.mt, nt: cf.nt, kt: cf.kt)
            guard let lib = try? { () throws -> MTLLibrary in try dev.makeLibrary(source: src, options: opts) }() else {
                do { _ = try dev.makeLibrary(source: src, options: opts) } catch { print("DQ_COMPILE_FAIL \(cf): \(error)".prefix(1500)) }
                continue
            }
            let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "dq")!)
            func enc(_ e: MTLComputeCommandEncoder, _ i: Int) {
                e.setComputePipelineState(pso)
                e.setBuffer(xb, offset: 0, index: 0); e.setBuffer(wb[i], offset: 0, index: 1); e.setBuffer(sb[i], offset: 0, index: 2)
                e.setBuffer(bb[i], offset: 0, index: 3); e.setBuffer(cb, offset: 0, index: 4)
                var m = UInt32(M), n = UInt32(N), k = UInt32(K)
                e.setBytes(&m, length: 4, index: 5); e.setBytes(&n, length: 4, index: 6); e.setBytes(&k, length: 4, index: 7)
                e.dispatchThreadgroups(MTLSize(width: N / cf.nt, height: (M + cf.mt - 1) / cf.mt, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }
            // correctness vs MLX (weights copy 0)
            do {
                let c1 = q.makeCommandBuffer()!; let e = c1.makeComputeCommandEncoder()!; enc(e, 0); e.endEncoding(); c1.commit(); c1.waitUntilCompleted()
                let p = cb.contents().bindMemory(to: Float16.self, capacity: M * N)
                let r = ref.asType(.float32).reshaped([-1]).asArray(Float.self)
                var maxAbs: Float = 0, maxRef: Float = 0
                for i in 0 ..< M * N { maxAbs = max(maxAbs, abs(Float(p[i]) - r[i])); maxRef = max(maxRef, abs(r[i])) }
                var best = Double.infinity
                for _ in 0 ..< 5 {
                    let c2 = q.makeCommandBuffer()!; let e2 = c2.makeComputeCommandEncoder(dispatchType: .serial)!
                    for rr in 0 ..< reps { enc(e2, rr % nbuf) }
                    e2.endEncoding(); c2.commit(); c2.waitUntilCompleted()
                    best = min(best, (c2.gpuEndTime - c2.gpuStartTime) * 1000 / Double(reps))
                }
                print(String(format: "DQ M=%d tile mt=%d nt=%d kt=%d %.4f ms %.0f GB/s vs_MLX x%.2f maxabs=%.4g maxref=%.4g", M, cf.mt, cf.nt, cf.kt, best, bytes / (best * 1e-3) / 1e9, mlxBest / best, maxAbs, maxRef))
            }
        }
    }
}

private func dqSource(mt: Int, nt: Int, kt: Int) -> String {
    """
    #include <metal_stdlib>
    #include <metal_tensor>
    #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
    using namespace metal;
    using namespace mpp::tensor_ops;
    constant constexpr int MT = \(mt), NT = \(nt), KT = \(kt);
    kernel void dq(device half* Ap [[buffer(0)]], device const uint* Wq [[buffer(1)]],
                   device const half* Sc [[buffer(2)]], device const half* Bi [[buffer(3)]],
                   device half* Cp [[buffer(4)]],
                   constant uint& M [[buffer(5)]], constant uint& N [[buffer(6)]], constant uint& K [[buffer(7)]],
                   uint2 tgid [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
        threadgroup half Wt[NT * KT];
        auto A = tensor<device half, dextents<int32_t, 2>, tensor_inline>(Ap, dextents<int32_t, 2>((int)K, (int)M));
        auto C = tensor<device half, dextents<int32_t, 2>, tensor_inline>(Cp, dextents<int32_t, 2>((int)N, (int)M));
        auto Wtt = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(Wt, dextents<int32_t, 2>(KT, NT));
        constexpr auto desc = matmul2d_descriptor(MT, NT, KT, false, true, false, matmul2d_descriptor::mode::multiply_accumulate);
        matmul2d<desc, execution_simdgroups<4>> op;
        const int n0 = tgid.x * NT, m0 = tgid.y * MT;
        auto tA0 = A.slice(0, m0);
        auto cT = op.get_destination_cooperative_tensor<decltype(tA0), decltype(Wtt), float>();
        #pragma unroll
        for (uint16_t i = 0; i < cT.get_capacity(); ++i) { if (cT.is_valid_element(i)) cT[i] = 0; }
        const uint kw = K / 8, kg = K / 64;
        for (uint k0 = 0; k0 < K; k0 += KT) {
            for (uint idx = tid; idx < (uint)(NT * KT / 8); idx += 128) {
                const uint row = idx / (KT / 8), wc = idx % (KT / 8);
                const uint word = Wq[(n0 + row) * kw + k0 / 8 + wc];
                const uint gi = (n0 + row) * kg + (k0 + wc * 8) / 64;
                const float s = (float)Sc[gi], b = (float)Bi[gi];
                threadgroup half* dst = Wt + row * KT + wc * 8;
                #pragma unroll
                for (uint j = 0; j < 8; ++j) dst[j] = (half)(s * (float)((word >> (4 * j)) & 0xF) + b);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            auto tA = A.slice(k0, m0);
            op.run(tA, Wtt, cT);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        #pragma unroll
        for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
            if (cT.is_valid_element(i)) {
                auto ids = cT.get_multidimensional_index(i);
                const int mm = m0 + (int)ids[1];
                if (mm < (int)M) Cp[(uint)mm * N + (uint)(n0 + (int)ids[0])] = (half)cT[i];
            }
        }
    }
    """
}

// MARK: W4A8 prefill prototype speed (gate 2): int8 tensor-op on real MLX 4-bit g64 packing vs MLX qmm

private func runW4A8Bench(_ args: [String]) {
    let M = args.count >= 4 ? Int(args[3]) ?? 1024 : 1024
    let shapesAll: [(String, Int, Int)] = [("gate+up", 5120, 34816), ("down", 17408, 5120)]
    let tiles: [(Int, Int, Int)] = args.count >= 5
        ? args[4].split(separator: ",").compactMap { s -> (Int, Int, Int)? in
            let p = s.split(separator: "x").compactMap { Int($0) }; return p.count == 3 ? (p[0], p[1], p[2]) : nil }
        : [(64, 64, 4), (128, 64, 4), (64, 128, 4), (128, 128, 4), (128, 128, 8), (64, 64, 2)]
    let nbuf = 4, reps = 8
    let v = Int(ProcessInfo.processInfo.environment["STRIM_W4A8_VAR"] ?? "0") ?? 0
    for (name, K, N) in shapesAll {
        let w = MLXRandom.normal([N, K]).asType(.float16)
        let (wq0, sc0, bi0) = quantized(w, groupSize: 64, bits: 4)
        let bi1 = bi0!
        eval(wq0, sc0, bi1)
        let ws: [(MLXArray, MLXArray, MLXArray)] = (0 ..< nbuf).map { i in
            let z = MLXArray(UInt32(0)) * MLXArray(UInt32(i))
            return (wq0 + z, sc0 + MLXArray(Float16(0)), bi1 + MLXArray(Float16(0))) }
        for q in ws { eval(q.0, q.1, q.2) }
        let x = MLXRandom.normal([M, K]).asType(.float16); eval(x)
        func wall(_ f: () -> [MLXArray]) -> Double { let t0 = Date(); eval(f()); return Date().timeIntervalSince(t0) * 1000 / Double(reps) }
        func best(_ f: () -> [MLXArray]) -> Double { _ = wall(f); return (0 ..< 4).map { _ in wall(f) }.min()! }
        let mlxMs = best { (0 ..< reps).map { r in quantizedMatmul(x, ws[r % nbuf].0, scales: ws[r % nbuf].1, biases: ws[r % nbuf].2, transpose: true, groupSize: 64, bits: 4) } }
        let flops = 2.0 * Double(M) * Double(N) * Double(K)
        print(String(format: "W4A8 %@ M=%d MLX_qmm %.3f ms %.1f TF/s", name as NSString, M, mlxMs, flops / (mlxMs * 1e-3) / 1e12))
        let qOnly = best { (0 ..< reps).flatMap { _ -> [MLXArray] in let q = W4A8.quantizeActivations(x); return [q.xi, q.a, q.a2] } }
        print(String(format: "W4A8 %@ quantize_only %.3f ms", name as NSString, qOnly))
        let qa = W4A8.quantizeActivations(x); eval(qa.xi, qa.a, qa.a2)
        let ref = quantizedMatmul(x, ws[0].0, scales: ws[0].1, biases: ws[0].2, transpose: true, groupSize: 64, bits: 4).asType(.float32)
        let G = K / 64
        let xq = (qa.xi.asType(.float32).reshaped([M, G, 64]) * qa.a.reshaped([M, G, 1])).reshaped([M, K])
        let wd = dequantized(ws[0].0, scales: ws[0].1, biases: ws[0].2, groupSize: 64, bits: 4).asType(.float32)
        let ref2 = matmul(xq, wd.T)
        eval(ref, ref2)
        for t in tiles {
            let y0 = W4A8.matmul(qa, wq: ws[0].0, scales: ws[0].1, biases: ws[0].2, mt: t.0, nt: t.1, sg: t.2, variant: v).asType(.float32)
            eval(y0)
            let rn = sqrt((ref * ref).mean()).item(Float.self)
            let e1 = abs(y0 - ref).max().item(Float.self), e1m = sqrt(((y0 - ref) * (y0 - ref)).mean()).item(Float.self) / rn
            let e2 = abs(y0 - ref2).max().item(Float.self), e2m = sqrt(((y0 - ref2) * (y0 - ref2)).mean()).item(Float.self) / rn
            let mmOnly = best { (0 ..< reps).map { r in W4A8.matmul(qa, wq: ws[r % nbuf].0, scales: ws[r % nbuf].1, biases: ws[r % nbuf].2, mt: t.0, nt: t.1, sg: t.2, variant: v) } }
            let total = best { (0 ..< reps).map { r in
                let q = W4A8.quantizeActivations(x)
                return W4A8.matmul(q, wq: ws[r % nbuf].0, scales: ws[r % nbuf].1, biases: ws[r % nbuf].2, mt: t.0, nt: t.1, sg: t.2, variant: v) } }
            print(String(format: "W4A8 %@ tile=%dx%d sg=%d matmul %.3f ms  total(quant+mm) %.3f ms  = %.2fx MLX  | relRMS vs qmm %.4g (max %.3g)  vs exact-int8-ref %.4g (max %.3g)",
                         name as NSString, t.0, t.1, t.2, mmOnly, total, total / mlxMs, e1m, e1, e2m, e2))
        }
    }
}
