import SwiftUI
import DBDeckCore

struct DatabaseBrowserView: View {
    let connection: ConnectionConfig
    let driver: any DatabaseDriver

    @State private var tables: [DatabaseTable] = []
    @State private var selectedTable: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        NavigationSplitView {
            List(tables, selection: $selectedTable) { table in
                Label {
                    Text(table.name)
                } icon: {
                    Image(systemName: table.kind == "view" ? "eye" : "tablecells")
                        .foregroundStyle(.secondary)
                }
                .tag(table.name)
            }
            .navigationTitle(connection.name)
            .overlay {
                if tables.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "Sem tabelas",
                        systemImage: "tablecells.badge.ellipsis",
                        description: Text("Este banco não tem tabelas ou a consulta falhou.")
                    )
                }
            }
        } detail: {
            if let table = selectedTable {
                TabView {
                    TableDataView(driver: driver, table: table)
                        .tabItem { Label("Dados", systemImage: "tablecells") }
                    StructureView(driver: driver, table: table)
                        .tabItem { Label("Estrutura", systemImage: "list.bullet.rectangle") }
                    SQLConsoleView(driver: driver)
                        .tabItem { Label("SQL", systemImage: "terminal") }
                }
            } else {
                ContentUnavailableView(
                    "Selecione uma tabela",
                    systemImage: "tablecells",
                    description: Text("Aba Dados, Estrutura e SQL ficam disponíveis aqui.")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItemGroup {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Menu {
                    Button("Dump do banco (.sql)…") {
                        Task { await exportDump() }
                    }
                    Button("Importar arquivo SQL…") {
                        Task { await importSQLFile() }
                    }
                } label: {
                    Label("Backup", systemImage: "externaldrive")
                }
                .disabled(isLoading)
            }
        }
        .task {
            await refresh()
        }
        .onChange(of: connection.id) { _, _ in
            Task { await refresh() }
        }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let notice {
                HStack {
                    Text(notice)
                    Spacer()
                }
                .font(.caption)
                .padding(8)
                .background(.thinMaterial)
                .padding(8)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    self.notice = nil
                }
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tables = try await driver.tables()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dump / Import

    private func exportDump() async {
        #if os(macOS)
        do {
            let sql = try await SQLDump.dump(driver: driver)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(connection.name.sanitized)-dump.sql"
            panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try sql.write(to: url, atomically: true, encoding: .utf8)
            notice = "Dump salvo em \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    private func importSQLFile() async {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let sql = try String(contentsOf: url, encoding: .utf8)
            let (statements, errors) = try await SQLDump.importSQL(sql, driver: driver)
            notice = "Importado: \(statements) statements executados\(errors.isEmpty ? "" : ", \(errors.count) erros")"
            if !errors.isEmpty {
                errorMessage = errors.prefix(3).joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }
}

extension String {
    var sanitized: String {
        replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
