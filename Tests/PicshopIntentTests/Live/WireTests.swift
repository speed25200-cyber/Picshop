import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class JSONValueTests: XCTestCase {
    func testStrictParseRejectsWhatRFC8259Rejects() {
        let invalid = [
            "{\"a\":1,}", "[1,]", "{\"a\":1} x", "[1][2]", "NaN", "[NaN]", "[Infinity]", "[1e400]", "[01]", "[.5]", "[1.]", "[+1]", "{'a':1}",
            "[\"\\ud800\"]", "[\"a\u{01}b\"]", "{\"a\":1,\"a\":2}", "// c\n[1]", "", "   ", "[\"\\x41\"]", "{\"a\" 1}", "[true false]", "tru", "[\"unterminated]",
        ]
        for text in invalid {
            XCTAssertThrowsError(try JSONValue.parse(text), text.debugDescription)
        }
    }

    func testStrictParseAcceptsValidJSON() throws {
        XCTAssertEqual(try JSONValue.parse(" {\"a\" : [1, -0.5, 2e3, true, null, \"é\\u00e9\\ud83d\\ude00\\n\"]} \n"),
                       ["a": [1, -0.5, 2000, true, nil, "éé😀\n"]])
        XCTAssertEqual(try JSONValue.parse("1"), 1)
        XCTAssertEqual(try JSONValue.parse("\"x\\/y\""), "x/y")
        XCTAssertEqual(try JSONValue.parse("[]"), [])
        XCTAssertEqual(try JSONValue.parse("{}"), [:])
    }

    func testGoldenSerialization() {
        let value: JSONValue = [
            "zeta": 1, "alpha": ["b": 2.5, "a": -3], "Émile": "raw é 😀 / \"quoted\" \\ back",
            "big": 9_007_199_254_740_991, "huge": 1e16, "small": 0.1, "neg": -0.0, "ctl": "\u{01}\u{1F}\t\n\r\u{08}\u{0C}", "list": [nil, false, true],
        ]
        let expected = #"{"alpha":{"a":-3,"b":2.5},"big":9007199254740991,"ctl":"\u0001\u001f\t\n\r\b\f","huge":1e+16,"list":[null,false,true],"neg":0,"small":0.1,"zeta":1,"Émile":"raw é 😀 / \"quoted\" \\ back"}"#
        XCTAssertEqual(value.serialized(), expected)
    }

    func testKeysSortByUTF8Bytes() {
        let value: JSONValue = ["b": 1, "B": 2, "é": 3, "e": 4, "_": 5]
        XCTAssertEqual(value.serialized(), #"{"B":2,"_":5,"b":1,"e":4,"é":3}"#)
    }

    func testRoundTrips() throws {
        let values: [JSONValue] = [
            ["steps": [["action": "adjust", "amount": 15, "parameter": "temperature"]]],
            ["text": "Ligne 1\nLigne « 2 »\t\"fin\"", "n": 1.25, "deep": [[[["x": nil]]]]],
            "😀", 0, -12.75, true,
        ]
        for value in values {
            let text = value.serialized()
            XCTAssertEqual(try JSONValue.parse(text), value, text)
            XCTAssertEqual(try JSONValue.parse(text).serialized(), text)
        }
    }

    func testAccessors() {
        let value: JSONValue = ["n": 3, "f": 1.5, "s": "x", "b": true, "a": [1], "o": ["k": nil]]
        XCTAssertEqual(value["n"]?.int, 3)
        XCTAssertNil(value["f"]?.int)
        XCTAssertEqual(value["f"]?.double, 1.5)
        XCTAssertEqual(value["s"]?.string, "x")
        XCTAssertEqual(value["b"]?.bool, true)
        XCTAssertEqual(value["a"]?.array?.count, 1)
        XCTAssertEqual(value["o"]?.object?["k"], .null)
        XCTAssertNil(value["missing"])
    }
}
