import Foundation
import ServiceManagement

/// Any JSON value, used to carry unknown app.json keys through a load/save round trip.
public enum SettingsJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([SettingsJSON]), object([String: SettingsJSON])

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([SettingsJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: SettingsJSON].self)) }
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// User settings in ~/.strim/app.json. All fields optional on disk.
public struct AppSettings: Codable, Equatable, Sendable {
    public var hostURL: String
    /// Absolute path to an existing, non-world-writable executable (validated before it is ever run).
    public var strimBinary: String?
    public var modelPath: String?
    public var mtpPath: String?
    /// Control-plane token file. Must be under the user's home; read-only in the UI. The MCP token is never used.
    public var controlTokenPath: String
    /// Folder chats work in. Chat is not offered without one (never $HOME).
    public var projectPath: String?
    /// Start the local Strim server after the model is available. Defaults on for first-run convenience.
    public var startServerWhenOpens: Bool
    /// Show the live decode speed next to the menu-bar glyph while generating.
    public var showSpeedInMenuBar: Bool
    /// Recently chosen project folders, newest first (at most `maxRecents`).
    public var recentProjects: [String]
    /// Default for new chats ("Default thinking" in Settings). A chat keeps the value it started with.
    public var thinkingEnabled: Bool
    /// The user chose "None" for the MTP head. A blank `mtp_path` alone means "use the default head", so "off" is explicit.
    public var mtpDisabled: Bool
    public static let maxRecents = 8

    public init(hostURL: String = AppPaths.defaultHostURL, strimBinary: String? = nil, modelPath: String? = nil,
                mtpPath: String? = nil, controlTokenPath: String = AppPaths.defaultControlTokenPath, projectPath: String? = nil,
                recentProjects: [String] = [], startServerWhenOpens: Bool = true, showSpeedInMenuBar: Bool = true,
                thinkingEnabled: Bool = true, mtpDisabled: Bool = false) {
        self.showSpeedInMenuBar = showSpeedInMenuBar
        self.recentProjects = recentProjects
        self.hostURL = hostURL; self.strimBinary = strimBinary; self.modelPath = modelPath
        self.mtpPath = mtpPath; self.controlTokenPath = controlTokenPath; self.projectPath = projectPath
        self.startServerWhenOpens = startServerWhenOpens
        self.thinkingEnabled = thinkingEnabled; self.mtpDisabled = mtpDisabled
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case hostURL = "host_url", strimBinary = "strim_binary", modelPath = "model_path"
        case mtpPath = "mtp_path", controlTokenPath = "control_token_path", projectPath = "project_path"
        case recentProjects = "recent_projects", startServerWhenOpens = "start_server_when_opens"
        case showSpeedInMenuBar = "show_speed_in_menu_bar"
        case thinkingEnabled = "thinking_enabled", mtpDisabled = "mtp_disabled"
    }
    /// A blank path in app.json (older builds could save one) means "use the default", never "unset".
    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    /// Keys this build does not know (older `token_path`, or written by a newer build). Kept and written back on save.
    public var unknownKeys: [String: SettingsJSON] = [:]

    /// Each key decodes on its own: a value of the wrong type (a string for a bool, a number for a path) falls back to
    /// that key's default instead of discarding the whole file.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        hostURL = get(.hostURL) ?? AppPaths.defaultHostURL
        strimBinary = Self.nonEmpty(get(.strimBinary))
        modelPath = Self.nonEmpty(get(.modelPath))
        mtpPath = Self.nonEmpty(get(.mtpPath))
        controlTokenPath = get(.controlTokenPath) ?? AppPaths.defaultControlTokenPath
        projectPath = Self.nonEmpty(get(.projectPath))
        recentProjects = get(.recentProjects) ?? []
        startServerWhenOpens = get(.startServerWhenOpens) ?? true
        showSpeedInMenuBar = get(.showSpeedInMenuBar) ?? true
        thinkingEnabled = get(.thinkingEnabled) ?? true
        mtpDisabled = get(.mtpDisabled) ?? false
        if let all = try? d.container(keyedBy: SettingsJSON.AnyKey.self) {
            let known = Set(CodingKeys.allCases.map(\.rawValue))
            for k in all.allKeys where !known.contains(k.stringValue) {
                if let v = try? all.decode(SettingsJSON.self, forKey: k) { unknownKeys[k.stringValue] = v }
            }
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: SettingsJSON.AnyKey.self)
        for (k, v) in unknownKeys { try c.encode(v, forKey: .init(k)) }
        // Known keys last so they always win over a same-named unknown entry.
        try c.encode(hostURL, forKey: .init(CodingKeys.hostURL.rawValue))
        try c.encodeIfPresent(strimBinary, forKey: .init(CodingKeys.strimBinary.rawValue))
        try c.encodeIfPresent(modelPath, forKey: .init(CodingKeys.modelPath.rawValue))
        try c.encodeIfPresent(mtpPath, forKey: .init(CodingKeys.mtpPath.rawValue))
        try c.encode(controlTokenPath, forKey: .init(CodingKeys.controlTokenPath.rawValue))
        try c.encodeIfPresent(projectPath, forKey: .init(CodingKeys.projectPath.rawValue))
        try c.encode(recentProjects, forKey: .init(CodingKeys.recentProjects.rawValue))
        try c.encode(startServerWhenOpens, forKey: .init(CodingKeys.startServerWhenOpens.rawValue))
        try c.encode(showSpeedInMenuBar, forKey: .init(CodingKeys.showSpeedInMenuBar.rawValue))
        try c.encode(thinkingEnabled, forKey: .init(CodingKeys.thinkingEnabled.rawValue))
        try c.encode(mtpDisabled, forKey: .init(CodingKeys.mtpDisabled.rawValue))
    }

    /// nil when `host_url` is not a plain loopback http URL with a port.
    public var validatedURL: URL? { HostURL.url(hostURL) }
    public var hostURLProblem: String? { HostURL.validate(hostURL) }
    /// Validated URL, or the default one when the configured value is rejected (the client itself fails closed).
    public var url: URL { validatedURL ?? URL(string: AppPaths.defaultHostURL)! }
    public var port: Int { url.port ?? 8203 }

    /// Result of reading app.json: the settings plus a notice when the file was unusable.
    public struct LoadReport: Sendable {
        public var settings: AppSettings
        /// Set when the file was corrupt: names the backup the bad file was moved to.
        public var notice: String?
        public var backupPath: String?
    }
    /// Missing file yields defaults. A corrupt file is moved to `<path>.bad-<timestamp>` (so the next save cannot destroy
    /// the user's settings), defaults are used, and the report carries the notice for the caller to show.
    public static func load(path: String = AppPaths.settingsPath) -> AppSettings {
        loadReport(path: path).settings
    }
    public static func loadReport(path: String = AppPaths.settingsPath, now: Date = Date()) -> LoadReport {
        guard let d = FileManager.default.contents(atPath: path) else { return LoadReport(settings: AppSettings()) }
        if let s = try? JSONDecoder().decode(AppSettings.self, from: d) { return LoadReport(settings: s) }
        // Not a JSON object (truncated, binary, or an array): keep the bytes aside, never overwrite them.
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var bad = path + ".bad-" + f.string(from: now)
        var n = 1
        while FileManager.default.fileExists(atPath: bad) { n += 1; bad = path + ".bad-" + f.string(from: now) + "-\(n)" }
        if (try? SecureFS.writeAtomically(d, to: bad)) != nil {
            try? FileManager.default.removeItem(atPath: path)
            return LoadReport(settings: AppSettings(), notice: "Settings file was unreadable; using defaults. The old file was kept as \(bad).", backupPath: bad)
        }
        return LoadReport(settings: AppSettings(), notice: "Settings file was unreadable and could not be backed up; using defaults. The old file is still at app.json until settings are next saved.", backupPath: nil)
    }
    /// 0600 file in a 0700 directory, written atomically.
    public func save(path: String = AppPaths.settingsPath) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFS.writeAtomically(try enc.encode(self), to: path)
    }
}

// MARK: secure file helpers

public struct SecureFSError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

public enum SecureFS {
    /// Creates `path` (and parents) and makes the final directory `mode`, owned by the current user.
    public static func ensureDir(_ path: String, mode: mode_t = 0o700) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(mode)])
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw SecureFSError(message: "\(path) is not a directory") }
        guard st.st_uid == getuid() else { throw SecureFSError(message: "\(path) is owned by another user") }
        if (st.st_mode & 0o7777) != mode, chmod(path, mode) != 0 { throw SecureFSError(message: "cannot set permissions on \(path)") }
    }

    /// Writes via an exclusive, no-follow temp file created with `fileMode`, then renames into place.
    public static func writeAtomically(_ data: Data, to path: String, fileMode: mode_t = 0o600, dirMode: mode_t = 0o700) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try ensureDir(dir, mode: dirMode)
        let tmp = dir + "/." + (path as NSString).lastPathComponent + "." + UUID().uuidString + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
        guard fd >= 0 else { throw SecureFSError(message: "cannot create \(tmp): \(String(cString: strerror(errno)))") }
        var ok = fchmod(fd, fileMode) == 0
        data.withUnsafeBytes { raw in
            var off = 0
            while ok, off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { ok = false } else { off += n }
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw SecureFSError(message: "cannot write \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Opens a log file for appending, creating it 0600 in a 0700 directory. Refuses symlinks.
    public static func openAppend(_ path: String, fileMode: mode_t = 0o600, dirMode: mode_t = 0o700) throws -> FileHandle {
        try ensureDir((path as NSString).deletingLastPathComponent, mode: dirMode)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, fileMode)
        guard fd >= 0 else { throw SecureFSError(message: "cannot open \(path): \(String(cString: strerror(errno)))") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            close(fd); throw SecureFSError(message: "\(path) is not a regular file owned by you")
        }
        if (st.st_mode & 0o7777) != fileMode { fchmod(fd, fileMode) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Validation for `strim_binary` before the app executes it.
public enum BinaryValidator {
    /// nil when the path is acceptable; otherwise the reason it is not.
    public static func validate(_ path: String) -> String? {
        if path.isEmpty { return "path is empty" }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return "path contains control characters" }
        guard path.hasPrefix("/") else { return "must be an absolute path (got \(DiffText.visible(path)))" }
        if path.split(separator: "/", omittingEmptySubsequences: true).contains(where: { $0 == ".." || $0 == "." }) {
            return "must be a normalised path without '.' or '..'"
        }
        var st = stat()
        guard stat(path, &st) == 0 else { return "does not exist" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return "is not a regular file" }
        if st.st_mode & S_IWOTH != 0 { return "is world-writable" }
        guard st.st_uid == getuid() || st.st_uid == 0 else { return "is owned by another user" }
        guard access(path, X_OK) == 0 else { return "is not executable" }
        return nil
    }
}

// MARK: host launching

public enum HostLaunchResult: Equatable, Sendable {
    case started(pid: Int32)
    /// Binary not found; `command` is what the user should run in Terminal.
    case binaryMissing(command: String)
    /// `strim_binary` failed validation and was NOT executed; `command` is what to run by hand.
    case binaryInvalid(reason: String, command: String)
    case needsModel
    case failed(String)
}

public protocol HostLauncher: Sendable {
    func start(settings: AppSettings) -> HostLaunchResult
}

public enum HostCommand {
    /// `~` and `~/x` expand to the home directory; a relative path is taken relative to home (the app has no meaningful cwd).
    public static func expandPath(_ p: String, home: String = AppPaths.home) -> String {
        let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "~" { return home }
        if t.hasPrefix("~/") { return home + String(t.dropFirst(1)) }
        if t.hasPrefix("/") || t.hasPrefix("-") { return t }
        return (home as NSString).appendingPathComponent(t)
    }
    /// Arguments after the binary: `serve <model> [mtp] --port N`. Option-like paths are refused.
    public static func arguments(settings: AppSettings, stateDir: String? = nil) -> [String]? {
        guard let m = AppSettings.nonEmpty(settings.modelPath), !m.hasPrefix("-") else { return nil }
        var a = ["serve", expandPath(m)]
        if !settings.mtpDisabled, let t = AppSettings.nonEmpty(settings.mtpPath) {
            guard !t.hasPrefix("-") else { return nil }
            a.append(expandPath(t))
        }
        a += ["--port", String(settings.port)]
        if let stateDir {
            a += ["--state-dir", stateDir, "--token-file", (stateDir as NSString).appendingPathComponent("token")]
        }
        return a
    }
    public static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_@%+=:,./~-]+$"#, options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func commandLine(binary: String, settings: AppSettings, stateDir: String? = nil) -> String? {
        guard let a = arguments(settings: settings, stateDir: stateDir) else { return nil }
        return ([binary] + a).map(shellQuote).joined(separator: " ")
    }
    /// Candidates in order: bundled `Contents/Resources/strim`, a `strim` next to the app executable, `~/.strim/bin`,
    /// every absolute `$PATH` entry, then the Homebrew locations. The arguments exist so tests can inject them.
    public static func defaultBinaries(resourcePath: String? = Bundle.main.bundleIdentifier == "dev.strim.Strim" ? Bundle.main.resourcePath : nil,
                                       executableDir: String? = Bundle.main.executableURL?.deletingLastPathComponent().path,
                                       path: String? = ProcessInfo.processInfo.environment["PATH"],
                                       home: String = AppPaths.home,
                                       fallbacks: [String] = ["/opt/homebrew/bin/strim", "/usr/local/bin/strim"]) -> [String] {
        // Strim.app ships the CLI at Contents/Resources/strim (packaging/app/make-app.sh); try it first so the
        // app works without Homebrew. Absent when running from `swift run`.
        var c: [String] = []
        if let r = resourcePath { c.append(r + "/strim") }
        if let e = executableDir { c.append(e + "/strim") }
        c.append(home + "/.strim/bin/strim")
        for dir in (path ?? "").split(separator: ":") where dir.hasPrefix("/") { c.append((String(dir) as NSString).appendingPathComponent("strim")) }
        c += fallbacks
        var seen = Set<String>()
        return c.filter { seen.insert($0).inserted }
    }
    public enum Resolution: Equatable, Sendable { case found(String), missing, invalid(String) }
    /// A configured `strim_binary` is used only if valid (never silently replaced); otherwise the first valid default.
    /// When no default is usable but one exists on disk (for example not executable), that is reported instead of "missing".
    public static func resolveBinary(settings: AppSettings, candidates: [String]? = nil) -> Resolution {
        if let b = AppSettings.nonEmpty(settings.strimBinary) {
            if let why = BinaryValidator.validate(b) { return .invalid("\(b) \(why)") }
            return .found(b)
        }
        var firstProblem: String?
        for c in candidates ?? defaultBinaries() {
            guard let why = BinaryValidator.validate(c) else { return .found(c) }
            if firstProblem == nil, why != "does not exist" { firstProblem = "\(c) \(why)" }
        }
        if let p = firstProblem { return .invalid(p) }
        return .missing
    }
}

/// Runs `strim serve` as a detached child writing to ~/.strim/host.log (0600). Never needs a login.
public struct ProcessHostLauncher: HostLauncher {
    public let stateDir: String?
    /// A process that exits within this many seconds is reported as a failed start with the last log lines.
    /// A healthy start therefore returns after about this long.
    public let startupGrace: Double
    /// Overrides binary discovery (tests); nil uses `HostCommand.defaultBinaries()`.
    public let binaryCandidates: [String]?
    public init(stateDir: String? = nil, startupGrace: Double = 1.0, binaryCandidates: [String]? = nil) {
        self.stateDir = stateDir; self.startupGrace = startupGrace; self.binaryCandidates = binaryCandidates
    }
    public var logPath: String { stateDir.map { ($0 as NSString).appendingPathComponent("host.log") } ?? AppPaths.hostLogPath }

    /// Last `count` non-empty lines of the log written at or after `offset`.
    static func tail(of path: String, from offset: UInt64, count: Int = 8) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(count).joined(separator: "\n")
    }

    public func start(settings: AppSettings) -> HostLaunchResult {
        guard let args = HostCommand.arguments(settings: settings, stateDir: stateDir) else { return .needsModel }
        let manual = HostCommand.commandLine(binary: "strim", settings: settings, stateDir: stateDir) ?? "strim serve"
        let bin: String
        switch HostCommand.resolveBinary(settings: settings, candidates: binaryCandidates) {
        case .missing: return .binaryMissing(command: manual)
        case .invalid(let why): return .binaryInvalid(reason: why, command: manual)
        case .found(let b): bin = b
        }
        // A doomed server (missing weights) would only fail later with an opaque log line; say so up front.
        var launchArgs = args
        var isDir: ObjCBool = false
        let model = args[1]
        guard FileManager.default.fileExists(atPath: model, isDirectory: &isDir) else {
            return .failed("model not found at \(model). Choose a model in Settings or let Strim download one.")
        }
        // `strim serve` takes the model as a folder (EngineConfig modelDir); a plain file can never load.
        guard isDir.boolValue else {
            return .failed("model not found at \(model): it is not a model folder. Choose a model in Settings or let Strim download one.")
        }
        // The MTP head is optional for `strim serve [mtpHead]`: without it the server runs plain decoding. Drop a
        // missing one rather than refuse to start; the note goes to the log.
        var note: String?
        if args.count > 2, args[2] != "--port", !FileManager.default.fileExists(atPath: args[2]) {
            note = "strim app: MTP head not found at \(args[2]); starting without MTP (slower decoding)."
            launchArgs.remove(at: 2)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = launchArgs
        do {
            let log = try SecureFS.openAppend(logPath)
            let offset = log.seekToEndOfFile()
            if let note { log.write(Data((note + "\n").utf8)) }
            p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            try p.run()
            if startupGrace > 0, exited.wait(timeout: .now() + startupGrace) == .success {
                let why = Self.tail(of: logPath, from: offset)
                return .failed("strim exited with status \(p.terminationStatus) right after starting." + (why.isEmpty ? " Log: \(logPath)" : "\n" + why))
            }
            return .started(pid: p.processIdentifier)
        } catch { return .failed(error.localizedDescription) }
    }
}

// MARK: MCP registration commands

public protocol McpCommandProvider: Sendable {
    /// Registration commands for Claude and Codex. Must never contain the token value.
    func commands(settings: AppSettings) async -> String
}

public enum McpTemplate {
    /// Same text as `strim mcp-config`, used when the CLI is not installed.
    public static func render(port: Int) -> String {
        let url = "http://127.0.0.1:\(port)/mcp"
        let hdr = "-t http strim \(url) -H \"Authorization: Bearer $(cat ~/.strim/token)\""
        return "# Claude Code (run inside the project that should delegate)\nclaude mcp add -s local \(hdr)\n"
            + "# Codex\nexport STRIM_TOKEN=$(cat ~/.strim/token)\ncodex mcp add strim --url \(url) --bearer-token-env-var STRIM_TOKEN\n"
    }
}

public struct CLIMcpCommandProvider: McpCommandProvider {
    public init() {}
    public func commands(settings: AppSettings) async -> String {
        guard case .found(let bin) = HostCommand.resolveBinary(settings: settings) else {
            return McpTemplate.render(port: settings.port)
        }
        func run(_ flag: String) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["mcp-config", flag, "--port", String(settings.port)]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
        }
        return await Task.detached {
            if let c = run("--claude"), let x = run("--codex") { return "# Claude Code\n" + c + "\n# Codex\n" + x }
            return McpTemplate.render(port: settings.port)
        }.value
    }
}

// MARK: login item and clipboard

public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ on: Bool) throws
}

public struct SMLoginItem: LoginItemControlling {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

public protocol ClipboardWriting: Sendable {
    func copy(_ text: String)
}

/// Time source, injectable so backoff is testable.
public protocol AppClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: AppClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }
}

/// Exponential backoff: base * 2^n capped at `cap`.
public struct Backoff: Equatable, Sendable {
    public var base: Double, cap: Double
    public private(set) var attempt = 0
    public init(base: Double = 1, cap: Double = 30) { self.base = base; self.cap = cap }
    public mutating func next() -> Double {
        let d = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return d
    }
    public mutating func reset() { attempt = 0 }
}

import AppKit

public struct PasteboardClipboard: ClipboardWriting {
    public init() {}
    public func copy(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
