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
        useTLS: Bool = false
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
    }

    public var displaySubtitle: String {
        switch engine {
        case .sqlite:
            return sqlitePath.isEmpty ? "sem arquivo" : sqlitePath
        default:
            return "\(host):\(port)/\(database)"
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

    public var display: String {
        switch self {
        case .null: return ""
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .text(let v): return v
        case .blob: return "‹blob›"
        }
    }

    public func sqlLiteral(engine: SQLEngine) -> String {
        switch self {
        case .null:
            return "NULL"
        case .int(let v):
            return String(v)
        case .double(let v):
            return String(v)
        case .bool(let v):
            return v ? "TRUE" : "FALSE"
        case .text(let v):
            let escaped = v.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        case .blob(let data):
            let hex = data.map { String(format: "%02X", $0) }.joined()
            switch engine {
            case .postgres:
                return "decode('\(hex)', 'hex')"
            case .mysql, .sqlite:
                return "X'\(hex)'"
            }
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
    public var id: String { name }
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
