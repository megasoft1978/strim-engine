import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
private func wiringModel(_ client: StrimControlClient, settings: AppSettings, launcher: HostLauncher = MockLauncher(.needsModel),
                         saved: Locked<[AppSettings]> = Locked([])) -> AppModel {
    AppModel(client: client, settings: settings, clock: RecordingClock(auto: 100), launcher: launcher, mcp: MockMcp(),
             loginItem: MockLogin(), clipboard: MockClipboard(), persist: { s in saved.with { $0.append(s) } },
             pollInterval: nil, modelDownloader: ModelDownloader(modelExists: { true }))
}

@Suite @MainActor struct ServerWiringTests {
    @Test func startServerWaitsForTheLaunchOutcome() async {
        let launcher = MockLauncher(.started(pid: 4242))
        let m = wiringModel(FakeControlClient(), settings: AppSettings(modelPath: "/models/q", startServerWhenOpens: false), launcher: launcher)
        await m.startServer()
        #expect(m.hostProcessPID == 4242, "the caller sees the result without polling")
        #expect(launcher.calls.value == 1)
        m.stop()
    }

    @Test func startServerFailureAlwaysCarriesAReason() async {
        for result in [HostLaunchResult.failed("boom"), .needsModel, .binaryMissing(command: "strim serve"), .binaryInvalid(reason: "bad", command: "strim serve")] {
            let m = wiringModel(FakeControlClient(), settings: AppSettings(modelPath: "/models/q", startServerWhenOpens: false), launcher: MockLauncher(result))
            await m.startServer()
            #expect(m.hostProcessPID == nil)
            #expect(m.lastError != nil || m.notice != nil, "\(result) must explain itself")
            m.stop()
        }
    }

    @Test func thinkingStartsFromSavedSettings() {
        let off = wiringModel(FakeControlClient(), settings: AppSettings(thinkingEnabled: false))
        #expect(off.thinkingEnabled == false)
        let on = wiringModel(FakeControlClient(), settings: AppSettings(thinkingEnabled: true))
        #expect(on.thinkingEnabled == true)
    }

    @Test func composerAndSettingsShareTheDefaultThinkingSetter() {
        let saved = Locked<[AppSettings]>([])
        let m = wiringModel(FakeControlClient(), settings: AppSettings(), saved: saved)
        m.setDefaultThinking(false)   // what the empty-chat composer toggle and Settings both call
        #expect(saved.value.last?.thinkingEnabled == false)
        let reopened = wiringModel(FakeControlClient(), settings: saved.value.last!)
        #expect(reopened.thinkingEnabled == false, "the next launch starts with the saved choice")
    }

    @Test func loadModelHonorsMTPOff() async {
        for (disabled, expected) in [(true, nil), (false, "/models/mtp")] as [(Bool, String?)] {
            let fake = FakeControlClient(status: status(.stopped, model: nil))
            let m = wiringModel(fake, settings: AppSettings(modelPath: "/models/q", mtpPath: "/models/mtp", mtpDisabled: disabled))
            m.start()
            #expect(await waitFor { m.connection.isConnected })
            await m.loadModel()
            #expect(await fake.statusValue.mtp == expected)
            m.stop()
        }
    }

    @Test func idleServerStartHonorsMTPOff() async {
        for (disabled, expectDefault) in [(true, false), (false, true)] {
            let fake = FakeControlClient(status: status(.stopped, model: nil))
            let m = wiringModel(fake, settings: AppSettings(modelPath: "/models/q", mtpDisabled: disabled))
            m.start()
            #expect(await waitFor { m.connection.isConnected && m.status?.state == .stopped })
            await m.startServer()
            let mtp = await fake.statusValue.mtp
            #expect(disabled ? mtp == nil : mtp?.hasSuffix("qwen38-mtp-4bit") == true, "disabled=\(disabled) mtp=\(mtp ?? "nil") default=\(expectDefault)")
            m.stop()
        }
    }

    @Test func stopConfirmationRuleIsOneModelProperty() async {
        let fake = FakeControlClient(status: status(.ready, active: 0))
        let m = wiringModel(fake, settings: AppSettings(modelPath: "/models/q"))
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(!m.serverStopNeedsConfirmation)
        await fake.emit(.status(status(.busy, active: 2)))
        #expect(await waitFor { m.status?.activeJobs == 2 })
        #expect(m.serverStopNeedsConfirmation, "toolbar, popover and overflow all gate on this")
        m.stop()
    }
}
