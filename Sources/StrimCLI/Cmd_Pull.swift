import Foundation
import StrimPull

// strim pull [--tier 4bit|6bit|8bit|oq4e] [--dir ~/.strim/models] [--revision-lock] [--verify] [--list]
//
// Downloads the text model and its MTP head at the revisions pinned in StrimPull/ManifestData.swift, resumable
// and sha256-verified. HF_TOKEN (if set) is sent as a bearer token and never printed. Progress goes to stderr.

private func pullErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private func printPullList() {
    print("strim pull tiers (default 4bit). Revisions are pinned commits; files are sha256-verified.")
    for t in PullManifest.tiers {
        print("")
        print("\(t.name)  \(t.memoryNote)")
        for r in PullManifest.repos(for: t) {
            print("  \(r.name)  \(String(format: "%.2f", Double(r.totalBytes) / 1e9)) GB  \(r.repo) @ \(r.revision)")
        }
        let total = PullManifest.repos(for: t).reduce(Int64(0)) { $0 + $1.totalBytes }
        print("  download total \(String(format: "%.2f", Double(total) / 1e9)) GB (+5 GB free-disk headroom required)")
    }
}

func runPull(_ args: [String]) {
    var tierName = "4bit"
    var dir = "~/.strim/models"
    var lock = false, verify = false
    var only: String?
    var i = 2
    func fail(_ s: String) -> Never { pullErr(s); exit(2) }
    while i < args.count {
        let a = args[i]
        func value() -> String {
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") { return String(a[a.index(after: eq)...]) }
            i += 1
            guard i < args.count else { fail("missing value for \(a)") }
            return args[i]
        }
        switch a {
        case "--list": printPullList(); exit(0)
        case "--revision-lock": lock = true
        case "--verify": verify = true
        default:
            if a == "--only" || a.hasPrefix("--only=") { only = value() }
            else if a == "--tier" || a.hasPrefix("--tier=") { tierName = value() }
            else if a == "--dir" || a.hasPrefix("--dir=") { dir = value() }
            else { fail("unknown argument \(a)\nusage: strim pull [--tier 4bit|6bit|8bit|oq4e] [--dir DIR] [--revision-lock] [--verify] [--list]") }
        }
        i += 1
    }
    guard let tier = PullManifest.tier(tierName) else { fail("unknown tier \(tierName); see strim pull --list") }
    let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    var o = PullOptions(dir: root)
    o.verify = verify
    o.revisionLock = lock
    if let ep = ProcessInfo.processInfo.environment["HF_ENDPOINT"], let u = URL(string: ep) { o.endpoint = u }
    if let t = ProcessInfo.processInfo.environment["HF_TOKEN"], !t.isEmpty { o.token = t }
    o.interactive = isatty(2) != 0
    o.log = { line in
        if isatty(2) != 0 { pullErr("\r\u{1b}[K" + line) } else { pullErr(line) }
    }
    o.status = { line in FileHandle.standardError.write(Data(("\r\u{1b}[K" + line).utf8)) }

    var selected = PullManifest.repos(for: tier)
    if let only { selected = selected.filter { $0.name == only }; if selected.isEmpty { fail("--only \(only) is not part of tier \(tier.name)") } }
    let opts = o
    let repos = selected
    pullErr("strim pull \(tier.name) -> \(root.path)")
    // Explicit handlers: a shell that started this job in the background may have set SIGINT to ignored. The .part.state
    // sidecar is written at most 1 s behind the transfer, so a rerun resumes from there.
    for (sig, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            if opts.interactive { FileHandle.standardError.write(Data("\r\u{1b}[K".utf8)) }
            pullErr("interrupted, progress saved; rerun strim pull to resume")
            exit(code)
        }
        src.resume()
        pullSignalSources.append(src)
    }
    exitAsync {
        do {
            let s = try await Puller(opts).pull(repos)
            if opts.interactive { FileHandle.standardError.write(Data("\r\u{1b}[K".utf8)) }
            let rate = s.seconds > 0 ? Double(s.downloadedBytes) / s.seconds / 1e6 : 0
            pullErr(String(format: "done: %d downloaded, %d already present, %@ in %.0fs (%.0f MB/s)",
                           s.downloadedFiles, s.skippedFiles, PullFormat.gb(s.downloadedBytes), s.seconds, rate))
            let m = root.appendingPathComponent(tier.model).path
            let h = root.appendingPathComponent(tier.head).path
            print("strim serve \(m) \(h) --port 8203")
            return 0
        } catch {
            if opts.interactive { FileHandle.standardError.write(Data("\r\u{1b}[K".utf8)) }
            pullErr("pull failed: \(error)")
            return 1
        }
    }
}

nonisolated(unsafe) private var pullSignalSources: [DispatchSourceSignal] = []
