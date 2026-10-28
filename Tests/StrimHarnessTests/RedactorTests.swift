import XCTest
@testable import StrimHarness

final class RedactorTests: XCTestCase {
    private func rep(_ c: Character, _ n: Int) -> String { String(repeating: c, count: n) }

    func testAWS() {
        let k = "AKIA" + rep("A", 16)
        XCTAssertEqual(Redactor.redact("key=\(k) end"), "key=[REDACTED] end")
    }
    func testGitHub() {
        for p in ["ghp_", "gho_", "ghs_", "github_pat_"] {
            let t = p + rep("a", 30)
            XCTAssertEqual(Redactor.redact("t \(t)."), "t [REDACTED].", p)
        }
    }
    func testSkKeys() {
        let a = "sk-" + rep("b", 32)
        let b = "sk-ant-" + rep("c", 40)
        XCTAssertEqual(Redactor.redact("\(a) \(b)"), "[REDACTED] [REDACTED]")
    }
    func testSlack() {
        let t = "xox" + "b-" + "1234567890-" + rep("d", 12)
        XCTAssertEqual(Redactor.redact("slack: \(t)"), "slack: [REDACTED]")
    }
    func testPrivateKeyBlock() {
        let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\n" + rep("Q", 64) + "\n" + rep("R", 20)
            + "\n-----END " + "RSA PRIVATE KEY-----"
        let out = Redactor.redact("before\n\(pem)\nafter")
        XCTAssertEqual(out, "before\n[REDACTED]\nafter")
        let out2 = Redactor.redact("x -----BEGIN " + "PRIVATE KEY-----\n" + rep("Z", 40) + "\n-----END " + "PRIVATE KEY-----")
        XCTAssertEqual(out2, "x [REDACTED]")
    }
    func testJWT() {
        let j = "eyJ" + rep("a", 12) + "." + "eyJ" + rep("b", 12) + "." + rep("c", 20)
        XCTAssertEqual(Redactor.redact("jwt \(j)"), "jwt [REDACTED]")
    }
    func testBearer() {
        let out = Redactor.redact("Authorization: Bearer " + rep("z", 24))
        XCTAssertEqual(out, "Authorization: Bearer [REDACTED]")
    }
    func testRegisteredSecret() {
        let s = "strim-local-" + UUID().uuidString
        XCTAssertEqual(Redactor.redact("a \(s) b"), "a \(s) b")
        Redactor.register(secret: s)
        XCTAssertEqual(Redactor.redact("a \(s) b \(s)"), "a [REDACTED] b [REDACTED]")
        Redactor.register(secret: "")
        XCTAssertEqual(Redactor.redact("plain"), "plain")
    }
    func testRegisterThreadSafe() {
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            Redactor.register(secret: "conc-secret-\(i)-\(UUID().uuidString)")
            _ = Redactor.redact("conc-secret-\(i) text")
        }
    }
    func testNoFalsePositivesOnCode() {
        let code = """
        func task(risk: Int) -> String { let ask = "sk-learn"; return "Bearer token auth" }
        let url = "https://example.com/a.b.c"; let id = "AKIAxyz"; // ghp_ short
        struct Mask { var skeleton_key_value_long_name = 1 }
        let x = foo.bar.baz; print("eyJ")
        """
        XCTAssertEqual(Redactor.redact(code), code)
    }
    func testIdempotent() {
        let t = "AKIA" + rep("B", 16) + " Bearer " + rep("q", 30) + " sk-" + rep("m", 30)
            + " -----BEGIN " + "PRIVATE KEY-----\n" + rep("A", 30) + "\n-----END " + "PRIVATE KEY-----"
        let once = Redactor.redact(t)
        XCTAssertEqual(Redactor.redact(once), once)
        XCTAssertFalse(once.contains("AKIA"))
    }

    func testAWSTemporaryKey() {
        let k = "ASIA" + rep("Q", 16)
        XCTAssertEqual(Redactor.redact("tmp \(k) end"), "tmp [REDACTED] end")
    }
    func testAWSSecretAccessKeyKeepsName() {
        let v = rep("x", 20) + "/" + rep("Y", 19)
        XCTAssertEqual(Redactor.redact("aws_secret_access_key = \(v)"), "aws_secret_access_key = [REDACTED]")
        XCTAssertEqual(Redactor.redact("aws_secret_access_key: \(v)"), "aws_secret_access_key: [REDACTED]")
    }
    func testStripeUnderscoreForms() {
        for p in ["sk_live_", "rk_live_", "sk_test_"] {
            let t = p + rep("a", 24)
            XCTAssertEqual(Redactor.redact("stripe \(t)."), "stripe [REDACTED].", p)
        }
    }
    func testGoogleAPIKey() {
        let k = "AIza" + rep("Z", 35)
        XCTAssertEqual(Redactor.redact("g \(k)."), "g [REDACTED].")
    }
    func testGitLabAndNpmAndGitHubVariants() {
        XCTAssertEqual(Redactor.redact("glpat-" + rep("a", 20)), "[REDACTED]")
        XCTAssertEqual(Redactor.redact("npm_" + rep("b", 36) + " x"), "[REDACTED] x")
        XCTAssertEqual(Redactor.redact("ghu_" + rep("c", 30)), "[REDACTED]")
        XCTAssertEqual(Redactor.redact("ghr_" + rep("d", 30)), "[REDACTED]")
    }
    func testURLCredentialsKeepSchemeAndHost() {
        let u = "postgres://app:" + "hunter2hunter2" + "@db.internal:5432/x?sslmode=require"
        XCTAssertEqual(Redactor.redact("dsn \(u)"), "dsn postgres://[REDACTED]@db.internal:5432/x?sslmode=require")
        XCTAssertEqual(Redactor.redact("see https://example.com/a.b"), "see https://example.com/a.b")
    }
    func testGenericAssignmentRedactsValueKeepsKey() {
        let v = "hunter" + "2hunter2"
        XCTAssertEqual(Redactor.redact("DB_PASSWORD=\(v)"), "DB_PASSWORD=[REDACTED]")
        XCTAssertEqual(Redactor.redact("api_key: \"abc123def456ghi\""), "api_key: \"[REDACTED]\"")
        XCTAssertEqual(Redactor.redact("{\"token\": \"tok" + "en1234567890\"}"), "{\"token\": \"[REDACTED]\"}")
    }
    func testGenericAssignmentNoFalsePositivesOnCode() {
        let code = """
        let token = tokens[i]
        var secret = self.authToken
        let token = nextTokenValue
        password = prompt("enter password")
        token = getTokenValueFromStore()
        secret = "short1"
        """
        XCTAssertEqual(Redactor.redact(code), code)
    }
    func testPrivateKeyManyBeginsNoEndIsLinear() {
        let text = String(repeating: "-----BEGIN PRIVATE KEY-----\n", count: 4000)
        let start = Date()
        let out = Redactor.redact(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(out.contains("BEGIN"))
        XCTAssertEqual(out, "[REDACTED]")
    }
    func testRegisteredSecretVariantsBase64AndPercent() {
        let s = "vk-" + "a+b/c=d f" + UUID().uuidString
        Redactor.register(secret: s)
        let b64 = Data(s.utf8).base64EncodedString()
        let pct = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(Redactor.redact("b64 \(b64) pct \(pct)"), "b64 [REDACTED] pct [REDACTED]")
    }
    func testRegisterStrimTokenFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redactor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("token")
        let tok = "strim-file-" + UUID().uuidString
        try (tok + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(Redactor.registerStrimToken(from: file))
        XCTAssertEqual(Redactor.redact("t \(tok)"), "t [REDACTED]")
        let missing = dir.appendingPathComponent("absent")
        XCTAssertFalse(Redactor.registerStrimToken(from: missing))
    }
    /// Each adversarial 1 MB input must redact in well under a second; the 3 s bound leaves CI headroom.
    private func assertFast(_ name: String, _ input: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let t0 = Date()
        let out = Redactor.redact(input)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertLessThan(dt, 3.0, "\(name) took \(dt)s", file: file, line: line)
        return out
    }
    func testAdversarialOneMBInputsAreLinear() {
        let n = 1_048_576
        _ = assertFast("x run", String(repeating: "x", count: n))
        _ = assertFast("a1 run", String(repeating: "a1", count: n / 2))
        _ = assertFast("colons", String(repeating: ":", count: n))
        _ = assertFast("equals", String(repeating: "=", count: n))
        _ = assertFast("at signs", String(repeating: "@", count: n))
        _ = assertFast("slashes", String(repeating: "/", count: n))
        _ = assertFast("sk- run", String(repeating: "sk-", count: n / 3))
        _ = assertFast("base64 run", String(repeating: "ABCDabcd0123+/", count: n / 14))
        _ = assertFast("many ://", String(repeating: "a://", count: n / 4))
        _ = assertFast("many BEGIN no END", String(repeating: "-----BEGIN PRIVATE KEY-----", count: n / 28))
        _ = assertFast("password= run", String(repeating: "password=", count: n / 9))
        _ = assertFast("token= run", String(repeating: "token=", count: n / 6))
        _ = assertFast("token= long value", "token=" + String(repeating: "a", count: n))
        _ = assertFast("eyJ run", String(repeating: "eyJ", count: n / 3))
        _ = assertFast("Bearer run", String(repeating: "Bearer ", count: n / 7))
        _ = assertFast("token then spaces", "token" + String(repeating: " ", count: n))
        _ = assertFast("ghp_ run", String(repeating: "ghp_", count: n / 4))
    }
    func testAdversarialInputWithManyRegisteredSecrets() {
        for i in 0..<200 { Redactor.register(secret: "budget-secret-\(i)-" + UUID().uuidString) }
        let out = assertFast("x run with secrets", String(repeating: "x", count: 1_048_576))
        XCTAssertEqual(out.count, 1_048_576)
    }
    func testLongTokenValueStillRedacted() {
        let v = "a1" + String(repeating: "b", count: 1000)
        XCTAssertEqual(Redactor.redact("token=\(v) end"), "token=[REDACTED] end")
    }
    func testBoundedWindowsDoNotSplitSecretsInShortInputs() {
        // A secret just under the value bound, preceded by a long non-secret run, is still caught.
        let filler = String(repeating: "x", count: 50_000)
        let secret = "ghp_" + String(repeating: "Q", count: 36)
        XCTAssertEqual(Redactor.redact(filler + " " + secret), filler + " [REDACTED]")
    }
    /// Fails for every 4-character window of `secret` that survives in `out`.
    private func assertNoSecretSlice(_ secret: String, in out: String, file: StaticString = #filePath, line: UInt = #line) {
        let c = Array(secret)
        guard c.count >= 4 else { return }
        for i in 0...(c.count - 4) {
            let slice = String(c[i..<(i + 4)])
            XCTAssertFalse(out.contains(slice), "slice \(slice) of \(secret) survived in \(out)", file: file, line: line)
        }
    }
    func testPrefixSuffixOverlappingSecretsFullyRedacted() {
        let a = "ABCDEFGHIJKLMNOP", b = "IJKLMNOPQRSTUVWX"
        Redactor.register(secret: a)
        Redactor.register(secret: b)
        let out = Redactor.redact("x ABCDEFGHIJKLMNOPQRSTUVWX y")
        XCTAssertEqual(out, "x [REDACTED] y")
        assertNoSecretSlice(a, in: out)
        assertNoSecretSlice(b, in: out)
    }
    func testSecretOverlappingRegexTokenIsFullyRedacted() {
        // The ghp_ token covers [0, 34); the registered secret starts inside it and runs past its end.
        let secret = "AAAAAAAAAAtail-9xQ"
        Redactor.register(secret: secret)
        let out = Redactor.redact("ghp_" + String(repeating: "A", count: 30) + "tail-9xQ")
        XCTAssertEqual(out, "[REDACTED]")
        assertNoSecretSlice("tail-9xQ", in: out)
    }
    func testAdjacentMatchesLeaveNoSlice() {
        let one = "AdjOne-123456", two = "AdjTwo-789012"
        Redactor.register(secret: one)
        Redactor.register(secret: two)
        let out = Redactor.redact(one + two)
        XCTAssertEqual(out, "[REDACTED]")
        assertNoSecretSlice(one, in: out)
        assertNoSecretSlice(two, in: out)
    }
    func testRawAndBase64VariantBothRedacted() {
        let raw = "Overlap-Raw-42" + UUID().uuidString
        Redactor.register(secret: raw)
        let b64 = Data(raw.utf8).base64EncodedString()
        let out = Redactor.redact("pre \(raw) mid \(b64) post")
        XCTAssertEqual(out, "pre [REDACTED] mid [REDACTED] post")
        assertNoSecretSlice(raw, in: out)
    }
    func testOverlapAcrossMultibyteCharactersKeepsOffsetsRight() {
        // UTF-16 offsets: an emoji (surrogate pair) before the secret must not shift the redacted range.
        let secret = "MultiByte-Secret-77"
        Redactor.register(secret: secret)
        XCTAssertEqual(Redactor.redact("\u{1F600} café \(secret) ✓ ghp_" + String(repeating: "z", count: 25)),
                       "\u{1F600} café [REDACTED] ✓ [REDACTED]")
    }
}
