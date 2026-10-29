import Foundation
import Testing
@testable import StrimAppCore

private final class FakeModelDownloadProcess: ModelDownloadProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _runs = 0
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
    private func incrementRuns() { lock.lock(); _runs += 1; lock.unlock() }
    func run(binary: String, arguments: [String], line: @escaping @Sendable (Data) -> Void) async throws {
        incrementRuns()
        if fail && runs == 1 {
            line(Data("{\"event\":\"error\",\"code\":\"network\",\"message\":\"network error: fixture failure\"}\n".utf8))
            try await Task.sleep(for: .milliseconds(20))
            throw URLError(.cannotConnectToHost)
        }
        line(Data("{\"event\":\"progress\",\"file\":\"fixture.safetensors\",\"doneBytes\":4200000000,\"totalBytes\":10000000000,\"bytesPerSec\":25000000,\"etaSec\":232}\n".utf8))
        try await Task.sleep(for: .milliseconds(20))
        try Task.checkCancellation()
        line(Data("{\"event\":\"done\"}\n".utf8))
    }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

@MainActor private func waitForDownload(_ condition: () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test func pullJSONParserHandlesPartialLinesAndUnknownEvents() {
    var parser = PullJSONParser()
    let a = Data("{\"event\":\"progress\",\"file\":\"weights-".utf8)
    let b = Data("part.safetensors\",\"doneBytes\":4200000000,\"totalBytes\":10000000000,\"bytesPerSec\":25000000,\"etaSec\":232}\n{\"event\":\"future\"}\n".utf8)
    #expect(parser.append(a).isEmpty)
    let events = parser.append(b)
    #expect(events.count == 1)
    if case .progress(let p) = events[0] {
        #expect(p.file == "weights-part.safetensors")
        #expect(p.doneBytes == 4_200_000_000)
        #expect(p.fraction == 0.42)
    } else { Issue.record("expected progress event") }
}

@Test func pullJSONParserDecodesPlanVerifyDoneAndError() {
    var parser = PullJSONParser()
    let input = """
    {"event":"plan","totalBytes":1234,"files":["model/a.safetensors"]}
    {"event":"verify","file":"model/a.safetensors"}
    {"event":"error","code":"disk_full","message":"low disk"}
    {"event":"done"}
    """
    let events = parser.append(Data(input.utf8)) + parser.finish()
    #expect(events.count == 4)
    #expect(events[0] == .plan(totalBytes: 1234, files: ["model/a.safetensors"]))
    #expect(events[1] == .verify(file: "model/a.safetensors"))
    #expect(events[2] == .error(code: "disk_full", message: "low disk"))
    #expect(events[3] == .done)
}

@Test func modelDownloadStateSelectsFocusedFirstRunSections() {
    let progress = ModelDownloadProgress(file: "weights.safetensors", doneBytes: 1, totalBytes: 2, bytesPerSec: 1)
    for state: ModelDownloadState in [
        .needsDownload(sizeBytes: 2, freeBytes: 3, resumable: false), .confirming,
        .downloading(progress), .verifying(file: "weights.safetensors"), .startingServer,
        .failed(message: "disk full", resumable: true),
    ] { #expect(state.isBlockingFirstRun) }
    #expect(!ModelDownloadState.idle.isBlockingFirstRun)
    #expect(!ModelDownloadState.done.isBlockingFirstRun)
}

@Test @MainActor func downloaderConfirmsDownloadsAndAutostarts() async throws {
    let runner = FakeModelDownloadProcess()
    var started = 0
    let downloader = ModelDownloader(process: runner, directory: "/unused", binary: { "/fixture/strim" },
                                    freeSpace: { _ in 30_000_000_000 }, modelExists: { false }, autostart: { started += 1 })
    downloader.inspect()
    if case .needsDownload = downloader.state {} else { Issue.record("expected first-run download state") }
    downloader.confirm()
    #expect(downloader.state == .confirming)
    downloader.beginDownload()
    await waitForDownload { downloader.state == .startingServer && started == 1 }
    #expect(downloader.state == .startingServer)
    #expect(started == 1)
    #expect(runner.runs == 1)
    downloader.serverDidStart()
    #expect(downloader.state == .done)
}

@Test @MainActor func downloaderDiskPrecheckReportsExactShortfall() {
    let runner = FakeModelDownloadProcess()
    let downloader = ModelDownloader(process: runner, directory: "/unused", binary: { "/fixture/strim" },
                                    freeSpace: { _ in 19_000_000_000 }, modelExists: { false })
    downloader.inspect(); downloader.confirm(); downloader.beginDownload()
    #expect(downloader.state == .failed(message: "Not enough free disk space. You need 20.2 GB; you are missing 1.2 GB.", resumable: false))
    #expect(runner.runs == 0)
}

@Test @MainActor func downloaderExistingModelSkipsPromptAndAutostarts() {
    var started = 0
    let downloader = ModelDownloader(process: FakeModelDownloadProcess(), directory: "/unused", binary: { nil },
                                    modelExists: { true }, autostart: { started += 1 })
    downloader.inspect()
    #expect(downloader.state == .done)
    #expect(started == 1)
}

@Test @MainActor func downloaderCancelKeepsResumeState() async throws {
    let runner = FakeModelDownloadProcess()
    let downloader = ModelDownloader(process: runner, directory: "/unused", binary: { "/fixture/strim" },
                                    freeSpace: { _ in 30_000_000_000 }, modelExists: { false })
    downloader.inspect(); downloader.confirm(); downloader.beginDownload()
    try await Task.sleep(for: .milliseconds(5))
    downloader.cancel()
    #expect(runner.cancelled)
    if case .needsDownload(_, _, let resumable) = downloader.state { #expect(resumable) }
    else { Issue.record("expected resumable first-run state") }
    downloader.confirm(); downloader.beginDownload()
    await waitForDownload { downloader.state == .startingServer }
    #expect(downloader.state == .startingServer)
    #expect(runner.runs == 2)
    downloader.serverDidStart()
    #expect(downloader.state == .done)
}

@Test @MainActor func downloaderFailureCanRetry() async throws {
    let runner = FakeModelDownloadProcess(fail: true)
    let downloader = ModelDownloader(process: runner, directory: "/unused", binary: { "/fixture/strim" },
                                    freeSpace: { _ in 30_000_000_000 }, modelExists: { false })
    downloader.inspect(); downloader.confirm(); downloader.beginDownload()
    await waitForDownload { if case .failed = downloader.state { true } else { false } }
    #expect(downloader.state == .failed(message: "network error: fixture failure", resumable: true))
    downloader.retry()
    await waitForDownload { downloader.state == .startingServer }
    #expect(downloader.state == .startingServer)
    #expect(runner.runs == 2)
    downloader.serverDidStart()
    #expect(downloader.state == .done)
}
