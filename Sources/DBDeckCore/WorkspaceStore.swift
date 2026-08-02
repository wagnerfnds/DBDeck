import Foundation

public enum WorkspaceStore {
    public static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "DBDeck/workspaces.json")
    }

    public static func load() -> [Workspace] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Workspace].self, from: data)
        } catch {
            return []
        }
    }

    public static func save(_ workspaces: [Workspace]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(workspaces)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DBDeck: falha ao salvar workspaces: \(error)")
        }
    }
}
