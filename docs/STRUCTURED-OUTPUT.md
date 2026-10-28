# Structured output, forced tool calls, thinking budget

Constrained decoding in the Swift sampler. Unconstrained requests take the old code path unchanged (no mask, no grammar object; `GenParams.constraint == nil`).

## Request fields (OpenAI Chat; Responses and Messages adapters translate into these)

| Field | Behaviour |
|---|---|
| `response_format: {"type":"json_object"}` | Output is one JSON object. |
| `response_format: {"type":"json_schema","json_schema":{"schema":{...}}}` | Output matches the schema. Responses: `text.format {type:"json_schema",schema}`. Messages: `output_config.format {type:"json_schema",schema}`. |
| `tool_choice: "required"` or `{"type":"function","function":{"name":N}}` | Output is one or more Qwen tool calls (`<tool_call>\n<function=NAME>\n<parameter=K>\nV\n</parameter>\n</function>\n</tool_call>`), name and parameters validated against the declared tools. Responses: `{"type":"function","name":N}`. Messages: `{"type":"any"}` / `{"type":"tool","name":N}`. |
| `tool_choice: "none"` | Tools are hidden from the prompt (unchanged). `auto` is unchanged; `auto` + `response_format` allows either the JSON document or a tool call. |
| `parallel_tool_calls: false` (Messages: `disable_parallel_tool_use`) | Exactly one forced call. |
| `thinking_budget` (alias `thinking_token_budget`, `chat_template_kwargs.thinking_budget`; Messages: `thinking.budget_tokens`) | Max reasoning tokens. When reached the engine forces `</think>`; the answer (and any grammar) follows. No effect when the prompt does not open a think block. |

## Supported JSON Schema subset

`type` (string, number, integer, boolean, null, object, array, or a list), `properties`, `required`, `additionalProperties` (default false when `properties` is present; a schema or `true` only for free-form maps without `properties`), `items`, `minItems`, `maxItems` (<= 1000), `enum`, `const`, `anyOf`, `nullable`, local `$ref` (`#`, `#/$defs/N`, `#/definitions/N`, recursion allowed). Annotations (`title`, `description`, `default`, `examples`, ...) are ignored. Anything else (`pattern`, `format`, `minimum`, `minLength`, `oneOf`, `allOf`, `not`, `patternProperties`, ...) is a 400 naming the keyword. Object members are emitted in declared order; optional ones may be skipped. JSON whitespace runs are bounded (10 bytes).

Tool parameter schemas are lenient: value-narrowing keywords are not enforced (the model still sees them) and `oneOf` is read as `anyOf`.

## Implementation

- `GrammarProgram`: schema/tool declaration to a byte-level pushdown grammar (pure, no tokenizer; used for 400 validation).
- `GrammarDFA`: set-of-stacks states interned to ids, memoized byte transitions.
- `GrammarVocab`/`GrammarRuntime`: byte trie of the vocabulary, built on the first constrained request; a token mask per DFA state is a bitset (31 KB at 248k vocab), computed lazily by a trie walk and cached (32 MB budget, 16 programs). Control tokens (`<|...|>`) are excluded; end-of-turn is allowed only in accepting states.
- Device side: the bitset expands to a bool array (LRU of 24 on device) and logits become `where(mask, logits, -inf)`.
- MTP: `SpecStream.constraint` supplies `[k+1, V]` masks for the verify rows computed from the host-side draft ids; a draft outside its row's mask can never equal the masked argmax (greedy) or has zero probability (sampled), so it is rejected exactly. Drafts themselves are not masked.
- Batched decode: constrained rows are masked before the per-row pick.
- Memory: vocab trie ~15 MB plus masks (<= 32 MB), only after the first constrained request.

## Limits

A schema that allows unbounded text can still run to `max_tokens` (`finish_reason: "length"`, output then incomplete). Raw string tool parameters accept any valid UTF-8 up to the parameter terminator.
