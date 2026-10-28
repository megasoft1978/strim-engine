import Foundation

public struct PullOptions: Sendable {
    public var dir: URL
    public var endpoint: URL = PullManifest.defaultEndpoint
    /// From HF_TOKEN. Only ever put into an Authorization header; never logged.
    public var token: String?
    public var verify = false
    public var revisionLock = false
    public var connections = 4
    /// Files smaller than this use one connection.
    public var splitThreshold: Int64 = 64 << 20
    public var reserveBytes: Int64 = 5_000_000_000
    public var retries = 4
    public var backoffSeconds: Double = 1
    public var interactive = false
    public var freeSpace: @Sendable (URL) -> Int64 = { PullDisk.freeBytes(at: $0) }
    public var sessionConfiguration: @Sendable () -> URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return c
    }
    /// Permanent progress lines (stderr).
    public var log: @Sendable (String) -> Void = { _ in }
    /// Transient single-line status, only called when `interactive`.
    public var status: @Sendable (String) -> Void = { _ in }
    public init(dir: URL) { self.dir = dir }
}

public enum PullDisk {
    public static func freeBytes(at url: URL) -> Int64 {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        var s = statfs()
        guard statfs(u.path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }
}

struct PullReceipt: Codable { var repo: String; var revision: String; var files: [PullFile] }

public struct PullSummary: Sendable {
    public var downloadedBytes: Int64 = 0
    public var skippedFiles = 0
    public var downloadedFiles = 0
    public var seconds: Double = 0
}

final class PullMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var done: Int64
    private var fetched: Int64 = 0
    private let began = Date()
    private var lastPrint = Date.distantPast
    private let options: PullOptions
    var label = ""
    init(total: Int64, alreadyHave: Int64, options: PullOptions) { self.total = total; self.done = alreadyHave; self.options = options }
    var fetchedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return fetched }
    func add(_ n: Int64) {
        lock.lock()
        done += n; fetched += n
        let now = Date()
        let due = options.interactive && now.timeIntervalSince(lastPrint) >= 0.5
        if due { lastPrint = now }
        let (d, f, l) = (done, fetched, label)
        lock.unlock()
        guard due else { return }
        let el = max(now.timeIntervalSince(began), 0.001)
        let rate = Double(f) / el
        let eta = rate > 0 ? Double(total - d) / rate : .infinity
        let pct = total > 0 ? Int(Double(d) * 100 / Double(total)) : 100
        options.status(String(format: "%3d%%  %@ / %@  %.0f MB/s  eta %@  %@", pct, PullFormat.gb(d), PullFormat.gb(total), rate / 1e6, PullFormat.duration(eta), l))
    }
}

/// Resumable, hash-verified downloader for pinned Hugging Face revisions. See docs/INSTALL.md.
public final class Puller: Sendable {
    let options: PullOptions
    public init(_ options: PullOptions) { self.options = options }

    enum Action { case skip, download }

    func destination(_ repo: PullRepo, _ file: PullFile) -> URL {
        options.dir.appendingPathComponent(repo.name).appendingPathComponent(file.path)
    }
    func receiptURL(_ repo: PullRepo) -> URL { options.dir.appendingPathComponent(repo.name).appendingPathComponent(".strim-pull.json") }
    func loadReceipt(_ repo: PullRepo) -> PullReceipt? {
        guard let d = try? Data(contentsOf: receiptURL(repo)) else { return nil }
        return try? JSONDecoder().decode(PullReceipt.self, from: d)
    }
    func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes already on disk for a resumable download of `file` (0 when it would start over).
    func resumableBytes(_ repo: PullRepo, _ file: PullFile) -> Int64 {
        loadPartState(file, destination(repo, file))?.doneBytes ?? 0
    }

    func partURL(_ dest: URL) -> URL { URL(fileURLWithPath: dest.path + ".part") }
    func stateURL(_ dest: URL) -> URL { URL(fileURLWithPath: dest.path + ".part.state") }

    func loadPartState(_ file: PullFile, _ dest: URL) -> PullPartState? {
        guard let s = fileSize(partURL(dest)), s > 0, s <= file.size else { return nil }
        if let d = try? Data(contentsOf: stateURL(dest)), let st = try? JSONDecoder().decode(PullPartState.self, from: d),
           st.size == file.size, s == file.size { return st }
        if s == file.size { return PullPartState(size: file.size, segments: [PullSegment(start: 0, end: file.size - 1, done: file.size)]) }
        // A plain truncated .part (no sidecar): the first s bytes are a valid prefix.
        let parts = file.size >= options.splitThreshold ? options.connections : 1
        return PullPartState(size: file.size, segments: [PullSegment(start: 0, end: s - 1, done: s)]
                             + PullPartState.split(from: s, to: file.size, parts: parts))
    }

    // MARK: pull

    public func pull(_ repos: [PullRepo]) async throws -> PullSummary {
        let began = Date()
        let fm = FileManager.default
        var plans: [(PullRepo, [(PullFile, Action)])] = []
        var needed: Int64 = 0
        var have: Int64 = 0
        var total: Int64 = 0
        for repo in repos {
            let receipt = loadReceipt(repo)
            if let r = receipt, r.revision != repo.revision, options.revisionLock {
                throw PullError.lockConflict(repo: repo.repo, locked: r.revision, pinned: repo.revision)
            }
            let trusted = receipt?.revision == repo.revision && !options.verify
            var items: [(PullFile, Action)] = []
            for f in repo.files {
                total += f.size
                let dest = destination(repo, f)
                if fileSize(dest) == f.size {
                    var ok = true
                    if !trusted {
                        options.log("checking \(repo.name)/\(f.path)")
                        ok = (try? PullHash.matches(f, at: dest)) ?? false
                    }
                    if ok { items.append((f, .skip)); have += f.size; continue }
                }
                let r = resumableBytes(repo, f)
                needed += f.size - r; have += r
                items.append((f, .download))
            }
            plans.append((repo, items))
        }
        if needed > 0 {
            let free = options.freeSpace(options.dir)
            if free < needed + options.reserveBytes {
                throw PullError.insufficientDisk(need: needed, free: free, reserve: options.reserveBytes)
            }
        }
        var summary = PullSummary()
        let meter = PullMeter(total: total, alreadyHave: have, options: options)
        for (repo, items) in plans {
            try fm.createDirectory(at: options.dir.appendingPathComponent(repo.name), withIntermediateDirectories: true)
            for (i, (f, action)) in items.enumerated() {
                if action == .skip { summary.skippedFiles += 1; continue }
                meter.label = "\(repo.name)/\(f.path) (\(i + 1)/\(items.count))"
                let t0 = Date()
                try await downloadFile(repo, f, meter: meter, singleConnection: false)
                summary.downloadedFiles += 1
                options.log(String(format: "ok  %@/%@  %@  %.1fs", repo.name, f.path, PullFormat.gb(f.size), Date().timeIntervalSince(t0)))
            }
            let receipt = PullReceipt(repo: repo.repo, revision: repo.revision, files: repo.files)
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: receiptURL(repo), options: .atomic)
        }
        summary.downloadedBytes = meter.fetchedBytes
        summary.seconds = Date().timeIntervalSince(began)
        return summary
    }

    // MARK: one file

    func downloadFile(_ repo: PullRepo, _ file: PullFile, meter: PullMeter, singleConnection: Bool) async throws {
        let dest = destination(repo, file)
        let part = partURL(dest), stateFile = stateURL(dest)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var state: PullPartState
        if let s = loadPartState(file, dest) { state = s }
        else {
            try? fm.removeItem(at: part); try? fm.removeItem(at: stateFile)
            let parts = (file.size >= options.splitThreshold && !singleConnection) ? options.connections : 1
            state = PullPartState(size: file.size, segments: PullPartState.split(from: 0, to: file.size, parts: parts))
        }
        if file.size == 0 { fm.createFile(atPath: part.path, contents: nil); state = PullPartState(size: 0, segments: []) }

        let fd = open(part.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw PullError.network("cannot open \(part.path): errno \(errno)") }
        if ftruncate(fd, off_t(file.size)) != 0 { close(fd); throw PullError.network("cannot size \(part.path): errno \(errno)") }

        let tracker = PartTracker(state: state, stateURL: stateFile)
        let url = repo.url(for: file, endpoint: options.endpoint)
        var base = URLRequest(url: url)
        if let t = options.token, !t.isEmpty { base.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        base.setValue("strim-pull", forHTTPHeaderField: "User-Agent")

        let request = base
        let opts = options
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<state.segments.count where state.segments[i].remaining > 0 {
                    group.addTask {
                        try await Puller.runSegment(index: i, tracker: tracker, fd: fd, base: request, file: file, total: file.size,
                                                    options: opts, meter: meter)
                    }
                }
                try await group.waitForAll()
            }
        } catch PullError.rangeIgnored where !singleConnection {
            tracker.persist(force: true); close(fd)
            try? fm.removeItem(at: part); try? fm.removeItem(at: stateFile)
            return try await downloadFile(repo, file, meter: meter, singleConnection: true)
        } catch {
            tracker.persist(force: true); close(fd)
            throw error
        }
        tracker.persist(force: true)
        fsync(fd); close(fd)

        let got = fileSize(part) ?? -1
        guard got == file.size else { throw PullError.sizeMismatch(file.path, expected: file.size, got: got) }
        guard try PullHash.matches(file, at: part) else {
            try? fm.removeItem(at: part); try? fm.removeItem(at: stateFile)
            throw PullError.hashMismatch(file.path)
        }
        guard rename(part.path, dest.path) == 0 else { throw PullError.network("rename failed for \(file.path): errno \(errno)") }
        try? fm.removeItem(at: stateFile)
    }

    static func runSegment(index: Int, tracker: PartTracker, fd: Int32, base: URLRequest, file: PullFile, total: Int64,
                           options: PullOptions, meter: PullMeter) async throws {
        var attempt = 0
        while true {
            let seg = tracker.segment(index)
            if seg.remaining <= 0 { return }
            let from = seg.start + seg.done
            var req = base
            req.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")
            let job = SegmentJob(request: req, fd: fd, startOffset: from, expected: seg.end - from + 1, path: file.path,
                                 allowFullBody: seg.start == 0 && seg.done == 0 && seg.end == total - 1) { n in
                tracker.add(index, n); meter.add(n)
            }
            do {
                try await job.run(configuration: options.sessionConfiguration())
                return
            } catch let e as PullError {
                let retryable: Bool
                switch e {
                case .network: retryable = true
                case let .http(c, _): retryable = c >= 500 || c == 408 || c == 429
                default: retryable = false
                }
                attempt += 1
                if !retryable || attempt > options.retries { throw e }
                try await Task.sleep(nanoseconds: UInt64(options.backoffSeconds * pow(2, Double(attempt - 1)) * 1e9))
            }
        }
    }
}

/// Per-segment progress, persisted (throttled) next to the .part file so an interrupted run resumes.
final class PartTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PullPartState
    private let stateURL: URL
    private var last = Date.distantPast
    init(state: PullPartState, stateURL: URL) { self.state = state; self.stateURL = stateURL }
    func segment(_ i: Int) -> PullSegment { lock.lock(); defer { lock.unlock() }; return state.segments[i] }
    func add(_ i: Int, _ n: Int64) {
        lock.lock(); state.segments[i].done += n; lock.unlock()
        persist(force: false)
    }
    func persist(force: Bool) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 1 else { lock.unlock(); return }
        last = now
        let data = try? JSONEncoder().encode(state)
        lock.unlock()
        if let data { try? data.write(to: stateURL, options: .atomic) }
    }
}
