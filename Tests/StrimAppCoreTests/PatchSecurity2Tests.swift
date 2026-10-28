import Foundation
import Testing
@testable import StrimAppCore

private func a(_ s: String) -> PatchAnalysis { DiffParser.analyze(s) }
private func newFile(_ path: String, body: String = "x") -> String {
    "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+\(body)\n"
}

@Suite struct ExecutingPathTests {
    @Test func namedPathsNeedConfirmation() {
        let paths = [".vscode/tasks.json", ".envrc", ".husky/pre-commit", ".githooks/pre-push", "Makefile", "sub/Makefile",
                     "package.json", "Package.swift", "pyproject.toml", "setup.py", "conftest.py", "tests/conftest.py",
                     ".gitattributes", ".gitmodules", ".npmrc", "Dockerfile", "Dockerfile.prod", "scripts/build.sh",
                     "tools/scripts/x.sh", ".github/workflows/ci.yml", "makefile", "PACKAGE.JSON", ".pre-commit-config.yaml"]
        for p in paths {
            let r = a(newFile(p))
            #expect(!r.blocked, "\(p)")
            #expect(r.needsConfirmation, "\(p) should need a tick")
            #expect(r.confirmationText?.contains(p) == true, "confirmation must name \(p): \(r.confirmationText ?? "nil")")
        }
    }
    @Test func ordinaryPathsDoNot() {
        for p in ["src/main.swift", "README.md", "docs/scripts.md", "Sources/Makefile.swift", "mypackage.json.txt", "descripts/x.txt", "a/b.py"] {
            #expect(!a(newFile(p)).needsConfirmation, "\(p)")
        }
    }
    @Test func renameIntoExecutingPathNamesIt() {
        let r = a("diff --git a/x b/Makefile\nsimilarity index 100%\nrename from x\nrename to Makefile\n")
        #expect(r.confirmationText?.contains("Makefile") == true && r.confirmationText?.contains("renames a file") == true)
    }
    @Test func manyPathsAreSummarised() {
        let r = a((1...6).map { newFile("scripts/s\($0).sh") }.joined())
        let t = r.confirmationText ?? ""
        #expect(t.contains("scripts/s1.sh") && t.contains("more"))
    }
}

@Suite struct HiddenCharacterTests {
    @Test func visibleEscaping() {
        #expect(DiffText.visible("plain ascii\tok") == "plain ascii\tok")
        #expect(DiffText.visible("a\u{202E}b") == "a\\u{202e}b")           // RLO
        #expect(DiffText.visible("a\u{200B}b\u{200D}") == "a\\u{200b}b\\u{200d}")   // ZWSP, ZWJ
        #expect(DiffText.visible("\u{2066}x\u{2069}") == "\\u{2066}x\\u{2069}")     // isolates
        #expect(DiffText.visible("\u{FEFF}bom") == "\\u{feff}bom")
        #expect(DiffText.visible("x\u{0}y\u{7}z\u{1B}") == "x\\u{0}y\\u{7}z\\u{1b}")
        #expect(DiffText.visible("é中😀") == "é中😀")                          // ordinary non-ASCII is left alone
        #expect(DiffText.hasHidden("a\u{202E}b") && !DiffText.hasHidden("é中😀") && !DiffText.hasHidden("tab\there"))
    }
    @Test func bidiInPathIsSuspiciousAndNeedsTick() {
        let evil = "src/te\u{202E}txt.swift"
        let r = a(newFile(evil))
        #expect(r.suspicious && !r.blocked && r.needsConfirmation)
        #expect(r.issues.contains { $0.reason.contains("invisible") && $0.reason.contains("\\u{202e}") })
        #expect(r.files[0].displayPath == "src/te\\u{202e}txt.swift")
        #expect(!(r.confirmationText ?? "").unicodeScalars.contains { $0.value == 0x202E })   // never echoed raw
        #expect(r.issues.allSatisfy { !$0.reason.unicodeScalars.contains { $0.value == 0x202E } })
    }
    @Test func zeroWidthInPathIsSuspicious() {
        #expect(a(newFile("ma\u{200B}in.swift")).suspicious)
        #expect(a(newFile("ma\u{00AD}in.swift")).suspicious)    // soft hyphen is Cf too
    }
    @Test func codeLinesWithHiddenCharsAreFlaggedAndEscaped() {
        let r = a(newFile("src/a.swift", body: "if isAdmin \u{202E}// \u{2066}check"))
        #expect(r.suspicious && !r.blocked && r.needsConfirmation)
        #expect(r.issues.contains { $0.reason.contains("line(s)") && $0.reason.contains("invisible") })
        let line = r.files[0].hunks[0].lines[0]
        #expect(line.hasHidden && line.displayText == "if isAdmin \\u{202e}// \\u{2066}check")
        #expect(r.files[0].hiddenLineCount == 1)
    }
    @Test func cleanPatchHasNoHiddenFlags() {
        let r = a(newFile("src/a.swift", body: "let s = \"héllo 中 😀\""))
        #expect(!r.suspicious)
    }
    @Test func headerRowsAndStrayLinesAreEscapedForDisplay() {
        let r = a("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n\u{202E}rm\n")
        #expect(r.blocked)
        #expect(r.files[0].strayLines.map(DiffText.visible) == ["\\u{202e}rm"])
        let h = a("diff --git a/x b/x\nunknown\u{200B}line\n")
        #expect(h.files[0].headerRows.last?.displayText == "unknown\\u{200b}line")
    }
    @Test func hugePatchWithNonAsciiStaysFast() {
        var s = "diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -1,0 +1,60000 @@\n"
        for i in 0..<60_000 { s += "+línea \(i) 中文\n" }
        let t0 = Date(); let r = a(s)
        #expect(Date().timeIntervalSince(t0) < 3 && !r.blocked && !r.suspicious)
    }
}

private func code(_ body: String) -> PatchAnalysis { a(newFile("src/a.swift", body: body)) }

@Suite struct BlankLookingCharacterTests {
    // every class of invisible / blank-looking scalar
    private let hiddenClasses: [(String, UInt32)] = [
        ("hangul choseong filler", 0x115F), ("hangul jungseong filler", 0x1160), ("hangul filler", 0x3164),
        ("halfwidth hangul filler", 0xFFA0), ("braille blank", 0x2800), ("combining grapheme joiner", 0x034F),
        ("mongolian vowel separator", 0x180E), ("variation selector 1", 0xFE00), ("variation selector 16", 0xFE0F),
        ("variation selector supplement", 0xE0100), ("word joiner", 0x2060), ("zero width space", 0x200B),
        ("rlo", 0x202E), ("tag space", 0xE0020), ("invisible separator", 0x2063),
    ]
    private let spaces: [UInt32] = [0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
                                    0x2009, 0x200A, 0x202F, 0x205F, 0x3000]
    private func s(_ v: UInt32) -> String { String(Unicode.Scalar(v)!) }

    @Test func classification() {
        for (name, v) in hiddenClasses {
            #expect(DiffText.isHidden(Unicode.Scalar(v)!), "\(name) U+\(String(v, radix: 16))")
            #expect(DiffText.hasHidden("a" + s(v) + "b"))
            #expect(DiffText.visible("a" + s(v) + "b") == "a\\u{\(String(v, radix: 16))}b", "\(name)")
        }
        for v in spaces {
            #expect(!DiffText.isHidden(Unicode.Scalar(v)!), "U+\(String(v, radix: 16)) is a space, not hidden")
            #expect(DiffText.isUnusualSpace(Unicode.Scalar(v)!))
            #expect(DiffText.hasHidden("a" + s(v) + "b"))                    // path semantics: flagged
            #expect(DiffText.visible("a" + s(v) + "b") == "a\\u{\(String(v, radix: 16))}b")
        }
        #expect(!DiffText.isUnusualSpace(" ") && !DiffText.isHidden(" ") && !DiffText.isHidden("a") && !DiffText.isHidden("\t"))
        #expect(!DiffText.hasHidden("é中😀 plain name.swift"))
    }
    @Test func eachClassInAPathIsSuspiciousAndNeedsTick() {
        for (name, v) in hiddenClasses {
            let r = a(newFile("src/a" + s(v) + "b.swift"))
            #expect(r.suspicious && !r.blocked && r.needsConfirmation, "\(name)")
            #expect(r.issues.allSatisfy { !$0.reason.unicodeScalars.contains { $0.value == v } }, "raw \(name) echoed")
            #expect(r.files[0].displayPath == "src/a\\u{\(String(v, radix: 16))}b.swift", "\(name)")
        }
        for v in spaces {
            let r = a(newFile("src/a" + s(v) + "b.swift"))
            #expect(r.suspicious && r.needsConfirmation, "space U+\(String(v, radix: 16)) in path")
        }
    }
    @Test func pathMadeOnlyOfHangulFiller() {
        let r = a(newFile("\u{3164}"))
        #expect(r.suspicious && r.needsConfirmation && r.files[0].displayPath == "\\u{3164}")
        let both = a(newFile("\u{3164}\u{3164}.swift"))
        #expect(both.suspicious)
    }
    @Test func hangulFillerInsideFilenameLooksLikeAnotherName() {
        let r = a(newFile("src/main\u{3164}.swift"))      // looks like main.swift
        #expect(r.suspicious && r.confirmationText?.contains("\\u{3164}") == true)
    }
    @Test func mongolianVowelSeparatorAndVariationSelectors() {
        #expect(a(newFile("src/x\u{180E}.swift")).suspicious)
        #expect(a(newFile("src/x\u{FE0F}.swift")).suspicious)
        #expect(a(newFile("src/x\u{E0100}.swift")).suspicious)
        #expect(a(newFile("src/x\u{034F}.swift")).suspicious)
        #expect(a(newFile("src/x\u{2800}.swift")).suspicious)
    }
    @Test func codeLinesHiddenClassesNeedATick() {
        for (name, v) in hiddenClasses {
            let r = code("let a = 1 " + s(v) + "// x")
            #expect(r.suspicious && r.needsConfirmation && !r.blocked, "\(name)")
            #expect(r.files[0].hunks[0].lines[0].hasHidden, "\(name)")
            #expect(r.files[0].hunks[0].lines[0].displayText == "let a = 1 \\u{\(String(v, radix: 16))}// x", "\(name)")
        }
    }
    @Test func nbspInPathBlocksUntilTickedButInCodeIsOnlyANote() {
        let path = a(newFile("src/a\u{00A0}b.swift"))
        #expect(path.suspicious && path.needsConfirmation && path.notes.isEmpty)
        for v in spaces {
            let r = code("let s = \"hello" + s(v) + "world\"")
            #expect(!r.suspicious && !r.needsConfirmation && !r.blocked, "U+\(String(v, radix: 16)) in code must not demand a tick")
            #expect(r.notes.count == 1 && r.notes[0].contains("unusual whitespace") && r.notes[0].contains("1 line"))
            #expect(r.files[0].hunks[0].lines[0].hasUnusualSpace && !r.files[0].hunks[0].lines[0].hasHidden)
            #expect(r.files[0].hunks[0].lines[0].displayText == "let s = \"hello\\u{\(String(v, radix: 16))}world\"")
            #expect(r.files[0].unusualSpaceLineCount == 1)
        }
    }
    @Test func plainSpacesAndTabsAreFine() {
        let r = code("\tlet s = \"a b\"  // two  spaces")
        #expect(!r.suspicious && r.notes.isEmpty)
    }
}

@Suite struct UnicodeNormalizationTests {
    private let nfc = "caf\u{E9}"
    private let nfd = "cafe\u{301}"
    @Test func swiftEqualityIsBlindToItButByteComparisonIsNot() {
        #expect(nfc == nfd)                                   // the trap
        #expect(Array(nfc.utf8) != Array(nfd.utf8))
    }
    @Test func decomposedPathIsFlagged() {
        let r = a(newFile(nfd + ".txt"))
        #expect(r.suspicious && r.needsConfirmation)
        #expect(r.issues.contains { $0.reason.contains("NFC") })
        #expect(!a(newFile(nfc + ".txt")).suspicious)
    }
    @Test func headerPathMismatchByNormalizationIsCaught() {
        // diff --git says NFC, +++ says NFD: String == would call them equal
        let p = a("diff --git a/\(nfc) b/\(nfc)\nnew file mode 100644\n--- /dev/null\n+++ b/\(nfd)\n@@ -0,0 +1 @@\n+x\n")
        #expect(p.suspicious)
        #expect(p.issues.contains { $0.reason.contains("+++") && $0.reason.contains("canonical") })
    }
    @Test func oldSideMismatchByNormalizationIsCaught() {
        let p = a("diff --git a/\(nfc) b/\(nfc)\n--- a/\(nfd)\n+++ b/\(nfc)\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(p.issues.contains { $0.reason.contains("---") && $0.reason.contains("canonical") })
    }
    @Test func identicalNFCHeadersAreClean() {
        let p = a("diff --git a/\(nfc) b/\(nfc)\n--- a/\(nfc)\n+++ b/\(nfc)\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(!p.suspicious)
    }
    @Test func bothNormalizationsOfTheSameNameAreCheckedNotDeduped() {
        // rename between canonically-equal names: both must be examined (and the NFD one flagged)
        let p = a("diff --git a/\(nfc) b/\(nfd)\nsimilarity index 100%\nrename from \(nfc)\nrename to \(nfd)\n")
        #expect(p.issues.contains { $0.reason.contains("NFC") })
    }
}
