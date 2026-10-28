import Foundation

/// One file of a pinned Hugging Face repo. LFS files carry `sha256` (the lfs.oid of the tree API);
/// every other file carries the git blob sha1 (`gitSha1`, the tree API `oid`) and its exact size.
public struct PullFile: Sendable, Equatable, Codable {
    public let path: String
    public let size: Int64
    public let sha256: String?
    public let gitSha1: String?
    public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256; self.gitSha1 = nil }
    public init(path: String, size: Int64, gitSha1: String) { self.path = path; self.size = size; self.sha256 = nil; self.gitSha1 = gitSha1 }
}

/// A repo pinned to one commit. `name` is the directory name under the models dir (and the model id the API reports).
public struct PullRepo: Sendable, Equatable {
    public let name: String
    public let repo: String
    public let revision: String
    public let files: [PullFile]
    public init(name: String, repo: String, revision: String, files: [PullFile]) {
        self.name = name; self.repo = repo; self.revision = revision; self.files = files
    }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `<endpoint>/<repo>/resolve/<pinned revision>/<path>`; never `main`.
    public func url(for file: PullFile, endpoint: URL) -> URL {
        var u = endpoint
        let parts: [String] = repo.split(separator: "/").map(String.init) + ["resolve", revision] + file.path.split(separator: "/").map(String.init)
        for part in parts { u.appendPathComponent(part) }
        return u
    }
}

public struct PullTier: Sendable, Equatable {
    public let name: String
    /// Names of PullRepo entries.
    public let model: String
    public let head: String
    public let memoryNote: String
}

public enum PullManifest {
    public static let defaultEndpoint = URL(string: "https://huggingface.co")!

    public static let tiers: [PullTier] = [
        PullTier(name: "4bit", model: "qwen38-4bit", head: "qwen38-mtp-4bit",
                 memoryNote: "measured peak ~31 GB on a 64 GB M5 Max; the only tier with a measured peak"),
        PullTier(name: "6bit", model: "qwen38-6bit", head: "qwen38-mtp-4bit",
                 memoryNote: "peak not measured; weights alone are larger than 4-bit"),
        PullTier(name: "8bit", model: "qwen38-8bit", head: "qwen38-mtp-8bit",
                 memoryNote: "peak not measured; weights alone are larger than 4-bit"),
        PullTier(name: "oq4e", model: "qwen38-oq4e-mtp", head: "qwen38-oq4e-mtp",
                 memoryNote: "peak not measured; mixed 4/5-bit with its own MTP head, experimental"),
    ]

    public static func repo(named name: String) -> PullRepo? { repos.first { $0.name == name } }
    public static func tier(_ name: String) -> PullTier? { tiers.first { $0.name == name } }

    /// The repos a tier needs, text model first, head second (deduplicated when the head is inside the model repo).
    public static func repos(for tier: PullTier) -> [PullRepo] {
        var out: [PullRepo] = []
        for n in [tier.model, tier.head] where !out.contains(where: { $0.name == n }) {
            if let r = repo(named: n) { out.append(r) }
        }
        return out
    }
}
