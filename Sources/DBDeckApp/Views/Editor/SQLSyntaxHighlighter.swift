import AppKit

/// Highlight de SQL por regex — keywords, strings, números e comentários, nas cores do
/// `Theme` (dinâmicas: acompanham claro/escuro).
///
/// Roda um passe completo a cada mudança de texto; consultas de console têm poucos KB,
/// então é imperceptível. Scripts de MBs colados são o caso em que um highlight
/// incremental passaria a valer — anotado como trabalho futuro.
enum SQLSyntaxHighlighter {
    static func font(size: CGFloat) -> NSFont {
        Theme.codeFont(size: size)
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
            "ilike", "analyze", "vacuum", "grant", "revoke", "procedure", "function",
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
        apply(numberRegex, color: Theme.syntaxNumber, in: text, range: range, storage: storage)
        apply(keywordRegex, color: Theme.syntaxKeyword, in: text, range: range, storage: storage)
        apply(stringRegex, color: Theme.syntaxString, in: text, range: range, storage: storage)
        apply(commentRegex, color: Theme.syntaxComment, in: text, range: range, storage: storage)
        storage.endEditing()
    }

    /// Versão para `NSAttributedString` avulso (biblioteca de consultas, prévias).
    static func attributed(_ sql: String, fontSize: CGFloat) -> NSAttributedString {
        let storage = NSTextStorage(string: sql)
        highlight(storage, fontSize: fontSize)
        return storage
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
