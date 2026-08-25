import SwiftUI
import DBDeckCore

struct SQLConsoleView: View {
    @Environment(AppSettings.self) private var settings
    let driver: any DatabaseDriver
    let tab: EditorTab
    let session: ConnectionSession
    /// Só a aba visível/selecionada registra atalhos de teclado. As abas ocultas
    /// continuam montadas (ZStack com opacity 0) e um ⌘⏎ registrado nelas roubaria
    /// o atalho da aba visível — executando o SQL da aba errada.
    var isActive: Bool = true

    @State private var result: QueryResult?
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var isShowingEditor = true
    @State private var selectedCell: EditCoord?
    @State private var selectedRow: Int?
    /// Cursor e seleção do editor — decidem O QUE o ⌘⏎ executa.
    @State private var editorSelection = EditorSelectionState()
    /// Vivo só enquanto uma execução está em curso; cancelá-lo interrompe a leitura.
    @State private var cancelToken: CancelToken?
    /// A leitura em curso, para cancelar a Task: no Postgres é o cancelamento da Task
    /// que manda o CancelRequest ao servidor.
    @State private var queryTask: Task<QueryResult, any Error>?
    /// O último comando do lote era um SELECT — muda o texto do estado vazio entre
    /// "não retornou linhas" e "comando sem resultado de linhas".
    @State private var lastWasSelect = false
    /// Fração do editor no INÍCIO do arrasto do divisor (o delta aplica sobre ela).
    @State private var dragStartFraction: Double?

    private var showLibrary: Bool { tab.showLibrary }

    private var sql: Binding<String> { Bindable(tab).sqlText }

    var body: some View {
        HStack(spacing: 0) {
            console
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showLibrary {
                Divider()
                QueryLibraryPanel(
                    session: session,
                    currentSQL: sql.wrappedValue,
                    onPick: { picked, title in
                        sql.wrappedValue = picked
                        if let title { tab.title = title }
                    }
                )
                .frame(width: 280)
                .transition(.move(edge: .trailing))
            }
        }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var console: some View {
        // Editor em cima, resultados embaixo, divisor arrastável no meio — a fração
        // vive na aba (EditorTab.editorFraction), então sobrevive à troca de abas.
        GeometryReader { geo in
            VStack(spacing: 0) {
                editorPane
                    .frame(height: isShowingEditor
                        ? max(120, geo.size.height * tab.editorFraction)
                        : nil)

                if isShowingEditor {
                    splitHandle(totalHeight: geo.size.height)
                }

                resultsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Consulta SQL")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { isShowingEditor.toggle() }
                } label: {
                    Image(systemName: isShowingEditor ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            if isShowingEditor {
                SQLEditorView(
                    text: sql,
                    placeholder: "SELECT * FROM minha_tabela LIMIT 100;",
                    selection: editorSelection,
                    completions: { text, cursor in
                        SQLCompletion.suggestions(text: text, cursor: cursor, catalog: session.completionCatalog)
                    },
                    prepareCompletions: { text, cursor in
                        // As colunas chegam por consulta de metadados: pedidas quando a
                        // tabela é citada, já estão em memória quando o `alias.` é digitado.
                        let statement = SQLDump.statements(in: text).first { $0.contains(cursor) }?.sql ?? text
                        session.prefetchColumns(
                            of: SQLCompletion.referencedTables(in: statement).map(\.table),
                            using: driver
                        )
                    }
                )
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            HStack {
                Button {
                    Task { await run(.selectionOrAll) }
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            editorSelection.hasSelection ? "Executar seleção" : "Executar",
                            systemImage: "play.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || sql.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // nil desregistra o atalho quando a aba está oculta/no split.
                .keyboardShortcut(isActive ? KeyboardShortcut(.return, modifiers: .command) : nil)

                Button {
                    Task { await run(.statementAtCursor) }
                } label: {
                    Label("Comando sob o cursor", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .labelStyle(.iconOnly)
                }
                .disabled(isRunning || sql.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(isActive ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                .help("Executa só o comando onde o cursor está (⌘⇧⏎)")

                if isRunning {
                    Button("Cancelar") { cancelRunningQuery() }
                        .keyboardShortcut(isActive ? KeyboardShortcut(".", modifiers: .command) : nil)
                        .help("Interrompe a leitura do resultado (⌘.)")
                }

                Button {
                    editorSelection.formatSQL()
                } label: {
                    Label("Formatar", systemImage: "wand.and.stars")
                        .labelStyle(.iconOnly)
                }
                .disabled(sql.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Formata a seleção ou a consulta inteira (⇧⌥F)")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab.showLibrary.toggle() }
                } label: {
                    Label("Biblioteca", systemImage: "books.vertical")
                }
                .foregroundStyle(showLibrary ? Color.accentColor : .primary)
                .help("Consultas salvas e histórico")

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let result, !result.columns.isEmpty {
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.label) { exportResult(result, format: format) }
                        }
                    } label: {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Exportar o resultado (CSV, JSON ou SQL)")
                }
            }
        }
        .padding(12)
    }

    /// Divisor arrastável entre editor e resultados (estilo Sequel Ace).
    private func splitHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Divider()
            // Área de pega generosa; o traço visual continua fino.
            Color.clear
                .frame(height: 9)
                .contentShape(Rectangle())
        }
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    let base = dragStartFraction ?? tab.editorFraction
                    dragStartFraction = base
                    guard totalHeight > 0 else { return }
                    let proposed = base + gesture.translation.height / totalHeight
                    tab.editorFraction = min(0.85, max(0.15, proposed))
                }
                .onEnded { _ in dragStartFraction = nil }
        )
    }

    @ViewBuilder
    private var resultsPane: some View {
        if let errorMessage {
            VStack {
                HStack {
                    Text(errorMessage)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
                Spacer()
            }
        } else if let result {
            if result.columns.isEmpty {
                VStack {
                    Spacer()
                    Text(lastWasSelect
                        ? "A consulta não retornou linhas."
                        : "Comando executado sem resultado de linhas.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                readOnlyGrid(result)
            }
        } else {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "Console SQL",
                    systemImage: "terminal",
                    description: Text("Escreva uma consulta e clique em Executar (⌘⏎).")
                )
                Spacer()
            }
        }
    }

    /// O que o atalho deve executar.
    private enum RunScope {
        /// ⌘⏎ — a seleção quando existe, senão o editor inteiro.
        case selectionOrAll
        /// ⌘⇧⏎ — só o comando onde o cursor está.
        case statementAtCursor
    }

    /// Os comandos a executar, com a faixa que cada um ocupa NO EDITOR (não no recorte):
    /// é a faixa que destaca o comando que falhar. A regra em si vive no core, testada.
    private func statementsToRun(_ scope: RunScope) -> [SQLStatement] {
        switch scope {
        case .selectionOrAll:
            return SQLRunTarget.statements(
                in: sql.wrappedValue,
                selection: editorSelection.hasSelection ? editorSelection.range : nil
            )
        case .statementAtCursor:
            return SQLRunTarget.statement(in: sql.wrappedValue, at: editorSelection.range.location)
                .map { [$0] } ?? []
        }
    }

    private func run(_ scope: RunScope) async {
        let statements = statementsToRun(scope)
        guard !statements.isEmpty else { return }

        editorSelection.dismissCompletions()
        let token = CancelToken()
        cancelToken = token
        isRunning = true
        errorMessage = nil
        result = nil
        message = nil
        selectedCell = nil
        selectedRow = nil
        defer {
            isRunning = false
            cancelToken = nil
        }

        let start = Date()
        var executed = 0
        var lastResult: QueryResult?
        var lastAffected: Int?
        var wasSelect = false

        for (index, statement) in statements.enumerated() {
            if token.isCancelled { break }
            session.recordQuery(statement.sql, limit: settings.historyLimit)
            do {
                if driver.isSelectStatement(statement.sql) {
                    let statementSQL = statement.sql
                    let reading = Task { try await collect(statementSQL, cancel: token) }
                    queryTask = reading
                    defer { queryTask = nil }
                    lastResult = try await reading.value
                    lastAffected = nil
                    wasSelect = true
                } else {
                    lastAffected = try await driver.execute(statement.sql)
                    lastResult = nil
                    wasSelect = false
                }
                executed += 1
            } catch is CancellationError {
                break
            } catch {
                // Num script de dezenas de comandos, achar o que falhou pelo texto da
                // mensagem do servidor é procurar agulha no palheiro: seleciona-se o
                // comando no editor e o cursor vai junto.
                editorSelection.select(NSRange(location: statement.location, length: statement.length))
                errorMessage = statements.count > 1
                    ? "Comando \(index + 1) de \(statements.count) — \(error.localizedDescription)"
                    : error.localizedDescription
                if executed > 0 {
                    message = "\(executed) de \(statements.count) executado\(executed == 1 ? "" : "s") antes do erro"
                }
                return
            }
        }

        lastWasSelect = wasSelect
        result = lastResult
        message = summary(
            statements: statements.count,
            executed: executed,
            cancelled: token.isCancelled,
            rows: lastResult?.rows.count,
            affected: lastAffected,
            start: start
        )
    }

    /// Lê o resultado em lotes em vez de esperar o conjunto inteiro: é o que dá efeito ao
    /// Cancelar — um `query` só volta quando o servidor terminou, e aí não há o que
    /// cancelar. O que já chegou é mantido quando se cancela no meio.
    private func collect(_ statement: String, cancel token: CancelToken) async throws -> QueryResult {
        // Preenchido na thread de I/O do driver, uma chamada por vez.
        final class Sink: @unchecked Sendable {
            var columns: [String] = []
            var rows: [[SQLValue]] = []
        }
        let sink = Sink()
        do {
            // previewLimit nil: o console mostra os valores íntegros de propósito.
            try await driver.streamQuery(statement, batchSize: 500, previewLimit: nil) { batch in
                if token.isCancelled { throw CancellationError() }
                if sink.columns.isEmpty { sink.columns = batch.columns }
                sink.rows.append(contentsOf: batch.rows)
            }
        } catch {
            // Cancelamento pode chegar de três jeitos: CancellationError (lote recusado ou
            // Task cancelada), ou o erro do próprio servidor depois do KILL QUERY /
            // sqlite3_interrupt. Depois de pedir para cancelar, qualquer um deles é o
            // resultado esperado — não um erro a mostrar.
            if error is CancellationError || token.isCancelled {
                return QueryResult(columns: sink.columns, rows: sink.rows)
            }
            throw error
        }
        return QueryResult(columns: sink.columns, rows: sink.rows)
    }

    /// Três frentes, porque nenhuma cobre tudo: o token recusa o próximo lote, a Task
    /// cancelada faz o PostgresNIO mandar CancelRequest, e `cancelRunningQuery` cobre
    /// MySQL (KILL QUERY) e SQLite (interrupt) — que não reagem a Task cancelada.
    private func cancelRunningQuery() {
        cancelToken?.cancel()
        queryTask?.cancel()
        let driver = self.driver
        Task { await driver.cancelRunningQuery() }
    }

    private func summary(
        statements: Int,
        executed: Int,
        cancelled: Bool,
        rows: Int?,
        affected: Int?,
        start: Date
    ) -> String {
        var parts: [String] = []
        if cancelled { parts.append("Cancelado") }
        if statements > 1 {
            parts.append("\(executed) de \(statements) comando\(statements == 1 ? "" : "s")")
        }
        if let rows {
            parts.append("\(rows) linha\(rows == 1 ? "" : "s")")
        } else if let affected {
            parts.append("\(affected) linha\(affected == 1 ? "" : "s") afetada\(affected == 1 ? "" : "s")")
        } else if statements == 1 && !cancelled {
            parts.append("OK")
        }
        parts.append(elapsed(since: start))
        return parts.joined(separator: " · ")
    }

    private func elapsed(since start: Date) -> String {
        let ms = Date().timeIntervalSince(start) * 1000
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }

    /// Grid nativo read-only: só as linhas visíveis existem, então um SELECT de
    /// dezenas de milhares de linhas renderiza instantâneo — e de quebra ganha
    /// seleção de célula, ⌘C e cópia de linha.
    private func readOnlyGrid(_ result: QueryResult) -> some View {
        DataGridView(
            columns: result.columns.map { GridColumnSpec(name: $0) },
            rows: result.rows,
            rowNumberStart: 1,
            editable: false,
            selectedCell: $selectedCell,
            selectedRow: $selectedRow,
            onSort: nil,
            onSetValue: nil
        )
        .gridStyle(rowHeight: settings.rowHeight, zebra: settings.zebraStripes)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func exportResult(_ result: QueryResult, format: ExportFormat) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "consulta.\(format.fileExtension)"
        panel.allowedContentTypes = [.init(filenameExtension: format.fileExtension) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // O console guarda os valores ÍNTEGROS de propósito (sem preview) — a
        // exportação sai fiel, inclusive no SQL.
        let text = ResultExporter.export(
            format: format,
            columns: result.columns,
            rows: result.rows,
            tableName: "consulta",
            engine: driver.engine
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            message = "\(format.label) salvo · \(result.rows.count) linhas"
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }
}

// MARK: - Biblioteca (consultas salvas + histórico)

private struct QueryLibraryPanel: View {
    @Environment(AppState.self) private var state
    let session: ConnectionSession
    let currentSQL: String
    /// (sql, título) — título presente quando veio de uma consulta salva.
    let onPick: (String, String?) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case saved = "Salvas"
        case history = "Histórico"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .saved
    @State private var search = ""
    @State private var showingSavePrompt = false
    @State private var saveTitle = ""
    /// SQL aguardando título no prompt (da consulta atual ou de um item do histórico).
    @State private var pendingSaveSQL = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Buscar", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)

            Divider()

            switch mode {
            case .saved: savedList
            case .history: historyList
            }

            Divider()

            Button {
                pendingSaveSQL = currentSQL
                saveTitle = ""
                showingSavePrompt = true
            } label: {
                Label("Salvar consulta atual", systemImage: "plus.circle")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
            .disabled(currentSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .background(.bar)
        .alert("Salvar consulta", isPresented: $showingSavePrompt) {
            TextField("Título", text: $saveTitle)
            Button("Salvar") {
                state.addSavedQuery(title: saveTitle, sql: pendingSaveSQL)
                mode = .saved
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Dê um título para encontrar depois.")
        }
    }

    // MARK: Salvas

    private var filteredSaved: [SavedQuery] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return state.savedQueries }
        return state.savedQueries.filter {
            $0.title.lowercased().contains(query) || $0.sql.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var savedList: some View {
        if filteredSaved.isEmpty {
            emptyState(
                search.isEmpty ? "Nenhuma consulta salva" : "Nada encontrado",
                icon: "bookmark",
                detail: search.isEmpty ? "Salve a consulta atual no botão abaixo." : nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredSaved) { query in
                        Button {
                            onPick(query.sql, query.title)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(query.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(flatten(query.sql))
                                    .font(Font(Theme.codeFont(size: 10)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Usar no editor") { onPick(query.sql, query.title) }
                            Divider()
                            Button("Excluir", role: .destructive) { state.removeSavedQuery(query.id) }
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    // MARK: Histórico

    private var filteredHistory: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return session.queryHistory }
        return session.queryHistory.filter { $0.lowercased().contains(query) }
    }

    @ViewBuilder
    private var historyList: some View {
        if filteredHistory.isEmpty {
            emptyState(
                search.isEmpty ? "Sem histórico nesta sessão" : "Nada encontrado",
                icon: "clock.arrow.circlepath",
                detail: search.isEmpty ? "As consultas executadas aparecem aqui." : nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredHistory.enumerated()), id: \.offset) { _, item in
                        Button {
                            onPick(item, nil)
                        } label: {
                            Text(flatten(item))
                                .font(Font(Theme.codeFont(size: 10.5)))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Usar no editor") { onPick(item, nil) }
                            Button("Salvar…") {
                                pendingSaveSQL = item
                                saveTitle = ""
                                showingSavePrompt = true
                            }
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func emptyState(_ title: String, icon: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func flatten(_ sql: String) -> String {
        sql.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }
}
