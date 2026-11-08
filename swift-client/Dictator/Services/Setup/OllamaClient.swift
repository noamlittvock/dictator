import Foundation

/// One chat message for a cleanup model.
struct ChatMessage: Codable, Equatable {
    var role: String
    var content: String
}

/// A cleanup the Core asks another Mac to run on its own Ollama: the
/// messages and options come from the speech server (`/polish/prepare`),
/// so every Mac cleans up exactly the same way.
struct CleanupJob: Codable, Equatable {
    var model: String
    var messages: [ChatMessage]
    var options: [String: Double]
}

/// Progress of a model download on one Mac.
struct ModelPullProgress: Codable, Equatable {
    var status: String
    var completed: Int64?
    var total: Int64?
    var done: Bool
    var error: String?

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

enum OllamaError: Error, LocalizedError, Equatable {
    case notRunning
    case invalidModelName
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama isn’t running on this Mac."
        case .invalidModelName: "That isn’t a valid model name."
        case .failed(let message): message
        }
    }
}

/// Talks to Ollama on this Mac only (127.0.0.1) — nothing is exposed on
/// the network; other Macs reach it through Dictator's own connection.
enum OllamaClient {
    static var base: URL { LocalModelInventory.ollamaBase }

    /// Ollama model names: "gemma4:e2b-it-qat", "library/qwen3:8b".
    static func isValidModelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_/"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) } && !name.contains("..")
    }

    static let keepAlive = "5m"

    /// Loads `model` into memory ahead of a clean-up (no prompt is run):
    /// Ollama loads a model when `/api/generate` gets just `model` and
    /// `keep_alive`. Best-effort; failures are ignored.
    static func preload(model: String, session: URLSession = .shared) {
        guard isValidModelName(model) else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/generate"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive])
        Task { _ = try? await session.data(for: request) }
    }

    static func chat(_ job: CleanupJob, timeout: TimeInterval = 30) async throws -> String {
        guard isValidModelName(job.model) else { throw OllamaError.invalidModelName }
        var request = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": job.model,
            "messages": job.messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "think": false,
            // Matches the speech server's idle window: unloaded after
            // about five idle minutes, so memory isn't held all day.
            "keep_alive": keepAlive,
            "options": job.options,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw OllamaError.notRunning
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.failed("Ollama reported a problem (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(text.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError.failed("Ollama sent an unexpected reply.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downloads a model, reporting progress until it's done.
    static func pull(_ model: String) -> AsyncThrowingStream<ModelPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard isValidModelName(model) else {
                    continuation.finish(throwing: OllamaError.invalidModelName)
                    return
                }
                var request = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 60 * 60 * 6)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw OllamaError.failed("Ollama couldn’t start the download.")
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = json["error"] as? String {
                            throw OllamaError.failed(error)
                        }
                        let status = json["status"] as? String ?? ""
                        continuation.yield(ModelPullProgress(
                            status: status,
                            completed: (json["completed"] as? NSNumber)?.int64Value,
                            total: (json["total"] as? NSNumber)?.int64Value,
                            done: status == "success",
                            error: nil
                        ))
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    continuation.finish(throwing: OllamaError.notRunning)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
