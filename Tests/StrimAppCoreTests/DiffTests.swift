import Testing
@testable import StrimAppCore

private let patch = """
diff --git a/Sources/a.swift b/Sources/a.swift
index 111..222 100644
--- a/Sources/a.swift
+++ b/Sources/a.swift
@@ -10,3 +10,4 @@ func f() {
 keep
-old
+new1
+new2
 tail
@@ -40,2 +41,1 @@
-gone
 end
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
\\ No newline at end of file

"""

@Suite struct DiffTests {
    @Test func parsesFilesHunksAndNumbers() {
        let files = DiffParser.parse(patch)
        #expect(files.map(\.path) == ["Sources/a.swift", "new.txt"])
        #expect(files[0].hunks.count == 2)
        #expect(files[0].added == 2 && files[0].removed == 2)
        #expect(files[1].isNew)
        let l = files[0].hunks[0].lines
        #expect(l.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(l[0].oldNumber == 10 && l[0].newNumber == 10)
        #expect(l[1].oldNumber == 11 && l[1].newNumber == nil)
        #expect(l[2].newNumber == 11 && l[3].newNumber == 12)
        #expect(l[4].oldNumber == 12 && l[4].newNumber == 13)
        #expect(files[0].hunks[1].lines[0].oldNumber == 40)
        #expect(files[1].hunks[0].lines.last?.kind == .meta)
        #expect(DiffParser.summary(files) == "2 files, +4 -2")
    }
    @Test func emptyAndGarbage() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.parse("not a diff\nat all").isEmpty)
        #expect(DiffParser.summary([]) == "0 files, +0 -0")
    }
    @Test func hunkOnlyPatch() {
        let f = DiffParser.parse("@@ -1,1 +1,1 @@\n-a\n+b\n")
        #expect(f.count == 1 && f[0].added == 1 && f[0].removed == 1)
        let a = DiffParser.analyze("@@ -1,1 +1,1 @@\n-a\n+b\n")
        #expect(a.blocked && a.suspicious)
    }
    @Test func deletedFile() {
        let f = DiffParser.parse("diff --git a/x b/x\ndeleted file mode 100644\n--- a/x\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-bye\n")
        #expect(f[0].isDeleted && f[0].removed == 1 && f[0].path == "x")
    }
}
