import SwiftUI
import DBDeckCore

/// Console SQL: editor em cima, resultado embaixo, divisor arrastável no meio.
///
/// As regras de execução são as do Mac (`SQLRunTarget`): com seleção roda a seleção,
/// sem seleção roda o script inteiro; "comando sob o cursor" roda só um. O resultado é
/// lido em streaming e pode ser cancelado no servidor.
struct ConsoleScreen: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    let connectionID: UUID
    let driver: any DatabaseDriver

    @State private var editor = SQLEditorController()
    @State private var result: QueryResult?
    @State private var resultVersion = 0
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var lastWasSelect = false
    @State private var cancelToken: CancelToken?
    @State private var queryTask: Task<QueryResult, any Error>?
    @State private var hasSelection = false
    @State private var showLibrary = false
    @State private var sharedFile: SharedFile?
    @State private var detailRow: Int?
    @State private var dragStart: Double?
    @State private var notice: String?

    private var session: ConnectionSession { state.session(for: connectionID) }

    /// O texto do console vive numa aba de consulta da sessão: sobrevive a navegar para
    /// uma tabela e voltar (e é a mesma aba que o menu "SELECT no console" preenche).
    /// Resolvida no `onAppear` — criar a aba durante o `body` seria mutar estado
    /// observado no meio da renderização.
    @State private var tabRef: EditorTab?
    private static let placeholderTab = EditorTab(kind: .query, title: "")
    private var tab: EditorTab { tabRef ?? Self.placeholderTab }

    private var sqlIsEmpty: Bool {
        tab.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if tabRef != nil {
                content
            } else {
                Color.clear
            }
        }
        .onAppear {
            if tabRef == nil {
                tabRef = session.tabs.first { $0.kind == .query } ?? session.newQuery()
            }
        }
    }

    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                editorPane
                    .frame(height: max(110, geo.size.height * tab.editorFraction))
                splitHandle(totalHeight: geo.size.height)
                resultsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Console SQL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                QueryLibrarySheet(session: session, currentSQL: tab.sqlText) { sql in
                    tab.sqlText = sql
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { detailRow.map { ResultRowTarget(row: $0) } },
            set: { detailRow = $0?.row }
        )) { target in
            NavigationStack {
                ResultRowView(result: result ?? QueryResult(columns: [], rows: []), row: target.row)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .shareSheet($sharedFile)
        .toast($notice)
        .onAppear {
            if tab.editorFraction == 0.5 { tab.editorFraction = 0.42 }
        }
    }

    // MARK: - Editor

    private var editorPane: some View {
        SQLEditor(
            text: Bindable(tab).sqlText,
            fontSize: settings.editorFontSize,
            indentUnit: settings.indentUnit,
            autoCompletion: settings.autoCompletion,
            controller: editor,
            completions: { text, cursor in
                SQLCompletion.suggestions(text: text, cursor: cursor, catalog: session.completionCatalog)
            },
            prepareCompletions: { text, cursor in
                let statement = SQLDump.statements(in: text).first { $0.contains(cursor) }?.sql ?? text
                session.prefetchColumns(
                    of: SQLCompletion.referencedTables(in: statement).map(\.table),
                    using: driver
                )
            },
            onRun: { Task { await run(.selectionOrAll) } },
            onSelectionChange: { hasSelection = $0 }
        )
        .overlay(alignment: .topLeading) {
            if sqlIsEmpty {
                Text("SELECT * FROM tabela LIMIT 100;")
                    .font(.system(size: settings.editorFontSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 15)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func splitHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
            statusLine
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { gesture in
                    let base = dragStart ?? tab.editorFraction
                    dragStart = base
                    guard totalHeight > 0 else { return }
                    tab.editorFraction = min(0.85, max(0.15, base + gesture.translation.height / totalHeight))
                }
                .onEnded { _ in
                    dragStart = nil
                    Haptics.selection()
                }
        )
        // Toque duplo alterna entre foco no editor e foco no resultado.
        .onTapGesture(count: 2) {
            withAnimation(.snappy) {
                tab.editorFraction = tab.editorFraction > 0.3 ? 0.18 : 0.5
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Divisor entre editor e resultado")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: tab.editorFraction = min(0.85, tab.editorFraction + 0.1)
            case .decrement: tab.editorFraction = max(0.15, tab.editorFraction - 0.1)
            @unknown default: break
            }
        }
    }

    private var statusLine: some View {
        HStack {
            if isRunning {
                ProgressView().controlSize(.mini)
                Text("Executando…")
            } else if let message {
                Text(message)
            }
            Spacer()
            if let result, !result.columns.isEmpty {
                Text("\(result.columns.count) col")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    // MARK: - Resultado

    @ViewBuilder
    private var resultsPane: some View {
        if let errorMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Erro", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else if let result {
            if result.columns.isEmpty {
                ContentUnavailableView(
                    lastWasSelect ? "Sem linhas" : "Comando executado",
                    systemImage: lastWasSelect ? "tray" : "checkmark.circle",
                    description: Text(message ?? "")
                )
            } else {
                DataGrid(
                    columns: result.columns.map { GridColumn(name: $0) },
                    rows: result.rows,
                    rowsVersion: resultVersion,
                    scrollResetToken: resultVersion,
                    rowHeight: settings.rowHeight,
                    zebra: settings.zebraStripes,
                    selectedRow: detailRow,
                    onTapCell: { row, _ in
                        Haptics.selection()
                        detailRow = row
                    },
                    cellMenu: { row, col in resultCellMenu(row: row, col: col) }
                )
            }
        } else if isRunning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Console SQL", systemImage: "terminal")
            } description: {
                Text("Escreva uma consulta e toque em ▶︎. Com texto selecionado, só a seleção roda.")
            } actions: {
                if !session.queryHistory.isEmpty || !state.savedQueries.isEmpty {
                    Button {
                        showLibrary = true
                    } label: { Label("Histórico e salvas", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func resultCellMenu(row: Int, col: Int) -> UIMenu? {
        guard let result, row < result.rows.count, col < result.rows[row].count else { return nil }
        let value = result.rows[row][col]
        return UIMenu(title: result.columns[col], children: [
            UIAction(title: "Copiar valor", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = value.copyText
                notice = "Valor copiado"
            },
            UIAction(title: "Copiar linha", image: UIImage(systemName: "doc.on.clipboard")) { _ in
                UIPasteboard.general.string = result.rows[row].map(\.copyText).joined(separator: "\t")
                notice = "Linha copiada"
            },
            UIAction(title: "Ver linha", image: UIImage(systemName: "list.bullet.rectangle")) { _ in
                detailRow = row
            },
        ])
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isRunning {
                Button(role: .destructive) {
                    cancelRunningQuery()
                } label: {
                    Label("Cancelar", systemImage: "stop.fill")
                }
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    Task { await run(.selectionOrAll) }
                } label: {
                    Label(hasSelection ? "Executar seleção" : "Executar", systemImage: "play.fill")
                }
                .disabled(sqlIsEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Menu {
                Button {
                    Task { await run(.statementAtCursor) }
                } label: {
                    Label("Executar comando sob o cursor", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(sqlIsEmpty || isRunning)
                Button {
                    editor.format(options: settings.formatterOptions)
                    Haptics.tap()
                } label: {
                    Label(hasSelection ? "Formatar seleção" : "Formatar SQL", systemImage: "wand.and.stars")
                }
                .disabled(sqlIsEmpty)
                Button {
                    showLibrary = true
                } label: {
                    Label("Histórico e salvas", systemImage: "books.vertical")
                }
                if let result, !result.columns.isEmpty {
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.label) { export(result, format: format) }
                        }
                    } label: {
                        Label("Exportar resultado", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    tab.sqlText = ""
                    result = nil
                    message = nil
                    errorMessage = nil
                } label: {
                    Label("Limpar", systemImage: "trash")
                }
                .disabled(sqlIsEmpty && result == nil)
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Execução

    private enum RunScope {
        case selectionOrAll
        case statementAtCursor
    }

    private func statementsToRun(_ scope: RunScope) -> [SQLStatement] {
        switch scope {
        case .selectionOrAll:
            return SQLRunTarget.statements(in: tab.sqlText, selection: editor.hasSelection ? editor.selectedRange : nil)
        case .statementAtCursor:
            return SQLRunTarget.statement(in: tab.sqlText, at: editor.selectedRange.location).map { [$0] } ?? []
        }
    }

    private func run(_ scope: RunScope) async {
        guard !isRunning else { return }
        let statements = statementsToRun(scope)
        guard !statements.isEmpty else { return }

        editor.dismissKeyboard()
        Haptics.tap()
        let token = CancelToken()
        cancelToken = token
        isRunning = true
        errorMessage = nil
        result = nil
        message = nil
        detailRow = nil
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
                    let sql = statement.sql
                    let driver = self.driver
                    let reading = Task { try await Self.collect(sql, driver: driver, cancel: token) }
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
                // Num script longo, o comando que falhou fica selecionado no editor.
                editor.select(NSRange(location: statement.location, length: statement.length))
                errorMessage = statements.count > 1
                    ? "Comando \(index + 1) de \(statements.count) — \(error.localizedDescription)"
                    : error.localizedDescription
                if executed > 0 {
                    message = "\(executed) de \(statements.count) executado\(executed == 1 ? "" : "s") antes do erro"
                }
                Haptics.error()
                return
            }
        }

        lastWasSelect = wasSelect
        result = lastResult ?? QueryResult(columns: [], rows: [])
        resultVersion += 1
        message = summary(
            statements: statements.count,
            executed: executed,
            cancelled: token.isCancelled,
            rows: lastResult?.rows.count,
            affected: lastAffected,
            start: start
        )
        Haptics.success()
    }

    private static func collect(_ statement: String, driver: any DatabaseDriver, cancel token: CancelToken) async throws -> QueryResult {
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
            if error is CancellationError || token.isCancelled {
                return QueryResult(columns: sink.columns, rows: sink.rows)
            }
            throw error
        }
        return QueryResult(columns: sink.columns, rows: sink.rows)
    }

    private func cancelRunningQuery() {
        cancelToken?.cancel()
        queryTask?.cancel()
        let driver = self.driver
        Task { await driver.cancelRunningQuery() }
        Haptics.tap()
    }

    private func summary(statements: Int, executed: Int, cancelled: Bool, rows: Int?, affected: Int?, start: Date) -> String {
        var parts: [String] = []
        if cancelled { parts.append("Cancelado") }
        if statements > 1 { parts.append("\(executed)/\(statements) comandos") }
        if let rows {
            parts.append("\(rows.formatted()) linha\(rows == 1 ? "" : "s")")
        } else if let affected {
            parts.append("\(affected.formatted()) afetada\(affected == 1 ? "" : "s")")
        } else if statements == 1 && !cancelled {
            parts.append("OK")
        }
        let ms = Date().timeIntervalSince(start) * 1000
        parts.append(ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000))
        return parts.joined(separator: " · ")
    }

    private func export(_ result: QueryResult, format: ExportFormat) {
        let text = ResultExporter.export(
            format: format, columns: result.columns, rows: result.rows, tableName: "consulta", engine: driver.engine
        )
        let url = ExportFiles.temporaryURL(named: "consulta", ext: format.fileExtension)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            sharedFile = SharedFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ResultRowTarget: Identifiable {
    var id: Int { row }
    var row: Int
}

/// Linha de um resultado do console (somente leitura), um campo por linha.
private struct ResultRowView: View {
    @Environment(\.dismiss) private var dismiss
    let result: QueryResult
    @State var row: Int
    @State private var viewing: ValueTarget?

    var body: some View {
        List {
            if row < result.rows.count {
                ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                    let value = index < result.rows[row].count ? result.rows[row][index] : .null
                    VStack(alignment: .leading, spacing: 4) {
                        Text(column).font(.subheadline.weight(.semibold))
                        if value == .null {
                            Text("NULL").font(.body.monospaced().italic()).foregroundStyle(.tertiary)
                        } else {
                            Text(value.display)
                                .font(.body.monospaced())
                                .lineLimit(8)
                                .textSelection(.enabled)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if value.display.count > 120 || value.display.contains("\n") {
                            viewing = ValueTarget(index: index, column: column, text: value.display, editable: false)
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = value.copyText
                            Haptics.success()
                        } label: { Label("Copiar valor", systemImage: "doc.on.doc") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Linha \(row + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $viewing) { target in
            ValueViewer(title: target.column, text: target.text, editable: false, onCommit: { _ in })
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fechar") { dismiss() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { row -= 1; Haptics.selection() } label: { Image(systemName: "chevron.up") }
                    .disabled(row == 0)
                Button { row += 1; Haptics.selection() } label: { Image(systemName: "chevron.down") }
                    .disabled(row >= result.rows.count - 1)
                Spacer()
                Text("\(row + 1) de \(result.rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard row < result.rows.count else { return }
                    UIPasteboard.general.string = result.rows[row].map(\.copyText).joined(separator: "\t")
                    Haptics.success()
                } label: { Image(systemName: "doc.on.clipboard") }
            }
        }
    }
}
