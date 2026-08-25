import SwiftUI
import AppKit
import DBDeckCore

/// NSTextView que delimita a palavra a completar pelas regras de identificador SQL.
///
/// O padrão do AppKit usa fronteiras de palavra de texto corrido: `criado_em` viraria
/// duas palavras e a sugestão substituiria só o pedaço depois do `_`.
final class SQLTextView: NSTextView {
    /// `true` enquanto a lista de sugestões está aberta. Enquanto ela está aberta é o
    /// AppKit que trata as teclas (filtra a lista, fecha no Esc/Enter); chamar
    /// `complete(nil)` de novo a cada tecla reabria a lista em cima dela mesma.
    private(set) var isCompletionActive = false
    /// `true` enquanto uma sugestão está sendo inserida — a mudança de texto/seleção
    /// que isso gera não é digitação do usuário.
    private(set) var isInsertingCompletion = false

    override var rangeForUserCompletion: NSRange {
        SQLCompletion.partialWordRange(in: string, cursor: selectedRange().location)
    }

    func beginCompletion() {
        isCompletionActive = true
        complete(nil)
    }

    /// Chamado pelo delegate quando não há mais sugestões: o AppKit fecha a lista sem
    /// avisar por `insertCompletion`, e sem isto a lista nunca mais abriria.
    func completionListEmptied() {
        isCompletionActive = false
    }

    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        // Só a escolha definitiva escreve no texto. O padrão do AppKit insere a sugestão
        // destacada como PRÉVIA, com o sufixo selecionado, a cada mudança de destaque —
        // isso deixava o editor com uma seleção fantasma (o botão virava "Executar
        // seleção" e o ⌘⏎ executava só o sufixo) e disparava o loop de reabertura.
        guard flag else { return }
        isInsertingCompletion = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        isInsertingCompletion = false
        isCompletionActive = false
    }
}

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
    /// Sugestões para o texto e cursor dados. Síncrono porque é o que o NSTextView
    /// exige — o que ainda não está em memória fica para a invocação seguinte.
    var completions: ((String, Int) -> [String])?
    /// Avisa que o texto mudou, para quem fornece as sugestões ir buscando em background
    /// o que vai faltar (as colunas das tabelas recém-citadas).
    var prepareCompletions: ((String, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView()
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
            offerCompletions()
        }

        /// Abre a lista sozinho enquanto se digita um identificador. Esperar pelo ⌥⎋ do
        /// AppKit faria o recurso não existir na prática — ninguém descobre o atalho.
        /// A partir de dois caracteres (ou logo depois de um ponto, onde só cabe coluna),
        /// para a lista não piscar a cada espaço digitado.
        private func offerCompletions() {
            guard parent.completions != nil,
                  let textView = textView as? SQLTextView,
                  !textView.isInsertingCompletion,
                  !textView.isCompletionActive else { return }
            let cursor = textView.selectedRange()
            guard cursor.length == 0, cursor.location > 0 else { return }

            let text = textView.string as NSString
            let afterDot = text.character(at: cursor.location - 1) == UInt16(UInt8(ascii: "."))
            let partial = SQLCompletion.partialWordRange(in: textView.string, cursor: cursor.location)
            guard afterDot || partial.length >= 2 else { return }

            // Depois do guarda: preparar varre o texto atrás dos FROM/JOIN, e fazer isso
            // a cada espaço digitado seria um passe pelo script inteiro por tecla.
            parent.prepareCompletions?(textView.string, cursor.location)
            textView.beginCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            if let sqlView = textView as? SQLTextView, sqlView.isInsertingCompletion { return }
            parent.selection?.update(textView.selectedRange())
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            // O NSTextView oferece a lista do corretor ortográfico em `words`: aqui ela
            // é descartada inteira — sugerir "select" como correção de "selct" não ajuda
            // quem está escrevendo SQL.
            index?.pointee = 0
            let words = parent.completions?(textView.string, NSMaxRange(charRange)) ?? []
            if words.isEmpty { (textView as? SQLTextView)?.completionListEmptied() }
            return words
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
