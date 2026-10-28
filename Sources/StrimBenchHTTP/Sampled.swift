import Foundation

public struct SampledConfig: Sendable {
    public var url: String
    public var model: String
    public var label: String
    public var outPath: String
    public var n = 3
    public var tokens = 256
    public var timeout = 900.0

    public init(url: String, model: String, label: String, outPath: String) {
        self.url = url; self.model = model; self.label = label; self.outPath = outPath
    }
}

/// Sampled decode check (final_sampled.py): N identical-prompt streaming requests,
/// temp 1.0 / top_p 0.95 / top_k 20 / seed 1234. Decode tok/s = (n-1)/(t_last-t_first), n = usage.completion_tokens.
public enum Sampled {
    public static let prompt = "Write a long, technical explanation of why local transformer decoding is memory bound at batch size one, "
        + "covering weight streaming, KV cache reads, speculative decoding and quantization trade-offs."

    public static func requestBody(model: String, tokens: Int) -> Data {
        let body: JSONValue = .obj([
            "model": .string(model),
            "messages": .array([.obj(["role": "user", "content": .string(prompt)])]),
            "max_tokens": .int(tokens), "temperature": 1.0, "top_p": 0.95, "top_k": 20, "seed": 1234, "stream": true,
            "stream_options": .obj(["include_usage": true]), "ignore_eos": true,
            "chat_template_kwargs": .obj(["enable_thinking": false]),
        ])
        return Data(JSON.dumps(body).utf8)
    }

    /// Row (key order identical to final_sampled.py) from a finished stream.
    public static func row(label: String, index: Int, tokens: Int, result res: StreamResult) -> JSONValue {
        let usage = res.usage ?? .null
        var n: Int?
        if case .int(let c) = usage["completion_tokens"] { n = c }
        var promptTokens: JSONValue = .null
        if case .int = usage["prompt_tokens"] { promptTokens = usage["prompt_tokens"] }
        var cached: JSONValue = .null
        let det = usage["prompt_tokens_details"]
        if det.truthy { cached = det["cached_tokens"] }
        var decode: Double?, ttft: Double?
        if let n, n != 0, let tf = res.tFirst, let tl = res.tLast, tf != 0, tl != 0, tl > tf, n >= 2 {
            decode = Double(n - 1) / (tl - tf)
            ttft = tf - res.tSend
        }
        let flag: String
        if let n { flag = n == tokens ? "ok" : (n < tokens ? "short" : "mismatch") } else { flag = "no_usage" }
        return .obj([
            "label": .string(label), "i": .int(index), "t_first": JSONValue(res.tFirst), "t_last": JSONValue(res.tLast),
            "usage": res.usage ?? .null, "error": JSONValue(res.error),
            "completion_tokens": JSONValue(n), "prompt_tokens": promptTokens, "cached_tokens": cached,
            "decode_tps": JSONValue(decode), "ttft_s": JSONValue(ttft), "tokens_flag": .string(flag),
            "text_head": .string(String(String.UnicodeScalarView(res.text.unicodeScalars.prefix(120)))),
        ])
    }

    /// Runs the requests sequentially and appends the rows to `outPath`. Returns the rows.
    @discardableResult
    public static func run(cfg: SampledConfig, log: LogSink) async throws -> [JSONValue] {
        var rows: [JSONValue] = []
        for i in 0 ..< cfg.n {
            let res = await ChatStreamer.post(url: chatEndpoint(cfg.url), body: requestBody(model: cfg.model, tokens: cfg.tokens),
                                              timeout: cfg.timeout, pieceKeys: PieceKeys.scoreboard, noOutputMessage: nil)
            rows.append(row(label: cfg.label, index: i, tokens: cfg.tokens, result: res))
        }
        try FileManager.default.createDirectory(atPath: (cfg.outPath as NSString).deletingLastPathComponent.isEmpty ? "." : (cfg.outPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: cfg.outPath) { FileManager.default.createFile(atPath: cfg.outPath, contents: nil) }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: cfg.outPath))
        defer { try? h.close() }
        try h.seekToEnd()
        for r in rows { h.write(Data((JSON.dumps(r) + "\n").utf8)) }
        for r in rows {
            let d = r["decode_tps"].double.map { pyFloatRepr(($0 * 100).rounded() / 100) } ?? "None"
            log("\(cfg.label) \(pyStr(r["i"])) n \(pyStr(r["completion_tokens"])) \(pyStr(r["tokens_flag"])) decode_tps \(d) err \(pyStr(r["error"]))")
        }
        return rows
    }
}
