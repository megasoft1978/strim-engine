import Foundation

/// Pure work-unit policy (no MLX, unit-testable). The engine loop asks for one unit at a time.
///
/// Policy
/// - Interactive beats background: while any interactive request exists, only interactive
///   requests are eligible. Background requests are paused at their current unit boundary:
///   a background decode keeps its cache, a background prefill keeps its finished chunks.
/// - Within the eligible class: a prefill chunk (<= 1024 tokens) and a decode pass alternate
///   when both are pending, so no decode waits more than one chunk. Prefills run FIFO.
///   `STRIM_PREFILL_BURST` / `STRIM_PREFILL_GAP_MS` (see `PrefillBurst`) allow a bounded run of prefill
///   chunks before the decode pass to cut the decode units that sit inside prefill-bound TTFT.
/// - Decode: one eligible request not in the batch -> solo decode (MTP when greedy). Two or more
///   eligible decoders (or any eligible batch member) -> one batched pass over the whole
///   batch; solos join the batch and then stay on plain decode until they finish (a joined
///   sequence has no MTP head state to resume, so leaving would not be exact).
///
/// Decode policy (`STRIM_DECODE_POLICY`, default `auto`)
/// - batch: as above.
/// - roundrobin: never batch; every decoder keeps its own SpecStream and decode units alternate
///   fairly (least recently served first). Bitwise identical to each sequence's single-stream run.
/// - auto: while no batch exists, >= 2 decoders compare the estimated aggregate tok/s of
///   time-sliced MTP (sum tokens-per-unit / sum ms-per-unit, rolling per sequence) with the
///   measured plain-batch table, with hysteresis (enter round-robin at +5%, leave at -10%, and
///   only after every sequence has >= 3 measured units). Leaving to the batch is one-way: a
///   joined sequence has no MTP head state to resume. Once a batch exists, arrivals join it.
enum DecodePolicy: String { case batch, roundrobin, auto
    static func current() -> DecodePolicy {
        guard let v = getenv("STRIM_DECODE_POLICY") else { return .auto }
        return DecodePolicy(rawValue: String(cString: v)) ?? .batch
    }
}

/// Prefill burst bound (`STRIM_PREFILL_BURST`=N, `STRIM_PREFILL_GAP_MS`=ms). Default: gap cap 3000 ms, no unit cap.
/// `STRIM_PREFILL_GAP_MS=0` or `off` restores the legacy one prefill unit / one decode unit alternation.
/// - units: max consecutive prefill units while a decoder is pending.
/// - gapSeconds: cap on prefill wall time before a decode unit (inter-token gap). A decode is forced when the
///   time since the last decode plus the predicted next prefill unit reaches the cap.
/// A decode is forced by whichever bound is hit first. Prefill-only periods (no decoder) never count against it.
struct PrefillBurst: Equatable {
    var units: Int
    var gapSeconds: Double

    static let legacy = PrefillBurst(units: 1, gapSeconds: .infinity)

    /// Default gap cap (on). `STRIM_PREFILL_GAP_MS=0` or `off` opts out to the legacy path.
    static let defaultGapMs = 3000.0

    static func from(env: [String: String]) -> PrefillBurst {
        let n = env["STRIM_PREFILL_BURST"].flatMap { Int($0) }.map { max($0, 1) }
        let raw = env["STRIM_PREFILL_GAP_MS"]
        if raw == "off" { return .legacy }
        let ms = raw.flatMap { Double($0) } ?? defaultGapMs
        if ms <= 0 { return .legacy }
        return PrefillBurst(units: n ?? Int.max, gapSeconds: ms / 1000)
    }

    static func current() -> PrefillBurst { from(env: ProcessInfo.processInfo.environment) }
}

struct Scheduler {
    /// Measured plain batched decode, ms per step at S=1, 1K ctx (docs/BATCH-MTP-2026-10-26.md).
    static func batchStepMs(_ b: Int) -> Double {
        switch b { case ...1: return 34; case 2: return 42; case 3: return 49; case 4: return 56
        default: return 56 + 7 * Double(b - 4) }
    }
    static let priorTokensPerUnit = 2.5, priorUnitMs = 36.0, warmUnits = 3

    var policy: DecodePolicy = .batch
    /// Prefill burst bound; read from the environment when the scheduler is created.
    var burst = PrefillBurst.current()
    /// Monotonic seconds. pick() runs at every unit start, so the time between picks is the previous unit's wall time.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var rrMode = false
    private var tick = 0
    private var prefillRun = 0         // consecutive prefill units since the last decode unit
    private var gapSeconds = 0.0       // prefill wall time since the last decode unit (decoders pending)
    private var lastPickAt: Double? = nil
    private var decodersWaiting = false  // a decoder was pending when the last prefill unit was picked
    private var prefillEstimate = 0.0  // EWMA of prefill unit wall time (predicts the next unit before starting it)

    enum Phase: Equatable { case prefill, decode }

    struct Entry {
        let id: Int
        let priority: Priority
        var phase: Phase
        let arrival: Int
        var batched = false
        var tpu = Scheduler.priorTokensPerUnit
        var ms = Scheduler.priorUnitMs
        var units = 0
        var served = 0
    }

    enum Unit: Equatable {
        case prefill(Int)
        case decodeSolo(Int)
        /// Step the whole batch after adding `join` (ids that were solo).
        case decodeBatch(join: [Int])
    }

    private(set) var entries: [Int: Entry] = [:]
    private var counter = 0
    private var lastWasPrefill = false

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func add(id: Int, priority: Priority, phase: Phase = .prefill) {
        counter += 1
        entries[id] = Entry(id: id, priority: priority, phase: phase, arrival: counter)
    }

    mutating func setPhase(_ id: Int, _ phase: Phase) { entries[id]?.phase = phase }
    mutating func remove(_ id: Int) { entries[id] = nil }
    func isBatched(_ id: Int) -> Bool { entries[id]?.batched ?? false }
    var batchMembers: [Int] { entries.values.filter { $0.batched }.sorted { $0.arrival < $1.arrival }.map { $0.id } }

    /// Engine feedback after a solo decode unit: tokens decided and wall ms (rolling mean, alpha 0.25).
    mutating func record(_ id: Int, tokens: Int, ms: Double) {
        guard var e = entries[id] else { return }
        let a = e.units == 0 ? 1.0 : 0.25
        e.tpu += a * (Double(tokens) - e.tpu); e.ms += a * (ms - e.ms); e.units += 1
        entries[id] = e
    }

    /// Plain (non-MTP) sequences: one token per unit, single-stream plain step cost.
    mutating func setPrior(_ id: Int, tokensPerUnit: Double, ms: Double) {
        entries[id]?.tpu = tokensPerUnit; entries[id]?.ms = ms
    }

    private mutating func preferRoundRobin(_ solos: [Entry]) -> Bool {
        let rr = 1000 * solos.reduce(0) { $0 + $1.tpu } / solos.reduce(0) { $0 + $1.ms }
        let bt = 1000 * Double(solos.count) / Scheduler.batchStepMs(solos.count)
        if rrMode {
            if solos.contains(where: { $0.units < Scheduler.warmUnits }) { return true }
            return rr * 1.10 >= bt
        }
        return rr >= bt * 1.05
    }

    private mutating func serve(_ solos: [Entry]) -> Unit {
        tick += 1
        let e = solos.min { ($0.served, $0.arrival) < ($1.served, $1.arrival) }!
        entries[e.id]?.served = tick
        return .decodeSolo(e.id)
    }

    mutating func pick() -> Unit? {
        guard !entries.isEmpty else { return nil }
        let now = clock()
        // wall time of the prefill unit that just ended; charged to the gap only if a decoder was waiting during it
        if lastWasPrefill, let last = lastPickAt {
            let d = now - last
            prefillEstimate = prefillEstimate == 0 ? d : 0.3 * d + 0.7 * prefillEstimate
            if decodersWaiting { gapSeconds += d }
        }
        lastPickAt = now
        let cls: Priority = entries.values.contains { $0.priority == .interactive } ? .interactive : .background
        let elig = entries.values.filter { $0.priority == cls }.sorted { $0.arrival < $1.arrival }
        let prefills = elig.filter { $0.phase == .prefill }
        let decoders = elig.filter { $0.phase == .decode }
        if decoders.isEmpty { gapSeconds = 0 }
        // gap cap is checked against gap + predicted next unit, so the prefill run before a decode stays <= cap
        let capHit = burst.gapSeconds.isFinite && gapSeconds + prefillEstimate >= burst.gapSeconds
        let forceDecode = prefillRun >= burst.units || capHit
        if !decoders.isEmpty && (forceDecode || prefills.isEmpty) {
            prefillRun = 0; gapSeconds = 0; lastWasPrefill = false
            let inBatch = decoders.filter { $0.batched }
            let solos = decoders.filter { !$0.batched }
            if inBatch.isEmpty && solos.count == 1 { rrMode = false; return .decodeSolo(solos[0].id) }
            if inBatch.isEmpty && policy != .batch {
                if policy == .roundrobin { return serve(solos) }
                let rr = preferRoundRobin(solos)
                rrMode = rr
                if rr { return serve(solos) }
            }
            for s in solos { entries[s.id]?.batched = true }
            return .decodeBatch(join: solos.map { $0.id })
        }
        if let p = prefills.first {
            lastWasPrefill = true
            decodersWaiting = !decoders.isEmpty
            prefillRun += 1
            return .prefill(p.id)
        }
        return nil
    }
}
