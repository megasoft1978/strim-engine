import Foundation
import StrimPrompt
import StrimTokenizer

// strim tokenize [--model DIR=models/qwen38-4bit] (--text FILE|- | --chat MESSAGES.json) [--max N] [--count | --json]
//
// Default: token ids on one comma-separated line. --json: {"count":N,"ids":[...]}. --count: the count only.
// --text: plain tokenization. --chat: OpenAI-style messages (an array, or {"messages":[...],"tools":[...]}) rendered
// with the chat template and tokenized as a fresh prompt. --max keeps the first N ids.
// Replaces the Python tokenizer calls in scripts/ab_bench.sh, scripts/quality_ab.sh and scripts/bench_swift.sh.

func runTokenize(_ args: [String]) {
    let usage = "usage: strim tokenize [--model DIR] (--text FILE|- | --chat MESSAGES.json) [--max N] [--count | --json]"
    func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        exit(2)
    }
    var model = "models/qwen38-4bit"
    var textPath: String?
    var chatPath: String?
    var maxIds: Int?
    var output = "line"
    var i = 2
    func next(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(flag)\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--model": model = next("--model")
        case "--text": textPath = next("--text")
        case "--chat": chatPath = next("--chat")
        case "--max":
            guard let n = Int(next("--max")), n >= 0 else { fail("bad --max\n\(usage)") }
            maxIds = n
        case "--count": output = "count"
        case "--json": output = "json"
        default: fail("unknown option \(args[i])\n\(usage)")
        }
        i += 1
    }
    guard (textPath == nil) != (chatPath == nil) else { fail(usage) }

    do {
        let tok = try Tokenizer.load(modelDir: model)
        var ids: [Int32]
        if let textPath {
            let data = textPath == "-"
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: textPath))
            guard let text = String(data: data, encoding: .utf8) else { fail("\(textPath): not valid UTF-8") }
            ids = TokenizeTool.textIds(text, tokenizer: tok)
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: chatPath!))
            guard let text = String(data: data, encoding: .utf8) else { fail("\(chatPath!): not valid UTF-8") }
            let chat = try TokenizeTool.chatInput(json: text)
            ids = try TokenizeTool.chatIds(messages: chat.messages, tools: chat.tools, tokenizer: tok)
        }
        if let maxIds { ids = Array(ids.prefix(maxIds)) }
        let list = ids.map(String.init).joined(separator: ",")
        switch output {
        case "count": print(ids.count)
        case "json": print("{\"count\":\(ids.count),\"ids\":[\(list)]}")
        default: print(list)
        }
    } catch {
        fail("error: \(error)")
    }
}
