import Foundation

/// Formatador de SQL por tokens — sem parser, sem dependência.
///
/// A regra é a de quem lê: cada cláusula de topo (SELECT, FROM, WHERE, …) numa linha;
/// lista do SELECT e do SET um item por linha; JOIN, AND e OR indentados sob a cláusula;
/// subconsulta abre bloco com indentação própria; palavras reservadas em caixa alta,
/// identificadores como estão. Strings, identificadores citados, comentários e corpos
/// dollar-quoted saem exatamente como entraram — o formatador NUNCA muda o que o
/// banco vai receber, só os espaços em volta.
public enum SQLFormatter {
    public static let indentUnit = "    "

    /// O que o usuário pode ajustar. Entra por parâmetro: o core não conhece preferências.
    public struct Options: Sendable, Equatable {
        public var indentUnit: String
        /// Palavras reservadas em caixa alta. Desligado, saem como foram escritas.
        public var uppercaseKeywords: Bool

        public init(indentUnit: String = SQLFormatter.indentUnit, uppercaseKeywords: Bool = true) {
            self.indentUnit = indentUnit
            self.uppercaseKeywords = uppercaseKeywords
        }
    }

    public static func format(_ sql: String, options: Options = Options()) -> String {
        var tokenizer = Tokenizer(sql)
        let tokens = tokenizer.tokenize()
        guard !tokens.isEmpty else { return sql.trimmingCharacters(in: .whitespacesAndNewlines) }
        let printer = Printer(tokens: tokens, options: options)
        return printer.run()
    }

    // MARK: - Tokens

    enum Kind: Equatable {
        case word          // identificador ou palavra-chave (decidido depois)
        case quoted        // "x", `x`
        case string        // 'x'
        case number
        case op            // = <> <= >= != + - * / % || :: etc.
        case comma, semicolon, lparen, rparen, dot
        case lineComment, blockComment
        case dollar        // $$…$$
    }

    struct Token: Equatable {
        var kind: Kind
        var text: String
        /// Havia quebra de linha antes deste token no original — decide se um comentário
        /// fica na própria linha ou colado ao fim da anterior.
        var precededByNewline: Bool

        var upper: String { text.uppercased() }
    }

    struct Tokenizer {
        private let chars: [Character]
        private var index = 0

        init(_ sql: String) {
            chars = Array(sql)
        }

        mutating func tokenize() -> [Token] {
            var tokens: [Token] = []
            var sawNewline = false
            while index < chars.count {
                let c = chars[index]
                if c.isWhitespace {
                    if c == "\n" || c == "\r" { sawNewline = true }
                    index += 1
                    continue
                }
                let start = index
                let kind: Kind
                if c == "-", peek(1) == "-" {
                    kind = .lineComment
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                } else if c == "#" {
                    kind = .lineComment
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                } else if c == "/", peek(1) == "*" {
                    kind = .blockComment
                    index += 2
                    while index < chars.count, !(chars[index] == "*" && peek(1) == "/") { index += 1 }
                    index = min(index + 2, chars.count)
                } else if c == "'" {
                    kind = .string
                    index += 1
                    while index < chars.count {
                        if chars[index] == "\\" { index += 2; continue }
                        if chars[index] == "'" {
                            if peek(1) == "'" { index += 2; continue }
                            index += 1
                            break
                        }
                        index += 1
                    }
                } else if c == "\"" || c == "`" {
                    kind = .quoted
                    index += 1
                    while index < chars.count, chars[index] != c { index += 1 }
                    index = min(index + 1, chars.count)
                } else if c == "$", let close = dollarClose(at: index) {
                    kind = .dollar
                    index = close
                } else if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                    kind = .number
                    while index < chars.count, chars[index].isNumber || chars[index] == "." || chars[index] == "e" || chars[index] == "E"
                        || ((chars[index] == "+" || chars[index] == "-") && (chars[index - 1] == "e" || chars[index - 1] == "E")) {
                        index += 1
                    }
                } else if c.isLetter || c == "_" || c == "@" || c == "$" || c == ":" && (peek(1)?.isLetter ?? false) {
                    kind = .word
                    index += 1
                    while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == "$" { index += 1 }
                } else {
                    switch c {
                    case ",": kind = .comma; index += 1
                    case ";": kind = .semicolon; index += 1
                    case "(": kind = .lparen; index += 1
                    case ")": kind = .rparen; index += 1
                    case ".": kind = .dot; index += 1
                    default:
                        kind = .op
                        // Operadores compostos mais longos primeiro.
                        let candidates = ["<=>", "!=", "<>", "<=", ">=", "||", "::", "->>", "->", "~*", "!~", ":="]
                        if let match = candidates.first(where: { matches($0, at: index) }) {
                            index += match.count
                        } else {
                            index += 1
                        }
                    }
                }
                tokens.append(Token(kind: kind, text: String(chars[start..<index]), precededByNewline: sawNewline))
                sawNewline = false
            }
            return tokens
        }

        private func peek(_ offset: Int) -> Character? {
            let i = index + offset
            return i < chars.count ? chars[i] : nil
        }

        private func matches(_ s: String, at i: Int) -> Bool {
            let target = Array(s)
            guard i + target.count <= chars.count else { return false }
            return Array(chars[i..<(i + target.count)]) == target
        }

        /// Fim (exclusivo) de um corpo `$tag$ … $tag$` começando em `i`, ou nil se não é um.
        private func dollarClose(at i: Int) -> Int? {
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            guard j < chars.count, chars[j] == "$" else { return nil }
            let tag = Array(chars[i...j])
            var k = j + 1
            while k + tag.count <= chars.count {
                if Array(chars[k..<(k + tag.count)]) == tag { return k + tag.count }
                k += 1
            }
            return chars.count
        }
    }

    // MARK: - Vocabulário

    /// Frases de mais de uma palavra tratadas como um token só (mais longas primeiro).
    static let phrases: [[String]] = [
        ["ON", "DUPLICATE", "KEY", "UPDATE"],
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["IS", "NOT", "NULL"], ["NOT", "MATERIALIZED"],
        ["GROUP", "BY"], ["ORDER", "BY"], ["PARTITION", "BY"], ["INSERT", "INTO"], ["DELETE", "FROM"],
        ["UNION", "ALL"], ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["FULL", "JOIN"], ["INNER", "JOIN"],
        ["CROSS", "JOIN"], ["NATURAL", "JOIN"], ["ON", "CONFLICT"], ["IS", "NULL"], ["IS", "NOT"],
        ["NOT", "IN"], ["NOT", "LIKE"], ["NOT", "EXISTS"], ["NOT", "BETWEEN"], ["CREATE", "TABLE"],
        ["ALTER", "TABLE"], ["DROP", "TABLE"], ["CREATE", "INDEX"], ["CREATE", "VIEW"],
        ["IF", "NOT", "EXISTS"], ["IF", "EXISTS"], ["PRIMARY", "KEY"], ["FOREIGN", "KEY"],
        ["NOT", "NULL"], ["DO", "NOTHING"], ["DO", "UPDATE"], ["FOR", "UPDATE"], ["WITH", "RECURSIVE"],
        ["EXCEPT", "ALL"], ["INTERSECT", "ALL"], ["FETCH", "FIRST"], ["FETCH", "NEXT"], ["ROWS", "ONLY"],
        ["ADD", "COLUMN"], ["DROP", "COLUMN"], ["ALTER", "COLUMN"], ["RENAME", "TO"],
    ]

    /// Cláusulas de topo: cada uma começa uma linha na indentação do bloco.
    static let clauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "WITH RECURSIVE",
        "UNION", "UNION ALL", "EXCEPT", "EXCEPT ALL", "INTERSECT", "INTERSECT ALL",
        "ON CONFLICT", "ON DUPLICATE KEY UPDATE", "WINDOW", "FETCH FIRST", "FETCH NEXT", "FOR UPDATE",
        "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "CREATE INDEX", "CREATE VIEW",
        "ADD COLUMN", "DROP COLUMN", "ALTER COLUMN", "RENAME TO",
    ]

    /// Cláusulas cuja lista vai um item por linha, indentado.
    static let listClauses: Set<String> = ["SELECT", "SET", "RETURNING", "ADD COLUMN"]

    static let joins: Set<String> = [
        "JOIN", "INNER JOIN", "LEFT JOIN", "LEFT OUTER JOIN", "RIGHT JOIN", "RIGHT OUTER JOIN",
        "FULL JOIN", "FULL OUTER JOIN", "CROSS JOIN", "NATURAL JOIN",
    ]

    /// Palavras reservadas que saem em caixa alta. Funções (count, coalesce, now) ficam
    /// como foram escritas — não são reservadas e muita gente prefere minúsculas.
    static let reserved: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "AS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "DROP", "ALTER", "TABLE",
        "INDEX", "VIEW", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "ON",
        "USING", "GROUP", "BY", "HAVING", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "UNION", "ALL",
        "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "BETWEEN", "EXISTS", "ANY", "SOME",
        "WITH", "RECURSIVE", "PRIMARY", "FOREIGN", "KEY", "REFERENCES", "UNIQUE", "CHECK", "DEFAULT",
        "CONSTRAINT", "ADD", "COLUMN", "RENAME", "TO", "BEGIN", "COMMIT", "ROLLBACK", "TRUNCATE",
        "EXPLAIN", "RETURNING", "TRUE", "FALSE", "CAST", "INTERVAL", "EXCEPT", "INTERSECT", "OVER",
        "PARTITION", "WINDOW", "FETCH", "FIRST", "NEXT", "ROWS", "ONLY", "NULLS", "LAST", "IF",
        "CONFLICT", "DO", "NOTHING", "DUPLICATE", "FOR", "LATERAL", "MATERIALIZED", "TEMPORARY",
        "ESCAPE", "COLLATE", "GRANT", "REVOKE", "ANALYZE", "VACUUM", "REPLACE", "IGNORE",
    ]

    // MARK: - Impressão

    final class Printer {
        private let tokens: [Token]
        private var out = ""
        private var lineIsEmpty = true
        /// Base de indentação de cada bloco aberto por parêntese (ou do statement, no fundo).
        private var indentStack: [Int] = [0]
        /// Modo "um item por linha" por bloco.
        private var listModeStack: [Bool] = [false]
        /// Quanto os itens da lista descem em relação ao bloco: 1 sob uma cláusula
        /// (`SELECT` / `SET`), 0 dentro do parêntese de um `CREATE TABLE` (o bloco já indenta).
        private var listOffsetStack: [Int] = [1]
        /// Parênteses abertos como bloco (subconsulta, DDL) vs. inline (função, IN).
        private var parenIsBlock: [Bool] = []
        /// Aninhamento de CASE, com a indentação do CASE.
        private var caseStack: [Int] = []
        private var previous: Token?
        /// Última cláusula de topo do statement corrente — decide se um `(` é DDL.
        private var currentClause: String?
        /// Índice do token corrente e quantos tokens a frase ocupa (para olhar à frente).
        private var position = 0
        private var phraseLength = 1

        private let options: Options

        init(tokens: [Token], options: Options) {
            self.tokens = tokens
            self.options = options
        }

        private var indent: Int { indentStack.last ?? 0 }
        private var listMode: Bool { listModeStack.last ?? false }

        func run() -> String {
            var i = 0
            while i < tokens.count {
                let (phrase, consumed) = readPhrase(at: i)
                position = i
                phraseLength = consumed
                let next = i + consumed < tokens.count ? tokens[i + consumed] : nil
                let afterNext = i + consumed + 1 < tokens.count ? tokens[i + consumed + 1] : nil
                emit(phrase, next: next, afterNext: afterNext)
                i += consumed
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Junta `GROUP BY`, `LEFT OUTER JOIN` etc. num token só.
        private func readPhrase(at i: Int) -> (Token, Int) {
            let token = tokens[i]
            guard token.kind == .word else { return (token, 1) }
            for phrase in SQLFormatter.phrases {
                guard i + phrase.count <= tokens.count else { continue }
                var matches = true
                for (offset, word) in phrase.enumerated() {
                    let candidate = tokens[i + offset]
                    if candidate.kind != .word || candidate.upper != word { matches = false; break }
                }
                if matches {
                    return (Token(kind: .word, text: phrase.joined(separator: " "), precededByNewline: token.precededByNewline), phrase.count)
                }
            }
            return (token, 1)
        }

        // MARK: Escrita

        private func newline(at level: Int) {
            if !lineIsEmpty {
                out += "\n"
            } else if !out.isEmpty {
                // Linha já vazia: só troca a indentação pendente.
                while out.last == " " { out.removeLast() }
            }
            out += String(repeating: options.indentUnit, count: max(0, level))
            lineIsEmpty = true
        }

        private func blankLine() {
            if !lineIsEmpty { out += "\n" }
            out += "\n"
            lineIsEmpty = true
        }

        private func write(_ text: String, spaceBefore: Bool) {
            if spaceBefore, !lineIsEmpty, out.last != " ", out.last != "\n" { out += " " }
            out += text
            lineIsEmpty = false
        }

        // MARK: Regras

        private func emit(_ token: Token, next: Token?, afterNext: Token?) {
            defer { previous = token }
            let upper = token.upper

            switch token.kind {
            case .lineComment:
                if token.precededByNewline || previous == nil { newline(at: indent) }
                write(token.text.trimmingCharacters(in: .whitespaces), spaceBefore: true)
                newline(at: indent)
                return
            case .blockComment:
                if token.precededByNewline { newline(at: indent) }
                write(token.text, spaceBefore: true)
                return
            case .dollar:
                write(token.text, spaceBefore: true)
                return
            case .semicolon:
                out += ";"
                lineIsEmpty = false
                indentStack = [0]
                listModeStack = [false]
                listOffsetStack = [1]
                parenIsBlock = []
                caseStack = []
                currentClause = nil
                if next != nil { blankLine() }
                return
            case .comma:
                out += ","
                lineIsEmpty = false
                if listMode { newline(at: indent + (listOffsetStack.last ?? 1)) }
                return
            case .dot:
                out += "."
                return
            case .lparen:
                // DDL: só o parêntese da lista de colunas (nível 0) é bloco; `varchar(80)`
                // dentro dele é inline.
                let isDDL = currentClause == "CREATE TABLE" && parenIsBlock.isEmpty
                    && (previous?.kind == .word || previous?.kind == .quoted)
                let isBlock = startsBlock(next: next) || isDDL
                // `count(` colado; `IN (`, `VALUES (` e `INSERT INTO t (` com espaço.
                let afterTableName = (currentClause == "INSERT INTO" || currentClause == "CREATE TABLE") && parenIsBlock.isEmpty
                let attached = !afterTableName && (previous.map { $0.kind == .word && !SQLFormatter.reserved.contains($0.upper) && !SQLFormatter.clauses.contains($0.upper) || $0.kind == .quoted || $0.kind == .rparen } ?? false)
                write("(", spaceBefore: !attached)
                parenIsBlock.append(isBlock)
                if isBlock {
                    // Subconsulta / DDL: bloco próprio, uma cláusula (ou coluna) por linha.
                    indentStack.append(indent + 1)
                    listModeStack.append(isDDL)
                    listOffsetStack.append(isDDL ? 0 : 1)
                    newline(at: indent)
                } else {
                    indentStack.append(indent)
                    listModeStack.append(false)
                    listOffsetStack.append(1)
                }
                return
            case .rparen:
                let wasBlock = parenIsBlock.popLast() ?? false
                indentStack.removeLast()
                listModeStack.removeLast()
                listOffsetStack.removeLast()
                if wasBlock { newline(at: indent) }
                out += ")"
                lineIsEmpty = false
                return
            case .op:
                emitOperator(token, next: next)
                return
            case .string, .quoted, .number:
                write(token.text, spaceBefore: needsSpaceBefore())
                return
            case .word:
                break
            }

            // Palavras: cláusulas, joins, AND/OR, CASE, ou identificador.
            let text = SQLFormatter.reserved.contains(upper) || SQLFormatter.clauses.contains(upper) || SQLFormatter.joins.contains(upper)
                ? (options.uppercaseKeywords ? upper : token.text) : token.text

            if SQLFormatter.clauses.contains(upper) {
                // Dentro de um parêntese inline (`IN (SELECT …)` curto) não abre bloco.
                let inlineParen = !(parenIsBlock.last ?? true)
                if inlineParen && previous?.kind == .lparen {
                    write(text, spaceBefore: false)
                } else {
                    let closesCase = !caseStack.isEmpty
                    if closesCase { caseStack = [] }
                    if previous != nil, previous?.kind != .lparen { newline(at: indent) }
                    write(text, spaceBefore: false)
                }
                currentClause = upper
                // Lista com um item só (`SELECT id`, `SELECT *`) fica na linha da cláusula;
                // com dois ou mais, um por linha.
                let multiItem = SQLFormatter.listClauses.contains(upper) && listHasComma(after: position + phraseLength)
                listModeStack[listModeStack.count - 1] = multiItem
                if multiItem, let next {
                    // SELECT DISTINCT fica na mesma linha; a lista começa depois.
                    if next.upper == "DISTINCT" || next.upper == "ALL" { return }
                    newline(at: indent + 1)
                }
                return
            }

            if SQLFormatter.joins.contains(upper) {
                newline(at: indent + 1)
                write(text, spaceBefore: false)
                return
            }

            switch upper {
            case "AND", "OR":
                if !caseStack.isEmpty || !(parenIsBlock.last ?? true) && !parenIsBlock.isEmpty {
                    write(text, spaceBefore: true)
                } else {
                    newline(at: indent + 1)
                    write(text, spaceBefore: false)
                }
            case "CASE":
                write(text, spaceBefore: needsSpaceBefore())
                caseStack.append(indent + 1)
            case "WHEN", "ELSE":
                if let level = caseStack.last {
                    newline(at: level + 1)
                    write(text, spaceBefore: false)
                } else {
                    write(text, spaceBefore: true)
                }
            case "END":
                if let level = caseStack.popLast() {
                    newline(at: level)
                    write(text, spaceBefore: false)
                } else {
                    write(text, spaceBefore: true)
                }
            case "DISTINCT" where previous.map({ SQLFormatter.listClauses.contains($0.upper) }) ?? false,
                 "ALL" where previous.map({ SQLFormatter.listClauses.contains($0.upper) }) ?? false:
                write(text, spaceBefore: true)
                if listMode { newline(at: indent + 1) }
            default:
                write(text, spaceBefore: needsSpaceBefore())
            }
        }

        private func emitOperator(_ token: Token, next: Token?) {
            let text = token.text
            if text == "::" || text == "->" || text == "->>" {
                out += text
                lineIsEmpty = false
                return
            }
            if text == "*" {
                // Wildcard (`SELECT *`, `count(*)`, `p.*`) sem espaços em volta;
                // multiplicação com espaços.
                let wildcard = previous.map { $0.kind == .lparen || $0.kind == .dot || $0.kind == .comma || SQLFormatter.reserved.contains($0.upper) || SQLFormatter.clauses.contains($0.upper) } ?? true
                write("*", spaceBefore: wildcard ? needsSpaceBefore() : true)
                return
            }
            if text == "-" || text == "+" {
                // Unário: depois de `(`, vírgula, operador ou palavra reservada.
                let unary = previous.map { $0.kind == .lparen || $0.kind == .comma || $0.kind == .op || SQLFormatter.reserved.contains($0.upper) } ?? true
                if unary {
                    write(text, spaceBefore: needsSpaceBefore())
                    return
                }
            }
            write(text, spaceBefore: true)
        }

        /// Espaço antes de um token comum: sim, exceto logo depois de `(`, `.`, `::`,
        /// operador unário ou no começo da linha.
        private func needsSpaceBefore() -> Bool {
            guard let previous, !lineIsEmpty else { return false }
            switch previous.kind {
            case .lparen, .dot: return false
            case .op:
                if previous.text == "::" || previous.text == "->" || previous.text == "->>" { return false }
                // `-1`: o unário acabou de ser escrito sem espaço.
                if (previous.text == "-" || previous.text == "+"), out.last == previous.text.last, out.dropLast().last.map({ $0 == " " || $0 == "(" || $0 == "," }) ?? true { return false }
                return true
            default: return true
            }
        }

        /// Há vírgula no nível 0 antes da próxima cláusula (ou fim do statement)?
        private func listHasComma(after start: Int) -> Bool {
            var depth = 0
            var j = start
            while j < tokens.count {
                let (phrase, consumed) = readPhrase(at: j)
                switch phrase.kind {
                case .lparen: depth += 1
                case .rparen:
                    if depth == 0 { return false }
                    depth -= 1
                case .comma:
                    if depth == 0 { return true }
                case .semicolon:
                    return false
                case .word:
                    if depth == 0, SQLFormatter.clauses.contains(phrase.upper) || SQLFormatter.joins.contains(phrase.upper) { return false }
                    // Um CASE ocupa várias linhas: merece a própria linha mesmo sendo o único item.
                    if depth == 0, phrase.upper == "CASE" { return true }
                default: break
                }
                j += consumed
            }
            return false
        }

        /// `(` abre bloco quando o que vem dentro é uma consulta.
        private func startsBlock(next: Token?) -> Bool {
            guard let next, next.kind == .word else { return false }
            return ["SELECT", "WITH", "WITH RECURSIVE", "VALUES", "INSERT INTO", "UPDATE", "DELETE FROM"].contains(next.upper)
        }
    }
}
