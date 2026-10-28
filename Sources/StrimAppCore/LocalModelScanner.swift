import Foundation
import StrimAPI

/// Fallback model discovery when the host has no `GET models`: directories with a `config.json` under
/// `~/.strim/models` and `~/models` (two levels deep).
public enum LocalModelScanner {
    public static func scan(roots: [String] = [NSHomeDirectory() + "/.strim/models", NSHomeDirectory() + "/models"]) -> [LocalModel] {
        let fm = FileManager.default
        var out: [LocalModel] = []
        var seen = Set<String>()
        func consider(_ path: String) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let real = url.path
            var isDir: ObjCBool = false
            guard !url.lastPathComponent.hasPrefix("."), !seen.contains(real),
                  fm.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: real + "/config.json") else { return }
            seen.insert(real)
            let files = (try? fm.contentsOfDirectory(atPath: real)) ?? []
            let bytes = files.filter { $0.hasSuffix(".safetensors") }.reduce(0.0) { acc, f in
                acc + Double(((try? fm.attributesOfItem(atPath: real + "/" + f)[.size]) as? NSNumber)?.int64Value ?? 0)
            }
            let name = url.lastPathComponent
            out.append(LocalModel(name: name, path: real, sizeGB: bytes > 0 ? bytes / 1_073_741_824 : nil,
                                  kind: name.lowercased().contains("mtp") ? "mtp" : "model"))
        }
        for root in roots {
            let kids = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for k in kids {
                let p = root + "/" + k
                consider(p)
                if !fm.fileExists(atPath: p + "/config.json") {
                    for g in ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted() { consider(p + "/" + g) }
                }
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
