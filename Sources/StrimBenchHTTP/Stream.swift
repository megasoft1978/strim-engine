import Foundation

/// Seconds on the same monotonic clock as Python's `time.perf_counter()` on macOS.
public func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

public func chatEndpoint(_ url: String) -> String {
    var u = url
    while u.hasSuffix("/") { u.removeLast() }
    return u.hasSuffix("/chat/completions") ? u : u + "/v1/chat/completions"
}

/// Delta fields that count as output, in priority order.
public enum PieceKeys {
    /// scoreboard.py / final_sampled.py: reasoning deltas count as output (same semantics as screen.py).
    public static let scoreboard = ["content", "reasoning_content", "reasoning"]
    /// final_replay.py: the first output chunk may also be reasoning or tool_calls.
    public static let replay = ["content", "reasoning_content", "reasoning", "tool_calls"]
    /// agent_replay.py as written: delta.content only.
    public static let classic = ["content"]
}

public struct StreamResult: Sendable, Equatable {
    public var tSend: Double
    public var tFirst: Double?
    public var tLast: Double?
    public var tEnd: Double?
    public var chunks = 0
    public var reasoningChunks = 0
    public var text = ""
    public var usage: JSONValue?
    public var error: String?
    public var firstKind: String?

    public init(tSend: Double) { self.tSend = tSend }
}

/// Incremental SSE reader for OpenAI-style chat streams. Feed it decoded lines with the
/// timestamp at which each line was received; it keeps timing, usage and text exactly as the
/// Python harness did. Pure, so TTFT/decode math is testable on hand-made traces.
public struct SSEParser: Sendable {
    public let pieceKeys: [String]
    public private(set) var result: StreamResult

    public init(tSend: Double, pieceKeys: [String]) {
        self.pieceKeys = pieceKeys
        self.result = StreamResult(tSend: tSend)
    }

    /// Returns true when `[DONE]` was seen. Throws on a data line that is not valid JSON (the
    /// Python tools turned that into a row error and kept the partial timing).
    public mutating func feed(line raw: String, at now: Double) throws -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return true }
        let obj: JSONValue
        do { obj = try JSON.parse(payload) } catch {
            throw StreamError.jsonDecode("\(error)")
        }
        guard case .object = obj else { throw StreamError.attribute }
        let usage = obj["usage"]
        if usage.truthy { result.usage = usage }
        let choices = obj["choices"]
        for ch in choices.array ?? [] {
            let d = ch["delta"]
            guard let kind = pieceKeys.first(where: { d[$0].truthy }) else { continue }
            if result.tFirst == nil {
                result.tFirst = now
                result.firstKind = kind
            }
            result.tLast = now
            result.chunks += 1
            if kind != "content" { result.reasoningChunks += 1 }
            if let s = d[kind].string { result.text += s }
        }
        return false
    }

    public mutating func finish(error: String?, noOutputMessage: String?, at now: Double) -> StreamResult {
        if let error {
            result.error = error
        } else if result.tFirst == nil, let noOutputMessage {
            result.error = noOutputMessage
        }
        result.tEnd = now
        return result
    }
}

enum StreamError: Error, CustomStringConvertible {
    case jsonDecode(String)
    case attribute
    case http(Int)
    case incomplete

    var description: String {
        switch self {
        case .jsonDecode(let m): return "JSONDecodeError: \(m)"
        case .attribute: return "AttributeError: stream event is not an object"
        case .http(let c): return "HTTPError: HTTP Error \(c): \(httpReasonPhrase(c))"
        case .incomplete: return "IncompleteRead: stream ended before [DONE] and without usage"
        }
    }
}

func httpReasonPhrase(_ c: Int) -> String {
    switch c {
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 408: "Request Timeout"
    case 413: "Payload Too Large"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    default: "Error"
    }
}

/// Streaming POST of an OpenAI-compatible chat request. Never throws: failures become `error` on the
/// result, with whatever timing was captured before the failure (like the Python `except Exception`).
public enum ChatStreamer {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]  // no proxies, like the Python OPENER
        cfg.timeoutIntervalForResource = 86400 * 7
        cfg.httpMaximumConnectionsPerHost = 64
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    public static func post(url: String, body: Data, timeout: Double, pieceKeys: [String],
                            noOutputMessage: String?) async -> StreamResult {
        var parser = SSEParser(tSend: monotonicSeconds(), pieceKeys: pieceKeys)
        var failure: String?
        do {
            guard let u = URL(string: url) else { throw URLError(.badURL) }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, resp) = try await session.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw StreamError.http(http.statusCode) }
            var done = false
            for try await line in bytes.lines {
                if try parser.feed(line: line, at: monotonicSeconds()) { done = true; break }
            }
            // URLSession hides a truncated chunked body (Python's http.client raised IncompleteRead). A healthy
            // OpenAI-style stream ends with [DONE]; ending without it and without a usage block means the server died.
            if !done, parser.result.usage == nil { throw StreamError.incomplete }
        } catch let e as StreamError {
            failure = e.description
        } catch let e as URLError {
            failure = "URLError: \(e.localizedDescription)"
        } catch {
            failure = "\(type(of: error)): \(error)"
        }
        return parser.finish(error: failure, noOutputMessage: noOutputMessage, at: monotonicSeconds())
    }
}
