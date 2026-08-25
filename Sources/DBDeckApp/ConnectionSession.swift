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

    /// Filtro com que a aba de tabela deve abrir (navegação pela setinha de FK). A view
    /// consome e zera — é um estado de abertura, não de vida.
    var initialFilter: TableLinkFilter?

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

/// `coluna = valor` para abrir uma tabela já filtrada (seguir uma chave estrangeira).
struct TableLinkFilter: Equatable {
    var column: String
    var value: String
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

    /// Colunas por tabela para o autocomplete, chaveadas em minúsculas.
    ///
    /// Fora da observação de propósito: quem lê é o delegate do NSTextView, e publicar
    /// mudança aqui redesenharia o console (e o grid de resultados junto) a cada tabela
    /// que termina de carregar.
    @ObservationIgnored private(set) var columnCache: [String: [SQLColumnInfo]] = [:]
    /// Tabelas com carga em curso — sem isto cada tecla digitada dispararia outra
    /// consulta de metadados para a mesma tabela.
    @ObservationIgnored private var columnsLoading: Set<String> = []

    init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    func recordQuery(_ sql: String, limit: Int = 30) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queryHistory.removeAll { $0 == trimmed }
        queryHistory.insert(trimmed, at: 0)
        // `while`, não `if`: reduzir o limite nas preferências apara o excesso acumulado.
        while queryHistory.count > max(1, limit) { queryHistory.removeLast() }
    }

    // MARK: - Catálogo do autocomplete

    var completionCatalog: SQLSchemaCatalog {
        SQLSchemaCatalog(tables: tables.map(\.name), columns: columnCache)
    }

    /// Carrega em background as colunas das tabelas citadas na consulta, para a próxima
    /// invocação do autocomplete já ter o que sugerir — o delegate do NSTextView é
    /// síncrono e não tem como esperar por I/O.
    func prefetchColumns(of names: [String], using driver: any DatabaseDriver) {
        for name in names {
            let key = name.lowercased()
            guard columnCache[key] == nil, !columnsLoading.contains(key) else { continue }
            // Só tabela que existe: um FROM pela metade ("FROM ped") não pode virar
            // consulta de metadados a cada tecla.
            guard let table = tables.first(where: { $0.name.lowercased() == key }) else { continue }
            columnsLoading.insert(key)
            Task { [weak self] in
                let columns = (try? await driver.columns(table: table.name))?
                    .map { SQLColumnInfo(name: $0.name, type: $0.type) }
                guard let self else { return }
                self.columnCache[key] = columns ?? []
                self.columnsLoading.remove(key)
            }
        }
    }

    /// As tabelas somem ao trocar de banco: as colunas memorizadas seriam do banco antigo.
    func clearColumnCache() {
        columnCache.removeAll()
        columnsLoading.removeAll()
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
    func openTable(_ name: String, newTab: Bool = false, filter: TableLinkFilter? = nil) {
        // Seguir uma FK abre SEMPRE uma aba nova: reaproveitar a aba da tabela de destino
        // jogaria fora o filtro/página que o usuário tinha lá.
        if let filter {
            let tab = EditorTab(kind: .table(name), title: name)
            tab.initialFilter = filter
            tabs.append(tab)
            selectedTabID = tab.id
            return
        }
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
