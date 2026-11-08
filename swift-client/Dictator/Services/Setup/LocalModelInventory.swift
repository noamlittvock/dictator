import Foundation
import Observation

/// The AI models installed on this Mac, read from Ollama's local API. Each
/// Mac reports them to the Core in `EdgeCapabilities.localModels`, so
/// Settings › Your Macs can show them on that Mac's card.
@MainActor
@Observable
final class LocalModelInventory {
    static let shared = LocalModelInventory()

    private(set) var models: [String] = []
    /// Ollama answered on this Mac at the last check.
    private(set) var ollamaRunning = false
    /// Called with the installed models, or nil while Ollama isn't running.
    @ObservationIgnored var onChange: (([String]?) -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    static let ollamaBase = URL(string: "http://127.0.0.1:11434")!

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        let result = await Self.fetchModels()
        let running = result != nil
        let names = (result ?? []).sorted()
        guard names != models || running != ollamaRunning else { return }
        ollamaRunning = running
        models = names
        onChange?(running ? names : nil)
    }

    /// `nil` when Ollama isn't running on this Mac.
    nonisolated static func fetchModels() async -> [String]? {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"), timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }
    }
}
