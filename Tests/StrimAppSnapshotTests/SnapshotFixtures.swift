import SwiftUI
import AppKit
@testable import StrimApp
import StrimAppCore
import StrimAPI

/// Fixture models, built once per test run from the app's own snapshot fixtures (`SnapshotMode.scenario`,
/// `SnapshotMode.projectsModel`): a scripted `FakeControlClient`, `MemoryChatStore`, no host, no network.
@MainActor
enum Fixtures {
    static var cache: [String: AppModel] = [:]

    static func model(_ key: String, _ build: () async -> AppModel) async -> AppModel {
        if let m = cache[key] { return m }
        let m = await build()
        cache[key] = m
        return m
    }

    static let stoppedStatus = HostStatus(state: .stopped, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 64), uptimeSeconds: 0, jobsPaused: false)

    static func status(_ key: String) async -> AppModel {
        await model("status-" + key) {
            switch key {
            case "running": return await SnapshotMode.scenario(status: SnapshotMode.runningStatus(), jobs: [], history: history)
            case "idle": return await SnapshotMode.scenario(status: SnapshotMode.runningStatus(state: .ready, decode: 0), history: history)
            case "stopped": return await SnapshotMode.scenario(status: stoppedStatus)
            case "error":
                return await SnapshotMode.scenario(status: HostStatus(state: .error, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 64),
                    uptimeSeconds: 0, lastCrash: "Metal command buffer failed: out of memory while loading model-00017-of-00032.safetensors", jobsPaused: false))
            default: // loading
                return await SnapshotMode.scenario(status: HostStatus(state: .loading, loadProgress: 0.42, memory: MemoryStats(weightsGB: 6.4, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 26.1), uptimeSeconds: 4, jobsPaused: false))
            }
        }
    }

    static let history: [Double] = (0..<60).map { (i: Int) -> Double in let x = Double(i); return 62 + 9 * sin(x / 5) + 3 * cos(x / 2.3) }

    /// First-run / download states. Key = state name.
    static func firstRun(_ key: String) async -> AppModel {
        await model("fr-" + key) {
            let state: ModelDownloadState
            var free: Int64 = 24_800_000_000
            var paused: Double?
            switch key {
            case "needs-download": state = .needsDownload(sizeBytes: 15_200_000_000, freeBytes: free, resumable: false)
            case "low-disk": free = 19_000_000_000; state = .needsDownload(sizeBytes: 15_200_000_000, freeBytes: free, resumable: false)
            case "downloading": state = .downloading(.init(file: "qwen38-4bit/model-00017-of-00032.safetensors", doneBytes: 6_384_000_000, totalBytes: 15_200_000_000, bytesPerSec: 28_400_000, etaSec: 310))
            case "paused": state = .needsDownload(sizeBytes: 15_200_000_000, freeBytes: free, resumable: true); paused = 0.42
            case "verifying": state = .verifying(file: "qwen38-4bit/model-00017-of-00032.safetensors")
            case "starting-server": state = .startingServer
            default: state = .failed(message: "The network connection was lost while downloading model-00017-of-00032.safetensors. Downloaded parts are kept.", resumable: true)
            }
            return await SnapshotMode.scenario(status: stoppedStatus, downloadState: state, free: free, pausedFraction: paused)
        }
    }

    /// Jobs. Started times sit mid-bucket of the relative text ("1m ago", "4m ago", "1h ago"), 30 s from a flip.
    static func jobs(select: String?) async -> AppModel {
        await model("jobs-" + (select ?? "none")) {
            let t = SnapshotMode.now
            let list = [JobSummary(id: "j_abcdefgh23", source: .mcp, status: .running, started: t - 90, title: "Fix failing ParseTests"),
                        JobSummary(id: "j_bcdefghi34", source: .mcp, status: .awaitingApproval, verify: .verified, started: t - 270, title: "Rename Config.timeout to requestTimeout"),
                        JobSummary(id: "j_cdefghij45", source: .chat, status: .done, verify: .verified, started: t - 5400, title: "Chat: strim-engine")]
            var details = SnapshotMode.sampleDetails()
            for i in details.indices { details[i].summary = list[i] }
            return await SnapshotMode.scenario(status: SnapshotMode.runningStatus(), jobs: list, details: details, select: select)
        }
    }

    /// The scripted tool-output chat (multi-line tool result, reasoning, usage line).
    static func chatTools() async -> AppModel {
        await model("chat-tools") { await SnapshotMode.scenario(status: SnapshotMode.runningStatus(), chat: true) }
    }

    static func projects(empty: Bool = false, grants: Bool = false) async -> AppModel {
        await model("projects-\(empty)-\(grants)") { await SnapshotMode.projectsModel(empty: empty, grants: grants) }
    }

    /// Consent sheet content (a folder outside the host's allowed folders).
    static func consent(error: String? = nil) async -> FolderConsent {
        let m = await SnapshotMode.projectsModel(grants: true)
        try? FileManager.default.createDirectory(atPath: "\(SnapshotMode.fxRoot)/new-client", withIntermediateDirectories: true)
        m.requestProject("\(SnapshotMode.fxRoot)/new-client")
        var c = m.pendingConsent ?? FolderConsent(path: "\(SnapshotMode.fxRoot)/new-client", kind: .add)
        c.error = error
        m.stop()
        return c
    }
}
