import UIKit
import DBDeckCore

/// Base das células do grid: linhas finas de grade à direita e embaixo, desenhadas
/// como camadas — sem subviews extras por célula e sem `draw(_:)`; o compositor pinta,
/// a CPU não. `CGColor` não acompanha claro/escuro sozinho, daí a re-resolução no
/// layout e na troca de aparência.
class GridLinedCell: UICollectionViewCell {
    private let right = CALayer()
    private let bottom = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for line in [right, bottom] {
            line.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            contentView.layer.addSublayer(line)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: GridLinedCell, _) in
            cell.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let scale = 1 / max(traitCollection.displayScale, 1)
        let color = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        right.backgroundColor = color
        bottom.backgroundColor = color
        right.frame = CGRect(x: bounds.maxX - scale, y: 0, width: scale, height: bounds.height)
        bottom.frame = CGRect(x: 0, y: bounds.maxY - scale, width: bounds.width, height: scale)
    }
}

/// Célula de dados: um `UILabel` de uma linha só.
final class GridDataCell: GridLinedCell {
    static let reuseID = "data"

    let label = UILabel()
    private let linkIcon = UIImageView(image: UIImage(systemName: "arrow.up.forward.circle.fill"))
    private var showsLink = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = false
        contentView.addSubview(label)
        linkIcon.tintColor = .tintColor
        linkIcon.contentMode = .scaleAspectFit
        linkIcon.isHidden = true
        contentView.addSubview(linkIcon)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let iconSize: CGFloat = showsLink ? 14 : 0
        label.frame = bounds.insetBy(dx: 8, dy: 0).inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: showsLink ? iconSize + 4 : 0))
        linkIcon.frame = CGRect(x: bounds.maxX - 8 - iconSize, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
    }

    func configure(
        value: SQLValue?,
        deferred: Bool,
        isLink: Bool,
        font: UIFont,
        italicFont: UIFont,
        background: UIColor,
        columnName: String
    ) {
        contentView.backgroundColor = background
        showsLink = isLink && value != nil && value != .null
        linkIcon.isHidden = !showsLink
        guard let value, !deferred else {
            label.text = "‹carregar›"
            label.font = italicFont
            label.textColor = .tertiaryLabel
            label.textAlignment = .left
            accessibilityLabel = "\(columnName): não carregado"
            setNeedsLayout()
            return
        }
        switch value {
        case .null:
            label.text = "NULL"
            label.font = italicFont
            label.textColor = .tertiaryLabel
            label.textAlignment = .left
        case .blob, .truncated(_, _, true):
            label.text = value.display
            label.font = italicFont
            label.textColor = .secondaryLabel
            label.textAlignment = .left
        case .bool(let flag):
            label.text = flag ? "true" : "false"
            label.font = font
            label.textColor = flag ? .systemGreen : .systemOrange
            label.textAlignment = .left
        default:
            // Quebras de linha viram espaço: a célula tem uma linha só, e um "\n" no
            // começo deixaria a célula aparentemente vazia.
            let text = value.cellDisplay
            label.text = text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ⏎ ") : text
            label.font = font
            label.textColor = isLink ? .tintColor : .label
            label.textAlignment = value.isNumeric ? .right : .left
        }
        accessibilityLabel = "\(columnName): \(value == .null ? "nulo" : value.display)"
        setNeedsLayout()
    }
}

/// Numeração das linhas (coluna pinada à esquerda).
final class GridIndexCell: GridLinedCell {
    static let reuseID = "index"

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabel
        contentView.addSubview(label)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        label.frame = bounds.insetBy(dx: 6, dy: 0)
    }

    func configure(number: Int, selected: Bool) {
        label.text = String(number)
        label.textColor = selected ? .tintColor : .tertiaryLabel
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        contentView.backgroundColor = selected ? UIColor.tintColor.withAlphaComponent(0.12) : .secondarySystemBackground
    }
}

/// Cabeçalho de coluna: nome, tipo e indicador de ordenação.
final class GridHeaderCell: GridLinedCell {
    static let reuseID = "header"

    private let name = UILabel()
    private let type = UILabel()
    private let sortIcon = UIImageView()
    private let keyIcon = UIImageView(image: UIImage(systemName: "key.fill"))
    private var hasKey = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        type.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        type.textColor = .tertiaryLabel
        type.lineBreakMode = .byTruncatingTail
        sortIcon.tintColor = .tintColor
        sortIcon.contentMode = .scaleAspectFit
        keyIcon.tintColor = .systemYellow
        keyIcon.contentMode = .scaleAspectFit
        [name, type, sortIcon, keyIcon].forEach(contentView.addSubview)
        isAccessibilityElement = true
        accessibilityTraits = [.header, .button]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let keyWidth: CGFloat = hasKey ? 12 : 0
        let sortWidth: CGFloat = sortIcon.image == nil ? 0 : 12
        let left: CGFloat = 8 + (hasKey ? keyWidth + 4 : 0)
        let available = bounds.width - left - 8 - (sortWidth > 0 ? sortWidth + 4 : 0)
        keyIcon.frame = CGRect(x: 8, y: 9, width: keyWidth, height: 12)
        name.frame = CGRect(x: left, y: 5, width: max(0, available), height: 20)
        type.frame = CGRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: 14)
        sortIcon.frame = CGRect(x: bounds.maxX - 8 - sortWidth, y: 9, width: sortWidth, height: 12)
    }

    func configure(column: GridColumn, sort: Bool?) {
        name.text = column.name
        type.text = column.type
        type.isHidden = column.type == nil
        hasKey = column.isPrimaryKey
        keyIcon.isHidden = !column.isPrimaryKey
        switch sort {
        case .some(true): sortIcon.image = UIImage(systemName: "chevron.up")
        case .some(false): sortIcon.image = UIImage(systemName: "chevron.down")
        case .none: sortIcon.image = nil
        }
        name.textColor = sort == nil ? .label : .tintColor
        accessibilityLabel = column.name
        accessibilityValue = sort.map { $0 ? "ordem crescente" : "ordem decrescente" }
        accessibilityHint = "Toque para ordenar"
        setNeedsLayout()
    }

    func configureCorner(rowCount: Int) {
        name.text = nil
        type.text = nil
        sortIcon.image = nil
        hasKey = false
        keyIcon.isHidden = true
        isAccessibilityElement = false
    }
}
