import SwiftUI
import DBDeckCore

@main
struct DBDeckMobileApp: App {
    @State private var state = AppState()
    @State private var settings = AppSettings()
    @State private var navigator = Navigator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(settings)
                .environment(navigator)
                // A janela só existe depois do primeiro layout: aplicar no init do App
                // não acharia cena nenhuma para ajustar.
                .onAppear { settings.applyAppearance() }
        }
    }
}

/// Três colunas no iPad (conexões › tabelas › conteúdo); no iPhone o mesmo split se
/// recolhe numa pilha de navegação. Uma árvore só, guiada por seleção — tocar numa
/// conexão empilha as tabelas, tocar numa tabela empilha o grid.
struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didAttemptReconnect = false

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConnectionsView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } content: {
            if let id = navigator.connectionID, state.config(for: id) != nil {
                DatabaseView(connectionID: id)
                    .id(id)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            } else {
                ContentUnavailableView(
                    "Nenhuma conexão",
                    systemImage: "cylinder.split.1x2",
                    description: Text("Escolha uma conexão para ver as tabelas.")
                )
            }
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .task { await reconnectLastIfWanted() }
        .onChange(of: navigator.connectionID) { _, id in
            state.selectedConnectionID = id
        }
        .onChange(of: scenePhase) { _, phase in
            // Voltando do background, sockets ociosos podem ter sido derrubados pelo
            // sistema. A próxima operação que falhar oferece reconectar; aqui só se
            // limpa o que já se sabe morto (túnel/driver desconectado).
            guard phase == .active else { return }
            for (id, driver) in state.active where !driver.isConnected {
                state.disconnect(id)
            }
        }
    }

    private func reconnectLastIfWanted() async {
        guard !didAttemptReconnect else { return }
        didAttemptReconnect = true
        guard settings.reconnectLastOnLaunch,
              let id = settings.lastConnectionID,
              state.config(for: id) != nil else { return }
        navigator.connectionID = id
        _ = await state.connect(id)
    }
}

/// Coluna de conteúdo: o grid da tabela escolhida ou o console SQL.
struct DetailView: View {
    @Environment(AppState.self) private var state
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Group {
            if let id = navigator.connectionID,
               let route = navigator.route,
               let driver = state.active[id] {
                switch route {
                case .table(let name):
                    TableScreen(connectionID: id, driver: driver, table: name)
                        .id("\(id)/\(navigator.databaseKey)/\(name)")
                case .console:
                    ConsoleScreen(connectionID: id, driver: driver)
                        .id("\(id)/console")
                }
            } else {
                ContentUnavailableView(
                    "Nada aberto",
                    systemImage: "tablecells",
                    description: Text("Abra uma tabela ou o console SQL.")
                )
            }
        }
    }
}

/// Para onde a coluna de detalhe aponta.
enum DetailRoute: Hashable {
    case table(String)
    case console
}

/// Estado de navegação do app (conexão aberta, rota de detalhe) e o cache dos modelos
/// de tabela — voltar a uma tabela já aberta reencontra a página, o filtro e a rolagem
/// em vez de pagar a consulta de novo.
@MainActor
@Observable
final class Navigator {
    var connectionID: UUID? {
        didSet {
            if connectionID != oldValue { route = nil }
        }
    }
    var route: DetailRoute?

    /// Muda quando o banco ativo troca: entra no `id` da view de tabela para que uma
    /// tabela homônima de outro banco não herde o estado da anterior.
    var databaseKey = ""

    /// Filtro pendente para a próxima abertura de tabela (seguir uma chave estrangeira).
    @ObservationIgnored var pendingFilter: [String: TableLinkFilter] = [:]

    @ObservationIgnored private var tableModels: [String: TableDataModel] = [:]

    func open(table: String, filter: TableLinkFilter? = nil) {
        if let filter {
            pendingFilter[table] = filter
            // Seguir FK sempre recomeça: o modelo antigo tinha outro filtro/página.
            tableModels[modelKey(table)] = nil
        }
        route = .table(table)
    }

    func model(for table: String, driver: any DatabaseDriver, settings: AppSettings) -> TableDataModel {
        let key = modelKey(table)
        if let existing = tableModels[key], existing.driverIdentity == ObjectIdentifier(driver as AnyObject) {
            return existing
        }
        let model = TableDataModel(driver: driver, table: table, settings: settings)
        model.initialFilter = pendingFilter.removeValue(forKey: table)
        tableModels[key] = model
        return model
    }

    /// Banco trocado ou conexão encerrada: os modelos apontam para tabelas que não
    /// existem mais naquele driver.
    func resetTables(for connectionID: UUID) {
        let prefix = connectionID.uuidString + "/"
        tableModels = tableModels.filter { !$0.key.hasPrefix(prefix) }
        databaseKey = UUID().uuidString
        if case .table = route, self.connectionID == connectionID { route = nil }
    }

    private func modelKey(_ table: String) -> String {
        "\(connectionID?.uuidString ?? "-")/\(databaseKey)/\(table)"
    }
}
