import SwiftUI
import DBDeckCore

struct NewConnectionTarget: Identifiable {
    let workspaceID: UUID
    var id: UUID { workspaceID }
}

/// Alvo do sheet de dump: conexão + banco resolvido.
struct DumpTarget: Identifiable {
    let connection: ConnectionConfig
    let database: String?
    var id: String { "\(connection.id)-\(database ?? "")" }
}

/// Seleção da árvore: uma conexão (database == nil) ou um banco específico dela.
struct SidebarSelection: Hashable {
    let connectionID: UUID
    let database: String?
}

struct SidebarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state

    @State private var selection: SidebarSelection?
    @State private var newWorkspaceName = ""
    @State private var showingNewWorkspace = false
    @State private var newConnectionWorkspace: NewConnectionTarget?
    @State private var editingConnection: ConnectionConfig?
    @State private var deletingConnection: ConnectionConfig?
    @State private var errorMessage: String?
    /// true enquanto a seleção da árvore está sendo espelhada de `state.selectedConnectionID`
    /// (ex.: ⌘P). O espelhamento não deve disparar handleSelection: quem mudou a seleção por
    /// fora já cuida de conectar/trocar de banco, e o eco reconectaria ao banco antigo.
    @State private var syncingSelection = false
    @State private var dumpTarget: DumpTarget?
    @State private var newDatabaseConnection: ConnectionConfig?

    var body: some View {
        List(selection: $selection) {
            ForEach(state.workspaces) { workspace in
                workspaceSection(workspace)
            }
        }
        .listStyle(.sidebar)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewWorkspace) { newWorkspaceSheet }
        .sheet(item: $editingConnection) { connection in
            ConnectionEditView(config: connection, workspaceID: state.workspace(for: connection.id)?.id)
        }
        .sheet(item: $newConnectionWorkspace) { target in
            ConnectionEditView(config: ConnectionConfig(engine: settings.defaultEngine, port: settings.defaultEngine.defaultPort), workspaceID: target.workspaceID)
        }
        .sheet(item: $dumpTarget) { target in
            DumpExportSheet(
                connectionID: target.connection.id,
                database: target.database,
                title: target.database ?? target.connection.name
            )
        }
        .sheet(item: $newDatabaseConnection) { connection in
            NewDatabaseSheet(connection: connection) { created in
                // Já abre o banco recém-criado: o caso de uso é criar para importar.
                selection = SidebarSelection(connectionID: connection.id, database: created)
            }
        }
        .confirmationDialog(
            "Remover “\(deletingConnection?.name ?? "")”?",
            isPresented: .init(get: { deletingConnection != nil }, set: { if !$0 { deletingConnection = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover conexão", role: .destructive) {
                if let c = deletingConnection { state.deleteConnection(c) }
                deletingConnection = nil
            }
            Button("Cancelar", role: .cancel) { deletingConnection = nil }
        } message: {
            Text("A conexão e sua senha no Keychain serão removidas.")
        }
        .alert("Erro", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: selection) { _, sel in
            if syncingSelection { syncingSelection = false } else { handleSelection(sel) }
        }
        .onChange(of: state.selectedConnectionID) { _, id in
            // Mantém a seleção da árvore em sincronia quando muda por fora (ex.: ⌘P).
            if let id, selection?.connectionID != id {
                syncingSelection = true
                selection = SidebarSelection(connectionID: id, database: state.session(for: id).activeDatabase)
            }
        }
    }

    // MARK: - Seções / nós

    private func workspaceSection(_ workspace: Workspace) -> some View {
        Section {
            ForEach(workspace.connections) { connection in
                ConnectionNode(
                    connection: connection,
                    onEdit: { editingConnection = connection },
                    onDelete: { deletingConnection = connection },
                    onDump: { database in dumpDatabase(connection, database: database) },
                    onNewDatabase: { newDatabaseConnection = connection }
                )
            }
        } header: {
            Text(workspace.name)
                .contextMenu {
                    Button("Nova conexão…") { newConnectionWorkspace = NewConnectionTarget(workspaceID: workspace.id) }
                    Divider()
                    Button("Remover workspace", role: .destructive) { state.deleteWorkspace(workspace) }
                }
        }
    }

    // MARK: - Seleção

    /// Abre o sheet de dump. `database == nil` usa o banco fixo da conexão (ou o ativo da sessão).
    private func dumpDatabase(_ connection: ConnectionConfig, database: String?) {
        let target = database
            ?? (connection.database.isEmpty ? state.session(for: connection.id).activeDatabase : connection.database)
        if connection.engine != .sqlite, (target ?? "").isEmpty {
            errorMessage = "Escolha um banco para o dump (expanda a conexão e clique com o direito num banco)."
            return
        }
        dumpTarget = DumpTarget(connection: connection, database: target)
    }

    private func handleSelection(_ sel: SidebarSelection?) {
        guard let sel else { return }
        state.selectedConnectionID = sel.connectionID
        Task {
            if state.active[sel.connectionID] == nil {
                _ = await state.connect(sel.connectionID)
                if case .failed(let message) = state.connectionStatus[sel.connectionID] {
                    errorMessage = message
                    return
                }
            }
            if let db = sel.database {
                let session = state.session(for: sel.connectionID)
                if session.activeDatabase != db {
                    _ = await state.switchDatabase(sel.connectionID, to: db)
                }
            }
        }
    }

    // MARK: - Toolbar / sheets

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                ForEach(state.workspaces) { workspace in
                    Button("em “\(workspace.name)”") {
                        newConnectionWorkspace = NewConnectionTarget(workspaceID: workspace.id)
                    }
                }
            } label: {
                Label("Nova conexão", systemImage: "plus")
            }
            .disabled(state.workspaces.isEmpty)

            Button { showingNewWorkspace = true } label: {
                Label("Novo workspace", systemImage: "folder.badge.plus")
            }
        }
    }

    private var newWorkspaceSheet: some View {
        VStack(spacing: 16) {
            Text("Novo workspace").font(.headline)
            TextField("Nome", text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Button("Cancelar") { showingNewWorkspace = false }.keyboardShortcut(.cancelAction)
                Button("Criar") {
                    let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        state.addWorkspace(named: name)
                        showingNewWorkspace = false
                        newWorkspaceName = ""
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

// MARK: - Nó de conexão (com árvore de bancos)

private struct ConnectionNode: View {
    @Environment(AppState.self) private var state
    let connection: ConnectionConfig
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Dump de um banco (nil = banco fixo/ativo da conexão).
    var onDump: (String?) -> Void
    var onNewDatabase: () -> Void

    @State private var expanded = false
    @State private var loadingDatabases = false

    private var isConnected: Bool { state.active[connection.id] != nil }
    private var hasFixedDatabase: Bool { !connection.database.isEmpty }
    private var session: ConnectionSession { state.session(for: connection.id) }
    /// Banco em uso de fato: o trocado na sessão ou, sem troca, o fixo do cadastro.
    private var activeDatabase: String? {
        session.activeDatabase ?? (hasFixedDatabase ? connection.database : nil)
    }

    var body: some View {
        // Mesmo com banco FIXO no cadastro, a conexão expande para os demais bancos do
        // servidor — o fixo é só o padrão de entrada, não uma prisão. SQLite fica fora
        // (um arquivo = um banco).
        if connection.engine == .sqlite {
            ConnectionRow(connection: connection)
                .tag(SidebarSelection(connectionID: connection.id, database: nil))
                .contextMenu { menu }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                databaseChildren
            } label: {
                ConnectionRow(connection: connection)
                    .tag(SidebarSelection(connectionID: connection.id, database: nil))
                    .contextMenu { menu }
            }
            .onChange(of: expanded) { _, isExpanded in
                if isExpanded { Task { await loadDatabases() } }
            }
        }
    }

    @ViewBuilder
    private var databaseChildren: some View {
        if loadingDatabases && session.databases.isEmpty {
            Label("Carregando bancos…", systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        } else if session.databases.isEmpty {
            Button("Criar banco de dados…") { onNewDatabase() }
                .buttonStyle(.link).font(.caption)
        } else {
            ForEach(session.databases, id: \.self) { db in
                Label {
                    HStack(spacing: 4) {
                        Text(db).lineLimit(1)
                        if db == connection.database {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                                .help("Banco padrão desta conexão")
                        }
                    }
                } icon: {
                    Image(systemName: "cylinder.split.1x2")
                        .foregroundStyle(activeDatabase == db ? Color.accentColor : .secondary)
                }
                .tag(SidebarSelection(connectionID: connection.id, database: db))
                .contextMenu {
                    Button("Dump do banco (.sql)…") { onDump(db) }
                    Divider()
                    Button("Novo banco de dados…") { onNewDatabase() }
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(isConnected ? "Desconectar" : "Conectar") {
            if isConnected { state.disconnect(connection.id) }
            else { Task { _ = await state.connect(connection.id) } }
        }
        if connection.engine != .sqlite {
            Button("Listar bancos") { Task { expanded = true; await loadDatabases() } }
        }
        if connection.engine != .sqlite {
            Button("Novo banco de dados…") { onNewDatabase() }
        }
        Button("Dump do banco (.sql)…") { onDump(nil) }
        Button("Editar…") { onEdit() }
        Divider()
        Button("Remover", role: .destructive) { onDelete() }
    }

    private func loadDatabases() async {
        loadingDatabases = true
        defer { loadingDatabases = false }
        if state.active[connection.id] == nil {
            _ = await state.connect(connection.id)
        }
        guard let driver = state.active[connection.id] else { return }
        if let list = try? await driver.databases() {
            state.setDatabases(list, for: connection.id)
        }
    }
}

// MARK: - Linha de conexão

private struct ConnectionRow: View {
    @Environment(AppState.self) private var state
    let connection: ConnectionConfig

    private var status: ConnectionStatus {
        state.connectionStatus[connection.id] ?? .disconnected
    }

    var body: some View {
        HStack(spacing: 9) {
            if let color = ConnectionColor.color(for: connection.color) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 30)
            }
            EngineBadge(engine: connection.engine, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(connection.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            StatusDot(status: status)
        }
        .padding(.vertical, 3)
    }
}

private struct StatusDot: View {
    let status: ConnectionStatus

    var body: some View {
        Group {
            if case .connecting = status {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).opacity(isConnected ? 1 : 0))
            }
        }
        .help(helpText)
    }

    private var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    private var color: Color {
        switch status {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var helpText: String {
        switch status {
        case .disconnected: return "Desconectado"
        case .connecting: return "Conectando…"
        case .connected: return "Conectado"
        case .failed(let message): return "Falha: \(message)"
        }
    }
}
