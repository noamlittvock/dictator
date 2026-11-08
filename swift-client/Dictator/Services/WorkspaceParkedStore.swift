import Foundation
import Darwin

/// Remembers parked windows on disk, in this Mac's own support folder.
final class WorkspaceParkedStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> [WorkspaceParkedRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([WorkspaceParkedRecord].self, from: data) else { return [] }
        return records
    }
    @discardableResult
    func save(_ records: [WorkspaceParkedRecord]) -> Bool {
        let manager = FileManager.default
        if records.isEmpty {
            do {
                try manager.removeItem(at: url)
                return true
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return true
            } catch { return false }
        }
        // Set permissions before writing any data; rename publishes the complete
        // private file atomically, including when replacing an older record.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".parked-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        do {
            let data = try JSONEncoder().encode(records)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return rename(temporary.path, url.path) == 0
        } catch {
            // Keep the previous complete recovery record if writing fails.
            return false
        }
    }
}
