import AppKit
import DBDeckCore

/// Lista de sugestões do editor SQL.
///
/// É uma janela filha (NSPanel), não uma view dentro do editor: o editor é pequeno (120 pt
/// no mínimo, com o divisor arrastado) e uma lista de 8 linhas não cabe abaixo do cursor na
/// maioria dos casos — como view ela seria clipada pelo scroll view e pelo `clipShape` do
/// console. Como janela, flipa para cima quando falta espaço e ignora o layout do SwiftUI.
///
/// O painel NUNCA vira key window: o `NSTextView` continua first responder e recebe todas
/// as teclas; quem decide o que ↑/↓/⏎/Esc fazem é a text view. O painel só desenha e aceita
/// clique. Isso elimina a classe inteira de bugs de foco de um popup "de verdade".
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 22
    private static let maxRows = 8
    private static let iconColumnWidth: CGFloat = 26

    private let panel: Panel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var font = Theme.codeFont(size: 13)
    private var prefix = ""
    private weak var parentWindow: NSWindow?

    private(set) var items: [SQLSuggestion] = []

    /// Chamado no clique numa linha. A text view aceita a sugestão selecionada.
    var onAccept: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    var selectedItem: SQLSuggestion? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    /// Painel sem borda que recusa virar key — ver o comentário da classe.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        // Material de menu: o mesmo fundo translúcido das listas de completion do sistema.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        panel.contentView = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Mostrar / esconder

    /// `anchor` é o retângulo da palavra parcial EM COORDENADAS DE TELA (o que
    /// `firstRect(forCharacterRange:)` devolve). A lista abre abaixo dele; acima se não
    /// couber.
    func show(items: [SQLSuggestion], prefix: String, anchoredTo anchor: NSRect, parent: NSWindow, font: NSFont) {
        self.font = font
        self.prefix = prefix
        self.items = items
        tableView.reloadData()
        selectRow(0)

        if parentWindow !== parent {
            detach()
            parentWindow = parent
            parent.addChildWindow(panel, ordered: .above)
        }
        layout(anchoredTo: anchor)
        panel.orderFront(nil)
    }

    /// Refiltra e volta ao topo: cada tecla reordena a lista, e o melhor match está
    /// sempre na primeira linha — manter a seleção antiga deixava o destaque preso lá
    /// embaixo num item que já não era o melhor.
    func update(items: [SQLSuggestion], prefix: String, anchoredTo anchor: NSRect) {
        self.prefix = prefix
        self.items = items
        tableView.reloadData()
        selectRow(0)
        layout(anchoredTo: anchor)
    }

    func hide() {
        guard panel.isVisible || parentWindow != nil else { return }
        detach()
        panel.orderOut(nil)
        items = []
    }

    /// `removeChildWindow` ANTES de `orderOut`: uma child window órfã segue a janela mãe
    /// mesmo invisível e reaparece no próximo `orderFront`.
    private func detach() {
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
    }

    // MARK: - Seleção

    /// Sem wrap: ↓ no fim fica no fim — o comportamento das listas do sistema.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let target = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        selectRow(target)
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        selectRow(tableView.clickedRow)
        onAccept?()
    }

    // MARK: - Layout

    private func layout(anchoredTo anchor: NSRect) {
        let rows = min(items.count, Self.maxRows)
        let height = CGFloat(rows) * Self.rowHeight + 8
        let width = preferredWidth()

        let screen = parentWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Alinha o texto da sugestão com a palavra parcial, descontando a coluna do ícone.
        var x = anchor.minX - Self.iconColumnWidth - 4
        x = min(max(x, visible.minX), visible.maxX - width)

        var y = anchor.minY - height - 2
        if y < visible.minY {
            // Não cabe abaixo do cursor: abre acima.
            y = anchor.maxY + 2
        }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// Largura pela linha mais longa (texto + detalhe), entre 220 e 420 pt.
    private func preferredWidth() -> CGFloat {
        let detailFont = NSFont.systemFont(ofSize: 11)
        var widest: CGFloat = 0
        for item in items.prefix(40) {
            var width = (item.text as NSString).size(withAttributes: [.font: font]).width
            if let detail = item.detail {
                width += 16 + (detail as NSString).size(withAttributes: [.font: detailFont]).width
            }
            widest = max(widest, width)
        }
        return min(max(widest + Self.iconColumnWidth + 24, 220), 420)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCellView)
            ?? CompletionCellView(identifier: identifier)
        cell.configure(item: items[row], prefix: prefix, font: font)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // Sem a linha de seleção "emphasized" do sistema o destaque sai cinza; como o
        // painel nunca é key, forçamos o azul de accent.
        let view = EmphasizedRowView()
        return view
    }

    private final class EmphasizedRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }
    }
}

/// Uma linha: ícone da categoria, texto com os caracteres casados em negrito, detalhe à
/// direita (tipo da coluna, tabela do apelido).
@MainActor
private final class CompletionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, label, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A linha selecionada é criada JÁ em destaque no primeiro desenho da lista, e o
    /// ícone com tinta fixa cinza sumia no fundo azul até a seleção mudar e o AppKit
    /// redesenhar. As cores acompanham o estilo de fundo explicitamente.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private var lastText = ""
    private var lastPrefix = ""
    private var lastFont = Theme.codeFont(size: 13)

    func configure(item: SQLSuggestion, prefix: String, font: NSFont) {
        icon.image = NSImage(systemSymbolName: Self.symbol(for: item.kind), accessibilityDescription: nil)
        lastText = item.text
        lastPrefix = prefix
        lastFont = font
        detail.stringValue = item.detail ?? ""
        detail.isHidden = item.detail == nil
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        icon.contentTintColor = emphasized ? .white : .secondaryLabelColor
        detail.textColor = emphasized ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        label.attributedStringValue = Self.highlighted(
            lastText, prefix: lastPrefix, font: lastFont,
            color: emphasized ? .white : .labelColor
        )
    }

    private static func symbol(for kind: SQLSuggestion.Kind) -> String {
        switch kind {
        case .table: "tablecells"
        case .column: "rectangle.split.3x1"
        case .keyword: "k.square"
        case .alias: "at"
        }
    }

    /// Os caracteres que casaram com o que foi digitado vão em negrito — no prefixo são os
    /// primeiros; numa subsequência, espalhados.
    private static func highlighted(_ text: String, prefix: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let bold = Theme.codeFont(size: font.pointSize, weight: .semibold)
        for offset in SQLCompletion.matchedOffsets(in: text, prefix: prefix) where offset < result.length {
            result.addAttribute(.font, value: bold, range: NSRange(location: offset, length: 1))
        }
        return result
    }
}
