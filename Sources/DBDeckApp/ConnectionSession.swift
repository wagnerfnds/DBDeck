import Foundation
import Observation
import DBDeckCore

/// Uma aba aberta no workspace de uma conexão — uma tabela ou um console SQL.
@MainActor
@Observable
final class EditorTab: Identifiable {
    let id = UUID()

    enum Kind: Equatable {
        case table(String)
        case query
    }

    var kind: Kind
    var title: String

    // Estado persistente de uma aba de consulta (sobrevive à troca de abas).
    var sqlText: String = ""

    /// Incrementado pelo ⌘R global; a view da aba observa e recarrega os dados.
    var reloadRequest = 0

    /// Painel de biblioteca (salvas + histórico) visível — vive na aba para o
    /// botão da toolbar conseguir abrir/fechar de fora do console.
    var showLibrary = false

    /// Fração da altura do console ocupada pelo editor SQL (arrastável pelo divisor).
    var editorFraction: Double = 0.5

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    var icon: String {
        switch kind {
        case .table: return "tablecells"
        case .query: return "terminal"
        }
    }

    var tableName: String? {
        if case .table(let name) = kind { return name }
        return nil
    }
}

/// Estado vivo de uma conexão: lista de tabelas + abas abertas.
/// Mantido em `AppState` por conexão, então as abas persistem ao alternar conexões.
@MainActor
@Observable
final class ConnectionSession {
    let connectionID: UUID

    var tables: [DatabaseTable] = []
    var tablesLoaded = false
    var tableFilter = ""

    /// Bancos disponíveis no servidor (quando a conexão não fixa um banco).
    var databases: [String] = []
    var databasesLoaded = false
    var activeDatabase: String?

    var tabs: [EditorTab] = []
    var selectedTabID: UUID?
    /// Aba mostrada no painel da direita (split lado a lado). nil = visão única.
    var splitTabID: UUID?

    /// Histórico de consultas executadas na sessão (mais recentes primeiro).
    var queryHistory: [String] = []

    init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    func recordQuery(_ sql: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queryHistory.removeAll { $0 == trimmed }
        queryHistory.insert(trimmed, at: 0)
        if queryHistory.count > 30 { queryHistory.removeLast() }
    }

    var selectedTab: EditorTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var filteredTables: [DatabaseTable] {
        let query = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return tables }
        return tables.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Abertura de abas

    /// Abre uma tabela. Com `newTab: false` reaproveita a aba de tabela atual (preview,
    /// estilo Xcode/navegador); com `newTab: true` sempre cria uma aba nova.
    func openTable(_ name: String, newTab: Bool = false) {
        if let existing = tabs.first(where: { $0.tableName == name }) {
            selectedTabID = existing.id
            return
        }
        if !newTab, let current = selectedTab, current.tableName != nil {
            current.kind = .table(name)
            current.title = name
            return
        }
        let tab = EditorTab(kind: .table(name), title: name)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    @discardableResult
    func newQuery(sql: String = "") -> EditorTab {
        let tab = EditorTab(kind: .query, title: "Consulta")
        tab.sqlText = sql
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func select(_ tab: EditorTab) {
        selectedTabID = tab.id
    }

    func close(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if splitTabID == tab.id { splitTabID = nil }
        if selectedTabID == tab.id {
            let fallback = index < tabs.count ? tabs[index] : tabs.last
            selectedTabID = fallback?.id
        }
    }

    /// Abre a aba no painel da direita (lado a lado).
    func openBeside(_ tab: EditorTab) {
        splitTabID = tab.id
    }

    func closeSplit() {
        splitTabID = nil
    }

    var splitTab: EditorTab? {
        guard let splitTabID, splitTabID != selectedTabID else { return nil }
        return tabs.first { $0.id == splitTabID }
    }

    func closeSelected() {
        if let tab = selectedTab { close(tab) }
    }

    /// Fecha as abas de tabela, mantendo os consoles SQL — usado ao trocar de banco:
    /// as tabelas abertas pertencem ao banco antigo e recarregá-las no novo dá
    /// "Table doesn't exist".
    func closeTableTabs() {
        tabs.removeAll { $0.tableName != nil }
        if let splitTabID, !tabs.contains(where: { $0.id == splitTabID }) {
            self.splitTabID = nil
        }
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.last?.id
        }
    }
}
