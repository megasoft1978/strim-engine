import Foundation
import StrimControl

// strim install-agent <model> [mtpHead] [--port N=8203] [--token-file PATH] [--label com.strim.host]
//                     [--dir DIR=~/Library/LaunchAgents] [--log-dir DIR=~/.strim/logs] [--binary PATH]
//                     [--no-run-at-load] [--no-keep-alive] [--dry-run] [--uninstall]
//
// Writes the launchd plist and prints the launchctl command to run. Never runs launchctl itself.

enum InstallAgentCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        func fail(_ s: String) -> Int32 { FileHandle.standardError.write(Data((s + "\n").utf8)); return 2 }
        let usage = "usage: strim install-agent <model> [mtpHead] [--port N] [--token-file PATH] [--label L] [--dir DIR] [--log-dir DIR] [--binary PATH] [--no-run-at-load] [--no-keep-alive] [--allow-unsafe-binary] [--dry-run] [--uninstall]"
        var positional: [String] = []
        var port: UInt16 = 8203, tokenFile: String?, label = "com.strim.host"
        var dir = LaunchAgent.defaultDir, logDir = LaunchAgent.defaultLogDir, binary: String?
        var runAtLoad = true, keepAlive = true, dry = false, uninstall = false, allowUnsafe = false
        var i = 2
        while i < args.count {
            let a = args[i]
            func value() -> String? {
                if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") { return String(a[a.index(after: eq)...]) }
                i += 1
                return i < args.count ? args[i] : nil
            }
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            switch name {
            case "--dry-run": dry = true
            case "--allow-unsafe-binary": allowUnsafe = true
            case "--uninstall": uninstall = true
            case "--no-run-at-load": runAtLoad = false
            case "--no-keep-alive": keepAlive = false
            case "--port":
                guard let v = value(), let p = UInt16(v) else { return fail("bad --port\n" + usage) }
                port = p
            case "--token-file", "--label", "--dir", "--log-dir", "--binary":
                guard let v = value() else { return fail("missing value for \(name)") }
                switch name {
                case "--token-file": tokenFile = absolute(v)
                case "--label": label = v
                case "--dir": dir = absolute(v)
                case "--log-dir": logDir = absolute(v)
                default: binary = absolute(v)
                }
            default:
                if a.hasPrefix("--") { return fail("unknown option \(a)\n" + usage) }
                positional.append(a)
            }
            i += 1
        }
        do {
            if uninstall {
                let o = try LaunchAgent.uninstall(label: label, dir: dir, dryRun: dry)
                print(dry ? "dry run: would remove \(o.plistPath)" : "removed \(o.plistPath) (if it existed)")
                print("stop the running agent with:\n  \(o.command)")
                return 0
            }
            guard let model = positional.first, positional.count <= 2 else { return fail(usage) }
            for p in positional where !FileManager.default.fileExists(atPath: absolute(p)) {
                FileHandle.standardError.write(Data("warning: \(absolute(p)) does not exist\n".utf8))
            }
            guard let rawExe = binary ?? currentExecutablePath() else { return fail("cannot determine the strim binary path; pass --binary") }
            let exe = try LaunchAgent.validateBinary(rawExe, allowUnsafe: allowUnsafe)
            let spec = LaunchAgentSpec(binary: exe, model: absolute(model),
                                       mtpHead: positional.count > 1 ? absolute(positional[1]) : nil, port: port,
                                       tokenFile: tokenFile, label: label, runAtLoad: runAtLoad, keepAlive: keepAlive,
                                       logDir: logDir, home: NSHomeDirectory())
            let o = try LaunchAgent.install(spec, dir: dir, dryRun: dry)
            if dry {
                print("dry run: would write \(o.plistPath):\n\(o.plist ?? "")")
            } else {
                print("wrote \(o.plistPath)")
            }
            print("start it with (not run by this tool):\n  \(o.command)")
            return 0
        } catch {
            return fail("install-agent: \(error)")
        }
    }

    private static func absolute(_ p: String) -> String {
        let e = (p as NSString).expandingTildeInPath
        return URL(fileURLWithPath: e).standardizedFileURL.path
    }
}
