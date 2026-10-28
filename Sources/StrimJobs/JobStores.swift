import Foundation

/// Returns true for ids this module generates (`j_` + 10 base32 chars); guards every path built from an id.
func isValidJobID(_ id: String) -> Bool {
    guard id.count == 12, id.hasPrefix("j_") else { return false }
    return id.dropFirst(2).allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
}

public actor InMemoryJobStore: JobStore {
    private var records: [JobID: JobRecord] = [:]
    private var eventLog: [JobID: [JobEvent]] = [:]
    public init() {}
    public func save(_ record: JobRecord) { records[record.id] = record }
    public func load(_ id: JobID) -> JobRecord? { records[id] }
    public func list() -> [JobRecord] { Array(records.values) }
    public func remove(_ id: JobID) { records[id] = nil; eventLog[id] = nil }
    public func appendEvent(_ id: JobID, _ event: JobEvent) { eventLog[id, default: []].append(event) }
    public func events(_ id: JobID) -> [JobEvent] { eventLog[id] ?? [] }
}

/// `<root>/<id>/job.json` + `events.jsonl`; directories 0700, files 0600, `job.json` written atomically.
public struct FileJobStore: JobStore {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim/jobs")) {
        self.root = root
    }

    private func jobDir(_ id: JobID) throws -> URL {
        guard isValidJobID(id) else { throw CocoaError(.fileReadInvalidFileName) }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    public func save(_ record: JobRecord) async throws {
        let dir = try jobDir(record.id)
        try ensureDir(root)
        try ensureDir(dir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(record)
        let tmp = dir.appendingPathComponent(".job.json.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, dir.appendingPathComponent("job.json").path) != 0 {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func load(_ id: JobID) async throws -> JobRecord? {
        let url = try jobDir(id).appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(JobRecord.self, from: data)
    }

    public func list() async throws -> [JobRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var out: [JobRecord] = []
        for n in names where isValidJobID(n) {
            if let r = try? await load(n) { out.append(r) }
        }
        return out
    }

    public func remove(_ id: JobID) async throws {
        let dir = try jobDir(id)
        // Only the files this store creates; a stray directory is left alone.
        for f in ["job.json", "events.jsonl"] { unlink(dir.appendingPathComponent(f).path) }
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in rest where f.hasPrefix(".job.json.") { unlink(dir.appendingPathComponent(f).path) }
        }
        rmdir(dir.path)
    }

    public func appendEvent(_ id: JobID, _ event: JobEvent) async throws {
        let dir = try jobDir(id)
        try ensureDir(root)
        try ensureDir(dir)
        var line = try JSONEncoder().encode(event)
        line.append(0x0A)
        let fd = open(dir.appendingPathComponent("events.jsonl").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let ok = line.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    public func events(_ id: JobID) async throws -> [JobEvent] {
        let url = try jobDir(id).appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(JobEvent.self, from: Data($0.utf8)) }
    }
}
