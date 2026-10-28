import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@Suite struct FormattingTests {
    @Test func numbers() {
        #expect(StatsFormat.tps(42.34) == "42.3 tok/s")
        #expect(StatsFormat.tps(0) == "–")
        #expect(StatsFormat.percent(0.4249) == "42%")
        #expect(StatsFormat.percent(1.7) == "100%")
        #expect(StatsFormat.gb(15.24) == "15.2 GB")
        #expect(StatsFormat.tokens(999) == "999")
        #expect(StatsFormat.tokens(12_345) == "12.3k")
        #expect(StatsFormat.tokens(2_500_000) == "2.50M")
        #expect(StatsFormat.seconds(12.34) == "12.3 s")
        #expect(StatsFormat.seconds(125) == "2m 5s")
    }
    @Test func durations() {
        #expect(StatsFormat.duration(5) == "5s")
        #expect(StatsFormat.duration(3725) == "1h 02m")
        #expect(StatsFormat.duration(90_000) == "1d 1h")
    }
    @Test func menuTitlesCoverEveryState() {
        let m = MemoryStats(weightsGB: 1, prefixTrieGB: 1, mlxCacheGB: 1, headroomGB: 1)
        func t(_ s: HostState, p: Double? = nil) -> String { StatsFormat.menuTitle(.connected(HostStatus(state: s, loadProgress: p, memory: m))) }
        #expect(t(.stopped) == "Strim: stopped")
        #expect(t(.loading, p: 0.42) == "Strim: loading 42%")
        #expect(t(.loading) == "Strim: loading 0%")
        #expect(t(.ready) == "Strim: ready")
        #expect(t(.busy) == "Strim: busy")
        #expect(t(.error) == "Strim: error")
        #expect(StatsFormat.menuTitle(.disconnected(reason: "x")) == "Strim: offline")
        #expect(StatsFormat.menuTitle(.connecting) == "Strim: connecting")
        for s in HostState.allCases { #expect(!StatsFormat.menuSymbol(.connected(HostStatus(state: s, memory: m))).isEmpty) }
    }
    @Test func memorySegmentsSumToOne() {
        let segs = StatsFormat.memorySegments(MemoryStats(weightsGB: 15, prefixTrieGB: 3, mlxCacheGB: 2, headroomGB: 20))
        #expect(segs.map(\.label) == ["Weights", "Prefix trie", "MLX cache", "Headroom"])
        #expect(abs(segs.reduce(0) { $0 + $1.fraction } - 1) < 1e-9)
        #expect(segs[0].fraction == 0.375)
        let zero = StatsFormat.memorySegments(MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 0))
        #expect(zero.allSatisfy { $0.fraction == 0 })
    }
    @Test func relativeTime() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(StatsFormat.relative(nil, now: now) == "never")
        #expect(StatsFormat.relative(now, now: now) == "just now")
        #expect(StatsFormat.relative(now.addingTimeInterval(-30), now: now) == "30s ago")
        #expect(StatsFormat.relative(now.addingTimeInterval(-300), now: now) == "5m ago")
    }
    @Test func offlineBannerTexts() {
        let u = "http://127.0.0.1:8203"
        #expect(OfflineBanner.text(for: ControlClientError.hostUnreachable("refused"), hostURL: u) == "Strim host is not running at \(u): refused.")
        #expect(OfflineBanner.text(for: ControlClientError.timeout, hostURL: u).contains("timeout"))
        #expect(OfflineBanner.text(for: ControlClientError.unauthorized(tokenPresent: true), hostURL: u).contains("rejected the control token"))
        #expect(OfflineBanner.text(for: ControlClientError.unauthorized(tokenPresent: false), hostURL: u).contains("Start the host once so it creates ~/.strim/control-token"))
        #expect(OfflineBanner.text(for: URLError(.networkConnectionLost), hostURL: u).hasPrefix("Lost connection to \(u)"))
    }
}
