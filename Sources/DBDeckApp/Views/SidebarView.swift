import SwiftUI
import DBDeckCore

struct NewConnectionTarget: Identifiable {
    let workspaceID: UUID
    var id: UUID { workspaceID }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state

    @State private var newWorkspaceName = ""
    @State private var showingNewWorkspace = false
    @State private var newConnectionWorkspace: NewConnectionTarget?
    @State private var editingConnection: ConnectionConfig?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedConnectionID) {
            ForEach(state.workspaces) { workspace in
                workspaceSection(workspace)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(state.workspaces) { workspace in
                        Button("em \"\(workspace.name)\"") {
                            newConnectionWorkspace = NewConnectionTarget(workspaceID: workspace.id)
                        }
                    }
                } label: {
                    Label("Nova conexão", systemImage: "plus")
                }
                .disabled(state.workspaces.isEmpty)

                Button {
                    showingNewWorkspace = true
                } label: {
                    Label("Novo workspace", systemImage: "folder.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showingNewWorkspace) {
            VStack(spacing: 16) {
                Text("Novo workspace")
                    .font(.headline)
                TextField("Nome", text: $newWorkspaceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                HStack {
                    Button("Cancelar") { showingNewWorkspace = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Criar") {
                        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            state.addWorkspace(named: name)
                            showingNewWorkspace = false
                            newWorkspaceName = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionEditView(
                config: connection,
                workspaceID: state.workspace(for: connection.id)?.id
            )
        }
        .sheet(item: $newConnectionWorkspace) { target in
            ConnectionEditView(config: ConnectionConfig(), workspaceID: target.workspaceID)
        }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: state.selectedConnectionID) { _, newValue in
            guard let id = newValue, state.config(for: id) != nil else { return }
            if state.active[id] == nil {
                Task {
                    let ok = await state.connect(id)
                    if !ok {
                        if case .failed(let message) = state.connectionStatus[id] {
                            errorMessage = message
                        } else {
                            errorMessage = "Falha ao conectar."
                        }
                    }
                }
            }
        }
    }

    private func workspaceSection(_ workspace: Workspace) -> some View {
        Section(workspace.name) {
            ForEach(workspace.connections) { connection in
                connectionRow(connection)
            }
        }
        .contextMenu {
            Button("Nova conexão…") {
                newConnectionWorkspace = NewConnectionTarget(workspaceID: workspace.id)
            }
            Divider()
            Button("Remover workspace", role: .destructive) {
                state.deleteWorkspace(workspace)
            }
        }
    }

    private func connectionRow(_ connection: ConnectionConfig) -> some View {
        ConnectionRow(connection: connection)
            .tag(connection.id)
            .contextMenu {
                Button("Conectar / Desconectar") {
                    toggle(connection)
                }
                Button("Editar…") {
                    editingConnection = connection
                }
                Divider()
                Button("Remover", role: .destructive) {
                    state.deleteConnection(connection)
                }
            }
    }

    private func toggle(_ connection: ConnectionConfig) {
        if state.active[connection.id] != nil {
            state.disconnect(connection.id)
        } else {
            Task { _ = await state.connect(connection.id) }
        }
    }
}

private struct ConnectionRow: View {
    @Environment(AppState.self) private var state
    let connection: ConnectionConfig

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connection.engine.symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .lineLimit(1)
                Text(connection.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusDot(status: state.connectionStatus[connection.id] ?? .disconnected)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusDot: View {
    let status: ConnectionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(helpText)
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
