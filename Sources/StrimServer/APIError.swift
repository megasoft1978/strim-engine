import Foundation
import StrimEngine
import StrimHTTP
import StrimTemplate

enum ErrorStyle { case openai, anthropic }

/// An error that maps to an OpenAI-style JSON body: {"error": {"message", "type"}}.
struct APIError: Error, CustomStringConvertible {
    let status: Int
    let type: String
    let message: String
    /// Seconds for a `Retry-After` header (429/503 from the admission queue).
    var retryAfter: Int? = nil
    var description: String { message }

    static func badRequest(_ m: String) -> APIError { APIError(status: 400, type: "invalid_request", message: m) }
    static func unauthorized() -> APIError {
        APIError(status: 401, type: "authentication_error", message: "Missing or invalid API key (Authorization: Bearer <token>)")
    }
    static func notFound(_ m: String = "Not Found") -> APIError { APIError(status: 404, type: "not_found", message: m) }
    static func queueFull(retryAfter: Int) -> APIError {
        APIError(status: 429, type: "rate_limit_exceeded", message: "Too many queued requests; retry later", retryAfter: retryAfter)
    }
    static func queueTimeout(retryAfter: Int) -> APIError {
        APIError(status: 503, type: "engine_unavailable", message: "Timed out waiting for an admission slot", retryAfter: retryAfter)
    }

    /// Maps engine and template failures to a status and type.
    static func from(_ error: Error) -> APIError {
        if let e = error as? APIError { return e }
        if let e = error as? TemplateError { return .badRequest(e.description) }
        if let e = error as? EngineError {
            switch e {
            case .badInput(let m): return .badRequest(m)
            case .busy, .unknownSession: return APIError(status: 409, type: "conflict", message: e.description)
            case .mlx: return APIError(status: 500, type: "engine_error", message: e.description)
            case .unhealthy, .insufficientMemory, .shutdown:
                return APIError(status: 503, type: "engine_unavailable", message: e.description)
            }
        }
        return APIError(status: 500, type: "engine_error", message: "\(error)")
    }

    var json: OrderedJSON {
        .ordered([("error", .ordered([("message", .string(message)), ("type", .string(type))]))])
    }

    /// Anthropic error body: {"type":"error","error":{"type","message"}}.
    var anthropicJSON: OrderedJSON {
        let t: String
        switch status {
        case 400: t = "invalid_request_error"
        case 401: t = "authentication_error"
        case 404: t = "not_found_error"
        case 429: t = "rate_limit_error"
        case 503: t = "overloaded_error"
        default: t = "api_error"
        }
        return .ordered([("type", .string("error")), ("error", .ordered([("type", .string(t)), ("message", .string(message))]))])
    }

    func respond(_ responder: Responder, style: ErrorStyle = .openai, headers: HTTPHeaders = HTTPHeaders()) async throws {
        let body = style == .anthropic ? anthropicJSON : json
        var headers = headers
        if let retryAfter { headers.append(name: "Retry-After", value: String(retryAfter)) }
        try await responder.json(status, Data(body.serialized().utf8), headers: headers)
    }
}
