import Foundation

public struct LaunchAgentError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Settings of the launchd job that keeps `strim serve` running.
public struct LaunchAgentSpec: Sendable, Equatable {
    public var label = "com.strim.host"
    /// Absolute path of the `strim` binary.
    public var binary: String
    public var model: String
    public var mtpHead: String?
    public var port: UInt16 = 8203
    public var tokenFile: String?
    public var runAtLoad = true
    public var keepAlive = true
    public var logDir: String
    public var home: String

    public init(binary: String, model: String, mtpHead: String? = nil, port: UInt16 = 8203, tokenFile: String? = nil,
                label: String = "com.strim.host", runAtLoad: Bool = true, keepAlive: Bool = true,
                logDir: String, home: String) {
        self.binary = binary; self.model = model; self.mtpHead = mtpHead; self.port = port; self.tokenFile = tokenFile
        self.label = label; self.runAtLoad = runAtLoad; self.keepAlive = keepAlive; self.logDir = logDir; self.home = home
    }

    public var programArguments: [String] {
        var a = [binary, "serve", model]
        if let mtpHead { a.append(mtpHead) }
        a += ["--port", String(port)]
        if let tokenFile { a += ["--token-file", tokenFile] }
        return a
    }
}

/// Path of the running executable (never argv[0] resolved against the cwd).
public func currentExecutablePath() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return Bundle.main.executablePath }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Builds, writes and removes the launchd plist. Never runs `launchctl`: callers print the command for the user.
public enum LaunchAgent {
    public static var defaultDir: String { NSHomeDirectory() + "/Library/LaunchAgents" }
    public static var defaultLogDir: String { NSHomeDirectory() + "/.strim/logs" }

    public static func validate(label: String) throws {
        let ok = !label.isEmpty && label.count <= 128 && !label.hasPrefix(".")
            && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) && $0.isASCII }
        guard ok else { throw LaunchAgentError("invalid label \"\(label)\" (letters, digits, '.', '_', '-' only)") }
    }

    public static func dictionary(_ s: LaunchAgentSpec) -> [String: Any] {
        [
            "Label": s.label,
            "ProgramArguments": s.programArguments,
            "RunAtLoad": s.runAtLoad,
            "KeepAlive": s.keepAlive,
            "ThrottleInterval": 30,                 // a config error must not become a restart storm
            "ProcessType": "Interactive",
            "StandardOutPath": s.logDir + "/host.out.log",
            "StandardErrorPath": s.logDir + "/host.err.log",
            "WorkingDirectory": s.home,
            "EnvironmentVariables": [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
                "HOME": s.home,
            ],
        ]
    }

    public static func plistData(_ s: LaunchAgentSpec) throws -> Data {
        try validate(label: s.label)
        return try PropertyListSerialization.data(fromPropertyList: dictionary(s), format: .xml, options: 0)
    }

    /// The binary launchd will run on every login: a real, executable, regular file that nobody else can replace.
    /// Refuses temp directories and group/world-writable files or directories on the path unless `allowUnsafe`.
    /// Returns the resolved (symlink-free) path.
    public static func validateBinary(_ path: String, allowUnsafe: Bool) throws -> String {
        try validateBinary(path, allowUnsafe: allowUnsafe, temporaryRoots: nil, directoryBoundary: nil)
    }

    static func validateBinary(_ path: String, allowUnsafe: Bool, temporaryRoots: [String]?, directoryBoundary: String?) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { throw LaunchAgentError("binary \(path) does not exist") }
        let real = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var st = stat()
        guard stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(real, X_OK) == 0 else {
            throw LaunchAgentError("\(real) is not an executable regular file")
        }
        if allowUnsafe { return real }
        var temps = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"]
        var tbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(NSTemporaryDirectory(), &tbuf) != nil {
            temps.append(String(decoding: tbuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        for t in temporaryRoots ?? temps where real == t || real.hasPrefix(t.hasSuffix("/") ? t : t + "/") {
            throw LaunchAgentError("\(real) is in a temporary directory; install the binary somewhere stable or pass --allow-unsafe-binary")
        }
        if st.st_mode & 0o022 != 0 {
            throw LaunchAgentError("\(real) is group/world-writable; pass --allow-unsafe-binary to use it anyway")
        }
        var dir = (real as NSString).deletingLastPathComponent
        let boundary = directoryBoundary.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        while true {
            var ds = stat()
            if stat(dir, &ds) == 0, ds.st_mode & 0o002 != 0, ds.st_mode & S_ISVTX == 0 || true {
                throw LaunchAgentError("directory \(dir) is world-writable; pass --allow-unsafe-binary to use \(real) anyway")
            }
            if dir == boundary || dir == "/" || dir.isEmpty { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return real
    }

    public static func plistPath(dir: String, label: String) -> String { dir + "/" + label + ".plist" }

    public static func bootstrapCommand(plist: String, uid: uid_t = getuid()) -> String { "launchctl bootstrap gui/\(uid) \(plist)" }
    public static func bootoutCommand(label: String, uid: uid_t = getuid()) -> String { "launchctl bootout gui/\(uid)/\(label)" }

    public struct Outcome: Sendable, Equatable {
        public var plistPath: String
        public var plist: String?        // dry-run: the content that would be written
        public var written: Bool
        public var command: String
    }

    /// Writes `<dir>/<label>.plist` (0644, atomically) and creates the log dir (0700). `dryRun` touches nothing.
    @discardableResult
    public static func install(_ s: LaunchAgentSpec, dir: String, dryRun: Bool) throws -> Outcome {
        let data = try plistData(s)
        let path = plistPath(dir: dir, label: s.label)
        let cmd = bootstrapCommand(plist: path)
        if dryRun { return Outcome(plistPath: path, plist: String(decoding: data, as: UTF8.self), written: false, command: cmd) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(atPath: s.logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG { throw LaunchAgentError("\(path) exists and is not a regular file") }
        let tmp = dir + "/.\(s.label).plist.\(UUID().uuidString).tmp"
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw LaunchAgentError("cannot write \(tmp)")
        }
        if rename(tmp, path) != 0 { unlink(tmp); throw LaunchAgentError("cannot move plist into place: \(String(cString: strerror(errno)))") }
        return Outcome(plistPath: path, plist: nil, written: true, command: cmd)
    }

    /// Removes `<dir>/<label>.plist` only (a regular file); returns the `bootout` command to run first/after.
    @discardableResult
    public static func uninstall(label: String, dir: String, dryRun: Bool) throws -> Outcome {
        try validate(label: label)
        let path = plistPath(dir: dir, label: label)
        let cmd = bootoutCommand(label: label)
        var st = stat()
        let exists = lstat(path, &st) == 0
        if exists, (st.st_mode & S_IFMT) != S_IFREG { throw LaunchAgentError("\(path) is not a regular file; not removing it") }
        if exists, !dryRun { unlink(path) }
        return Outcome(plistPath: path, plist: nil, written: false, command: cmd)
    }
}
