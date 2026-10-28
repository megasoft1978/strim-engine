import Foundation

/// Benchmark arms. H: harness alone (local model, via the MCP over HTTP). C: Claude Code driving the local
/// model through strim serve's Anthropic endpoint. P: real Claude Code alone (paid). M: real Claude Code with
/// the strim MCP and the delegation guidance (paid).
public enum Arm: String, CaseIterable, Codable, Sendable {
    case P, M, H, C
    public var isPaid: Bool { self == .P || self == .M }
    public var usesLocalModel: Bool { self != .P }
    public static func parseList(_ s: String) -> [Arm]? {
        var out: [Arm] = []
        for part in s.split(separator: ",") {
            guard let a = Arm(rawValue: part.trimmingCharacters(in: .whitespaces).uppercased()) else { return nil }
            if !out.contains(a) { out.append(a) }
        }
        return out.isEmpty ? nil : out
    }
}

/// Oracle for answer-style tasks. `all_of`/`any_of`/`none_of` are regexes (grep -E style).
public struct ExpectedAnswer: Codable, Sendable, Equatable {
    public var allOf: [String] = []
    public var anyOf: [String] = []
    public var noneOf: [String] = []
    public var isEmpty: Bool { allOf.isEmpty && anyOf.isEmpty && noneOf.isEmpty }
    public init(allOf: [String] = [], anyOf: [String] = [], noneOf: [String] = []) {
        self.allOf = allOf; self.anyOf = anyOf; self.noneOf = noneOf
    }
    enum CodingKeys: String, CodingKey { case allOf = "all_of", anyOf = "any_of", noneOf = "none_of" }
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let s = try? single.decode(String.self) { allOf = [NSRegularExpression.escapedPattern(for: s)]; return }
            if let a = try? single.decode([String].self) { allOf = a.map { NSRegularExpression.escapedPattern(for: $0) }; return }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allOf = try c.decodeIfPresent([String].self, forKey: .allOf) ?? []
        anyOf = try c.decodeIfPresent([String].self, forKey: .anyOf) ?? []
        noneOf = try c.decodeIfPresent([String].self, forKey: .noneOf) ?? []
    }
}

public struct TaskSpec: Codable, Sendable, Equatable {
    public var id: String
    public var taskClass: String
    public var repo: String?
    public var baseCommit: String?
    public var prompt: String
    public var verifyCmd: String?
    public var testPaths: [String]
    public var testSha256: [String: String]
    public var expectedAnswer: ExpectedAnswer?
    public var estSoloTurns: Int?
    public var noEdit: Bool
    public var answerEnv: String
    public var snapshot: String?
    public var treeSha256: String?
    public var knownAnswer: String?
    public var wrongAnswer: String?

    enum CodingKeys: String, CodingKey {
        case id, repo, prompt, snapshot
        case taskClass = "class", baseCommit = "base_commit", verifyCmd = "verify_cmd", testPaths = "test_paths"
        case testSha256 = "test_sha256", expectedAnswer = "expected_answer", estSoloTurns = "est_solo_turns"
        case noEdit = "no_edit", answerEnv = "answer_env", treeSha256 = "tree_sha256", knownAnswer = "known_answer", wrongAnswer = "wrong_answer"
    }

    public init(id: String, taskClass: String, prompt: String, verifyCmd: String? = nil, testPaths: [String] = [],
                expectedAnswer: ExpectedAnswer? = nil, noEdit: Bool = false) {
        self.id = id; self.taskClass = taskClass; self.prompt = prompt; self.verifyCmd = verifyCmd
        self.testPaths = testPaths; self.expectedAnswer = expectedAnswer; self.noEdit = noEdit
        self.testSha256 = [:]; self.answerEnv = "ANSWER_FILE"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskClass = try c.decode(String.self, forKey: .taskClass)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        baseCommit = try c.decodeIfPresent(String.self, forKey: .baseCommit)
        prompt = try c.decode(String.self, forKey: .prompt)
        verifyCmd = try c.decodeIfPresent(String.self, forKey: .verifyCmd)
        testPaths = try c.decodeIfPresent([String].self, forKey: .testPaths) ?? []
        testSha256 = try c.decodeIfPresent([String: String].self, forKey: .testSha256) ?? [:]
        expectedAnswer = try? c.decodeIfPresent(ExpectedAnswer.self, forKey: .expectedAnswer)
        estSoloTurns = try c.decodeIfPresent(Int.self, forKey: .estSoloTurns)
        noEdit = try c.decodeIfPresent(Bool.self, forKey: .noEdit) ?? false
        answerEnv = try c.decodeIfPresent(String.self, forKey: .answerEnv) ?? "ANSWER_FILE"
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
        treeSha256 = try c.decodeIfPresent(String.self, forKey: .treeSha256)
        knownAnswer = try c.decodeIfPresent(String.self, forKey: .knownAnswer)
        wrongAnswer = try c.decodeIfPresent(String.self, forKey: .wrongAnswer)
    }

    /// Answer-style task: the final message is checked, not the tree.
    public var isAnswerTask: Bool { expectedAnswer?.isEmpty == false || noEdit || taskClass.lowercased().contains("qa") }
}

/// A task plus where it lives on disk.
public struct LoadedTask: Sendable {
    public var spec: TaskSpec
    public var dir: URL
    public var language: String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("task.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["language"] as? String
    }
    public var id: String { spec.id }
    /// Snapshot of the base tree: a tarball (`snapshot` field, else snapshot/base.tar.gz) or a directory (snapshot/, base/).
    public func solutionPatch() -> URL? {
        let u = dir.appendingPathComponent("solution.patch")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public func snapshotSource() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let s = spec.snapshot { candidates.append(s) }
        candidates += ["snapshot.tar.gz", "base.tar.gz", "snapshot.tgz", "snapshot", "base"]
        for c in candidates {
            let u = dir.appendingPathComponent(c)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

/// One JSONL line per (task, arm, rep) run. Encoded with snake_case keys, sorted.
public struct LedgerRow: Codable, Sendable, Equatable {
    public var taskId: String
    public var taskClass: String
    public var arm: Arm
    public var rep: Int
    public var success: Bool
    public var testsTampered: Bool = false
    public var verifyNote: String = ""
    // Parent (paid Claude) usage: nil for arms with no parent.
    public var parentInUncached: Int?
    public var parentCacheCreate: Int?
    public var parentCacheRead: Int?
    public var parentOut: Int?
    public var parentTotal: Int?
    public var parentCostUsd: Double?
    // Local model usage (H, C, and the delegated part of M).
    public var localPromptTokens: Int?
    public var localCachedTokens: Int?
    public var localCompletionTokens: Int?
    public var localTurns: Int?
    public var turns: Int?
    public var delegations: Int = 0
    public var polls: Int = 0
    /// Delegations the host refused for a cwd/path/root reason: infrastructure, not a delegation outcome (not in `delegations`).
    public var pathRefusals: Int?
    public var patchApplied: Bool?
    public var wallS: Double = 0
    public var claimedDone: Bool = false
    /// Claimed done but the independent verify failed.
    public var falseDone: Bool = false
    /// The parent redid the work after a failed delegation.
    public var redo: Bool = false
    public var timedOut: Bool = false
    /// Arm H: the harness's own verdict (verified|failed|unverified|verified_modified_tests|declined|none), the exit code of
    /// its verify command, and the job status (done|failed|limit|declined|cancelled|timeout). Additive: old rows decode with nil.
    public var harnessVerifyStatus: String?
    public var harnessVerifyExit: Int?
    public var harnessStatus: String?
    public var error: String?
    /// Infrastructure failure (server down, binary missing): the row is rerun on resume.
    public var infraError: Bool = false
    public var dryRun: Bool = false
    public var ts: String = ""

    public init(taskId: String, taskClass: String, arm: Arm, rep: Int, success: Bool) {
        self.taskId = taskId; self.taskClass = taskClass; self.arm = arm; self.rep = rep; self.success = success
    }

    public var key: RunKey { RunKey(taskId: taskId, arm: arm, rep: rep) }
}

public struct RunKey: Hashable, Sendable {
    public var taskId: String
    public var arm: Arm
    public var rep: Int
    public init(taskId: String, arm: Arm, rep: Int) { self.taskId = taskId; self.arm = arm; self.rep = rep }
}

/// What an arm executor reports back; the runner adds the independent verification.
public struct ArmOutcome: Sendable {
    public var parentInUncached: Int?
    public var parentCacheCreate: Int?
    public var parentCacheRead: Int?
    public var parentOut: Int?
    public var parentCostUsd: Double?
    public var localPromptTokens: Int?
    public var localCachedTokens: Int?
    public var localCompletionTokens: Int?
    public var localTurns: Int?
    public var turns: Int?
    public var delegations = 0
    public var polls = 0
    public var pathRefusals = 0
    public var patchApplied: Bool?
    public var claimedDone = false
    public var redo = false
    public var timedOut = false
    public var harnessVerifyStatus: String?
    public var harnessVerifyExit: Int?
    public var harnessStatus: String?
    public var error: String?
    public var infraError = false
    /// Final answer text for answer-style tasks.
    public var answer: String?
    public init() {}
}
