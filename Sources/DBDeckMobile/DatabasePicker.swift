import SwiftUI
import DBDeckCore

/// Bancos usados recentemente por conexão — o topo da lista é quase sempre onde se quer ir.
enum RecentDatabases {
    private static func key(_ connectionID: UUID) -> String { "recentDatabases.\(connectionID.uuidString)" }

    static func list(for connectionID: UUID) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(connectionID)) ?? []
    }

    static func record(_ database: String, for connectionID: UUID) {
        var list = list(for: connectionID)
        list.removeAll { $0 == database }
        list.insert(database, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: key(connectionID))
    }
}

/// Lista de bancos com busca, para escolher onde trabalhar.
///
/// Servidor com dezenas de bancos não cabe num menu: aqui há busca, os recentes no topo,
/// o banco padrão da conexão marcado e os bancos de sistema (`mysql`, `sys`,
/// `information_schema`, `template0`…) recolhidos no fim — raramente são o destino.
struct DatabaseList: View {
    let databases: [String]
    var current: String?
    var defaultDatabase: String?
    var recents: [String] = []
    var engine: SQLEngine
    var isLoading = false
    /// Instrução no topo (estado "nenhum banco escolhido" da tela de tabelas).
    var prompt: String?
    var onPick: (String) -> Void
    var onRefresh: (() async -> Void)?
    var onCreate: (() -> Void)?

    @State private var search = ""
    @State private var showSystem = false

    private static let systemNames: Set<String> = [
        "information_schema", "performance_schema", "mysql", "sys",
        "template0", "template1",
    ]

    private func isSystem(_ name: String) -> Bool { Self.systemNames.contains(name.lowercased()) }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query)
    }

    private var recentVisible: [String] {
        guard query.isEmpty else { return [] }
        return recents.filter { databases.contains($0) }
    }

    private var userDatabases: [String] {
        databases.filter { !isSystem($0) && matches($0) }
    }

    private var systemDatabases: [String] {
        databases.filter { isSystem($0) && matches($0) }
    }

    private var systemExpanded: Bool {
        showSystem || !query.isEmpty || userDatabases.isEmpty
    }

    var body: some View {
        List {
            if let prompt, query.isEmpty {
                Section {
                    Label {
                        Text(prompt).font(.subheadline).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "hand.point.down.fill").foregroundStyle(.tint)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            if !recentVisible.isEmpty {
                Section("Recentes") {
                    ForEach(recentVisible, id: \.self) { row($0) }
                }
            }
            if !userDatabases.isEmpty {
                Section {
                    ForEach(userDatabases, id: \.self) { row($0) }
                } header: {
                    Text(query.isEmpty ? "\(userDatabases.count) bancos" : "Resultados")
                }
            }
            if !systemDatabases.isEmpty {
                Section {
                    // Aberto ao buscar (quem digitou "mysql" quer vê-lo) e quando só há
                    // bancos de sistema — recolhido, a lista pareceria vazia.
                    if systemExpanded {
                        ForEach(systemDatabases, id: \.self) { row($0) }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy) { showSystem.toggle() }
                    } label: {
                        HStack {
                            Text("Sistema (\(systemDatabases.count))")
                            Spacer()
                            if query.isEmpty && !userDatabases.isEmpty {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showSystem ? 90 : 0))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let onCreate, engine != .sqlite {
                Section {
                    Button {
                        onCreate()
                    } label: {
                        Label("Novo banco de dados", systemImage: "plus.circle.fill")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar banco")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .refreshable { await onRefresh?() }
        .overlay {
            if databases.isEmpty {
                if isLoading {
                    ProgressView("Listando bancos…")
                } else {
                    ContentUnavailableView(
                        "Nenhum banco listado",
                        systemImage: "cylinder.split.1x2",
                        description: Text("O usuário pode não ter permissão para listar bancos. Puxe para tentar de novo.")
                    )
                }
            } else if userDatabases.isEmpty && systemDatabases.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func row(_ name: String) -> some View {
        Button {
            Haptics.selection()
            onPick(name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSystem(name) ? "gearshape" : "cylinder.split.1x2.fill")
                    .foregroundStyle(name == current ? Color.accentColor : (isSystem(name) ? .secondary : engine.accent))
                    .frame(width: 24)
                Text(name)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if name == defaultDatabase {
                    Text("padrão")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                if name == current {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        // Linha de lista, não link: sem isto o texto herda a cor de destaque.
        .tint(.primary)
        .accessibilityAddTraits(name == current ? .isSelected : [])
    }
}

/// Folha de troca de banco, aberta pelo título da tela de tabelas.
struct DatabasePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID
    let databases: [String]
    var current: String?
    var defaultDatabase: String?
    var engine: SQLEngine
    var isLoading: Bool
    var onPick: (String) -> Void
    var onRefresh: () async -> Void
    var onCreate: () -> Void

    var body: some View {
        DatabaseList(
            databases: databases,
            current: current,
            defaultDatabase: defaultDatabase,
            recents: RecentDatabases.list(for: connectionID),
            engine: engine,
            isLoading: isLoading,
            onPick: { name in
                onPick(name)
                dismiss()
            },
            onRefresh: onRefresh,
            onCreate: {
                dismiss()
                onCreate()
            }
        )
        .navigationTitle("Banco de dados")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fechar") { dismiss() }
            }
        }
    }
}
