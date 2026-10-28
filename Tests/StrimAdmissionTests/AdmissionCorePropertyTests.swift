import Testing
@testable import StrimAdmission

/// Deterministic xorshift so failures reproduce from the seed.
struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

@Suite struct AdmissionCorePropertyTests {
    private func invariants(_ c: AdmissionCore) {
        #expect(c.active.count <= c.limits.maxInflight)
        #expect(c.activeBackground <= c.limits.maxBackground)
        #expect(c.passedOver <= c.limits.starvationLimit)
        // Work conserving: a free slot never coexists with an admissible waiter.
        if c.active.count < c.limits.maxInflight {
            #expect(c.waitingInteractive.isEmpty)
            let heldParked = c.activeInteractive > 0 && c.passedOver < c.limits.starvationLimit
                && c.waitingBackground.first.map(c.parked.contains) == true
            #expect(c.waitingBackground.isEmpty || c.activeBackground >= c.limits.maxBackground || heldParked)
        }
    }

    @Test(arguments: [1, 2, 3, 7, 42, 1234, 99991, 31337])
    func randomOpsKeepInvariants(seed: UInt64) {
        var rng = Rng(s: seed &* 0x9E3779B97F4A7C15 | 1)
        for (inflight, bg, starve) in [(1, 1, 1), (2, 1, 3), (4, 2, 2), (3, 3, 8)] {
            var c = AdmissionCore(limits: AdmissionLimits(maxInflight: inflight, maxBackground: bg, starvationLimit: starve))
            var ids = 0
            var lastAdmitted: [AdmissionClass: Int] = [:]
            var classOf: [Int: AdmissionClass] = [:]
            func track(_ granted: [Int]) {
                for g in granted {
                    let cls = classOf[g]!
                    #expect(g > (lastAdmitted[cls] ?? 0), "FIFO within a class")   // per-class order
                    lastAdmitted[cls] = g
                }
            }
            for _ in 0..<600 {
                switch rng.below(3) {
                case 0, 1:
                    ids += 1
                    let cls: AdmissionClass = rng.below(3) == 0 ? .background : .interactive
                    classOf[ids] = cls
                    track(c.enqueue(ids, cls, parked: cls == .background && rng.below(2) == 0))
                default:
                    // Release/cancel anything: active, waiting or already gone.
                    if ids > 0 { track(c.release(1 + rng.below(ids))) }
                }
                invariants(c)
            }
        }
    }

    /// Interactive arrives continuously (one active, a new one queued before each release). Background is admitted
    /// within `starvationLimit` interactive admissions.
    @Test(arguments: [1, 2, 5, 8])
    func noStarvationUnderInteractiveStream(limit: Int) {
        var c = AdmissionCore(limits: AdmissionLimits(maxInflight: 2, maxBackground: 1, starvationLimit: limit))
        var id = 0
        func next() -> Int { id += 1; return id }
        var current = next()
        _ = c.enqueue(current, .interactive)
        let bg = next()
        _ = c.enqueue(bg, .background)
        var rounds = 0
        while c.state(of: bg) != .active(.background), rounds < 1000 {
            let nxt = next()
            _ = c.enqueue(nxt, .interactive)   // queued behind the active one(s)
            _ = c.release(current)
            current = nxt
            rounds += 1
        }
        #expect(c.state(of: bg) == .active(.background))
        #expect(rounds <= limit + 1, "background waited \(rounds) rounds with limit \(limit)")
    }

    @Test func interactiveOutranksBackgroundWhenBothWait() {
        var c = AdmissionCore(limits: AdmissionLimits(maxInflight: 1))
        _ = c.enqueue(1, .interactive)
        #expect(c.enqueue(2, .background).isEmpty)
        #expect(c.enqueue(3, .interactive).isEmpty)
        #expect(c.release(1) == [3])
        #expect(c.release(3) == [2])
    }

    @Test func backgroundCapIsClampedBelowInflight() {
        #expect(AdmissionLimits(maxInflight: 4, maxBackground: 9).maxBackground == 3)
        #expect(AdmissionLimits(maxInflight: 1, maxBackground: 0).maxBackground == 1)
        #expect(AdmissionLimits(maxInflight: 0).maxInflight == 1)
    }

    /// Cancel (release) at every state of one request: waiting, active, gone; all leave the core consistent.
    @Test func cancelAtEveryState() {
        var c = AdmissionCore(limits: AdmissionLimits(maxInflight: 1))
        _ = c.enqueue(1, .background)                 // active
        _ = c.enqueue(2, .interactive)                // waiting
        _ = c.enqueue(3, .background)                 // waiting
        #expect(c.state(of: 2) == .waiting)
        #expect(c.release(2).isEmpty)                 // cancel a waiter: nothing granted
        #expect(c.state(of: 2) == .gone)
        #expect(c.release(2).isEmpty)                 // double cancel is a no-op
        #expect(c.release(1) == [3])                  // cancel the active one: next waiter admitted
        #expect(c.release(3).isEmpty)
        #expect(c.active.isEmpty && c.waitingBackground.isEmpty && c.waitingInteractive.isEmpty)
    }

    /// A parked (turn-boundary) background waiter stays out while interactive is active, a fresh one does not;
    /// the starvation guard still frees a parked one after enough interactive admissions.
    @Test func parkedBackgroundWaitsOutActiveInteractive() {
        var c = AdmissionCore(limits: AdmissionLimits(maxInflight: 3, maxBackground: 1, starvationLimit: 2))
        _ = c.enqueue(1, .interactive)
        #expect(c.enqueue(2, .background, parked: true).isEmpty)       // free slot, but interactive is active
        #expect(c.enqueue(3, .interactive) == [3])                     // passed over once
        #expect(c.release(1).isEmpty)
        #expect(c.enqueue(4, .interactive) == [4, 2])                  // passed over twice: boost admits it
        #expect(c.state(of: 2) == .active(.background))
        var f = AdmissionCore(limits: AdmissionLimits(maxInflight: 3))
        _ = f.enqueue(1, .interactive)
        #expect(f.enqueue(2, .background) == [2])                      // fresh background coexists
    }

    @Test func interactivePresentReflectsActiveAndWaiting() {
        var c = AdmissionCore(limits: AdmissionLimits(maxInflight: 1))
        #expect(!c.interactivePresent)
        _ = c.enqueue(1, .background)
        _ = c.enqueue(2, .interactive)
        #expect(c.interactivePresent)                  // waiting
        _ = c.release(1)
        #expect(c.interactivePresent)                  // active
        _ = c.release(2)
        #expect(!c.interactivePresent)
    }
}
