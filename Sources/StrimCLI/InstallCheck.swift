import Darwin
import Foundation
import StrimAPI

/// Best-effort local probes. A shared deadline keeps doctor responsive even when tools hang.
struct SystemInstallProbe: InstallProbe {
    let copies: [InstallCopy]
    let processes: [InstallProcess]
    let caskInstalled: Bool?
    let brewPrefix: String?
    let serverVersion: String?

    init(port: UInt16) {
        let deadline = Date().addingTimeInterval(1.5)
        func run(_ executable: String, _ args: [String], limit: TimeInterval) -> (status: Int32, output: String)? {
            let remaining = min(limit, deadline.timeIntervalSinceNow)
            guard remaining > 0, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
            return InstallProcessRunner.run(executable, args, timeout: remaining)
        }
        func version(_ path: String) -> String? {
            Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
        let fm = FileManager.default
        var paths = ["/Applications/Strim.app", NSHomeDirectory() + "/Applications/Strim.app"]
        if let result = run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'dev.strim.Strim'"], limit: 0.4), result.0 == 0 {
            paths += result.1.components(separatedBy: .newlines).filter { $0.hasSuffix("/Strim.app") }
        }
        paths = Array(Set(paths.filter { fm.fileExists(atPath: $0) })).sorted()
        copies = paths.map { InstallCopy(path: $0, version: version($0)) }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fm.isExecutableFile(atPath: $0) }
        brewPrefix = brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        if let brew, let result = run(brew, ["list", "--cask", "strim-app"], limit: 0.45) {
            caskInstalled = result.0 == 0
        } else { caskInstalled = nil }
        var found: [InstallProcess] = []
        if let ps = run("/bin/ps", ["-axo", "pid=,command="], limit: 0.3), ps.0 == 0 {
            for line in ps.1.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard parts.count == 2, let pid = Int32(parts[0]), pid != getpid() else { continue }
                let command = String(parts[1])
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
                let path = String(cString: buffer)
                let appRange = path.range(of: ".app/Contents/MacOS/")
                let isApp = appRange != nil && ["Strim", "StrimApp"].contains((path as NSString).lastPathComponent)
                let isServer = (path as NSString).lastPathComponent == "strim" && command.range(of: #"(^|\s)serve(\s|$)"#, options: .regularExpression) != nil
                guard isApp || isServer else { continue }
                let appPath = appRange.map { String(path[..<$0.lowerBound]) + ".app" }
                found.append(.init(path: path, version: appPath.flatMap(version), pid: pid))
            }
        }
        processes = found
        var detectedVersion: String?
        for endpoint in ["/health", "/v1/strim/status"] {
            guard let response = run("/usr/bin/curl", ["--silent", "--max-time", "0.25", "--noproxy", "*", "http://127.0.0.1:\(port)\(endpoint)"], limit: 0.3), response.0 == 0,
                  let data = response.1.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let value = json["version"] as? String, !value.isEmpty else { continue }
            detectedVersion = value
            break
        }
        serverVersion = detectedVersion
    }
}
