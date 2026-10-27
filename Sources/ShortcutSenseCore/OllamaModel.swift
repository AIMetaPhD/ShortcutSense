import Foundation

/// A model advertised by the local Ollama service.
public struct OllamaModel: Equatable, Sendable, Identifiable {
    public let name: String
    public let sizeBytes: Int64
    public let family: String?

    public var id: String { name }

    /// Ollama can serve some models from its own cloud. A model whose name carries
    /// the cloud marker is therefore not guaranteed to execute on this machine.
    public var isLocallyExecutable: Bool {
        OllamaModelPolicy.isLocallyExecutable(name)
    }

    public init(name: String, sizeBytes: Int64, family: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.family = family
    }
}

/// Decides which models this product is willing to send data to.
///
/// Loopback is necessary but not sufficient: `127.0.0.1:11434` is a proxy in front of
/// whatever Ollama decides to run, and Ollama's cloud models are served under names
/// carrying a `-cloud` suffix. Sending an aggregate payload to such a model would
/// break the "fully offline" promise while every URL check still passed.
///
/// This is a name-based check because it is the only locality signal Ollama exposes
/// without inspecting server configuration. It is deliberately conservative: a name
/// it cannot classify is treated as not local.
public enum OllamaModelPolicy {
    /// Markers Ollama uses for models executed remotely.
    private static let cloudMarkers = ["-cloud", ":cloud", "cloud/"]

    public static func isLocallyExecutable(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard !lowered.isEmpty else { return false }
        return !cloudMarkers.contains { lowered.contains($0) }
    }

    /// Models safe to offer, preserving the service's ordering.
    public static func locallyExecutable(from models: [OllamaModel]) -> [OllamaModel] {
        models.filter(\.isLocallyExecutable)
    }

    /// Human-readable reason shown next to a rejected model.
    public static func rejectionReason(_ name: String) -> String? {
        isLocallyExecutable(name) ? nil : "This model is served by Ollama Cloud, not from this Mac."
    }
}

/// Parses `GET /api/tags`.
public enum OllamaTagsParser {
    public static func parse(_ data: Data) throws -> [OllamaModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [[String: Any]] else {
            throw AIError.invalidResponse
        }
        return rawModels.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            let details = entry["details"] as? [String: Any]
            return OllamaModel(name: name, sizeBytes: size,
                               family: details?["family"] as? String)
        }
    }
}

/// Extracts the JSON object from a model response that may be wrapped in prose or
/// markdown fences.
///
/// Local models routinely answer with ```json … ``` or with a sentence before the
/// object. Rejecting those outright would make the feature look broken for models
/// that are otherwise perfectly usable, so the object is extracted first and then
/// validated against the same strict schema.
public enum JSONResponseExtractor {
    public static func extractObject(from text: String) -> Data? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // Strip a fenced block if present.
        if let fenceStart = candidate.range(of: "```") {
            var rest = String(candidate[fenceStart.upperBound...])
            if let newline = rest.firstIndex(of: "\n") {
                rest = String(rest[rest.index(after: newline)...])
            }
            if let fenceEnd = rest.range(of: "```") {
                rest = String(rest[..<fenceEnd.lowerBound])
            }
            candidate = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(candidate[start...end])
        return slice.data(using: .utf8)
    }
}
