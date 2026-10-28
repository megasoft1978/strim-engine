import Dispatch
import Foundation
import StrimTemplate

// File tools for the agent harness: read_file, list_files, grep, edit_file, write_file.
// Every path goes through WorkspacePolicy.resolve; every returned string goes through Redactor.redact.
// Policy denials and bad arguments come back as isError ToolResults, never as thrown errors.
// Files are opened only after an lstat check that they are regular, and re-verified on the descriptor
// (no links, single hard link, still inside the workspace). Regex and glob work is bounded.

private let maxWriteBytes = 1_048_576
private let maxEditBytes = 1_048_576
private let maxSearchFileBytes = 1_048_576
private let readWindowBytes = 262_144
private let outputCap = 8000
private let listCap = 200
private let grepCap = 100
private let defaultReadLimit = 400
private let maxGlobChars = 256
private let maxPatternChars = 200
private let maxGrepLineChars = 4000
private let searchDeadlineSeconds = 5.0
private let abandonGraceSeconds = 2.0
private let maxRunningSearches = 4
private let skipDirNames: Set<String> = [".git", "node_modules", ".build"]

private struct FileToolError: Error {
    let message: String
}

private func ok(_ text: String) -> ToolResult {
    ToolResult(output: Redactor.redact(text))
}

private func fail(_ text: String) -> ToolResult {
    ToolResult(output: Redactor.redact(text), isError: true)
}

private func describe(_ error: Error) -> String {
    switch error {
    case let e as FileToolError: return e.message
    case PolicyError.outsideWorkspace(let p): return "error: path outside workspace: \(p)"
    case PolicyError.denied(let p): return "error: access denied: \(p)"
    case PolicyError.readOnly(let p): return "error: read-only job, cannot modify \(p)"
    default: return "error: \(error)"
    }
}

private func policy(_ context: ToolContext) -> WorkspacePolicy {
    WorkspacePolicy(root: URL(fileURLWithPath: context.root), access: context.access)
}

private func requireWrite(_ context: ToolContext, _ path: String) throws {
    guard context.access == .write else {
        throw FileToolError(message: "error: read-only job, cannot modify \(path)")
    }
}

private func requireString(_ args: [String: OrderedJSON], _ key: String) throws -> String {
    guard let s = args[key]?.stringValue else {
        throw FileToolError(message: "error: missing string argument '\(key)'")
    }
    return s
}

private func optionalInt(_ args: [String: OrderedJSON], _ key: String) throws -> Int? {
    guard let v = args[key] else { return nil }
    guard case let .int(i) = v else {
        throw FileToolError(message: "error: '\(key)' must be an integer")
    }
    return i
}

private func trimmedPath(_ path: String) -> String {
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}

/// Workspace root as the policy resolves it (realpath), used for display paths.
private func workspaceRoot(_ context: ToolContext) throws -> String {
    trimmedPath(try policy(context).resolve(".", forWriting: false).path)
}

/// `url` relative to `root` when inside it, else the absolute path.
private func relative(_ url: URL, to root: String) -> String {
    let p = url.path
    return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
}

// MARK: descriptor-level checks

private func lstatPath(_ path: String) -> stat? {
    var st = stat()
    return lstat(path, &st) == 0 ? st : nil
}

/// File type bits of the entry itself (links are not followed), nil when it does not exist.
private func entryKind(_ url: URL) -> mode_t? {
    lstatPath(url.path).map { $0.st_mode & S_IFMT }
}

/// True when the open descriptor resolves (F_GETPATH) to a location inside the workspace `root`.
/// Compared after canonical normalization and case folding, since APFS is case-insensitive.
private func fdInsideRoot(_ fd: Int32, root: String) -> Bool {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &buf) == 0, let rootReal = WorkspacePolicy.realPath(of: root) else { return false }
    let actual = String(cString: buf).precomposedStringWithCanonicalMapping.lowercased()
    let base = rootReal.precomposedStringWithCanonicalMapping.lowercased()
    return actual == base || actual.hasPrefix(base == "/" ? "/" : base + "/")
}

/// Opens a workspace file for reading. Only a plain regular file with one hard link is accepted, checked
/// with lstat before open (a FIFO is never opened) and again on the descriptor. O_NOFOLLOW refuses a
/// symlink swapped in after resolution; O_NONBLOCK keeps a special file from blocking the open.
private func openVerified(_ url: URL, root: String, path: String) throws -> Int32 {
    guard let st = lstatPath(url.path) else { throw FileToolError(message: "error: no such file: \(path)") }
    switch st.st_mode & S_IFMT {
    case S_IFREG: break
    case S_IFDIR: throw FileToolError(message: "error: is a directory: \(path); use list_files")
    default: throw FileToolError(message: "error: not a regular file: \(path)")
    }
    guard st.st_nlink <= 1 else { throw FileToolError(message: "error: hard-linked file refused: \(path)") }
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw FileToolError(message: "error: cannot read \(path)") }
    var opened = stat()
    guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink <= 1 else {
        close(fd)
        throw FileToolError(message: "error: not a regular file: \(path)")
    }
    guard fdInsideRoot(fd, root: root) else {
        close(fd)
        throw PolicyError.outsideWorkspace(path)
    }
    return fd
}

/// Refuses a non-regular path (FIFO, device, socket) before anything reads from it.
private func requireRegularFile(_ url: URL, _ path: String) throws {
    guard let kind = entryKind(url) else { throw FileToolError(message: "error: no such file: \(path)") }
    guard kind == S_IFREG else { throw FileToolError(message: "error: not a regular file: \(path)") }
}

private struct VerifiedFile {
    let data: Data  // first min(size, maxBytes) bytes
    let size: Int
}

/// Reads at most `maxBytes` from the start of a verified workspace file, plus its total size.
private func readVerified(_ url: URL, root: String, path: String, maxBytes: Int) throws -> VerifiedFile {
    let fd = try openVerified(url, root: root, path: path)
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else { throw FileToolError(message: "error: cannot read \(path)") }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while data.count < maxBytes {
        let want = min(chunk.count, maxBytes - data.count)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
        if n < 0 {
            if errno == EINTR { continue }
            throw FileToolError(message: "error: cannot read \(path)")
        }
        if n == 0 { break }
        data.append(contentsOf: chunk[0..<n])
    }
    return VerifiedFile(data: data, size: Int(st.st_size))
}

/// Text from raw bytes: refuses binary (NUL in the first 8000 bytes) and non-UTF-8. When `truncated`,
/// cuts back to the last newline so the text never ends inside a line or a multi-byte character.
private func decodeText(_ data: Data, path: String, truncated: Bool) throws -> String {
    guard !data.prefix(8000).contains(0) else {
        throw FileToolError(message: "error: binary file: \(path)")
    }
    var bytes = data
    if truncated {
        guard let nl = data.lastIndex(of: 0x0A) else {
            throw FileToolError(message: "error: no line break in the first 256 KB of \(path)")
        }
        bytes = data.prefix(through: nl)
    }
    guard let text = String(data: bytes, encoding: .utf8) else {
        throw FileToolError(message: "error: not UTF-8 text: \(path)")
    }
    return text
}

/// Atomically replaces `url` (a resolved workspace path) with `data`, creating it if absent. The parent
/// directory is opened without following links and its real path is re-checked against `root`; the temp
/// file is created with O_EXCL|O_NOFOLLOW inside that directory and renamed over the target. A final
/// component that is a link, directory, special file or multiply-linked file is refused, never written through.
func writeAtomically(_ data: Data, to url: URL, root: String) throws {
    let name = url.lastPathComponent
    let pfd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard pfd >= 0 else { throw FileToolError(message: "error: cannot open directory of \(name)") }
    defer { close(pfd) }
    guard fdInsideRoot(pfd, root: root) else { throw PolicyError.outsideWorkspace(url.path) }

    var mode: mode_t = 0o644
    var existing = stat()
    if fstatat(pfd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard existing.st_mode & S_IFMT == S_IFREG else {
            throw FileToolError(message: "error: not a regular file: \(name)")
        }
        guard existing.st_nlink <= 1 else { throw FileToolError(message: "error: hard-linked file refused: \(name)") }
        mode = existing.st_mode & 0o7777
    } else if errno != ENOENT {
        throw FileToolError(message: "error: cannot inspect \(name)")
    }

    let tmp = ".\(name).\(UUID().uuidString).tmp"
    let fd = openat(pfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else { throw FileToolError(message: "error: cannot create temp file for \(name)") }
    let written = data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var off = 0
        while off < raw.count {
            let n = write(fd, base + off, raw.count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    let closed = close(fd) == 0
    guard written && closed, renameat(pfd, tmp, pfd, name) == 0 else {
        unlinkat(pfd, tmp, 0)
        throw FileToolError(message: "error: cannot write \(name)")
    }
}

// MARK: bounded work

/// Runs the blocking `work` on a GCD thread and waits at most `seconds`; nil on timeout. Regex matching cannot
/// be cancelled, so it never runs on the cooperative pool. A work item that never returns is abandoned: its
/// thread stays blocked, but the caller gets nil and the tool call returns.
func runWithDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let gate = OnceGate()
        DispatchQueue.global().async {
            let value = work()
            if gate.claim() { cont.resume(returning: value) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if gate.claim() { cont.resume(returning: nil) }
        }
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Accounting for search workers abandoned at their deadline, one per tool instance (a tool catalog is one job).
/// At most `maxRunningSearches` workers may be alive. A worker still alive `abandonGraceSeconds` after its
/// deadline ignored the abort, so searching is disabled for the rest of the job instead of spawning more spinners.
final class SearchLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<Int> = []
    private var nextToken = 0
    private var disabled = false

    /// Number of search workers still running (finished ones are removed).
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active.count
    }

    /// nil when disabled or when `maxRunningSearches` workers are still alive.
    func acquire() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, active.count < maxRunningSearches else { return nil }
        nextToken += 1
        active.insert(nextToken)
        return nextToken
    }

    func release(_ token: Int) {
        lock.lock()
        defer { lock.unlock() }
        active.remove(token)
    }

    /// Disables searching if `token` is still alive `grace` seconds from now.
    func watch(_ token: Int, grace: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.active.contains(token) { self.disabled = true }
        }
    }

    var isDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabled
    }
}

/// Runs one search worker under `limiter`: refused while disabled or saturated, abandoned at `seconds`.
/// `work` returns nil when it stopped itself at its deadline; both cases throw "search timed out".
func runSearch<T: Sendable>(_ limiter: SearchLimiter, seconds: Double = searchDeadlineSeconds,
                            grace: Double = abandonGraceSeconds, _ work: @escaping @Sendable () -> T?) async throws -> T {
    guard !limiter.isDisabled else {
        throw FileToolError(message: "error: search disabled: an earlier search ignored its deadline; restart the job")
    }
    guard let token = limiter.acquire() else {
        throw FileToolError(message: "error: search unavailable: \(maxRunningSearches) earlier searches are still running")
    }
    let outcome: T?? = await runWithDeadline(seconds) { () -> T? in
        defer { limiter.release(token) }
        return work()
    }
    guard let finished = outcome, let value = finished else {
        limiter.watch(token, grace: grace)
        throw FileToolError(message: "error: search timed out")
    }
    return value
}

/// One line matched against `regex`, stopping at `deadline`: matching runs through enumerateMatches with
/// .reportProgress so the abort flag is seen during a long match. nil when the deadline passed mid-match.
private func lineMatches(_ regex: NSRegularExpression, _ s: String, deadline: Date) -> Bool? {
    var found = false
    var expired = false
    regex.enumerateMatches(in: s, options: [.reportProgress], range: NSRange(s.startIndex..., in: s)) { result, _, stop in
        if result != nil {
            found = true
            stop.pointee = true
        } else if Date() > deadline {
            expired = true
            stop.pointee = true
        }
    }
    if found { return true }
    return expired ? nil : false
}

// MARK: walking and globbing

/// Policy check for an entry found while walking the workspace: denied entries are hidden entirely.
private func visibility(_ policy: WorkspacePolicy, root: String) -> @Sendable (URL) -> Bool {
    { url in (try? policy.resolve(relative(url, to: root), forWriting: false)) != nil }
}

/// Regular files under `base`, sorted by path. Skips VCS/build directories, links, and special files
/// (FIFOs, devices, sockets), and entries `visible` rejects; denied directories are not descended into.
/// nil when `deadline` passes first.
private func walkFiles(_ base: URL, deadline: Date, visible: (URL) -> Bool) -> [URL]? {
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: []) else {
        return []
    }
    var out: [URL] = []
    while let obj = en.nextObject() {
        if Date() > deadline { return nil }
        guard let url = obj as? URL else { continue }
        let kind = entryKind(url)
        if kind == S_IFDIR {
            if skipDirNames.contains(url.lastPathComponent) || !visible(url) { en.skipDescendants() }
        } else if kind == S_IFREG, visible(url) {
            out.append(url)
        }
    }
    return out.sorted { $0.path < $1.path }
}

struct Listing: Sendable {
    let items: [String]
    /// True when more visible entries exist than `items` holds (listing stopped at `listCap`).
    let more: Bool
}

/// Non-recursive listing of `url`: visible entries sorted by name, stopping after `listCap` of them, so the
/// scan itself is bounded, not just the output. nil when `deadline` passes first.
private func listChildren(_ url: URL, root: String, pol: WorkspacePolicy, deadline: Date) -> Listing? {
    let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    let visible = visibility(pol, root: root)
    var items: [String] = []
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        if Date() > deadline { return nil }
        guard !skipDirNames.contains(child.lastPathComponent), !isSymlink(child), visible(child) else { continue }
        if items.count == listCap { return Listing(items: items, more: true) }
        items.append(relative(child, to: root) + (isDirectory(child) ? "/" : ""))
    }
    return Listing(items: items, more: false)
}

/// Head/tail cap: keeps the first and last parts of `s` around a marker, total <= `limit` chars.
private func capped(_ s: String, marker: String, limit: Int = outputCap) -> String {
    guard s.count > limit else { return s }
    let m = "\n" + marker + "\n"
    let budget = limit - m.count
    let head = budget * 2 / 3
    return String(s.prefix(head)) + m + String(s.suffix(budget - head))
}

private enum GlobToken {
    case literal(Character)
    case anyOne
    case star
    case globstar
}

/// Glob match on a path: `*` is any run without `/`, `**` any run including `/`
/// (`**/` may match zero directories), `?` one character other than `/`.
/// Dynamic programming over (pattern token, text index): O(pattern * text) time, no recursion.
private func globMatches(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern)
    var tokens: [GlobToken] = []
    var i = 0
    while i < p.count {
        if p[i] == "*" {
            if i + 1 < p.count && p[i + 1] == "*" {
                i += 2
                if i < p.count && p[i] == "/" { i += 1 }
                tokens.append(.globstar)
            } else {
                i += 1
                tokens.append(.star)
            }
        } else {
            tokens.append(p[i] == "?" ? .anyOne : .literal(p[i]))
            i += 1
        }
    }
    let t = Array(text)
    let n = t.count
    // next[j]: the tokens after the current one match t[j...]. Start: no tokens left, so only the end matches.
    var next = [Bool](repeating: false, count: n + 1)
    next[n] = true
    for token in tokens.reversed() {
        var cur = [Bool](repeating: false, count: n + 1)
        switch token {
        case .literal(let c):
            for j in 0..<n where t[j] == c { cur[j] = next[j + 1] }
        case .anyOne:
            for j in 0..<n where t[j] != "/" { cur[j] = next[j + 1] }
        case .star, .globstar:
            let stopAtSlash: Bool
            if case .star = token { stopAtSlash = true } else { stopAtSlash = false }
            // cur[j]: the token matches an empty run, or consumes t[j] and continues at j + 1.
            cur[n] = next[n]
            for j in stride(from: n - 1, through: 0, by: -1) {
                let allowed = !(stopAtSlash && t[j] == "/")
                cur[j] = next[j] || (allowed && cur[j + 1])
            }
        }
        next = cur
    }
    return next[0]
}

/// Glob filter for a file found under `base`: a pattern without `/` matches the file name at any depth,
/// otherwise the path relative to `base`.
private func matchesGlob(_ file: URL, glob: String?, base: String) -> Bool {
    guard let glob else { return true }
    let subject = glob.contains("/") ? relative(file, to: base) : file.lastPathComponent
    return globMatches(glob, subject)
}

// MARK: regex validation

/// True when a quantified group contains a quantifier, directly or through nested groups: `(a+)+`,
/// `(a|b*)*`, `((a)+)*`, `(a?){2,}`. Such patterns backtrack exponentially and ICU has no time limit.
/// Escapes and bracket classes are skipped.
private func hasNestedQuantifier(_ pattern: String) -> Bool {
    let p = Array(pattern)
    var groups: [Bool] = []  // per open group: contains a quantifier so far
    var i = 0
    func isRepeat(_ j: Int) -> Bool {
        guard j < p.count else { return false }
        if p[j] == "*" || p[j] == "+" { return true }
        if p[j] == "{" { return j + 1 < p.count && p[j + 1].isNumber }
        return false
    }
    func markTop() {
        if !groups.isEmpty { groups[groups.count - 1] = true }
    }
    while i < p.count {
        let c = p[i]
        if c == "\\" { i += 2; continue }
        if c == "[" {
            i += 1
            if i < p.count && p[i] == "^" { i += 1 }
            if i < p.count && p[i] == "]" { i += 1 }
            while i < p.count && p[i] != "]" { i += p[i] == "\\" ? 2 : 1 }
            i += 1
            continue
        }
        switch c {
        case "(":
            groups.append(false)
        case ")":
            if let inner = groups.popLast() {
                let quantified = isRepeat(i + 1)
                if quantified && inner { return true }
                if quantified || inner { markTop() }
            }
        case "*", "+", "{":
            if c != "{" || isRepeat(i) { markTop() }
        case "?":
            // `(?` opens a group syntax, not a quantifier.
            if i == 0 || p[i - 1] != "(" { markTop() }
        default:
            break
        }
        i += 1
    }
    return false
}

/// Rejects regexes that are too long, nest quantifiers, or do not compile.
private func validatePattern(_ pattern: String) throws {
    guard pattern.count <= maxPatternChars else {
        throw FileToolError(message: "error: regex longer than \(maxPatternChars) characters")
    }
    guard !hasNestedQuantifier(pattern) else {
        throw FileToolError(message: "error: regex rejected: nested quantifiers such as (a+)+ are not allowed")
    }
    guard (try? NSRegularExpression(pattern: pattern)) != nil else {
        throw FileToolError(message: "error: invalid regex: \(pattern)")
    }
}

// MARK: grep worker

/// `path:line:text` matches under `url` (a file, or a directory walked recursively), at most `grepCap`.
/// Lines are matched on their first `maxGrepLineChars` characters. nil when `deadline` passes first.
private func grepFiles(_ url: URL, isDir: Bool, pattern: String, glob: String?, base: String,
                       root: String, pol: WorkspacePolicy, deadline: Date) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    guard let files = isDir ? walkFiles(url, deadline: deadline, visible: visibility(pol, root: root)) : [url] else {
        return nil
    }
    var matches: [String] = []
    search: for file in files {
        if Date() > deadline { return nil }
        guard matchesGlob(file, glob: glob, base: base) else { continue }
        let rel = relative(file, to: root)
        guard let f = try? readVerified(file, root: root, path: rel, maxBytes: maxSearchFileBytes),
              f.size <= maxSearchFileBytes,
              let text = try? decodeText(f.data, path: rel, truncated: false) else { continue }
        for (i, line) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            if i % 256 == 0 && Date() > deadline { return nil }
            let s = String(line.prefix(maxGrepLineChars))
            guard let hit = lineMatches(regex, s, deadline: deadline) else { return nil }
            guard hit else { continue }
            matches.append("\(rel):\(i + 1):\(s)")
            if matches.count >= grepCap { break search }
        }
    }
    return matches
}

private func schema(_ properties: [(String, OrderedJSON)], required: [String]) -> OrderedJSON {
    .ordered([
        ("type", .string("object")),
        ("properties", .ordered(properties)),
        ("required", .array(required.map { .string($0) })),
    ])
}

private func prop(_ type: String, _ description: String) -> OrderedJSON {
    .ordered([("type", .string(type)), ("description", .string(description))])
}

public struct ReadFileTool: HarnessTool {
    public let name = "read_file"
    public let spec = ToolSpec(
        name: "read_file",
        description: "Read a UTF-8 text file in the workspace. Returns numbered lines (N<TAB>text), "
            + "400 lines from line 1 by default; use offset and limit to page. Only the first 256 KB of a file "
            + "can be read. Output capped at 8000 chars.",
        parameters: schema([
            ("path", prop("string", "File path relative to the workspace root.")),
            ("offset", prop("integer", "1-based line to start at. Default 1.")),
            ("limit", prop("integer", "Maximum number of lines. Default 400.")),
        ], required: ["path"]))

    public init() {}

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        do { return try read(args, context) } catch { return fail(describe(error)) }
    }

    private func read(_ args: [String: OrderedJSON], _ context: ToolContext) throws -> ToolResult {
        let path = try requireString(args, "path")
        let offset = try optionalInt(args, "offset") ?? 1
        let limit = try optionalInt(args, "limit") ?? defaultReadLimit
        guard offset >= 1 else { throw FileToolError(message: "error: offset must be >= 1") }
        guard limit >= 1 else { throw FileToolError(message: "error: limit must be >= 1") }

        let url = try policy(context).resolve(path, forWriting: false)
        let file = try readVerified(url, root: context.root, path: path, maxBytes: readWindowBytes)
        let truncated = file.size > file.data.count
        let text = try decodeText(file.data, path: path, truncated: truncated)

        var lines = text.isEmpty ? [] : text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
        if text.last?.isNewline == true { lines.removeLast() }
        guard offset == 1 || offset <= lines.count else {
            let scope = truncated ? " readable in the first 256 KB" : ""
            throw FileToolError(message: "error: offset \(offset) beyond end (\(lines.count) lines\(scope))")
        }

        // offset is 1 or <= lines.count, so start <= lines.count and the subtraction cannot overflow.
        let start = offset - 1
        let take = min(limit, lines.count - start)
        let end = start + take
        let body = (start..<end).map { "\($0 + 1)\t\(lines[$0])" }.joined(separator: "\n")
        var out = capped(body, marker: "... [truncated; use offset]")
        if end < lines.count {
            out += "\n[\(lines.count - end) more lines; use offset=\(end + 1)]"
        }
        if truncated {
            out += "\n[file is \(file.size) bytes; only its first 256 KB is readable with read_file; use grep to locate lines]"
        }
        return ok(out)
    }
}

public struct ListFilesTool: HarnessTool {
    public let name = "list_files"
    let limiter = SearchLimiter()
    public let spec = ToolSpec(
        name: "list_files",
        description: "List entries of a workspace directory (non-recursive; directories end with /). "
            + "With glob, search recursively for files: a glob without / matches file names at any depth, "
            + "a glob with / matches paths relative to the workspace root. Skips .git, node_modules, .build. "
            + "Max 200 entries; glob up to 256 characters.",
        parameters: schema([
            ("path", prop("string", "Directory relative to the workspace root. Default '.'.")),
            ("glob", prop("string", "Optional glob, e.g. '*.swift' or 'Sources/**/*.swift'.")),
        ], required: []))

    public init() {}

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        do { return try await list(args, context) } catch { return fail(describe(error)) }
    }

    private func list(_ args: [String: OrderedJSON], _ context: ToolContext) async throws -> ToolResult {
        let path = args["path"]?.stringValue ?? "."
        let glob = args["glob"]?.stringValue
        let url = try policy(context).resolve(path, forWriting: false)
        guard isDirectory(url) else { throw FileToolError(message: "error: not a directory: \(path)") }
        let root = try workspaceRoot(context)
        let base = trimmedPath(url.path)

        let deadline = Date().addingTimeInterval(searchDeadlineSeconds)
        let pol = policy(context)
        let items: [String]
        var more: String?
        if let glob {
            guard glob.count <= maxGlobChars else {
                throw FileToolError(message: "error: glob longer than \(maxGlobChars) characters")
            }
            let files = try await runSearch(limiter) { () -> [URL]? in
                walkFiles(url, deadline: deadline, visible: visibility(pol, root: root))?
                    .filter { matchesGlob($0, glob: glob, base: base) }
            }
            items = files.prefix(listCap).map { relative($0, to: root) }
            if files.count > items.count { more = "[\(files.count - items.count) more; narrow with glob or path]" }
        } else {
            let listing = try await runSearch(limiter) { () -> Listing? in
                listChildren(url, root: root, pol: pol, deadline: deadline)
            }
            items = listing.items
            if listing.more { more = "[more entries not listed; narrow with path]" }
        }

        if items.isEmpty { return ok("(no entries)") }
        var out = capped(items.joined(separator: "\n"), marker: "... [truncated; narrow glob or path]")
        if let more { out += "\n" + more }
        return ok(out)
    }
}

public struct GrepTool: HarnessTool {
    public let name = "grep"
    let limiter = SearchLimiter()
    public let spec = ToolSpec(
        name: "grep",
        description: "Search file contents with a regular expression (NSRegularExpression syntax, up to 200 "
            + "characters, no nested quantifiers such as (a+)+). Returns path:line:text for up to 100 matching "
            + "lines; lines are matched on their first 4000 characters. Skips binary files and files over 1 MB. "
            + "glob filters files as in list_files.",
        parameters: schema([
            ("pattern", prop("string", "Regular expression.")),
            ("path", prop("string", "File or directory relative to the workspace root. Default '.'.")),
            ("glob", prop("string", "Optional file filter, e.g. '*.swift'.")),
        ], required: ["pattern"]))

    public init() {}

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        do { return try await search(args, context) } catch { return fail(describe(error)) }
    }

    private func search(_ args: [String: OrderedJSON], _ context: ToolContext) async throws -> ToolResult {
        let pattern = try requireString(args, "pattern")
        try validatePattern(pattern)
        let path = args["path"]?.stringValue ?? "."
        let glob = args["glob"]?.stringValue
        if let glob, glob.count > maxGlobChars {
            throw FileToolError(message: "error: glob longer than \(maxGlobChars) characters")
        }
        let url = try policy(context).resolve(path, forWriting: false)
        let root = try workspaceRoot(context)
        let dir = isDirectory(url)
        if !dir { try requireRegularFile(url, path) }
        let base = dir ? trimmedPath(url.path) : url.deletingLastPathComponent().path
        let deadline = Date().addingTimeInterval(searchDeadlineSeconds)
        let pol = policy(context)

        let matches = try await runSearch(limiter) { () -> [String]? in
            grepFiles(url, isDir: dir, pattern: pattern, glob: glob, base: base,
                      root: root, pol: pol, deadline: deadline)
        }

        if matches.isEmpty { return ok("(no matches)") }
        var out = capped(matches.joined(separator: "\n"), marker: "... [truncated; narrow pattern or path]")
        if matches.count >= grepCap { out += "\n[stopped at \(grepCap) matches]" }
        return ok(out)
    }
}

public struct EditFileTool: HarnessTool {
    public let name = "edit_file"
    public let spec = ToolSpec(
        name: "edit_file",
        description: "Replace one exact occurrence of old with new in a workspace file. old must occur exactly "
            + "once; include surrounding lines to make it unique. Files up to 1 MB. Requires write access.",
        parameters: schema([
            ("path", prop("string", "File path relative to the workspace root.")),
            ("old", prop("string", "Exact text to replace; must match exactly once.")),
            ("new", prop("string", "Replacement text (may be empty to delete).")),
        ], required: ["path", "old", "new"]))

    public init() {}

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        do { return try edit(args, context) } catch { return fail(describe(error)) }
    }

    private func edit(_ args: [String: OrderedJSON], _ context: ToolContext) throws -> ToolResult {
        let path = try requireString(args, "path")
        let old = try requireString(args, "old")
        let new = try requireString(args, "new")
        guard !old.isEmpty else { throw FileToolError(message: "error: old must not be empty") }
        let url = try policy(context).resolve(path, forWriting: true)
        try requireWrite(context, path)

        let file = try readVerified(url, root: context.root, path: path, maxBytes: maxEditBytes)
        guard file.size <= maxEditBytes else {
            throw FileToolError(message: "error: \(path) is \(file.size) bytes; edit_file handles files up to 1 MB")
        }
        let text = try decodeText(file.data, path: path, truncated: false)
        let count = text.components(separatedBy: old).count - 1
        var span: (start: Int, end: Int)
        var normalized = false
        if count == 1 {
            guard let r = text.range(of: old, options: .literal) else {
                throw FileToolError(message: "error: old not found in \(path) (0 matches); re-read the file with read_file and copy the text exactly")
            }
            span = (text.utf8.distance(from: text.startIndex, to: r.lowerBound),
                    text.utf8.distance(from: text.startIndex, to: r.upperBound))
        } else if count > 1 {
            throw FileToolError(message: multiMatchMessage(text, old, path: path, count: count))
        } else if let loose = looseSpan([UInt8](file.data), old) {
            span = loose
            normalized = true
        } else {
            throw FileToolError(message: notFoundMessage(text, old, path: path))
        }

        let bytes = [UInt8](file.data)
        var newBytes = [UInt8](new.utf8)
        if normalized, bytes[span.start..<span.end].contains(0x0D) {
            newBytes = toCRLF(newBytes)
        }
        let oldLines = lineCount(bytes[span.start..<span.end])
        let startLine = 1 + bytes[0..<span.start].reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let updated = Array(bytes[0..<span.start]) + newBytes + Array(bytes[span.end...])
        try writeAtomically(Data(updated), to: url, root: context.root)

        let newLines = lineCount(newBytes[...])
        var head = "edited \(path): "
        let oldRange = oldLines <= 1 ? "line \(startLine)" : "lines \(startLine)-\(startLine + oldLines - 1)"
        if newLines == 0 {
            head += "removed \(oldRange)"
        } else {
            let newRange = newLines == 1 ? "line \(startLine)" : "lines \(startLine)-\(startLine + newLines - 1)"
            head += "replaced \(oldRange); now \(newRange)"
        }
        if normalized { head += " (matched after normalizing trailing whitespace/CRLF)" }
        let window = contextWindow(updated, firstLine: startLine, lastLine: startLine + max(newLines, 1) - 1)
        return ok(head + "\n" + window)
    }
}

// MARK: edit_file helpers

private let editContextLines = 3
private let editShownLines = 24
private let editLineChars = 160
private let editNearMissScanLines = 20_000
private let editNearMissMaxCandidates = 3

/// Number of lines a byte span covers (a trailing newline does not start a new line); 0 for an empty span.
private func lineCount(_ b: ArraySlice<UInt8>) -> Int {
    guard !b.isEmpty else { return 0 }
    let nl = b.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    return nl + (b.last == 0x0A ? 0 : 1)
}

private func toCRLF(_ b: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(b.count + b.count / 16)
    var prev: UInt8 = 0
    for c in b {
        if c == 0x0A && prev != 0x0D { out.append(0x0D) }
        out.append(c)
        prev = c
    }
    return out
}

/// Bytes with CR and trailing spaces/tabs removed from every line; `map[i]` is the original offset of byte i.
private func normalizeLines(_ b: [UInt8], withMap: Bool) -> (bytes: [UInt8], map: [Int]) {
    var out: [UInt8] = []
    var map: [Int] = []
    out.reserveCapacity(b.count)
    var lineStart = 0
    while lineStart <= b.count {
        var lineEnd = lineStart
        while lineEnd < b.count && b[lineEnd] != 0x0A { lineEnd += 1 }
        var keep = lineEnd
        while keep > lineStart, b[keep - 1] == 0x0D || b[keep - 1] == 0x20 || b[keep - 1] == 0x09 { keep -= 1 }
        for i in lineStart..<keep {
            out.append(b[i])
            if withMap { map.append(i) }
        }
        if lineEnd < b.count {
            out.append(0x0A)
            if withMap { map.append(lineEnd) }
        }
        lineStart = lineEnd + 1
    }
    return (out, map)
}

/// Unique match of `old` in `bytes` after trailing-whitespace and CRLF normalization, as an original byte span.
private func looseSpan(_ bytes: [UInt8], _ old: String) -> (start: Int, end: Int)? {
    let o = normalizeLines([UInt8](old.utf8), withMap: false).bytes
    guard !o.isEmpty else { return nil }
    let t = normalizeLines(bytes, withMap: true)
    let hay = Data(t.bytes)
    let needle = Data(o)
    guard let first = hay.range(of: needle) else { return nil }
    if first.upperBound < hay.count, hay.range(of: needle, in: first.upperBound..<hay.count) != nil { return nil }
    let start = t.map[first.lowerBound]
    let end = t.map[first.upperBound - 1] + 1
    return (start, end)
}

private func collapse(_ s: Substring) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
}

private func snippet(_ s: Substring) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.count > editLineChars ? String(t.prefix(editLineChars)) + "..." : t
}

private func multiMatchMessage(_ text: String, _ old: String, path: String, count: Int) -> String {
    var lineNos: [Int] = []
    var searchFrom = text.startIndex
    var line = 1
    var counted = text.startIndex
    while lineNos.count < 5, let r = text.range(of: old, options: .literal, range: searchFrom..<text.endIndex) {
        line += text[counted..<r.lowerBound].utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        counted = r.lowerBound
        lineNos.append(line)
        searchFrom = r.upperBound
    }
    let where_ = lineNos.map(String.init).joined(separator: ", ") + (count > lineNos.count ? ", ..." : "")
    return "error: old matches \(count) times in \(path) (starting at lines \(where_)); nothing was changed. "
        + "Include more surrounding lines in old so it matches exactly once."
}

private func notFoundMessage(_ text: String, _ old: String, path: String) -> String {
    var msg = "error: old not found in \(path) (0 matches); nothing was changed. "
    let oldLines = old.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        .map { collapse($0.prefix(editLineChars * 2)) }
    let nonBlank = oldLines.filter { !$0.isEmpty }
    guard let anchorIndex = nonBlank.indices.max(by: { nonBlank[$0].count < nonBlank[$1].count }) else {
        return msg + "Re-read the file with read_file and copy the text exactly."
    }
    let anchor = String(nonBlank[anchorIndex].prefix(200))
    let fileLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
    var hits: [(line: Int, exact: Bool)] = []
    for (i, raw) in fileLines.prefix(editNearMissScanLines).enumerated() {
        let c = collapse(raw.prefix(editLineChars * 2))
        if c == anchor {
            hits.append((i + 1, true))
        } else if c.count >= 8, c.contains(anchor) || anchor.contains(c) {
            hits.append((i + 1, false))
        }
        if hits.count >= editNearMissMaxCandidates { break }
    }
    if hits.isEmpty {
        return msg + "No similar line found. Re-read the file with read_file and copy the text exactly."
    }
    // Whole-block check: does the old block match some candidate ignoring whitespace differences?
    var blockLines = Array(oldLines.drop(while: { $0.isEmpty }))
    while blockLines.last?.isEmpty == true { blockLines.removeLast() }
    let anchorOffset = blockLines.firstIndex(of: nonBlank[anchorIndex]) ?? 0
    for h in hits {
        let first = h.line - 1 - anchorOffset
        guard first >= 0, first + blockLines.count <= fileLines.count else { continue }
        let same = blockLines.enumerated().allSatisfy { collapse(fileLines[first + $0.offset].prefix(editLineChars * 2)) == $0.element }
        if same {
            return msg + "The text matches at lines \(first + 1)-\(first + blockLines.count) only if whitespace "
                + "(indentation or inner spacing) is ignored. Re-read those lines with read_file and copy them exactly."
        }
    }
    msg += "Closest lines:\n"
    msg += hits.map { "  \($0.line): \(snippet(fileLines[$0.line - 1]))" }.joined(separator: "\n")
    return msg + "\nRe-read the file with read_file and copy the text exactly."
}

/// Numbered lines of `bytes` from `firstLine - 3` to `lastLine + 3`; long runs keep head and tail around "...".
private func contextWindow(_ bytes: [UInt8], firstLine: Int, lastLine: Int) -> String {
    let lo = max(1, firstLine - editContextLines)
    let hi = lastLine + editContextLines
    var out: [String] = []
    var lineNo = 1
    var start = 0
    var i = 0
    while i <= bytes.count && lineNo <= hi {
        if i == bytes.count || bytes[i] == 0x0A {
            if lineNo >= lo, !(i == bytes.count && start == i && lineNo > 1) {
                var end = i
                if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                var line = String(decoding: bytes[start..<min(end, start + editLineChars * 4)], as: UTF8.self)
                if line.count > editLineChars { line = String(line.prefix(editLineChars)) + "..." }
                out.append("\(lineNo)\t\(line)")
            }
            lineNo += 1
            start = i + 1
        }
        i += 1
    }
    if out.count > editShownLines {
        let head = editShownLines / 2
        out = Array(out.prefix(head)) + ["... [\(out.count - editShownLines) lines not shown]"] + Array(out.suffix(editShownLines - head))
    }
    return out.joined(separator: "\n")
}

public struct WriteFileTool: HarnessTool {
    public let name = "write_file"
    public let spec = ToolSpec(
        name: "write_file",
        description: "Create or overwrite a UTF-8 text file in the workspace; parent directories are created. "
            + "Max 1 MB. Requires write access.",
        parameters: schema([
            ("path", prop("string", "File path relative to the workspace root.")),
            ("content", prop("string", "Full file content.")),
        ], required: ["path", "content"]))

    public init() {}

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        do { return try write(args, context) } catch { return fail(describe(error)) }
    }

    private func write(_ args: [String: OrderedJSON], _ context: ToolContext) throws -> ToolResult {
        let path = try requireString(args, "path")
        let content = try requireString(args, "content")
        guard content.utf8.count <= maxWriteBytes else {
            throw FileToolError(message: "error: content is \(content.utf8.count) bytes; limit is 1 MB")
        }
        let url = try policy(context).resolve(path, forWriting: true)
        try requireWrite(context, path)
        guard !isDirectory(url) else { throw FileToolError(message: "error: is a directory: \(path)") }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try writeAtomically(data, to: url, root: context.root)
        return ok("wrote \(data.count) bytes to \(path)")
    }
}
