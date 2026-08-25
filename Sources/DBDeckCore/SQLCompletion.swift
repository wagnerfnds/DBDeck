import Foundation

// MARK: - Catálogo

/// Uma coluna do ponto de vista do autocomplete: nome e tipo (o tipo é o detalhe que o
/// popup mostra à direita — `varchar(255)`, `int4`).
public struct SQLColumnInfo: Sendable, Equatable, Hashable {
    public let name: String
    public let type: String?

    public init(name: String, type: String? = nil) {
        self.name = name
        self.type = type
    }
}

/// O que existe no banco, do ponto de vista do autocomplete.
///
/// As colunas chegam sob demanda: pedir as colunas de todas as tabelas ao abrir o console
/// seria uma consulta por tabela num schema com centenas delas. Quem preenche é o app,
/// conforme as tabelas vão sendo citadas na consulta.
public struct SQLSchemaCatalog: Sendable, Equatable {
    /// Nomes como o banco os devolve — é o que vai ser inserido no editor.
    public var tables: [String]
    /// Colunas por tabela, chaveadas em minúsculas (SQL não diferencia caixa aqui).
    public var columns: [String: [SQLColumnInfo]]

    public init(tables: [String] = [], columns: [String: [SQLColumnInfo]] = [:]) {
        self.tables = tables
        self.columns = columns
    }

    /// Conveniência para quem só tem os nomes (testes, catálogos antigos).
    public init(tables: [String], columns: [String: [String]]) {
        self.tables = tables
        self.columns = columns.mapValues { $0.map { SQLColumnInfo(name: $0) } }
    }

    public func columns(of table: String) -> [SQLColumnInfo] {
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

// MARK: - Sugestão

/// Uma entrada da lista de sugestões. `kind` decide o ícone e se ganha espaço depois de
/// aceita; `detail` é o texto secundário (tipo da coluna, tabela do apelido).
public struct SQLSuggestion: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable {
        case keyword, table, column, alias
    }

    public let text: String
    public let kind: Kind
    public let detail: String?

    public init(text: String, kind: Kind, detail: String? = nil) {
        self.text = text
        self.kind = kind
        self.detail = detail
    }
}

/// O que a posição do cursor pede.
public enum SQLCompletionTrigger: Sendable, Equatable {
    /// Nada a sugerir: cursor depois de espaço/pontuação, ou dentro de string/comentário.
    case none
    /// Digitando um identificador ou palavra-chave.
    case identifier
    /// Logo depois de `apelido.` — só colunas cabem aqui.
    case afterDot
}

// MARK: - Motor

/// Sugestões do editor SQL: palavras-chave, tabelas, apelidos e colunas.
///
/// Tudo aqui trabalha em unidades UTF-16, a medida do `NSRange` do `NSTextView` — contar
/// `Character` deslocaria a faixa em qualquer consulta com acento e o editor substituiria
/// o pedaço errado do texto.
public enum SQLCompletion {
    // MARK: Palavra sob o cursor

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

    /// Decide se a posição do cursor pede sugestões — a regra do "abre sozinho".
    ///
    /// Vive no core, e não no editor, porque é o tipo de coisa que se quer testar sem
    /// AppKit: "dentro de string não abre" é um caso de teste, não uma impressão.
    public static func trigger(in text: String, cursor: Int) -> SQLCompletionTrigger {
        let string = text as NSString
        let position = min(max(cursor, 0), string.length)
        guard !isInsideStringOrComment(string, at: position) else { return .none }
        let partial = partialWordRange(in: text, cursor: position)
        if qualifier(in: text, before: partial.location) != nil { return .afterDot }
        return partial.length >= 1 ? .identifier : .none
    }

    // MARK: Tabelas citadas

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

    // MARK: Sugestões

    /// Sugestões para o cursor, já ordenadas e sem repetição.
    public static func suggestions(text: String, cursor: Int, catalog: SQLSchemaCatalog) -> [SQLSuggestion] {
        let partial = partialWordRange(in: text, cursor: cursor)
        let prefix = (text as NSString).substring(with: partial)
        let statement = SQLDump.statements(in: text).first { $0.contains(cursor) }?.sql ?? text
        let references = referencedTables(in: statement)

        // `alias.` / `tabela.` — só as colunas daquela tabela, sem ruído de keyword.
        if let qualifier = qualifier(in: text, before: partial.location) {
            let resolved = references.first {
                $0.alias?.caseInsensitiveCompare(qualifier) == .orderedSame
            }?.table ?? qualifier
            return rank(columnSuggestions(catalog.columns(of: resolved)), prefix: prefix)
        }

        var candidates: [SQLSuggestion] = []
        // Colunas das tabelas em jogo primeiro: é o que se está digitando na maior
        // parte do tempo dentro de um SELECT/WHERE. Depois os apelidos, que são curtos
        // e baratos de completar; depois tabelas; palavras-chave por último.
        for reference in references {
            candidates += columnSuggestions(catalog.columns(of: reference.table))
        }
        for reference in references {
            // A palavra sendo digitada logo depois do nome da tabela É lida como apelido
            // pelo reconhecedor (`FROM pedidos WHE`): sugerir "WHE" de volta seria ruído.
            if let alias = reference.alias, alias.caseInsensitiveCompare(prefix) != .orderedSame {
                candidates.append(SQLSuggestion(text: alias, kind: .alias, detail: reference.table))
            }
        }
        candidates += catalog.tables.map { SQLSuggestion(text: $0, kind: .table) }
        candidates += keywords.map { SQLSuggestion(text: $0, kind: .keyword) }
        return rank(candidates, prefix: prefix)
    }

    private static func columnSuggestions(_ columns: [SQLColumnInfo]) -> [SQLSuggestion] {
        columns.map { SQLSuggestion(text: $0.name, kind: .column, detail: $0.type?.lowercased()) }
    }

    /// Como um candidato casou com o prefixo. A ordem do enum é a ordem de exibição.
    public enum Match: Int, Comparable, Sendable {
        /// O próprio texto digitado (mesma caixa ou não) — vai para o topo, como no Xcode.
        case exact
        /// Começa com o prefixo, na mesma caixa.
        case exactPrefix
        /// Começa com o prefixo, ignorando caixa.
        case prefix
        /// Um segmento depois de `_` começa com o prefixo: `leads` casa `automacao_leads`.
        /// É o que faz sentido em nomes snake_case, sem o ruído do fuzzy por subsequência.
        case wordStart
        /// Contém o prefixo em qualquer posição — só a partir de três caracteres.
        case substring

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Ordem de grupo dentro de um mesmo tipo de match. Palavras-chave primeiro: são
    /// poucas e precisas — `sel` tem que mostrar SELECT antes de qualquer tabela que
    /// comece com "sel". Depois as colunas das tabelas citadas (o que mais se digita num
    /// SELECT/WHERE), apelidos e, por último, o catálogo inteiro de tabelas.
    private static func groupOrder(_ kind: SQLSuggestion.Kind) -> Int {
        switch kind {
        case .keyword: 0
        case .column: 1
        case .alias: 2
        case .table: 3
        }
    }

    /// Filtra e ordena por (qualidade do match, grupo, ordem original). A qualidade manda
    /// primeiro: um prefixo de qualquer grupo vence um match parcial de qualquer outro.
    /// Repetições (ignorando caixa) somem. O match exato entra — é ele que se quer aceitar
    /// para ganhar o espaço/caixa — a não ser que seja o ÚNICO item, quando a lista só
    /// atrapalharia o Enter de quebrar linha.
    private static func rank(_ candidates: [SQLSuggestion], prefix: String) -> [SQLSuggestion] {
        var seen = Set<String>()
        var scored: [(order: Int, match: Match, item: SQLSuggestion)] = []
        for (order, candidate) in candidates.enumerated() {
            guard var match = match(candidate.text, prefix: prefix) else { continue }
            guard seen.insert(candidate.text.lowercased()).inserted else { continue }
            // Palavra-chave não perde para a caixa: quem digita `sel` quer SELECT, e a
            // tabela `selecoes` não pode passar na frente só por estar em minúsculas.
            if candidate.kind == .keyword, match == .prefix { match = .exactPrefix }
            scored.append((order, match, candidate))
        }
        if scored.count == 1, scored[0].match == .exact, scored[0].item.text == prefix { return [] }
        return scored
            .sorted { lhs, rhs in
                if lhs.match != rhs.match { return lhs.match < rhs.match }
                let lhsGroup = groupOrder(lhs.item.kind), rhsGroup = groupOrder(rhs.item.kind)
                if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
                return lhs.order < rhs.order
            }
            .map(\.item)
    }

    /// Casamento de um candidato com o prefixo — também usado pelo popup para pôr em
    /// negrito os caracteres casados.
    public static func match(_ candidate: String, prefix: String) -> Match? {
        guard !prefix.isEmpty else { return .prefix }
        if candidate.caseInsensitiveCompare(prefix) == .orderedSame { return .exact }
        if candidate.hasPrefix(prefix) { return .exactPrefix }
        let lowerCandidate = candidate.lowercased()
        let lowerPrefix = prefix.lowercased()
        if lowerCandidate.hasPrefix(lowerPrefix) { return .prefix }
        guard prefix.count >= 2 else { return nil }
        if segmentStarts(of: lowerCandidate).contains(where: { lowerCandidate[$0...].hasPrefix(lowerPrefix) }) {
            return .wordStart
        }
        guard prefix.count >= 3 else { return nil }
        return lowerCandidate.contains(lowerPrefix) ? .substring : nil
    }

    /// Índices (em UTF-16, para o `NSAttributedString` do popup) dos caracteres do
    /// candidato que casam com o prefixo — sempre um trecho contíguo.
    public static func matchedOffsets(in candidate: String, prefix: String) -> [Int] {
        guard !prefix.isEmpty, let kind = match(candidate, prefix: prefix) else { return [] }
        let lowerCandidate = candidate.lowercased()
        let lowerPrefix = prefix.lowercased()
        let location: String.Index?
        switch kind {
        case .exact, .exactPrefix, .prefix:
            location = lowerCandidate.startIndex
        case .wordStart:
            location = segmentStarts(of: lowerCandidate).first { lowerCandidate[$0...].hasPrefix(lowerPrefix) }
        case .substring:
            location = lowerCandidate.range(of: lowerPrefix)?.lowerBound
        }
        guard let location else { return [] }
        let start = lowerCandidate.utf16.distance(from: lowerCandidate.startIndex, to: location)
        return Array(start..<(start + lowerPrefix.utf16.count))
    }

    /// Índices onde começa cada segmento depois de `_` (o início do texto não conta —
    /// esse é o caso de prefixo).
    private static func segmentStarts(of text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var index = text.startIndex
        while let underscore = text[index...].firstIndex(of: "_") {
            let next = text.index(after: underscore)
            if next < text.endIndex { starts.append(next) }
            index = next
        }
        return starts
    }

    // MARK: Léxico

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

    /// Varre do início até `position` acompanhando strings e comentários. Um passe por
    /// tecla sobre o texto até o cursor — o mesmo custo do highlight, que já roda por tecla.
    private static func isInsideStringOrComment(_ string: NSString, at position: Int) -> Bool {
        var quote: unichar = 0
        var lineComment = false
        var blockComment = false
        var index = 0
        while index < position {
            let unit = string.character(at: index)
            let next: unichar = index + 1 < string.length ? string.character(at: index + 1) : 0
            if lineComment {
                if unit == 0x0A { lineComment = false }
            } else if blockComment {
                if unit == 0x2A, next == 0x2F { blockComment = false; index += 1 }
            } else if quote != 0 {
                if unit == 0x5C { index += 1 }              // `\x` escapado
                else if unit == quote {
                    if next == quote { index += 1 }          // `''` continua a string
                    else { quote = 0 }
                }
            } else {
                switch unit {
                case 0x27, 0x22, 0x60: quote = unit          // ' " `
                case 0x2D where next == 0x2D: lineComment = true; index += 1
                case 0x23: lineComment = true                // # (MySQL)
                case 0x2F where next == 0x2A: blockComment = true; index += 1
                default: break
                }
            }
            index += 1
        }
        return quote != 0 || lineComment || blockComment
    }

    /// Quebra em identificadores, identificadores citados e pontuação relevante,
    /// descartando strings e comentários — o suficiente para achar FROM/JOIN.
    private static func tokenize(_ statement: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let characters = Array(statement)
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
