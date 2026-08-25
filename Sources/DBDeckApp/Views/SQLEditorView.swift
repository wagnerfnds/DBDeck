import SwiftUI
import AppKit
import DBDeckCore

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
    @ObservationIgnored weak var textView: SQLTextView?

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

    /// Fecha a lista de sugestões (o console chama ao executar).
    func dismissCompletions() {
        textView?.dismissCompletions(suppress: false)
    }
}

/// Editor de SQL: `SQLTextView` (teclado, autocomplete, indentação) dentro de um scroll
/// view com gutter de números de linha. Sem dependências.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var placeholder: String?
    /// Compartilhado com o console: de lá saem "executar seleção" e "executar o
    /// comando sob o cursor".
    var selection: EditorSelectionState?
    /// Sugestões para o texto e cursor dados. Síncrono: o que ainda não está em memória
    /// fica para a tecla seguinte.
    var completions: ((String, Int) -> [SQLSuggestion])?
    /// Avisa que o texto mudou, para quem fornece as sugestões ir buscando em background
    /// o que vai faltar (as colunas das tabelas recém-citadas).
    var prepareCompletions: ((String, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView.make(fontSize: fontSize)
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.completionProvider = completions
        textView.prepareCompletions = prepareCompletions

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        selection?.textView = textView
        textView.string = text
        context.coordinator.highlight()
        ruler.invalidateLineStarts()
        context.coordinator.refreshDecorations()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.completionProvider = completions
        textView.prepareCompletions = prepareCompletions
        textView.placeholder = placeholder
        // Mudança vinda de fora (biblioteca, histórico): substitui preservando o cursor
        // no que der; a checagem evita re-highlight e loop de eco a cada tecla.
        if textView.string != text {
            textView.dismissCompletions(suppress: false)
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
            context.coordinator.ruler?.invalidateLineStarts()
            context.coordinator.refreshDecorations()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        weak var ruler: LineNumberRulerView?
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
            ruler?.invalidateLineStarts()
            refreshDecorations()
            // O placeholder só existe com o texto vazio; sem isto ele fica pintado por
            // baixo do primeiro caractere até o próximo redesenho.
            textView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            parent.selection?.update(textView.selectedRange())
            refreshDecorations()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            SQLSyntaxHighlighter.highlight(storage, fontSize: parent.fontSize)
        }

        /// Realce do comando sob o cursor + linha atual no gutter.
        func refreshDecorations() {
            textView?.refreshStatementHighlight()
            ruler?.needsDisplay = true
        }
    }
}
