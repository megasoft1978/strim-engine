import Foundation
import StrimHarness

/// File locations of one Strim host. Defaults live under `~/.strim`.
public struct HostPaths: Sendable {
    public var root: URL
    public var tokenPathOverride: String?
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim"),
                tokenPath: String? = nil) {
        self.root = root; self.tokenPathOverride = tokenPath
    }
    public static var `default`: HostPaths { HostPaths() }
    public var config: URL { root.appendingPathComponent("config.json") }
    public var token: URL { tokenPathOverride.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("token") }
    public var lock: URL { root.appendingPathComponent("host.lock") }
    public var jobs: URL { root.appendingPathComponent("jobs", isDirectory: true) }
}

public struct HostConfigError: Error, CustomStringConvertible {
    public let description: String
}

/// Host settings from `~/.strim/config.json` (`{"mcp": {"requireApproval", "maxAccess", "allowedRoots"}}`).
/// Missing file or keys fall back to the defaults. Invalid values fail loudly (a policy file must not be
/// silently ignored).
public struct HostConfig: Sendable, Equatable {
    public var requireApproval = false
    public var maxAccess: AccessLevel = .write
    /// Empty: any cwd. Otherwise a job's cwd must be inside one of these directories.
    public var allowedRoots: [String] = []
    public init(requireApproval: Bool = false, maxAccess: AccessLevel = .write, allowedRoots: [String] = []) {
        self.requireApproval = requireApproval; self.maxAccess = maxAccess; self.allowedRoots = allowedRoots
    }

    /// Loads `url`; tightens a group/other-accessible file to 0600.
    public static func load(from url: URL) throws -> HostConfig {
        var cfg = HostConfig()
        guard FileManager.default.fileExists(atPath: url.path) else { return cfg }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mode = attrs[.posixPermissions] as? Int, mode & 0o077 != 0 {
            chmod(url.path, 0o600)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw HostConfigError(description: "cannot read \(url.path): \(error.localizedDescription)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostConfigError(description: "\(url.path): not a JSON object")
        }
        guard let mcp = obj["mcp"] else { return cfg }
        guard let m = mcp as? [String: Any] else { throw HostConfigError(description: "\(url.path): \"mcp\" must be an object") }
        if let v = m["requireApproval"] {
            guard let b = v as? Bool else { throw HostConfigError(description: "\(url.path): mcp.requireApproval must be a boolean") }
            cfg.requireApproval = b
        }
        if let v = m["maxAccess"] {
            guard let s = v as? String, let a = AccessLevel(rawValue: s) else {
                throw HostConfigError(description: "\(url.path): mcp.maxAccess must be \"read\" or \"write\"")
            }
            cfg.maxAccess = a
        }
        if let v = m["allowedRoots"] {
            guard let arr = v as? [String] else { throw HostConfigError(description: "\(url.path): mcp.allowedRoots must be an array of strings") }
            cfg.allowedRoots = arr.map { ($0 as NSString).expandingTildeInPath }
        }
        return cfg
    }

    /// Writes the config as 0600 JSON.
    public func write(to url: URL) throws {
        let obj: [String: Any] = ["mcp": ["requireApproval": requireApproval, "maxAccess": maxAccess.rawValue,
                                          "allowedRoots": allowedRoots]]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HostConfigError(description: "cannot write \(url.path)")
        }
        chmod(url.path, 0o600)
    }
}

extension HostConfig {
    /// What `strim serve` runs with: an unset (empty) `mcp.allowedRoots` becomes the home directory instead of "any
    /// cwd". `HostConfig()` itself stays unrestricted so tests can inject it. `defaulted` is true when the default applied.
    public func withProductionDefaults(home: String = NSHomeDirectory()) -> (config: HostConfig, defaulted: Bool) {
        guard allowedRoots.isEmpty else { return (self, false) }
        var c = self
        c.allowedRoots = [home]
        return (c, true)
    }
}

/// Access and path limits applied to every MCP-originated job before it is submitted.
public struct HostPolicy: Sendable {
    public var maxAccess: AccessLevel
    public var allowedRoots: [String]
    public init(maxAccess: AccessLevel, allowedRoots: [String]) { self.maxAccess = maxAccess; self.allowedRoots = allowedRoots }
    public init(_ c: HostConfig) { self.init(maxAccess: c.maxAccess, allowedRoots: c.allowedRoots) }

    /// A human-readable rejection, or nil when the request is allowed. `access` is the raw requested value.
    public func violation(access: String?, cwd: String?, home: String = NSHomeDirectory()) -> String? {
        if access == "write", maxAccess == .read {
            return "access=write rejected: this host allows read access only (mcp.maxAccess=read in ~/.strim/config.json). Retry with access=read."
        }
        if let cwd, !cwd.isEmpty, let why = SensitiveDirs.refuse(path: cwd, home: home) {
            return "cwd \(cwd) rejected: \(why)."
        }
        if !allowedRoots.isEmpty {
            guard let cwd, !cwd.isEmpty else { return "cwd is required and must be inside an allowed root (mcp.allowedRoots)." }
            let real = Self.canonical(cwd)
            let ok = allowedRoots.contains { root in
                let r = Self.canonical(root)
                return real == r || real.hasPrefix(r.hasSuffix("/") ? r : r + "/")
            }
            if !ok { return "cwd \(cwd) is outside the allowed roots (mcp.allowedRoots in ~/.strim/config.json); canonical path: \(real)." }
        }
        return nil
    }

    /// Standardized path with symlinks resolved for the longest existing ancestor (the rest may not exist yet).
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        while url.path != "/" {
            if realpath(url.path, &buf) != nil {
                let base = String(cString: buf)
                return rest.reversed().reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            rest.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        return rest.reversed().reduce("") { $0 + "/" + $1 }
    }
}
