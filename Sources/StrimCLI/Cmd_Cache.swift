import Foundation
import StrimCore

// strim cache clear [--dir DIR]   delete all disk prefix-cache files (every model fingerprint)
// strim cache stats [--dir DIR]   file count and size
// DIR defaults to $STRIM_PREFIX_DISK_DIR or ~/.strim/cache. Only *.spd / *.tmp files inside the fingerprint
// subdirectories are removed; nothing else under DIR is touched. See docs/CONTROL-API.md (disk prefix cache).

func runCache(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    var dir = ProcessInfo.processInfo.environment["STRIM_PREFIX_DISK_DIR"].map { ($0 as NSString).expandingTildeInPath } ?? PrefixDisk.defaultRoot
    var cmd: String?
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--dir" { i += 1; guard i < args.count else { fail("missing value for --dir") }; dir = (args[i] as NSString).expandingTildeInPath }
        else if a.hasPrefix("--dir=") { dir = (String(a.dropFirst(6)) as NSString).expandingTildeInPath }
        else if a.hasPrefix("--") { fail("unknown option \(a)") }
        else if cmd == nil { cmd = a }
        else { fail("unexpected argument \(a)") }
        i += 1
    }
    switch cmd {
    case "clear":
        let r = PrefixDisk.clearAll(root: dir)
        print("cleared \(r.files) files, \(String(format: "%.2f", Double(r.bytes) / 1e9)) GB from \(dir)")
    case "stats":
        let u = PrefixDisk.usage(root: dir)
        print("\(u.files) files, \(String(format: "%.2f", Double(u.bytes) / 1e9)) GB in \(dir)")
    default:
        fail("usage: strim cache clear|stats [--dir DIR]")
    }
}
