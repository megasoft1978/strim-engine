import Foundation

/// The dictated draft for one chat; the chat view copies `text` into that chat's composer.
public struct DictationOutput: Equatable, Sendable {
    public var threadID: String
    public var text: String
    /// Grows with every publish, so a repeat of the same text is still a change the view sees.
    public var seq = 0
}

// Dictation in the chat composer. The view owns the draft text; this side owns the session and says what the draft
// should read. Dictated text goes after what was typed, partials are replaced by finals, and nothing is ever sent here.
extension AppModel {
    /// The mic button and Cmd-Shift-D: starts dictating into `tid`'s composer (whose current text is `draft`), or stops.
    public func toggleDictation(in tid: String, draft: String) {
        if dictationState.isActive {
            dictationEngine?.stop()
            return
        }
        let engine = dictationEngine ?? makeDictationEngine()
        dictationThreadID = tid
        dictationText.begin(base: draft)
        dictationState = .preparing
        engine.start()
    }

    /// Esc, switching chats, quitting the composer: stop listening; the last words are still delivered.
    public func stopDictation() {
        if dictationState.isActive { dictationEngine?.stop() } else if dictationState.error != nil { dismissDictationMessage() }
    }

    /// Sending: stop and drop whatever the recogniser still has, so nothing lands in the cleared composer.
    func cancelDictation() {
        guard dictationThreadID != nil else { return }
        let wasActive = dictationState.isActive
        dictationThreadID = nil
        dictationText = DictationText()
        if wasActive { dictationEngine?.stop() } else { dictationState = .idle }
    }

    public func dismissDictationMessage() {
        guard dictationState.error != nil else { return }
        dictationState = .idle
        dictationThreadID = nil
    }

    /// The composer text changed (typing, paste, clearing). While dictating, later speech goes after the new text.
    public func dictationDraftChanged(_ draft: String, in tid: String) {
        guard tid == dictationThreadID else { return }
        dictationText.userEdited(draft)
    }

    /// Dictation state as one chat's composer shows it: other chats stay idle.
    public func dictationState(for tid: String) -> DictationState { dictationThreadID == tid ? dictationState : .idle }

    /// Another chat's dictation session is still winding down; starting one here would have to wait.
    public func dictationBusyElsewhere(for tid: String) -> Bool { dictationState.isActive && dictationThreadID != tid }

    public static func dictationSettingsURL() -> URL? { URL(string: DictationInfo.settingsURL) }

    private func makeDictationEngine() -> Dictation {
        let engine = dictationFactory()
        engine.onEvent = { [weak self] in self?.handleDictation($0) }
        dictationEngine = engine
        return engine
    }

    func handleDictation(_ event: DictationEvent) {
        switch event {
        case .state(let s):
            guard dictationThreadID != nil else {
                // Cancelled (Send) or dismissed: only the end of the session matters, whether it ends cleanly or with an error.
                if s == .idle || s.error != nil { dictationState = .idle }
                return
            }
            dictationState = s
            if s == .idle { dictationThreadID = nil }
        case .partial(let text):
            guard dictationThreadID != nil else { return }
            dictationText.setPartial(text)
            publishDictation()
        case .final(let text):
            guard dictationThreadID != nil else { return }
            dictationText.commit(text)
            publishDictation()
        }
    }

    private func publishDictation() {
        guard let tid = dictationThreadID else { return }
        dictationSeq += 1
        dictationOutput = DictationOutput(threadID: tid, text: dictationText.composed, seq: dictationSeq)
    }
}
