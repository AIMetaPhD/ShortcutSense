import Foundation
import ShortcutSenseCore

/// Real HTTP transport for the optional local Ollama explanation layer.
///
/// Safety properties enforced here, on top of `OptionalAI`'s own checks:
/// - The endpoint is re-validated as loopback immediately before the request.
/// - The request has a hard timeout and no redirects are followed.
/// - Only the body bytes are returned; nothing is logged.
/// Refuses every HTTP redirect.
///
/// `OptionalAI.isLoopback` checks the URL we *ask for*. Without this delegate, a
/// server on 127.0.0.1 answering `302 Location: https://elsewhere` would make
/// URLSession send the aggregate payload to that host — the loopback guarantee would
/// hold for the request line and fail for the actual destination.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OllamaTransport: AITransport {
    /// Ollama's generate API expects `{model, prompt, stream:false, format:"json"}`.
    let model: String
    let session: URLSession
    private let redirectDelegate = NoRedirectSessionDelegate()

    init(model: String = "qwen2.5:7b") {
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = OptionalAI.defaultTimeout
        configuration.timeoutIntervalForResource = OptionalAI.defaultTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration,
                                  delegate: redirectDelegate, delegateQueue: nil)
    }

    func post(_ body: Data, to url: URL, timeout: TimeInterval) throws -> Data {
        // Defence in depth: OptionalAI already checked, but this is the only place
        // that actually opens a socket, so check again.
        guard OptionalAI.isLoopback(url) else { throw AIError.nonLoopbackEndpoint }

        let prompt = """
        You explain, in one short paragraph, why an application shortcut suggestion \
        might help. Reply with JSON only, containing exactly these three keys and \
        nothing else: {"reason": string, "explanation": string, "category": one of \
        "efficiency"|"consistency"|"ergonomics"|"other"}. Never suggest commands, \
        scripts or configuration changes.

        Data:
        \(String(decoding: body, as: UTF8.self))
        """

        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.2, "num_predict": 200],
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(AIError.timeout)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(AIError.transport(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = .failure(AIError.transport("HTTP \(status)"))
                return
            }
            result = .success(data ?? Data())
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw AIError.timeout
        }
        return try result.get()
    }
}

extension OllamaTransport {
    static func generateEndpoint(from url: URL) -> URL {
        OptionalAI.generateEndpoint(from: url)
    }
}
