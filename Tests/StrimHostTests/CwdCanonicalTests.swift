import Foundation
import Testing
@testable import StrimHost

/// Allowed-root check canonicalises both sides: aliases of an allowed root pass, real escapes do not.
@Suite(.serialized) struct CwdCanonicalTests {
    private func mk() throws -> (base: String, real: String, outside: String) {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "cwdcanon-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base + "/root/proj", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        let canon = HostPolicy.canonical(base)
        return (base, canon + "/root", canon + "/outside")
    }

    @Test func symlinkedSpellingOfRootPasses() throws {
        let (base, real, _) = try mk(); defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createSymbolicLink(atPath: base + "/alias", withDestinationPath: real)
        let p = HostPolicy(maxAccess: .write, allowedRoots: [base + "/alias"])  // root given as the symlink
        #expect(p.violation(access: "write", cwd: real + "/proj", home: "/nonexistent") == nil)
        let p2 = HostPolicy(maxAccess: .write, allowedRoots: [real])  // cwd given as the symlink
        #expect(p2.violation(access: "write", cwd: base + "/alias/proj", home: "/nonexistent") == nil)
    }

    @Test func varSpellingMatchesPrivateVar() throws {
        let (base, _, _) = try mk(); defer { try? FileManager.default.removeItem(atPath: base) }
        // NSTemporaryDirectory() is /var/folders/... on macOS; the canonical form is /private/var/...
        let p = HostPolicy(maxAccess: .write, allowedRoots: [HostPolicy.canonical(base) + "/root"])
        #expect(p.violation(access: "write", cwd: base + "/root/proj", home: "/nonexistent") == nil)
        let q = HostPolicy(maxAccess: .write, allowedRoots: [base + "/root"])
        #expect(q.violation(access: "write", cwd: HostPolicy.canonical(base) + "/root/proj", home: "/nonexistent") == nil)
    }

    @Test func realEscapesAreRejected() throws {
        let (base, real, outside) = try mk(); defer { try? FileManager.default.removeItem(atPath: base) }
        let p = HostPolicy(maxAccess: .write, allowedRoots: [real])
        // dot-dot
        #expect(p.violation(access: "write", cwd: real + "/proj/../../outside", home: "/nonexistent") != nil)
        // symlink inside the root pointing outside
        try FileManager.default.createSymbolicLink(atPath: real + "/proj/escape", withDestinationPath: outside)
        let why = p.violation(access: "write", cwd: real + "/proj/escape", home: "/nonexistent")
        #expect(why?.contains("outside the allowed roots") == true)
        #expect(why?.contains("canonical path: \(outside)") == true)
        // sibling sharing a name prefix
        try FileManager.default.createDirectory(atPath: real + "-evil", withIntermediateDirectories: true)
        #expect(p.violation(access: "write", cwd: real + "-evil", home: "/nonexistent") != nil)
    }
}
