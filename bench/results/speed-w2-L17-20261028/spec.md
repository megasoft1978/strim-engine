# Ternary-Bonsai-2-27B-mlx-2bit: rotation spec (derived from config.json, hadamard.json, safetensors header, card text; no vendor Python read or run)

Gate 1 verdict: PASS. The transform is fully defined by data in the pack.

## Files (prism-ml/Ternary-Bonsai-2-27B-mlx-2bit, Apache-2.0)
- model.safetensors 8,595,477,990 B, single shard, no index (we write model.safetensors.index.json from the header; vision_tower.* excluded from the map). Not separable by download (one file); the 0.92 GB tower is simply never touched.
- config.json: model_type prism_hadamard_qwen35, text_config = qwen3_5_text (hidden 5120, 64 layers, full_attention_interval 4, 24/4 heads, head_dim 256, vocab 248320, mtp_num_hidden_layers 0, tie_word_embeddings false), quantization {bits 2, group_size 128, mode affine} (global only, no per-module overrides), gdn_activation_layout "grouped", `modules` (402 entries: path, block 1024, embedding flag, dtype float16).
- hadamard.json (version 1): transform "normalized-sylvester-walsh-hadamard", axis "input-last-dimension", block_size 1024, sign_mode "explicit", sign_widths [5120, 6144, 17408], sign_values (28672 floats, +-1, concatenated per width), weight_names (401 `.weight` names), inverse_weight_names [language_model.model.embed_tokens.weight], gdn_v_grouped true.

## Rotated tensors (401 + 1 embedding)
lm_head; per layer mlp gate/up/down; linear_attn in_proj_qkv, in_proj_z, out_proj (48 layers); self_attn q/k/v/o (16 layers). NOT rotated: in_proj_a / in_proj_b (dense F32 [48,5120]), conv1d, A_log, dt_bias, all norms (F32), q_norm/k_norm.
Every rotated projection also stores its own `<module>.signs` F32 tensor ([5120], [6144] for out_proj/o_proj, [17408] for down_proj); load check compares each against hadamard.json (identical per width).

## Runtime rule
- Linear: y = qmm(T(x), W'), T(x) = H_1024-blockwise(x * s) over the last axis (K/1024 blocks: 5, 6, 17), H = Sylvester (natural order) / sqrt(1024) = scale 2^-5.
- Embedding: stored rows are rotated; original row = T^-1(row) = s * H(row) (H symmetric, involutive). embed_tokens width 5120 uses the 5120 sign vector.
- lm_head: rotated like any linear (input = final-norm output).
- Order H(x*s) vs s*H(x): the card says only "matching transform"; resolved empirically (see results.md, `bonsaispike nll`).
- Quant: affine 2-bit g128, ternary levels as codes {0,1,2} -> {-s,0,+s} (bias = -scale). lm_head and embed are quantized too (no fp16 escape). All other floats F32 in file; activations run in float16 (card dtype); we cast F32 non-sign tensors to f16 at shard load.
- GDN: weights are already in "grouped" layout; no permutation applied by us (engine layout for the 4-bit model has identical shapes; confirmed by coherence in results).
- MTP: none.

## Implementation (spike)
Sources/StrimCore/Hadamard.swift (`Hadamard`, `ActivationRotation`), 4 small hooks in Weights.swift (`rotation`, `qmm` input transform keyed on K, embedding inverse, draft vocab off, F32 cast). Transform = f32 multiply + MLX `hadamardTransform` on [.., K/1024, 1024] + cast back.
