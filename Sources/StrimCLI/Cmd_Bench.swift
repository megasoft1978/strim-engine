import Foundation
import StrimBenchHTTP
import StrimTokenizer

/// `strim bench http <run|scoreboard|replay|sampled|aggregate|report|all|engines>`: the HTTP benchmark harness
/// (docs/BENCH.md). args is the full argv (args[1] == "bench").
enum BenchCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        guard args.count >= 3, args[2] == "http" else {
            FileHandle.standardError.write(Data("usage: strim bench http <subcommand> ...\n\(BenchHTTPCLI.usage)\n".utf8))
            return 2
        }
        let factory: TokenizerFactory = { dir in BenchTokenizer(try Tokenizer.load(modelDir: dir)) }
        do {
            return try await BenchHTTPCLI.run(Array(args.dropFirst(3)), tokenizerFactory: factory)
        } catch let e as BenchError {
            FileHandle.standardError.write(Data("error: \(e)\n".utf8))
            return 2
        }
    }
}

/// StrimTokenizer behind the bench harness's prompt-sizing interface (no `tokenizers` Python package needed).
private struct BenchTokenizer: TextTokenizer {
    let tok: Tokenizer
    init(_ t: Tokenizer) { tok = t }
    func encode(_ text: String) -> [Int] { tok.encode(text).map { Int($0) } }
    func decode(_ ids: [Int]) -> String { tok.decode(ids.map { Int32($0) }) }
}
