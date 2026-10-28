import Foundation
import Testing
@testable import StrimAgentBench

/// The shipped corpus: language coverage, per-language class balance and the balanced pilot selection.
@Suite struct LanguageMixTests {
    static let required = ["typescript", "javascript", "react", "rust", "java", "ruby", "python", "go", "swift"]

    func corpus() -> [LoadedTask] { TaskLoader.load(root: repoRoot().appendingPathComponent("bench/agenttasks")) }

    @Test func everyRequiredLanguageHasEnoughTasksOfMixedClasses() {
        let tasks = corpus()
        for lang in Self.required {
            let mine = tasks.filter { $0.language == lang }
            #expect(mine.count >= 3, "\(lang) has \(mine.count) tasks")
        }
        for lang in ["typescript", "javascript", "react", "rust", "java", "ruby", "python"] {
            let classes = Set(tasks.filter { $0.language == lang }.map(\.spec.taskClass))
            #expect(classes.isSuperset(of: ["test-fix", "feature-impl", "repo-qa"]), "\(lang): \(classes)")
        }
    }

    @Test func verifyCommandsUseOnlyAllowListedRunners() {
        for t in corpus() {
            guard let cmd = t.spec.verifyCmd, !t.spec.isAnswerTask else { continue }
            for seg in cmd.components(separatedBy: " && ") {
                if seg.hasPrefix("!") { continue }   // grep checks of mechanical-edit tasks run in the grader only
                var words = seg.split(separator: " ").map(String.init)
                if words.first == "./scripts/javatest.sh" { words = ["javatest"] }
                else if words.first == "sh", words.dropFirst().first == "scripts/javatest.sh" { words = ["javatest"] }
                #expect(RunTestsService.validate(words) == nil, Comment(rawValue: "\(t.id): `\(seg)` -> \(RunTestsService.validate(words) ?? "")"))
            }
            #expect(!t.spec.testPaths.isEmpty, "\(t.id) has no hash-restored test paths")
        }
    }

    @Test func pilotIsBalancedAndDeterministic() {
        let tasks = corpus()
        let pilot = TaskLoader.pilot(tasks, perLanguage: 2)
        #expect((12...18).contains(pilot.count), "\(pilot.count) tasks")
        for lang in Self.required { #expect(pilot.filter { $0.language == lang }.count >= 2, Comment(rawValue: lang)) }
        #expect(Set(pilot.map(\.spec.taskClass)).count >= 3)
        #expect(pilot.map(\.id) == TaskLoader.pilot(tasks, perLanguage: 2).map(\.id))
        let sel = TaskLoader.select(tasks, limit: nil, ids: [], classes: [], languages: ["python", "rust"])
        #expect(sel.allSatisfy { ["python", "rust"].contains($0.language ?? "") } && sel.count == 8)
        #expect(TaskLoader.select(tasks, limit: nil, ids: [], classes: [], languages: ["python"], pilotPerLanguage: 1).count == 1)
    }
}
