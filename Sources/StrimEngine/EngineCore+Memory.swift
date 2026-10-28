import Foundation
import MLX

extension EngineCore {
    /// Holds the process `phys_footprint` (weights + trie + live state + MLX buffer cache + Metal
    /// overhead) under `cfg.memoryBudgetBytes`. Admission works from estimates; this is the backstop
    /// against what they miss. Cheapest first: release the MLX buffer cache, then trim the prefix
    /// trie (GDN states of interior nodes, then LRU leaves), then demote hot sessions. Live requests
    /// are never touched. After a trim it waits 8 units so a footprint pinned by live work does not
    /// flush the buffer cache on every pass.
    func relieveMemoryPressure() {
        let limit = cfg.memoryBudgetBytes
        var foot = ProcessFootprint.bytes()
        footprintBytes = foot
        guard foot > limit, unitsRun - lastPressureUnit >= 8 else { return }
        lastPressureUnit = unitsRun
        let before = foot
        Memory.clearCache()
        foot = ProcessFootprint.bytes()
        if foot > limit, let prefix, prefix.totalBytes > 0 {
            prefix.shrink(to: prefix.totalBytes - (foot - limit) - limit / 50)
            Memory.clearCache()
            foot = ProcessFootprint.bytes()
        }
        while foot > limit, let old = hotLRU.first, let s = sessions[old] {
            dropHot(s)
            Memory.clearCache()
            foot = ProcessFootprint.bytes()
        }
        pressureTrims += 1
        footprintBytes = foot
        FileHandle.standardError.write(Data(("[mem] pressure: footprint \(before >> 20) -> \(foot >> 20) MiB (limit \(limit >> 20)), "
            + "trie \((prefix?.totalBytes ?? 0) >> 20) MiB/\(prefix?.nodeCount ?? 0) nodes, hot \(hotLRU.count)\n").utf8))
    }
}
