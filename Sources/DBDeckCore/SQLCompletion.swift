import Foundation

/// O que existe no banco, do ponto de vista do autocomplete.
///
/// As colunas chegam sob demanda: pedir as colunas de todas as tabelas ao abrir o console
/// seria uma consulta por tabela num schema com centenas delas. Quem preenche é o app,
/// conforme as tabelas vão sendo citadas na consulta.
public struct SQLSchemaCatalog: Sendable, Equatable {
    /// Nomes como o banco os devolve — é o que vai ser inserido no editor.
    public var tables: [String]
    /// Colunas por tabela, chaveadas em minúsculas (SQL não diferencia caixa aqui).
    public var columns: [String: [String]]

    public init(tables: [String] = [], columns: [String: [String]] = [:]) {
        self.tables = tables
        self.columns = columns
    }

    public func columns(of table: String) -> [String] {
        if let exact = columns[table.lowercased()] { return exact }
        // `schema.tabela` no FROM: o catálogo é chaveado pelo nome que o driver lista,
        // que vem sem o schema.
        guard let dot = table.lastIndex(of: ".") else { return [] }
        return columns[table[table.index(after: dot)...].lowercased()] ?? []
    }
}

/// Uma tabela citada num comando, com o apelido que ela recebeu.
public struct SQLTableReference: Sendable, Equatable {
    public let table: String
    public let alias: String?

    public init(table: String, alias: String?) {
        self.table = table
        self.alias = alias
    }
}

/// Sugestões do editor SQL: palavras-chave, tabelas e colunas.
///
/// Tudo aqui trabalha em unidades UTF-16, a medida do `NSRange` do `NSTextView` — contar
/// `Character` deslocaria a faixa em qualquer consulta com acento e o editor substituiria
/// o pedaço errado do texto.
public enum SQLCompletion {
    // MARK: - Palavra sob o cursor

    /// Faixa da palavra parcial imediatamente antes do cursor (vazia quando o cursor está
    /// depois de um espaço ou pontuação).
    public static func partialWordRange(in text: String, cursor: Int) -> NSRange {
        let string = text as NSString
        let end = min(max(cursor, 0), string.length)
        var start = end
        while start > 0, isIdentifierUnit(string.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Qualificador antes do ponto (`pedidos.cli|` → "pedidos"), ou nil quando não há ponto.
    public static func qualifier(in text: String, before partialStart: Int) -> String? {
        let string = text as NSString
        var index = partialStart
        guard index > 0, string.character(at: index - 1) == UInt16(UInt8(ascii: ".")) else { return nil }
        index -= 1
        var start = index
        while start > 0, isIdentifierUnit(string.character(at: start - 1)) {
            start -= 1
        }
        guard start < index else { return nil }
        return string.substring(with: NSRange(location: start, length: index - start))
    }

    // MARK: - Tabelas citadas

    /// Tabelas citadas depois de FROM/JOIN/UPDATE/INTO, com o apelido quando houver.
    ///
    /// É deliberadamente um reconhecedor raso, não um parser: serve para saber de quem
    /// pedir colunas. Errar para mais custa uma consulta de metadados; errar para menos
    /// custa uma sugestão que não aparece.
    public static func referencedTables(in statement: String) -> [SQLTableReference] {
        var references: [SQLTableReference] = []
        let tokens = tokenize(statement)
        var index = 0
        while index < tokens.count {
            let keyword = tokens[index].uppercased()
            let introducesTable = keyword == "FROM" || keyword == "JOIN" || keyword == "UPDATE"
                || (keyword == "INTO" && index > 0)
            guard introducesTable, index + 1 < tokens.count else {
                index += 1
                continue
            }
            let name = unquote(tokens[index + 1])
            guard isIdentifier(name) else {
                index += 1
                continue
            }
            // Apelido: `t AS x`, `t x` — mas não `t WHERE`, `t ON`, `t INNER`…
            var alias: String?
            var next = index + 2
            if next < tokens.count, tokens[next].uppercased() == "AS" { next += 1 }
            if next < tokens.count {
                let candidate = unquote(tokens[next])
                if isIdentifier(candidate), !reservedAfterTable.contains(candidate.uppercased()) {
                    alias = candidate
                }
            }
            references.append(SQLTableReference(table: name, alias: alias))
            index += 2
        }
        return references
    }

    // MARK: - Sugestões

    /// Sugestões para o cursor, já ordenadas e sem repetição.
    public static func suggestions(text: String, cursor: Int, catalog: SQLSchemaCatalog) -> [String] {
        let partial = partialWordRange(in: text, cursor: cursor)
        let prefix = (text as NSString).substring(with: partial)
        let statement = SQLDump.statements(in: text).first { $0.contains(cursor) }?.sql ?? text
        let references = referencedTables(in: statement)

        // `alias.` / `tabela.` — só as colunas daquela tabela, sem ruído de keyword.
        if let qualifier = qualifier(in: text, before: partial.location) {
            let resolved = references.first {
                $0.alias?.caseInsensitiveCompare(qualifier) == .orderedSame
            }?.table ?? qualifier
            return rank(catalog.columns(of: resolved), prefix: prefix)
        }

        var candidates: [String] = []
        // Colunas das tabelas em jogo primeiro: é o que se está digitando na maior
        // parte do tempo dentro de um SELECT/WHERE.
        for reference in references {
            candidates += catalog.columns(of: reference.table)
        }
        candidates += catalog.tables
        candidates += keywords
        return rank(candidates, prefix: prefix)
    }

    /// Filtra por prefixo, remove repetição (ignorando caixa) e preserva a ordem de
    /// prioridade de quem montou a lista.
    private static func rank(_ candidates: [String], prefix: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            guard prefix.isEmpty || candidate.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            // Sugerir exatamente o que já está digitado só polui a lista.
            guard candidate.caseInsensitiveCompare(prefix) != .orderedSame else { continue }
            guard seen.insert(candidate.lowercased()).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    // MARK: - Léxico

    private static func isIdentifierUnit(_ unit: unichar) -> Bool {
        if let scalar = Unicode.Scalar(unit) {
            let character = Character(scalar)
            if character.isLetter || character.isNumber { return true }
            return character == "_" || character == "$"
        }
        // Metade de um par substituto (emoji): é conteúdo de string, não identificador.
        return false
    }

    /// Aceita nome qualificado (`schema.tabela`) — o tokenizador mantém o ponto junto.
    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        guard value.last != "." else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." }
    }

    private static func unquote(_ token: String) -> String {
        guard token.count >= 2, let first = token.first, let last = token.last, first == last,
              first == "\"" || first == "`" else { return token }
        return String(token.dropFirst().dropLast())
    }

    /// Quebra em identificadores, identificadores citados e pontuação relevante,
    /// descartando strings e comentários — o suficiente para achar FROM/JOIN.
    private static func tokenize(_ statement: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var characters = Array(statement)
        var index = 0

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "'":
                flush()
                index += 1
                while index < characters.count, characters[index] != "'" { index += 1 }
            case "\"", "`":
                flush()
                let quote = character
                var quoted = String(quote)
                index += 1
                while index < characters.count, characters[index] != quote {
                    quoted.append(characters[index])
                    index += 1
                }
                quoted.append(quote)
                tokens.append(quoted)
            case "-" where index + 1 < characters.count && characters[index + 1] == "-":
                flush()
                while index < characters.count, characters[index] != "\n" { index += 1 }
            case "/" where index + 1 < characters.count && characters[index + 1] == "*":
                flush()
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index += 1
            default:
                if character.isLetter || character.isNumber || character == "_" || character == "$" || character == "." {
                    current.append(character)
                } else {
                    flush()
                }
            }
            index += 1
        }
        flush()
        return tokens
    }

    /// Palavras que NUNCA são apelido de tabela — sem esta lista `FROM pedidos WHERE`
    /// registraria "WHERE" como apelido e o `alias.` pararia de resolver.
    private static let reservedAfterTable: Set<String> = [
        "WHERE", "ON", "USING", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
        "JOIN", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "SET", "VALUES",
        "SELECT", "AND", "OR", "AS", "RETURNING", "FOR", "WINDOW", "FETCH", "INTO",
    ]

    /// Sugeridas em caixa alta, que é como se escreve SQL legível.
    public static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING",
        "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON", "USING",
        "CREATE TABLE", "CREATE INDEX", "CREATE VIEW", "ALTER TABLE", "DROP TABLE",
        "ADD COLUMN", "PRIMARY KEY", "FOREIGN KEY", "REFERENCES", "UNIQUE", "DEFAULT",
        "NOT NULL", "IS NULL", "IS NOT NULL", "DISTINCT", "COUNT", "SUM", "AVG", "MIN",
        "MAX", "COALESCE", "CASE", "WHEN", "THEN", "ELSE", "END", "BETWEEN", "LIKE",
        "ILIKE", "EXISTS", "UNION ALL", "WITH", "AS", "AND", "OR", "NOT", "IN",
        "BEGIN", "COMMIT", "ROLLBACK", "EXPLAIN", "TRUNCATE", "ASC", "DESC",
    ]
}
