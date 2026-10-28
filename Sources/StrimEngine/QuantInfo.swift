import Foundation
import StrimCore

/// Quantization identity of a loaded model (+ optional MTP head), for /v1/strim/status.
public enum QuantInfo {
    /// "<model quant hash>/<head quant hash>": hash of the global spec and every per-module override of
    /// each config.json `quantization` block ("none" if absent, "-" if there is no head).
    public static func fingerprint(modelDir: String, headDir: String?) -> String {
        QuantConfig.fingerprint(modelDir: modelDir, headDir: headDir)
    }
}
