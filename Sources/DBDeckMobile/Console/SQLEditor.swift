import SwiftUI
import UIKit
import DBDeckCore

/// Ponte entre o console (SwiftUI) e o editor UIKit: seleção atual e ações que mexem no
/// texto (formatar, selecionar o comando que falhou, inserir).
@MainActor
final class SQLEditorController {
    fileprivate weak var textView: SQLTextView?

    var selectedRange: NSRange { textView?.selectedRange ?? NSRange(location: 0, length: 0) }
    var hasSelection: Bool { selectedRange.length > 0 }

    func select(_ range: NSRange) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= length else { return }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    func format(options: SQLFormatter.Options) {
        textView?.formatSQL(options: options)
    }

    func insert(_ text: String) {
        textView?.insertText(text)
    }

    func focus() { textView?.becomeFirstResponder() }
    func dismissKeyboard() { textView?.resignFirstResponder() }
}

struct SQLEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var indentUnit: String
    var autoCompletion: Bool
    var controller: SQLEditorController
    var completions: (_ text: String, _ cursor: Int) -> [SQLSuggestion]
    var prepareCompletions: (_ text: String, _ cursor: Int) -> Void
    var onRun: () -> Void
    var onSelectionChange: (_ hasSelection: Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> SQLTextView {
        let view = SQLTextView()
        view.delegate = context.coordinator
        view.text = text
        view.fontSize = fontSize
        view.indentUnit = indentUnit
        view.highlight()
        let bar = KeyboardBar()
        bar.onKey = { [weak view] key in view?.handleBarKey(key) }
        bar.onSuggestion = { [weak view, weak coordinator = context.coordinator] suggestion in
            view?.accept(suggestion)
            coordinator?.refreshSuggestions()
        }
        bar.onRun = { [weak coordinator = context.coordinator] in coordinator?.parent.onRun() }
        bar.onDismiss = { [weak view] in view?.resignFirstResponder() }
        view.inputAccessoryView = bar
        context.coordinator.bar = bar
        controller.textView = view
        return view
    }

    func updateUIView(_ view: SQLTextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        if view.fontSize != fontSize {
            view.fontSize = fontSize
            view.highlight()
        }
        view.indentUnit = indentUnit
        // Só sobrescreve quando o texto veio de fora (biblioteca, histórico): reatribuir
        // a cada atualização perderia cursor, undo e composição de acentos.
        if view.text != text, !view.hasMarkedTextInput {
            view.text = text
            view.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SQLEditor
        weak var bar: KeyboardBar?
        private var highlightWork: DispatchWorkItem?

        init(parent: SQLEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? SQLTextView else { return }
            parent.text = view.text
            // Até alguns KB o passe completo é imperceptível; um script colado de MBs
            // espera a digitação parar para não travar cada tecla.
            highlightWork?.cancel()
            if (view.text as NSString).length < 20_000 {
                view.highlight()
            } else {
                let work = DispatchWorkItem { [weak view] in view?.highlight() }
                highlightWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
            let cursor = view.selectedRange.location
            parent.prepareCompletions(view.text, cursor)
            refreshSuggestions()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.onSelectionChange(textView.selectedRange.length > 0)
            refreshSuggestions()
        }

        func refreshSuggestions() {
            guard let textView = parent.controller.textView,
                  parent.autoCompletion,
                  textView.isFirstResponder,
                  textView.selectedRange.length == 0,
                  !textView.hasMarkedTextInput else {
                bar?.setSuggestions([])
                return
            }
            let text = textView.text ?? ""
            let cursor = textView.selectedRange.location
            switch SQLCompletion.trigger(in: text, cursor: cursor) {
            case .none:
                bar?.setSuggestions([])
            case .identifier, .afterDot:
                let partial = SQLCompletion.partialWordRange(in: text, cursor: cursor)
                let typed = (text as NSString).substring(with: partial)
                let list = parent.completions(text, cursor)
                    .filter { $0.text.caseInsensitiveCompare(typed) != .orderedSame || $0.kind != .keyword }
                bar?.setSuggestions(Array(list.prefix(16)))
            }
        }
    }
}

// MARK: - Text view

final class SQLTextView: UITextView {
    var fontSize: CGFloat = 15
    var indentUnit = "    "

    var hasMarkedTextInput: Bool { markedTextRange != nil }

    init() {
        super.init(frame: .zero, textContainer: nil)
        // Nada de "ajuda" de digitação: aspas curvas e travessões quebram SQL em
        // silêncio, e o corretor trocaria nomes de tabela por palavras do dicionário.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        dataDetectorTypes = []
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        isFindInteractionEnabled = true
        accessibilityLabel = "Editor SQL"
        // As cores do realce são dinâmicas, mas ficam gravadas resolvidas no texto.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SQLTextView, _) in
            view.highlight()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func highlight() {
        let selection = selectedRange
        SQLSyntaxHighlighter.highlight(textStorage, fontSize: fontSize)
        typingAttributes = [
            .font: SQLSyntaxHighlighter.font(size: fontSize),
            .foregroundColor: UIColor.label,
        ]
        if selectedRange != selection { selectedRange = selection }
    }


    // MARK: Teclado de hardware (iPad)

    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(insertIndent))
        tab.wantsPriorityOverSystemBehavior = true
        return [tab]
    }

    @objc private func insertIndent() { insertText(indentUnit) }

    // MARK: Edição

    /// Enter mantém a indentação da linha atual — é o que deixa escrever um SELECT
    /// de várias linhas sem brigar com o teclado.
    override func insertText(_ text: String) {
        guard text == "\n", !hasMarkedTextInput else {
            super.insertText(text)
            return
        }
        let string = self.text as NSString
        let cursor = selectedRange.location
        let lineStart = string.lineRange(for: NSRange(location: min(cursor, string.length), length: 0)).location
        var indentEnd = lineStart
        while indentEnd < cursor, indentEnd < string.length {
            let character = string.character(at: indentEnd)
            guard character == 32 || character == 9 else { break }
            indentEnd += 1
        }
        let indent = string.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        super.insertText("\n" + indent)
    }

    func handleBarKey(_ key: KeyboardBar.Key) {
        UIDevice.current.playInputClick()
        switch key {
        case .text(let value):
            insertText(value)
        case .pair(let open, let close):
            // Com seleção, envolve; sem, insere o par e deixa o cursor no meio.
            let selection = selectedRange
            if selection.length > 0, let range = selectedTextRange {
                let inner = (text as NSString).substring(with: selection)
                replace(range, withText: open + inner + close)
            } else {
                insertText(open + close)
                if let position = position(from: selectedTextRange?.start ?? beginningOfDocument, offset: -close.count) {
                    selectedTextRange = textRange(from: position, to: position)
                }
            }
        case .indent:
            insertText(indentUnit)
        case .left, .right:
            let offset = key == .left ? -1 : 1
            if let start = selectedTextRange?.start, let next = position(from: start, offset: offset) {
                selectedTextRange = textRange(from: next, to: next)
            }
        }
    }

    func accept(_ suggestion: SQLSuggestion) {
        let cursor = selectedRange.location
        let partial = SQLCompletion.partialWordRange(in: text, cursor: cursor)
        guard let start = position(from: beginningOfDocument, offset: partial.location),
              let end = position(from: start, offset: partial.length),
              let range = textRange(from: start, to: end) else { return }
        let trailing: String
        switch suggestion.kind {
        case .keyword, .table: trailing = " "
        case .column, .alias: trailing = ""
        }
        replace(range, withText: suggestion.text + trailing)
    }

    func formatSQL(options: SQLFormatter.Options) {
        let selection = selectedRange
        let source = text as NSString
        let target = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        let formatted = SQLFormatter.format(source.substring(with: target), options: options)
        guard formatted != source.substring(with: target),
              let start = position(from: beginningOfDocument, offset: target.location),
              let end = position(from: start, offset: target.length),
              let range = textRange(from: start, to: end) else { return }
        // `replace` (e não `text =`) mantém uma entrada de undo e dispara o delegate.
        replace(range, withText: formatted)
    }
}

// MARK: - Barra do teclado

/// Barra sobre o teclado: sugestões de autocomplete quando há o que completar, senão
/// as teclas que o teclado do iOS esconde atrás de duas camadas (`* ( ) ' = ; .`).
/// À direita, fixos: executar e baixar o teclado.
final class KeyboardBar: UIInputView {
    enum Key: Equatable {
        case text(String)
        case pair(String, String)
        case indent
        case left, right
    }

    var onKey: ((Key) -> Void)?
    var onSuggestion: ((SQLSuggestion) -> Void)?
    var onRun: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var suggestions: [SQLSuggestion] = []
    private var showingSuggestions = false

    private static let quickKeys: [(String, Key)] = [
        ("⇥", .indent), ("◀︎", .left), ("▶︎", .right),
        ("*", .text("*")), (",", .text(", ")), ("( )", .pair("(", ")")), ("' '", .pair("'", "'")),
        ("=", .text(" = ")), (";", .text(";")), (".", .text(".")), ("_", .text("_")),
        ("<", .text(" < ")), (">", .text(" > ")), ("%", .text("%")), ("\"", .pair("\"", "\"")),
    ]
    private static let keywordKeys = ["SELECT", "FROM", "WHERE", "AND", "JOIN", "ON", "ORDER BY", "GROUP BY", "LIMIT", "COUNT(*)", "INSERT INTO", "UPDATE", "SET", "DELETE FROM"]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleHeight]

        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let run = UIButton(configuration: .filled())
        run.configuration?.image = UIImage(systemName: "play.fill")
        run.configuration?.cornerStyle = .capsule
        run.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        run.accessibilityLabel = "Executar"
        run.addAction(UIAction { [weak self] _ in self?.onRun?() }, for: .touchUpInside)

        let dismiss = UIButton(configuration: .plain())
        dismiss.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
        dismiss.accessibilityLabel = "Ocultar teclado"
        dismiss.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        let trailing = UIStackView(arrangedSubviews: [dismiss, run])
        trailing.spacing = 2
        trailing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -4),
            trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSuggestions(_ list: [SQLSuggestion]) {
        guard list != suggestions || showingSuggestions != !list.isEmpty else { return }
        suggestions = list
        showingSuggestions = !list.isEmpty
        rebuild()
        scroll.setContentOffset(.zero, animated: false)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if showingSuggestions {
            for suggestion in suggestions {
                stack.addArrangedSubview(suggestionButton(suggestion))
            }
        } else {
            for (title, key) in Self.quickKeys {
                stack.addArrangedSubview(keyButton(title: title, monospaced: true) { [weak self] in self?.onKey?(key) })
            }
            for keyword in Self.keywordKeys {
                stack.addArrangedSubview(keyButton(title: keyword, monospaced: false) { [weak self] in
                    self?.onKey?(.text(keyword + " "))
                })
            }
        }
    }

    private func keyButton(title: String, monospaced: Bool, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: monospaced ? 12 : 10, bottom: 6, trailing: monospaced ? 12 : 10)
        var attributed = AttributedString(title)
        attributed.font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: 16, weight: .medium)
            : UIFont.systemFont(ofSize: 13, weight: .semibold)
        config.attributedTitle = attributed
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func suggestionButton(_ suggestion: SQLSuggestion) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        var title = AttributedString(suggestion.text)
        title.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        config.attributedTitle = title
        if let detail = suggestion.detail {
            var subtitle = AttributedString(detail)
            subtitle.font = UIFont.systemFont(ofSize: 10)
            config.attributedSubtitle = subtitle
            config.titleAlignment = .leading
        }
        let symbol: String
        switch suggestion.kind {
        case .keyword:
            symbol = "textformat"
            config.baseForegroundColor = .systemPurple
            config.baseBackgroundColor = .systemPurple
        case .table:
            symbol = "tablecells"
            config.baseForegroundColor = .systemBlue
            config.baseBackgroundColor = .systemBlue
        case .column:
            symbol = "line.3.horizontal"
            config.baseForegroundColor = .systemTeal
            config.baseBackgroundColor = .systemTeal
        case .alias:
            symbol = "at"
            config.baseForegroundColor = .systemOrange
            config.baseBackgroundColor = .systemOrange
        }
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePadding = 5
        let button = UIButton(configuration: config)
        button.accessibilityLabel = "Completar \(suggestion.text)"
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onSuggestion?(suggestion)
        }, for: .touchUpInside)
        return button
    }
}

extension KeyboardBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
