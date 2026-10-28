import Foundation

/// Where the per-language runners live on this machine, resolved by the HOST (never by an agent-supplied PATH).
/// Used by the verifier and by the `runtests` service so a verify command finds node, ruby, cargo, java, ... inside the
/// sandbox, which reads (never writes) these directories.
public enum Toolchains {
    static func latestChild(_ dir: String, prefix: String = "", suffix: String = "") -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
        return names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last.map { dir + "/" + $0 }
    }

    /// Existing bin dirs, most specific first: node (+ npm, npx, tsc), rust toolchain bin (cargo/rustc directly, no rustup proxy),
    /// ruby, a JDK. bun and deno live in /opt/homebrew/bin, which is already on the base PATH.
    public static func pathDirs(home: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if let n = latestChild(home + "/.nvm/versions/node", prefix: "v") { out.append(n + "/bin") }
        let tcs = home + "/.rustup/toolchains"
        if let t = ((try? fm.contentsOfDirectory(atPath: tcs)) ?? []).sorted().first(where: { $0.hasPrefix("stable-") }) { out.append(tcs + "/" + t + "/bin") }
        else if let t = latestChild(tcs, prefix: "1.") { out.append(t + "/bin") }
        if let r = latestChild(home + "/.rbenv/versions", prefix: "3.") { out.append(r + "/bin") }
        if let j = jdkHome() { out.append(j + "/bin") }
        if let p = pythonHome() { out.append(p + "/bin") }
        return out.filter { fm.fileExists(atPath: $0) }
    }

    /// The python.org framework build (exact version dir). It lives under /Library, which the sandbox already reads; the user
    /// site-packages, pip config and caches under the home stay unreadable, and `python3 -I` ignores PYTHON* variables and user site.
    public static func pythonHome() -> String? {
        latestChild("/Library/Frameworks/Python.framework/Versions", prefix: "3.").flatMap { FileManager.default.isExecutableFile(atPath: $0 + "/bin/python3") ? $0 : nil }
    }

    public static func jdkHome() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/opt/openjdk@17", "/opt/homebrew/opt/openjdk@11", "/opt/homebrew/opt/openjdk"] where fm.fileExists(atPath: p + "/bin/javac") { return p }
        return latestChild("/Library/Java/JavaVirtualMachines", suffix: ".jdk").map { $0 + "/Contents/Home" }.flatMap { fm.fileExists(atPath: $0 + "/bin/javac") ? $0 : nil }
    }

    /// Extra read-only roots under the home that the runners above need.
    public static func readable(home: String) -> [String] {
        [".rbenv/versions", ".nvm/versions", ".rustup/toolchains"].map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Offline settings and cache locations under `scratch` (never the home) for every runner, without PATH.
    public static func cacheEnv(scratch: String) -> [String: String] {
        var env: [String: String] = [:]
        env["npm_config_cache"] = scratch + "/npm"
        env["npm_config_offline"] = "true"
        env["npm_config_update_notifier"] = "false"
        env["npm_config_audit"] = "false"
        env["npm_config_fund"] = "false"
        env["DENO_DIR"] = scratch + "/deno"
        env["DENO_NO_UPDATE_CHECK"] = "1"
        env["BUN_INSTALL_CACHE_DIR"] = scratch + "/bun"
        env["CARGO_HOME"] = scratch + "/cargo"
        env["CARGO_NET_OFFLINE"] = "true"
        env["CARGO_TARGET_DIR"] = scratch + "/cargo-target"
        env["NO_COLOR"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        return env
    }

    /// Offline, cache-in-scratch settings for every runner, plus PATH with the toolchain dirs in front.
    public static func apply(to env: inout [String: String], home: String, scratch: String) {
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["PATH"] = (pathDirs(home: home) + [base]).joined(separator: ":")
        if let j = jdkHome() { env["JAVA_HOME"] = j }
        for (k, v) in cacheEnv(scratch: scratch) { env[k] = v }
        for k in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONPLATLIBDIR", "RUBYOPT", "RUBYLIB", "NODE_OPTIONS", "NODE_PATH", "CARGO_BUILD_RUSTC_WRAPPER", "RUSTC_WRAPPER", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS"] { env[k] = nil }
    }
}
