import Foundation
import StrimHarness

public struct Provenance: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var parent: String?
    public var source: String
    public var coordinate: String?
    public var round: Int?
    public var valGainPP: Double?
    public var ledger: String?
    public var seed: UInt64?
    public var dryRun: Bool
    public var createdAt: String
    public init(fingerprint: String, parent: String? = nil, source: String = "strim evolve v0", coordinate: String? = nil,
                round: Int? = nil, valGainPP: Double? = nil, ledger: String? = nil, seed: UInt64? = nil, dryRun: Bool = false,
                createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.fingerprint = fingerprint; self.parent = parent; self.source = source; self.coordinate = coordinate
        self.round = round; self.valGainPP = valGainPP; self.ledger = ledger; self.seed = seed; self.dryRun = dryRun
        self.createdAt = createdAt
    }
}

public enum PackStoreError: Error, CustomStringConvertible {
    case io(String), mismatch(String)
    public var description: String { switch self { case .io(let s), .mismatch(let s): return s } }
}

/// `~/.strim/packs/<fingerprint>/` (0700): system.md, tool_guidance.md, guardrails.md, memory.md, knobs.json,
/// candidate.json, provenance.jsonl. `ACTIVE` names the adopted fingerprint. Writes only inside `root`.
public struct PackStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var defaultRoot: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".strim/packs") }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Writes the pack files of `candidate` into `dir` (created 0700). Used for the store and for the live dir.
    @discardableResult
    public static func materialize(_ c: PackCandidate, into dir: URL, fingerprint: String? = nil) throws -> String {
        let fp = fingerprint ?? PackLibrary.fingerprint(c)
        let rendered = PackLibrary.render(c)
        try ensureDir(dir)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let files: [(String, Data)] = [
            ("system.md", Data(rendered.system.utf8)), ("tool_guidance.md", Data(rendered.toolGuidance.utf8)),
            ("guardrails.md", Data(rendered.guardrails.utf8)), ("memory.md", Data(rendered.memory.utf8)),
            ("knobs.json", try enc.encode(rendered.knobs)), ("candidate.json", try enc.encode(c)),
            ("FINGERPRINT", Data(fp.utf8)),
            // Harness check (PackLoader.load): must equal HarnessPack.fingerprint of the files it reads.
            (PackLoader.packHashFile, Data(rendered.harnessPack.fingerprint.utf8)),
        ]
        let components: Set<String> = ["system.md", "tool_guidance.md", "guardrails.md", "memory.md"]
        for (n, d) in files {
            let url = dir.appendingPathComponent(n)
            // The harness reads an empty regular file as unreadable, but treats a missing component as empty (same hash).
            if components.contains(n), d.isEmpty { try? FileManager.default.removeItem(at: url); continue }
            try write(d, to: url)
        }
        return fp
    }

    @discardableResult
    public func save(_ c: PackCandidate, provenance: Provenance) throws -> URL {
        let fp = PackLibrary.fingerprint(c)
        guard provenance.fingerprint == fp else { throw PackStoreError.mismatch("provenance fingerprint \(provenance.fingerprint) != \(fp)") }
        try Self.ensureDir(root)
        let dir = root.appendingPathComponent(fp)
        try Self.materialize(c, into: dir, fingerprint: fp)
        let line = Canonical.json(provenance) + Data("\n".utf8)
        let log = dir.appendingPathComponent("provenance.jsonl")
        if let h = FileHandle(forWritingAtPath: log.path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try Self.write(line, to: log) }
        return dir
    }

    /// Loads and re-derives the fingerprint; throws when files were edited or the candidate has foreign fields.
    public func load(_ fp: String) throws -> PackCandidate {
        let dir = root.appendingPathComponent(fp)
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("candidate.json")) else { throw PackStoreError.io("no pack \(fp) in \(root.path)") }
        let c = try JSONDecoder().decode(PackCandidate.self, from: d)
        let now = PackLibrary.fingerprint(c)
        guard now == fp else { throw PackStoreError.mismatch("pack \(fp) re-derives to \(now): files or variant texts changed") }
        return c
    }

    public func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 16 && $0.allSatisfy(\.isHexDigit) }.sorted()
    }

    public func setActive(_ fp: String) throws {
        _ = try load(fp)
        try Self.write(Data(fp.utf8), to: root.appendingPathComponent("ACTIVE"))
    }

    public func active() -> String? {
        (try? String(contentsOf: root.appendingPathComponent("ACTIVE"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
