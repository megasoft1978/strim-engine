import Foundation
import StrimControl
import StrimEngine
import StrimJobs
import StrimAPI
import StrimAdmission
import StrimHost
import StrimServer

// strim serve <model> [mtpHead] [--port N=8203] [--token-file PATH] [--no-auth] [--model-dir DIR]...
//                              [--max-inflight N] [--max-background N] [--no-admission]
//                              [--prefix-disk] [--prefix-disk-dir DIR]
//
// Engine + OpenAI-compatible HTTP server in one process, bound to 127.0.0.1. A bearer token is required
// unless --no-auth is given; it lives in ~/.strim/token (0600) and only the path is printed.
// Priority admission (interactive before background) is on by default; see docs/ADMISSION.md.

func runServe(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    var positional: [String] = []
    var port: UInt16 = 8203
    var tokenPath = TokenStore.defaultPath
    var noAuth = false
    var modelDirs: [String] = []
    var admission = AdmissionOptions()
    var i = 2
    while i < args.count {
        let a = args[i]
        func value() -> String {
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") { return String(a[a.index(after: eq)...]) }
            i += 1
            guard i < args.count else { fail("missing value for \(a)") }
            return args[i]
        }
        if a == "--no-auth" { noAuth = true }
        else if a == "--prefix-disk" { setenv("STRIM_PREFIX_DISK", "1", 1) }
        else if a == "--prefix-disk-dir" || a.hasPrefix("--prefix-disk-dir=") {
            setenv("STRIM_PREFIX_DISK", "1", 1)
            setenv("STRIM_PREFIX_DISK_DIR", (value() as NSString).expandingTildeInPath, 1)
        }
        else if a == "--model-dir" || a.hasPrefix("--model-dir=") { modelDirs.append((value() as NSString).expandingTildeInPath) }
        else if a == "--port" || a.hasPrefix("--port=") {
            guard let p = UInt16(value()) else { fail("bad --port") }
            port = p
        } else if a == "--token-file" || a.hasPrefix("--token-file=") { tokenPath = value() }
        else if AdmissionOptions.owns(a) {
            do { try admission.parse(a, value: value) } catch { fail("\(error)") }
        }
        else if a.hasPrefix("--") { fail("unknown option \(a)") }
        else { positional.append(a) }
        i += 1
    }
    guard let model = positional.first, positional.count <= 2 else {
        fail("usage: strim serve <model> [mtpHead] [--port N=8203] [--token-file PATH] [--no-auth] [--model-dir DIR]... "
             + "[--max-inflight N] [--max-background N] [--no-admission] [--prefix-disk] [--prefix-disk-dir DIR]")
    }
    let head = positional.count > 1 ? positional[1] : nil

    var token: String?
    if !noAuth {
        do { token = try TokenStore.loadOrCreate(path: tokenPath) } catch { fail("token: \(error)") }
    }

    let controlTokenPath = ControlToken.path(besideAPITokenAt: tokenPath)
    let controlToken: String
    do { controlToken = try ControlToken.loadOrCreate(path: controlTokenPath) } catch { fail("control token: \(error)") }

    Task {
        do {
            let paths = HostPaths(tokenPath: tokenPath)
            let loadedConfig = try HostConfig.load(from: paths.config)
            let (hostConfig, rootsDefaulted) = loadedConfig.withProductionDefaults()
            if rootsDefaulted {
                // Once per start, only when the default applied (MCP is mounted at /mcp whenever serve runs). The home default is kept.
                FileHandle.standardError.write(Data("strim: MCP jobs are limited to \(NSHomeDirectory()) (mcp.allowedRoots not set; ~/.strim, ~/.aws, ~/.ssh stay refused).\n  To narrow: add {\"mcp\": {\"allowedRoots\": [\"/path/to/projects\"]}} to ~/.strim/config.json, then restart.\n".utf8))
            }
            // Lock before loading the model: a second host must fail fast, not after 27B weights are resident.
            let lock = try HostLock.acquire(at: paths.lock)
            let cfg = EngineConfig.fromEnvironment(modelDir: model, headDir: head)
            let t0 = Date()
            let engine = try await LocalEngineClient.start(cfg)
            let modelId = URL(fileURLWithPath: model).lastPathComponent
            // The slot owns the engine so the control API can unload/reload it; everything else talks to its proxy.
            let jobStore = FileJobStore(root: paths.jobs)
            let slot = EngineSlot(
                factory: { model, mtp, _ in try await LocalEngineClient.start(EngineConfig.fromEnvironment(modelDir: model, headDir: mtp)) },
                release: { e in await (e as? LocalEngineClient)?.shutdown() },
                busyProbe: { await StrimControlPlane.activeWork(in: jobStore) })
            await slot.adopt(engine, model: model, mtp: head)
            let maxSessions = Int(ProcessInfo.processInfo.environment["STRIM_MAX_SESSIONS"] ?? "") ?? 8
            // One gate shared by the HTTP layer and the job layer (StrimHost hands it to JobManager). The engine admits by
            // memory rather than a fixed sequence count, so the default slot count is the session pool size.
            let limits = admission.limits(defaultInflight: maxSessions)
            let gate = limits.map { PriorityGate(limits: $0) }
            let host = StrimHost(
                engine: slot.client,
                serverConfig: ServerConfig(modelId: modelId, defaults: SamplingDefaults.load(modelDir: model),
                                           maxSessions: maxSessions, bearerToken: token, admission: gate),
                hostConfig: hostConfig, paths: paths, lock: lock)
            var copts = StrimControlPlane.Options()
            // Models the control API may load: ~/models, next to the model/head this host started with, --model-dir.
            copts.modelRoots = [NSHomeDirectory() + "/models", (model as NSString).deletingLastPathComponent]
                + (head.map { [($0 as NSString).deletingLastPathComponent] } ?? []) + modelDirs
            StrimControlPlane(host: host, slot: slot, auth: ControlAuth(controlToken: controlToken, apiToken: token),
                              options: copts).register(on: host.server)
            let bound = try await host.start(port: port)
            print(String(format: "engine ready in %.1fs  model=%@  head=%@", Date().timeIntervalSince(t0), modelId, head ?? "none"))
            print("strim serve: http://127.0.0.1:\(bound)  (OpenAI-compatible: /v1/chat/completions /v1/models /health /metrics)")
            if noAuth { print("auth: DISABLED (--no-auth), loopback dev only") }
            else { print("auth: bearer token required; token file: \(tokenPath)") }
            print("control: http://127.0.0.1:\(bound)\(StrimRoutes.status)  (menu-bar app API; control token: \(controlTokenPath))")
            print("mcp: http://127.0.0.1:\(bound)/mcp  (register with: strim mcp-config --claude|--codex --port \(bound))")
            if let l = limits { print("admission: on  max_inflight=\(l.maxInflight)  max_background=\(l.maxBackground)") }
            else { print("admission: off (--no-admission)") }
            fflush(stdout)
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler {
                    Task {
                        await host.shutdown()
                        try? await slot.unload(force: true)
                        exit(0)
                    }
                }
                src.resume()
                signalSources.append(src)
            }
        } catch {
            fail("serve failed: \(error)")
        }
    }
    dispatchMain()
}

nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []
