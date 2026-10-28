import Foundation
import Testing
@testable import StrimAppCore

private func a(_ s: String) -> PatchAnalysis { DiffParser.analyze(s) }
private func reasons(_ p: PatchAnalysis) -> String { p.issues.map(\.reason).joined(separator: " | ") }

private let plain = "diff --git a/x.txt b/x.txt\nindex 111..222 100644\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"

@Suite struct PatchSafetyTests {
    @Test func plainPatchIsClean() {
        let p = a(plain)
        #expect(!p.suspicious && !p.blocked && !p.needsConfirmation)
        #expect(p.confirmationText == nil)
        #expect(p.files.count == 1 && p.files[0].kinds == [.modified])
        #expect(p.totalAdded == 1 && p.totalRemoved == 1)
        #expect(p.byteSize == plain.utf8.count)
    }

    @Test func everyHeaderLineIsKeptAsARow() {
        let p = a(plain)
        let rows = p.files[0].headerRows.map(\.text)
        #expect(rows == ["index 111..222 100644", "--- a/x.txt", "+++ b/x.txt"])
        #expect(p.files[0].headerRows.map(\.tag) == ["index", "old file", "new file path"])
    }

    @Test func symlinkToAbsolutePathIsFlagged() {
        let p = a("diff --git a/link b/link\nnew file mode 120000\nindex 0000000..abc 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/etc/passwd\n\\ No newline at end of file\n")
        let f = p.files[0]
        #expect(f.isSymlink && f.symlinkTarget == "/etc/passwd" && f.kinds.contains(.symlink) && f.kinds.contains(.added))
        #expect(p.issues.contains { $0.reason.contains("symlink target") && !$0.blocking })
        #expect(p.suspicious && !p.blocked && p.needsConfirmation)
        #expect(p.confirmationText?.contains("adds a symlink") == true)
    }

    @Test func relativeSymlinkNeedsConfirmationButIsNotSuspicious() {
        let p = a("diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+target.txt\n\\ No newline at end of file\n")
        #expect(!p.suspicious && p.needsConfirmation)
        #expect(p.confirmationText == "This patch adds a symlink")
    }

    @Test func symlinkWithDotDotTargetIsSuspicious() {
        let p = a("diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+../../secret\n")
        #expect(p.suspicious)
    }

    @Test func modeChangeTo755() {
        let p = a("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        let f = p.files[0]
        #expect(f.oldMode == "100644" && f.newMode == "100755" && f.kinds == [.modeChange])
        #expect(f.headerRows.map(\.tag) == ["old mode", "new mode"])
        #expect(p.needsConfirmation && !p.blocked)
        #expect(p.confirmationText == "This patch makes a file executable")
    }

    @Test func symlinkPlusExecutableNamedTogether() {
        let p = a("diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+t\n"
                  + "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        #expect(p.confirmationText == "This patch adds a symlink and makes a file executable")
    }

    @Test func newExecutableFile() {
        let p = a("diff --git a/b.sh b/b.sh\nnew file mode 100755\n--- /dev/null\n+++ b/b.sh\n@@ -0,0 +1 @@\n+echo\n")
        #expect(p.confirmationText == "This patch adds an executable file")
    }

    @Test func renameIntoGithubWorkflows() {
        let p = a("diff --git a/build.sh b/.github/workflows/ci.yml\nsimilarity index 90%\nrename from build.sh\nrename to .github/workflows/ci.yml\n")
        let f = p.files[0]
        #expect(f.kinds == [.renamed] && f.renameFrom == "build.sh" && f.renameTo == ".github/workflows/ci.yml")
        #expect(f.headerRows.map(\.tag) == ["similarity", "rename from", "rename to"])
        #expect(p.needsConfirmation)
        let t = p.confirmationText ?? ""
        #expect(t.contains("renames a file") && t.contains(".github"))
    }

    @Test func copySection() {
        let p = a("diff --git a/a b/b\nsimilarity index 100%\ncopy from a\ncopy to b\n")
        #expect(p.files[0].kinds == [.copied] && p.confirmationText == "This patch copies a file")
    }

    @Test func gitBinaryPatch() {
        let p = a("diff --git a/i.png b/i.png\nnew file mode 100644\nindex 000..111\nGIT binary patch\nliteral 5\nE0000000000\n\nliteral 0\nHcmV?d00001\n\n")
        let f = p.files[0]
        #expect(f.isBinary && f.kinds.contains(.binary) && f.binaryLineCount == 2)
        #expect(f.headerRows.map(\.tag) == ["new file mode", "index", "binary", "binary hunk", "binary hunk"])
        #expect(!p.blocked && p.needsConfirmation)
        #expect(p.confirmationText?.contains("binary data") == true)
    }

    @Test func binaryFilesDiffer() {
        let p = a("diff --git a/i.png b/i.png\nindex 111..222 100644\nBinary files a/i.png and b/i.png differ\n")
        #expect(p.files[0].isBinary && p.needsConfirmation)
        #expect(p.files[0].headerRows.last?.tag == "binary")
    }

    @Test func deletedFileAndSubmodule() {
        let d = a("diff --git a/x b/x\ndeleted file mode 100644\n--- a/x\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n")
        #expect(d.files[0].kinds == [.deleted] && !d.needsConfirmation)
        let s = a("diff --git a/sub b/sub\nnew file mode 160000\nindex 000..abc\n--- /dev/null\n+++ b/sub\n@@ -0,0 +1 @@\n+Subproject commit abc\n")
        #expect(s.confirmationText?.contains("submodule") == true)
    }

    @Test func mismatchedHunkCountsBlock() {
        let tooFew = a("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n-b\n+c\n")
        #expect(tooFew.blocked && reasons(tooFew).contains("hunk"))
        let tooMany = a("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-b\n+c\n+extra\n")
        #expect(tooMany.blocked)
        #expect(tooMany.files[0].hunks[0].lines.count == 2)   // the extra line is kept as a stray row
        #expect(tooMany.files[0].strayLines == ["+extra"])
    }

    @Test func strayLinesBetweenHunksAreKeptAndBlock() {
        let p = a("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\nrm -rf /\n@@ -9 +9 @@\n-c\n+d\n")
        #expect(p.blocked && p.files[0].strayLines == ["rm -rf /"])
        #expect(p.files[0].hunks.count == 2)
    }

    @Test func unknownHeaderLineBlocksAndIsKept() {
        let p = a("diff --git a/x b/x\nsetuid root\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(p.blocked && p.files[0].headerRows.contains { $0.text == "setuid root" && $0.tag == "unknown" })
    }

    @Test func contentBeforeFirstHeaderBlocks() {
        let p = a("# innocent preamble\n" + plain)
        #expect(p.blocked && reasons(p).contains("before the first diff header"))
        #expect(p.preamble == ["# innocent preamble"])
    }

    @Test func malformedHunkHeaderBlocks() {
        let p = a("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ nonsense @@\n-a\n")
        #expect(p.blocked)
    }

    @Test func nonUTF8AndNulBlock() {
        var d = Data(plain.utf8); d.append(contentsOf: [0xFF, 0xFE, 0x0A])
        #expect(DiffParser.analyze(data: d).blocked)
        #expect(a(plain + " \u{0}\n").blocked)
        #expect(a("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\u{FFFD}\n").blocked)
    }

    @Test func oddPathsAreSuspicious() {
        func path(_ p: String) -> PatchAnalysis {
            a("diff --git a/\(p) b/\(p)\nnew file mode 100644\n--- /dev/null\n+++ b/\(p)\n@@ -0,0 +1 @@\n+x\n")
        }
        for bad in ["../../etc/passwd", "a/../b", "/abs/path", ".git/hooks/pre-commit", "sub/.git/config", "we\"ird", "tab\tname", "ctl\u{1}x"] {
            let p = path(bad)
            #expect(p.suspicious, "\(bad) should be suspicious")
            #expect(p.confirmationText != nil || p.blocked)
        }
        #expect(!path("src/ok-file_1.swift").suspicious)
        #expect(!path("dir/.gitignore").suspicious)
    }

    @Test func quotedGitPathIsSuspicious() {
        let p = a("diff --git \"a/caf\\303\\251\" \"b/caf\\303\\251\"\nnew file mode 100644\n--- /dev/null\n+++ \"b/caf\\303\\251\"\n@@ -0,0 +1 @@\n+x\n")
        #expect(p.suspicious)
    }

    @Test func differingPathsWithoutRenameAreSuspicious() {
        let p = a("diff --git a/one b/two\n--- a/one\n+++ b/two\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(p.suspicious)
    }

    @Test func emptyPatchBlocks() {
        #expect(a("").blocked)
        #expect(a("\n\n").blocked)
    }

    @Test func crlfPatchParses() {
        let p = a(plain.replacingOccurrences(of: "\n", with: "\r\n"))
        // trailing CR in header paths is a control character
        #expect(p.suspicious)
    }

    @Test func hugePatchIsFast() {
        var s = "diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -1,100000 +1,100000 @@\n"
        for i in 0..<100_000 { s += i % 2 == 0 ? "-line \(i)\n" : " ctx \(i)\n" }
        // fix counts: removed 50k + ctx 50k old = 100k; new = ctx 50k -> adjust header
        s = s.replacingOccurrences(of: "+1,100000", with: "+1,50000")
        let t0 = Date()
        let p = a(s)
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(!p.blocked && p.totalRemoved == 50_000 && p.files[0].hunks[0].lines.count == 100_000)
        #expect(p.byteSize == s.utf8.count)
    }

    @Test func summaryUsesParsedData() {
        let p = a(plain)
        #expect(p.summary.contains("1 file") && p.summary.contains("+1") && p.summary.contains("-1") && p.summary.contains("B"))
    }

    // MARK: binary hunks parsed as git does

    private let binHead = "diff --git a/i.bin b/i.bin\nnew file mode 100644\nindex 000..111\nGIT binary patch\n"

    @Test func binaryForwardAndReverseThenNextFile() {
        let p = a(binHead + "literal 5\nE0000000000\n\nliteral 0\nHcmV?d00001\n\n" + plain)
        #expect(!p.blocked)
        #expect(p.files.count == 2 && p.files[1].path == "x.txt" && p.files[1].hunks.count == 1)
    }
    @Test func binaryDeltaHunk() {
        #expect(!a(binHead + "delta 5\nE0000000000\n\n").blocked)
    }
    @Test func hiddenFileInsideBinaryModeIsBlocked() {
        // an attacker hides a second file's header and a text hunk as "binary payload"
        let p = a(binHead + "literal 5\nE0000000000\ndiff --git a/.github/ci.yml b/.github/ci.yml\n--- a/.github/ci.yml\n+++ b/.github/ci.yml\n@@ -1 +1 @@\n-a\n+b\n\n")
        #expect(p.blocked)
        #expect(p.files.contains { $0.path == ".github/ci.yml" })   // and it is visible, not swallowed
    }
    @Test func headerLinesInsideBinaryDataAreStray() {
        for bad in ["--- a/x", "+++ b/x", "@@ -1 +1 @@", "diff --git a/y b/y"] {
            let p = a(binHead + "literal 5\nE0000000000\n\(bad)\n\n")
            #expect(p.blocked, "\(bad) inside binary data must block")
        }
    }
    @Test func binaryDataValidation() {
        #expect(a(binHead + "literal 5\nE000000000\n\n").blocked)          // too short for its length char
        #expect(a(binHead + "literal 5\nE00000000000\n\n").blocked)         // too long
        #expect(a(binHead + "literal 5\nE000 00000 0\n\n").blocked)         // space is not base85
        #expect(a(binHead + "literal 5\n!0000000000\n\n").blocked)          // bad length char
        #expect(a(binHead + "literal 5\n\n").blocked)                        // empty hunk
        #expect(a(binHead + "literal 5\nE0000000000\n").blocked)             // no blank terminator
        #expect(a(binHead).blocked)                                           // no data at all
        #expect(a(binHead + "nonsense\n").blocked)                           // not literal/delta
    }
    @Test func lengthCharsCoverBothRanges() {
        let line52 = "z" + String(repeating: "0", count: 65)     // 52 bytes -> 13 groups -> 65 chars
        let line26 = "Z" + String(repeating: "0", count: 35)     // 26 bytes -> 7 groups -> 35 chars
        let line27 = "a" + String(repeating: "0", count: 35)     // 27 bytes -> 7 groups -> 35 chars
        #expect(!a(binHead + "literal 105\n\(line52)\n\(line26)\n\(line27)\n\n").blocked)
    }
    @Test func atMostTwoBinaryHunks() {
        let h = "literal 5\nE0000000000\n\n"
        #expect(!a(binHead + h + h).blocked)
        #expect(a(binHead + h + h + h).blocked)
    }
    @Test func textHunkInBinaryFileBlocks() {
        #expect(a("diff --git a/x b/x\nBinary files a/x and b/x differ\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n").blocked)
        #expect(a("diff --git a/x b/x\nBinary files a/x and b/x differ\nrandom\n").blocked)
        #expect(!a("diff --git a/x b/x\nBinary files a/x and b/x differ\n").blocked)
    }

    // MARK: git mode normalisation

    private func modeChange(_ old: String, _ new: String) -> PatchAnalysis {
        a("diff --git a/f b/f\nold mode \(old)\nnew mode \(new)\n")
    }
    @Test func gitModeParsing() {
        #expect(GitMode.parse("100644") == 0o100644)
        #expect(GitMode.parse("0100755") == 0o100755)
        #expect(GitMode.parse(" 100755 ") == 0o100755)
        #expect(GitMode.parse("100777") == 0o100777)
        #expect(GitMode.parse("") == nil && GitMode.parse("rwx") == nil && GitMode.parse("1008") == nil && GitMode.parse("-100644") == nil)
        #expect(GitMode.isSymlink(0o120000) && GitMode.isSymlink(0o120777) && !GitMode.isSymlink(0o100644))
        #expect(GitMode.isGitlink(0o160000) && GitMode.isExecutable(0o100755) && !GitMode.isExecutable(0o100644))
        #expect(GitMode.isAllowed(0o100644) && GitMode.isAllowed(0o100755) && GitMode.isAllowed(0o120000) && GitMode.isAllowed(0o160000))
        #expect(!GitMode.isAllowed(0o100777) && !GitMode.isAllowed(0o100666) && !GitMode.isAllowed(0o040000))
    }
    @Test func equivalentSpellingsOfExecutableAreRecognised() {
        for spelling in ["100755", "0100755", "100755 ", "\t100755"] {
            let p = modeChange("100644", spelling)
            #expect(!p.blocked, "\(spelling)")
            #expect(p.confirmationText == "This patch makes a file executable", "\(spelling)")
        }
        let same = modeChange("100755", "0100755")
        #expect(same.files[0].kinds.isEmpty || !same.files[0].kinds.contains(.modeChange))
    }
    @Test func weirdModesBlock() {
        for bad in ["100777", "100666", "100600", "040000", "garbage", "10064x", "", "9", "100644100644"] {
            #expect(modeChange("100644", bad).blocked, "new mode \(bad)")
            #expect(modeChange(bad, "100644").blocked, "old mode \(bad)")
        }
        #expect(a("diff --git a/f b/f\nnew file mode 100666\n--- /dev/null\n+++ b/f\n@@ -0,0 +1 @@\n+x\n").blocked)
        #expect(a("diff --git a/f b/f\ndeleted file mode 100777\n--- a/f\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n").blocked)
        #expect(a("diff --git a/f b/f\nindex 1..2 100777\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\n").blocked)
        #expect(!a("diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\n").blocked)
    }
    @Test func symlinkVariants() {
        for m in ["120000", "0120000", "120000 "] {
            let p = a("diff --git a/l b/l\nnew file mode \(m)\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+t\n")
            #expect(p.files[0].isSymlink && p.confirmationText == "This patch adds a symlink", "\(m)")
        }
        let viaIndex = a("diff --git a/l b/l\nindex 1..2 120000\n--- a/l\n+++ b/l\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(viaIndex.files[0].isSymlink && viaIndex.confirmationText == "This patch changes a symlink")
        #expect(modeChange("100644", "120000").files[0].isSymlink)
        #expect(a("diff --git a/l b/l\nnew file mode 160000\n").confirmationText == "This patch touches a submodule")
    }
}
