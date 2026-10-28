import Foundation

/// Port of bench/needle.py: needle-in-a-haystack long-context check, sent to an OpenAI-compatible chat endpoint.
/// Haystack = the seed (bench/prompt_seed.txt) tokens repeated and cut so the whole prompt is `ctx` tokens; the needle
/// sentence goes in at 70% of the haystack and the question is appended. PASS when the answer contains the code.
public enum Needle {
    public static let code = "ZX-4417"
    public static let needleText = "\nIMPORTANT: the deploy code is ZX-4417. Remember it.\n"
    public static let questionText = "\n\nQuestion: What is the deploy code? Answer with the code only.\nAnswer:"
    public static let depth = 0.7
    public static let maxTokens = 24
    public static let defaultLengths = [16384, 65536]

    public struct Config: Sendable {
        public var url: String
        public var model: String
        public var tokenizerPath: String
        public var seedPath: String
        public var outDir: String
        public var tokenFile: String?
        public var lengths = Needle.defaultLengths
        public var reps = 1
        public var timeout = 900.0
    }

    public struct Run: Sendable, Equatable {
        public var ctx: Int
        public var rep: Int
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var answer = ""
        public var elapsed = 0.0
        public var error: String?

        public init(ctx: Int, rep: Int) { self.ctx = ctx; self.rep = rep }

        public var pass: Bool { error == nil && Needle.passes(answer) }
    }

    public struct Summary: Equatable, Sendable {
        public struct Length: Equatable, Sendable {
            public var ctx: Int
            public var runs: Int
            public var passes: Int
        }
        public var lengths: [Length]
        public var runs: Int
        public var passes: Int
        public var allPass: Bool { runs > 0 && passes == runs }
    }

    /// Token-exact prompt of `ctx` tokens, built as needle.py does: seed tokens repeated, cut to `ctx - needle - question`,
    /// needle tokens inserted at `Int(len * 0.7)`, question tokens appended, then decoded.
    public static func buildPrompt(seed: String, ctx: Int, tokenizer: TextTokenizer) throws -> String {
        let ids = tokenizer.encode(seed)
        let needle = tokenizer.encode(needleText)
        let question = tokenizer.encode(questionText)
        let room = ctx - needle.count - question.count
        guard room > 0 else { throw BenchError("needle: ctx \(ctx) is too small for the needle and question (\(needle.count + question.count) tokens)") }
        guard !ids.isEmpty else { throw BenchError("needle: the seed encodes to no tokens") }
        var body: [Int] = []
        body.reserveCapacity(room + ids.count)
        while body.count < room { body += ids }
        body = Array(body.prefix(room))
        let pos = Int(Double(body.count) * depth)
        return tokenizer.decode(Array(body[..<pos]) + needle + Array(body[pos...]) + question)
    }

    /// needle.py: `"ZX-4417" in body_out` (case-sensitive substring of the answer text).
    public static func passes(_ answer: String) -> Bool { answer.contains(code) }

    public static func requestBody(prompt: String, model: String) -> Data {
        let body: JSONValue = .obj([
            "model": .string(model),
            "messages": .array([.obj(["role": "user", "content": .string(prompt)])]),
            "max_tokens": .int(maxTokens), "temperature": 0.0, "stream": false,
            "chat_template_kwargs": .obj(["enable_thinking": false]),
        ])
        return Data(JSON.dumps(body).utf8)
    }

    /// Answer text and usage from a non-streaming chat completion. A null content counts as an empty answer.
    public static func parseResponse(_ data: Data) throws -> (answer: String, promptTokens: Int?, completionTokens: Int?) {
        let v = try JSON.parse(data)
        let message = v["choices"].array?.first?["message"] ?? .null
        guard let answer = message["content"].string ?? (message["content"].isNull ? "" : nil) else {
            throw BenchError("needle: response has no choices[0].message.content")
        }
        return (answer, v["usage"]["prompt_tokens"].int, v["usage"]["completion_tokens"].int)
    }

    public static func send(prompt: String, url: String, model: String, token: String?, timeout: Double) async throws
        -> (answer: String, promptTokens: Int?, completionTokens: Int?)
    {
        guard let u = URL(string: chatEndpoint(url)) else { throw BenchError("needle: bad --url \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = requestBody(prompt: prompt, model: model)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await ChatStreamer.session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw BenchError("HTTP Error \(http.statusCode): \(httpReasonPhrase(http.statusCode))")
        }
        return try parseResponse(data)
    }

    /// Runs every (length, rep) in order, sequentially. A failed request is recorded on its run and the run continues.
    public static func execute(_ cfg: Config, tokenizer: TextTokenizer, token: String?, log: LogSink) async throws -> [Run] {
        let seed = try String(contentsOfFile: cfg.seedPath, encoding: .utf8)
        var runs: [Run] = []
        for ctx in cfg.lengths {
            let prompt = try buildPrompt(seed: seed, ctx: ctx, tokenizer: tokenizer)
            for rep in 1 ... cfg.reps {
                var run = Run(ctx: ctx, rep: rep)
                let start = monotonicSeconds()
                do {
                    let r = try await send(prompt: prompt, url: cfg.url, model: cfg.model, token: token, timeout: cfg.timeout)
                    run.answer = r.answer
                    run.promptTokens = r.promptTokens
                    run.completionTokens = r.completionTokens
                } catch {
                    run.error = "\(error)"
                }
                run.elapsed = monotonicSeconds() - start
                let tokens = run.promptTokens.map(String.init) ?? "None"
                log("ctx \(ctx) rep \(rep) \(run.pass ? "PASS" : "FAIL") prompt_tokens \(tokens) elapsed \(String(format: "%.1f", run.elapsed))s"
                    + (run.error.map { " error \($0)" } ?? ""))
                runs.append(run)
            }
        }
        return runs
    }

    public static func summarize(_ runs: [Run]) -> Summary {
        var order: [Int] = []
        for r in runs where !order.contains(r.ctx) { order.append(r.ctx) }
        let lengths = order.map { ctx -> Summary.Length in
            let mine = runs.filter { $0.ctx == ctx }
            return Summary.Length(ctx: ctx, runs: mine.count, passes: mine.filter(\.pass).count)
        }
        return Summary(lengths: lengths, runs: runs.count, passes: runs.filter(\.pass).count)
    }

    public static func resultsJSON(_ cfg: Config, runs: [Run], summary s: Summary) -> JSONValue {
        let meta: JSONValue = .obj([
            "generated_by": "strim bench http needle",
            "endpoint": .string(chatEndpoint(cfg.url)), "model": .string(cfg.model),
            "tokenizer": .string(cfg.tokenizerPath), "seed": .string(cfg.seedPath),
            "token_file": JSONValue(cfg.tokenFile), "needle": .string(code), "depth": .double(depth),
            "max_tokens": .int(maxTokens), "temperature": 0.0, "reps": .int(cfg.reps),
            "lengths": .array(cfg.lengths.map { JSONValue.int($0) }),
        ])
        let summary: JSONValue = .obj([
            "runs": .int(s.runs), "passes": .int(s.passes), "all_pass": .bool(s.allPass),
            "lengths": .array(s.lengths.map { .obj(["ctx": .int($0.ctx), "runs": .int($0.runs), "passes": .int($0.passes)]) }),
        ])
        let rows: JSONValue = .array(runs.map { r -> JSONValue in
            .obj([
                "ctx": .int(r.ctx), "rep": .int(r.rep), "pass": .bool(r.pass),
                "prompt_tokens": JSONValue(r.promptTokens), "completion_tokens": JSONValue(r.completionTokens),
                "answer": .string(r.answer), "elapsed_s": .double(r.elapsed), "error": JSONValue(r.error),
            ])
        })
        return .obj(["meta": meta, "summary": summary, "runs": rows])
    }

    public static func markdown(_ cfg: Config, runs: [Run], summary s: Summary) -> String {
        func cell(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            return flat.count > 80 ? String(flat.prefix(80)) + "..." : flat
        }
        var out = "# Needle-in-a-haystack (strim bench http needle)\n\n"
        out += "- endpoint: `\(chatEndpoint(cfg.url))`, model: `\(cfg.model)`\n"
        out += "- tokenizer: `\(cfg.tokenizerPath)`, seed: `\(cfg.seedPath)`\n"
        out += "- needle `\(Needle.code)` at depth \(pyFloatRepr(depth)) of the haystack, max_tokens \(maxTokens), temperature 0\n"
        out += "- result: **\(s.passes)/\(s.runs) PASS**\n\n"
        out += "| ctx | runs | pass |\n|---:|---:|---:|\n"
        for l in s.lengths { out += "| \(l.ctx) | \(l.runs) | \(l.passes)/\(l.runs) |\n" }
        out += "\n## Runs\n\n| ctx | rep | result | prompt tokens | answer | elapsed s | error |\n"
        out += "|---:|---:|---|---:|---|---:|---|\n"
        for r in runs {
            out += "| \(r.ctx) | \(r.rep) | \(r.pass ? "PASS" : "FAIL") | \(r.promptTokens.map(String.init) ?? "") | "
            out += "\(cell(r.answer)) | \(String(format: "%.1f", r.elapsed)) | \(r.error.map(cell) ?? "") |\n"
        }
        return out
    }

    public static func writeOutputs(_ cfg: Config, runs: [Run]) throws -> Summary {
        let s = summarize(runs)
        try FileManager.default.createDirectory(atPath: cfg.outDir, withIntermediateDirectories: true)
        try (JSON.dumps(resultsJSON(cfg, runs: runs, summary: s), indent: 2) + "\n")
            .write(toFile: cfg.outDir + "/results.json", atomically: false, encoding: .utf8)
        try markdown(cfg, runs: runs, summary: s).write(toFile: cfg.outDir + "/summary.md", atomically: false, encoding: .utf8)
        return s
    }
}

extension BenchHTTPCLI {
    /// `strim bench http needle --url URL --model M --tokenizer PATH [...]`. Exit 0 when every run passes, 1 otherwise.
    static func cmdNeedle(_ args: [String], factory: TokenizerFactory?, cwd: String, log: LogSink) async throws -> Int32 {
        let o = try Opts(args, valued: ["url", "model", "tokenizer", "lengths", "reps", "seed", "token-file", "out", "timeout"])
        func abs(_ p: String) -> String { URL(fileURLWithPath: p, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path }
        guard let url = o.one("url") else { throw BenchError("needle: --url is required") }
        guard let model = o.one("model") else { throw BenchError("needle: --model is required") }
        guard let tokenizer = o.one("tokenizer") else { throw BenchError("needle: --tokenizer is required (prompt lengths are token-exact)") }
        var cfg = Needle.Config(url: url, model: model, tokenizerPath: abs(tokenizer), seedPath: abs(o.one("seed") ?? "bench/prompt_seed.txt"),
                                outDir: abs(o.one("out") ?? "bench/results/needle-\(timestamp())"))
        cfg.lengths = try o.ints("lengths") ?? Needle.defaultLengths
        if let v = try o.int("reps") { cfg.reps = v }
        if let v = try o.double("timeout") { cfg.timeout = v }
        if let f = o.one("token-file") { cfg.tokenFile = abs(f) }
        guard cfg.reps >= 1, !cfg.lengths.isEmpty, cfg.lengths.allSatisfy({ $0 > 0 }) else {
            throw BenchError("needle: --reps must be >= 1 and --lengths positive")
        }
        var token: String?
        if let f = cfg.tokenFile {
            let t = try String(contentsOfFile: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw BenchError("needle: --token-file \(f) is empty") }
            token = t
        }
        guard let factory else { throw BenchError("needle: no tokenizer backend linked") }
        let tok: TextTokenizer
        do {
            var dir = cfg.tokenizerPath
            if dir.hasSuffix("tokenizer.json") { dir = (dir as NSString).deletingLastPathComponent }
            tok = try factory(dir)
        } catch {
            throw BenchError("needle: cannot load tokenizer \(cfg.tokenizerPath): \(error)")
        }
        let runs = try await Needle.execute(cfg, tokenizer: tok, token: token, log: log)
        let s = try Needle.writeOutputs(cfg, runs: runs)
        print("wrote \(cfg.outDir)/results.json and \(cfg.outDir)/summary.md")
        print("needle: \(s.passes)/\(s.runs) PASS")
        return s.allPass ? 0 : 1
    }
}
