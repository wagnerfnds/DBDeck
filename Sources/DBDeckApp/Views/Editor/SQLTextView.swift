import AppKit
import DBDeckCore

/// O `NSTextView` do editor SQL: autocomplete próprio, indentação, fechamento de pares,
/// placeholder e realce do comando sob o cursor.
///
/// O autocomplete NÃO usa o `complete(_:)` nativo. Aquele mecanismo é o F5 do TextEdit:
/// insere prévias com o sufixo selecionado, toma o teclado enquanto a lista está aberta e
/// a fecha por caminhos que não avisam ninguém — foi a fonte de "apagar buga". Aqui a
/// text view decide o que cada tecla faz e o popup só desenha.
@MainActor
final class SQLTextView: NSTextView {
    static let indentUnit = "    "

    let completionPopup = CompletionPopup()
    /// Sugestões para (texto, cursor). Síncrono e em memória: o que ainda não chegou do
    /// banco simplesmente não aparece nesta tecla.
    var completionProvider: ((String, Int) -> [SQLSuggestion])?
    /// Avisa que uma tabela foi citada, para quem fornece as sugestões ir buscar as
    /// colunas em background.
    var prepareCompletions: ((String, Int) -> Void)?
    var placeholder: String? {
        didSet { needsDisplay = true }
    }

    /// Faixa que o popup está completando. nil = fechado.
    private var completionRange: NSRange?
    /// Depois de aceitar ou fechar com Esc, só nova DIGITAÇÃO reabre — Backspace e setas
    /// nunca abrem a lista sozinhos.
    private var suppressUntilNextInsert = false
    /// A inserção da sugestão passa por `insertText`; sem isto ela mesma reabriria a lista.
    private var isAcceptingCompletion = false
    /// Faixa com o fundo de "comando sob o cursor". nil = nenhum.
    private var highlightedStatement: NSRange?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Construção

    /// Monta a pilha TextKit 1 explicitamente. Um `NSTextView()` cru sobe em TextKit 2, e
    /// o primeiro acesso a `layoutManager` (gutter, atributos temporários) faz o AppKit
    /// rebaixar para TextKit 1 em silêncio, com aviso no console — melhor ser explícito.
    static func make(fontSize: CGFloat) -> SQLTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = SQLTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = Theme.codeFont(size: fontSize)
        view.typingAttributes = [
            .font: Theme.codeFont(size: fontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true

        view.completionPopup.onAccept = { [weak view] in view?.acceptCompletion() }
        return view
    }

    // MARK: - Ciclo de vida

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        guard let window else {
            // Aba fechada com a lista aberta: sem isto a child window fica órfã.
            dismissCompletions(suppress: false)
            return
        }
        let center = NotificationCenter.default
        // Rolar ou redimensionar desloca a palavra sob a lista: fecha em vez de perseguir
        // (é o que o Xcode faz ao rolar com o trackpad).
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissCompletions(suppress: false) }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissCompletions(suppress: false) }
            })
        }
    }

    override func resignFirstResponder() -> Bool {
        dismissCompletions(suppress: false)
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        dismissCompletions(suppress: false)
        super.mouseDown(with: event)
    }

    // MARK: - Teclado

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Com ⌘ nada é nosso: ⌘⏎/⌘⇧⏎/⌘. do console já passaram por performKeyEquivalent.
        // Com texto marcado (IME de acento/ideograma) o sistema é dono das teclas.
        if flags.contains(.command) || hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        // ⌃Space: abrir a lista à mão, inclusive depois de espaço (mostra tudo).
        if event.keyCode == 49, flags.contains(.control) {
            showCompletions(manual: true)
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘] ⌘[ ⌘/ são do editor, não do menu: tratados aqui e consumidos. Qualquer outro
    /// atalho segue para a cadeia (é assim que o ⌘⏎ do console chega ao SwiftUI).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "]": indentSelection(); return true
            case "[": outdentSelection(); return true
            case "/": toggleComment(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if completionPopup.isVisible, !hasMarkedText() {
            switch selector {
            case #selector(moveUp(_:)):
                completionPopup.moveSelection(by: -1)
            case #selector(moveDown(_:)):
                completionPopup.moveSelection(by: 1)
            case #selector(pageUp(_:)), #selector(scrollPageUp(_:)):
                completionPopup.moveSelection(by: -8)
            case #selector(pageDown(_:)), #selector(scrollPageDown(_:)):
                completionPopup.moveSelection(by: 8)
            case #selector(insertNewline(_:)), #selector(insertTab(_:)), #selector(insertLineBreak(_:)):
                // ⏎ com a lista aberta aceita — e NÃO vira quebra de linha, porque o
                // `super` não é chamado.
                acceptCompletion()
            case #selector(cancelOperation(_:)):
                dismissCompletions(suppress: true)
            case #selector(moveLeft(_:)), #selector(moveRight(_:)),
                 #selector(moveWordLeft(_:)), #selector(moveWordRight(_:)),
                 #selector(moveToBeginningOfLine(_:)), #selector(moveToEndOfLine(_:)),
                 #selector(moveToLeftEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
                super.doCommand(by: selector)
                refreshCompletions(fromTyping: false)
            case #selector(deleteBackward(_:)), #selector(deleteWordBackward(_:)), #selector(deleteForward(_:)):
                super.doCommand(by: selector)
                refreshCompletions(fromTyping: false)
            default:
                dismissCompletions(suppress: false)
                super.doCommand(by: selector)
            }
            return
        }

        switch selector {
        case #selector(insertNewline(_:)):
            insertNewlineKeepingIndent()
        case #selector(insertTab(_:)):
            if selectionSpansMultipleLines() { indentSelection() } else { insertText(Self.indentUnit, replacementRange: selectedRange()) }
        case #selector(insertBacktab(_:)):
            outdentSelection()
        case #selector(deleteBackward(_:)):
            if !deleteEmptyPair() { super.doCommand(by: selector) }
        default:
            super.doCommand(by: selector)
        }
    }

    /// ⌥Esc / F5 nativos: em vez da lista do TextEdit, a nossa.
    override func complete(_ sender: Any?) {
        showCompletions(manual: true)
    }

    // MARK: - Inserção de texto

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // Só digitação de um caractere, sem seleção e fora do IME entra no fechamento de
        // pares; o resto (colar, texto vindo do IME, inserções nossas) passa direto.
        if !isAcceptingCompletion, !hasMarkedText(), replacementRange.location == NSNotFound,
           selectedRange().length == 0, typed.utf16.count == 1, let character = typed.first {
            if isClosingCharacter(character), nextCharacter() == character {
                // "Overtype": o fechamento já está ali (foi inserido automaticamente).
                setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
                afterTyping()
                return
            }
            if let closing = closingPair(for: character), shouldAutoClose(character) {
                super.insertText(String(character) + String(closing), replacementRange: replacementRange)
                setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
                afterTyping()
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        if !isAcceptingCompletion { afterTyping() }
    }

    private func afterTyping() {
        suppressUntilNextInsert = false
        refreshCompletions(fromTyping: true)
    }

    // MARK: - Autocomplete

    func showCompletions(manual: Bool) {
        suppressUntilNextInsert = false
        refreshCompletions(fromTyping: true, force: manual)
    }

    /// Reavalia a lista depois de cada tecla: abre (só vindo de digitação), refiltra ou
    /// fecha. `force` ignora o gatilho — é o ⌃Space depois de um espaço.
    private func refreshCompletions(fromTyping: Bool, force: Bool = false) {
        guard let provider = completionProvider, !hasMarkedText(), let window else {
            dismissCompletions(suppress: false)
            return
        }
        let cursor = selectedRange()
        guard cursor.length == 0 else {
            dismissCompletions(suppress: false)
            return
        }
        let trigger = SQLCompletion.trigger(in: string, cursor: cursor.location)
        guard trigger != .none || force else {
            dismissCompletions(suppress: false)
            return
        }
        let wasVisible = completionPopup.isVisible
        // Backspace e setas nunca ABREM a lista: só ajustam uma que já está aberta.
        guard wasVisible || fromTyping else { return }
        guard !suppressUntilNextInsert || force else { return }
        // Cursor saiu para a esquerda da palavra que estava sendo completada: acabou.
        if wasVisible, let range = completionRange, cursor.location < range.location {
            dismissCompletions(suppress: false)
            return
        }

        prepareCompletions?(string, cursor.location)
        let items = provider(string, cursor.location)
        guard !items.isEmpty else {
            dismissCompletions(suppress: false)
            return
        }

        let partial = SQLCompletion.partialWordRange(in: string, cursor: cursor.location)
        completionRange = partial
        let prefix = (string as NSString).substring(with: partial)
        // Faixa vazia (logo depois do `.`): o AppKit devolve o retângulo do caret.
        let anchorRange = partial.length > 0 ? partial : NSRange(location: cursor.location, length: 0)
        let anchor = firstRect(forCharacterRange: anchorRange, actualRange: nil)

        if wasVisible {
            completionPopup.update(items: items, prefix: prefix, anchoredTo: anchor)
        } else {
            completionPopup.show(items: items, prefix: prefix, anchoredTo: anchor, parent: window, font: font ?? Theme.codeFont(size: 13))
        }
    }

    func acceptCompletion() {
        guard let item = completionPopup.selectedItem else {
            dismissCompletions(suppress: false)
            return
        }
        // Recomputada na hora: a faixa guardada pode ter envelhecido com a digitação.
        let cursor = selectedRange().location
        let range = SQLCompletion.partialWordRange(in: string, cursor: cursor)
        dismissCompletions(suppress: false)

        var text = item.text
        // Depois de tabela ou palavra-chave quase sempre vem espaço; depois de coluna vem
        // vírgula, `=` ou `.` — aí o espaço só atrapalharia.
        if item.kind == .table || item.kind == .keyword, needsTrailingSpace(after: NSMaxRange(range)) {
            text += " "
        }
        isAcceptingCompletion = true
        // `insertText` (nunca `string =`): uma entrada de undo e o `textDidChange` do
        // delegate sobe o texto ao binding.
        insertText(text, replacementRange: range)
        isAcceptingCompletion = false
        suppressUntilNextInsert = true
    }

    func dismissCompletions(suppress: Bool) {
        completionPopup.hide()
        completionRange = nil
        if suppress { suppressUntilNextInsert = true }
    }

    private func needsTrailingSpace(after position: Int) -> Bool {
        let text = string as NSString
        guard position < text.length else { return true }
        let next = text.character(at: position)
        return next != 0x20 && next != 0x0A && next != 0x2E && next != 0x29 && next != 0x2C
    }

    // MARK: - Pares

    private func closingPair(for character: Character) -> Character? {
        switch character {
        case "(": ")"
        case "'": "'"
        case "\"": "\""
        default: nil
        }
    }

    private func isClosingCharacter(_ character: Character) -> Bool {
        character == ")" || character == "'" || character == "\""
    }

    private func nextCharacter() -> Character? {
        let text = string as NSString
        let position = selectedRange().location
        guard position < text.length, let scalar = Unicode.Scalar(text.character(at: position)) else { return nil }
        return Character(scalar)
    }

    private func previousCharacter() -> Character? {
        let text = string as NSString
        let position = selectedRange().location
        guard position > 0, let scalar = Unicode.Scalar(text.character(at: position - 1)) else { return nil }
        return Character(scalar)
    }

    /// Fecha o par só onde o fechamento não atrapalha: antes de espaço, fim, `)` ou `,`.
    /// Aspa simples não fecha depois de letra (`don't`) nem dentro de string/comentário —
    /// ali a aspa digitada É o fechamento.
    private func shouldAutoClose(_ character: Character) -> Bool {
        if let next = nextCharacter(), !(next.isWhitespace || next == ")" || next == "," || next == ";") {
            return false
        }
        if character == "'" || character == "\"" {
            if let previous = previousCharacter(), previous.isLetter || previous.isNumber { return false }
            if SQLCompletion.trigger(in: string, cursor: selectedRange().location) == .none,
               previousCharacter().map({ !$0.isWhitespace && $0 != "(" && $0 != "," && $0 != "=" }) ?? false {
                return false
            }
        }
        return true
    }

    /// Backspace entre um par vazio (`()`, `''`) apaga os dois.
    private func deleteEmptyPair() -> Bool {
        guard selectedRange().length == 0, let previous = previousCharacter(),
              let closing = closingPair(for: previous), nextCharacter() == closing else { return false }
        let position = selectedRange().location
        insertText("", replacementRange: NSRange(location: position - 1, length: 2))
        return true
    }

    // MARK: - Indentação e comentário

    private func lineRange(for range: NSRange) -> NSRange {
        (string as NSString).lineRange(for: range)
    }

    private func selectionSpansMultipleLines() -> Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        return (string as NSString).substring(with: selection).contains("\n")
    }

    /// Enter mantém a indentação da linha; entre `(` e `)` abre um bloco indentado.
    private func insertNewlineKeepingIndent() {
        let text = string as NSString
        let selection = selectedRange()
        let line = text.substring(with: lineRange(for: NSRange(location: selection.location, length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if previousCharacter() == "(", nextCharacter() == ")" {
            let inner = "\n" + indent + Self.indentUnit
            insertText(inner + "\n" + indent, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + inner.utf16.count, length: 0))
        } else {
            insertText("\n" + indent, replacementRange: selection)
        }
    }

    /// Aplica `transform` a cada linha coberta pela seleção, numa única substituição (uma
    /// entrada de undo) e mantém as linhas selecionadas.
    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let text = string as NSString
        let selection = selectedRange()
        var lines = lineRange(for: selection)
        // `lineRange` inclui a quebra final; sem tirá-la a última "linha" seria vazia.
        var block = text.substring(with: lines)
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline {
            block.removeLast()
            lines.length -= 1
        }
        let transformed = transform(block.components(separatedBy: "\n")).joined(separator: "\n")
        guard transformed != block else { return }
        insertText(transformed, replacementRange: lines)
        setSelectedRange(NSRange(location: lines.location, length: transformed.utf16.count))
    }

    func indentSelection() {
        transformSelectedLines { lines in
            lines.map { $0.isEmpty ? $0 : Self.indentUnit + $0 }
        }
    }

    func outdentSelection() {
        transformSelectedLines { lines in
            lines.map { line in
                if line.hasPrefix(Self.indentUnit) { return String(line.dropFirst(Self.indentUnit.count)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.drop { $0 == " " })
            }
        }
    }

    /// Todas as linhas já comentadas → descomenta; senão comenta todas, na indentação.
    func toggleComment() {
        transformSelectedLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !content.isEmpty && content.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
            }
            return lines.map { line in
                let indentEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
                let indent = line[..<indentEnd]
                let body = line[indentEnd...]
                if allCommented {
                    guard body.hasPrefix("--") else { return line }
                    var rest = body.dropFirst(2)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    return String(indent) + String(rest)
                }
                guard !body.isEmpty else { return line }
                return String(indent) + "-- " + String(body)
            }
        }
    }

    // MARK: - Decorações

    /// Fundo sutil no comando sob o cursor — é o que o ⌘⇧⏎ vai executar. Atributo
    /// TEMPORÁRIO do layout manager, não do storage: não entra no undo nem no binding.
    /// Só quando há mais de um comando; com um só, pintar o editor inteiro é ruído.
    func refreshStatementHighlight() {
        guard let layoutManager else { return }
        let text = string as NSString
        var target: NSRange?
        if text.length <= 256_000 {
            let statements = SQLDump.statements(in: string)
            if statements.count > 1 {
                let cursor = selectedRange().location
                if let hit = statements.first(where: { $0.contains(cursor) }) {
                    target = NSRange(location: hit.location, length: hit.length)
                }
            }
        }
        guard target != highlightedStatement else { return }
        // Limpa o texto inteiro, não só a faixa antiga: depois de uma edição a faixa
        // guardada pode não corresponder mais ao que está pintado.
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        if let target, NSMaxRange(target) <= text.length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.statementBackground, forCharacterRange: target)
        }
        highlightedStatement = target
    }

    /// Placeholder desenhado pela própria view, no lugar exato onde o texto começa — o
    /// overlay SwiftUI de antes desalinhava sempre que o inset ou a fonte mudavam.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placeholder, string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.codeFont(size: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5),
            y: textContainerOrigin.y
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
