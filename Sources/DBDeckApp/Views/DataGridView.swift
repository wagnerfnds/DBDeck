import SwiftUI
import AppKit
import DBDeckCore

/// Especificação de coluna para o DataGridView: nome + dicas que mudam o desenho
/// (ícone de PK no cabeçalho, checkbox para bool, alinhamento à direita para números).
struct GridColumnSpec: Equatable {
    let name: String
    var typeHint = ""
    var isPrimaryKey = false
    var isBool = false
    var isNumeric = false
}

extension GridColumnSpec {
    /// Deriva as dicas do tipo declarado — mesma lógica do antigo isBoolColumn/isNumericColumn.
    init(column: DatabaseColumn) {
        let type = column.type.lowercased()
        self.init(
            name: column.name,
            typeHint: column.type,
            isPrimaryKey: column.isPrimaryKey,
            isBool: type.contains("bool"),
            isNumeric: ["int", "double", "real", "float", "numeric", "decimal", "serial"].contains { type.contains($0) }
        )
    }
}

/// Interpreta um valor como booleano (colunas bool chegam como .bool, "1" ou "true").
private func boolFlag(_ value: SQLValue) -> Bool {
    if case .bool(let flag) = value { return flag }
    let display = value.display
    return display == "true" || display == "1"
}

/// Grid de dados nativo — NSTableView **cell-based**, a arquitetura do Sequel Ace.
///
/// O modo view-based (uma NSView por célula) não sobrevive a tabelas largas: com 281
/// colunas o NSTableView materializa ~280 views POR LINHA VISÍVEL — a rolagem vertical
/// pagava a criação delas, a horizontal mostrava células "pipocando" conforme cada layer
/// desenhava, e o layout de milhares de views dominava o main thread. No modo cell-based
/// não existe view nenhuma por célula: um único NSCell POR COLUNA desenha todas as
/// células visíveis direto no canvas da tabela — rolagem é só desenho, como no grid
/// `SPCopyTable` do Sequel Ace.
///
/// Modelo de escrita: commit-on-end — `onSetValue` dispara só no FIM da edição
/// (Enter/Tab/perda de foco), nunca por keystroke. A edição usa o field editor nativo
/// (`editColumn`), com o Return interceptado em `textDidEndEditing` para mover a
/// seleção para baixo sem reabrir edição (o mesmo truque do SPCopyTable).
struct DataGridView: NSViewRepresentable {
    var columns: [GridColumnSpec]
    var rows: [[SQLValue]]
    var rowNumberStart: Int = 1
    var editable: Bool = false
    /// Índice da linha "nova" (ainda não inserida) — gutter mostra "+" em accent.
    var newRowIndex: Int? = nil
    /// Colunas que nem foram pedidas no SELECT (índices em `columns`): a célula mostra
    /// "(não carregado)" e o valor real só vem quando o usuário abre a célula.
    var deferredColumns: Set<Int> = []
    /// Página ainda chegando: linhas só crescem no fim, então dá para usar
    /// `noteNumberOfRowsChanged` (barato) em vez de `reloadData`.
    var isStreaming: Bool = false
    @Binding var selectedCell: EditCoord?
    @Binding var selectedRow: Int?
    var sortColumn: String? = nil
    var sortAscending: Bool = true
    /// Sort é server-side: o clique no header só repassa o nome da coluna.
    var onSort: ((String) -> Void)? = nil
    /// Escrita de valor (fim de edição, checkbox, Definir NULL). Nunca por keystroke.
    var onSetValue: ((_ row: Int, _ col: Int, _ value: SQLValue) -> Void)? = nil
    var onCopyRowAsInsert: ((Int) -> Void)? = nil
    /// `true` quando a célula tem só um prefixo (ou nem foi carregada) e precisa ser
    /// buscada no servidor antes de editar/copiar.
    var needsFullValue: ((_ row: Int, _ col: Int) -> Bool)? = nil
    /// Pede o valor íntegro de uma célula; a edição reabre sozinha quando ele chega.
    var onRequestFullValue: ((_ row: Int, _ col: Int) -> Void)? = nil
    /// Cópia delegada (⌘C, "Copiar valor"/"Copiar linha"): quem sabe materializar os
    /// valores cortados é o dono dos dados, não o grid.
    var onCopyValue: ((_ row: Int, _ col: Int) -> Void)? = nil
    var onCopyRow: ((_ row: Int) -> Void)? = nil

    /// Nome da coluna + amostra de valores, com clamp em [minWidth, maxWidth].
    static func estimateWidth(column: String, values: some Sequence<String>) -> CGFloat {
        var longest = column.count + 4
        for display in values {
            longest = max(longest, min(60, display.count))
        }
        let estimate = CGFloat(longest) * 8.5 + 24
        return min(GridStyle.maxWidth, max(GridStyle.minWidth, estimate))
    }

    /// Índices de até `limit` linhas ESPALHADAS pela página. Amostrar só as primeiras
    /// dimensiona mal quando os valores variam ao longo da página — o Sequel Ace
    /// percorre a página com passo `count / 100` pelo mesmo motivo.
    static func sampleIndexes(count: Int, limit: Int = 100) -> StrideTo<Int> {
        guard count > limit, limit > 0 else { return stride(from: 0, to: count, by: 1) }
        return stride(from: 0, to: count, by: count / limit)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = DataGridTableView()
        coordinator.tableView = tableView
        tableView.gridCoordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = NSColor(Theme.gridLine)
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Theme.rowHeight
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.headerView = NSTableHeaderView()
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.cellClicked(_:))
        // O doubleAction SUPRIME a edição espontânea do cell-based (clique em linha
        // selecionada abriria o field editor estilo Finder). Toda edição passa pelos
        // nossos handlers via `editColumn`.
        tableView.doubleAction = #selector(Coordinator.cellDoubleClicked(_:))

        // Menu único para o grid inteiro.
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu

        coordinator.columnsSnapshot = columns
        coordinator.rowsSnapshot = rows
        coordinator.rowNumberStartSnapshot = rowNumberStart
        coordinator.newRowIndexSnapshot = newRowIndex
        coordinator.editableSnapshot = editable
        coordinator.sortColumnSnapshot = sortColumn
        coordinator.sortAscendingSnapshot = sortAscending
        coordinator.selectedCellSnapshot = selectedCell
        coordinator.rebuildColumns(on: tableView)
        coordinator.applySortIndicators(on: tableView)
        tableView.reloadData()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        return scrollView
    }

    /// Responde ao layout do SwiftUI SEM medir o conteúdo. Sem isto, o SwiftUI pede o
    /// `fittingSize` do NSScrollView e o CoreAutoLayout popularia um engine com a
    /// subárvore inteira a cada reavaliação de layout da tela. Um grid rolável ocupa o
    /// espaço que lhe derem; seu tamanho nunca depende do conteúdo.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 500)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }

        // NUNCA escrever em binding dentro do update — isSyncing corta o eco
        // (reloadData/selectRowIndexes disparam tableViewSelectionDidChange).
        coordinator.isSyncing = true
        defer { coordinator.isSyncing = false }

        let columnsChanged = columns != coordinator.columnsSnapshot
        // Detecção de APPEND: as linhas anteriores continuam as mesmas (comparação por
        // identidade de buffer — O(n) de ponteiros) e só entraram linhas novas no fim.
        // É o caso de cada lote do streaming E da publicação final: basta avisar a nova
        // contagem.
        let snapshot = coordinator.rowsSnapshot
        let appendOnly = !columnsChanged
            && rows.count > snapshot.count
            && rows.prefix(snapshot.count).elementsEqual(snapshot)
        // O == de Array tem fast-path por identidade de buffer: estado inalterado é O(1),
        // e cada linha não tocada compara por identidade do próprio buffer.
        let rowsChanged = appendOnly || rows != snapshot
        let metaChanged = rowNumberStart != coordinator.rowNumberStartSnapshot
            || newRowIndex != coordinator.newRowIndexSnapshot
            || editable != coordinator.editableSnapshot
            || deferredColumns != coordinator.deferredColumnsSnapshot
        let newRowAppeared = newRowIndex != nil && coordinator.newRowIndexSnapshot == nil

        coordinator.columnsSnapshot = columns
        coordinator.rowsSnapshot = rows
        coordinator.rowNumberStartSnapshot = rowNumberStart
        coordinator.newRowIndexSnapshot = newRowIndex
        coordinator.editableSnapshot = editable
        coordinator.deferredColumnsSnapshot = deferredColumns

        // Dados trocando sob uma edição em curso (ex.: loadPage assíncrono): aborta a
        // edição sem commit — os dados novos têm precedência. Os fluxos síncronos
        // (Salvar, sort, paginação…) commitam ANTES via makeFirstResponder(nil).
        if (columnsChanged || rowsChanged), tableView.editedRow >= 0 {
            coordinator.cancelActiveEditing()
        }

        // Semeia as larguras ANTES do reload: a ordem continua a mais barata mesmo no
        // cell-based (menos invalidação de área já desenhada).
        if !coordinator.hasSeededWidths, !rows.isEmpty {
            coordinator.seedColumnWidths(on: tableView)
        }

        if columnsChanged {
            coordinator.rebuildColumns(on: tableView)
            tableView.reloadData()
        } else if appendOnly {
            tableView.noteNumberOfRowsChanged()
        } else if rowsChanged || metaChanged {
            // Cell-based: reloadData é só "redesenhe" — não existem views para destruir.
            tableView.reloadData()
        }

        if columnsChanged
            || sortColumn != coordinator.sortColumnSnapshot
            || sortAscending != coordinator.sortAscendingSnapshot {
            coordinator.sortColumnSnapshot = sortColumn
            coordinator.sortAscendingSnapshot = sortAscending
            coordinator.applySortIndicators(on: tableView)
        }

        // Sincroniza a seleção de linha vinda do SwiftUI.
        let targetRow = selectedRow.flatMap { $0 >= 0 && $0 < rows.count ? $0 : nil }
        if tableView.selectedRow != (targetRow ?? -1) {
            if let targetRow {
                tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }

        // Seleção de célula mudou por fora (ex.: loadPage limpa): redesenha só as
        // duas células afetadas.
        if selectedCell != coordinator.selectedCellSnapshot {
            let previous = coordinator.selectedCellSnapshot
            coordinator.selectedCellSnapshot = selectedCell
            coordinator.redrawCells(previous, selectedCell)
        }

        // Nova linha acabou de aparecer: seleciona e garante que está visível.
        if newRowAppeared, let newRowIndex, newRowIndex < rows.count {
            tableView.selectRowIndexes(IndexSet(integer: newRowIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRowIndex)
        }

        // Edição agendada (Tab commitou e mudou `rows`, ou o valor íntegro de uma
        // célula truncada chegou): só agora, com o reload feito, o field editor novo
        // pode nascer sem ser derrubado.
        if let pending = coordinator.pendingEdit {
            let stillLoading = needsFullValue?(pending.row, pending.col) == true
            if !stillLoading {
                coordinator.pendingEdit = nil
                DispatchQueue.main.async {
                    coordinator.beginEdit(pending)
                }
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGridView
        weak var tableView: DataGridTableView?

        // Snapshots para diff no updateNSView.
        var columnsSnapshot: [GridColumnSpec] = []
        var rowsSnapshot: [[SQLValue]] = []
        var rowNumberStartSnapshot = 1
        var newRowIndexSnapshot: Int?
        var editableSnapshot = false
        var deferredColumnsSnapshot: Set<Int> = []
        var sortColumnSnapshot: String?
        var sortAscendingSnapshot = true
        var selectedCellSnapshot: EditCoord?
        /// Célula cujo valor íntegro já foi pedido — evita repetir a consulta em loop
        /// quando a carga falha.
        var awaitingFullValue: EditCoord?

        /// Evita ecoar bindings enquanto o updateNSView mexe na tabela.
        var isSyncing = false

        /// Baseline do valor em edição (display original; "" para NULL) — o commit só
        /// emite onSetValue quando o texto realmente mudou.
        var editBaseline: String?
        /// Edição agendada para DEPOIS do próximo updateNSView (Tab que commitou, ou
        /// célula truncada aguardando o valor íntegro).
        var pendingEdit: EditCoord?

        /// As larguras já foram calculadas com linhas de verdade.
        var hasSeededWidths = false
        var widthSeedPasses = 0
        /// Posição de cada NSTableColumn por identifier — o objectValueFor roda por
        /// célula desenhada e a busca linear em centenas de colunas dominava o perfil.
        var columnPositionByID: [NSUserInterfaceItemIdentifier: Int] = [:]

        // Célula/linha clicadas quando o menu de contexto abriu.
        private var contextRow: Int?
        private var contextCol: Int?

        static let gutterColumnID = NSUserInterfaceItemIdentifier("#gutter")

        init(parent: DataGridView) {
            self.parent = parent
        }

        // MARK: Colunas

        func rebuildColumns(on tableView: NSTableView) {
            for column in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(column)
            }

            // Gutter fixo com o número da linha.
            let gutter = NSTableColumn(identifier: Self.gutterColumnID)
            gutter.title = "#"
            gutter.width = GridStyle.indexWidth
            gutter.resizingMask = []
            gutter.isEditable = false
            gutter.dataCell = GridTextCell.makeGutterCell()
            tableView.addTableColumn(gutter)

            for spec in parent.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.name))
                column.minWidth = GridStyle.minWidth
                column.maxWidth = GridStyle.maxWidth
                column.resizingMask = .userResizingMask
                column.headerToolTip = spec.typeHint.isEmpty ? spec.name : "\(spec.name) — \(spec.typeHint)"
                if spec.isBool {
                    // Checkbox display-only: o toggle é do cellClicked (não do tracking
                    // nativo), então a coluna fica não-editável.
                    let cell = NSButtonCell()
                    cell.setButtonType(.switch)
                    cell.title = ""
                    cell.controlSize = .small
                    cell.imagePosition = .imageOnly
                    cell.alignment = .center
                    column.dataCell = cell
                    column.isEditable = false
                } else {
                    column.dataCell = GridTextCell.makeValueCell()
                    // `editColumn` exige coluna editável; a edição ESPONTÂNEA continua
                    // bloqueada porque o doubleAction está instalado.
                    column.isEditable = true
                }
                if spec.isPrimaryKey {
                    column.headerCell.attributedStringValue = Self.pkHeaderTitle(
                        name: spec.name,
                        font: column.headerCell.font
                    )
                } else {
                    column.title = spec.name
                }
                tableView.addTableColumn(column)
            }
            widthSeedPasses = 0
            hasSeededWidths = false
            columnPositionByID = Dictionary(
                uniqueKeysWithValues: tableView.tableColumns.enumerated().map { ($1.identifier, $0) }
            )
            seedColumnWidths(on: tableView)
        }

        /// Roda `body` sem animação implícita e com as mudanças agrupadas. O contexto de
        /// animação zero impede o AppKit de animar o reposicionamento do conteúdo ao
        /// mudar largura de coluna.
        static func withoutAnimation(batchOn tableView: NSTableView, _ body: () -> Void) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            tableView.beginUpdates()
            body()
            tableView.endUpdates()
            NSAnimationContext.endGrouping()
        }

        /// Semeia as larguras a partir de uma amostra dos valores. Roda uma vez com os
        /// nomes (colunas nascem antes dos dados) e uma vez com as primeiras linhas.
        func seedColumnWidths(on tableView: NSTableView) {
            widthSeedPasses += 1
            hasSeededWidths = !parent.rows.isEmpty
            let sample = DataGridView.sampleIndexes(count: parent.rows.count)
            Self.withoutAnimation(batchOn: tableView) {
                for (index, column) in tableView.tableColumns.enumerated() where index > 0 {
                    let colIndex = index - 1
                    guard colIndex < parent.columns.count else { continue }
                    let width = DataGridView.estimateWidth(
                        column: parent.columns[colIndex].name,
                        values: sample.lazy.map { row in
                            let values = self.parent.rows[row]
                            // `cellDisplay` limita o custo em valores gigantes.
                            return colIndex < values.count ? values[colIndex].cellDisplay : ""
                        }
                    )
                    // Só escreve se mudou de verdade: cada escrita invalida a tabela.
                    if abs(column.width - width) > 2 {
                        column.width = width
                    }
                }
            }

            // O ajuste à janela roda UMA vez por tabela, no seed definitivo — precisa da
            // largura real do scroll view, que só existe depois do layout.
            guard hasSeededWidths else { return }
            DispatchQueue.main.async { [weak tableView] in
                guard let tableView else { return }
                self.fitColumnWidths(on: tableView)
            }
        }

        /// Espreme proporcionalmente as colunas largas até a página caber na janela,
        /// nenhuma abaixo de `preferredMaxWidth`. Só roda logo depois de montar as
        /// colunas, então não desfaz resize manual.
        func fitColumnWidths(on tableView: NSTableView) {
            guard let visible = tableView.enclosingScrollView?.contentSize.width, visible > 0 else { return }
            let dataColumns = tableView.tableColumns.dropFirst() // pula o gutter
            let total = dataColumns.reduce(GridStyle.indexWidth) { $0 + $1.width }
            guard total > visible else { return }

            let reducible = dataColumns.reduce(CGFloat.zero) {
                $0 + max(0, $1.width - GridStyle.preferredMaxWidth)
            }
            guard reducible > 0 else { return }
            let needed = min(total - visible, reducible)

            Self.withoutAnimation(batchOn: tableView) {
                for column in dataColumns where column.width > GridStyle.preferredMaxWidth {
                    let excess = column.width - GridStyle.preferredMaxWidth
                    let target = column.width - (excess / reducible * needed).rounded(.up)
                    if abs(column.width - target) > 2 {
                        column.width = target
                    }
                }
            }
        }

        /// Título de coluna PK: 🔑 (key.fill em amarelo) + nome.
        private static func pkHeaderTitle(name: String, font: NSFont?) -> NSAttributedString {
            let title = NSMutableAttributedString()
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemYellow]))
            if let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "chave primária")?
                .withSymbolConfiguration(config) {
                let attachment = NSTextAttachment()
                attachment.image = key
                attachment.bounds = CGRect(x: 0, y: -1, width: key.size.width, height: key.size.height)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            }
            title.append(NSAttributedString(
                string: name,
                attributes: [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .semibold)]
            ))
            return title
        }

        func applySortIndicators(on tableView: NSTableView) {
            for (index, column) in tableView.tableColumns.enumerated() {
                guard index > 0 else { continue }
                let isSorted = parent.onSort != nil && column.identifier.rawValue == parent.sortColumn
                let imageName = parent.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                tableView.setIndicatorImage(isSorted ? NSImage(named: imageName) : nil, in: column)
            }
        }

        // MARK: Dados (cell-based: valor + estilo, nenhuma view)

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        private func value(row: Int, colIndex: Int) -> SQLValue {
            guard row < parent.rows.count else { return .null }
            let rowValues = parent.rows[row]
            return colIndex < rowValues.count ? rowValues[colIndex] : .null
        }

        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            guard let tableColumn, row < parent.rows.count,
                  let columnPosition = columnPositionByID[tableColumn.identifier]
            else { return nil }

            if columnPosition == 0 {
                return row == parent.newRowIndex ? "+" : String(parent.rowNumberStart + row)
            }
            let colIndex = columnPosition - 1
            guard colIndex < parent.columns.count else { return nil }

            if parent.columns[colIndex].isBool {
                return NSNumber(value: boolFlag(value(row: row, colIndex: colIndex)))
            }
            if parent.deferredColumns.contains(colIndex) {
                return "(não carregado)"
            }
            let cellValue = value(row: row, colIndex: colIndex)
            switch cellValue {
            case .null: return "NULL"
            case .blob: return "BLOB"
            default: return cellValue.cellDisplay
            }
        }

        /// Estilo por célula, aplicado no cell COMPARTILHADO da coluna imediatamente
        /// antes de cada desenho — o coração do cell-based.
        func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
            guard let tableColumn,
                  let columnPosition = columnPositionByID[tableColumn.identifier]
            else { return }

            if let button = cell as? NSButtonCell {
                button.isEnabled = parent.editable && parent.onSetValue != nil
                return
            }
            guard let textCell = cell as? GridTextCell else { return }

            if columnPosition == 0 {
                let isNew = row == parent.newRowIndex
                textCell.applyStyle(isNew ? .gutterNew : .gutter)
                textCell.showsSelectionRing = false
                return
            }

            let colIndex = columnPosition - 1
            guard colIndex < parent.columns.count else { return }
            textCell.showsSelectionRing = parent.selectedCell == EditCoord(row: row, col: colIndex)

            if parent.deferredColumns.contains(colIndex) {
                textCell.applyStyle(.null)
                return
            }
            switch value(row: row, colIndex: colIndex) {
            case .null:
                textCell.applyStyle(.null)
            case .blob:
                textCell.applyStyle(.blob)
            case .truncated(_, _, let isBinary):
                textCell.applyStyle(isBinary ? .blob : .muted)
            default:
                textCell.applyStyle(parent.columns[colIndex].isNumeric ? .valueNumeric : .value)
            }
        }

        /// Commit da edição (field editor nativo): chega aqui SÓ no fim (Enter/Tab/foco).
        func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
            guard let tableColumn,
                  let columnPosition = columnPositionByID[tableColumn.identifier],
                  columnPosition > 0
            else { return }
            let colIndex = columnPosition - 1
            let text = object as? String ?? ""
            let baseline = editBaseline
            editBaseline = nil
            // Sem mudança real: não emite — manter `rows == original` é o que evita o
            // falso "alterações não salvas".
            guard text != (baseline ?? "") else { return }
            parent.onSetValue?(row, colIndex, .text(text))
        }

        /// Edição ESPONTÂNEA sempre bloqueada — o doubleAction/Return/type-to-edit
        /// chamam `editColumn` explicitamente, depois dos gates (BLOB, truncado…).
        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
            false
        }

        // MARK: Seleção

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let tableView else { return }
            let row = tableView.selectedRow
            // A seleção de linha mudou para longe da célula selecionada: apaga o anel.
            if let cellCoord = parent.selectedCell, row != cellCoord.row {
                setSelectedCell(nil)
            }
            let newValue: Int? = row >= 0 ? row : nil
            if parent.selectedRow != newValue {
                parent.selectedRow = newValue
            }
        }

        @objc func cellClicked(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let columnPosition = tableView.clickedColumn
            guard row >= 0, row < parent.rows.count else { return }
            if columnPosition > 0, columnPosition - 1 < parent.columns.count {
                let colIndex = columnPosition - 1
                setSelectedCell(EditCoord(row: row, col: colIndex))
                // Checkbox: o clique simples alterna (o tracking nativo está desligado).
                if parent.columns[colIndex].isBool, parent.editable, parent.onSetValue != nil {
                    endActiveEditing()
                    let current = boolFlag(value(row: row, colIndex: colIndex))
                    parent.onSetValue?(row, colIndex, .bool(!current))
                }
            } else {
                // Gutter: a linha continua selecionada (seleção nativa), célula não.
                setSelectedCell(nil)
            }
        }

        /// Atualiza binding + redesenha as duas células afetadas (sem reloadData).
        func setSelectedCell(_ coord: EditCoord?) {
            let previous = selectedCellSnapshot
            selectedCellSnapshot = coord
            if parent.selectedCell != coord {
                parent.selectedCell = coord
            }
            redrawCells(previous, coord)
        }

        func redrawCells(_ first: EditCoord?, _ second: EditCoord?) {
            guard let tableView else { return }
            for coord in [first, second].compactMap({ $0 }) {
                guard coord.row < tableView.numberOfRows,
                      coord.col + 1 < tableView.numberOfColumns else { continue }
                tableView.setNeedsDisplay(tableView.frameOfCell(atColumn: coord.col + 1, row: coord.row))
            }
        }

        /// Seleção via teclado: célula + linha nativa + auto-scroll.
        func select(_ coord: EditCoord) {
            guard let tableView,
                  coord.row >= 0, coord.row < parent.rows.count,
                  coord.col >= 0, coord.col < parent.columns.count else { return }
            setSelectedCell(coord)
            if parent.selectedRow != coord.row {
                parent.selectedRow = coord.row
            }
            if tableView.selectedRow != coord.row {
                isSyncing = true
                tableView.selectRowIndexes(IndexSet(integer: coord.row), byExtendingSelection: false)
                isSyncing = false
            }
            tableView.scrollRowToVisible(coord.row)
            tableView.scrollColumnToVisible(coord.col + 1) // +1 pula o gutter
        }

        /// Esc fora de edição: limpa célula e linha selecionadas.
        func clearSelection() {
            setSelectedCell(nil)
            tableView?.deselectAll(nil)
        }

        // MARK: Teclado (navegação e atalhos fora de edição)

        /// Célula editável inline: grid editável, coluna não-bool e valor não-binário.
        /// Prefixo de TEXTO é editável — a edição só abre depois de carregar o valor
        /// íntegro (ver `beginEdit`); prefixo BINÁRIO não, como qualquer BLOB.
        func isEditableCell(_ coord: EditCoord) -> Bool {
            guard parent.editable, parent.onSetValue != nil,
                  coord.row >= 0, coord.row < parent.rows.count,
                  coord.col >= 0, coord.col < parent.columns.count else { return false }
            if parent.columns[coord.col].isBool { return false }
            switch value(row: coord.row, colIndex: coord.col) {
            case .blob: return false
            case .truncated(_, _, let isBinary): return !isBinary
            default: return true
            }
        }

        /// Próxima célula editável a partir de `coord` (Tab: frente, Shift+Tab: trás),
        /// pulando bool/BLOB, com wrap de linha; nil nos extremos do grid.
        func nextEditableCoord(from coord: EditCoord, forward: Bool) -> EditCoord? {
            let columnCount = parent.columns.count
            guard columnCount > 0 else { return nil }
            var row = coord.row
            var col = coord.col
            while true {
                if forward {
                    col += 1
                    if col == columnCount { col = 0; row += 1 }
                    if row >= parent.rows.count { return nil }
                } else {
                    col -= 1
                    if col < 0 { col = columnCount - 1; row -= 1 }
                    if row < 0 { return nil }
                }
                let candidate = EditCoord(row: row, col: col)
                if isEditableCell(candidate) { return candidate }
            }
        }

        /// Trata o keyDown da tabela (nunca dispara durante edição — o field editor
        /// é o first responder). Retorna true quando o evento foi consumido.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let tableView else { return false }
            let mods = event.modifierFlags

            // Redundância do ⌘C (o caminho normal é o copy(_:) da responder chain).
            if mods.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
                guard hasCopyableSelection else { return false }
                copySelection()
                return true
            }

            guard !parent.rows.isEmpty, !parent.columns.isEmpty else { return false }
            let lastRow = parent.rows.count - 1
            let lastCol = parent.columns.count - 1
            let start = parent.selectedCell ?? EditCoord(row: parent.selectedRow ?? 0, col: 0)
            let current = EditCoord(
                row: min(max(0, start.row), lastRow),
                col: min(max(0, start.col), lastCol)
            )

            switch event.specialKey {
            case .leftArrow?:
                select(EditCoord(row: current.row, col: max(0, current.col - 1)))
                return true
            case .rightArrow?:
                select(EditCoord(row: current.row, col: min(lastCol, current.col + 1)))
                return true
            case .upArrow?:
                let row = mods.contains(.command) ? 0 : max(0, current.row - 1)
                select(EditCoord(row: row, col: current.col))
                return true
            case .downArrow?:
                let row = mods.contains(.command) ? lastRow : min(lastRow, current.row + 1)
                select(EditCoord(row: row, col: current.col))
                return true
            case .home?:
                select(EditCoord(row: 0, col: current.col))
                return true
            case .end?:
                select(EditCoord(row: lastRow, col: current.col))
                return true
            case .pageUp?, .pageDown?:
                let page = max(1, tableView.rows(in: tableView.visibleRect).length)
                let row = event.specialKey == .pageUp
                    ? max(0, current.row - page)
                    : min(lastRow, current.row + page)
                select(EditCoord(row: row, col: current.col))
                return true
            default:
                break
            }

            // Return (36) / Enter numérico (76): inicia edição na célula selecionada.
            if event.keyCode == 36 || event.keyCode == 76 {
                guard let coord = parent.selectedCell else { return false }
                beginEdit(coord)
                return true
            }

            // Backspace (51) / Forward Delete (117): define NULL na célula.
            if event.keyCode == 51 || event.keyCode == 117 {
                guard parent.editable, parent.onSetValue != nil,
                      let coord = parent.selectedCell,
                      coord.col < parent.columns.count, !parent.columns[coord.col].isBool
                else { return false }
                parent.onSetValue?(coord.row, coord.col, .null)
                return true
            }

            // Type-to-edit: caractere imprimível substitui o conteúdo da célula.
            if !mods.contains(.command), !mods.contains(.control),
               let characters = event.characters,
               let scalar = characters.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value != 0x7F,
               !(0xF700...0xF8FF).contains(scalar.value),
               let coord = parent.selectedCell, isEditableCell(coord) {
                beginEdit(coord, initialText: characters)
                return true
            }

            return false
        }

        // MARK: Sort

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard parent.onSort != nil, tableColumn.identifier != Self.gutterColumnID else { return }
            endActiveEditing()
            parent.onSort?(tableColumn.identifier.rawValue)
        }

        // MARK: Auto-ajuste de largura (duplo-clique no divisor do header)

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard column > 0, column - 1 < parent.columns.count else { return GridStyle.indexWidth }
            let colIndex = column - 1
            let spec = parent.columns[colIndex]

            let headerFont = tableView.tableColumns[column].headerCell.font
                ?? NSFont.systemFont(ofSize: 11, weight: .semibold)
            var width = NSAttributedString(string: spec.name, attributes: [.font: headerFont]).size().width
            if spec.isPrimaryKey {
                width += 16 // ícone key.fill + espaço
            }

            if parent.deferredColumns.contains(colIndex) {
                let placeholder = NSAttributedString(
                    string: "(não carregado)",
                    attributes: [.font: GridTextCell.nullFont]
                ).size().width
                return min(GridStyle.maxWidth, max(GridStyle.minWidth, max(width, placeholder) + 16))
            }

            // Strings maiores que o maxWidth comporta são cortadas antes de medir.
            let cellFont = GridTextCell.valueFont
            let maxChars = Int(GridStyle.maxWidth / 5) + 2
            for rowValues in parent.rows where colIndex < rowValues.count {
                let text: String
                switch rowValues[colIndex] {
                case .null: text = "NULL"
                case .blob: text = "BLOB"
                default: text = String(rowValues[colIndex].cellDisplay.prefix(maxChars))
                }
                let measured = NSAttributedString(string: text, attributes: [.font: cellFont]).size().width
                if measured > width { width = measured }
            }
            return min(GridStyle.maxWidth, max(GridStyle.minWidth, width + 16))
        }

        // MARK: Edição (field editor nativo via editColumn, commit-on-end)

        @objc func cellDoubleClicked(_ sender: Any?) {
            guard let tableView, parent.editable, parent.onSetValue != nil else { return }
            let row = tableView.clickedRow
            let columnPosition = tableView.clickedColumn
            guard row >= 0, row < parent.rows.count, columnPosition > 0 else { return }
            let col = columnPosition - 1
            guard col < parent.columns.count else { return }
            beginEdit(EditCoord(row: row, col: col))
        }

        /// Inicia a edição in-place com o field editor nativo. `initialText`
        /// (type-to-edit) substitui o conteúdo com o cursor no fim.
        func beginEdit(_ coord: EditCoord, initialText: String? = nil) {
            guard let tableView, parent.editable else { return }
            guard isEditableCell(coord) else { return }

            // Célula com valor cortado (ou coluna adiada): editar o prefixo gravaria
            // dado truncado por cima do original. Pede o valor íntegro e reabre a
            // edição quando ele chega (pendingEdit dispara no próximo updateNSView).
            if parent.needsFullValue?(coord.row, coord.col) == true {
                guard awaitingFullValue != coord else {
                    awaitingFullValue = nil
                    return
                }
                endActiveEditing()
                awaitingFullValue = coord
                setSelectedCell(coord)
                pendingEdit = coord
                parent.onRequestFullValue?(coord.row, coord.col)
                return
            }
            awaitingFullValue = nil
            endActiveEditing()

            let cellValue = value(row: coord.row, colIndex: coord.col)
            setSelectedCell(coord)
            tableView.scrollRowToVisible(coord.row)
            tableView.scrollColumnToVisible(coord.col + 1)

            // editColumn exige a linha selecionada.
            if tableView.selectedRow != coord.row {
                isSyncing = true
                tableView.selectRowIndexes(IndexSet(integer: coord.row), byExtendingSelection: false)
                isSyncing = false
            }

            editBaseline = cellValue == .null ? "" : cellValue.display
            tableView.editColumn(coord.col + 1, row: coord.row, with: nil, select: true)

            // O field editor nasce com o texto de EXIBIÇÃO ("NULL", preview…); troca
            // pelo valor de edição real — baseline ou o texto digitado (type-to-edit).
            if let editor = tableView.currentEditor() {
                let text = initialText ?? editBaseline ?? ""
                editor.string = text
                if initialText != nil {
                    editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                } else {
                    editor.selectAll(nil)
                }
            }
        }

        /// Encerra a edição em curso commitando (perder o first responder dispara o
        /// fluxo nativo de textDidEndEditing → setObjectValue).
        func endActiveEditing() {
            guard let tableView, tableView.editedRow >= 0 else { return }
            tableView.window?.makeFirstResponder(tableView)
        }

        /// Encerra a edição em curso SEM commit (dados mudaram por fora).
        func cancelActiveEditing() {
            guard let tableView, tableView.editedRow >= 0 else { return }
            editBaseline = nil
            tableView.abortEditing()
            tableView.window?.makeFirstResponder(tableView)
        }

        /// Chamado pela DataGridTableView quando o field editor termina com Tab/Backtab:
        /// move a edição para a célula editável vizinha (o nativo andaria coluna a
        /// coluna, sem pular BLOB/bool nem fazer wrap de linha).
        func moveEditing(forward: Bool) {
            guard let coord = selectedCellSnapshot ?? parent.selectedCell else { return }
            guard let next = nextEditableCoord(from: coord, forward: forward) else {
                select(coord)
                return
            }
            select(next)
            // O commit do Tab pode ter mudado `rows` (updateNSView + reload a caminho):
            // a próxima edição nasce DEPOIS desse ciclo, via pendingEdit.
            pendingEdit = next
        }

        /// Chamado quando o field editor termina com Return: commit + seleção desce
        /// (comportamento Sequel Ace — não reabre a edição).
        func moveSelectionDownAfterEditing() {
            guard let coord = selectedCellSnapshot ?? parent.selectedCell else { return }
            select(EditCoord(row: min(coord.row + 1, parent.rows.count - 1), col: coord.col))
        }

        // MARK: Cópia

        var hasCopyableSelection: Bool {
            parent.selectedCell != nil || (tableView?.selectedRow ?? -1) >= 0
        }

        /// ⌘C: célula selecionada → valor; senão linha selecionada → tab-separado.
        /// Quando o dono dos dados sabe materializar valores cortados, a cópia é
        /// delegada — copiar o prefixo com "…" seria entregar dado incompleto.
        func copySelection() {
            if let coord = parent.selectedCell,
               coord.row < parent.rows.count, coord.col < parent.rows[coord.row].count {
                if let delegated = parent.onCopyValue {
                    delegated(coord.row, coord.col)
                    return
                }
                let value = parent.rows[coord.row][coord.col]
                setPasteboard(value == .null ? "NULL" : value.display)
            } else if let row = tableView?.selectedRow, row >= 0, row < parent.rows.count {
                copyRow(row)
            }
        }

        private func copyRow(_ row: Int) {
            guard row < parent.rows.count else { return }
            if let delegated = parent.onCopyRow {
                delegated(row)
                return
            }
            let line = parent.rows[row]
                .map { $0 == .null ? "NULL" : $0.display }
                .joined(separator: "\t")
            setPasteboard(line)
        }

        private func setPasteboard(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        // MARK: Menu de contexto

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let row = tableView.clickedRow
            let columnPosition = tableView.clickedColumn
            guard row >= 0, row < parent.rows.count else { return }

            contextRow = row
            contextCol = columnPosition > 0 && columnPosition - 1 < parent.columns.count
                ? columnPosition - 1
                : nil

            // O clique direito também seleciona a célula/linha clicada.
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let col = contextCol {
                setSelectedCell(EditCoord(row: row, col: col))
            } else {
                setSelectedCell(nil)
            }

            if contextCol != nil {
                menu.addItem(makeItem("Copiar valor", action: #selector(copyValueAction(_:))))
            }
            menu.addItem(makeItem("Copiar linha", action: #selector(copyRowAction(_:))))
            if parent.onCopyRowAsInsert != nil {
                menu.addItem(makeItem("Copiar como INSERT", action: #selector(copyRowAsInsertAction(_:))))
            }
            if parent.editable, parent.onSetValue != nil, contextCol != nil {
                menu.addItem(.separator())
                menu.addItem(makeItem("Definir NULL", action: #selector(setNullAction(_:))))
            }
        }

        private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func copyValueAction(_ sender: Any?) {
            guard let row = contextRow, let col = contextCol,
                  row < parent.rows.count, col < parent.rows[row].count else { return }
            if let delegated = parent.onCopyValue {
                delegated(row, col)
                return
            }
            let value = parent.rows[row][col]
            setPasteboard(value == .null ? "NULL" : value.display)
        }

        @objc private func copyRowAction(_ sender: Any?) {
            guard let row = contextRow else { return }
            copyRow(row)
        }

        @objc private func copyRowAsInsertAction(_ sender: Any?) {
            guard let row = contextRow, row < parent.rows.count else { return }
            parent.onCopyRowAsInsert?(row)
        }

        @objc private func setNullAction(_ sender: Any?) {
            guard let row = contextRow, let col = contextCol, row < parent.rows.count else { return }
            parent.onSetValue?(row, col, .null)
        }
    }
}

// MARK: - NSTableView (⌘C, teclado e o truque do textDidEndEditing)

/// Subclasse necessária para o copy da responder chain, os hooks de teclado da UX e a
/// interceptação do fim de edição — Return move a seleção para baixo e Tab/Backtab
/// movem a EDIÇÃO para a célula editável vizinha, em vez do comportamento nativo.
final class DataGridTableView: NSTableView {
    weak var gridCoordinator: DataGridView.Coordinator?

    /// Navegação/atalhos fora de edição — durante edição o field editor é o first
    /// responder e este keyDown nunca dispara.
    override func keyDown(with event: NSEvent) {
        if gridCoordinator?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// Esc fora de edição limpa a seleção de célula/linha.
    override func cancelOperation(_ sender: Any?) {
        gridCoordinator?.clearSelection()
    }

    /// O truque do SPCopyTable: o movimento que encerrou a edição é reescrito para
    /// `illegal` ANTES de o NSTableView agir — senão o Return/Tab nativos iniciariam a
    /// edição da célula vizinha por conta própria (sem pular BLOB/bool, sem wrap e sem
    /// o gate de valores truncados). O commit (setObjectValue) já aconteceu dentro do
    /// super; só a NAVEGAÇÃO é nossa.
    override func textDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?["NSTextMovement"] as? Int ?? NSIllegalTextMovement

        var info = notification.userInfo ?? [:]
        info["NSTextMovement"] = NSIllegalTextMovement
        super.textDidEndEditing(Notification(
            name: notification.name,
            object: notification.object,
            userInfo: info
        ))

        switch movement {
        case NSReturnTextMovement:
            window?.makeFirstResponder(self)
            gridCoordinator?.moveSelectionDownAfterEditing()
        case NSTabTextMovement:
            window?.makeFirstResponder(self)
            gridCoordinator?.moveEditing(forward: true)
        case NSBacktabTextMovement:
            window?.makeFirstResponder(self)
            gridCoordinator?.moveEditing(forward: false)
        default:
            break
        }
    }

    @objc func copy(_ sender: Any?) {
        gridCoordinator?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(DataGridTableView.copy(_:)) {
            return gridCoordinator?.hasCopyableSelection ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Célula

/// NSTextFieldCell do grid: UMA instância por coluna desenha todas as células visíveis
/// daquela coluna (o `willDisplayCell` ajusta estilo por célula imediatamente antes de
/// cada desenho). Sem views, sem layers, sem layout — só desenho, como o Sequel Ace.
final class GridTextCell: NSTextFieldCell {
    /// Estilos pré-computados; trocar fonte/cor por célula desenhada precisa ser barato.
    enum Style {
        case value
        case valueNumeric
        case null
        case blob
        case muted
        case gutter
        case gutterNew
    }

    static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let smallFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    static let nullFont = NSFontManager.shared.convert(
        NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        toHaveTrait: .italicFontMask
    )
    private static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let gutterNewFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

    /// Anel accent da célula selecionada — setado pelo willDisplayCell antes do desenho.
    var showsSelectionRing = false

    static func makeValueCell() -> GridTextCell {
        let cell = GridTextCell(textCell: "")
        cell.font = valueFont
        cell.lineBreakMode = .byTruncatingTail
        cell.truncatesLastVisibleLine = true
        cell.drawsBackground = false
        cell.isBezeled = false
        cell.isEditable = true
        cell.isSelectable = true
        cell.usesSingleLineMode = true
        return cell
    }

    static func makeGutterCell() -> GridTextCell {
        let cell = makeValueCell()
        cell.isEditable = false
        cell.isSelectable = false
        cell.alignment = .center
        return cell
    }

    func applyStyle(_ style: Style) {
        switch style {
        case .value:
            font = Self.valueFont
            textColor = .labelColor
            alignment = .left
        case .valueNumeric:
            font = Self.valueFont
            textColor = .labelColor
            alignment = .right
        case .null:
            font = Self.nullFont
            textColor = NSColor(Theme.nullText)
            alignment = .left
        case .blob:
            font = Self.smallFont
            textColor = .secondaryLabelColor
            alignment = .left
        case .muted:
            font = Self.valueFont
            textColor = .secondaryLabelColor
            alignment = .left
        case .gutter:
            font = Self.gutterFont
            textColor = .tertiaryLabelColor
            alignment = .center
        case .gutterNew:
            font = Self.gutterNewFont
            textColor = .controlAccentColor
            alignment = .center
        }
    }

    /// Margem horizontal do texto (o cell nativo desenha colado na borda).
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inset = super.drawingRect(forBounds: rect)
        inset.origin.x += 6
        inset.size.width = max(0, inset.size.width - 12)
        return inset
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: cellFrame, in: controlView)
        if showsSelectionRing {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(
                roundedRect: cellFrame.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2
            )
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
