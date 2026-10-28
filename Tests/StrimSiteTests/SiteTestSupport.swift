import Foundation
@testable import StrimSite

/// Repo root (the directory holding Package.swift), found from this file's path.
let repoRoot: String = {
    if let e = ProcessInfo.processInfo.environment["STRIM_REPO_ROOT"], !e.isEmpty { return e }
    var dir = (#filePath as NSString).deletingLastPathComponent
    while dir != "/" {
        if FileManager.default.fileExists(atPath: dir + "/Package.swift") { return dir }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return FileManager.default.currentDirectoryPath
}()

func readString(_ path: String) -> String { String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) }

/// A throw-away tree that mirrors the repo through symlinks, except for the `replacing` paths which hold new contents.
/// Directories on the way to a replaced file are real; every sibling is a symlink to the original.
final class OverlayRoot {
    let path: String
    init(replacing: [String: String]) throws {
        let fm = FileManager.default
        path = NSTemporaryDirectory() + "strim-site-overlay-" + UUID().uuidString
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        try OverlayRoot.populate(src: repoRoot, dst: path, rel: "", replacing: replacing)
        SafeIO.registerTestRoot(path)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    private static func populate(src: String, dst: String, rel: String, replacing: [String: String]) throws {
        let fm = FileManager.default
        let prefix = rel.isEmpty ? "" : rel + "/"
        let deeper = replacing.keys.filter { $0.hasPrefix(prefix) }
        for name in try fm.contentsOfDirectory(atPath: src) {
            if rel.isEmpty, name == ".build" || name == ".git" || name == ".venv-sprint" || name == "models" || name == "wheelhouse" { continue }
            let r = prefix + name
            let s = src + "/" + name, d = dst + "/" + name
            if let content = replacing[r] {
                try Data(content.utf8).write(to: URL(fileURLWithPath: d))
            } else if deeper.contains(where: { $0.hasPrefix(r + "/") }) {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                try populate(src: s, dst: d, rel: r, replacing: replacing)
            } else {
                try fm.createSymbolicLink(atPath: d, withDestinationPath: s)
            }
        }
        // replaced files that do not exist in the source tree yet (creating their directories)
        for (k, v) in replacing where k.hasPrefix(prefix) {
            let d = dst + "/" + k.dropFirst(prefix.count)
            if !fm.fileExists(atPath: d) {
                try fm.createDirectory(atPath: (d as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(v.utf8).write(to: URL(fileURLWithPath: d))
            }
        }
    }
}
