import Foundation
import DBDeckCore

/// Arquivos SQLite do app no iOS.
///
/// O sandbox do iOS não deixa abrir um caminho qualquer: o arquivo escolhido no app
/// Arquivos é COPIADO para `Documents/Databases`, que fica visível no próprio app
/// Arquivos (UIFileSharingEnabled) — dá para soltar bancos ali pelo Finder também.
///
/// O caminho absoluto do container muda entre instalações e atualizações (o UUID da
/// pasta do app é outro), então o caminho gravado na conexão é re-resolvido pelo nome
/// do arquivo na hora de conectar.
enum SQLiteFileStore {
    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appending(path: "Databases", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Caminho que existe hoje para o arquivo gravado na conexão.
    static func resolve(_ storedPath: String) -> String {
        guard !storedPath.isEmpty else { return storedPath }
        if FileManager.default.fileExists(atPath: storedPath) { return storedPath }
        let name = (storedPath as NSString).lastPathComponent
        let candidate = directory.appending(path: name).path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : storedPath
    }

    /// Bancos já guardados no app, mais recentes primeiro.
    static func files() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            // -wal/-shm/-journal são companheiros do banco, não bancos.
            .filter { url in !["wal", "shm", "journal"].contains { url.lastPathComponent.hasSuffix("-" + $0) } }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    /// Copia um arquivo escolhido no seletor do sistema para dentro do app.
    static func importFile(from source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let destination = uniqueURL(named: source.lastPathComponent)
        // Coordenação: o arquivo pode estar no iCloud Drive e ainda não baixado.
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinatorError) { url in
            do { try FileManager.default.copyItem(at: url, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    /// Cria um banco vazio — o SQLite cria o arquivo na primeira abertura.
    static func newDatabaseURL(named name: String) -> URL {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "banco" }
        let hasExtension = ["sqlite", "sqlite3", "db"].contains((base as NSString).pathExtension.lowercased())
        return uniqueURL(named: hasExtension ? base : base + ".sqlite")
    }

    private static func uniqueURL(named name: String) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func sizeLabel(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
