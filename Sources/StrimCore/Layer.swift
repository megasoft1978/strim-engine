import Foundation
import MLX

/// Elementwise chains as compiled pure functions (f32 math inside, no captured state).
/// STRIM_NO_COMPILE_ELEMENTWISE=1 restores the eager path for A/B.
public enum Fused {
    nonisolated(unsafe) public static let enabled =
        ProcessInfo.processInfo.environment["STRIM_NO_COMPILE_ELEMENTWISE"] != "1"

    static func swigluEager(_ gate: MLXArray, _ up: MLXArray) -> MLXArray {
        let g = gate.asType(.float32)
        return (g * sigmoid(g) * up.asType(.float32)).asType(gate.dtype)
    }
    static func gatedEager(_ z: MLXArray, _ normed: MLXArray) -> MLXArray {
        let g = z.asType(.float32)
        return (g * sigmoid(g) * normed.asType(.float32)).asType(z.dtype)
    }
    static func attnGateEager(_ flat: MLXArray, _ gate: MLXArray) -> MLXArray {
        (flat.asType(.float32) * sigmoid(gate.asType(.float32))).asType(flat.dtype)
    }
    static func betaGEager(_ b: MLXArray, _ a: MLXArray, _ aLog: MLXArray, _ dtBias: MLXArray) -> [MLXArray] {
        let softplus = log(1 + exp(a.asType(.float32) + dtBias))
        return [sigmoid(b), exp(-exp(aLog) * softplus)]
    }

    nonisolated(unsafe) static let swigluC: (MLXArray, MLXArray) -> MLXArray =
        compile(shapeless: true) { swigluEager($0, $1) }
    nonisolated(unsafe) static let gatedC: (MLXArray, MLXArray) -> MLXArray =
        compile(shapeless: true) { gatedEager($0, $1) }
    nonisolated(unsafe) static let attnGateC: (MLXArray, MLXArray) -> MLXArray =
        compile(shapeless: true) { attnGateEager($0, $1) }
    nonisolated(unsafe) static let betaGC: ([MLXArray]) -> [MLXArray] =
        compile(shapeless: true) { betaGEager($0[0], $0[1], $0[2], $0[3]) }

    /// silu(gate) * up in f32, cast back to gate dtype.
    public static func swiglu(_ gate: MLXArray, _ up: MLXArray) -> MLXArray {
        enabled ? swigluC(gate, up) : swigluEager(gate, up)
    }
    /// silu(z) * normed in f32, cast back to z dtype (GDN gated norm).
    public static func gatedNorm(_ z: MLXArray, _ normed: MLXArray) -> MLXArray {
        enabled ? gatedC(z, normed) : gatedEager(z, normed)
    }
    /// flat * sigmoid(gate) in f32, cast back to flat dtype (attention output gate).
    public static func attnGate(_ flat: MLXArray, _ gate: MLXArray) -> MLXArray {
        enabled ? attnGateC(flat, gate) : attnGateEager(flat, gate)
    }
    /// (beta, g) from b/a projections; aLog and dtBias are f32.
    public static func betaG(_ b: MLXArray, _ a: MLXArray, aLog: MLXArray, dtBias: MLXArray) -> (MLXArray, MLXArray) {
        let r = enabled ? betaGC([b, a, aLog, dtBias]) : betaGEager(b, a, aLog, dtBias)
        return (r[0], r[1])
    }
}

public enum MLP {
    static func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

    /// SwiGLU: down(silu(gate(x)) * up(x)), with gate and up as one fused qmv.
    public static func forward(_ x: MLXArray, store: WeightStore, layer: Int) throws -> MLXArray {
        let f = try store.mlpFused(layer)
        let all = store.qmm(x, f.w, f.s, f.b)
        let inter = all.shape[all.ndim - 1] / 2
        let gate = all[0..., 0..., 0 ..< inter]
        let up = all[0..., 0..., inter ..< (2 * inter)]
        let act = Fused.swiglu(gate, up)
        return try store.linear("language_model.model.layers.\(layer).mlp.down_proj", act)
    }

    public static func forward(_ x: MLXArray, store: WeightStore, prefix: String) throws -> MLXArray {
        let gate = try store.linear(prefix + "gate_proj", x)
        let up = try store.linear(prefix + "up_proj", x)
        let act = Fused.swiglu(gate, up)
        return try store.linear(prefix + "down_proj", act)
    }
}

public enum DecoderLayer {
    /// One full transformer layer: pre-norm attention/GDN + residual, pre-norm MLP + residual.
    public static func forward(_ x: MLXArray, store: WeightStore, layer: Int, cache: ModelCache? = nil) throws -> MLXArray {
        let p = "language_model.model.layers.\(layer)."
        let n1 = try store.rmsNorm(p + "input_layernorm", x)
        // Layer 0/1/2 are GDN (full_attention_interval = 4); 3 is gated attention.
        let mixed: MLXArray
        if (layer + 1) % 4 != 0 {
            mixed = try GDN.forward(n1, store: store, layer: layer, state: cache?.gdnState(layer))
        } else {
            mixed = try Attention.forward(n1, store: store, layer: layer, cache: cache?.attentionCache(layer))
        }
        let h = x + mixed
        let n2 = try store.rmsNorm(p + "post_attention_layernorm", h)
        let mlp = try MLP.forward(n2, store: store, layer: layer)
        return h + mlp
    }
}
