import Foundation
import Darwin
import StrimHarness

/// Best-effort cleanup after a host died without cleanup: kills marked same-user job processes owned by
/// this host's state directory. Legacy unowned markers are swept only by the default host.
/// Call only while holding the host lock, when no job of this host is live.
public enum OrphanSweep {
    /// Returns the number of processes killed.
    @discardableResult
    public static func killMarkedProcesses(marker: String = "STRIM_JOB=", hostID: String = HostIdentity.id(for: HostIdentity.defaultRoot), includeLegacy: Bool = true) -> Int {
        let uid = getuid(), me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return 0 }
        var killed = 0
        let allowLegacy = includeLegacy && hostID == HostIdentity.id(for: HostIdentity.defaultRoot)
        for pid in pids.prefix(Int(got)) where pid > 1 && pid != me {
            var info = proc_bsdinfo()
            let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard n == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == uid else { continue }
            let env = environment(of: pid)
            guard env.contains(where: { $0.hasPrefix(marker) }) else { continue }
            let owners = env.filter { $0.hasPrefix("STRIM_HOST=") }
            guard owners == ["STRIM_HOST=" + hostID] || (owners.isEmpty && allowLegacy) else { continue }
            if kill(pid, SIGKILL) == 0 { killed += 1 }
        }
        if killed > 0 { FileHandle.standardError.write(Data("strim: killed \(killed) orphaned job process(es)\n".utf8)) }
        return killed
    }

    /// Environment strings of `pid` via KERN_PROCARGS2 (empty when unreadable).
    static func environment(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 8 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        // skip exec path, then padding NULs
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var seen: Int32 = 0
        while seen < argc, i < size {   // skip argv
            while i < size, buf[i] != 0 { i += 1 }
            i += 1; seen += 1
        }
        var env: [String] = []
        while i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            if j == i { break }
            env.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return env
    }
}
