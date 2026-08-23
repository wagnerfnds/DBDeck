import Foundation

/// Consulta salva pelo usuário, com título para busca na biblioteca do console.
public struct SavedQuery: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var sql: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, sql: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.sql = sql
        self.createdAt = createdAt
    }
}

public enum SavedQueryStore {
    public static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "DBDeck/saved-queries.json")
    }

    public static func load() -> [SavedQuery] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([SavedQuery].self, from: data)
        } catch {
            return []
        }
    }

    public static func save(_ queries: [SavedQuery]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(queries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DBDeck: falha ao salvar consultas: \(error)")
        }
    }
}
