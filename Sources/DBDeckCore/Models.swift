import Foundation

// MARK: - Engines

public enum SQLEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres
    case mysql
    case sqlite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        }
    }

    public var symbol: String {
        switch self {
        case .postgres: "server.rack"
        case .mysql: "cylinder.split.1x2"
        case .sqlite: "externaldrive.connected.to.line.below"
        }
    }

    /// Delimita um identificador (tabela/coluna) na sintaxe do engine, dobrando o
    /// delimitador que apareça no nome.
    public func quote(_ name: String) -> String {
        switch self {
        case .mysql:
            return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        case .postgres, .sqlite:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }
}

// MARK: - Config

public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var engine: SQLEngine
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String
    public var sqlitePath: String
    public var useTLS: Bool
    /// Rótulo de cor (ex.: "red", "green") para identificação visual. Opcional (compatível com JSON antigo).
    public var color: String?
    /// Bancos do servidor memorizados após a primeira listagem. Opcional.
    public var cachedDatabases: [String]?
    /// Túnel SSH. Opcional para os JSONs gravados antes do recurso continuarem decodificando.
    public var ssh: SSHConfig?

    public init(
        id: UUID = UUID(),
        name: String = "Nova conexão",
        engine: SQLEngine = .postgres,
        host: String = "localhost",
        port: Int = 5432,
        username: String = "",
        password: String = "",
        database: String = "",
        sqlitePath: String = "",
        useTLS: Bool = false,
        color: String? = nil,
        cachedDatabases: [String]? = nil,
        ssh: SSHConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.sqlitePath = sqlitePath
        self.useTLS = useTLS
        self.color = color
        self.cachedDatabases = cachedDatabases
        self.ssh = ssh
    }

    public var databasesCache: [String] { cachedDatabases ?? [] }

    public var sshConfig: SSHConfig { ssh ?? SSHConfig() }

    /// SQLite é arquivo local: não há porta para encaminhar.
    public var usesSSHTunnel: Bool { engine != .sqlite && sshConfig.enabled }

    public var displaySubtitle: String {
        switch engine {
        case .sqlite:
            return sqlitePath.isEmpty ? "sem arquivo" : sqlitePath
        default:
            let target = "\(host):\(port)/\(database)"
            // O túnel é o que explica um "localhost" que na verdade é um servidor remoto.
            return usesSSHTunnel ? "\(target) via ssh \(sshConfig.host)" : target
        }
    }
}

public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var connections: [ConnectionConfig]

    public init(id: UUID = UUID(), name: String = "Novo workspace", connections: [ConnectionConfig] = []) {
        self.id = id
        self.name = name
        self.connections = connections
    }
}

// MARK: - Values

public enum SQLValue: Sendable, Equatable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case text(String)
    case blob(Data)
    /// Valor grande cortado NA ORIGEM: só o prefixo saiu do buffer da rede.
    /// O grid mostra ~200 caracteres numa célula de 160 px — materializar um TEXT/JSON
    /// de megabytes por linha era o que fazia a página inteira custar centenas de MB de
    /// String. `byteCount` é o tamanho real no servidor; `isBinary` separa BLOB de TEXT.
    /// Quem precisa do valor íntegro (editar, exportar, copiar como INSERT) recarrega a
    /// célula sob demanda — é o equivalente ao `asPreview:NO` do Sequel Ace.
    case truncated(prefix: String, byteCount: Int, isBinary: Bool)

    /// `true` quando o valor é só um prefixo — nunca pode ser gravado de volta nem exportado.
    public var isTruncated: Bool {
        if case .truncated = self { return true }
        return false
    }

    public var display: String {
        switch self {
        case .null: return ""
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .text(let v): return v
        case .blob: return "‹blob›"
        case .truncated(let prefix, let byteCount, let isBinary):
            return isBinary ? "‹blob \(Self.byteLabel(byteCount))›" : prefix + "…"
        }
    }

    /// Texto para desenhar numa célula do grid. Nunca devolve mais que
    /// `cellDisplayLimit` caracteres: mandar uma String de megabytes para um
    /// `NSTextField` faz o AppKit medir o texto inteiro para desenhar 160 px dele.
    /// Complementa o corte no driver — vale também para resultados do console SQL,
    /// que mantém os valores íntegros de propósito.
    public var cellDisplay: String {
        guard case .text(let value) = self else { return display }
        guard value.utf8.count > Self.cellDisplayLimit else { return value }
        let head = String(value.prefix(Self.cellDisplayLimit))
        return head.utf8.count < value.utf8.count ? head + "…" : value
    }

    private static let cellDisplayLimit = 300

    private static func byteLabel(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }

    /// Corta um valor recém-decodificado para exibição. `limit` em caracteres para texto
    /// e em bytes para blob; `nil` devolve o valor íntegro (dump, export, edição).
    public func truncatedForPreview(limit: Int?) -> SQLValue {
        guard let limit else { return self }
        switch self {
        case .text(let value):
            // `utf8.count` não percorre a string inteira quando ela é nativa, e o
            // `prefix` só materializa o que sobra — o custo fica O(limit), não O(valor).
            guard value.utf8.count > limit else { return self }
            // `prefix` conta Characters e o gate acima conta bytes: em texto multibyte o
            // prefixo pode ser a string inteira — aí não há nada a truncar.
            let head = String(value.prefix(limit))
            guard head.utf8.count < value.utf8.count else { return self }
            return .truncated(prefix: head, byteCount: value.utf8.count, isBinary: false)
        case .blob(let data):
            guard data.count > limit else { return self }
            return .truncated(prefix: "", byteCount: data.count, isBinary: true)
        default:
            return self
        }
    }

    public func sqlLiteral(engine: SQLEngine) -> String {
        var out = ""
        appendSQLLiteral(engine: engine, to: &out)
        return out
    }

    /// Escreve o literal direto num buffer. Dumps grandes chamam isto milhões de vezes:
    /// `sqlLiteral` devolvendo String nova por valor (mais `replacingOccurrences` e
    /// `map/joined` no hex) dominava o tempo de CPU da exportação.
    public func appendSQLLiteral(engine: SQLEngine, to out: inout String) {
        switch self {
        case .null:
            out += "NULL"
        case .int(let v):
            out += String(v)
        case .double(let v):
            out += String(v)
        case .bool(let v):
            out += v ? "TRUE" : "FALSE"
        case .text(let v):
            out += "'"
            Self.appendEscaped(v, engine: engine, to: &out)
            out += "'"
        case .blob(let data):
            switch engine {
            case .postgres:
                out += "decode('"
                Self.appendHex(data, to: &out)
                out += "', 'hex')"
            case .mysql, .sqlite:
                out += "X'"
                Self.appendHex(data, to: &out)
                out += "'"
            }
        case .truncated:
            // Inalcançável em caminhos de escrita: dump/export/edição sempre pedem o
            // valor íntegro (previewLimit nil) ou recarregam a célula antes. O default
            // é `DEFAULT` em vez do prefixo — melhor o banco recusar do que gravar
            // silenciosamente um valor cortado por cima do original.
            out += "DEFAULT"
        }
    }

    /// Escapa o conteúdo de um literal de texto (sem as aspas externas).
    /// No MySQL a barra invertida É um escape (sem `NO_BACKSLASH_ESCAPES`): dobrar só a
    /// aspa simples corrompia qualquer valor com `\` (caminhos, regex, JSON) no re-import.
    /// Em Postgres/SQLite (`standard_conforming_strings`) a barra é literal e não se toca.
    private static func appendEscaped(_ value: String, engine: SQLEngine, to out: inout String) {
        let isMySQL = engine == .mysql
        let needsEscape = value.utf8.contains { byte in
            byte == 0x27 || (isMySQL && (byte == 0x5C || byte == 0x00 || byte == 0x1A))
        }
        // Caminho rápido: nada a escapar, copia a string inteira de uma vez.
        guard needsEscape else {
            out += value
            return
        }
        for scalar in value.unicodeScalars {
            switch scalar {
            case "'": out += "''"
            case "\\" where isMySQL: out += "\\\\"
            case "\0" where isMySQL: out += "\\0"
            case "\u{1A}" where isMySQL: out += "\\Z"
            default: out.unicodeScalars.append(scalar)
            }
        }
    }

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private static func appendHex(_ data: Data, to out: inout String) {
        out.reserveCapacity(out.count + data.count * 2)
        for byte in data {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
    }
}

// MARK: - Metadata

public struct DatabaseTable: Identifiable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var id: String { name }
}

public struct DatabaseColumn: Identifiable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var defaultValue: String?
    public var ordinal: Int
    /// Coluna calculada pelo banco (`GENERATED ALWAYS AS ...`). Nunca entra em INSERT:
    /// o servidor recusa valores para ela (ERROR 3105 no MySQL) — o dump precisa
    /// deixá-la de fora, como o mysqldump faz.
    public var isGenerated: Bool = false
    public var id: String { name }

    /// Colunas cujo conteúdo pode ser arbitrariamente grande. São as candidatas a não
    /// serem pedidas no SELECT do grid (equivalente ao `columnIsBlobOrText` do Sequel Ace).
    public var isBlobOrText: Bool {
        let type = type.lowercased()
        if type.contains("varchar") || type.contains("varying") { return false }
        return ["text", "blob", "json", "jsonb", "bytea", "clob", "xml", "geometry"]
            .contains { type.contains($0) }
    }
}

/// Total de linhas de uma tabela. `isEstimate` marca o número vindo das estatísticas do
/// engine (instantâneo) em vez de um `COUNT(*)` — que em InnoDB/Postgres com milhões de
/// linhas é varredura completa e travava a abertura da tabela por segundos.
public struct RowCountEstimate: Sendable, Equatable {
    /// Negativo quando o engine não sabe estimar (ex.: tabela Postgres nunca analisada)
    /// e a contagem exata seria cara demais — a UI omite o total nesse caso.
    public var value: Int
    public var isEstimate: Bool

    public var isKnown: Bool { value >= 0 }

    public static let unknown = RowCountEstimate(value: -1, isEstimate: true)

    public init(value: Int, isEstimate: Bool) {
        self.value = value
        self.isEstimate = isEstimate
    }
}

public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[SQLValue]]
    public var affectedRows: Int?

    public init(columns: [String], rows: [[SQLValue]], affectedRows: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
    }
}

// MARK: - Errors

public enum DriverError: LocalizedError {
    case notConnected
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Não conectado."
        case .queryFailed(let message):
            return message
        }
    }
}
