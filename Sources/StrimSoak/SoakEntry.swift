import Foundation
import StrimAgentBench

/// `strim soak` dispatch: parse, pre-flight checks, GPU lock, then one `SoakSession`. Returns the exit code.
public enum SoakEntry {
    public static func run(_ argv: [String], executable: String, cwd: String, home: String,
                           env: [String: String]) -> Int32 {
        let mode: SoakMode
        do { mode = try SoakArgs.parse(argv, cwd: cwd, home: home, env: env) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n\(SoakArgs.usage)\n".utf8))
            return 2
        }
        switch mode {
        case .help:
            print(SoakArgs.usage)
            return 0
        case .listTasks:
            listTasks()
            return 0
        case .summarize(let dir):
            return summarize(dir)
        case .run(let opts):
            return runSoak(opts, executable: executable, cwd: cwd)
        }
    }

    public static func listTasks() {
        for (i, t) in SoakTasks.all.enumerated() {
            let idx = i < 10 ? "0\(i)" : "\(i)"
            print("\(idx) \(t.id): \(t.prompt)")
            let unchanged = t.unchanged.isEmpty ? "" : "; must stay unchanged: \(t.unchanged.joined(separator: ", "))"
            print("     checks: \(t.checks.count) check(s) in the toy repo\(unchanged)")
        }
    }

    /// Re-renders summary.txt from an existing results dir (no server, no clients).
    static func summarize(_ dir: String) -> Int32 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir + "/tasks.jsonl") || fm.fileExists(atPath: dir + "/run.json") else {
            FileHandle.standardError.write(Data("no soak results in \(dir)\n".utf8))
            return 1
        }
        let cfg = readObject(dir + "/run.json") ?? ["started": "unknown (no run.json)"]
        let text = SoakSummary.render(name: URL(fileURLWithPath: dir).lastPathComponent, cfg: cfg,
                                      tasks: readRows(dir + "/tasks.jsonl"), events: readRows(dir + "/server.jsonl"),
                                      serverLog: (try? String(contentsOfFile: dir + "/server.log", encoding: .utf8)) ?? "")
        try? text.write(toFile: dir + "/summary.txt", atomically: false, encoding: .utf8)
        print(text)
        return 0
    }

    static func runSoak(_ opts: SoakOptions, executable: String, cwd: String) -> Int32 {
        func fail(_ s: String) -> Int32 {
            FileHandle.standardError.write(Data((s + "\n").utf8))
            return 1
        }
        var isDir: ObjCBool = false
        for p in [opts.model, opts.head] {
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                return fail("missing model directory: \(p) (pass --model/--head or run from the repo root)")
            }
        }
        guard let go = SoakProc.which("go") else {
            return fail("go not found on PATH (the toy-repo checks run go test)")
        }
        if portOpen(opts.port) { return fail("port \(opts.port) already in use; refusing to attach to a foreign server") }

        Interrupt.install()
        let lock: FileLock
        do {
            lock = try FileLock.acquire(path: opts.lockPath, timeout: opts.lockWaitS) {
                print("waiting for GPU lock \(opts.lockPath) ...")
            }
        } catch { return fail("\(error)") }
        defer { lock.release() }

        let out = opts.out ?? cwd + "/bench/soak/results/" + SoakClock.stamp()
        let claudeDir = out + "/isolated/claude-config", codexDir = out + "/isolated/codex-home"
        let server = StrimServeProcess(bin: executable, model: opts.model, head: opts.head, port: opts.port,
                                       tokenFile: opts.tokenFile, logPath: out + "/server.log")
        do {
            let session = try SoakSession(opts: opts, out: out, server: server,
                                       verify: SoakVerify.Env(home: NSHomeDirectory(), goBin: go)) { token in
                CLIClientLauncher(port: opts.port, modelId: opts.modelId, claudeBin: opts.claudeBin,
                                  codexBin: opts.codexBin, claudeConfigDir: claudeDir, codexHome: codexDir,
                                  token: token)
            }
            return session.execute()
        } catch {
            return fail("error: \(error)")
        }
    }

    /// True when something already accepts connections on 127.0.0.1:port.
    static func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    static func readObject(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func readRows(_ path: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
}
