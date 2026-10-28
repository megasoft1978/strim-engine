import Foundation
import MLX

/// Per-step token constraint for speculative decoding (structured output, forced tool calls, thinking
/// budget). The owner tracks the grammar state after every token it has emitted; `SpecStream` asks for
/// the masks of the k+1 rows of one verify pass.
public protocol VerifyConstraint: AnyObject {
    /// `[drafts.count + 1, V]` bool mask (true = allowed). Row i constrains the token decided after the
    /// pending token and `drafts[0 ..< i]`. nil when no row is constrained. Rows after the first draft that
    /// violates its mask are never used by the accept rule.
    func verifyMask(drafts: [Int32]) -> MLXArray?
}

/// Logits with disallowed tokens at -inf (float32). `mask` broadcasts against `logits`.
public func maskLogits(_ logits: MLXArray, _ mask: MLXArray) -> MLXArray {
    MLX.where(mask, logits.asType(.float32), MLXArray(-Float.infinity))
}
