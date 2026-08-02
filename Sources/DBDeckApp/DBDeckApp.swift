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
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            DetailView()
        }
        .navigationTitle("DBDeck")
    }
}

struct DetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let id = state.selectedConnectionID,
           let config = state.config(for: id),
           let driver = state.active[id] {
            DatabaseBrowserView(connection: config, driver: driver)
        } else if let id = state.selectedConnectionID {
            ConnectionPlaceholderView(connectionID: id)
        } else {
            ContentUnavailableView(
                "Nenhuma conexão selecionada",
                systemImage: "shippingbox",
                description: Text("Selecione uma conexão na barra lateral ou crie uma nova.")
            )
        }
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
                ContentUnavailableView(
                    "Falha na conexão",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .disconnected:
                ContentUnavailableView(
                    "Conexão inativa",
                    systemImage: "plug",
                    description: Text("Clique em Conectar para abrir esta conexão.")
                )
                Button("Conectar") {
                    Task { _ = await state.connect(connectionID) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
