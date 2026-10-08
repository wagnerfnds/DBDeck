import SwiftUI
import DBDeckCore

/// Tela inicial: conexões agrupadas por workspace.
struct ConnectionsView: View {
    @Environment(AppState.self) private var state
    @Environment(Navigator.self) private var navigator

    @State private var search = ""
    @State private var editing: ConnectionDraft?
    @State private var showSettings = false
    @State private var showNewWorkspace = false
    @State private var newWorkspaceName = ""
    @State private var renamingWorkspace: Workspace?
    @State private var deletingConnection: ConnectionConfig?
    @State private var deletingWorkspace: Workspace?

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.connectionID) {
            ForEach(state.workspaces) { workspace in
                let connections = filtered(workspace.connections)
                if !connections.isEmpty || search.isEmpty {
                    Section {
                        ForEach(connections) { connection in
                            ConnectionRow(connection: connection)
                                .tag(connection.id)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deletingConnection = connection
                                    } label: { Label("Remover", systemImage: "trash") }
                                    Button {
                                        editing = ConnectionDraft(config: connection, workspaceID: workspace.id)
                                    } label: { Label("Editar", systemImage: "pencil") }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .leading) {
                                    if state.active[connection.id] != nil {
                                        Button {
                                            disconnect(connection.id)
                                        } label: { Label("Desconectar", systemImage: "bolt.slash") }
                                        .tint(.orange)
                                    }
                                }
                                .contextMenu { menu(for: connection, in: workspace) }
                        }
                        if connections.isEmpty {
                            Button {
                                newConnection(in: workspace.id)
                            } label: {
                                Label("Adicionar conexão", systemImage: "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                        }
                    } header: {
                        workspaceHeader(workspace)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("DBDeck")
        .searchable(text: $search, prompt: "Buscar conexões")
        .overlay {
            if state.workspaces.allSatisfy({ $0.connections.isEmpty }) && search.isEmpty {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Label("Preferências", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newConnection(in: nil) } label: {
                        Label("Nova conexão", systemImage: "cylinder.split.1x2")
                    }
                    Button {
                        newWorkspaceName = ""
                        showNewWorkspace = true
                    } label: {
                        Label("Novo workspace", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Adicionar", systemImage: "plus")
                } primaryAction: {
                    newConnection(in: nil)
                }
            }
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                ConnectionFormView(draft: draft)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsScreen() }
        }
        .alert("Novo workspace", isPresented: $showNewWorkspace) {
            TextField("Nome", text: $newWorkspaceName)
            Button("Criar") {
                let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
                state.addWorkspace(named: name.isEmpty ? "Workspace" : name)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Workspaces agrupam conexões — por cliente, ambiente ou projeto.")
        }
        .alert("Renomear workspace", isPresented: .init(
            get: { renamingWorkspace != nil },
            set: { if !$0 { renamingWorkspace = nil } }
        )) {
            TextField("Nome", text: $newWorkspaceName)
            Button("Salvar") {
                if let workspace = renamingWorkspace,
                   let index = state.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        state.workspaces[index].name = name
                        WorkspaceStore.save(state.workspaces)
                    }
                }
                renamingWorkspace = nil
            }
            Button("Cancelar", role: .cancel) { renamingWorkspace = nil }
        }
        .confirmationDialog(
            "Remover “\(deletingConnection?.name ?? "")”?",
            isPresented: .init(get: { deletingConnection != nil }, set: { if !$0 { deletingConnection = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover conexão", role: .destructive) {
                if let connection = deletingConnection {
                    if navigator.connectionID == connection.id { navigator.connectionID = nil }
                    state.deleteConnection(connection)
                    Haptics.success()
                }
                deletingConnection = nil
            }
        } message: {
            Text("A senha guardada no Keychain também é apagada.")
        }
        .confirmationDialog(
            "Remover o workspace “\(deletingWorkspace?.name ?? "")”?",
            isPresented: .init(get: { deletingWorkspace != nil }, set: { if !$0 { deletingWorkspace = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover workspace e conexões", role: .destructive) {
                if let workspace = deletingWorkspace {
                    if let id = navigator.connectionID, workspace.connections.contains(where: { $0.id == id }) {
                        navigator.connectionID = nil
                    }
                    for connection in workspace.connections {
                        KeychainManager.deletePassword(for: connection.id)
                        KeychainManager.deletePassword(for: connection.id, kind: .ssh)
                    }
                    state.deleteWorkspace(workspace)
                }
                deletingWorkspace = nil
            }
        } message: {
            Text("\(deletingWorkspace?.connections.count ?? 0) conexão(ões) serão removidas.")
        }
    }

    // MARK: - Partes

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        HStack {
            Text(workspace.name)
            Spacer()
            Menu {
                Button { newConnection(in: workspace.id) } label: {
                    Label("Nova conexão aqui", systemImage: "plus")
                }
                Button {
                    newWorkspaceName = workspace.name
                    renamingWorkspace = workspace
                } label: {
                    Label("Renomear", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) { deletingWorkspace = workspace } label: {
                    Label("Remover workspace", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Opções do workspace \(workspace.name)")
        }
    }

    @ViewBuilder
    private func menu(for connection: ConnectionConfig, in workspace: Workspace) -> some View {
        if state.active[connection.id] != nil {
            Button { disconnect(connection.id) } label: {
                Label("Desconectar", systemImage: "bolt.slash")
            }
        } else {
            Button {
                navigator.connectionID = connection.id
            } label: {
                Label("Conectar", systemImage: "bolt")
            }
        }
        Button {
            editing = ConnectionDraft(config: connection, workspaceID: workspace.id)
        } label: {
            Label("Editar", systemImage: "pencil")
        }
        Button {
            var copy = connection
            copy.id = UUID()
            copy.name = connection.name + " (cópia)"
            copy.password = KeychainManager.password(for: connection.id) ?? ""
            state.addConnection(copy, sshSecret: KeychainManager.password(for: connection.id, kind: .ssh), to: workspace.id)
        } label: {
            Label("Duplicar", systemImage: "plus.square.on.square")
        }
        if state.workspaces.count > 1 {
            Menu {
                ForEach(state.workspaces.filter { $0.id != workspace.id }) { target in
                    Button(target.name) { move(connection, to: target.id) }
                }
            } label: {
                Label("Mover para…", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) { deletingConnection = connection } label: {
            Label("Remover", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Sem conexões", systemImage: "cylinder.split.1x2")
        } description: {
            Text("Conecte-se a PostgreSQL, MySQL ou abra um arquivo SQLite.")
        } actions: {
            Button {
                newConnection(in: nil)
            } label: {
                Label("Nova conexão", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Ações

    private func filtered(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return connections }
        return connections.filter {
            $0.name.lowercased().contains(query)
                || $0.host.lowercased().contains(query)
                || $0.database.lowercased().contains(query)
                || $0.engine.displayName.lowercased().contains(query)
        }
    }

    private func newConnection(in workspaceID: UUID?) {
        if state.workspaces.isEmpty { state.addWorkspace(named: "Conexões") }
        let target = workspaceID ?? state.workspaces.first?.id
        editing = ConnectionDraft(config: ConnectionConfig(), workspaceID: target, isNew: true)
    }

    private func disconnect(_ id: UUID) {
        state.disconnect(id)
        navigator.resetTables(for: id)
        if navigator.connectionID == id { navigator.route = nil }
        Haptics.tap()
    }

    private func move(_ connection: ConnectionConfig, to workspaceID: UUID) {
        for index in state.workspaces.indices {
            state.workspaces[index].connections.removeAll { $0.id == connection.id }
        }
        if let index = state.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            state.workspaces[index].connections.append(connection)
        }
        WorkspaceStore.save(state.workspaces)
    }
}

/// O que o formulário de conexão recebe para abrir.
struct ConnectionDraft: Identifiable {
    var id: UUID { config.id }
    var config: ConnectionConfig
    var workspaceID: UUID?
    var isNew = false
}

// MARK: - Linha

private struct ConnectionRow: View {
    @Environment(AppState.self) private var state
    let connection: ConnectionConfig

    var body: some View {
        HStack(spacing: 12) {
            EngineBadge(engine: connection.engine, size: 38)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: state.connectionStatus[connection.id])
                        .padding(2)
                        .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                        .offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let color = ConnectionColor.color(for: connection.color) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(connection.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let message) = state.connectionStatus[connection.id] {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if connection.engine == .sqlite {
            return connection.sqlitePath.isEmpty ? "sem arquivo" : (connection.sqlitePath as NSString).lastPathComponent
        }
        let target = connection.database.isEmpty
            ? "\(connection.host):\(connection.port)"
            : "\(connection.host):\(connection.port)/\(connection.database)"
        return connection.username.isEmpty ? target : "\(connection.username)@\(target)"
    }
}
