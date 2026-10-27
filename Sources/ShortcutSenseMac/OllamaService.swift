import AppKit
import Foundation
import ShortcutSenseCore

/// Refuses every HTTP redirect.
///
/// `OptionalAI.isLoopback` checks the URL we ask for. Without this delegate a server
/// on 127.0.0.1 could answer `302 Location: https://elsewhere` and URLSession would
/// send the aggregate payload there — the loopback guarantee would hold for the
/// request line and fail for the actual destination.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Talks to a local Ollama instance.
///
/// Design constraints from the fix request:
/// - Discovery is `GET /api/tags`; nothing about a model name is hard-coded.
/// - Every call is async and cancellable, with a bounded timeout, so a slow or hung
///   server cannot freeze SwiftUI.
/// - Only `127.0.0.1:11434` is contacted, and only models that are not Ollama Cloud.
/// - Nothing is logged: no prompt text, no token, no response body.
actor OllamaService {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    enum Status: Equatable {
        case disabled
        /// Service reachable, models available.
        case connected([OllamaModel])
        /// Service reachable but every advertised model is cloud-hosted.
        case connectedCloudOnly([OllamaModel])
        /// The Ollama app is installed but nothing is listening.
        case installedNotRunning
        /// Not reachable and no app found to start.
        case notInstalled
        case failed(String)

        var isUsable: Bool {
            if case .connected(let models) = self { return !models.isEmpty }
            return false
        }

        var models: [OllamaModel] {
            switch self {
            case .connected(let models), .connectedCloudOnly(let models): return models
            default: return []
            }
        }
    }

    struct DiscoveryReport: Equatable {
        let status: Status
        let latencyMilliseconds: Int
        let checkedAt: Date
    }

    struct GenerationOutcome: Equatable {
        let explanation: AIExplanation
        let model: String
        let latencyMilliseconds: Int
        /// True when the value came from the deterministic template because the
        /// model was unavailable, refused, or returned something invalid.
        let usedFallback: Bool
        let fallbackReason: String?
    }

    private let baseURL: URL
    private let session: URLSession
    /// Discovery must fail fast: a closed port should not make the user wait.
    private let discoveryTimeout: TimeInterval
    /// Generation needs a long budget: measured on a real Mac, the first request to a
    /// 9B model took 12.6 s because Ollama loads the weights before answering. A
    /// short timeout reported that as "the model did not answer", which was wrong.
    private let generationTimeout: TimeInterval

    init(baseURL: URL = OllamaService.defaultBaseURL,
         discoveryTimeout: TimeInterval = 3,
         generationTimeout: TimeInterval = 90) {
        self.baseURL = baseURL
        self.discoveryTimeout = discoveryTimeout
        self.generationTimeout = generationTimeout
        let timeout = generationTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Redirects are refused: a local server answering 302 could otherwise move
        // the payload to another host after the loopback check had passed.
        self.session = URLSession(configuration: configuration,
                                  delegate: NoRedirectSessionDelegate(),
                                  delegateQueue: nil)
    }

    // MARK: - Discovery

    func discover() async -> DiscoveryReport {
        let started = Date()
        do {
            let data = try await get(path: "/api/tags", timeout: discoveryTimeout)
            let models = try OllamaTagsParser.parse(data)
            let local = OllamaModelPolicy.locallyExecutable(from: models)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if local.isEmpty {
                return DiscoveryReport(status: models.isEmpty ? .failed("No models installed")
                                                              : .connectedCloudOnly(models),
                                       latencyMilliseconds: elapsed, checkedAt: Date())
            }
            return DiscoveryReport(status: .connected(local),
                                   latencyMilliseconds: elapsed, checkedAt: Date())
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            // A refused endpoint is not the same as "not installed": saying so would
            // send the user installing software when the real problem is the URL.
            if let aiError = error as? AIError, aiError == .nonLoopbackEndpoint {
                return DiscoveryReport(status: .failed("The endpoint is not loopback"),
                                       latencyMilliseconds: elapsed, checkedAt: Date())
            }
            let installed = OllamaInstallation.isAppInstalled
            return DiscoveryReport(
                status: installed ? .installedNotRunning : .notInstalled,
                latencyMilliseconds: elapsed, checkedAt: Date())
        }
    }

    /// Starts the Ollama app the user already installed, then polls until the service
    /// answers. Only called after the user explicitly allowed it.
    func startInstalledAppAndWait(attempts: Int = 12,
                                  interval: Duration = .milliseconds(500)) async -> DiscoveryReport {
        guard let url = OllamaInstallation.appURL else {
            return DiscoveryReport(status: .notInstalled, latencyMilliseconds: 0, checkedAt: Date())
        }
        _ = url
        await OllamaInstallation.launchApp()
        for _ in 0..<attempts {
            if Task.isCancelled { break }
            let report = await discover()
            if case .connected = report.status { return report }
            try? await Task.sleep(for: interval)
        }
        return await discover()
    }

    // MARK: - Generation

    func explain(_ request: AIExplanationRequest, model: String) async -> GenerationOutcome {
        let started = Date()
        func fallback(_ reason: String) -> GenerationOutcome {
            GenerationOutcome(explanation: OptionalAI.template(for: request),
                              model: model,
                              latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                              usedFallback: true, fallbackReason: reason)
        }

        guard OllamaModelPolicy.isLocallyExecutable(model) else {
            return fallback("This model is hosted by Ollama Cloud, not on this Mac.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(request) else {
            return fallback("Could not encode the request.")
        }

        let prompt = """
        You explain, in one short paragraph, why an application shortcut suggestion \
        might help. Reply with JSON only, containing exactly these three keys and \
        nothing else: {"reason": string, "explanation": string, "category": one of \
        "efficiency"|"consistency"|"ergonomics"|"other"}. Never suggest commands, \
        scripts or configuration changes.

        Data:
        \(String(decoding: payload, as: UTF8.self))
        """

        // `think: false` matters for reasoning models (qwen3 and later): with thinking
        // enabled they spend the whole token budget on hidden reasoning and return an
        // empty `response`. Measured on a real Mac with qwen3.5:9b, which produced an
        // empty string until thinking was disabled.
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "think": false,
            // Reasoning models spend tokens on hidden thinking before the answer, so
            // the budget has to cover both. 400 was measured to run out on qwen3.5:9b.
            "options": ["temperature": 0.2, "num_predict": 1200],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return fallback("Could not build the request.")
        }

        do {
            let data = try await post(path: "/api/generate", body: bodyData,
                                      timeout: generationTimeout)
            // The size cap applies to the *answer*, not to Ollama's envelope: a
            // reasoning model puts far more than 16 KiB of hidden `thinking` in the
            // envelope even when the final `response` is three short fields.
            let candidate: Data
            if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = envelope["response"] as? String {
                candidate = Data(inner.utf8)
            } else {
                candidate = data
            }
            guard candidate.count <= OptionalAI.maximumResponseBytes else {
                return fallback("The model answer was too large.")
            }
            // Accept a fenced or prose-wrapped object, then apply the same strict
            // schema check as everywhere else.
            guard let extracted = JSONResponseExtractor.extractObject(
                    from: String(decoding: candidate, as: UTF8.self)) else {
                return fallback("The model returned an empty or non-JSON answer.")
            }
            let explanation = try OptionalAI.parse(extracted)
            return GenerationOutcome(
                explanation: explanation, model: model,
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                usedFallback: false, fallbackReason: nil)
        } catch let error as AIError {
            return fallback(Self.describe(error))
        } catch is CancellationError {
            return fallback("Cancelled.")
        } catch {
            return fallback("The local model did not answer.")
        }
    }

    private static func describe(_ error: AIError) -> String {
        switch error {
        case .disabled: return "Local AI is turned off."
        case .nonLoopbackEndpoint: return "The endpoint is not loopback."
        case .timeout: return "The local model timed out."
        case .transport(let detail): return "Transport: \(detail)"
        case .invalidResponse: return "The model returned something that is not valid JSON for the required schema."
        case .responseTooLong: return "The model response was too long."
        case .unexpectedFields: return "The model returned fields outside the allowed schema."
        case .unsafeContent: return "The model returned text that looks like an instruction to run something."
        }
    }

    // MARK: - HTTP

    private func get(path: String, timeout: TimeInterval) async throws -> Data {
        try await perform(method: "GET", path: path, body: nil, timeout: timeout)
    }

    private func post(path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        try await perform(method: "POST", path: path, body: body, timeout: timeout)
    }

    private func perform(method: String, path: String, body: Data?,
                         timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AIError.nonLoopbackEndpoint
        }
        guard OptionalAI.isLoopback(url) else { throw AIError.nonLoopbackEndpoint }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.transport("HTTP \(http.statusCode)")
        }
        return data
    }
}

/// Locating and launching the Ollama application, without assuming a CLI is on PATH.
enum OllamaInstallation {
    static var appURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Ollama.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isAppInstalled: Bool { appURL != nil }

    /// Launches the app if present. Returns false when it is not installed.
    @MainActor
    static func launchApp() async -> Bool {
        guard let url = appURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
