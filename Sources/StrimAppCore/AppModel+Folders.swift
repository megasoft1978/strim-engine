import Foundation
import StrimAPI

// Folder access: a project outside the host's allowed roots needs the user's explicit consent, which asks the host to
// grant the folder (control token). Nothing here runs from chat content or host events: the only entry points are
// `requestProject`, `requestRelocate`, `requestGrant(forThread:)` (all called from UI actions), and `confirmConsent`
// (the Allow button). `reconcileFolders` only re-grants folders the user already consented to.

public enum FolderConsentKind: Equatable, Sendable {
    case add
    case relocate(projectID: String)
    /// A chat open was refused; Allow grants the thread's project folder.
    case retry(threadID: String)
}

public struct FolderConsent: Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    /// Resolved folder path.
    public var path: String
    public var kind: FolderConsentKind
    /// Why the host refused (shown in the sheet).
    public var error: String?
    public var working = false
    public init(path: String, kind: FolderConsentKind) { self.path = path; self.kind = kind }

    public var title: String { "Allow Strim to read, change files and run commands in \(PathDisplay.tilde(path))?" }
    public static let detail = "Strim works in an isolated copy and every change comes back as a patch you review in Jobs."
}

public enum ProjectRequest: Equatable, Sendable {
    /// Usable now (inside an allowed folder, or already allowed).
    case added(ChatProject)
    /// The consent step is on screen (`AppModel.pendingConsent`).
    case needsConsent
    case failed(ProjectFolder.Problem)
}

public enum FolderMessages {
    /// The host's folder-policy refusal (cwd outside the allowed roots), as a chat-open error.
    public static func isFolderRefusal(_ error: Error) -> Bool {
        let text: String
        switch error {
        case ControlClientError.http(let s, let api): guard s == 403 else { return false }; text = api?.message ?? ""
        case let a as APIError: guard a.code == "forbidden" else { return false }; text = a.message
        default: return false
        }
        return text.contains("outside the allowed roots")
    }

    /// The host's own explanation when it gave one.
    public static func text(_ error: Error) -> String {
        return error.localizedDescription
    }

    static func isOffline(_ error: Error) -> Bool {
        if let e = error as? ControlClientError {
            switch e { case .hostUnreachable, .timeout: return true; default: return false }
        }
        return false
    }
}

extension AppModel {
    static func resolvedPath(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    static func contains(_ root: String, _ path: String) -> Bool {
        let r = resolvedPath(root), p = resolvedPath(path)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    var folderHome: String { Self.resolvedPath(hostFolders?.home ?? NSHomeDirectory()) }

    /// True when the host already lets Strim work in `path` (home, or inside a granted folder).
    public func isFolderAllowed(_ path: String) -> Bool {
        let roots = hostFolders?.folders ?? [folderHome]
        return roots.contains { Self.contains($0, path) }
    }

    /// The granted folder (outside home) that covers the project, nil for projects in home or Scratch.
    public func folderAccessRoot(_ p: ChatProject) -> String? {
        guard !p.isScratch else { return nil }
        let home = folderHome
        if let granted = hostFolders?.granted.first(where: { Self.contains($0, p.path) && !Self.contains(home, $0) }) { return granted }
        // Host list unknown (offline): a consented project outside home counts as granted.
        if hostFolders == nil, let r = Self.consentedRoot(p), !Self.contains(home, p.path) { return r }
        return nil
    }

    /// The folder the user consented to for this project, only while the project's path still resolves to it.
    static func consentedRoot(_ p: ChatProject) -> String? {
        guard p.folderConsent != nil, let r = p.consentRoot, r.hasPrefix("/"), r != "/", resolvedPath(p.path) == r else { return nil }
        return r
    }

    /// Roots the user granted, for Settings.
    public var grantedFolders: [String] { hostFolders?.granted ?? [] }

    // MARK: requests (UI actions only)

    /// Adds a project when its folder is allowed; otherwise shows the consent step. Never grants by itself.
    @discardableResult
    public func requestProject(_ raw: String) -> ProjectRequest {
        switch ProjectFolder.resolve(raw) {
        case .failure(let e):
            lastError = e.message
            return .failed(e)
        case .success(let dir):
            if let p = projects.first(where: { $0.path == dir && !$0.isScratch }), isFolderAllowed(dir) || p.folderConsent != nil {
                return .added(p)
            }
            if isFolderAllowed(dir) {
                switch addProject(dir) { case .success(let p): return .added(p); case .failure(let e): return .failed(e) }
            }
            enqueueConsent(FolderConsent(path: dir, kind: .add))
            return .needsConsent
        }
    }

    /// Locate: repoints the project, asking for consent first when the new folder is not allowed.
    public func requestRelocate(_ id: String, path raw: String) async -> ProjectRequest {
        switch ProjectFolder.resolve(raw) {
        case .failure(let e):
            lastError = e.message
            return .failed(e)
        case .success(let dir):
            if isFolderAllowed(dir) {
                switch await relocateProject(id, path: dir) { case .success(let p): return .added(p); case .failure(let e): return .failed(e) }
            }
            enqueueConsent(FolderConsent(path: dir, kind: .relocate(projectID: id)))
            return .needsConsent
        }
    }

    /// "Grant access" on a refused chat.
    public func requestGrant(forThread tid: String) {
        guard let t = thread(tid), let p = project(t.projectId), !p.isScratch else { return }
        enqueueConsent(FolderConsent(path: p.path, kind: .retry(threadID: tid)))
    }

    private func enqueueConsent(_ c: FolderConsent) {
        if pendingConsent == nil { pendingConsent = c }
        else if pendingConsent?.path != c.path || pendingConsent?.kind != c.kind, !consentQueue.contains(where: { $0.path == c.path && $0.kind == c.kind }) {
            consentQueue.append(c)
        }
    }

    private func advanceConsent() { pendingConsent = consentQueue.isEmpty ? nil : consentQueue.removeFirst() }

    /// Cancel: nothing is added or granted.
    public func cancelConsent() { advanceConsent() }

    /// Allow: asks the host to grant the folder. An offline host queues it (applied when the server connects); a host
    /// refusal keeps the sheet open with the reason and adds nothing.
    @discardableResult
    public func confirmConsent() async -> ChatProject? {
        guard var c = pendingConsent, !c.working else { return nil }
        c.working = true; c.error = nil; pendingConsent = c
        var root = Self.resolvedPath(c.path)
        if connection.isConnected {
            do { root = try await grantChecked(c.path) ?? root; log("granted folder \(PathDisplay.tilde(c.path))") }
            catch {
                if !FolderMessages.isOffline(error) {
                    c.working = false
                    c.error = isNotImplemented(error) ? "This Strim server cannot grant folder access. Update the server." : FolderMessages.text(error)
                    pendingConsent = c
                    return nil
                }
                log("folder grant queued: host unreachable")
            }
        } else {
            log("folder grant queued: host offline")
        }
        var result: ChatProject?
        switch c.kind {
        case .add:
            if case .success(let p) = addProject(c.path) { result = p; markConsent(p.id, root: root); _ = newThread(projectID: p.id) }
        case .relocate(let id):
            if case .success(let p) = await relocateProject(id, path: c.path) { result = p; markConsent(p.id, root: root) }
        case .retry(let tid):
            if let t = thread(tid), let p = project(t.projectId) { result = p; markConsent(p.id, root: root) }
            chatUnavailable[tid] = nil; folderRefused.remove(tid)
        }
        advanceConsent()
        return result.flatMap { project($0.id) }
    }

    private func markConsent(_ projectID: String, root: String) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[i].folderConsent = nowTS
        projects[i].consentRoot = root
        saveIndex()
    }

    // MARK: revoke

    /// Project menu: revokes the folder that covers the project.
    public func revokeFolderAccess(projectID: String) async {
        guard let p = project(projectID), let root = folderAccessRoot(p) else { return }
        await revokeFolder(root)
    }

    /// Revokes a granted folder; projects under it lose their consent and their open sessions end.
    public func revokeFolder(_ root: String) async {
        do { hostFolders = try await client.revokeFolder(path: root) }
        catch {
            if case ControlClientError.http(404, _) = error { /* already gone on the host */ }
            else if let a = error as? APIError, a.code == "not_found" { /* same */ }
            else { lastError = "Revoke folder access: \(FolderMessages.text(error))"; return }
            if hostFolders != nil { hostFolders?.folders.removeAll { $0 == root } }
        }
        log("revoked folder \(PathDisplay.tilde(root))")
        for i in projects.indices where !projects[i].isScratch && Self.contains(root, projects[i].path) {
            projects[i].folderConsent = nil; projects[i].consentRoot = nil
            for t in threads where t.projectId == projects[i].id {
                if generatingThreadID == t.id { await cancel(t.id) }
                await closeSession(t.id)
            }
        }
        saveIndex()
    }

    // MARK: connect

    /// On every connect: refresh the host's folder list and re-grant, without asking, the folders the user already
    /// consented to (host restart, config loss). A folder without recorded consent is never granted here.
    func reconcileFolders() async {
        guard connection.isConnected else { return }
        do { hostFolders = try await client.folders() }
        catch { hostFolders = nil; return }
        for p in projects where !p.isScratch {
            // Only the exact folder the user allowed, and only while the project still resolves to it.
            guard let root = Self.consentedRoot(p), !isFolderAllowed(root) else { continue }
            do { _ = try await grantChecked(root); log("re-granted folder \(PathDisplay.tilde(root))") }
            catch { log("folder re-grant failed: \(FolderMessages.text(error))") }
        }
    }

    /// Grants `path` and checks the host stored the folder that was shown. A different resolved entry (the folder was
    /// swapped between the sheet and the click) is revoked again and reported. Returns the entry the host stored.
    private func grantChecked(_ path: String) async throws -> String? {
        var known = hostFolders
        if known == nil { known = try? await client.folders() }
        let before = known?.folders
        let list = try await client.grantFolder(path: path)
        hostFolders = list
        guard let before else { return nil }
        let added = list.folders.filter { !before.contains($0) }
        guard !added.isEmpty else { return nil }
        if let hit = added.first(where: { $0.lowercased() == Self.resolvedPath(path).lowercased() || $0.lowercased() == path.lowercased() }) { return hit }
        for e in added { if let l = try? await client.revokeFolder(path: e) { hostFolders = l } }
        throw FolderMessageError(text: "The folder resolved to \(added[0]) when it was granted, not the folder shown. Nothing was granted.")
    }
}

struct FolderMessageError: Error, LocalizedError { var text: String; var errorDescription: String? { text } }
