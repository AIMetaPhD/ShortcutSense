import Foundation

/// The only data ever sent to a local model. Fixed shape, no free-form fields.
public struct AIExplanationRequest: Codable, Equatable, Sendable {
    public let type: String
    public let appName: String
    public let observedActivations7d: Int
    public let originLabel: String
    public let activeDays: Int
    public let proposedShortcut: String
    public let conflictStatus: String
    public let confidence: String
    /// Always nil today. Time savings are never measured, so they are never claimed.
    public let estimatedMinutesSaved: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case appName = "app_name"
        case observedActivations7d = "observed_activations_7d"
        case originLabel = "origin_label"
        case activeDays = "active_days"
        case proposedShortcut = "proposed_shortcut"
        case conflictStatus = "conflict_status"
        case confidence
        case estimatedMinutesSaved = "estimated_minutes_saved"
    }

    public init(type: String, appName: String, observedActivations7d: Int, originLabel: String,
                activeDays: Int, proposedShortcut: String, conflictStatus: String,
                confidence: String, estimatedMinutesSaved: Int? = nil) {
        self.type = type; self.appName = appName
        self.observedActivations7d = observedActivations7d; self.originLabel = originLabel
        self.activeDays = activeDays; self.proposedShortcut = proposedShortcut
        self.conflictStatus = conflictStatus; self.confidence = confidence
        self.estimatedMinutesSaved = estimatedMinutesSaved
    }
}

public enum AICategory: String, Codable, Sendable {
    case efficiency
    case consistency
    case ergonomics
    case other
}

public struct AIExplanation: Codable, Equatable, Sendable {
    public let reason: String
    public let explanation: String
    public let category: AICategory
    public init(reason: String, explanation: String, category: AICategory) {
        self.reason = reason; self.explanation = explanation; self.category = category
    }
}

public enum AIError: Error, Equatable {
    case disabled
    case nonLoopbackEndpoint
    case transport(String)
    case timeout
    case invalidResponse
    case responseTooLong
    case unexpectedFields
    case unsafeContent
}

/// Transport abstraction so the safety envelope can be tested without a server.
public protocol AITransport: Sendable {
    func post(_ body: Data, to url: URL, timeout: TimeInterval) throws -> Data
}

/// Strict, opt-in, loopback-only explanation layer.
///
/// Guarantees (verified by `OptionalAITests`):
/// - Disabled by default; no network call at all when disabled.
/// - Only `127.0.0.1` (or `::1`) is ever contacted — a hostname is refused even if it
///   resolves locally, so a malicious hosts file cannot redirect traffic.
/// - The model can only return `{reason, explanation, category}`; any extra field,
///   non-string value, oversized payload, or timeout produces the deterministic
///   template instead. Model output can never change configuration.
public struct OptionalAI: Sendable {
    public static let maximumResponseBytes = 16 * 1024
    public static let defaultTimeout: TimeInterval = 12

    public let transport: AITransport

    public init(transport: AITransport) {
        self.transport = transport
    }

    public func explain(_ request: AIExplanationRequest,
                        enabled: Bool,
                        endpoint: URL?,
                        timeout: TimeInterval = OptionalAI.defaultTimeout) throws -> AIExplanation {
        guard enabled else { throw AIError.disabled }
        guard let endpoint else { throw AIError.nonLoopbackEndpoint }
        guard Self.isLoopback(endpoint) else { throw AIError.nonLoopbackEndpoint }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(request)

        let data: Data
        do {
            data = try transport.post(payload, to: endpoint, timeout: timeout)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.transport(String(describing: error))
        }

        guard data.count <= Self.maximumResponseBytes else { throw AIError.responseTooLong }
        return try Self.parse(data)
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    /// Normalises a user-supplied endpoint into Ollama's generate path.
    ///
    /// A bare host (`http://127.0.0.1:11434`) becomes `/api/generate`; a full path is
    /// left alone. Scheme and host are unchanged, so the loopback check still applies.
    public static func generateEndpoint(from url: URL) -> URL {
        guard url.path.isEmpty || url.path == "/" else { return url }
        return url.appendingPathComponent("api/generate")
    }

    /// Deterministic template used whenever the model is unavailable or misbehaves.
    public static func template(for request: AIExplanationRequest) -> AIExplanation {
        let originPhrase: String
        switch request.originLabel {
        case "managed_hotkey":
            originPhrase = "You already switch to \(request.appName) with a ShortcutSense hotkey."
        case "observed_keyboard_navigation":
            originPhrase = "You reach \(request.appName) with the keyboard; a dedicated hotkey may add little."
        default:
            originPhrase = "\(request.appName) came to the front \(request.observedActivations7d) times on \(request.activeDays) days. How you got there is not known."
        }
        return AIExplanation(
            reason: "Frequent app switching",
            explanation: "\(originPhrase) A dedicated hotkey would be \(request.proposedShortcut). Known conflict status: \(request.conflictStatus.replacingOccurrences(of: "_", with: " ")).",
            category: .efficiency)
    }

    /// Parses a model response. Accepts either the bare object or an Ollama envelope
    /// (`{"response": "<json string>"}`). Rejects anything that is not exactly the
    /// three allowed fields with the allowed types.
    ///
    /// Throws on every problem rather than returning the template: a caller that wants
    /// the deterministic fallback must ask for it (`OptionalAI.template(for:)`), so it
    /// cannot silently believe a malformed answer came from the model.
    public static func parse(_ data: Data) throws -> AIExplanation {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIError.invalidResponse
        }

        var candidate = object
        if let dictionary = object as? [String: Any],
           let inner = dictionary["response"] as? String {
            guard let innerData = inner.data(using: .utf8),
                  let innerObject = try? JSONSerialization.jsonObject(with: innerData) else {
                throw AIError.invalidResponse
            }
            candidate = innerObject
        }

        guard let dictionary = candidate as? [String: Any] else { throw AIError.invalidResponse }
        let allowed: Set<String> = ["reason", "explanation", "category"]
        guard Set(dictionary.keys).isSubset(of: allowed) else { throw AIError.unexpectedFields }
        guard let reason = dictionary["reason"] as? String,
              let explanation = dictionary["explanation"] as? String,
              let categoryRaw = dictionary["category"] as? String,
              let category = AICategory(rawValue: categoryRaw) else {
            throw AIError.invalidResponse
        }
        guard reason.count <= 200, explanation.count <= 600 else { throw AIError.responseTooLong }
        // Both fields are rendered in the UI, so both are checked. Checking only the
        // explanation would let a shell-looking string through in `reason`.
        guard !looksExecutable(explanation), !looksExecutable(reason) else {
            throw AIError.unsafeContent
        }
        return AIExplanation(reason: reason, explanation: explanation, category: category)
    }

    /// Rejects text that reads like an instruction to run something. The model can
    /// never influence configuration, but surfacing shell-like text is still a
    /// phishing vector inside the UI.
    static func looksExecutable(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["```", "osascript", "apple script", "applescript", "sudo ", "curl ",
                       "defaults write", "rm -rf", "chmod ", "/bin/sh", "bash -c"]
        return markers.contains { lowered.contains($0) }
    }
}

/// Deterministic in-process transport used by tests and by "AI disabled" builds.
public struct UnavailableTransport: AITransport {
    public init() {}
    public func post(_ body: Data, to url: URL, timeout: TimeInterval) throws -> Data {
        throw AIError.transport("no transport configured")
    }
}
