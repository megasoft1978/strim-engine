import Foundation

public struct InstallCopy {
    public var path: String
    public var version: String?
    public init(path: String, version: String?) { self.path = path; self.version = version }
}
public struct InstallProcess {
    public var path: String
    public var version: String?
    public var pid: Int32
    public init(path: String, version: String?, pid: Int32) { self.path = path; self.version = version; self.pid = pid }
}
public protocol InstallProbe {
    var copies: [InstallCopy] { get }
    var processes: [InstallProcess] { get }
    var caskInstalled: Bool? { get }
    var brewPrefix: String? { get }
    var serverVersion: String? { get }
}
public struct InstallFinding {
    public var message: String
    public var fix: String
}
/// Runs a tool with a hard time limit. stdout is drained while the child runs, so output larger than the
/// pipe buffer cannot block it. Returns nil only on launch failure or when the limit elapses (child terminated).
public enum InstallProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let reader = pipe.fileHandleForReading
        let collected = LockedData()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.set(reader.readDataToEndOfFile())
            drained.signal()
        }
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); return nil }
        guard drained.wait(timeout: .now() + max(0, end.timeIntervalSinceNow)) == .success else { return nil }
        return (process.terminationStatus, String(decoding: collected.value, as: UTF8.self))
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
public enum InstallCheck {
    public static func findings(probe: any InstallProbe, cliVersion: String) -> [InstallFinding] {
        var result: [InstallFinding] = []
        let copies = probe.copies.sorted { $0.path < $1.path }
        if copies.count > 1 {
            result.append(.init(message: "Multiple app copies (keep /Applications/Strim.app): " + copies.map { "\($0.path) (\($0.version ?? "unknown"))" }.joined(separator: ", "), fix: "open /Applications"))
        }
        for copy in copies where copy.version != nil && copy.version != cliVersion {
            result.append(.init(message: "App \(copy.path) version \(copy.version!) differs from CLI \(cliVersion)", fix: "brew install --cask strim-app"))
        }
        func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        for process in probe.processes where !inside(process.path, "/Applications/Strim.app") && !(probe.brewPrefix.map { inside(process.path, $0) } ?? false) {
            result.append(.init(message: "Running process \(process.path) (\(process.version ?? "unknown"), PID \(process.pid))", fix: "kill -TERM \(process.pid)"))
        }
        if !copies.isEmpty && probe.caskInstalled == false {
            result.append(.init(message: "Homebrew cask strim-app is not installed", fix: "brew install --cask strim-app"))
        }
        if let version = probe.serverVersion, version != cliVersion {
            result.append(.init(message: "Server version \(version) differs from CLI \(cliVersion)", fix: "brew upgrade --cask strim-app"))
        }
        return result
    }
}
