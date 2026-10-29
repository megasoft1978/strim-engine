import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@Suite @MainActor struct UIStateTests {
    private func model(_ fake: StrimControlClient = FakeControlClient()) -> AppModel {
        AppModel(client: fake, settings: AppSettings(modelPath: "/m", projectPath: "/tmp", startServerWhenOpens: false),
                 clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(), loginItem: MockLogin(),
                 clipboard: MockClipboard(), persist: { _ in }, pollInterval: nil,
                 modelDownloader: ModelDownloader(modelExists: { true }))
    }

    @Test func decodeHistoryKeepsTheNewest60Samples() {
        let m = model()
        m.seedDecodeHistory((0..<100).map(Double.init))
        #expect(m.decodeHistory.count == AppModel.decodeHistoryLimit)
        #expect(m.decodeHistory.first == 40 && m.decodeHistory.last == 99)
    }

    @Test func liveStatusFeedsTheSparklineHistory() async {
        let m = model()
        m.start()
        #expect(await waitFor { !m.decodeHistory.isEmpty })
        m.stop()
    }

    @Test func menuBarSpeedSettingDefaultsOnAndSurvivesOldFiles() throws {
        #expect(AppSettings().showSpeedInMenuBar)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"model_path":"/only"}"#.utf8))
        #expect(old.showSpeedInMenuBar)
        var s = AppSettings(); s.showSpeedInMenuBar = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(!back.showSpeedInMenuBar)
    }

    @Test func pausingRemembersWhereTheDownloadStopped() {
        let p = ModelDownloadProgress(file: "f", doneBytes: 4_000_000_000, totalBytes: 10_000_000_000, bytesPerSec: 1)
        let d = ModelDownloader(modelExists: { false }, initialState: .downloading(p))
        d.cancel()
        #expect(d.pausedFraction == 0.4)
        if case .needsDownload(_, _, let resumable) = d.state { #expect(resumable) } else { Issue.record("expected needsDownload") }
    }
}
