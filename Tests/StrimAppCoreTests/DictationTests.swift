import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

// Dictation without a microphone: FakeDictation stands in for the engine, SpeechDictation is only driven up to the
// permission / OS checks (which run before any Speech or audio API is touched).

@MainActor
private struct DictRig {
    let model: AppModel
    let fake: FakeDictation
    let thread: String

    static func make() -> DictRig {
        let fake = FakeControlClient()
        let dirs = [tempDir("proj"), tempDir("proj")]
        let settings = AppSettings(modelPath: "/models/q", projectPath: dirs[0], recentProjects: dirs, startServerWhenOpens: false)
        let m = AppModel(client: fake, settings: settings, clock: RecordingClock(auto: 1000), mcp: MockMcp(), persist: { _ in },
                         pollInterval: nil, modelDownloader: ModelDownloader(modelExists: { true }), chatStore: MemoryChatStore(),
                         scratchRoot: tempDir("scratch") + "/Strim Scratch")
        let dict = FakeDictation()
        m.dictationFactory = { dict }
        let t = m.newThread(projectID: m.projects[0].id)!
        return DictRig(model: m, fake: dict, thread: t.id)
    }
    var text: String? { model.dictationOutput?.text }
    /// A chat in the other project; selects it.
    func otherChat() -> ChatThread {
        let p = model.projects.first { $0.id != model.thread(thread)?.projectId }!
        return model.newThread(projectID: p.id)!
    }
}

@MainActor
@Suite struct DictationTests {
    // MARK: text

    @Test func partialIsReplacedByTheNextPartialAndThenByTheFinal() {
        var t = DictationText(base: "")
        t.setPartial("hello wor")
        #expect(t.composed == "hello wor")
        t.setPartial("hello world")
        #expect(t.composed == "hello world")
        t.commit("Hello world.")
        #expect(t.composed == "Hello world.")
        t.setPartial("next")
        #expect(t.composed == "Hello world. next")
        t.commit("Next one.")
        #expect(t.composed == "Hello world. Next one.")
    }

    @Test func dictationGoesAfterTheTypedTextWithOneSpace() {
        var t = DictationText(base: "Fix the bug")
        t.setPartial("in parser")
        #expect(t.composed == "Fix the bug in parser")
        t.begin(base: "Line one\n")
        t.commit("line two")
        #expect(t.composed == "Line one\nline two", "no extra space after a newline")
        t.begin(base: "typed")
        #expect(t.composed == "typed", "nothing dictated yet: the draft is untouched")
        t.begin(base: "")
        t.commit("  \n ")
        #expect(t.composed == "")
        t.commit("two\nlines")
        #expect(t.composed == "two lines", "newlines from the recogniser never reach the single-line field")
    }

    @Test func typingWhileDictatingBecomesTheNewBase() {
        var t = DictationText(base: "a")
        t.commit("b")
        let echo = t.userEdited("a b"), typed = t.userEdited("a b typed")
        #expect(!echo, "the composer echoing our own text is not an edit")
        #expect(typed)
        t.setPartial("c")
        #expect(t.composed == "a b typed c")
    }

    @Test func silenceGateStopsAfterTwoSecondsOfQuietFollowingSpeech() {
        var g = SilenceGate()
        var early = [g.feed(rms: 0.2, duration: 0.1)]
        for _ in 0..<19 { early.append(g.feed(rms: 0.001, duration: 0.1)) }
        #expect(!early.contains(true))
        let stop = g.feed(rms: 0.001, duration: 0.1)
        #expect(stop, "2.0 s of quiet")
        var g2 = SilenceGate()
        _ = g2.feed(rms: 0.2, duration: 0.1)
        for _ in 0..<15 { _ = g2.feed(rms: 0.001, duration: 0.1) }
        let again = g2.feed(rms: 0.2, duration: 0.1)
        #expect(!again, "speech resets the quiet counter")
        #expect(g2.quiet == 0)
    }

    @Test func silenceGateGivesUpWhenNothingWasSaid() {
        var g = SilenceGate()
        var early: [Bool] = []
        for _ in 0..<79 { early.append(g.feed(rms: 0.0, duration: 0.1)) }
        #expect(!early.contains(true))
        let stop = g.feed(rms: 0.0, duration: 0.1)
        #expect(stop, "8 s without any speech")
    }

    @Test func typedWordsAreNotDuplicatedByTheRecognisersInFlightPhrase() {
        var t = DictationText(base: "")
        t.setPartial("hello world")
        let edited = t.userEdited("hello world!")
        #expect(edited)
        t.setPartial("hello world foo")
        #expect(t.composed == "hello world! foo")
        t.setPartial("hello world foo bar")
        #expect(t.composed == "hello world! foo bar")
        t.commit("Hello world foo bar.")
        #expect(t.composed == "hello world! foo bar.")
        t.setPartial("hello world again")
        #expect(t.composed == "hello world! foo bar. hello world again", "the suppressed prefix ends with the final")
    }

    @Test func punctuationInTheFinalDoesNotDuplicateTheTypedPhrase() {
        var a = DictationText(base: "")
        a.setPartial("hello world")
        a.userEdited("hello world!")
        a.commit("Hello world.")
        #expect(a.composed == "hello world!", "a final that only adds punctuation adds nothing")

        var b = DictationText(base: "")
        b.setPartial("hello world")
        b.userEdited("hello world!")
        b.commit("Hello, world. Foo")
        #expect(b.composed == "hello world! Foo", "only the new words are appended")

        var c = DictationText(base: "")
        c.setPartial("hello world")
        c.userEdited("hello world!")
        c.commit("Hello worldwide.")
        #expect(c.composed == "hello world! Hello worldwide.", "a longer word is not the typed one")
    }

    @Test func aPartialThatDoesNotStartWithTheEditedPhraseIsKept() {
        var t = DictationText(base: "")
        t.setPartial("hello world")
        t.userEdited("hello world!")
        t.setPartial("something else")
        #expect(t.composed == "hello world! something else")
        t.setPartial("hello worldwide")
        #expect(t.composed == "hello world! hello worldwide", "only whole words count as a prefix")
    }

    // MARK: model

    @Test func toggleStartsListeningAndAPartialAppearsInTheComposer() {
        let r = DictRig.make()
        r.fake.onStart = [.state(.preparing)]
        r.model.toggleDictation(in: r.thread, draft: "Please")
        #expect(r.fake.startCount == 1 && r.model.dictationState == .preparing)
        #expect(r.model.dictationState(for: r.thread) == .preparing)
        #expect(r.model.dictationState(for: "other") == .idle, "only the chat being dictated into shows the state")
        r.fake.emit(.state(.listening))
        r.fake.emit(.partial("rename the"))
        #expect(r.text == "Please rename the" && r.model.dictationOutput?.threadID == r.thread)
        r.fake.emit(.partial("rename the timeout"))
        #expect(r.text == "Please rename the timeout")
        r.fake.emit(.final("rename the timeout."))
        #expect(r.text == "Please rename the timeout.")
    }

    @Test func toggleAgainStopsAndTheLastWordsStillLand() {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.onStop = []   // the engine finalises asynchronously
        r.fake.emit(.partial("almost"))
        r.model.toggleDictation(in: r.thread, draft: "ignored while listening")
        #expect(r.fake.stopCount == 1 && r.fake.startCount == 1)
        #expect(r.model.dictationState == .listening, "still finishing")
        r.fake.emit(.final("Almost done."))
        r.fake.emit(.state(.idle))
        #expect(r.model.dictationState == .idle && r.model.dictationOutput?.text == "Almost done.")
        #expect(r.model.dictationThreadID == nil)
    }

    @Test func escapeAndSwitchingChatsStopIt() {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.model.stopDictation()
        #expect(r.fake.stopCount == 1 && r.model.dictationState == .idle)

        r.model.toggleDictation(in: r.thread, draft: "")
        let other = r.otherChat()
        #expect(other.id != r.thread)
        #expect(r.fake.stopCount == 2 && r.model.dictationState == .idle)
    }

    @Test func dictationNeverSends() {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.emit(.final("send this to the model"))
        r.fake.emit(.state(.idle))
        #expect(r.model.queuedText(for: r.thread) == nil && r.model.chatMessages.isEmpty)
        #expect(r.model.messages[r.thread]?.isEmpty ?? true)
    }

    @Test func sendingDropsLateDictationSoItCannotRefillTheComposer() async {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.emit(.partial("hello there"))
        let sent = r.model.submitDraft(r.model.dictationOutput!.text, in: r.thread, available: true)
        #expect(sent != nil)
        #expect(r.fake.stopCount == 1)
        let before = r.model.dictationOutput
        r.fake.emit(.final("hello there again"))
        r.fake.emit(.state(.idle))
        #expect(r.model.dictationOutput == before, "late words after Send are ignored")
        #expect(r.model.dictationState == .idle)
        await sent?.value
    }

    @Test func typingDuringDictationKeepsWhatWasTyped() {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.emit(.final("first"))
        r.model.dictationDraftChanged("first, edited", in: r.thread)
        r.fake.emit(.partial("second"))
        #expect(r.text == "first, edited second")
        r.model.dictationDraftChanged("ignored", in: "other-chat")
        r.fake.emit(.final("second."))
        #expect(r.text == "first, edited second.")
    }

    @Test func anErrorAfterSendStillEndsTheSessionAndTheMicWorksAgain() {
        let r = DictRig.make()
        r.fake.onStop = []
        r.model.toggleDictation(in: r.thread, draft: "")
        let sent = r.model.submitDraft("hi", in: r.thread, available: true)
        #expect(sent != nil)
        r.fake.emit(.state(.error(.failed("x"))))
        #expect(r.model.dictationState == .idle)
        r.model.toggleDictation(in: r.thread, draft: "")
        #expect(r.fake.startCount == 2)
    }

    @Test func aRepeatedUtteranceIsStillANewOutput() {
        let r = DictRig.make()
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.emit(.final("same words"))
        let first = r.model.dictationOutput
        r.fake.emit(.state(.idle))
        r.model.toggleDictation(in: r.thread, draft: "")
        r.fake.emit(.final("same words"))
        let second = r.model.dictationOutput
        #expect(first?.text == second?.text && first != second && second!.seq > first!.seq)
    }

    @Test func theMicIsBusyOnlyWhileAnotherChatsSessionRunsDown() {
        let r = DictRig.make()
        r.fake.onStop = []
        r.model.toggleDictation(in: r.thread, draft: "")
        #expect(!r.model.dictationBusyElsewhere(for: r.thread))
        #expect(r.model.dictationBusyElsewhere(for: "other"))
        r.fake.emit(.state(.idle))
        #expect(!r.model.dictationBusyElsewhere(for: "other"))
    }

    @Test func permissionDeniedShowsTheMessageAndOffersSettings() {
        let r = DictRig.make()
        r.fake.onStart = [.state(.preparing), .state(.error(.microphoneDenied))]
        r.model.toggleDictation(in: r.thread, draft: "keep")
        let e = r.model.dictationState(for: r.thread).error
        #expect(e == .microphoneDenied && e?.offersSettings == true)
        #expect(e?.message.contains("System Settings") == true)
        #expect(AppModel.dictationSettingsURL()?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(r.model.dictationState(for: "other") == .idle)
        r.model.dismissDictationMessage()
        #expect(r.model.dictationState == .idle && r.model.dictationState(for: r.thread) == .idle)
    }

    @Test func errorsCanBeRetriedAndOtherErrorsOfferNoSettings() {
        let r = DictRig.make()
        r.fake.onStart = [.state(.error(.failed("no microphone input is available")))]
        r.model.toggleDictation(in: r.thread, draft: "")
        #expect(r.model.dictationState.error == .failed("no microphone input is available"))
        #expect(r.model.dictationState.error?.offersSettings == false)
        #expect(DictationError.needsNewerOS.message == "Dictation needs macOS 26 or later.")
        #expect(!DictationError.microphoneRestricted.offersSettings && !DictationError.needsNewerOS.offersSettings)
        r.fake.onStart = [.state(.listening)]
        r.model.toggleDictation(in: r.thread, draft: "")   // retry from the error state
        #expect(r.fake.startCount == 2 && r.model.dictationState == .listening)
        r.model.stopDictation()
        #expect(r.model.dictationState == .idle)
    }

    @Test func switchingChatsDismissesAnError() {
        let r = DictRig.make()
        r.fake.onStart = [.state(.error(.microphoneDenied))]
        r.model.toggleDictation(in: r.thread, draft: "")
        _ = r.otherChat()
        #expect(r.model.dictationState == .idle)
    }

    @Test func theEngineIsCreatedOnFirstUseOnly() {
        let r = DictRig.make()
        #expect(r.model.dictationEngine == nil, "launching the app never touches the microphone or Speech")
        r.model.toggleDictation(in: r.thread, draft: "")
        #expect(r.model.dictationEngine != nil)
    }

    // MARK: real engine, up to the checks that run before any audio or Speech API

    private struct StubMic: MicrophoneAccess {
        var status: MicrophoneStatus
        let asked: Locked<Int>
        func ensure() async -> MicrophoneStatus { asked.with { $0 += 1 }; return status }
    }

    private func run(_ d: SpeechDictation) async -> [DictationEvent] {
        var seen: [DictationEvent] = []
        d.onEvent = { seen.append($0) }
        d.start()
        for _ in 0..<400 where !(seen.last.map { if case .state(.error) = $0 { true } else { false } } ?? false) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return seen
    }

    @Test func realEngineReportsDeniedAndRestrictedWithoutTouchingSpeech() async {
        for (status, expected) in [(MicrophoneStatus.denied, DictationError.microphoneDenied), (.restricted, .microphoneRestricted)] {
            let asked = Locked(0)
            let d = SpeechDictation(mic: StubMic(status: status, asked: asked), osSupported: true)
            let events = await run(d)
            #expect(events == [.state(.preparing), .state(.error(expected))])
            #expect(asked.value == 1)
        }
    }

    @Test func realEngineSaysNeedsNewerOSBeforeAskingForTheMicrophone() async {
        let asked = Locked(0)
        let d = SpeechDictation(mic: StubMic(status: .granted, asked: asked), osSupported: false)
        let events = await run(d)
        #expect(events == [.state(.preparing), .state(.error(.needsNewerOS))])
        #expect(asked.value == 0, "no permission prompt on a Mac that cannot dictate")
    }
}

