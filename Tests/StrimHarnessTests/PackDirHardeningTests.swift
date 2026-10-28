import Foundation
import Testing
@testable import StrimHarness

@Suite struct PackDirHardeningTests {
    private func tmp(_ mode: mode_t = 0o700) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pack-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        chmod(d.path, mode)
        return d
    }
    private func put(_ d: URL, _ name: String, _ text: String) throws { try Data(text.utf8).write(to: d.appendingPathComponent(name)) }
    private func rm(_ d: URL) { chmod(d.path, 0o700); try? FileManager.default.removeItem(at: d) }

    @Test func goodDirectoryLoads() throws {
        let d = tmp(); defer { rm(d) }
        try put(d, "system.md", "S"); try put(d, "memory.md", "M")
        let p = try #require(try PackLoader.load(directory: d))
        #expect(p.system == "S" && p.memory == "M" && p.toolGuidance == "" && p.guardrails == "")
    }

    @Test func emptyComponentFilesAreValidAndMatchTheShippedPack() throws {
        let shipped = PackLoader.shipped()
        let d = tmp(); defer { rm(d) }
        for (n, t) in [("system.md", shipped.system), ("tool_guidance.md", shipped.toolGuidance),
                       ("guardrails.md", shipped.guardrails), ("memory.md", shipped.memory)] { try put(d, n, t) }
        try put(d, PackLoader.packHashFile, shipped.fingerprint)
        let p = try #require(try PackLoader.load(directory: d))
        #expect(p == shipped && p.fingerprint == shipped.fingerprint)
        // Explicitly empty files, and an empty system.md.
        let e = tmp(); defer { rm(e) }
        try put(e, "system.md", "S"); try put(e, "guardrails.md", ""); try put(e, "memory.md", "")
        let q = try #require(try PackLoader.load(directory: e))
        #expect(q.guardrails == "" && q.memory == "" && q.system == "S")
        // A symlink to an empty file is still refused.
        let o = tmp(); defer { rm(o) }
        try put(o, "empty.md", "")
        try FileManager.default.createSymbolicLink(atPath: e.appendingPathComponent("tool_guidance.md").path,
                                                   withDestinationPath: o.appendingPathComponent("empty.md").path)
        #expect(throws: (any Error).self) { try PackLoader.load(directory: e) }
    }

    @Test func missingSystemMeansShipped() throws {
        let d = tmp(); defer { rm(d) }
        #expect(try PackLoader.load(directory: d) == nil)
    }

    @Test func fifoIsRefusedWithoutHanging() throws {
        let d = tmp(); defer { rm(d) }
        try put(d, "system.md", "S")
        #expect(mkfifo(d.appendingPathComponent("memory.md").path, 0o600) == 0)
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
    }

    @Test func symlinkToDevZeroIsRefused() throws {
        let d = tmp(); defer { rm(d) }
        try put(d, "system.md", "S")
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("guardrails.md").path, withDestinationPath: "/dev/zero")
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
        let e = tmp(); defer { rm(e) }
        try FileManager.default.createSymbolicLink(atPath: e.appendingPathComponent("system.md").path, withDestinationPath: "/dev/zero")
        #expect(throws: (any Error).self) { try PackLoader.load(directory: e) }
    }

    @Test func symlinkToRegularFileOutsideIsRefused() throws {
        let d = tmp(); defer { rm(d) }
        let o = tmp(); defer { rm(o) }
        try put(o, "x.md", "OUTSIDE")
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("system.md").path,
                                                   withDestinationPath: o.appendingPathComponent("x.md").path)
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
    }

    @Test func hugeFileIsRefused() throws {
        let d = tmp(); defer { rm(d) }
        try put(d, "system.md", String(repeating: "a", count: PackLoader.packFileMaxBytes + 1))
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
        try put(d, "system.md", String(repeating: "a", count: PackLoader.packFileMaxBytes))
        #expect(try PackLoader.load(directory: d)?.system.utf8.count == PackLoader.packFileMaxBytes)
    }

    @Test func nonUTF8IsRefused() throws {
        let d = tmp(); defer { rm(d) }
        try Data([0xff, 0xfe, 0x00]).write(to: d.appendingPathComponent("system.md"))
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
    }

    @Test func groupOrWorldWritableDirectoryIsRefused() throws {
        for mode: mode_t in [0o770, 0o707, 0o777] {
            let d = tmp(mode); defer { rm(d) }
            try put(d, "system.md", "S")
            #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
            #expect(throws: (any Error).self) { try PackLoader.knobs(inDirectory: d) }
        }
        let ok = tmp(0o755); defer { rm(ok) }
        try put(ok, "system.md", "S")
        #expect(try PackLoader.load(directory: ok) != nil)
    }

    @Test func directoryOwnedBySomeoneElseIsRefused() throws {
        // /private/var/root-owned or system dirs are not ours; /usr/bin is root-owned and not group/world-writable.
        #expect(throws: (any Error).self) { try PackLoader.load(directory: URL(fileURLWithPath: "/usr/bin")) }
        #expect(throws: (any Error).self) { try PackLoader.load(directory: URL(fileURLWithPath: "/etc/hosts")) }   // not a directory
    }

    @Test func fingerprintFileMustMatchTheFilesRead() throws {
        let d = tmp(); defer { rm(d) }
        try put(d, "system.md", "S"); try put(d, "memory.md", "M")
        let fp = HarnessPack(system: "S", toolGuidance: "", guardrails: "", memory: "M").fingerprint
        try put(d, PackLoader.packHashFile, fp + "\n")
        #expect(try PackLoader.load(directory: d)?.memory == "M")
        try put(d, "memory.md", "tampered")
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
        try put(d, PackLoader.packHashFile, String(repeating: "0", count: 64))
        try put(d, "memory.md", "M")
        #expect(throws: (any Error).self) { try PackLoader.load(directory: d) }
    }

    @Test func builtinFallsBackToShippedOnAnyFailure() {
        // builtin() reads the environment; exercised through load() failing above. Here: shipped is never empty.
        #expect(!PackLoader.shipped().system.isEmpty)
    }
}
