import Foundation
import MLX
import StrimCore

extension EngineCore {
    /// Builds the per-request constraint (grammar position, reasoning budget). nil when the spec enforces
    /// nothing for this prompt, so unconstrained requests never touch the grammar machinery.
    func makeConstraint(_ spec: ConstraintSpec, startsInThink: Bool) throws -> RequestConstraint? {
        let budget = startsInThink ? spec.thinkingBudget : nil
        guard spec.hasGrammar || budget != nil else { return nil }
        if grammar == nil {
            let tok = tokenizer!
            grammar = GrammarEngine(vocabCount: tok.vocabSize, tokenBytes: { tok.bytes(for: $0) }, eos: Array(defaultStops).sorted(),
                                    skip: { id in
                                        let b = tok.bytes(for: Int32(id))
                                        return b.count >= 4 && b[0] == 0x3C && b[1] == 0x7C && b[b.count - 2] == 0x7C && b[b.count - 1] == 0x3E
                                    })
            deviceMasks = DeviceMasks()
        }
        let width = try store.tensor("language_model.lm_head.weight").shape[0]
        var rt: GrammarRuntime?
        if spec.hasGrammar {
            do { rt = try grammar!.runtime(for: spec, logitsWidth: width) }
            catch let e as GrammarError { throw EngineError.badInput(e.message) }
        }
        var closeId: Int32 = -1
        if budget != nil {
            guard let id = tokenizer.specialIds["</think>"] else { throw EngineError.badInput("thinking budget needs a </think> token") }
            closeId = id
        }
        return RequestConstraint(rt: rt, engine: grammar!, masks: deviceMasks!, width: width, budget: budget,
                                 closeId: closeId, startsInThink: startsInThink)
    }

    /// First output token from prefill logits `[V]`: sampled (position-keyed) or argmax, after the constraint mask.
    func firstToken(_ r: Request, _ logits: MLXArray) -> Int32 {
        let l = r.constraint?.apply(logits) ?? logits
        return r.sampler?.sampleFirst(l) ?? Int32(argMax(l).item(Int32.self))
    }
}
