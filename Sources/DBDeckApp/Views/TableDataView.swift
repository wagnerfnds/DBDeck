import SwiftUI
import DBDeckCore

/// Coordenada de célula (linha × coluna) para seleção/edição no grid.
struct EditCoord: Hashable {
    let row: Int
    let col: Int
}

/// Operadores do filtro de conteúdo (estilo Sequel Ace).
enum RowFilterOperator: String, CaseIterable, Identifiable {
    case equals = "="
    case notEquals = "≠"
    case greater = ">"
    case greaterOrEqual = "≥"
    case less = "<"
    case lessOrEqual = "≤"
    case contains = "contém"
    case beginsWith = "começa com"
    case endsWith = "termina com"
    case isNull = "é NULL"
    case isNotNull = "não é NULL"

    var id: String { rawValue }
    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

/// Uma linha de filtro: coluna + operador + valor, com liga/desliga individual.
struct RowFilter: Identifiable, Equatable {
    let id = UUID()
    var column: String = ""
    var op: RowFilterOperator = .equals
    var value: String = ""
    var enabled = true
}

struct TableDataView: View {
    @Environment(AppSettings.self) private var settings
    let driver: any DatabaseDriver
    let table: String
    /// Aba dona desta view — observada para reagir ao ⌘R global (reloadRequest).
    var tab: EditorTab? = nil
    /// Só a aba visível registra o ⌘S — oculta (ZStack opacity 0) ela roubaria o
    /// atalho da aba visível e salvaria as alterações pendentes da aba errada.
    var isActive: Bool = true

    @State private var columns: [DatabaseColumn] = []
    @State private var primaryKeys: [String] = []
    @State private var rows: [[SQLValue]] = []
    @State private var original: [[SQLValue]] = []
    @State private var offset = 0
    @State private var totalCount: Int?
    /// Total vindo das estatísticas do engine (mostrado com "~"): abrir uma tabela de
    /// milhões de linhas não pode esperar um COUNT(*), que é varredura completa.
    @State private var totalIsEstimate = false
    /// Colunas BLOB/TEXT não pedidas no SELECT (índices em `columns`).
    @State private var deferredColumns: Set<Int> = []
    @State private var deferBlobs = false
    /// Página ainda chegando do servidor — o grid já mostra o que baixou.
    @State private var isStreaming = false
    /// Identifica o carregamento em curso. Com publicação progressiva, dois `loadPage`
    /// sobrepostos (cliques rápidos em avançar/voltar) intercalariam linhas de páginas
    /// diferentes; só o carregamento mais recente pode escrever em `rows`.
    @State private var loadGeneration = 0
    @State private var isNewRow = false
    @State private var selectedRow: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var notice: String?

    @State private var sortColumn: String?
    @State private var sortAscending = true
    @State private var selectedCell: EditCoord?
    @State private var showInspector = false

    // Guard de alterações não salvas: a ação (paginação/sort/filtro/reload) fica
    // adiada enquanto o diálogo decide entre salvar, descartar ou cancelar.
    @State private var pendingAction: (() -> Void)?
    @State private var showDiscardDialog = false

    // Filtro de conteúdo (linhas de coluna + operador + valor → WHERE com AND).
    // Visível por padrão: ao abrir a tabela já aparece uma linha com a PK selecionada.
    @State private var showFilter = true
    @State private var filters: [RowFilter] = []
    @FocusState private var focusedFilterField: UUID?
    /// WHERE aplicado no momento (congelado no Filtrar/toggle).
    @State private var appliedFilter: String?

    /// 1000 linhas por página (o mesmo default do Sequel Ace): com o corte de valores na
    /// origem e o desenho por célula visível, a página maior custa quase o mesmo e reduz
    /// pela metade os cliques de paginação — que é onde mora o OFFSET caro.
    private var pageSize: Int { settings.pageSize }

    /// Caracteres/bytes trazidos por célula no grid. Uma célula tem ~160 px: acima disto
    /// nada é visível, e materializar o valor inteiro era o que fazia uma página com uma
    /// coluna TEXT custar centenas de MB. Ver `SQLValue.truncated`.
    private var previewLimit: Int { settings.previewLimit }

    /// Lote de linhas por publicação durante o streaming da página.
    private let streamBatchSize = 100

    private var hasPendingChanges: Bool { rows != original }

    private var selectedRowBinding: Binding<[SQLValue]>? {
        guard let selectedRow, selectedRow < rows.count else { return nil }
        return Binding(
            get: { rows[selectedRow] },
            set: { rows[selectedRow] = $0 }
        )
    }

    private var inspectorTitle: String {
        guard let selectedRow, selectedRow < rows.count else { return "Nenhuma linha" }
        if isNewRow && selectedRow == rows.count - 1 { return "Nova linha" }
        return "Linha \(offset + selectedRow + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if primaryKeys.isEmpty && !isLoading && !columns.isEmpty {
                banner
            }

            if showFilter {
                filterBar
                Divider()
            }

            HStack(spacing: 0) {
                if rows.isEmpty && !isLoading {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            "Nenhum registro",
                            systemImage: "tray",
                            description: Text("Esta página está vazia ou a tabela não tem linhas.")
                        )
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    grid
                }

                if showInspector {
                    Divider()
                    RowInspector(
                        columns: columns,
                        title: inspectorTitle,
                        values: selectedRowBinding,
                        editable: !primaryKeys.isEmpty
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .task { await load() }
        .onChange(of: tab?.reloadRequest) { _, _ in
            runGuarded { reloadCurrentPage() }
        }
        // Linhas por página / prévia por célula mudaram nas preferências: a página
        // atual é recarregada com os valores novos (o offset fica).
        .onChange(of: settings.pageSize) { _, _ in
            runGuarded { reloadCurrentPage(recount: false) }
        }
        .onChange(of: settings.previewLimit) { _, _ in
            runGuarded { reloadCurrentPage(recount: false) }
        }
        .confirmationDialog(
            "Há alterações não salvas",
            isPresented: $showDiscardDialog,
            titleVisibility: .visible
        ) {
            Button("Salvar e continuar") {
                let action = pendingAction
                pendingAction = nil
                Task {
                    // Só executa a ação pendente se o save realmente funcionou;
                    // caso contrário o loadPage da ação sobrescreveria as edições.
                    if await saveChanges() {
                        action?()
                    }
                }
            }
            Button("Descartar", role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                action?()
            }
            Button("Cancelar", role: .cancel) { pendingAction = nil }
        }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottomTrailing) { noticeToast }
    }

    private var filterBar: some View {
        VStack(spacing: 4) {
            ForEach($filters) { $filter in
                filterRow($filter)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func filterRow(_ filter: Binding<RowFilter>) -> some View {
        let isFirst = filters.first?.id == filter.wrappedValue.id
        HStack(spacing: 6) {
            // Funil clicável: liga/desliga só esta linha sem removê-la.
            Button {
                filter.wrappedValue.enabled.toggle()
                applyFilter()
            } label: {
                Image(systemName: filter.wrappedValue.enabled
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(filter.wrappedValue.enabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(filter.wrappedValue.enabled ? "Desativar este filtro" : "Ativar este filtro")

            Group {
                Picker("", selection: filter.column) {
                    ForEach(columns) { column in
                        Text(column.name).tag(column.name)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 190)
                Picker("", selection: filter.op) {
                    ForEach(RowFilterOperator.allCases) { op in
                        Text(op.rawValue).tag(op)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TextField("valor", text: filter.value)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!filter.wrappedValue.op.needsValue)
                    .focused($focusedFilterField, equals: filter.wrappedValue.id)
                    .onExitCommand { focusedFilterField = nil }
                    .onSubmit { applyFilter() }
                    .frame(maxWidth: 260)
            }
            .opacity(filter.wrappedValue.enabled ? 1 : 0.45)

            Button {
                addFilterRow(after: filter.wrappedValue.id)
            } label: {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Adicionar filtro")

            if filters.count > 1 {
                Button {
                    removeFilterRow(filter.wrappedValue.id)
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remover este filtro")
            }

            Spacer()

            if isFirst {
                Button("Filtrar") { applyFilter() }
                    .controlSize(.small)
                if appliedFilter != nil {
                    Button {
                        clearFilter()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Limpar filtros")
                }
                Button {
                    closeFilterBar()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Fechar barra de filtro")
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text("Tabela sem chave primária — edição desabilitada (consulta e export continuam).")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Grid

    private var grid: some View {
        // Grid nativo (NSTableView): só as ~40 linhas visíveis existem por vez;
        // header pinado, sort, resize, zebra e edição via field editor são nativos.
        // A edição vive no Coordinator do DataGridView e escreve em `rows` só no
        // fim (commit-on-end) — a normalização de tipos continua no saveChanges.
        DataGridView(
            columns: columns.map { GridColumnSpec(column: $0) },
            rows: rows,
            rowNumberStart: offset + 1,
            editable: !primaryKeys.isEmpty,
            newRowIndex: isNewRow ? rows.count - 1 : nil,
            deferredColumns: deferredColumns,
            isStreaming: isStreaming,
            selectedCell: $selectedCell,
            selectedRow: $selectedRow,
            sortColumn: sortColumn,
            sortAscending: sortAscending,
            onSort: { toggleSort($0) },
            onSetValue: { row, col, value in
                guard row < rows.count, col < rows[row].count else { return }
                rows[row][col] = value
            },
            onCopyRowAsInsert: { row in Task { await copyRowAsInsert(row) } },
            // O grid só edita valores íntegros: ao abrir a edição de uma célula cortada
            // (ou de coluna adiada) ele pede o valor real e reabre a edição quando chega.
            needsFullValue: { row, col in needsFullValue(row: row, col: col) },
            onRequestFullValue: { row, col in
                Task {
                    if await loadFullValue(row: row, col: col) == false {
                        withAnimation { notice = "Não foi possível carregar o valor completo" }
                    }
                }
            },
            onCopyValue: { row, col in
                Task {
                    if needsFullValue(row: row, col: col) {
                        await loadFullValue(row: row, col: col)
                    }
                    guard row < rows.count, col < rows[row].count else { return }
                    copyToPasteboard(displayForCopy(rows[row][col]))
                }
            },
            onCopyRow: { row in
                Task {
                    await materializeRow(row)
                    guard row < rows.count else { return }
                    copyToPasteboard(
                        rows[row].map(displayForCopy).joined(separator: "\t")
                    )
                }
            }
        )
        .gridStyle(rowHeight: settings.rowHeight, zebra: settings.zebraStripes)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func displayForCopy(_ value: SQLValue) -> String {
        value == .null ? "NULL" : value.display
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Encerra de forma síncrona qualquer edição de célula em curso no grid nativo —
    /// o field editor commita via controlTextDidEndEditing antes de a ação continuar.
    private func commitActiveCellEdit() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Ações que recarregam a página (sort, paginação, filtro, reload) descartariam
    /// edições pendentes em silêncio: commita a edição de célula em curso e, se há
    /// alterações não salvas, pergunta antes de continuar (salvar/descartar/cancelar).
    private func runGuarded(_ action: @escaping () -> Void) {
        commitActiveCellEdit()
        if hasPendingChanges || isNewRow {
            pendingAction = action
            showDiscardDialog = true
        } else {
            action()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            iconButton("arrow.clockwise", help: "Recarregar (⌘R)") {
                runGuarded { reloadCurrentPage() }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showFilter.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(appliedFilter != nil ? Color.accentColor : (showFilter ? Color.primary : .secondary))
            .help("Filtrar conteúdo")

            if !primaryKeys.isEmpty {
                iconButton("plus", help: "Nova linha") { startNewRow() }
                iconButton("trash", help: "Excluir linha selecionada") {
                    commitActiveCellEdit()
                    Task { await deleteSelected() }
                }
                    .disabled(selectedRow == nil)

                Button {
                    commitActiveCellEdit()
                    Task { await saveChanges() }
                } label: {
                    Label("Salvar", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasPendingChanges && !isNewRow)
                // nil desregistra o atalho quando a aba está oculta/no split.
                .keyboardShortcut(isActive ? KeyboardShortcut("s", modifiers: .command) : nil)

                if hasPendingChanges || isNewRow {
                    Text("alterações não salvas")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showInspector ? Color.accentColor : .secondary)
            .help("Inspetor de linha")

            Menu {
                Section("Página atual (\(dataRowCount) linhas)") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) {
                            commitActiveCellEdit()
                            Task { await exportPage(format: format) }
                        }
                    }
                }
                Section("Tabela inteira") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) {
                            commitActiveCellEdit()
                            Task { await exportWholeTable(format: format) }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Exportar (CSV, JSON ou SQL)")

            // Só aparece quando há o que adiar — em tabela sem TEXT/BLOB seria ruído.
            if columns.contains(where: \.isBlobOrText) {
                Button {
                    // A mutação vai DENTRO da closure guardada: cancelar o diálogo de
                    // alterações pendentes não pode deixar o botão aceso sem recarga.
                    runGuarded {
                        deferBlobs.toggle()
                        reloadCurrentPage(recount: false)
                    }
                } label: {
                    Image(systemName: "doc.richtext")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(deferBlobs ? Color.accentColor : .secondary)
                .help(deferBlobs
                    ? "Colunas TEXT/BLOB adiadas — carregadas sob demanda ao abrir a célula"
                    : "Não carregar colunas TEXT/BLOB na listagem (mais rápido em tabelas pesadas)")
            }

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                iconButton("chevron.left", help: "Página anterior") {
                    runGuarded {
                        let cursor = previousPageCursor()
                        Task { await loadPage(cursor: cursor) }
                    }
                }
                .disabled(offset == 0)

                // Total estimado (ou desconhecido) vira botão: a contagem exata é a
                // varredura completa que a abertura evita, e só roda a pedido.
                if totalIsEstimate || totalCount == nil {
                    Button(pageLabel) { Task { await countExactly() } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Contagem estimada pelo banco — clique para contar exatamente")
                } else {
                    Text(pageLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                iconButton("chevron.right", help: "Próxima página") {
                    runGuarded {
                        let cursor = nextPageCursor()
                        Task { await loadPage(cursor: cursor) }
                    }
                }
                .disabled(rows.count < pageSize)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var pageLabel: String {
        let dataCount = isNewRow ? rows.count - 1 : rows.count
        guard dataCount > 0 else { return isLoading ? "carregando…" : "0 linhas" }
        let end = offset + dataCount
        guard let total = totalCount else { return "\(offset + 1)–\(end) de ?" }
        // "~" marca o total vindo das estatísticas do engine, como no Sequel Ace.
        return "\(offset + 1)–\(end) de \(totalIsEstimate ? "~" : "")\(total)"
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var noticeToast: some View {
        Group {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .padding(12)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.notice = nil }
                    }
            }
        }
    }

    // MARK: - Sort

    private func toggleSort(_ column: String) {
        // O estado do sort só muda DENTRO da ação guardada — cancelar o diálogo não
        // pode deixar o indicador do header apontando um sort que não aconteceu.
        runGuarded {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
            Task { await loadPage(cursor: .absolute(0)) }
        }
    }

    // MARK: - Ações

    private func load() async {
        do {
            // UMA consulta de metadados. `columns()` já marca a PK em todos os engines
            // (SHOW FULL COLUMNS no MySQL, pg_index no Postgres, table_info no SQLite):
            // o `primaryKeys()` que vinha logo depois era uma ida ao servidor a mais em
            // toda abertura de tabela, repetindo a consulta que o `columns()` já fizera.
            columns = try await driver.columns(table: table)
            primaryKeys = columns.filter(\.isPrimaryKey).map(\.name)
            if filters.isEmpty {
                var first = RowFilter()
                first.column = primaryKeys.first ?? columns.first?.name ?? ""
                filters = [first]
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadPage(cursor: .absolute(0), recount: true)
    }

    // MARK: - Paginação

    /// Construtor do SELECT da página (cursor, keyset, ordenação, colunas adiadas).
    /// Vive no core para ser testável: a correção da paginação por âncora é o ponto mais
    /// delicado desta tela e não dá para exercitá-la de dentro de uma View.
    private var queryBuilder: PageQueryBuilder {
        PageQueryBuilder(
            engine: driver.engine,
            table: table,
            columns: columns,
            primaryKeys: primaryKeys,
            sortColumn: sortColumn,
            sortAscending: sortAscending,
            filter: appliedFilter,
            pageSize: pageSize,
            deferBlobs: deferBlobs
        )
    }

    private var keysetColumn: String? { queryBuilder.keysetColumn }

    /// Valor da PK numa linha da página atual, para servir de âncora. Prefixo truncado ou
    /// NULL não servem — a comparação sairia errada.
    private func keysetValue(at rowIndex: Int) -> SQLValue? {
        guard let key = keysetColumn,
              let column = columns.firstIndex(where: { $0.name == key }),
              rowIndex >= 0, rowIndex < rows.count, column < rows[rowIndex].count
        else { return nil }
        let value = rows[rowIndex][column]
        guard !value.isTruncated, value != .null else { return nil }
        return value
    }

    private var dataRowCount: Int { isNewRow ? max(0, rows.count - 1) : rows.count }

    private func nextPageCursor() -> PageCursor {
        let target = offset + pageSize
        guard let anchor = keysetValue(at: dataRowCount - 1) else { return .absolute(target) }
        return .after(anchor, offset: target)
    }

    private func previousPageCursor() -> PageCursor {
        let target = max(0, offset - pageSize)
        // Só ancora quando a página anterior é cheia: com `target` no começo da tabela o
        // OFFSET 0 é barato e evita o caso de borda da última página curta.
        guard target > 0, let anchor = keysetValue(at: 0) else { return .absolute(target) }
        return .before(anchor, offset: target)
    }

    /// Recarrega a página atual sem pagar o OFFSET de novo (⌘R, pós-salvar, pós-excluir).
    private func reloadCurrentPage(recount: Bool = true) {
        Task { await reloadCurrentPageAwaiting(recount: recount) }
    }

    private func reloadCurrentPageAwaiting(recount: Bool = true) async {
        guard let anchor = keysetValue(at: 0) else {
            await loadPage(cursor: .absolute(offset), recount: recount)
            return
        }
        await loadPage(cursor: .atOrAfter(anchor, offset: offset), recount: recount)
    }

    // MARK: - Consulta da página


    /// Ponte do `streamQuery` (callback `@Sendable`, roda na thread de I/O do driver) para
    /// consumo aqui no main actor. É o que permite desenhar as primeiras linhas antes de a
    /// página inteira ter chegado.
    private func rowBatches(sql: String) -> AsyncThrowingStream<RowBatch, any Error> {
        let driver = self.driver
        let batchSize = streamBatchSize
        let limit = previewLimit
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await driver.streamQuery(sql, batchSize: batchSize, previewLimit: limit) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `recount: false` pula a contagem — ordenar e paginar não mudam o total.
    private func loadPage(cursor requested: PageCursor, recount: Bool = false) async {
        // Cursor de keyset sem coluna âncora (o sort mudou, a PK sumiu num ALTER): cai
        // para OFFSET. Sem isso a condição seria descartada e a página voltaria em
        // silêncio para o começo da tabela.
        let cursor = queryBuilder.normalize(requested)

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        isStreaming = true
        selectedCell = nil
        selectedRow = nil
        isNewRow = false
        defer {
            // Um carregamento antigo terminando não pode apagar o "carregando" do novo.
            if loadGeneration == generation {
                isLoading = false
                isStreaming = false
            }
        }

        let page = queryBuilder.make(cursor: cursor)
        let deferred = queryBuilder.deferredColumnIndexes

        do {
            var accumulated: [[SQLValue]] = []
            var resultColumns: [String] = []
            // Publicação progressiva: o primeiro lote aparece na hora (enche a viewport)
            // e os seguintes vão espaçando — a curva do `tableLoadUpdate` do Sequel Ace.
            // Em tabela LARGA cada publicação custa um pass de layout sobre milhares de
            // células (o NSTableView view-based materializa TODAS as colunas da linha
            // visível), então o teto de publicações intermediárias cai com a largura.
            var nextPublish = ContinuousClock.now
            var interval = Duration.milliseconds(20)
            var intermediatePublishes = 0
            let publishBudget = columns.count >= 50 ? 1 : 3

            for try await batch in rowBatches(sql: page.sql) {
                if resultColumns.isEmpty { resultColumns = batch.columns }
                accumulated.append(contentsOf: batch.rows)
                // Cursor `.before` lê ao contrário: publicar parcial mostraria as linhas
                // na ordem errada, então só o resultado final vai para a tela.
                guard loadGeneration == generation else { return }
                guard !page.reversed,
                      intermediatePublishes < publishBudget,
                      ContinuousClock.now >= nextPublish else { continue }
                rows = accumulated
                original = accumulated
                self.offset = cursor.offset
                deferredColumns = deferred
                intermediatePublishes += 1
                interval = interval == .milliseconds(20) ? .milliseconds(200) : .milliseconds(500)
                nextPublish = ContinuousClock.now + interval
            }

            guard loadGeneration == generation else { return }
            if page.reversed { accumulated.reverse() }

            // A aba Estrutura pode ter alterado a tabela (ALTER TABLE executa na hora)
            // com esta view ainda viva: se as colunas do resultado não batem com as
            // conhecidas, ressincroniza ANTES de publicar as linhas — senão inspetor e
            // saveChanges indexariam colunas obsoletas (index out of range = crash).
            if !resultColumns.isEmpty, resultColumns != columns.map(\.name) {
                if let fresh = try? await driver.columns(table: table), !fresh.isEmpty {
                    columns = fresh
                    primaryKeys = fresh.filter(\.isPrimaryKey).map(\.name)
                }
            }
            guard loadGeneration == generation else { return }
            rows = accumulated
            original = accumulated
            self.offset = cursor.offset
            deferredColumns = deferred
            if recount { await refreshCount(loadedRows: accumulated.count) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Total de linhas SEM travar a abertura. Sem filtro, o driver decide entre a
    /// estimativa do engine e o COUNT(*) exato pelo tamanho da tabela. Com filtro não há
    /// estatística possível: se a página voltou curta o total é exato de graça
    /// (`offset + linhas`); senão fica desconhecido até o usuário pedir a contagem.
    private func refreshCount(loadedRows: Int) async {
        if loadedRows < pageSize {
            totalCount = offset + loadedRows
            totalIsEstimate = false
            return
        }
        guard appliedFilter == nil else {
            totalCount = nil
            totalIsEstimate = false
            return
        }
        guard let estimate = try? await driver.rowCount(table: table, allowExactScan: false) else {
            totalCount = nil
            return
        }
        totalCount = estimate.isKnown ? estimate.value : nil
        totalIsEstimate = estimate.isEstimate
    }

    // MARK: - Valores cortados / não carregados

    /// `true` quando a célula não tem o valor íntegro em memória: ou veio cortada pelo
    /// `previewLimit`, ou a coluna nem foi pedida no SELECT (`deferBlobs`).
    private func needsFullValue(row: Int, col: Int) -> Bool {
        if deferredColumns.contains(col) { return true }
        guard row < rows.count, col < rows[row].count else { return false }
        return rows[row][col].isTruncated
    }

    /// Recarrega uma célula inteira do servidor. O grid trabalha com prefixos; editar,
    /// copiar ou exportar precisa do valor real. É o `asPreview:NO` do Sequel Ace — lá o
    /// valor completo já está no buffer local, aqui custa uma consulta de uma célula só.
    @discardableResult
    private func loadFullValue(row: Int, col: Int) async -> Bool {
        guard row < rows.count, col < columns.count, col < rows[row].count,
              let sql = singleCellQuery(row: row, column: columns[col]),
              let value = try? await driver.query(sql, previewLimit: nil).rows.first?.first
        else { return false }
        guard row < rows.count, col < rows[row].count else { return false }
        // A célula recarregada entra também em `original`: ela não é uma edição do
        // usuário, e sem isso a linha ficaria marcada como "não salva" para sempre.
        rows[row][col] = value
        if row < original.count, col < original[row].count { original[row][col] = value }
        return true
    }

    private func singleCellQuery(row: Int, column: DatabaseColumn) -> String? {
        var keyValues: [(column: String, value: SQLValue)] = []
        if row < original.count {
            for key in primaryKeys {
                guard let index = columns.firstIndex(where: { $0.name == key }),
                      index < original[row].count else { return nil }
                keyValues.append((key, original[row][index]))
            }
        }
        return queryBuilder.singleCellQuery(
            column: column,
            primaryKeyValues: keyValues,
            absoluteRowIndex: offset + row
        )
    }

    /// Materializa todos os valores cortados/não carregados de uma linha.
    private func materializeRow(_ row: Int) async {
        for col in columns.indices where needsFullValue(row: row, col: col) {
            await loadFullValue(row: row, col: col)
        }
    }

    /// Relê a página inteira sem corte e sem adiar colunas. Usado pela exportação —
    /// um CSV com "…" no fim de cada célula grande seria dado corrompido.
    private func fullPageRows() async -> [[SQLValue]]? {
        let hasPartialValues = deferBlobs || rows.contains { row in row.contains(where: \.isTruncated) }
        guard hasPartialValues else { return nil }
        let anchor = keysetValue(at: 0)
        let cursor: PageCursor = anchor.map { .atOrAfter($0, offset: offset) } ?? .absolute(offset)
        let page = queryBuilder.make(cursor: cursor, deferring: false)
        guard let result = try? await driver.query(page.sql, previewLimit: nil) else { return nil }
        return page.reversed ? result.rows.reversed() : result.rows
    }

    /// Contagem exata sob demanda (clique no rodapé). É a varredura completa que a
    /// abertura evita — só roda quando o usuário pede explicitamente.
    private func countExactly() async {
        isLoading = true
        defer { isLoading = false }
        if let appliedFilter {
            let sql = "SELECT COUNT(*) FROM \(driver.quoteIdentifier(table)) WHERE \(appliedFilter)"
            guard let first = try? await driver.query(sql).rows.first?.first else { return }
            switch first {
            case .int(let value): totalCount = Int(value)
            case .text(let value): totalCount = Int(value)
            default: return
            }
            totalIsEstimate = false
            return
        }
        guard let exact = try? await driver.rowCount(table: table, allowExactScan: true) else { return }
        totalCount = exact.isKnown ? exact.value : nil
        totalIsEstimate = exact.isEstimate
    }

    // MARK: - Filtro de conteúdo

    private func applyFilter() {
        let clauses = filters.filter(\.enabled).compactMap { whereClause(for: $0) }
        let newFilter = clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
        // Toggle/Filtrar sem mudança efetiva não deve custar um round-trip ao banco.
        guard newFilter != appliedFilter else { return }
        runGuarded {
            appliedFilter = newFilter
            Task { await loadPage(cursor: .absolute(0), recount: true) }
        }
    }

    private func clearFilter() {
        // Sem filtro aplicado só há campos locais para limpar — nada a guardar.
        guard appliedFilter != nil else {
            for index in filters.indices { filters[index].value = "" }
            return
        }
        // Mutações de UI DENTRO da closure guardada: se o usuário cancelar o diálogo
        // de alterações pendentes, os campos continuam refletindo o WHERE em vigor.
        runGuarded {
            for index in filters.indices { filters[index].value = "" }
            appliedFilter = nil
            Task { await loadPage(cursor: .absolute(0), recount: true) }
        }
    }

    private func addFilterRow(after id: UUID) {
        var newFilter = RowFilter()
        newFilter.column = primaryKeys.first ?? columns.first?.name ?? ""
        if let index = filters.firstIndex(where: { $0.id == id }) {
            filters.insert(newFilter, at: index + 1)
        } else {
            filters.append(newFilter)
        }
    }

    private func removeFilterRow(_ id: UUID) {
        filters.removeAll { $0.id == id }
        applyFilter()
    }

    private func closeFilterBar() {
        // Sem filtro aplicado, fechar a barra não recarrega nada — pode ser imediato.
        guard appliedFilter != nil else {
            withAnimation(.easeInOut(duration: 0.15)) { showFilter = false }
            return
        }
        // Esconder a barra DENTRO da closure guardada: cancelar o diálogo mantém a
        // barra visível (e o funil em accent), refletindo o filtro ainda ativo.
        runGuarded {
            withAnimation(.easeInOut(duration: 0.15)) { showFilter = false }
            appliedFilter = nil
            Task { await loadPage(cursor: .absolute(0), recount: true) }
        }
    }

    private func whereClause(for filter: RowFilter) -> String? {
        guard !filter.column.isEmpty else { return nil }
        if filter.op.needsValue && filter.value.isEmpty { return nil }
        let column = driver.quoteIdentifier(filter.column)
        let escaped = literalEscaped(filter.value)
        // Curingas do LIKE escapados com '|' (ESCAPE explícito vale nos três engines),
        // para "contém 100%" achar literalmente "100%" e não qualquer "100…".
        let pattern = literalEscaped(
            filter.value
                .replacingOccurrences(of: "|", with: "||")
                .replacingOccurrences(of: "%", with: "|%")
                .replacingOccurrences(of: "_", with: "|_")
        )
        // Postgres não faz coerção implícita no LIKE: em coluna integer/uuid ele
        // falha com "operator does not exist" — o CAST dá paridade com MySQL/SQLite.
        let textColumn = driver.engine == .postgres ? "CAST(\(column) AS TEXT)" : column
        switch filter.op {
        case .equals: return "\(column) = '\(escaped)'"
        case .notEquals: return "\(column) <> '\(escaped)'"
        case .greater: return "\(column) > '\(escaped)'"
        case .greaterOrEqual: return "\(column) >= '\(escaped)'"
        case .less: return "\(column) < '\(escaped)'"
        case .lessOrEqual: return "\(column) <= '\(escaped)'"
        case .contains: return "\(textColumn) LIKE '%\(pattern)%' ESCAPE '|'"
        case .beginsWith: return "\(textColumn) LIKE '\(pattern)%' ESCAPE '|'"
        case .endsWith: return "\(textColumn) LIKE '%\(pattern)' ESCAPE '|'"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        }
    }

    /// Escapa o valor para literal de string: aspas simples sempre; no MySQL a barra
    /// invertida também (no sql_mode padrão `\` escapa dentro do literal — "C:\temp\"
    /// sem isso engoliria a aspa de fechamento e quebraria o statement).
    private func literalEscaped(_ value: String) -> String {
        var escaped = value
        if driver.engine == .mysql {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        return escaped.replacingOccurrences(of: "'", with: "''")
    }

    private func startNewRow() {
        if isNewRow { return }
        commitActiveCellEdit()
        rows.append(Array(repeating: .null, count: columns.count))
        isNewRow = true
        selectedRow = rows.count - 1
    }

    /// Copia a linha como statement INSERT pronto para colar (menu de contexto do grid).
    /// Materializa antes as células cortadas/não carregadas — colar um INSERT com
    /// prefixos gravaria dado truncado no destino.
    private func copyRowAsInsert(_ row: Int) async {
        guard row < rows.count else { return }
        await materializeRow(row)
        guard row < rows.count else { return }
        let names = columns.map { driver.quoteIdentifier($0.name) }.joined(separator: ", ")
        let values = columns.indices.map { index -> String in
            guard index < rows[row].count else { return "NULL" }
            switch rows[row][index] {
            case .null: return "NULL"
            case .int(let value): return String(value)
            case .double(let value): return String(value)
            case .bool(let value): return value ? "TRUE" : "FALSE"
            case .text(let value): return "'\(literalEscaped(value))'"
            case .blob: return rows[row][index].sqlLiteral(engine: driver.engine)
            // Só chega aqui se a recarga acima falhou (linha sem PK localizável).
            case .truncated: return "DEFAULT"
            }
        }.joined(separator: ", ")
        let sql = "INSERT INTO \(driver.quoteIdentifier(table)) (\(names)) VALUES (\(values));"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
        withAnimation { notice = "INSERT copiado" }
    }

    /// Retorna `true` quando todas as alterações pendentes foram persistidas.
    /// `false` indica falha (erro de SQL/conexão ou linha sem PK) — nesse caso
    /// as edições continuam em `rows` e o chamador NÃO deve recarregar a página.
    @discardableResult
    private func saveChanges() async -> Bool {
        do {
            var updated = 0
            var inserted = 0
            var problems: [String] = []

            let dataRowsCount = isNewRow ? rows.count - 1 : rows.count
            for i in 0..<dataRowsCount where i < original.count {
                var changes: [(column: String, value: SQLValue)] = []
                for (j, column) in columns.enumerated() {
                    // Guarda de j: linhas carregadas antes de um ALTER TABLE podem ter
                    // menos valores que `columns` — indexar direto seria crash.
                    let newValue = (i < rows.count && j < rows[i].count) ? rows[i][j] : .null
                    let oldValue = (i < original.count && j < original[i].count) ? original[i][j] : .null
                    // Prefixo nunca é gravado: seria sobrescrever o valor do servidor por
                    // uma versão cortada. Por construção não dá para editar uma célula
                    // truncada sem antes carregar o valor íntegro — isto é a rede de
                    // segurança para qualquer caminho que escape dessa regra.
                    if newValue != oldValue, !newValue.isTruncated {
                        changes.append((column.name, normalize(newValue, column: column)))
                    }
                }
                if !changes.isEmpty {
                    let pkValues: [SQLValue] = primaryKeys.map { key in
                        let index = columns.firstIndex { $0.name == key } ?? 0
                        return (i < original.count && index < original[i].count) ? original[i][index] : .null
                    }
                    if pkValues.contains(.null) {
                        problems.append("Linha \(i + 1): chave primária nula — não foi possível atualizar.")
                    } else {
                        updated += try await driver.updateRow(
                            table: table,
                            primaryKey: primaryKeys,
                            pkValues: pkValues,
                            changes: changes
                        )
                    }
                }
            }

            if isNewRow, let newIndex = rows.indices.last {
                var values: [(column: String, value: SQLValue)] = []
                for (j, column) in columns.enumerated() {
                    guard j < rows[newIndex].count else { continue }
                    let value = rows[newIndex][j]
                    if case .null = value { continue }
                    values.append((column.name, normalize(value, column: column)))
                }
                if !values.isEmpty {
                    inserted += try await driver.insertRow(table: table, values: values)
                }
            }

            if !problems.isEmpty {
                // Não recarrega: loadPage sobrescreveria `rows`/`original` e as
                // edições das linhas sem PK seriam perdidas em silêncio.
                errorMessage = problems.joined(separator: "\n")
                return false
            }
            await reloadCurrentPageAwaiting()
            withAnimation { notice = "Salvo · \(updated) atualizadas, \(inserted) inseridas" }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deleteSelected() async {
        guard let selectedRow else { return }
        if isNewRow, selectedRow == rows.count - 1 {
            rows.removeLast()
            isNewRow = false
            self.selectedRow = nil
            return
        }
        guard selectedRow < original.count else { return }
        let pkValues: [SQLValue] = primaryKeys.map { key in
            let index = columns.firstIndex { $0.name == key } ?? 0
            return index < original[selectedRow].count ? original[selectedRow][index] : .null
        }
        guard !pkValues.contains(.null) else {
            errorMessage = "Não é possível excluir: chave primária nula."
            return
        }
        do {
            _ = try await driver.deleteRow(table: table, primaryKey: primaryKeys, pkValues: pkValues)
            await reloadCurrentPageAwaiting()
            withAnimation { notice = "Linha excluída" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalize(_ value: SQLValue, column: DatabaseColumn) -> SQLValue {
        guard case .text(let text) = value else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return column.isNullable ? .null : .text("")
        }
        let type = column.type.lowercased()
        if type.contains("bool") {
            switch trimmed.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: return .text(trimmed)
            }
        }
        if type.contains("int") {
            if let value = Int64(trimmed) { return .int(value) }
        } else if type.contains("double") || type.contains("real") || type.contains("float") || type.contains("numeric") || type.contains("decimal") {
            if let value = Double(trimmed) { return .double(value) }
        }
        return .text(trimmed)
    }

    private func savePanel(suggestedName: String, format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.allowedContentTypes = [.init(filenameExtension: format.fileExtension) ?? .plainText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Exporta a página visível nos valores ÍNTEGROS (o grid trabalha com prefixos e
    /// colunas adiadas — um export com "…" seria dado corrompido).
    private func exportPage(format: ExportFormat) async {
        guard let url = savePanel(suggestedName: table, format: format) else { return }
        let visible = isNewRow ? Array(rows.dropLast()) : rows
        let fullRows = await fullPageRows() ?? visible
        let text = ResultExporter.export(
            format: format,
            columns: columns.map(\.name),
            rows: fullRows,
            tableName: table,
            engine: driver.engine
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { notice = "\(format.label) salvo · \(fullRows.count) linhas" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exporta a tabela COMPLETA em streaming — nunca materializa a tabela em memória.
    private func exportWholeTable(format: ExportFormat) async {
        guard let url = savePanel(suggestedName: table, format: format) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let total = try await ResultExporter.exportTable(
                driver: driver, table: table, format: format,
                write: { chunk in try handle.write(contentsOf: Data(chunk.utf8)) },
                progress: { done in
                    Task { @MainActor in notice = "Exportando… \(done) linhas" }
                }
            )
            withAnimation { notice = "\(format.label) salvo · \(total) linhas" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

