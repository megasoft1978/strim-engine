// Frozen golden: the Ollama Modelfile TEMPLATE exactly as it was in bench/final_run.py (OLLAMA_TEMPLATE)
// when the Python benchmark drivers were removed. Do not edit to make a test pass.
enum Goldens {
    static let ollamaTemplate = #"""
    {{- range .Messages }}
    {{- if eq .Role "user" }}<|im_start|>user
    {{ .Content }}<|im_end|>
    {{ else if eq .Role "assistant" }}<|im_start|>assistant
    {{ .Content }}{{ range .ToolCalls }}
    <tool_call>
    {"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
    </tool_call>{{ end }}<|im_end|>
    {{ else if eq .Role "tool" }}<|im_start|>user
    <tool_response>
    {{ .Content }}
    </tool_response><|im_end|>
    {{ else }}<|im_start|>{{ .Role }}
    {{ .Content }}<|im_end|>
    {{ end }}{{ end }}<|im_start|>assistant
    <think>

    </think>


    """#
}
