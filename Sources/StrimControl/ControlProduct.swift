import Foundation
import StrimAPI
import StrimHost
import StrimHTTP
import StrimJobs
import StrimServer

/// Product routes: background pause/resume, job cancel, local model listing, pack fingerprint.
extension StrimControlPlane {
    func registerProduct(on server: StrimOpenAIServer) {
        add(server, "POST", StrimRoutes.pause, write: true) { c, req in try await c.pause(req) }
        add(server, "POST", StrimRoutes.resume, write: true) { c, _ in try await c.resume() }
        add(server, "POST", StrimRoutes.jobCancel, write: true) { c, req in try await c.cancelJob(req) }
        add(server, "GET", StrimRoutes.models, write: false) { c, _ in try c.listModels() }
        add(server, "GET", StrimRoutes.pack, write: false) { c, _ in try c.packInfo() }
    }

    // MARK: pause / resume

    func pauseState(cancelled: Int = 0) async -> JobsPauseState {
        let c = await jobs.backgroundCounts
        return JobsPauseState(paused: await jobs.isBackgroundPaused, queued: c.queued, running: c.running, cancelled: cancelled)
    }

    /// Body is optional: `{}` or empty pauses and lets running jobs finish.
    func pause(_ req: Request) async throws -> Reply {
        let b = req.body.isEmpty ? PauseRequest() : try ControlJSON.decode(PauseRequest.self, from: req.body)
        let n = await jobs.pauseBackground(cancelRunning: b.cancelRunning)
        return try .json(await pauseState(cancelled: n))
    }

    func resume() async throws -> Reply {
        await jobs.resumeBackground()
        return try .json(await pauseState())
    }

    // MARK: cancel

    /// Idempotent: a finished job is returned unchanged with `cancelled: false`.
    func cancelJob(_ req: Request) async throws -> Reply {
        let b = try ControlJSON.decode(JobCancelRequest.self, from: req.body)
        guard ControlMapping.isValidJobID(b.jobID) else { throw ControlError.badRequest("malformed job id") }
        guard let before = try? await jobs.status(b.jobID, waitS: 0) else { throw ControlError.notFound("no job \(b.jobID)") }
        let after = try await jobs.cancel(b.jobID)
        await jobs.flush()
        return try .json(JobCancelResult(jobID: b.jobID, status: ControlMapping.status(after.status),
                                         cancelled: !before.status.isTerminal && after.status == .cancelled))
    }

    // MARK: models

    /// Directories under `options.modelRoots` (two levels deep) that hold a `config.json`.
    func listModels() throws -> Reply {
        let fm = FileManager.default
        var out: [LocalModel] = []
        var seen = Set<String>()
        func consider(_ url: URL) {
            guard out.count < 200 else { return }
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let real = PatchApplier.realPath(url.path), !seen.contains(real) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: real + "/config.json"), (try? checkModelPath(real)) != nil else { return }
            seen.insert(real)
            let files = (try? fm.contentsOfDirectory(atPath: real)) ?? []
            let bytes = files.filter { $0.hasSuffix(".safetensors") }.reduce(0.0) { acc, f in
                acc + Double((try? fm.attributesOfItem(atPath: real + "/" + f)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            out.append(LocalModel(name: name, path: real, sizeGB: bytes > 0 ? bytes / ControlMapping.gib : nil,
                                  kind: name.lowercased().contains("mtp") ? "mtp" : "model"))
        }
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map { dir.appendingPathComponent($0) }
        }
        for root in options.modelRoots {
            let r = URL(fileURLWithPath: root)
            consider(r)
            for c in children(r) {
                consider(c)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue, !fm.fileExists(atPath: c.path + "/config.json") {
                    for g in children(c) { consider(g) }
                }
            }
        }
        out.sort { $0.name.lowercased() < $1.name.lowercased() }
        return try .json(ModelList(models: out))
    }

    // MARK: pack

    /// Read-only view of `~/.strim/packs` (written by `strim evolve`): `ACTIVE` plus the newest provenance line.
    func packInfo() throws -> Reply {
        let root = options.packsRoot ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".strim/packs")
        return try .json(Self.readPackInfo(root: root))
    }

    static func readPackInfo(root: URL) -> PackInfo {
        let fm = FileManager.default
        func isFP(_ s: String) -> Bool { s.count == 16 && s.allSatisfy(\.isHexDigit) }
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(isFP).sorted()
        var active = (try? String(contentsOf: root.appendingPathComponent("ACTIVE"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = active, !isFP(a) || !names.contains(a) { active = nil }
        var latest: EvolveSummary?
        for fp in names {
            guard let line = lastLine(of: root.appendingPathComponent(fp).appendingPathComponent("provenance.jsonl")),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let created = obj["createdAt"] as? String else { continue }
            let s = EvolveSummary(fingerprint: fp, parent: obj["parent"] as? String, round: obj["round"] as? Int,
                                  valGainPP: (obj["valGainPP"] as? NSNumber)?.doubleValue,
                                  dryRun: obj["dryRun"] as? Bool ?? false, createdAt: created, source: obj["source"] as? String)
            if latest == nil || created > latest!.createdAt { latest = s }
        }
        return PackInfo(activeFingerprint: active, packCount: names.count, lastEvolve: latest)
    }

    /// Last non-empty line of a file, reading at most its final 64 KiB.
    private static func lastLine(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let d = try? h.readToEnd() else { return nil }
        return String(decoding: d, as: UTF8.self).split(separator: "\n").last.map(String.init)
    }
}
