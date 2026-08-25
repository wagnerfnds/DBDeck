import AppKit

/// Gutter com números de linha e realce da linha do cursor.
///
/// Uma linha numerada é um parágrafo (até `\n`): as continuações de uma linha longa
/// quebrada pela largura não ganham número, como no Xcode.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// Posição (UTF-16) do início de cada parágrafo. Recomputado a cada mudança de texto —
    /// contar `\n` é uma varredura linear barata, e é o que permite achar o número de uma
    /// linha por busca binária em vez de recontar do começo a cada redesenho.
    private var lineStarts: [Int] = [0]
    private var digits = 2

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        invalidateLineStarts()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) não é suportado") }

    override var isFlipped: Bool { true }

    /// Chamado pelo Coordinator quando o texto muda.
    func invalidateLineStarts() {
        guard let textView else { return }
        let text = textView.string as NSString
        var starts = [0]
        var searchRange = NSRange(location: 0, length: text.length)
        while true {
            let newline = text.range(of: "\n", options: [], range: searchRange)
            guard newline.location != NSNotFound else { break }
            starts.append(newline.location + 1)
            searchRange = NSRange(location: newline.location + 1, length: text.length - newline.location - 1)
        }
        lineStarts = starts
        let needed = max(2, String(starts.count).count)
        if needed != digits {
            digits = needed
            updateThickness()
        }
        needsDisplay = true
    }

    private var font: NSFont {
        Theme.codeFont(size: max(9, (textView?.font?.pointSize ?? 13) - 2))
    }

    private func updateThickness() {
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = ceil(width) + 16
    }

    /// Número da linha (a partir de 1) que contém a posição.
    private func lineNumber(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fundo próprio: o `NSRulerView` pinta um cinza opaco que destoa do editor
        // transparente.
        NSColor(Theme.headerBackground).setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        // Origem do texto em coordenadas do gutter: os dois rolam juntos.
        let origin = convert(NSPoint.zero, from: textView)
        let insetY = textView.textContainerInset.height
        let font = self.font
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? font)
        let cursorLine = lineNumber(at: textView.selectedRange().location)

        func drawNumber(_ number: Int, at y: CGFloat, height: CGFloat) {
            let isCursorLine = number == cursorLine
            if isCursorLine {
                Theme.currentLineBackground.setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: height).fill()
            }
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCursorLine ? Theme.gutterCurrentLineText : Theme.gutterText,
            ]
            let size = label.size(withAttributes: attributes)
            let point = NSPoint(x: ruleThickness - size.width - 8, y: y + (height - size.height) / 2)
            label.draw(at: point, withAttributes: attributes)
        }

        if text.length == 0 {
            drawNumber(1, at: origin.y + insetY, height: lineHeight)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphRange, actualGlyphRange: nil)
            let number = self.lineNumber(at: characterRange.location)
            // Só o PRIMEIRO fragmento de um parágrafo leva número.
            guard self.lineStarts[number - 1] == characterRange.location else { return }
            drawNumber(number, at: usedRect.minY + origin.y + insetY, height: usedRect.height)
        }

        // Texto terminando em `\n`: a linha vazia final não tem fragmento, mas existe.
        if text.hasSuffix("\n") {
            let number = lineStarts.count
            let extra = layoutManager.extraLineFragmentRect
            drawNumber(number, at: extra.minY + origin.y + insetY, height: max(extra.height, lineHeight))
        }
    }
}
