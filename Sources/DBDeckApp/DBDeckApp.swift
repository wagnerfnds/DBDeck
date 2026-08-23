import SwiftUI
import DBDeckCore

@main
struct DBDeckApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
        // Sem título no toolbar: com a sidebar recolhida (⌘B) o texto "DBDeck" ficava
        // espremido sobre o divisor de colunas. O chip de banco/cor já identifica o contexto.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showPalette = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            TablesColumn()
        } detail: {
            EditorColumn()
        }
        .background {
            // Atalhos globais: ⌘P abre a paleta; ⌘B esconde/mostra a coluna de conexões.
            Button("") { showPalette = true }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
            Button("") {
                withAnimation {
                    columnVisibility = columnVisibility == .doubleColumn ? .all : .doubleColumn
                }
            }
            .keyboardShortcut("b", modifiers: .command)
            .hidden()
            // ⌘R recarrega a aba selecionada (a view da aba observa reloadRequest).
            Button("") {
                if let id = state.selectedConnectionID, state.active[id] != nil {
                    state.session(for: id).selectedTab?.reloadRequest += 1
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()
            // ⌘W em cascata: fecha a aba selecionada; sem abas, desconecta a conexão
            // ativa; sem conexões, aí sim fecha a janela (comportamento padrão).
            Button("") { handleCloseShortcut() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
        .overlay {
            if showPalette {
                CommandPalette(isPresented: $showPalette)
                    .transition(.opacity)
            }
        }
    }

    private func handleCloseShortcut() {
        if let id = state.selectedConnectionID, state.active[id] != nil {
            let session = state.session(for: id)
            if session.selectedTab != nil {
                session.closeSelected()
                return
            }
            state.disconnect(id)
            return
        }
        // Nenhuma conexão selecionada ativa; se outra ainda estiver aberta, fecha ela.
        if let otherID = state.active.keys.first {
            state.disconnect(otherID)
            return
        }
        NSApp.keyWindow?.performClose(nil)
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
            VStack(spacing: 8) {
                Text("DBDeck")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Seu banco de dados, à mão.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("Selecione uma conexão na lateral ou crie uma nova para começar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ConnectionPlaceholderView: View {
    @Environment(AppState.self) private var state
    let connectionID: UUID

    var body: some View {
        VStack(spacing: 16) {
            let status = state.connectionStatus[connectionID] ?? .disconnected
            switch status {
            case .connecting:
                ProgressView("Conectando…")
            case .connected:
                EmptyView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Falha na conexão", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Tentar novamente") {
                        Task { _ = await state.connect(connectionID) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .disconnected:
                ContentUnavailableView {
                    Label("Conexão inativa", systemImage: "plug")
                } description: {
                    Text("Clique em Conectar para abrir esta conexão.")
                } actions: {
                    Button("Conectar") {
                        Task { _ = await state.connect(connectionID) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
