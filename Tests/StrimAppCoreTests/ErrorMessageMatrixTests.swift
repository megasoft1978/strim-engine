import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

private final class MatrixProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String, URLError.Code?) = (500, "", nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (status, body, failure) = Self.reply
        if let failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ErrorMessageMatrixTests {
    @Test func responseMatrix() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let client = HTTPControlClient(baseURL: URL(string: "http://127.0.0.1:12345")!, token: TokenReader(path: temp.appendingPathComponent("token").path, home: temp.path), session: HTTPControlClient.hardenedSession(extraProtocols: [MatrixProtocol.self]))
        let calls: [(String, () async throws -> Void)] = [
            ("status", { _ = try await client.status() }),
            ("open", { _ = try await client.chatOpen(ChatOpenRequest(cwd: "/tmp")) }),
            ("send", { try await client.chatAppend(ChatAppendRequest(sessionID: "s", text: "hi")) }),
            ("cancel", { try await client.chatCancel(ChatCancelRequest(sessionID: "s")) }),
            ("grant", { _ = try await client.grantFolder(path: "/tmp") }),
            ("revoke", { _ = try await client.revokeFolder(path: "/tmp") }),
            ("list", { _ = try await client.folders() }),
            ("apply", { try await client.approve(PatchApproval(jobID: "j", action: .apply)) }),
        ]
        let rows: [(Int, String, URLError.Code?, String, Bool, Bool)] = [
            (400, envelope("bad_request", "request body required"), nil, "Request body required.", false, false),
            (401, "", nil, "The Strim server requires a control token. Start the server to create one.", false, false),
            (401, envelope("unauthorized", "missing or invalid credentials"), nil, "The Strim server requires a control token. Start the server to create one.", false, false),
            (403, "", nil, "The Strim server refused this request (403). Check server access settings.", false, false),
            (403, envelope("forbidden", "cwd /tmp is outside the allowed roots"), nil, "cwd /tmp is outside the allowed roots", false, true),
            (403, envelope("forbidden", "this credential is not valid for this route"), nil, "this credential is not valid for this route", false, false),
            (404, envelope("not_found", "no job j"), nil, "Not found: no job j.", false, false),
            (409, envelope("conflict", "turn_in_progress: a turn is already running"), nil, "A response is already in progress. Wait for it to finish, then try again.", false, false),
            (409, envelope("conflict", "max_sessions: too many sessions"), nil, "Too many chats are open. Close one and try again.", false, false),
            (409, envelope("max_sessions", "too many sessions"), nil, "Too many chats are open. Close one and try again.", false, false),
            (409, envelope("turn_in_progress", "a turn is running"), nil, "A response is already in progress. Wait for it to finish, then try again.", false, false),
            (404, envelope("not_found", "session_not_found: s"), nil, "This chat session has ended. Open a new chat and try again.", false, false),
            (409, envelope("conflict", "session_closed: sessionClosed"), nil, "This chat session has ended. Open a new chat and try again.", false, false),
            (409, envelope("conflict", "idle_timeout: idleTimeout"), nil, "This chat session has ended. Open a new chat and try again.", false, false),
            (400, envelope("bad_request", "empty_text: emptyText"), nil, "Enter a message before sending.", false, false),
            (400, envelope("bad_request", "text_too_long: textTooLong(32000)"), nil, "The message is too long. Shorten it and try again.", false, false),
            (400, envelope("bad_request", "unknown_profile: unknownProfile"), nil, "The selected chat profile is unavailable. Check the server configuration.", false, false),
            (413, "", nil, "The request is too large. Reduce its size and try again.", false, false),
            (429, "", nil, "The Strim server is handling too many requests. Try again later.", false, false),
            (500, "", nil, "The Strim server encountered an error. Try again.", false, false),
            (502, "", nil, "The Strim server received an invalid upstream response. Try again.", false, false),
            (503, envelope("unavailable", "no model loaded (state: unloaded)"), nil, "No model loaded (state: unloaded).", false, false),
            (0, "", .timedOut, "Strim server didn't respond in time. Check that it is running (menu bar).", true, false),
            (0, "", .cannotConnectToHost, "Strim server isn't responding on 127.0.0.1:12345. Start it from the menu bar.", true, false),
            (0, "", .cannotFindHost, "The Strim server address could not be found. Check host_url in settings.", false, false),
            (0, "", .badURL, "The Strim server address is invalid. Check host_url in settings.", false, false),
            (0, "", .secureConnectionFailed, "A secure connection to the Strim server failed. Check host_url in settings.", false, false),
            (0, "", .cancelled, "The request was cancelled.", false, false),
        ]
        for (status, body, failure, expected, offline, folder) in rows {
            MatrixProtocol.reply = (status, body, failure)
            for (name, call) in calls {
                do { try await call(); Issue.record("Expected error for \(name), status \(status)") }
                catch {
                    #expect(error.localizedDescription == expected, "\(name), status \(status): \(error.localizedDescription)")
                    #expect(FolderMessages.isOffline(error) == offline, "\(name), status \(status)")
                    #expect(FolderMessages.isFolderRefusal(error) == folder, "\(name), status \(status)")
                }
            }
        }
        for body in ["", "<html>"] {
            MatrixProtocol.reply = (200, body, nil)
            for (name, call) in calls where ["status", "open", "grant", "revoke", "list"].contains(name) {
                do { try await call(); Issue.record("Expected decoding error for \(name)") }
                catch { #expect(error.localizedDescription == "The Strim server returned an invalid response. Try again.") }
            }
        }
    }
    private func envelope(_ code: String, _ message: String) -> String {
        String(decoding: try! JSONEncoder().encode(APIErrorEnvelope(error: APIError(code: code, message: message))), as: UTF8.self)
    }
}
