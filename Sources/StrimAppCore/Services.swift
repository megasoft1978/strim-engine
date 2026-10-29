import Foundation
import ServiceManagement

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
    /// Recently chosen project folders, newest first (at most `maxRecents`).
    public var recentProjects: [String]
    public static let maxRecents = 8

    public init(hostURL: String = AppPaths.defaultHostURL, strimBinary: String? = nil, modelPath: String? = nil,
                mtpPath: String? = nil, controlTokenPath: String = AppPaths.defaultControlTokenPath, projectPath: String? = nil,
                recentProjects: [String] = []) {
        self.recentProjects = recentProjects
        self.hostURL = hostURL; self.strimBinary = strimBinary; self.modelPath = modelPath
        self.mtpPath = mtpPath; self.controlTokenPath = controlTokenPath; self.projectPath = projectPath
    }
    enum CodingKeys: String, CodingKey {
        case hostURL = "host_url", strimBinary = "strim_binary", modelPath = "model_path"
        case mtpPath = "mtp_path", controlTokenPath = "control_token_path", projectPath = "project_path"
        case recentProjects = "recent_projects"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        hostURL = try c.decodeIfPresent(String.self, forKey: .hostURL) ?? AppPaths.defaultHostURL
        strimBinary = try c.decodeIfPresent(String.self, forKey: .strimBinary)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        mtpPath = try c.decodeIfPresent(String.self, forKey: .mtpPath)
        controlTokenPath = try c.decodeIfPresent(String.self, forKey: .controlTokenPath) ?? AppPaths.defaultControlTokenPath
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
    }

    /// nil when `host_url` is not a plain loopback http URL with a port.
    public var validatedURL: URL? { HostURL.url(hostURL) }
    public var hostURLProblem: String? { HostURL.validate(hostURL) }
    /// Validated URL, or the default one when the configured value is rejected (the client itself fails closed).
    public var url: URL { validatedURL ?? URL(string: AppPaths.defaultHostURL)! }
    public var port: Int { url.port ?? 8203 }

    /// Missing or unreadable file yields defaults.
    public static func load(path: String = AppPaths.settingsPath) -> AppSettings {
        guard let d = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
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
    /// Arguments after the binary: `serve <model> [mtp] --port N`. Option-like paths are refused.
    public static func arguments(settings: AppSettings) -> [String]? {
        guard let m = settings.modelPath, !m.isEmpty, !m.hasPrefix("-") else { return nil }
        var a = ["serve", m]
        if let t = settings.mtpPath, !t.isEmpty {
            guard !t.hasPrefix("-") else { return nil }
            a.append(t)
        }
        a += ["--port", String(settings.port)]
        return a
    }
    public static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_@%+=:,./~-]+$"#, options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func commandLine(binary: String, settings: AppSettings) -> String? {
        guard let a = arguments(settings: settings) else { return nil }
        return ([binary] + a).map(shellQuote).joined(separator: " ")
    }
    public static func defaultBinaries() -> [String] {
        // Strim.app ships the CLI at Contents/Resources/strim (packaging/app/make-app.sh); try it first so the
        // app works without Homebrew. Absent when running from `swift run`.
        var c: [String] = []
        if let r = Bundle.main.resourcePath, Bundle.main.bundleIdentifier == "dev.strim.Strim" { c.append(r + "/strim") }
        return c + [AppPaths.home + "/.strim/bin/strim", "/opt/homebrew/bin/strim", "/usr/local/bin/strim"]
    }
    public enum Resolution: Equatable, Sendable { case found(String), missing, invalid(String) }
    /// A configured `strim_binary` is used only if valid (never silently replaced); otherwise the first valid default.
    public static func resolveBinary(settings: AppSettings) -> Resolution {
        if let b = settings.strimBinary, !b.isEmpty {
            if let why = BinaryValidator.validate(b) { return .invalid(why) }
            return .found(b)
        }
        for c in defaultBinaries() where BinaryValidator.validate(c) == nil { return .found(c) }
        return .missing
    }
}

/// Runs `strim serve` as a detached child writing to ~/.strim/host.log (0600). Never needs a login.
public struct ProcessHostLauncher: HostLauncher {
    public init() {}
    public func start(settings: AppSettings) -> HostLaunchResult {
        guard let args = HostCommand.arguments(settings: settings) else { return .needsModel }
        let manual = HostCommand.commandLine(binary: "strim", settings: settings) ?? "strim serve"
        let bin: String
        switch HostCommand.resolveBinary(settings: settings) {
        case .missing: return .binaryMissing(command: manual)
        case .invalid(let why): return .binaryInvalid(reason: why, command: manual)
        case .found(let b): bin = b
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        do {
            let log = try SecureFS.openAppend(AppPaths.hostLogPath)
            log.seekToEndOfFile()
            p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
            try p.run()
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
