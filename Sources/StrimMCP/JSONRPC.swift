import Foundation
import StrimTemplate

/// JSON-RPC 2.0 error codes used by the MCP route.
enum RPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

struct RPCError: Error {
    var code: Int
    var message: String
}

/// One decoded incoming JSON-RPC message.
enum RPCMessage {
    case request(id: OrderedJSON, method: String, params: OrderedJSON?)
    case notification(method: String)
    case response
    /// Malformed envelope; `id` is the request id when it could be recovered, else `.null`.
    case invalid(id: OrderedJSON)

    static func classify(_ value: OrderedJSON) -> RPCMessage {
        guard case .object = value else { return .invalid(id: .null) }
        let id = value["id"]
        let validID: OrderedJSON? = {
            switch id {
            case .some(.string), .some(.int): return id
            default: return nil
            }
        }()
        guard value["jsonrpc"]?.stringValue == "2.0" else { return .invalid(id: validID ?? .null) }
        if let m = value["method"] {
            guard let method = m.stringValue else { return .invalid(id: validID ?? .null) }
            if id == nil { return .notification(method: method) }
            guard let validID else { return .invalid(id: .null) }
            return .request(id: validID, method: method, params: value["params"])
        }
        if (value["result"] != nil || value["error"] != nil), validID != nil { return .response }
        return .invalid(id: validID ?? .null)
    }
}

enum RPC {
    static func result(_ id: OrderedJSON, _ result: OrderedJSON) -> OrderedJSON {
        .ordered([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
    }

    static func error(_ id: OrderedJSON, _ code: Int, _ message: String) -> OrderedJSON {
        .ordered([("jsonrpc", .string("2.0")), ("id", id),
                  ("error", .ordered([("code", .int(code)), ("message", .string(message))]))])
    }

    static func notification(_ method: String, _ params: OrderedJSON) -> OrderedJSON {
        .ordered([("jsonrpc", .string("2.0")), ("method", .string(method)), ("params", params)])
    }

    static func data(_ value: OrderedJSON) -> Data { Data(value.serialized().utf8) }
}
