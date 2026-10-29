// Dry-run stand-in for an inference engine (NOT part of the product; compiled by pass.sh with swiftc when H2H_DRYRUN=1).
// usage: h2h-stub --port N --engine NAME     env: STUB_PF (prefill tok/s, 200000) STUB_DEC (decode tok/s, 2000) STUB_CACHE (1)
//   STUB_MODEL (model id listed by /v1/models) STUB_HELPER=1 (fork a helper child like oMLX) STUB_ORPHAN=1 (a helper that escapes the tree)
//   STUB_GUARD_AT=n (after n requests with >=12000 prompt tokens are in flight the stub "aborts" them with HTTP 500, logs an
//   oMLX-style hard-memory-pressure line and answers 500 for every later chat request until restarted) STUB_HANG=1 (never answer chat).
import Foundation
import Dispatch

setvbuf(stderr, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
var port: UInt16 = 8999, engine = "stub"
var a = CommandLine.arguments.dropFirst().makeIterator()
while let k = a.next() { if k == "--port", let v = a.next() { port = UInt16(v) ?? port } else if k == "--engine", let v = a.next() { engine = v } }
func envD(_ k: String, _ d: Double) -> Double { env[k].flatMap { Double($0) } ?? d }
let PF = envD("STUB_PF", 200000), DEC = envD("STUB_DEC", 2000), CACHE = env["STUB_CACHE"] != "0", GUARD = Int(envD("STUB_GUARD_AT", 0))
let MODEL = env["STUB_MODEL"] ?? "qwen38-4bit"
let lock = NSLock(); var prior: [String] = []; var bigInflight = 0; var unloaded = false
func spawn(_ sh: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", sh]; try? p.run() }
if env["STUB_HELPER"] == "1" { spawn("exec sleep 3600") }
if env["STUB_ORPHAN"] == "1" { spawn("(sleep 3600 >/dev/null 2>&1 &)") }
func send(_ fd: Int32, _ s: String) { let b = Array(s.utf8); var o = 0; while o < b.count { let n = write(fd, Array(b[o...]), b.count - o); if n <= 0 { return }; o += n } }
func reply(_ fd: Int32, _ code: Int, _ body: String, _ type: String = "application/json") {
    send(fd, "HTTP/1.1 \(code) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
}
func handle(_ fd: Int32) {
    defer { close(fd) }
    var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536); var hdrEnd: Range<Data.Index>?
    while hdrEnd == nil { let n = read(fd, &tmp, tmp.count); if n <= 0 { return }; buf.append(contentsOf: tmp[0..<n]); hdrEnd = buf.range(of: Data("\r\n\r\n".utf8)) }
    let head = String(decoding: buf[..<hdrEnd!.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n"); let first = lines[0].split(separator: " ")
    let clen = lines.compactMap { l -> Int? in l.lowercased().hasPrefix("content-length:") ? Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
    var body = Data(buf[hdrEnd!.upperBound...])
    while body.count < clen { let n = read(fd, &tmp, tmp.count); if n <= 0 { break }; body.append(contentsOf: tmp[0..<n]) }
    guard first.count >= 2 else { return }
    let path = String(first[1])
    if path.hasPrefix("/v1/models") || path == "/health" { return reply(fd, 200, "{\"object\":\"list\",\"data\":[{\"id\":\"\(MODEL)\",\"object\":\"model\"}]}") }
    guard path.hasSuffix("/chat/completions"), let req = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return reply(fd, 404, "{}") }
    let msgs = (req["messages"] as? [[String: Any]]) ?? []
    let prompt = msgs.map { ($0["content"] as? String) ?? "" }.joined(separator: "\n")
    let ptok = max(1, prompt.utf8.count / 4), maxTok = (req["max_tokens"] as? Int) ?? 64, stream = (req["stream"] as? Bool) ?? false
    if env["STUB_HANG"] == "1" { sleep(100000) }
    lock.lock()
    if unloaded { lock.unlock(); return reply(fd, 500, "{\"error\":\"model unloaded (hard memory pressure)\"}") }
    var cached = 0
    if CACHE {
        let p = Array(prompt.utf8); var best = 0
        for q in prior { let qa = Array(q.utf8); var i = 0; while i < min(p.count, qa.count) && p[i] == qa[i] { i += 1 }; best = max(best, i) }
        cached = (best / 4 / 256) * 256; prior.append(prompt); if prior.count > 24 { prior.removeFirst() }
    }
    let big = ptok >= 12000; if big { bigInflight += 1 }
    let trip = GUARD > 0 && big && bigInflight >= GUARD; if trip { unloaded = true }
    lock.unlock()
    if trip { FileHandle.standardError.write(Data("stub - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload (usage 54.5 GB, ceiling 56.0 GB)\n".utf8)) }
    defer { if big { lock.lock(); bigInflight -= 1; lock.unlock() } }
    if big && GUARD > 0 { usleep(300_000); lock.lock(); let u = unloaded; lock.unlock(); if u { return reply(fd, 500, "{\"error\":\"Request aborted: process memory limit exceeded\"}") } }
    usleep(UInt32(Double(ptok - cached) / PF * 1e6))
    let word = " w", n = maxTok
    var usage = "\"usage\":{\"prompt_tokens\":\(ptok),\"completion_tokens\":\(n),\"total_tokens\":\(ptok + n)"
    usage += CACHE ? ",\"prompt_tokens_details\":{\"cached_tokens\":\(cached)}}" : "}"
    if !stream {
        let text = "stub " + String(repeating: word, count: n)
        return reply(fd, 200, "{\"id\":\"s\",\"object\":\"chat.completion\",\"model\":\"\(MODEL)\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\(jsonQ(text))},\"finish_reason\":\"length\"}],\(usage)}")
    }
    send(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
    for _ in 0..<n { send(fd, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(word)\"}}]}\n\n"); usleep(UInt32(1e6 / DEC)) }
    send(fd, "data: {\"choices\":[],\(usage)}\n\ndata: [DONE]\n\n")
}
func jsonQ(_ s: String) -> String { "\"" + s + "\"" }
signal(SIGPIPE, SIG_IGN)
let s = socket(AF_INET, SOCK_STREAM, 0); var one: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4)
var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
if rc != 0 || listen(s, 128) != 0 { FileHandle.standardError.write(Data("stub: cannot bind \(port)\n".utf8)); exit(1) }
print("stub[\(engine)] listening on \(port)")
while true { let c = accept(s, nil, nil); if c >= 0 { Thread.detachNewThread { handle(c) } } }
