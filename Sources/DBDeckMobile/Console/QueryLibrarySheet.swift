import SwiftUI
import DBDeckCore

/// Consultas salvas (globais) e histórico da sessão.
struct QueryLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let session: ConnectionSession
    let currentSQL: String
    let onPick: (String) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case history = "Histórico"
        case saved = "Salvas"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .history
    @State private var search = ""
    @State private var showingSavePrompt = false
    @State private var saveTitle = ""
    @State private var pendingSaveSQL = ""

    var body: some View {
        List {
            switch mode {
            case .history:
                ForEach(Array(filteredHistory.enumerated()), id: \.offset) { _, sql in
                    Button {
                        pick(sql)
                    } label: {
                        SQLPreview(sql: sql)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            pendingSaveSQL = sql
                            saveTitle = ""
                            showingSavePrompt = true
                        } label: { Label("Salvar", systemImage: "bookmark") }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button { pick(sql) } label: { Label("Usar no editor", systemImage: "square.and.pencil") }
                        Button {
                            pendingSaveSQL = sql
                            saveTitle = ""
                            showingSavePrompt = true
                        } label: { Label("Salvar…", systemImage: "bookmark") }
                        Button {
                            UIPasteboard.general.string = sql
                        } label: { Label("Copiar", systemImage: "doc.on.doc") }
                    }
                }
            case .saved:
                ForEach(filteredSaved) { query in
                    Button {
                        pick(query.sql)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(query.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            SQLPreview(sql: query.sql)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            state.removeSavedQuery(query.id)
                        } label: { Label("Excluir", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar")
        .overlay {
            if mode == .history && filteredHistory.isEmpty {
                emptyState(search.isEmpty ? "Sem histórico" : "Nada encontrado", icon: "clock.arrow.circlepath",
                           detail: search.isEmpty ? "As consultas executadas nesta sessão aparecem aqui." : nil)
            } else if mode == .saved && filteredSaved.isEmpty {
                emptyState(search.isEmpty ? "Nenhuma consulta salva" : "Nada encontrado", icon: "bookmark",
                           detail: search.isEmpty ? "Deslize uma consulta do histórico para salvá-la." : nil)
            }
        }
        .navigationTitle("Biblioteca")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Fechar") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pendingSaveSQL = currentSQL
                    saveTitle = ""
                    showingSavePrompt = true
                } label: {
                    Label("Salvar atual", systemImage: "bookmark.fill")
                }
                .disabled(currentSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Salvar consulta", isPresented: $showingSavePrompt) {
            TextField("Título", text: $saveTitle)
            Button("Salvar") {
                state.addSavedQuery(title: saveTitle, sql: pendingSaveSQL)
                mode = .saved
                Haptics.success()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Dê um título para encontrar depois.")
        }
        .onAppear {
            if session.queryHistory.isEmpty && !state.savedQueries.isEmpty { mode = .saved }
        }
    }

    private var filteredHistory: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return session.queryHistory }
        return session.queryHistory.filter { $0.lowercased().contains(query) }
    }

    private var filteredSaved: [SavedQuery] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return state.savedQueries }
        return state.savedQueries.filter {
            $0.title.lowercased().contains(query) || $0.sql.lowercased().contains(query)
        }
    }

    private func pick(_ sql: String) {
        Haptics.tap()
        onPick(sql)
        dismiss()
    }

    private func emptyState(_ title: String, icon: String, detail: String?) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: detail.map(Text.init))
    }
}

private struct SQLPreview: View {
    let sql: String

    var body: some View {
        Text(AttributedString(SQLSyntaxHighlighter.attributed(String(sql.flattenedSQL.prefix(400)), fontSize: 13)))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
