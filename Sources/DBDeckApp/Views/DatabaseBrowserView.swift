import SwiftUI
import DBDeckCore

// MARK: - Coluna de tabelas (segunda coluna do NavigationSplitView)

struct TablesColumn: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let id = state.selectedConnectionID, state.active[id] != nil {
                TableSidebar(connectionID: id, session: state.session(for: id))
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Sem tabelas",
                    systemImage: "tablecells",
                    description: Text("Selecione uma conexão para ver as tabelas.")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
    }
}

private struct TableSidebar: View {
    @Environment(AppState.self) private var state
    let connectionID: UUID
    let session: ConnectionSession

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showNewDatabase = false

    /// Banco fixado no cadastro da conexão (vazio = navegar todos os bancos do servidor).
    private var fixedDatabase: String {
        state.config(for: connectionID)?.database ?? ""
    }
    private var browsingServer: Bool { fixedDatabase.isEmpty }
    private var currentDatabase: String? {
        // O banco trocado na sessão vale mais que o fixo do cadastro — a conexão com
        // banco padrão também pode navegar para os demais bancos do servidor.
        session.activeDatabase ?? (browsingServer ? nil : fixedDatabase)
    }

    var body: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(session.filteredTables) { table in
                    TableRow(table: table)
                        .tag(table.name)
                        .contextMenu {
                            Button("Abrir") { session.openTable(table.name) }
                            Button("Abrir em nova aba") { session.openTable(table.name, newTab: true) }
                            Divider()
                            Button("Exportar tabela (.sql)…") { exportTable(table) }
                        }
                }
            } header: {
                HStack {
                    Text("Tabelas")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("\(session.tables.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .overlay {
            if browsingServer && currentDatabase == nil {
                ContentUnavailableView {
                    Label("Escolha um banco", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Selecione um banco do servidor na lateral.")
                } actions: {
                    if state.config(for: connectionID)?.engine != .sqlite {
                        Button("Criar banco de dados…") { showNewDatabase = true }
                    }
                }
            } else if session.tables.isEmpty && !isLoading {
                ContentUnavailableView("Sem tabelas", systemImage: "tablecells.badge.ellipsis",
                                       description: Text("Este banco não tem tabelas."))
            } else if session.filteredTables.isEmpty && !session.tableFilter.isEmpty {
                ContentUnavailableView.search(text: session.tableFilter)
            }
        }
        .task(id: connectionID) {
            if currentDatabase != nil, !session.tablesLoaded { await reload() }
        }
        .onChange(of: session.activeDatabase) { _, db in
            if db != nil { Task { await reload() } }
        }
        .alert("Erro", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showNewDatabase) {
            if let config = state.config(for: connectionID) {
                NewDatabaseSheet(connection: config) { created in
                    Task { await state.switchDatabase(connectionID, to: created) }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Filtrar tabelas", text: Bindable(session).tableFilter)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !session.tableFilter.isEmpty {
                Button { session.tableFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Recarregar tabelas")
            .disabled(isLoading || currentDatabase == nil)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { session.selectedTab?.tableName },
            set: { if let name = $0 { session.openTable(name) } }
        )
    }

    private func reload() async {
        guard let driver = state.active[connectionID] else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            session.tables = try await driver.tables()
            session.tablesLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exporta DDL + dados de uma tabela num arquivo .sql.
    private func exportTable(_ table: DatabaseTable) {
        guard let driver = state.active[connectionID] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table.name.sanitized).sql"
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let sql = try await SQLDump.dumpTable(driver: driver, table: table)
                try sql.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Coluna do editor (detail do NavigationSplitView)

struct EditorColumn: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let id = state.selectedConnectionID,
               let config = state.config(for: id),
               let driver = state.active[id] {
                EditorArea(connection: config, driver: driver, session: state.session(for: id))
                    .id(id)
            } else if let id = state.selectedConnectionID {
                ConnectionPlaceholderView(connectionID: id)
            } else {
                WelcomeView()
            }
        }
    }
}

private struct EditorArea: View {
    @Environment(AppState.self) private var state
    let connection: ConnectionConfig
    let driver: any DatabaseDriver
    let session: ConnectionSession

    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showDumpSheet = false
    @State private var showNewDatabase = false
    /// Progresso do import (bytes lidos) — arquivos grandes levam minutos.
    @State private var importProgress: (statements: Int, bytes: Int, errors: Int)?
    /// O último notice veio com erros — muda o ícone do toast (sem checkmark verde).
    @State private var noticeIsWarning = false

    var body: some View {
        VStack(spacing: 0) {
            if !session.tabs.isEmpty {
                EditorTabBar(session: session, onNewQuery: { session.newQuery() })
            }
            editorPanes
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(connection.name)
        .navigationSubtitle(liveSubtitle)
        .toolbar { toolbarContent }
        .alert("Erro", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .overlay(alignment: .bottom) { noticeBar }
        .sheet(isPresented: $showDumpSheet) {
            DumpExportSheet(
                connectionID: connection.id,
                database: session.activeDatabase ?? (connection.database.isEmpty ? nil : connection.database),
                title: currentDatabase ?? connection.name
            )
        }
        .sheet(isPresented: $showNewDatabase) {
            NewDatabaseSheet(connection: connection) { created in
                Task { await state.switchDatabase(connection.id, to: created) }
            }
        }
    }

    @ViewBuilder
    private var editorPanes: some View {
        if session.tabs.isEmpty {
            emptyEditor
        } else {
            // O ZStack com TODAS as abas é SEMPRE o primeiro filho do HStack: abrir ou
            // fechar o painel dividido não pode mudar a identidade estrutural das views
            // das abas (recriá-las descartaria em silêncio edições não salvas, filtro,
            // ordenação e página — ignorando o diálogo de guarda).
            HStack(spacing: 0) {
                ZStack {
                    ForEach(session.tabs) { tab in
                        tabContent(tab, pane: "main", isActive: tab.id == session.selectedTabID)
                            .opacity(tab.id == session.selectedTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == session.selectedTabID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Os grids são NSTableView reais: opacity(0)/allowsHitTesting não
                // resignam o first responder do AppKit, então trocar de aba deixaria
                // o teclado (type-to-edit, Backspace→NULL, setas) caindo no grid
                // INVISÍVEL da aba anterior. Resignar aqui também commita qualquer
                // field editor em curso antes de a aba sumir.
                .onChange(of: session.selectedTabID) { _, _ in
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }

                if let split = session.splitTab {
                    Divider()
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: split.icon).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(split.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Button { session.closeSplit() } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Fechar painel lateral")
                        }
                        .padding(.horizontal, 10).frame(height: 26).background(.bar)
                        Divider()
                        // isActive: false — atalhos (⌘⏎/⌘S) pertencem só à aba selecionada
                        // do painel principal; o painel lateral é referência visual.
                        tabContent(split, pane: "split", isActive: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// `pane` entra no `.id` para o mesmo tab poder aparecer no painel principal e no
    /// dividido sem colisão de identidade — e para trocar o tab do painel dividido
    /// (ou reusar a posição com outro console) nunca herdar @State do anterior.
    @ViewBuilder
    private func tabContent(_ tab: EditorTab, pane: String, isActive: Bool) -> some View {
        switch tab.kind {
        case .table(let name):
            TableEditorView(driver: driver, tab: tab, table: name, isActive: isActive)
                .id("\(pane)-\(tab.id)#\(name)")
        case .query:
            SQLConsoleView(driver: driver, tab: tab, session: session, isActive: isActive)
                .id("\(pane)-\(tab.id)")
        }
    }

    private var emptyEditor: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells").font(.system(size: 46, weight: .thin)).foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Escolha uma tabela").font(.title3.weight(.semibold))
                Text("Selecione uma tabela na lateral ou abra um console SQL.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // Sem keyboardShortcut aqui: o botão "Nova consulta" do toolbar (sempre
            // montado) já registra ⌘T — registrar nos dois seria despacho indefinido.
            Button { session.newQuery() } label: { Label("Nova consulta SQL", systemImage: "terminal") }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Banco realmente aberto agora: o trocado em sessão (⌘P/sidebar) vence o fixo do cadastro.
    private var currentDatabase: String? {
        if let active = session.activeDatabase, !active.isEmpty { return active }
        if connection.engine == .sqlite {
            return connection.sqlitePath.isEmpty ? nil : (connection.sqlitePath as NSString).lastPathComponent
        }
        return connection.database.isEmpty ? nil : connection.database
    }

    private var liveSubtitle: String {
        guard connection.engine != .sqlite else { return connection.displaySubtitle }
        return "\(connection.host):\(connection.port)/\(currentDatabase ?? "")"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Espaçador flexível: empurra o grupo até a borda direita da janela
        // (só o placement .primaryAction deixava o grupo logo após a sidebar).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Identificação rápida: cor da conexão + banco ativo, alinhado à direita do toolbar.
            HStack(spacing: 5) {
                Circle()
                    .fill(ConnectionColor.color(for: connection.color) ?? connection.engine.accent)
                    .frame(width: 6, height: 6)
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(connection.engine.accent)
                Text(currentDatabase ?? "sem banco")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(currentDatabase == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quinary, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            // Respiro entre esta pílula e a cápsula de vidro que o sistema desenha
            // em volta do grupo de toolbar — sem isso as bordas ficam coladas.
            .padding(3)
            .help("Banco ativo desta conexão")

            Button { session.newQuery() } label: { Label("Nova consulta", systemImage: "plus.square") }
                .help("Nova consulta SQL (⌘T)")
                .keyboardShortcut("t", modifiers: .command)

            // ⌘W fica no atalho global do ContentView (cascata aba → conexão → janela).
            Button { session.closeSelected() } label: { Label("Fechar aba", systemImage: "xmark.square") }
                .help("Fechar aba (⌘W)")
                .disabled(session.selectedTab == nil)

            Button {
                if let tab = session.selectedTab, case .query = tab.kind {
                    tab.showLibrary.toggle()
                } else {
                    let tab = session.newQuery()
                    tab.showLibrary = true
                }
            } label: { Label("Biblioteca", systemImage: "books.vertical") }
                .help("Consultas salvas e histórico")

            Menu {
                Button("Dump do banco (.sql)…") { showDumpSheet = true }
                    // Sem banco resolvido não há o que dumpar (MySQL falharia no SHOW TABLES,
                    // Postgres cairia no banco de manutenção) — mesma guarda da sidebar.
                    .disabled(currentDatabase == nil && connection.engine != .sqlite)
                Button("Importar arquivo SQL…") { Task { await importSQLFile() } }
                if connection.engine != .sqlite {
                    Divider()
                    Button("Novo banco de dados…") { showNewDatabase = true }
                }
            } label: { Label("Backup", systemImage: "externaldrive") }
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var noticeBar: some View {
        if let importProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Importando… \(importProgress.statements) statements · \(ByteCountFormatter.string(fromByteCount: Int64(importProgress.bytes), countStyle: .file))")
                    .font(.callout).monospacedDigit()
                // Erros aparecem ENQUANTO acontecem — descobrir só no fim de um arquivo
                // de gigabytes (dezenas de minutos) é o mesmo que nunca descobrir.
                if importProgress.errors > 0 {
                    Label("\(importProgress.errors) erros", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 16)
        } else if let notice {
            HStack(spacing: 8) {
                Image(systemName: noticeIsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(noticeIsWarning ? .orange : .green)
                Text(notice).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { self.notice = nil }
            }
        }
    }

    private func importSQLFile() async {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        importProgress = (0, 0, 0)
        defer { isBusy = false; importProgress = nil }
        do {
            // Streaming a partir do arquivo: um dump de centenas de MB não cabe
            // confortavelmente numa String só para ser fatiado depois.
            let (statements, errors) = try await SQLDump.importSQL(fileURL: url, driver: driver) { done, bytes, failed in
                Task { @MainActor in importProgress = (done, bytes, failed) }
            }
            noticeIsWarning = !errors.isEmpty
            withAnimation { notice = "Importado: \(statements) statements\(errors.isEmpty ? "" : " · \(errors.count) erros")" }
            if !errors.isEmpty { errorMessage = errors.prefix(3).joined(separator: "\n\n") }
        } catch {
            // Abortos (erros em série, cancelamento, I/O) chegam aqui — a mensagem
            // do DumpError.tooManyErrors já diz quantos falharam e mostra o último.
            errorMessage = error.localizedDescription
        }
        #endif
    }
}

// MARK: - Auxiliares

private struct TableRow: View {
    let table: DatabaseTable
    var body: some View {
        Label {
            Text(table.name).lineLimit(1)
        } icon: {
            Image(systemName: table.kind == "view" ? "eye" : "tablecells")
                .foregroundStyle(table.kind == "view" ? Color.purple : Color.accentColor)
        }
    }
}

extension String {
    var sanitized: String {
        replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}
