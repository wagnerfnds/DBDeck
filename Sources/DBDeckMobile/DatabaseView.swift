import SwiftUI
import DBDeckCore

/// Tabelas de uma conexão, com troca de banco e atalho para o console.
struct DatabaseView: View {
    @Environment(AppState.self) private var state
    @Environment(Navigator.self) private var navigator
    let connectionID: UUID

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var sharedFile: SharedFile?
    @State private var exporting: String?
    @State private var showNewDatabase = false
    @State private var newDatabaseName = ""
    @State private var kindFilter: KindFilter = .all

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all = "Todas"
        case tables = "Tabelas"
        case views = "Views"
        var id: String { rawValue }
    }

    private var config: ConnectionConfig? { state.config(for: connectionID) }
    private var session: ConnectionSession { state.session(for: connectionID) }
    private var driver: (any DatabaseDriver)? { state.active[connectionID] }
    private var status: ConnectionStatus? { state.connectionStatus[connectionID] }

    private var activeDatabase: String? {
        session.activeDatabase ?? (config?.database.isEmpty == false ? config?.database : nil)
    }

    var body: some View {
        @Bindable var session = session
        Group {
            if driver == nil {
                connectingState
            } else {
                tableList
            }
        }
        .navigationTitle(config?.name ?? "Conexão")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: connectionID) { await connectAndLoad() }
        .errorAlert($errorMessage)
        .toast($notice)
        .shareSheet($sharedFile)
        .alert("Novo banco de dados", isPresented: $showNewDatabase) {
            TextField("nome", text: $newDatabaseName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Criar") { Task { await createDatabase() } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: - Estados

    @ViewBuilder
    private var connectingState: some View {
        if case .failed(let message) = status {
            ContentUnavailableView {
                Label("Não foi possível conectar", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button {
                    Task { await connectAndLoad() }
                } label: {
                    Label("Tentar de novo", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 14) {
                if let config { EngineBadge(engine: config.engine, size: 52) }
                ProgressView()
                Text("Conectando a \(config?.name ?? "")…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var visibleTables: [DatabaseTable] {
        session.filteredTables.filter { table in
            switch kindFilter {
            case .all: true
            case .tables: table.kind != "view"
            case .views: table.kind == "view"
            }
        }
    }

    private var hasViews: Bool { session.tables.contains { $0.kind == "view" } }

    private var tableList: some View {
        @Bindable var navigator = navigator
        @Bindable var session = session
        return List(selection: $navigator.route) {
            Section {
                NavigationLink(value: DetailRoute.console) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Console SQL").font(.body.weight(.medium))
                            Text(session.queryHistory.first?.flattenedSQL ?? "Escreva e execute consultas")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            Section {
                if hasViews {
                    Picker("Tipo", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(visibleTables) { table in
                    NavigationLink(value: DetailRoute.table(table.name)) {
                        TableRowLabel(table: table)
                    }
                    .contextMenu { tableMenu(table) }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await exportTable(table) }
                        } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                        .tint(.blue)
                    }
                }
            } header: {
                HStack {
                    Text(session.tablesLoaded ? "\(visibleTables.count) \(visibleTables.count == 1 ? "item" : "itens")" : "Tabelas")
                    Spacer()
                    if isLoading { ProgressView().controlSize(.mini) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $session.tableFilter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filtrar tabelas")
        .refreshable { await reloadTables() }
        .overlay {
            if session.tablesLoaded && visibleTables.isEmpty {
                if session.tableFilter.isEmpty {
                    ContentUnavailableView("Banco vazio", systemImage: "tray", description: Text("Nenhuma tabela neste banco."))
                } else {
                    ContentUnavailableView.search(text: session.tableFilter)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let exporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(exporting).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: exporting)
    }

    @ViewBuilder
    private func tableMenu(_ table: DatabaseTable) -> some View {
        Button {
            navigator.open(table: table.name)
        } label: { Label("Abrir", systemImage: "tablecells") }
        Button {
            let console = consoleTab()
            let quoted = driver?.quoteIdentifier(table.name) ?? table.name
            console.sqlText = "SELECT * FROM \(quoted) LIMIT 100;"
            navigator.route = .console
        } label: { Label("SELECT no console", systemImage: "terminal") }
        Button {
            UIPasteboard.general.string = table.name
            notice = "Nome copiado"
        } label: { Label("Copiar nome", systemImage: "doc.on.doc") }
        Divider()
        Button {
            Task { await exportTable(table) }
        } label: { Label("Exportar dump (.sql)", systemImage: "square.and.arrow.up") }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let config, config.engine != .sqlite, driver != nil {
            ToolbarItem(placement: .principal) {
                databaseMenu(config)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await reloadTables() }
                } label: { Label("Recarregar", systemImage: "arrow.clockwise") }
                if let config, config.engine != .sqlite {
                    Button {
                        newDatabaseName = ""
                        showNewDatabase = true
                    } label: { Label("Novo banco de dados", systemImage: "plus.square.on.square") }
                }
                Button {
                    Task { await dumpDatabase() }
                } label: { Label("Dump do banco (.sql)", systemImage: "externaldrive.badge.icloud") }
                Divider()
                Button(role: .destructive) {
                    state.disconnect(connectionID)
                    navigator.resetTables(for: connectionID)
                    navigator.connectionID = nil
                } label: { Label("Desconectar", systemImage: "bolt.slash") }
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
            }
        }
    }

    private func databaseMenu(_ config: ConnectionConfig) -> some View {
        Menu {
            if session.databases.isEmpty {
                Text("Nenhum banco listado")
            }
            ForEach(session.databases, id: \.self) { database in
                Button {
                    Task { await switchDatabase(to: database) }
                } label: {
                    if database == activeDatabase {
                        Label(database, systemImage: "checkmark")
                    } else {
                        Text(database)
                    }
                }
            }
            Divider()
            Button {
                Task { await loadDatabases() }
            } label: { Label("Atualizar lista", systemImage: "arrow.clockwise") }
        } label: {
            HStack(spacing: 4) {
                VStack(spacing: 0) {
                    Text(config.name).font(.headline).lineLimit(1)
                    Text(activeDatabase ?? "escolher banco")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary, Color(uiColor: .tertiarySystemFill))
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Banco ativo: \(activeDatabase ?? "nenhum"). Toque para trocar.")
        .task { if !session.databasesLoaded { await loadDatabases() } }
    }

    // MARK: - Ações

    private func consoleTab() -> EditorTab {
        session.tabs.first { $0.kind == .query } ?? session.newQuery()
    }

    private func connectAndLoad() async {
        if state.active[connectionID] == nil {
            guard await state.connect(connectionID) else {
                Haptics.error()
                return
            }
        }
        if !session.tablesLoaded { await reloadTables() }
    }

    private func reloadTables() async {
        guard let driver else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            session.tables = try await driver.tables()
            session.tablesLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDatabases() async {
        guard let driver else { return }
        if let list = try? await driver.databases() {
            state.setDatabases(list, for: connectionID)
        }
    }

    private func switchDatabase(to database: String) async {
        guard database != activeDatabase else { return }
        Haptics.selection()
        isLoading = true
        defer { isLoading = false }
        navigator.resetTables(for: connectionID)
        if await state.switchDatabase(connectionID, to: database) {
            await reloadTables()
        } else if case .failed(let message) = state.connectionStatus[connectionID] {
            errorMessage = message
        }
    }

    private func createDatabase() async {
        let name = newDatabaseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try await state.createDatabase(named: name, charset: nil, on: connectionID)
            notice = "Banco “\(name)” criado"
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportTable(_ table: DatabaseTable) async {
        guard let driver else { return }
        exporting = "Exportando \(table.name)…"
        defer { exporting = nil }
        do {
            let sql = try await SQLDump.dumpTable(driver: driver, table: table)
            let url = ExportFiles.temporaryURL(named: table.name, ext: "sql")
            try sql.write(to: url, atomically: true, encoding: .utf8)
            sharedFile = SharedFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Dump do banco ativo em streaming direto para o arquivo — nunca o banco inteiro na memória.
    private func dumpDatabase() async {
        guard let driver else { return }
        let name = activeDatabase ?? config?.name ?? "dump"
        exporting = "Gerando dump…"
        defer { exporting = nil }
        do {
            let url = ExportFiles.temporaryURL(named: name, ext: "sql")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try await SQLDump.dump(
                driver: driver,
                tables: nil,
                write: { chunk in try handle.write(contentsOf: Data(chunk.utf8)) },
                progress: { progress in
                    let label = "Dump · \(progress.tableIndex + 1)/\(progress.tableCount) · \(progress.tableName)"
                    Task { @MainActor in exporting = label }
                }
            )
            sharedFile = SharedFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TableRowLabel: View {
    let table: DatabaseTable

    var body: some View {
        Label {
            Text(table.name)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: table.kind == "view" ? "eye" : "tablecells")
                .foregroundStyle(table.kind == "view" ? Color.purple : Color.accentColor)
        }
    }
}
