import Foundation
import StrimSite

/// `strim site build|check|refresh-soak|list-figures` entry point (replaced the retired Python script).
/// args is the full argv (args[1] == "site"). Flags match the Python script: --check, --list-figures, --refresh-soak.
enum SiteCommand {
    static let usage = """
    usage: strim site <build|check|refresh-soak|list-figures> [--check] [--list-figures] [--refresh-soak] [--root DIR]
      build           render site/index.html and README.md from site/data/results.json, then run the checks
      check           checks only, nothing is written (same as build --check)
      refresh-soak    fill the soak.* figures from the latest complete 30-minute soak run, then build
      list-figures    print every figure id, value, unit and source
      --root DIR      repository root (default: nearest parent of the cwd that has site/data/results.json)
    """

    static func run(_ args: [String]) async throws -> Int32 {
        var opts = SiteOptions()
        var rootArg: String?
        var sub: String?
        var i = 2
        while i < args.count {
            let a = args[i]
            switch a {
            case "--check": opts.check = true
            case "--list-figures": opts.listFigures = true
            case "--refresh-soak": opts.refreshSoak = true
            case "--root":
                i += 1
                guard i < args.count else { FileHandle.standardError.write(Data("--root needs a directory\n".utf8)); return 2 }
                rootArg = args[i]
            case "-h", "--help": print(usage); return 0
            default:
                if sub == nil, !a.hasPrefix("-") { sub = a } else {
                    FileHandle.standardError.write(Data("unknown argument \(a)\n\(usage)\n".utf8)); return 2
                }
            }
            i += 1
        }
        switch sub {
        case nil, "build": break
        case "check": opts.check = true
        case "refresh-soak": opts.refreshSoak = true
        case "list-figures": opts.listFigures = true
        default:
            FileHandle.standardError.write(Data("unknown subcommand \(sub!)\n\(usage)\n".utf8)); return 2
        }
        guard let root = rootArg ?? findRoot() else {
            FileHandle.standardError.write(Data("error: cannot find a repo root with site/data/results.json (use --root)\n".utf8)); return 2
        }
        do {
            let res = try SiteBuilder(root: (root as NSString).standardizingPath).run(opts)
            return res.exitCode
        } catch let e as SiteError {
            FileHandle.standardError.write(Data((e.message + "\n").utf8))
            return 1
        }
    }

    static func findRoot() -> String? {
        var dir = FileManager.default.currentDirectoryPath
        while true {
            if FileManager.default.fileExists(atPath: dir + "/site/data/results.json") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }
}
