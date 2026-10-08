import UIKit

/// Layout de planilha para o `UICollectionView` do grid.
///
/// Uma seção só, item = `linha * (colunas + 1) + coluna`, onde a linha 0 é o cabeçalho
/// e a coluna 0 é a numeração. Nada é pré-calculado por item: a posição sai de soma de
/// prefixos (colunas) e multiplicação (linhas), e `layoutAttributesForElements(in:)` só
/// materializa o retângulo visível — uma página de 50 mil linhas × 40 colunas custa o
/// mesmo que uma de 100. É o equivalente ao "só as ~40 linhas visíveis existem" do
/// NSTableView no Mac.
///
/// Cabeçalho e numeração ficam pinados acompanhando o `contentOffset`, por isso o
/// layout invalida a cada mudança de bounds — barato, porque só o visível é refeito.
final class SpreadsheetLayout: UICollectionViewLayout {
    /// Larguras medidas pelo conteúdo. As efetivas (`columnWidths`) esticam para ocupar a
    /// tela quando a soma não chega à largura visível — um resultado de duas colunas
    /// estreitas não deixa meia tela vazia à direita.
    var measuredWidths: [CGFloat] = [] { didSet { stretch(force: true) } }
    private(set) var columnWidths: [CGFloat] = [] { didSet { recomputeOffsets() } }
    private var stretchedForWidth: CGFloat = -1
    var rowCount = 0
    var rowHeight: CGFloat = 34
    var headerHeight: CGFloat = 44
    var indexWidth: CGFloat = 44

    /// x de início de cada coluna de dados (já somado o `indexWidth`), + o fim da última.
    private var columnOffsets: [CGFloat] = [0]

    var columnCount: Int { columnWidths.count }
    private var stride: Int { columnCount + 1 }

    private func recomputeOffsets() {
        var offsets: [CGFloat] = [indexWidth]
        offsets.reserveCapacity(columnWidths.count + 1)
        var x = indexWidth
        for width in columnWidths {
            x += width
            offsets.append(x)
        }
        columnOffsets = offsets
    }

    func setIndexWidth(_ width: CGFloat) {
        indexWidth = width
        stretch(force: true)
    }

    func setMeasuredWidth(_ width: CGFloat, at index: Int) {
        guard index < measuredWidths.count else { return }
        measuredWidths[index] = width
    }

    private func stretch(force: Bool) {
        let available = (collectionView?.bounds.width ?? 0) - indexWidth
        guard force || available != stretchedForWidth else { return }
        stretchedForWidth = available
        let total = measuredWidths.reduce(0, +)
        guard total > 0, available > total else {
            columnWidths = measuredWidths
            return
        }
        let factor = available / total
        columnWidths = measuredWidths.map { ($0 * factor).rounded(.down) }
    }

    override func prepare() {
        super.prepare()
        stretch(force: false)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(
            width: columnOffsets.last ?? indexWidth,
            height: headerHeight + CGFloat(rowCount) * rowHeight
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    // MARK: - Geometria

    /// Índice da linha de dados (0-based) e da coluna de dados (0-based) de um item.
    func position(of item: Int) -> (row: Int, col: Int) {
        (item / stride - 1, item % stride - 1)
    }

    func item(row: Int, col: Int) -> Int {
        (row + 1) * stride + (col + 1)
    }

    /// Primeira coluna cujo fim passa de `x` (busca binária nos prefixos).
    private func firstColumn(atOrAfter x: CGFloat) -> Int {
        var low = 0
        var high = columnCount - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let mid = (low + high) / 2
            if columnOffsets[mid + 1] <= x { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func attributes(row: Int, col: Int, offset: CGPoint) -> UICollectionViewLayoutAttributes {
        let indexPath = IndexPath(item: item(row: row, col: col), section: 0)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let isHeader = row < 0
        let isIndex = col < 0

        let x: CGFloat = isIndex ? max(0, offset.x) : columnOffsets[col]
        let width: CGFloat = isIndex ? indexWidth : columnWidths[col]
        let y: CGFloat = isHeader ? max(0, offset.y) : headerHeight + CGFloat(row) * rowHeight
        let height: CGFloat = isHeader ? headerHeight : rowHeight

        attributes.frame = CGRect(x: x, y: y, width: width, height: height)
        // Canto > cabeçalho > numeração > células: o que está pinado cobre o que rola.
        attributes.zIndex = isHeader && isIndex ? 30 : isHeader ? 20 : isIndex ? 10 : 0
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard columnCount > 0, let collectionView else { return [] }
        let offset = collectionView.contentOffset

        let firstRow = max(0, Int((rect.minY - headerHeight) / rowHeight))
        let lastRow = min(rowCount - 1, Int((rect.maxY - headerHeight) / rowHeight))
        let firstCol = firstColumn(atOrAfter: rect.minX)
        let lastCol = min(columnCount - 1, firstColumn(atOrAfter: rect.maxX))

        var result: [UICollectionViewLayoutAttributes] = []
        let visibleRows = max(0, lastRow - firstRow + 1)
        result.reserveCapacity((visibleRows + 1) * (lastCol - firstCol + 2))

        if rowCount > 0, firstRow <= lastRow {
            for row in firstRow...lastRow {
                result.append(attributes(row: row, col: -1, offset: offset))
                for col in firstCol...lastCol {
                    result.append(attributes(row: row, col: col, offset: offset))
                }
            }
        }
        result.append(attributes(row: -1, col: -1, offset: offset))
        for col in firstCol...lastCol {
            result.append(attributes(row: -1, col: col, offset: offset))
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard columnCount > 0 else { return nil }
        let (row, col) = position(of: indexPath.item)
        guard row < rowCount, col < columnCount else { return nil }
        return attributes(row: row, col: col, offset: collectionView?.contentOffset ?? .zero)
    }

    /// Frame da célula sem o deslocamento dos pinados — para rolar até ela.
    func unpinnedFrame(row: Int, col: Int) -> CGRect {
        CGRect(
            x: col < 0 ? 0 : columnOffsets[col],
            y: headerHeight + CGFloat(row) * rowHeight,
            width: col < 0 ? indexWidth : columnWidths[col],
            height: rowHeight
        )
    }
}
