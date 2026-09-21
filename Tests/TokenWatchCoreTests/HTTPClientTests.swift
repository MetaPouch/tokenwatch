import XCTest
@testable import TokenWatchCore

final class HTTPClientTests: XCTestCase {
    /// Anthropic's actual shape (confirmed against a live 401 response): `error` nests the
    /// human message under its own `message` field, alongside a `type` this extraction ignores.
    func testExtractsNestedAnthropicStyleErrorMessage() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired. Re-authenticate to continue."},"request_id":null}"#
        let data = Data(body.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), "OAuth access token has expired. Re-authenticate to continue.")
    }

    /// Most OpenAI-compatible APIs (OpenRouter, z.ai, Kimi, ...) share this same nested shape.
    func testExtractsNestedOpenAIStyleErrorMessage() {
        let body = #"{"error":{"message":"Invalid API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let data = Data(body.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), "Invalid API key provided")
    }

    func testExtractsFlatMessageField() {
        let data = Data(#"{"message":"Rate limit exceeded"}"#.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), "Rate limit exceeded")
    }

    /// A body that parses as the common shape but carries no usable message string still falls
    /// back to the raw text, rather than surfacing `nil` and losing the error entirely.
    func testFallsBackToRawBodyWhenNoMessageFieldMatches() {
        let data = Data(#"{"status":"unavailable"}"#.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), #"{"status":"unavailable"}"#)
    }

    func testFallsBackToRawBodyForNonJSONText() {
        let data = Data("Service Unavailable".utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), "Service Unavailable")
    }

    func testRawBodyFallbackIsTruncatedTo200Characters() {
        let longText = String(repeating: "x", count: 500)
        let data = Data(longText.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data)?.count, 200)
    }

    func testEmptyMessageFieldFallsBackToRawBody() {
        let body = #"{"error":{"message":""}}"#
        let data = Data(body.utf8)
        XCTAssertEqual(HTTPClient.errorMessage(from: data), body)
    }
}
