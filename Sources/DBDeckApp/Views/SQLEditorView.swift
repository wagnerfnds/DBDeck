import SwiftUI
import AppKit

/// Cursor e seleção do editor, para o console decidir O QUE executar.
///
/// Só `hasSelection` é observado: a faixa muda a cada tecla e a cada movimento do cursor,
/// e observá-la redesenharia o grid de resultados junto — num resultado de dezenas de
/// milhares de linhas isso é caro por seta apertada.
@MainActor
@Observable
final class EditorSelectionState {
    /// Muda só quando ALTERNA entre ter e não ter seleção, para o botão trocar de rótulo
    /// sem redesenhar o console a cada caractere selecionado.
    private(set) var hasSelection = false

    @ObservationIgnored private(set) var range = NSRange(location: 0, length: 0)
    /// O editor vivo, para o console conseguir destacar o comando que falhou. Fraca:
    /// a aba pode ser fechada com uma consulta ainda rodando.
    @ObservationIgnored weak var textView: NSTextView?

    func update(_ newRange: NSRange) {
        range = newRange
        let selecting = newRange.length > 0
        if selecting != hasSelection { hasSelection = selecting }
    }

    /// Texto selecionado, ou nil quando é só um cursor.
    var selectedText: String? {
        guard range.length > 0, let textView else { return nil }
        let full = textView.string as NSString
        guard NSMaxRange(range) <= full.length else { return nil }
        return full.substring(with: range)
    }

    /// Seleciona e rola até a faixa — é assim que o comando que falhou fica visível
    /// no meio de um script longo.
    func select(_ target: NSRange) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let location = min(target.location, length)
        let clamped = NSRange(location: location, length: min(target.length, length - location))
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        update(clamped)
    }
}

/// Editor de SQL com syntax highlight — NSTextView puro, sem dependências.
/// O highlight roda a cada mudança de texto; consultas de console têm poucos KB,
/// então um passe completo por tecla é imperceptível.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    /// Compartilhado com o console: de lá saem "executar seleção" e "executar o
    /// comando sob o cursor".
    var selection: EditorSelectionState?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = SQLSyntaxHighlighter.font(size: fontSize)
        textView.typingAttributes = [
            .font: SQLSyntaxHighlighter.font(size: fontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        context.coordinator.textView = textView
        selection?.textView = textView
        textView.string = text
        context.coordinator.highlight()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Mudança vinda de fora (biblioteca, histórico): substitui preservando o cursor
        // no que der; a checagem evita re-highlight e loop de eco a cada tecla.
        if textView.string != text {
            let previous = textView.selectedRange()
            // Trocar o texto dispara textViewDidChangeSelection no meio da atualização da
            // view; publicar dali mutaria estado observado durante o redesenho.
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            let clamped = min(previous.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            context.coordinator.isApplyingExternalText = false
            selection?.update(textView.selectedRange())
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: NSTextView?
        /// Ver `updateNSView`: silencia a publicação da seleção durante o redesenho.
        var isApplyingExternalText = false

        init(parent: SQLEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.selection?.update(textView.selectedRange())
            highlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            parent.selection?.update(textView.selectedRange())
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            SQLSyntaxHighlighter.highlight(storage, fontSize: parent.fontSize)
        }
    }
}

/// Highlight de SQL por regex — keywords, strings, números e comentários, nas cores
/// dinâmicas do sistema (acompanham claro/escuro).
enum SQLSyntaxHighlighter {
    static func font(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // Compiladas uma vez — o highlight roda por tecla.
    private static let keywordRegex: NSRegularExpression = {
        let keywords = [
            "select", "from", "where", "and", "or", "not", "in", "is", "null", "like",
            "insert", "into", "values", "update", "set", "delete", "create", "drop",
            "alter", "table", "index", "view", "database", "schema", "trigger",
            "join", "inner", "left", "right", "full", "outer", "cross", "on", "using",
            "group", "by", "having", "order", "asc", "desc", "limit", "offset",
            "union", "all", "distinct", "as", "case", "when", "then", "else", "end",
            "between", "exists", "any", "some", "cast", "convert", "with", "recursive",
            "primary", "foreign", "key", "references", "unique", "check", "default",
            "constraint", "add", "column", "modify", "change", "rename", "to",
            "begin", "commit", "rollback", "transaction", "truncate", "explain",
            "show", "describe", "use", "if", "ifnull", "coalesce", "count", "sum",
            "avg", "min", "max", "concat", "substring", "replace", "now", "curdate",
            "date", "year", "month", "day", "interval", "true", "false", "returning",
        ]
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let numberRegex = try! NSRegularExpression(
        pattern: "\\b\\d+(?:\\.\\d+)?\\b"
    )
    /// Aspas simples (com '' e \' escapados), aspas duplas e crases.
    private static let stringRegex = try! NSRegularExpression(
        pattern: "'(?:[^'\\\\]|\\\\.|'')*'|\"[^\"\\n]*\"|`[^`\\n]*`"
    )
    private static let commentRegex = try! NSRegularExpression(
        pattern: "--[^\\n]*|#[^\\n]*|/\\*.*?\\*/",
        options: [.dotMatchesLineSeparators]
    )

    static func highlight(_ storage: NSTextStorage, fontSize: CGFloat) {
        let range = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString

        storage.beginEditing()
        storage.setAttributes([
            .font: font(size: fontSize),
            .foregroundColor: NSColor.labelColor,
        ], range: range)

        // Ordem importa: o que vem depois vence — uma keyword dentro de string fica
        // com a cor de string, e tudo dentro de comentário fica cinza.
        apply(numberRegex, color: .systemBlue, in: text, range: range, storage: storage)
        apply(keywordRegex, color: .systemPurple, in: text, range: range, storage: storage)
        apply(stringRegex, color: .systemRed, in: text, range: range, storage: storage)
        apply(commentRegex, color: .secondaryLabelColor, in: text, range: range, storage: storage)
        storage.endEditing()
    }

    private static func apply(
        _ regex: NSRegularExpression,
        color: NSColor,
        in text: NSString,
        range: NSRange,
        storage: NSTextStorage
    ) {
        regex.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
