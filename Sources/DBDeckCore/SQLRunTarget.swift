import Foundation

/// Decide QUAIS comandos um gatilho do console executa.
///
/// Mora no core, e não na view, porque é a regra que define o comportamento do ⌘⏎ e do
/// ⌘⇧⏎ — o tipo de coisa que se quer cobrir por teste em vez de conferir clicando.
public enum SQLRunTarget {
    /// Comandos do gatilho "executar": a seleção quando há uma, senão o texto inteiro.
    ///
    /// As faixas devolvidas são sempre relativas ao TEXTO INTEIRO, mesmo quando saem de um
    /// recorte — quem chama usa a faixa para destacar no editor o comando que falhou, e
    /// uma faixa relativa à seleção apontaria para o começo do editor.
    public static func statements(in text: String, selection: NSRange?) -> [SQLStatement] {
        guard let selection, selection.length > 0 else {
            return SQLDump.statements(in: text)
        }
        let full = text as NSString
        // Seleção fora do texto: acontece quando o texto muda por baixo (biblioteca,
        // histórico) antes do gatilho chegar. Melhor executar tudo que recortar errado.
        guard selection.location >= 0, NSMaxRange(selection) <= full.length else {
            return SQLDump.statements(in: text)
        }
        let slice = full.substring(with: selection)
        return SQLDump.statements(in: slice).map {
            SQLStatement(sql: $0.sql, location: $0.location + selection.location, length: $0.length)
        }
    }

    /// Comando sob o cursor. Com o cursor num espaço entre comandos vale o anterior — é
    /// onde o cursor fica depois de digitar o comando e apertar o atalho.
    public static func statement(in text: String, at cursor: Int) -> SQLStatement? {
        let all = SQLDump.statements(in: text)
        if let hit = all.first(where: { $0.contains(cursor) }) { return hit }
        if let previous = all.last(where: { $0.endLocation < cursor }) { return previous }
        return all.first
    }
}
