import Foundation
import Testing
@testable import StrimSite

@Suite struct SiteSafeIOTests {
    static func tmp() throws -> String {
        let d = ((NSTemporaryDirectory() + "strim-safeio-" + UUID().uuidString) as NSString).resolvingSymlinksInPath
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    @Test func normalPathReadsAndWrites() throws {
        let root = try Self.tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/site/data", withIntermediateDirectories: true)
        try SafeIO.write(root: root, path: root + "/site/data/r.json", "{}")
        #expect(SafeIO.readRegular(root: root, path: root + "/site/data/r.json") == "{}")
    }

    @Test func symlinkedParentDirectoryIsRefusedOnReadAndWrite() throws {
        let root = try Self.tmp(), elsewhere = try Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: elsewhere) }
        try "secret".write(toFile: elsewhere + "/r.json", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/site", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/site/data", withDestinationPath: elsewhere)
        #expect(SafeIO.readRegular(root: root, path: root + "/site/data/r.json") == nil)
        #expect(throws: SiteError.self) { try SafeIO.write(root: root, path: root + "/site/data/r.json", "pwn") }
        #expect(readString(elsewhere + "/r.json") == "secret")
    }

    @Test func symlinkedFileIsRefused() throws {
        let root = try Self.tmp(), elsewhere = try Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: elsewhere) }
        try "secret".write(toFile: elsewhere + "/f", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/f", withDestinationPath: elsewhere + "/f")
        #expect(SafeIO.readRegular(root: root, path: root + "/f") == nil)
    }

    @Test func symlinkedRootIsResolvedOnce() throws {
        let real = try Self.tmp(), link = NSTemporaryDirectory() + "strim-safeio-link-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: real); try? FileManager.default.removeItem(atPath: link) }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let want = realpath(real, nil).map { String(cString: $0) }
        #expect(SiteBuilder(root: link).root == want)
    }
}
