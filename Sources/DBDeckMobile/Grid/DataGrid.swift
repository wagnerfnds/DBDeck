import SwiftUI
import UIKit
import DBDeckCore

/// Coluna como o grid a enxerga (tabela ou resultado de consulta).
struct GridColumn: Equatable {
    var name: String
    var type: String?
    var isPrimaryKey = false

    init(name: String, type: String? = nil, isPrimaryKey: Bool = false) {
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
    }

    init(column: DatabaseColumn) {
        self.init(name: column.name, type: column.type, isPrimaryKey: column.isPrimaryKey)
    }
}

/// Grid de dados para o toque, sobre `UICollectionView` + `SpreadsheetLayout`.
///
/// - Toque numa célula: seleciona e chama `onTapCell` (a tela abre o detalhe da linha).
/// - Toque no cabeçalho: ordena.
/// - Toque e segure: menu de contexto nativo (copiar, filtrar por valor, seguir FK…).
/// - Puxar para baixo: recarrega. Chegar perto do fim: `onNearEnd` (rolagem infinita).
///
/// `rowsVersion` é o que decide recarregar: comparar milhares de linhas a cada
/// atualização de SwiftUI custaria mais que a recarga.
struct DataGrid: UIViewRepresentable {
    var columns: [GridColumn]
    var rows: [[SQLValue]]
    var rowsVersion: Int
    var scrollResetToken = 0
    var sortColumn: String? = nil
    var sortAscending = true
    var deferredColumns: Set<Int> = []
    var linkColumns: Set<Int> = []
    var rowHeight: CGFloat
    var zebra: Bool
    var fontSize: CGFloat = 13
    var selectedRow: Int?

    var onTapCell: ((_ row: Int, _ col: Int) -> Void)?
    var onTapHeader: ((_ col: Int) -> Void)?
    var onNearEnd: (() -> Void)?
    var onRefresh: (() async -> Void)?
    var cellMenu: ((_ row: Int, _ col: Int) -> UIMenu?)?
    var headerMenu: ((_ col: Int) -> UIMenu?)?

    func makeCoordinator() -> GridCoordinator { GridCoordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SpreadsheetLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .systemBackground
        view.contentInsetAdjustmentBehavior = .never
        // Rolagem nos dois eixos sem travar num só: em tabela larga o dedo raramente
        // é perfeitamente horizontal.
        view.isDirectionalLockEnabled = true
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = true
        view.keyboardDismissMode = .onDrag
        view.register(GridDataCell.self, forCellWithReuseIdentifier: GridDataCell.reuseID)
        view.register(GridIndexCell.self, forCellWithReuseIdentifier: GridIndexCell.reuseID)
        view.register(GridHeaderCell.self, forCellWithReuseIdentifier: GridHeaderCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        // Prefetch do UICollectionView prepara células fora da tela à frente da rolagem;
        // com layout próprio de planilha ele só atrapalha (prepara colunas erradas).
        view.isPrefetchingEnabled = false
        context.coordinator.collectionView = view
        context.coordinator.layout = layout
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(from: self)
    }
}

@MainActor
final class GridCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
    weak var collectionView: UICollectionView?
    var layout: SpreadsheetLayout!

    private var config: DataGrid?
    private var columns: [GridColumn] = []
    private var rows: [[SQLValue]] = []
    private var rowsVersion = -1
    private var scrollResetToken = 0
    private var fontSize: CGFloat = 0
    private var widthsKey: [String] = []
    private var selectedCell: (row: Int, col: Int)?
    private var nearEndRequested = false
    private var refresh: UIRefreshControl?

    private var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var italicFont = UIFont.italicSystemFont(ofSize: 12)
    private let zebraColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.035) : UIColor(white: 0, alpha: 0.025)
    }
    private let selectionColor = UIColor.tintColor.withAlphaComponent(0.14)
    private let cellSelectionColor = UIColor.tintColor.withAlphaComponent(0.28)

    func update(from config: DataGrid) {
        guard let collectionView else { return }
        let previous = self.config
        self.config = config

        if config.fontSize != fontSize {
            fontSize = config.fontSize
            font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            italicFont = .italicSystemFont(ofSize: fontSize - 1)
        }

        configureRefreshControl(enabled: config.onRefresh != nil)

        var needsReload = false
        let columnsChanged = config.columns != columns
        if columnsChanged || config.rowsVersion != rowsVersion {
            let wasEmpty = rows.isEmpty
            columns = config.columns
            rows = config.rows
            rowsVersion = config.rowsVersion
            nearEndRequested = false
            // Larguras medidas uma vez por conjunto de colunas (e de novo quando chegam
            // as primeiras linhas): recalcular a cada lote faria as colunas pularem
            // enquanto a página ainda está chegando.
            let key = columns.map(\.name)
            if columnsChanged || key != widthsKey || (wasEmpty && !rows.isEmpty) {
                widthsKey = key
                layout.measuredWidths = measureWidths()
            }
            if columnsChanged || wasEmpty { selectedCell = nil }
            needsReload = true
        }
        if layout.rowCount != rows.count { layout.rowCount = rows.count }
        if layout.rowHeight != config.rowHeight {
            layout.rowHeight = config.rowHeight
            needsReload = true
        }
        let digits = max(2, String(max(rows.count, 1)).count)
        let indexWidth = CGFloat(digits) * 8 + 16
        if layout.indexWidth != indexWidth {
            layout.setIndexWidth(indexWidth)
            needsReload = true
        }

        let resetScroll = columnsChanged || config.scrollResetToken != scrollResetToken
        scrollResetToken = config.scrollResetToken
        if needsReload {
            collectionView.reloadData()
            if resetScroll, collectionView.refreshControl?.isRefreshing != true {
                collectionView.setContentOffset(.zero, animated: false)
            }
        } else if previous?.sortColumn != config.sortColumn
                    || previous?.sortAscending != config.sortAscending
                    || previous?.zebra != config.zebra
                    || previous?.selectedRow != config.selectedRow
                    || previous?.linkColumns != config.linkColumns {
            reconfigureVisible()
        }
        if config.selectedRow == nil, selectedCell != nil, previous?.selectedRow != nil {
            selectedCell = nil
            reconfigureVisible()
        }
    }

    private func reconfigureVisible() {
        guard let collectionView else { return }
        collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
    }

    private func configureRefreshControl(enabled: Bool) {
        guard let collectionView else { return }
        if enabled, refresh == nil {
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
            collectionView.refreshControl = control
            refresh = control
        } else if !enabled, refresh != nil {
            collectionView.refreshControl = nil
            refresh = nil
        }
    }

    @objc private func refreshPulled() {
        guard let onRefresh = config?.onRefresh else {
            refresh?.endRefreshing()
            return
        }
        Task { @MainActor in
            await onRefresh()
            self.refresh?.endRefreshing()
        }
    }

    // MARK: - Larguras

    /// Largura por conteúdo, em aritmética de fonte monoespaçada: a largura de um
    /// caractere vezes o maior texto de uma amostra. Sem medir texto com o TextKit —
    /// numa tabela de 80 colunas isso seriam milhares de medições a cada abertura.
    private func measureWidths() -> [CGFloat] {
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let headerFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let sample = rows.prefix(80)
        return columns.enumerated().map { index, column in
            var longest = 0
            for row in sample where index < row.count {
                let length: Int
                switch row[index] {
                case .null: length = 4
                case .text(let text): length = min(text.count, 48)
                default: length = min(row[index].display.count, 48)
                }
                if length > longest { longest = length }
            }
            let headerWidth = (column.name as NSString).size(withAttributes: [.font: headerFont]).width
                + (column.isPrimaryKey ? 16 : 0) + 20
            let typeWidth = CGFloat(min((column.type ?? "").count, 24)) * 6.2
            let contentWidth = CGFloat(longest) * charWidth + 20
            return min(280, max(72, headerWidth, typeWidth + 16, contentWidth))
        }
    }


    // MARK: - Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        columns.isEmpty ? 0 : (rows.count + 1) * (columns.count + 1)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let (row, col) = layout.position(of: indexPath.item)
        if row < 0 {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GridHeaderCell.reuseID, for: indexPath) as! GridHeaderCell
            if col < 0 {
                cell.configureCorner(rowCount: rows.count)
            } else {
                let column = columns[col]
                let sort: Bool? = config?.sortColumn == column.name ? config?.sortAscending : nil
                cell.configure(column: column, sort: sort)
            }
            return cell
        }
        if col < 0 {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GridIndexCell.reuseID, for: indexPath) as! GridIndexCell
            cell.configure(number: row + 1, selected: config?.selectedRow == row)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GridDataCell.reuseID, for: indexPath) as! GridDataCell
        let value: SQLValue? = row < rows.count && col < rows[row].count ? rows[row][col] : nil
        let isSelectedRow = config?.selectedRow == row
        let isSelectedCell = isSelectedRow && selectedCell?.col == col
        let background: UIColor
        if isSelectedCell {
            background = cellSelectionColor
        } else if isSelectedRow {
            background = selectionColor
        } else if config?.zebra == true, row % 2 == 1 {
            background = zebraColor
        } else {
            background = .clear
        }
        cell.configure(
            value: value,
            deferred: config?.deferredColumns.contains(col) == true,
            isLink: config?.linkColumns.contains(col) == true,
            font: font,
            italicFont: italicFont,
            background: background,
            columnName: columns[col].name
        )
        return cell
    }

    // MARK: - Delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let (row, col) = layout.position(of: indexPath.item)
        if row < 0 {
            guard col >= 0 else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            config?.onTapHeader?(col)
            return
        }
        selectedCell = (row, max(col, 0))
        config?.onTapCell?(row, max(col, 0))
        reconfigureVisible()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let (row, col) = layout.position(of: indexPath.item)
        if row < 0 {
            guard col >= 0, let menu = config?.headerMenu?(col) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        }
        guard col >= 0, let menu = config?.cellMenu?(row, col) else { return nil }
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { _ in menu }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let onNearEnd = config?.onNearEnd, !nearEndRequested, !rows.isEmpty else { return }
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
        // Três telas antes do fim: a próxima página chega antes do dedo alcançar o fim.
        if visibleBottom > scrollView.contentSize.height - scrollView.bounds.height * 3 {
            nearEndRequested = true
            onNearEnd()
        }
    }
}
