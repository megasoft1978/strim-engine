import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
private struct GRig {
    let fake: FakeControlClient
    let model: AppModel
    let store: MemoryChatStore

    /// `home` is what the (fake) host reports as its home folder. `connect: false` leaves the host offline.
    static func make(home: String = "/Users/test", enforce: Bool = false, connect: Bool = true, store: MemoryChatStore = MemoryChatStore(),
                     roots: [String]? = nil) async -> GRig {
        let fake = FakeControlClient()
        await fake.setFolders(home: home, roots: roots, enforce: enforce)
        await fake.setUniqueSessions(true)
        let scratch = tempDir("scratch")
        let m = AppModel(client: fake, settings: AppSettings(modelPath: "/models/q", startServerWhenOpens: false), clock: RecordingClock(auto: 1000),
                         mcp: MockMcp(), persist: { _ in }, pollInterval: nil, modelDownloader: ModelDownloader(modelExists: { true }),
                         chatStore: store, scratchRoot: scratch + "/Strim Scratch")
        if connect {
            m.start()
            _ = await waitFor { m.connection.isConnected && m.hostFolders != nil }
        }
        return GRig(fake: fake, model: m, store: store)
    }
}

private func grants(_ fake: FakeControlClient) async -> [String] { await fake.calls.filter { $0.hasPrefix("grant:") } }

@MainActor
@Suite struct FolderGrantAppTests {
    @Test func consentRequiredOutsideHome() async {
        let r = await GRig.make()
        let dir = tempDir("outside")
        #expect(r.model.requestProject(dir) == .needsConsent)
        let c = r.model.pendingConsent
        #expect(c?.path == dir && c?.kind == .add)
        #expect(c?.title.hasPrefix("Allow Strim to read, change files and run commands in ") == true)
        #expect(r.model.projects.isEmpty, "nothing is added before the user allows")
        #expect(await grants(r.fake).isEmpty)
        r.model.stop()
    }

    @Test func noPromptInsideHome() async {
        let dir = tempDir("insidehome")
        let r = await GRig.make(home: (dir as NSString).deletingLastPathComponent)
        guard case .added(let p) = r.model.requestProject(dir) else { Issue.record("expected added"); return }
        #expect(p.path == dir && r.model.pendingConsent == nil && r.model.projects.count == 1)
        #expect(await grants(r.fake).isEmpty)
        #expect(r.model.folderAccessRoot(p) == nil, "no lock glyph inside home")
        r.model.stop()
    }

    @Test func cancelAddsNothing() async {
        let r = await GRig.make()
        r.model.requestProject(tempDir("c"))
        r.model.cancelConsent()
        #expect(r.model.pendingConsent == nil && r.model.projects.isEmpty && r.store.storedIndex.projects.isEmpty)
        #expect(await grants(r.fake).isEmpty)
        r.model.stop()
    }

    @Test func allowGrantsThenProjectIsUsable() async {
        let r = await GRig.make(enforce: true)
        let dir = tempDir("allow")
        r.model.requestProject(dir)
        let p = await r.model.confirmConsent()
        #expect(await grants(r.fake) == ["grant:\(dir)"])
        #expect(p?.path == dir && p?.folderConsent != nil && r.model.pendingConsent == nil)
        #expect(r.store.storedIndex.projects.first?.folderConsent != nil, "consent is persisted in the chat index")
        #expect(r.model.hostFolders?.granted == [dir])
        #expect(r.model.folderAccessRoot(p!) == dir)
        #expect(r.model.selectedThread?.projectId == p?.id)
        await r.model.probeChat()
        if case .ready = r.model.chat {} else { Issue.record("chat should open in the granted folder: \(r.model.chat)") }
        r.model.stop()
    }

    @Test func grantFailureSurfacesTheHostText() async {
        let r = await GRig.make()
        await r.fake.setGrantFailure(APIError(code: "forbidden", message: "/x is inside a protected system location (/usr)"))
        r.model.requestProject(tempDir("fail"))
        let p = await r.model.confirmConsent()
        #expect(p == nil && r.model.projects.isEmpty)
        #expect(r.model.pendingConsent?.error?.contains("protected system location") == true)
        #expect(r.model.pendingConsent?.working == false)
        r.model.cancelConsent()
        #expect(r.model.pendingConsent == nil && r.store.storedIndex.projects.isEmpty)
        r.model.stop()
    }

    @Test func offlineGrantIsQueuedAndAppliedOnStart() async {
        let r = await GRig.make(connect: false)
        let dir = tempDir("queued")
        #expect(r.model.requestProject(dir) == .needsConsent)
        let p = await r.model.confirmConsent()
        #expect(p?.path == dir && p?.folderConsent != nil, "project kept, consent stored")
        #expect(await grants(r.fake).isEmpty, "host offline: nothing sent yet")
        r.model.start()
        let applied = await waitFor { r.model.hostFolders?.granted == [dir] }
        #expect(applied && r.model.pendingConsent == nil, "granted after connect with no new prompt")
        #expect(await grants(r.fake) == ["grant:\(dir)"])
        r.model.stop()
    }

    @Test func hostRestartRegrantsConsentedFolderOnlyWithoutPrompt() async {
        let consented = tempDir("consented"), never = tempDir("never")
        let idx = ChatIndex(projects: [ChatProject(path: consented, addedAt: 1, lastActivity: 1, folderConsent: 5, consentRoot: consented),
                                       ChatProject(path: never, addedAt: 1, lastActivity: 1)], threads: [])
        let r = await GRig.make(store: MemoryChatStore(index: idx))   // host config lost: only home is allowed
        let ok = await waitFor { r.model.hostFolders?.granted == [consented] }
        #expect(ok && r.model.pendingConsent == nil)
        #expect(await grants(r.fake) == ["grant:\(consented)"], "a folder the user never consented to is not granted")
        r.model.stop()
    }

    @Test func poisonedOrLegacyIndexEntriesAreNeverGranted() async {
        let real = tempDir("real"), other = tempDir("other")
        let link = tempDir("links") + "/L"
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let idx = ChatIndex(projects: [
            ChatProject(path: "/tmp", addedAt: 1, lastActivity: 1, folderConsent: 5),                       // legacy / poisoned: no consentRoot
            ChatProject(path: "/tmp", addedAt: 1, lastActivity: 1, folderConsent: 5, consentRoot: "/"),     // poisoned root
            ChatProject(path: link, name: "L", addedAt: 1, lastActivity: 1, folderConsent: 5, consentRoot: real),
        ], threads: [])
        // the symlink is repointed after consent was recorded
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other)
        let r = await GRig.make(store: MemoryChatStore(index: idx))
        _ = await waitFor { r.model.hostFolders != nil }
        try? await Task.sleep(for: .milliseconds(100))
        let none = await grants(r.fake)
        #expect(none.isEmpty, "got \(none)")
        // pointing it back re-grants exactly the consented root
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        await r.model.reconcileFolders()
        #expect(await grants(r.fake) == ["grant:\(real)"])
        r.model.stop()
    }

    @Test func swappedFolderIsRevokedAndReported() async {
        let r = await GRig.make()
        let dir = tempDir("swap")
        await r.fake.setGrantRewrite([dir: "/private/somewhere/else"])
        r.model.requestProject(dir)
        let p = await r.model.confirmConsent()
        #expect(p == nil && r.model.projects.isEmpty)
        #expect(r.model.pendingConsent?.error?.contains("not the folder shown") == true)
        #expect(await r.fake.calls.contains("revoke:/private/somewhere/else"))
        #expect(r.model.hostFolders?.granted == [])
        // case-only difference (case-insensitive volume) is accepted
        let d2 = tempDir("Case")
        await r.fake.setGrantRewrite([d2: d2.lowercased()])
        r.model.cancelConsent()
        r.model.requestProject(d2)
        #expect(await r.model.confirmConsent() != nil)
        r.model.stop()
    }

    @Test func revokeClearsConsentAndEndsSessions() async {
        let r = await GRig.make(enforce: true)
        let dir = tempDir("rev")
        r.model.requestProject(dir)
        let p = await r.model.confirmConsent()!
        await r.model.probeChat()
        #expect(r.model.liveSessions.count == 1)
        await r.model.revokeFolderAccess(projectID: p.id)
        #expect(await r.fake.calls.contains("revoke:\(dir)"))
        #expect(r.model.hostFolders?.granted == [] && r.model.project(p.id)?.folderConsent == nil)
        #expect(r.model.liveSessions.isEmpty)
        #expect(r.model.folderAccessRoot(r.model.project(p.id)!) == nil)
        r.model.stop()
    }

    @Test func removeProjectCanRevokeToo() async {
        let r = await GRig.make(enforce: true)
        let dir = tempDir("rm")
        r.model.requestProject(dir)
        let p = await r.model.confirmConsent()!
        await r.model.removeProject(p.id, revokeAccess: true)
        #expect(await r.fake.calls.contains("revoke:\(dir)") && r.model.projects.isEmpty)
        let r2 = await GRig.make(enforce: true)
        let d2 = tempDir("rm2")
        r2.model.requestProject(d2)
        let q = await r2.model.confirmConsent()!
        await r2.model.removeProject(q.id)
        #expect(await !r2.fake.calls.contains("revoke:\(d2)"), "plain remove keeps the grant")
        r.model.stop(); r2.model.stop()
    }

    @Test func refusedChatShowsHostTextAndGrantAccessWorks() async {
        let r = await GRig.make(enforce: true)
        let dir = tempDir("refused")
        guard case .success(let p) = r.model.addProject(dir), let t = r.model.newThread(projectID: p.id) else { Issue.record("setup"); return }
        await r.model.probeChat()
        #expect(r.model.chatUnavailable[t.id]?.contains("outside the allowed roots") == true)
        #expect(r.model.folderRefused.contains(t.id))
        r.model.requestGrant(forThread: t.id)
        #expect(r.model.pendingConsent?.path == dir && r.model.pendingConsent?.kind == .retry(threadID: t.id))
        _ = await r.model.confirmConsent()
        #expect(r.model.chatUnavailable[t.id] == nil && !r.model.folderRefused.contains(t.id))
        await r.model.probeChat()
        if case .ready = r.model.chat {} else { Issue.record("chat should open after Grant access") }
        r.model.stop()
    }

    @Test func otherRefusalsAreNotFolderRefusals() {
        #expect(FolderMessages.isFolderRefusal(APIError(code: "forbidden", message: "cwd /x is outside the allowed roots (...)")))
        #expect(!FolderMessages.isFolderRefusal(APIError(code: "forbidden", message: "cwd /x rejected: refusing a credentials or host-state directory")))
        #expect(!FolderMessages.isFolderRefusal(APIError(code: "conflict", message: "outside the allowed roots")))
        #expect(FolderMessages.isFolderRefusal(ControlClientError.http(status: 403, api: APIError(code: "forbidden", message: "cwd /x is outside the allowed roots"))))
        #expect(!FolderMessages.isFolderRefusal(ControlClientError.forbidden))
    }

    @Test func projectJSONWithoutConsentStillDecodes() throws {
        let old = #"{"id":"a","path":"/p","name":"p","addedAt":1,"lastActivity":2,"isScratch":false}"#
        let p = try JSONDecoder().decode(ChatProject.self, from: Data(old.utf8))
        #expect(p.folderConsent == nil)
        let round = try JSONDecoder().decode(ChatProject.self, from: JSONEncoder().encode(ChatProject(path: "/p", folderConsent: 3)))
        #expect(round.folderConsent == 3)
    }

    @Test func multipleRequestsQueueOneConsentAtATime() async {
        let r = await GRig.make()
        let a = tempDir("qa"), b = tempDir("qb")
        r.model.requestProject(a); r.model.requestProject(b); r.model.requestProject(a)
        #expect(r.model.pendingConsent?.path == a)
        r.model.cancelConsent()
        #expect(r.model.pendingConsent?.path == b)
        r.model.cancelConsent()
        #expect(r.model.pendingConsent == nil && r.model.projects.isEmpty)
        r.model.stop()
    }
}
