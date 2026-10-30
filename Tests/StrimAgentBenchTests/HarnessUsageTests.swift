import Foundation
import Testing
@testable import StrimAgentBench

/// H-arm token accounting: a job that ended limit/failed/cancelled has no `usage:` line in its reply, so the usage
/// comes from the job's result.json (fixture job dir below mirrors the host's `writeResult` layout).
@Suite struct HarnessUsageTests {
    static func jobDir(_ root: URL, _ id: String, usage: [String: Any]?) {
        var result: [String: Any] = ["status": "limit", "summary": "wall-clock limit reached (900s)", "files_changed": [], "commands": []]
        if let usage { result["usage"] = usage }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let dir = root.appendingPathComponent(id)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! data.write(to: dir.appendingPathComponent("result.json"))
    }

    @Test func limitJobUsageComesFromResultJSON() {
        let jobs = tempDir("usage-limit")
        Self.jobDir(jobs, "j_lim1", usage: ["prompt_tokens": 4200, "cached_tokens": 900, "completion_tokens": 310,
                                            "turns": 7, "seconds": 812.5])
        let reply = HarnessReply.parse("strim job j_lim1: limit wall-clock limit reached (900s)")
        #expect(reply.promptTokens == nil)
        #expect(HarnessArm.resolvedUsage(reply, jobsDir: jobs, waitS: 0)
                == JobUsage(promptTokens: 4200, cachedTokens: 900, completionTokens: 310, turns: 7))
    }

    @Test func doneReplyUsageLineWinsOverDisk() {
        let jobs = tempDir("usage-done")
        Self.jobDir(jobs, "j_done1", usage: ["prompt_tokens": 1, "cached_tokens": 0, "completion_tokens": 1, "turns": 1])
        let reply = HarnessReply.parse("DONE strim job j_done1 verify=verified turn 3/40 5s\n"
                                       + "usage: 100 prompt (10 cached) + 20 completion tokens, 3 turns, 5s")
        #expect(HarnessArm.resolvedUsage(reply, jobsDir: jobs, waitS: 0)
                == JobUsage(promptTokens: 100, cachedTokens: 10, completionTokens: 20, turns: 3))
    }

    @Test func missingOrUsagelessResultIsNil() {
        let jobs = tempDir("usage-missing")
        Self.jobDir(jobs, "j_nousage", usage: nil)
        #expect(HarnessArm.jobUsage(jobId: "j_nousage", jobsDir: jobs, waitS: 0) == nil)
        #expect(HarnessArm.jobUsage(jobId: "j_absent", jobsDir: jobs, waitS: 0) == nil)
        let declined = HarnessReply.parse("strim job j_nousage: declined")
        #expect(HarnessArm.resolvedUsage(declined, jobsDir: jobs, waitS: 0) == nil)
    }

    @Test func pollsUntilResultJSONAppears() throws {
        let jobs = tempDir("usage-late")
        let writer = Thread {
            usleep(300_000)
            Self.jobDir(jobs, "j_late1", usage: ["prompt_tokens": 50, "cached_tokens": 0, "completion_tokens": 5, "turns": 1])
        }
        writer.start()
        let u = HarnessArm.jobUsage(jobId: "j_late1", jobsDir: jobs, waitS: 5)
        #expect(u == JobUsage(promptTokens: 50, cachedTokens: 0, completionTokens: 5, turns: 1))
    }

    @Test func rejectsPathLikeJobIds() {
        let jobs = tempDir("usage-path")
        Self.jobDir(jobs, "j_ok", usage: ["prompt_tokens": 1, "cached_tokens": 0, "completion_tokens": 1, "turns": 1])
        #expect(HarnessArm.jobUsage(jobId: "../j_ok", jobsDir: jobs, waitS: 0) == nil)
        #expect(HarnessArm.jobUsage(jobId: "..", jobsDir: jobs, waitS: 0) == nil)
        #expect(HarnessArm.jobUsage(jobId: "", jobsDir: jobs, waitS: 0) == nil)
    }
    /// The server's state dir is what the arm reads from; the real `~/.strim` is never a source.
    @Test func jobsDirComesOnlyFromTheServerStateDir() throws {
        let state = tempDir("usage-state")
        let withState = ServerEndpoint(port: 1, token: "t", modelId: "m", stateDir: state)
        #expect(HarnessArm(endpoint: withState).jobsDir == state.appendingPathComponent("jobs", isDirectory: true))
        // attached or unknown state: no jobs dir, so a limit job's tokens stay unknown instead of reading ~/.strim
        let unknown = ServerEndpoint(port: 1, token: "t", modelId: "m")
        #expect(HarnessArm(endpoint: unknown).jobsDir == nil)
        let limit = HarnessReply.parse("strim job j_home1: limit wall-clock limit reached (900s)")
        #expect(HarnessArm.resolvedUsage(limit, jobsDir: nil, waitS: 0) == nil)
        // the state dir of a spawned server's launch is the one granted with --state-dir, and that is the jobs source
        let base = tempDir("usage-launch")
        let root = base.appendingPathComponent("strim-evolve-7")
        let out = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let launch = try LocalServer.serverLaunch(strimBin: "build/strim", model: "models/q", head: nil, port: 8231,
                                                  tokenFile: "out/t", workRoot: root, logDir: out)
        let dir = try #require(launch.stateDir)
        let i = try #require(launch.argv.firstIndex(of: "--state-dir"))
        #expect(launch.argv[i + 1] == dir.path)
        #expect(dir.path.hasPrefix(out.path) && !dir.path.hasPrefix(NSHomeDirectory() + "/.strim"))
        Self.jobDir(dir.appendingPathComponent("jobs"), "j_fromstate", usage: ["prompt_tokens": 7, "cached_tokens": 0,
                                                                              "completion_tokens": 3, "turns": 1])
        let ep = ServerEndpoint(port: 8231, token: "t", modelId: "m", stateDir: dir)
        let fromState = HarnessReply.parse("strim job j_fromstate: limit wall-clock limit reached (900s)")
        #expect(HarnessArm.resolvedUsage(fromState, jobsDir: HarnessArm(endpoint: ep).jobsDir, waitS: 0)
                == JobUsage(promptTokens: 7, cachedTokens: 0, completionTokens: 3, turns: 1))
    }
}
