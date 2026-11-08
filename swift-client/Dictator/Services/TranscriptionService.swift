import Foundation

/// HTTP client for POST /transcribe to the server.
/// Replaces Python httpx client. Sends raw float32 PCM, receives plain text.
final class TranscriptionService {
    private let session: URLSession
    /// Separate from `session` so a warm call never queues ahead of `/transcribe`.
    private let warmSession: URLSession

    init(session: URLSession? = nil, warmSession: URLSession? = nil) {
        let warmConfig = URLSessionConfiguration.ephemeral
        warmConfig.timeoutIntervalForRequest = 3
        warmConfig.timeoutIntervalForResource = 5
        self.warmSession = warmSession ?? URLSession(configuration: warmConfig, delegate: SpeechRedirectPolicy(), delegateQueue: nil)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180.0
        config.timeoutIntervalForResource = 600.0
        config.httpMaximumConnectionsPerHost = 1
        self.session = session ?? URLSession(
            configuration: config,
            delegate: SpeechRedirectPolicy(),
            delegateQueue: nil
        )
    }

    /// Fire-and-forget `POST /warm`, sent when a dictation starts (key down
    /// on any Mac, from the Core). The speech server holds no models while
    /// idle; `/warm` returns at once and starts loading Whisper, plus the
    /// clean-up model unless `refineLevel` is `.exact` (the server reads
    /// `X-Refine-Level`; a missing header means clean-up is needed). Pass
    /// `.exact` when clean-up runs elsewhere, so the server doesn't load a
    /// model this dictation won't use. The models load while the user is
    /// still speaking, and `/transcribe` waits for any load in progress.
    ///
    /// Sent on its own short-timeout session, never on `session`: that one
    /// allows one connection per host, so a warm call could sit in front of
    /// the real `/transcribe`. Errors (server unreachable, bad URL) are
    /// swallowed; this is a pure latency optimization and never blocks
    /// recording or surfaces as a failure.
    func warmUp(serverURL: String, refineLevel: RefineLevel) {
        guard let request = Self.warmRequest(serverURL: serverURL, refineLevel: refineLevel) else { return }
        let session = warmSession
        Task { _ = try? await session.data(for: request) }
    }

    /// Quick "is anything there?" check on a speech server, so a Mac that is
    /// off costs `timeout` seconds rather than the long processing limit.
    /// Any HTTP answer counts as reachable; only connection failures throw.
    static func checkReachable(serverURL: String, timeout: TimeInterval) async throws {
        let base = try SpeechEndpoint.validated(serverURL)
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: SpeechRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await session.data(for: request)
    }

    /// The `/warm` request for `serverURL`, or nil when the address isn't valid.
    static func warmRequest(serverURL: String, refineLevel: RefineLevel) -> URLRequest? {
        guard let baseURL = try? SpeechEndpoint.validated(serverURL) else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("warm"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue(refineLevel.rawValue, forHTTPHeaderField: "X-Refine-Level")
        authorize(&request)
        return request
    }

    private static func authorize(_ request: inout URLRequest) {
        if let host = request.url?.host,
           let key = LocalSecret.speechKey(requestHost: host, ownAddresses: LocalSecret.ownInterfaceAddresses(),
                                          localKey: LocalSecret.speechServerKey(), remoteKey: LocalSecret.remoteSpeechServerKey()) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Open health check: never send the key, and never follow redirects.
    static func healthData(at url: URL, timeout: TimeInterval = 3) async throws -> Data {
        _ = try SpeechEndpoint.validated(url.absoluteString)
        let session = URLSession(configuration: .ephemeral, delegate: SpeechRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranscriptionError.invalidResponse }
        return data
    }

    func transcribe(
        audio: CapturedAudio,
        serverURL: String,
        refineLevel: RefineLevel,
        dictionary: [[String: String]],
        languages: [String]? = nil,
        vocabularyHint: VocabularyHintInput? = nil,
        timeout: TimeInterval? = nil,
        beforeRequest: (@Sendable () throws -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let baseURL = try SpeechEndpoint.validated(serverURL)
        let url = baseURL.appendingPathComponent("transcribe")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audio.data
        Self.authorize(&request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(audio.sampleRate)", forHTTPHeaderField: "X-Sample-Rate")
        request.setValue("\(audio.frameCount)", forHTTPHeaderField: "X-Frame-Count")
        if let languages { request.setValue(languages.joined(separator: ","), forHTTPHeaderField: "X-Dictation-Languages") }
        if let timeout { request.timeoutInterval = timeout }

        // v2 headers — refine level, dictionary
        request.setValue(refineLevel.rawValue, forHTTPHeaderField: "X-Refine-Level")

        if !dictionary.isEmpty {
            // Base64-encode: raw JSON in a header gets
            // mangled when entries contain non-ASCII (Hebrew patterns → 400).
            if let json = try? JSONSerialization.data(withJSONObject: dictionary) {
                request.setValue(json.base64EncodedString(), forHTTPHeaderField: "X-Dictionary")
            }
        }

        if let vocabularyHint {
            let terms = VocabularyHint.orderedTerms(vocabularyHint)
            if !terms.isEmpty {
                let json = try JSONSerialization.data(withJSONObject: ["terms": terms])
                request.setValue(json.base64EncodedString(), forHTTPHeaderField: "X-Vocabulary-Hint")
            }
        }

        try beforeRequest?()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        if httpResponse.statusCode == 401 { throw TranscriptionError.authenticationRequired }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.serverError(httpResponse.statusCode, body)
        }

        // Negotiate JSON with newer servers, retaining plain-text compatibility.
        struct Payload: Decodable { var text: String; var raw: String? }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        let text = payload?.text ?? String(data: data, encoding: .utf8) ?? ""
        let inferenceMs = httpResponse.value(forHTTPHeaderField: "X-Inference-Ms")
            .flatMap { Int($0) }

        // An older server reports no level: it ran an ordinary clean-up.
        let polish = CleanupOutcome(server: httpResponse.value(forHTTPHeaderField: "X-Polish"), requested: refineLevel,
                                    ran: httpResponse.value(forHTTPHeaderField: "X-Polish-Level"))
        return TranscriptionResult(text: text, inferenceMs: inferenceMs, rawText: payload?.raw, cleanupOutcome: polish,
                                   cleanupMs: httpResponse.value(forHTTPHeaderField: "X-Polish-Ms").flatMap { Int($0) })
    }
}

struct TranscriptionResult {
    let text: String
    let inferenceMs: Int?
    var rawText: String? = nil
    /// What the server's clean-up did; nil when it wasn't asked to do one.
    var cleanupOutcome: CleanupOutcome? = nil
    var cleanupMs: Int? = nil
}

enum TranscriptionError: Error, LocalizedError {
    case invalidResponse
    case authenticationRequired
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The speech server sent back something Dictator couldn’t read."
        case .authenticationRequired: "The speech server needs its key. Add it in Settings › Advanced › Speech server key. The recording is kept in History & Privacy."
        case .serverError(let code, let body): "The speech server answered with an error (\(code)) instead of text: \(body)"
        }
    }
}

/// A redirect must not silently send a recording to a destination the user
/// didn't choose.
final class SpeechRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
