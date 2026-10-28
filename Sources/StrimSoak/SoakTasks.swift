import Foundation

/// A deterministic post-run check. Every check runs only after the diff allowlist has passed.
public enum SoakCheck: Sendable, Equatable {
    /// `go test ./...` inside the verify sandbox (writes only in the repo and scratch, no home reads, no network).
    case goTest
    /// Case-insensitive substrings that must all appear in the file.
    case contains(path: String, words: [String])
    /// Trimmed non-empty lines of the file equal this set.
    case lines(path: String, expected: Set<String>)
    /// The word appears in no file of the repo.
    case absent(word: String)
    /// Non-overlapping occurrences of `needle` in the file are at most `atMost`.
    case count(path: String, needle: String, atMost: Int)
    /// Every exported top-level func or type has a `//` comment on the line above.
    case documented(path: String)
}

/// One soak task: a tiny from-scratch Go module with a seeded bug (or a reading/notes task), its prompt and checks.
public struct SoakTask: Sendable {
    public let id: String
    public let prompt: String
    /// The throwaway module (repo-relative path -> text). Also the hash baseline for the diff allowlist.
    public let files: [String: String]
    /// Repo files the task may change or add. `notes/` is always allowed.
    public let editable: [String]
    /// Files that must stay byte-identical to the template.
    public let unchanged: [String]
    /// Host-owned acceptance tests, written only after the diff allowlist passes and before the checks run.
    public let hidden: [String: String]
    public let checks: [SoakCheck]
}

public enum SoakTasks {
    public static let prefix = "Work only inside the current directory; do not use the network. "

    static let goMod = "module mathkit\n\ngo 1.21\n"

    /// Module files every task starts from (plus go.mod and an empty notes/ dir for the redirected test log).
    static func module(_ files: [String: String]) -> [String: String] {
        var m = files
        m["go.mod"] = goMod
        m["notes/.keep"] = ""
        return m
    }

    // Shared sources. Each task's module is built from these, so the seeded bugs are the only difference.

    static let statsGo = #"""
    package mathkit

    import "sort"

    // Mean returns the arithmetic mean of a non-empty slice.
    func Mean(xs []float64) float64 {
        sum := 0.0
        for _, x := range xs {
            sum += x
        }
        return sum / float64(len(xs))
    }

    // Median returns the median of a non-empty slice.
    func Median(xs []float64) float64 {
        s := append([]float64(nil), xs...)
        sort.Float64s(s)
        mid := len(s) / 2
        if len(s)%2 == 1 {
            return s[mid]
        }
        return s[mid] // BUG: even length should average the two middle values
    }

    // Variance returns the population variance of a non-empty slice.
    func Variance(xs []float64) float64 {
        m := Mean(xs)
        sum := 0.0
        for _, x := range xs {
            sum += (x - m) * (x - m)
        }
        return sum / float64(len(xs))
    }

    """#

    static let statsTestGo = #"""
    package mathkit

    import "testing"

    func TestMean(t *testing.T) {
        if got := Mean([]float64{1, 2, 3}); got != 2 {
            t.Fatalf("Mean = %v", got)
        }
    }

    func TestMedianOdd(t *testing.T) {
        if got := Median([]float64{3, 1, 2}); got != 2 {
            t.Fatalf("Median odd = %v", got)
        }
    }

    func TestMedianEven(t *testing.T) {
        if got := Median([]float64{1, 2, 3, 4}); got != 2.5 {
            t.Fatalf("Median even = %v", got)
        }
    }

    """#

    /// Slugify with the punctuation bug: `\s+` runs become "-" but punctuation survives.
    static let slugBuggyGo = #"""
    package mathkit

    import (
        "regexp"
        "strings"
    )

    var spaces = regexp.MustCompile(`\s+`)

    // Slugify lowercases s, trims it and joins whitespace runs with "-".
    func Slugify(s string) string {
        return spaces.ReplaceAllString(strings.ToLower(strings.TrimSpace(s)), "-")
    }

    """#

    static let slugPunctTestGo = #"""
    package mathkit

    import "testing"

    func TestSlugifySpaces(t *testing.T) {
        if got := Slugify("Hello World"); got != "hello-world" {
            t.Fatalf("got %q", got)
        }
    }

    func TestSlugifyPunctuation(t *testing.T) {
        if got := Slugify("  Hello,  World! "); got != "hello-world" {
            t.Fatalf("got %q", got)
        }
    }

    """#

    static let slugSimpleGo = #"""
    package mathkit

    import "strings"

    // Slugify lowercases s, trims it and joins words with "-".
    func Slugify(s string) string {
        return strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(s))), "-")
    }

    """#

    static let slugSimpleTestGo = #"""
    package mathkit

    import "testing"

    func TestSlugifySpaces(t *testing.T) {
        if got := Slugify("Hello World"); got != "hello-world" {
            t.Fatalf("got %q", got)
        }
    }

    """#

    static let wordCountGo = #"""
    package mathkit

    import "strings"

    // WordCount returns the number of whitespace-separated words in s.
    func WordCount(s string) int {
        return len(strings.Fields(s))
    }

    """#

    static let wordCountTestGo = #"""
    package mathkit

    import "testing"

    func TestWordCount(t *testing.T) {
        if got := WordCount(" a b  c "); got != 3 {
            t.Fatalf("got %d", got)
        }
    }

    func TestWordCountEmpty(t *testing.T) {
        if got := WordCount("   "); got != 0 {
            t.Fatalf("got %d", got)
        }
    }

    """#

    static let utilGo = #"""
    package mathkit

    // Ping returns the string pong.
    func Ping() string {
        return "pong"
    }

    """#

    static let utilTestGo = #"""
    package mathkit

    import "testing"

    func TestPing(t *testing.T) {
        if got := Ping(); got != "pong" {
            t.Fatalf("got %q", got)
        }
    }

    """#

    static let mainGo = #"""
    package main

    import (
        "fmt"
        "mathkit"
        "os"
        "strings"
    )

    func main() {
        args := os.Args[1:]
        fmt.Println(mathkit.Slugify(strings.Join(args, " ")))
    }

    """#

    /// The 12 tasks, in the same order and with the same explain / fix / refactor / test mix as the committed run2 set.
    public static let all: [SoakTask] = [
        SoakTask(
            id: "explain_stats",
            prompt: "Read stats.go. Write notes/stats_explained.md with one bullet per exported function saying what it "
                + "computes and how it handles edge cases. Do not modify any other file.",
            files: module(["stats.go": statsGo]),
            editable: [], unchanged: ["stats.go"], hidden: [:],
            checks: [.contains(path: "notes/stats_explained.md", words: ["Mean", "Median", "Variance"])]),
        SoakTask(
            id: "fix_median",
            prompt: "stats_test.go has a failing test. Read the code, fix the bug in stats.go so every test in "
                + "stats_test.go passes, and do not edit the tests. You cannot run commands; the harness runs the tests afterwards.",
            files: module(["stats.go": statsGo, "stats_test.go": statsTestGo]),
            editable: ["stats.go"], unchanged: ["stats_test.go"], hidden: [:],
            checks: [.goTest]),
        SoakTask(
            id: "grep_callers",
            prompt: "Find every file in this repo that calls `Slugify(` outside its definition in text.go. Write their "
                + "repo-relative paths, one per line, into notes/slugify_callers.txt. Change nothing else.",
            files: module([
                "text.go": slugSimpleGo,
                "cli.go": "package mathkit\n\nimport \"strings\"\n\n// Run turns command arguments into a slug.\nfunc Run(args []string) string {\n\treturn Slugify(strings.Join(args, \" \"))\n}\n",
                "text_test.go": slugSimpleTestGo,
                "other.go": "package mathkit\n\nimport \"strings\"\n\n// Title upper-cases the first letter of s.\nfunc Title(s string) string {\n\tif s == \"\" {\n\t\treturn s\n\t}\n\treturn strings.ToUpper(s[:1]) + s[1:]\n}\n",
            ]),
            editable: [], unchanged: ["text.go", "cli.go", "text_test.go", "other.go"], hidden: [:],
            checks: [.lines(path: "notes/slugify_callers.txt", expected: ["cli.go", "text_test.go"])]),
        SoakTask(
            id: "rename_word_count",
            prompt: "Rename the function `WordCount` to `CountWords` everywhere in this repo: its definition, every "
                + "caller, the tests and the README. Afterwards the string `WordCount` must not appear anywhere in the "
                + "repo. You cannot run commands; the harness runs the tests afterwards.",
            files: module([
                "text.go": wordCountGo,
                "text_test.go": wordCountTestGo,
                "README.md": "# wordtool\n\nWordCount counts the words in a string.\n",
            ]),
            editable: ["text.go", "text_test.go", "README.md"], unchanged: [], hidden: [:],
            checks: [.goTest, .absent(word: "WordCount")]),
        SoakTask(
            id: "add_docstrings",
            prompt: "Add a one-line doc comment to every exported function and type in text.go that has none. "
                + "Do not change any code.",
            files: module([
                "text.go": "package mathkit\n\nimport \"strings\"\n\nfunc Slugify(s string) string {\n\treturn strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(s))), \"-\")\n}\n\nfunc Title(s string) string {\n\tif s == \"\" {\n\t\treturn s\n\t}\n\treturn strings.ToUpper(s[:1]) + s[1:]\n}\n",
                "text_test.go": "package mathkit\n\nimport \"testing\"\n\nfunc TestSlugify(t *testing.T) {\n\tif Slugify(\"A B\") != \"a-b\" {\n\t\tt.Fatal(\"slugify\")\n\t}\n}\n\nfunc TestTitle(t *testing.T) {\n\tif Title(\"go\") != \"Go\" {\n\t\tt.Fatal(\"title\")\n\t}\n}\n",
            ]),
            editable: ["text.go"], unchanged: ["text_test.go"], hidden: [:],
            checks: [.documented(path: "text.go"), .goTest]),
        SoakTask(
            id: "run_tests_report",
            prompt: "You cannot run commands. Read stats.go, stats_test.go, text.go and text_test.go, work out which test "
                + "functions would fail, and write their names, one per line, into notes/failing_tests.txt. Change nothing else.",
            files: module([
                "stats.go": statsGo,
                "stats_test.go": statsTestGo,
                "text.go": slugBuggyGo,
                "text_test.go": slugPunctTestGo,
            ]),
            editable: [], unchanged: ["stats.go", "stats_test.go", "text.go", "text_test.go"], hidden: [:],
            checks: [.lines(path: "notes/failing_tests.txt", expected: ["TestMedianEven", "TestSlugifyPunctuation"])]),
        SoakTask(
            id: "refactor_normalize",
            prompt: "In text.go, `Slugify` and `WordCount` both start with the same `strings.ToLower(strings.TrimSpace(...))` "
                + "steps. Move them into an unexported helper `normalize(s string) string` and call it from both. Behaviour "
                + "must not change and no test may be edited. You cannot run commands; the harness runs the tests afterwards.",
            files: module([
                "text.go": """
                package mathkit

                import "strings"

                // Slugify lowercases s, trims it and joins words with "-".
                func Slugify(s string) string {
                    t := strings.ToLower(strings.TrimSpace(s))
                    return strings.Join(strings.Fields(t), "-")
                }

                // WordCount returns the number of words in s after lowercasing and trimming it.
                func WordCount(s string) int {
                    t := strings.ToLower(strings.TrimSpace(s))
                    return len(strings.Fields(t))
                }

                """,
                "text_test.go": """
                package mathkit

                import "testing"

                func TestSlugifySpaces(t *testing.T) {
                    if got := Slugify("Hello World"); got != "hello-world" {
                        t.Fatalf("got %q", got)
                    }
                }

                func TestWordCount(t *testing.T) {
                    if got := WordCount(" a b  c "); got != 3 {
                        t.Fatalf("got %d", got)
                    }
                }

                """,
            ]),
            editable: ["text.go"], unchanged: ["text_test.go"], hidden: [:],
            checks: [.goTest, .contains(path: "text.go", words: ["func normalize("]),
                     .count(path: "text.go", needle: "strings.ToLower(", atMost: 1)]),
        SoakTask(
            id: "add_clamp",
            prompt: "Add `Clamp(x, lo, hi int) int` to util.go: return x limited to the range [lo, hi], and panic when "
                + "lo > hi. Add unit tests for it in util_test.go and make the tests pass. You cannot run commands; the harness runs `go test ./...` afterwards.",
            files: module(["util.go": utilGo, "util_test.go": utilTestGo]),
            editable: ["util.go", "util_test.go"], unchanged: ["go.mod"],
            hidden: ["zz_hidden_clamp_test.go": #"""
            package mathkit

            import "testing"

            func TestHiddenClamp(t *testing.T) {
                if Clamp(5, 0, 3) != 3 || Clamp(-1, 0, 3) != 0 || Clamp(2, 0, 3) != 2 {
                    t.Fatal("clamp range")
                }
                defer func() {
                    if recover() == nil {
                        t.Fatal("expected a panic when lo > hi")
                    }
                }()
                Clamp(1, 3, 0)
            }

            """#],
            checks: [.goTest]),
        SoakTask(
            id: "explain_cli",
            prompt: "Read cmd/mathkit/main.go and text.go. In notes/cli_flow.md explain, in at most 15 lines, how "
                + "`go run ./cmd/mathkit <words>` turns its arguments into output.",
            files: module(["text.go": slugSimpleGo, "text_test.go": slugSimpleTestGo, "cmd/mathkit/main.go": mainGo]),
            editable: [], unchanged: ["cmd/mathkit/main.go", "text.go"], hidden: [:],
            checks: [.contains(path: "notes/cli_flow.md", words: ["args", "slugify"])]),
        SoakTask(
            id: "fix_slugify",
            prompt: "text_test.go has a failing test for punctuation in Slugify. Fix text.go so that its tests pass. "
                + "Do not edit the tests. You cannot run commands; the harness runs the tests afterwards.",
            files: module(["text.go": slugBuggyGo, "text_test.go": slugPunctTestGo]),
            editable: ["text.go"], unchanged: ["text_test.go"], hidden: [:],
            checks: [.goTest]),
        SoakTask(
            id: "add_load_numbers",
            prompt: "Add `LoadNumbers(path string) ([]float64, error)` to numbers.go. It reads a text file of "
                + "whitespace-separated numbers and returns them as float64 (an empty file gives an empty slice). Add tests "
                + "in numbers_test.go that write a temporary file, and make the tests pass. You cannot run commands; the harness runs `go test ./...` afterwards.",
            files: module(["numbers.go": "package mathkit\n"]),
            editable: ["numbers.go", "numbers_test.go"], unchanged: ["go.mod"],
            hidden: ["zz_hidden_numbers_test.go": #"""
            package mathkit

            import (
                "os"
                "path/filepath"
                "testing"
            )

            func TestHiddenLoadNumbers(t *testing.T) {
                dir := t.TempDir()
                p := filepath.Join(dir, "n.txt")
                if err := os.WriteFile(p, []byte("1 2.5\n 3\n"), 0o644); err != nil {
                    t.Fatal(err)
                }
                got, err := LoadNumbers(p)
                if err != nil || len(got) != 3 || got[0] != 1 || got[1] != 2.5 || got[2] != 3 {
                    t.Fatalf("got %v, %v", got, err)
                }
                e := filepath.Join(dir, "e.txt")
                if err := os.WriteFile(e, nil, 0o644); err != nil {
                    t.Fatal(err)
                }
                got, err = LoadNumbers(e)
                if err != nil || len(got) != 0 {
                    t.Fatalf("empty file: %v, %v", got, err)
                }
            }

            """#],
            checks: [.goTest]),
        SoakTask(
            id: "add_stdev",
            prompt: "Add `Stdev(xs []float64) (float64, error)` to stats.go: the sample standard deviation (n-1 "
                + "denominator) of at least two numbers, and an error otherwise. Add tests in stats_stdev_test.go and make "
                + "the tests pass. You cannot run commands; the harness runs `go test ./...` afterwards.",
            files: module(["stats.go": "package mathkit\n\n// Mean returns the arithmetic mean of a non-empty slice.\nfunc Mean(xs []float64) float64 {\n\tsum := 0.0\n\tfor _, x := range xs {\n\t\tsum += x\n\t}\n\treturn sum / float64(len(xs))\n}\n",
                           "stats_test.go": "package mathkit\n\nimport \"testing\"\n\nfunc TestMean(t *testing.T) {\n\tif Mean([]float64{1, 2, 3}) != 2 {\n\t\tt.Fatal(\"mean\")\n\t}\n}\n"]),
            editable: ["stats.go", "stats_stdev_test.go"], unchanged: ["stats_test.go"],
            hidden: ["zz_hidden_stdev_test.go": #"""
            package mathkit

            import (
                "math"
                "testing"
            )

            func TestHiddenStdev(t *testing.T) {
                got, err := Stdev([]float64{2, 4, 4, 4, 5, 5, 7, 9})
                if err != nil || math.Abs(got-2.1380899352993947) > 1e-9 {
                    t.Fatalf("stdev = %v, %v", got, err)
                }
                if _, err := Stdev([]float64{1}); err == nil {
                    t.Fatal("expected an error for one value")
                }
            }

            """#],
            checks: [.goTest]),
    ]
}
