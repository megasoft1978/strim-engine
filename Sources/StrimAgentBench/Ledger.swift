import Foundation

public enum JSONL {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// Append-only JSONL ledger. One line per run; reading skips malformed lines (a crash may leave a torn tail).
public struct Ledger: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func append(_ row: LedgerRow) throws {
        var data = try JSONL.encoder().encode(row)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd: Int32
        do { fd = try openSafe(url.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600) }
        catch { throw LedgerError.io("\(error)") }
        defer { close(fd) }
        // Repair a torn tail so the new row starts on its own line.
        if lseek(fd, 0, SEEK_END) > 0 {
            var last: UInt8 = 0
            let rfd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if rfd >= 0 {
                let size = lseek(rfd, -1, SEEK_END)
                if size >= 0, readByte(rfd, &last), last != 0x0A { data.insert(0x0A, at: 0) }
                close(rfd)
            }
        }
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard n == data.count else { throw LedgerError.io("short write to \(url.path)") }
        fsync(fd)
    }

    public func read() -> [LedgerRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONL.decoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(LedgerRow.self, from: Data($0.utf8)) }
    }

    /// Runs that count as done on resume (infra failures are rerun).
    public func doneKeys() -> Set<RunKey> {
        Set(read().filter { !$0.infraError }.map(\.key))
    }
}

func readByte(_ fd: Int32, _ b: inout UInt8) -> Bool { read(fd, &b, 1) == 1 }

public enum LedgerError: Error, CustomStringConvertible {
    case io(String)
    public var description: String { if case .io(let s) = self { return s }; return "" }
}

/// Side file for run-level events (budget stops). Not part of the report.
public struct EventLog: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func record(_ event: String, _ fields: [String: String] = [:]) {
        var obj = fields
        obj["event"] = event
        obj["ts"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let fd = try? openSafe(url.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600) else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
    }
}
