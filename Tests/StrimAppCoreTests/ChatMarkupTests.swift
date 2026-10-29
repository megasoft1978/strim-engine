import Testing
import Foundation
import StrimAPI
@testable import StrimAppCore

@Suite struct ThinkSplitterTests {
    private func split(_ s: String, final: Bool = true) -> [ThinkSplitter.Segment] { ThinkSplitter.split(s, final: final) }
    private func r(_ t: String) -> ThinkSplitter.Segment { .init(isReasoning: true, text: t) }
    private func a(_ t: String) -> ThinkSplitter.Segment { .init(isReasoning: false, text: t) }

    @Test func plainTextUntouched() { #expect(split("hello\nworld") == [a("hello\nworld")]) }

    @Test func closingTagOnlyAfterAnswerIsDropped() {
        #expect(split("answer text\n</think>") == [a("answer text\n")])
    }

    @Test func closingTagOnlyTurnsPrecedingIntoReasoning() {
        #expect(split("Let me think.\n</think>\n\nThe answer.") == [r("Let me think."), a("The answer.")])
    }

    @Test func fullBlock() { #expect(split("<think>\nhm\n</think>\n\nanswer") == [r("hm"), a("answer")]) }

    @Test func multipleBlocks() {
        #expect(split("<think>one</think>A<think>two</think>B") == [r("one"), a("A"), r("two"), a("B")])
    }

    @Test func tagSplitAcrossChunks() {
        let raw = "<think>plan</think>done"
        for cut in 1..<raw.count {
            let idx = raw.index(raw.startIndex, offsetBy: cut)
            // Streaming view of the prefix never shows a partial tag, and the complete text is always the same.
            let partial = split(String(raw[..<idx]), final: false).map(\.text).joined()
            #expect(!partial.contains("<") && !partial.contains("think>"))
        }
        #expect(split(raw, final: false) == [r("plan"), a("done")])
    }

    @Test func partialTagHeldWhileStreamingAndShownAtEnd() {
        #expect(split("abc</thi", final: false) == [a("abc")])
        #expect(split("abc</thi", final: true) == [a("abc</thi")])
    }

    @Test func tagsInsideCodeFenceStayLiteral() {
        let t = "text\n```html\n<think>x</think>\n</think>\n```\nafter"
        #expect(split(t) == [a(t)])
    }
}

@Suite struct MarkdownBlockTests {
    @Test func fencedDiffKeepsNewlines() {
        let t = "```diff\n--- a/x\n+++ b/x\n-old\n+new\n```\n\nDone."
        let b = MarkdownBlock.parse(t)
        #expect(b == [.code(language: "diff", text: "--- a/x\n+++ b/x\n-old\n+new"), .prose("Done.")])
    }
    @Test func unterminatedFenceIsCodeWhileStreaming() {
        #expect(MarkdownBlock.parse("hi\n```go\nfunc a() {\n") == [.prose("hi"), .code(language: "go", text: "func a() {\n")])
    }
    @Test func diffLineKinds() {
        #expect(DiffLineKind.classify("+x") == .added && DiffLineKind.classify("-x") == .removed)
        #expect(DiffLineKind.classify("+++ b/x") == .header && DiffLineKind.classify("@@ -1 +1 @@") == .hunk)
        #expect(DiffLineKind.classify(" ctx") == .context)
    }
}

@Suite struct JobListFilterTests {
    private func job(_ id: String, _ st: JobStatusDTO, age: Double, now: Double) -> JobSummary {
        JobSummary(id: id, source: .chat, status: st, started: now - age - 10, finished: st.isFinished ? now - age : nil)
    }
    @Test func defaultKeepsActiveAndLast24h() {
        let now = Date(timeIntervalSince1970: 2_000_000_000), t = now.timeIntervalSince1970
        let jobs = [job("run", .running, age: 3 * 86400, now: t), job("new", .done, age: 3600, now: t),
                    job("old", .cancelled, age: 2 * 86400, now: t), job("older", .done, age: 9 * 86400, now: t)]
        let r = JobListFilter.apply(jobs, now: now, showAll: false)
        #expect(r.shown.map(\.id) == ["run", "new"] && r.total == 4 && r.hidden == 2 && r.active == 1)
        #expect(JobListFilter.apply(jobs, now: now, showAll: true).shown.count == 4)
        #expect(JobListFilter.apply(jobs, now: now, showAll: false, keep: "old").shown.map(\.id) == ["run", "new", "old"])
    }
}
