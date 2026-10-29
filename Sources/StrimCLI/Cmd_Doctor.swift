import Foundation
import StrimAPI
import StrimCore
import StrimPull

// strim --version | version: one line, static, never touches MLX/Metal.
// strim doctor [--dir ~/.strim/models]: version, runtime config, the GPU smoke test (device + tiny matmul) and the model dir status.

func runVersion(_ args: [String]) {
    print("strim \(StrimVersion.current)")
}

/// Runtime config, printed once by `strim doctor` (not by `--version`).
private func printRuntimeConfig() {
    let cfg = RuntimeConfig.measuredSpeed
    print("model:   \(cfg.model.repo)")
    print("quant:   \(cfg.quant.rawValue)-bit")
    print("context: \(cfg.contextTokens) tokens")
    print("prefill: \(cfg.prefillStep) tokens/step")
    print("mtp:     depth \(cfg.mtpDepth)")
    print("wired:   \(cfg.wiredLimitGB) GB")
}

func runDoctor(_ args: [String]) {
    var dir = "~/.strim/models"
    var strict = false
    var port: UInt16 = 8203
    var i = 2
    while i < args.count {
        if args[i] == "--dir", i + 1 < args.count { dir = args[i + 1]; i += 1 }
        else if args[i].hasPrefix("--dir=") { dir = String(args[i].dropFirst("--dir=".count)) }
        else if args[i] == "--strict" { strict = true }
        else if args[i] == "--port", i + 1 < args.count, let value = UInt16(args[i + 1]), value > 0 { port = value; i += 1 }
        else if args[i].hasPrefix("--port="), let value = UInt16(args[i].dropFirst("--port=".count)), value > 0 { port = value }
        else { FileHandle.standardError.write(Data("usage: strim doctor [--dir DIR=~/.strim/models] [--port N=8203] [--strict]\n".utf8)); exit(2) }
        i += 1
    }
    let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    runVersion(args)
    printRuntimeConfig()
    print("device:  \(Compute.deviceName)")
    let mm = Compute.matMulSmoke()
    let ok = mm.values == [10, 13, 28, 40]
    print("matmul:  \(mm.shape) -> \(mm.values) \(ok ? "ok" : "UNEXPECTED")")
    print("models:  \(root.path)")
    let fm = FileManager.default
    var anyMissing = false
    for t in PullManifest.tiers {
        let names = PullManifest.repos(for: t)
        let state = names.map { r -> String in
            let d = root.appendingPathComponent(r.name)
            let missing = r.files.filter { f in
                let sz = (try? fm.attributesOfItem(atPath: d.appendingPathComponent(f.path).path)[.size] as? NSNumber)?.int64Value
                return sz != f.size
            }
            return missing.isEmpty ? "\(r.name) ok" : (missing.count == r.files.count ? "\(r.name) absent" : "\(r.name) incomplete (\(missing.count) files)")
        }
        if t.name == "4bit", state.contains(where: { !$0.hasSuffix(" ok") }) { anyMissing = true }
        print("  \(t.name): " + state.joined(separator: ", "))
    }
    if anyMissing { print("missing the default 4bit model: run `strim pull`") }
    let findings = InstallCheck.findings(probe: SystemInstallProbe(port: port), cliVersion: StrimVersion.current)
    print("install:")
    if findings.isEmpty { print("  no install issues detected") }
    for finding in findings { print("  \(finding.message) — fix: `\(finding.fix)`") }
    exit(ok && (!strict || findings.isEmpty) ? 0 : 1)
}
