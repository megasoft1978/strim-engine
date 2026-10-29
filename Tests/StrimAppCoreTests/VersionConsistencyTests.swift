import Foundation
import StrimAPI
import Testing

private final class VersionTestBundle: NSObject {}

@Suite struct VersionConsistencyTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func capture(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let match = try #require(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try #require(Range(match.range(at: 1), in: text))
        return String(text[range])
    }

    private func releaseVersion() throws -> String {
        try capture(#"\A# Strim ([0-9]+\.[0-9]+\.[0-9]+)\r?$"#, in: read("RELEASE_NOTES.md"))
    }

    /// The version released before this one: the first "## Also in X" section of RELEASE_NOTES.md.
    private func previousReleaseVersion() throws -> String {
        try capture(#"^## Also in ([0-9]+\.[0-9]+\.[0-9]+)\r?$"#, in: read("RELEASE_NOTES.md"))
    }

    private func cli() throws -> URL {
        var directory = Bundle(for: VersionTestBundle.self).bundleURL
        // swift test may run inside the test bundle's Contents/MacOS directory.
        for _ in 0..<6 {
            let binary = directory.appendingPathComponent("strim")
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            directory.deleteLastPathComponent()
        }
        Issue.record("No built strim executable beside the test bundle")
        throw CocoaError(.fileNoSuchFile)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strim-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(_ executable: URL, _ arguments: [String], directory: URL,
                     environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.path,
                               "TMPDIR": directory.path].merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        return text
    }

    @Test func releaseArtifactsAgree() throws {
        let expected = try releaseVersion()
        #expect(StrimVersion.current == expected)
        #expect(try read("VERSION") == expected + "\n")
        #expect(try capture(#"public static let current = "([^"]+)""#,
                            in: read("Sources/StrimAPI/Version.swift")) == expected)
        let formula = try read("packaging/homebrew/strim.rb")
        // The tap files carry release checksums, so they are updated right after a release is built: they must name
        // either this version or the one released just before it (the previous RELEASE_NOTES section), never another.
        let allowed = [expected, try previousReleaseVersion()]
        // Homebrew infers this formula's version from the URL; check the tag and filename.
        let tag = try capture(#"/releases/download/v([^/]+)/"#, in: formula)
        #expect(allowed.contains(tag), "formula tag \(tag) not in \(allowed)")
        #expect(try capture(#"/strim-([^/]+)-arm64-macos\.tar\.gz"#, in: formula) == tag)
        let cask = try capture(#"^  version "([^"]+)""#, in: read("packaging/homebrew/Casks/strim-app.rb"))
        #expect(cask == tag, "cask \(cask) and formula \(tag) disagree")
    }

    @Test func cliPrintsReleaseVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["--version", "version"] {
            #expect(try run(cli(), [command], directory: directory) == "strim \(releaseVersion())\n")
        }
    }

    @Test(arguments: ["scripts/make_app.sh", "packaging/app/make-app.sh"])
    func appPlistUsesVersionSource(script: String) throws {
        let source = try read(script)
        let assignment = try NSRegularExpression(pattern: #"^version=.*$"#, options: [.anchorsMatchLines])
        let match = assignment.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
        let versionLine = match.flatMap { Range($0.range, in: source).map { String(source[$0]) } } ?? ""
        let delimiter = try capture(#"<<('?PLIST'?)"#, in: source)
        let plist = try capture(#"(?s)<<(?:'PLIST'|PLIST)\n(.*?)\nPLIST"#, in: source)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Run only the real version assignment and plist heredoc, never build, sign or launch an app.
        let harness = "set -euo pipefail\n. \"$LAYOUT\"\n\(versionLine)\ncat <<\(delimiter)\n\(plist)\nPLIST\n"
        for expected in [try releaseVersion(), "9.8.7"] {
            try (expected + "\n").write(to: directory.appendingPathComponent("VERSION"),
                                       atomically: true, encoding: .utf8)
            let rendered = try run(URL(fileURLWithPath: "/bin/bash"), ["-c", harness], directory: directory,
                                   environment: ["ROOT": directory.path, "root": directory.path,
                                                 "build": try cli().deletingLastPathComponent().path,
                                                 "LAYOUT": root.appendingPathComponent("packaging/release/layout.sh").path])
            let info = try #require(PropertyListSerialization.propertyList(from: Data(rendered.utf8),
                                                                          format: nil) as? [String: Any])
            #expect(info["CFBundleShortVersionString"] as? String == expected, "\(script)")
            #expect(info["CFBundleVersion"] as? String == expected, "\(script)")
        }
    }
}
