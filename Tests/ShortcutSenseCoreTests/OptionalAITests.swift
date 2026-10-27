import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-15 / AC-16: AI is optional, loopback-only, schema-limited and fail-safe.
final class OptionalAITests: XCTestCase {
    private let request = AIExplanationRequest(
        type: "launch_focus", appName: "Google Chrome", observedActivations7d: 12,
        originLabel: "unknown_origin", activeDays: 4,
        proposedShortcut: "Control+Option+Shift+C",
        conflictStatus: "no_known_conflict", confidence: "heuristic")

    private final class RecordingTransport: AITransport, @unchecked Sendable {
        var response: Data
        var error: Error?
        private(set) var calls: [URL] = []
        private(set) var lastBody: Data?

        init(response: Data = Data(), error: Error? = nil) {
            self.response = response; self.error = error
        }

        func post(_ body: Data, to url: URL, timeout: TimeInterval) throws -> Data {
            calls.append(url)
            lastBody = body
            if let error { throw error }
            return response
        }
    }

    private func validResponse() -> Data {
        Data(#"{"reason":"Frequent switching","explanation":"You switch often.","category":"efficiency"}"#.utf8)
    }

    // MARK: - Disabled by default

    func testDisabledMakesNoNetworkCall() {
        let transport = RecordingTransport(response: validResponse())
        let ai = OptionalAI(transport: transport)
        XCTAssertThrowsError(try ai.explain(request, enabled: false,
                                            endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!)) { error in
            XCTAssertEqual(error as? AIError, .disabled)
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - Loopback only

    func testNonLoopbackEndpointIsRefused() {
        for host in ["http://192.168.1.10:11434", "https://127.0.0.1:11434",
                     "http://example.com:11434", "http://0.0.0.0:11434",
                     "http://localhost:11434"] {
            let transport = RecordingTransport(response: validResponse())
            let ai = OptionalAI(transport: transport)
            XCTAssertThrowsError(try ai.explain(request, enabled: true, endpoint: URL(string: host)!)) { error in
                XCTAssertEqual(error as? AIError, .nonLoopbackEndpoint, "endpoint \(host) must be refused")
            }
            XCTAssertTrue(transport.calls.isEmpty, "no request may leave the machine for \(host)")
        }
    }

    func testLoopbackEndpointsAreAccepted() throws {
        for host in ["http://127.0.0.1:11434/api/generate", "http://[::1]:11434/api/generate"] {
            let transport = RecordingTransport(response: validResponse())
            let ai = OptionalAI(transport: transport)
            _ = try ai.explain(request, enabled: true, endpoint: URL(string: host)!)
            XCTAssertEqual(transport.calls.count, 1)
        }
    }

    /// `localhost` is resolved through /etc/hosts, so accepting it would reintroduce a
    /// name-resolution step the app cannot verify. Only literal loopback is allowed.
    func testLocalhostHostnameIsRefused() {
        let transport = RecordingTransport(response: validResponse())
        let ai = OptionalAI(transport: transport)
        XCTAssertThrowsError(try ai.explain(request, enabled: true,
                                            endpoint: URL(string: "http://localhost:11434")!)) { error in
            XCTAssertEqual(error as? AIError, .nonLoopbackEndpoint)
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - Payload whitelist

    func testPayloadContainsOnlyWhitelistedFields() throws {
        let transport = RecordingTransport(response: validResponse())
        let ai = OptionalAI(transport: transport)
        _ = try ai.explain(request, enabled: true,
                           endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!)
        let body = String(decoding: try XCTUnwrap(transport.lastBody), as: UTF8.self)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let allowed: Set<String> = ["type", "app_name", "observed_activations_7d", "origin_label",
                                    "active_days", "proposed_shortcut", "conflict_status",
                                    "confidence", "estimated_minutes_saved"]
        XCTAssertTrue(Set(object.keys).isSubset(of: allowed), "unexpected field in AI payload")
        XCTAssertEqual(object["origin_label"] as? String, "unknown_origin")
        // Time savings are never measured, so the field is either absent or null —
        // never a number the model could repeat as fact.
        let savings = object["estimated_minutes_saved"]
        XCTAssertTrue(savings == nil || savings is NSNull,
                      "estimated_minutes_saved must never carry a fabricated value")
    }

    // MARK: - Malformed model output

    func testMalformedJSONFallsBackToTemplate() {
        let transport = RecordingTransport(response: Data("not json at all".utf8))
        let ai = OptionalAI(transport: transport)
        XCTAssertThrowsError(try ai.explain(request, enabled: true,
                                            endpoint: URL(string: "http://127.0.0.1:11434")!)) { error in
            XCTAssertEqual(error as? AIError, .invalidResponse)
        }
        // The deterministic template is always available as the fallback.
        let template = OptionalAI.template(for: request)
        XCTAssertFalse(template.explanation.isEmpty)
        XCTAssertEqual(template.category, .efficiency)
    }

    func testExtraFieldsAreRejected() {
        let payload = Data(#"{"reason":"a","explanation":"b","category":"other","command":"rm -rf /"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .unexpectedFields)
        }
    }

    func testUnknownCategoryIsRejected() {
        let payload = Data(#"{"reason":"a","explanation":"b","category":"hack"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .invalidResponse)
        }
    }

    func testOversizedResponseIsRejected() {
        let huge = String(repeating: "a", count: OptionalAI.maximumResponseBytes + 1)
        let payload = Data(#"{"reason":"a","explanation":"\#(huge)","category":"other"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .responseTooLong)
        }
    }

    func testOversizedTransportResponseIsRejectedBeforeParsing() {
        let transport = RecordingTransport(response: Data(repeating: 0x41,
                                                         count: OptionalAI.maximumResponseBytes + 1))
        let ai = OptionalAI(transport: transport)
        XCTAssertThrowsError(try ai.explain(request, enabled: true,
                                            endpoint: URL(string: "http://127.0.0.1:11434")!)) { error in
            XCTAssertEqual(error as? AIError, .responseTooLong)
        }
    }

    func testExecutableLookingTextIsRejected() {
        let payload = Data(#"{"reason":"a","explanation":"Run sudo rm -rf /tmp","category":"other"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .unsafeContent)
        }
    }

    func testOllamaEnvelopeIsUnwrapped() throws {
        let inner = #"{\"reason\":\"r\",\"explanation\":\"e\",\"category\":\"consistency\"}"#
        let envelope = Data(#"{"model":"qwen","response":"\#(inner)","done":true}"#.utf8)
        let parsed = try OptionalAI.parse(envelope)
        XCTAssertEqual(parsed.category, .consistency)
    }

    func testTransportFailureIsReportedAndTemplateRemainsAvailable() {
        let transport = RecordingTransport(error: AIError.transport("connection refused"))
        let ai = OptionalAI(transport: transport)
        XCTAssertThrowsError(try ai.explain(request, enabled: true,
                                            endpoint: URL(string: "http://127.0.0.1:11434")!))
        XCTAssertFalse(OptionalAI.template(for: request).explanation.isEmpty)
    }

    // MARK: - Core does not depend on AI

    func testTemplateNeverClaimsUnknownOriginWasAClick() {
        let template = OptionalAI.template(for: request)
        XCTAssertFalse(template.explanation.lowercased().contains("click"))
        XCTAssertFalse(template.explanation.lowercased().contains("dock"))
        XCTAssertTrue(template.explanation.contains("not known"))
    }
}

/// Endpoint normalisation must never be able to turn a loopback URL into a remote one.
final class EndpointNormalisationTests: XCTestCase {
    func testBareHostBecomesGeneratePath() {
        let bare = URL(string: "http://127.0.0.1:11434")!
        XCTAssertEqual(OptionalAI.generateEndpoint(from: bare).absoluteString,
                       "http://127.0.0.1:11434/api/generate")
    }

    func testRootPathBecomesGeneratePath() {
        let root = URL(string: "http://127.0.0.1:11434/")!
        XCTAssertEqual(OptionalAI.generateEndpoint(from: root).absoluteString,
                       "http://127.0.0.1:11434/api/generate")
    }

    func testFullPathIsUnchanged() {
        let full = URL(string: "http://127.0.0.1:11434/api/generate")!
        XCTAssertEqual(OptionalAI.generateEndpoint(from: full), full)
        let custom = URL(string: "http://127.0.0.1:8080/v1/chat")!
        XCTAssertEqual(OptionalAI.generateEndpoint(from: custom), custom)
    }

    func testNormalisedEndpointStaysLoopback() {
        for raw in ["http://127.0.0.1:11434", "http://[::1]:11434"] {
            let normalised = OptionalAI.generateEndpoint(from: URL(string: raw)!)
            XCTAssertTrue(OptionalAI.isLoopback(normalised), "\(raw) must stay loopback after normalisation")
        }
    }

    func testRemoteEndpointStaysRejectedAfterNormalisation() {
        let remote = URL(string: "http://192.168.1.10:11434")!
        XCTAssertFalse(OptionalAI.isLoopback(OptionalAI.generateEndpoint(from: remote)))
    }
}

/// Independent review findings (Muse, 2026-10-26): the fallback parameter was never
/// returned, and only the explanation was checked for executable-looking text.
final class AISafetyGapTests: XCTestCase {
    private let request = AIExplanationRequest(
        type: "launch_focus", appName: "Chrome", observedActivations7d: 9,
        originLabel: "unknown_origin", activeDays: 3,
        proposedShortcut: "Control+Option+Shift+C",
        conflictStatus: "no_known_conflict", confidence: "heuristic")

    func testParseThrowsInsteadOfSilentlyReturningTheTemplate() {
        // A malformed answer must never be presented as if the model said it.
        XCTAssertThrowsError(try OptionalAI.parse(Data("not json".utf8)))
        let withExtra = Data(#"{"reason":"a","explanation":"b","category":"other","x":1}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(withExtra))
    }

    func testExecutableTextInReasonIsAlsoRejected() {
        let payload = Data(#"{"reason":"run defaults write com.x y","explanation":"fine","category":"other"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .unsafeContent,
                           "reason is rendered too, so it needs the same check")
        }
    }

    func testExecutableTextInExplanationStillRejected() {
        let payload = Data(#"{"reason":"fine","explanation":"paste osascript -e x","category":"other"}"#.utf8)
        XCTAssertThrowsError(try OptionalAI.parse(payload)) { error in
            XCTAssertEqual(error as? AIError, .unsafeContent)
        }
    }

    func testCleanAnswerStillParses() throws {
        let payload = Data(#"{"reason":"frequent switching","explanation":"A shortcut may help.","category":"efficiency"}"#.utf8)
        let parsed = try OptionalAI.parse(payload)
        XCTAssertEqual(parsed.category, .efficiency)
    }

    func testCallerGetsTemplateWhenParseFails() {
        // This is the documented contract: explain() propagates the error, and the
        // app layer substitutes template(for:). Verify the template is reachable.
        XCTAssertFalse(OptionalAI.template(for: request).explanation.isEmpty)
        XCTAssertThrowsError(try OptionalAI.parse(Data("{}".utf8)))
    }
}
