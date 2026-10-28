import Foundation
import Testing
@testable import StrimTemplate

@Test func jsonPreservesKeyOrderAndSerializesLikePython() throws {
    let src = #"{"z": 1, "a": {"y": [1, 2.0, 1e-07, 1e+16, true, null], "b": "x"}, "m": "café 😀"}"#
    let v = try OrderedJSON.parse(src)
    #expect(v.members?.map(\.key) == ["z", "a", "m"])
    #expect(v.serialized() == #"{"z": 1, "a": {"y": [1, 2.0, 1e-07, 1e+16, true, null], "b": "x"}, "m": "café 😀"}"#)
}

@Test func serializerEscapesLikeTojsonWithEnsureAsciiFalse() {
    let s = OrderedJSON.string("q\" b\\ n\n r\r t\t bs\u{08} ff\u{0C} c\u{01}\u{1f} del\u{7f} <>&' é😀 \u{2028}")
    #expect(s.serialized() == "\"q\\\" b\\\\ n\\n r\\r t\\t bs\\b ff\\f c\\u0001\\u001f del\u{7f} <>&' é😀 \u{2028}\"")
}

@Test func floatReprMatchesCPython() {
    let cases: [(Double, String)] = [
        (1.0, "1.0"), (2.5, "2.5"), (0.1, "0.1"), (1e-7, "1e-07"), (1e16, "1e+16"), (1e15, "1000000000000000.0"),
        (0.0001, "0.0001"), (0.00001, "1e-05"), (123456789.123456789, "123456789.12345679"), (1e22, "1e+22"),
        (-0.0, "-0.0"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (100.0, "100.0"),
        (1234567890123456.0, "1234567890123456.0"), (12345678901234567.0, "1.2345678901234568e+16"), (-2.5e-5, "-2.5e-05"),
    ]
    for (d, want) in cases { #expect(OrderedJSON.double(d).serialized() == want, "\(d)") }
}

@Test func parserMatchesPythonLoads() throws {
    #expect(try OrderedJSON.parse("12345678901234567890") == .bigInt("12345678901234567890"))
    #expect(try OrderedJSON.parse(#"{"a": 1, "b": 2, "a": 3}"#).serialized() == #"{"a": 3, "b": 2}"#)
    #expect(try OrderedJSON.parse(" [1,2 , {\"k\":null}] ").serialized() == #"[1, 2, {"k": null}]"#)
    for bad in ["{", "[1,]", "01", "{'a':1}", "\"\u{01}\"", "1 2", "", "tru"] {
        #expect(throws: (any Error).self) { try OrderedJSON.parse(bad) }
    }
}
