import Foundation

public protocol DatabaseDriver: Sendable {
    var engine: SQLEngine { get }
    var isConnected: Bool { get }

    func connect() async throws
    func disconnect() async

    /// Bancos disponíveis (Postgres). MySQL retorna apenas o atual, SQLite lista vazio.
    func databases() async throws -> [String]
    func tables() async throws -> [DatabaseTable]
    func columns(table: String) async throws -> [DatabaseColumn]
    func primaryKeys(table: String) async throws -> [String]

    /// Para SELECT e comandos que retornam linhas.
    func query(_ sql: String) async throws -> QueryResult
    /// Para INSERT/UPDATE/DELETE/DDL. Retorna linhas afetadas.
    func execute(_ sql: String) async throws -> Int

    func fetchRows(table: String, limit: Int, offset: Int) async throws -> QueryResult

    func quoteIdentifier(_ name: String) -> String
}

public extension DatabaseDriver {
    func quoteIdentifier(_ name: String) -> String {
        switch engine {
        case .mysql:
            return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        case .postgres, .sqlite:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    func isSelectStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["select", "with", "show", "pragma", "describe", "explain", "values", "desc"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    func fetchRows(table: String, limit: Int = 500, offset: Int = 0) async throws -> QueryResult {
        try await query("SELECT * FROM \(quoteIdentifier(table)) LIMIT \(limit) OFFSET \(offset)")
    }

    func countRows(table: String) async throws -> Int {
        let result = try await query("SELECT COUNT(*) FROM \(quoteIdentifier(table))")
        guard let first = result.rows.first?.first else { return 0 }
        switch first {
        case .int(let v): return Int(v)
        case .text(let v): return Int(v) ?? 0
        default: return 0
        }
    }

    // MARK: - Edição genérica (baseada em PK)

    func updateRow(
        table: String,
        primaryKey: [String],
        pkValues: [SQLValue],
        changes: [(column: String, value: SQLValue)]
    ) async throws -> Int {
        guard primaryKey.count == pkValues.count, !changes.isEmpty else { return 0 }
        var setClauses: [String] = []
        for change in changes {
            setClauses.append("\(quoteIdentifier(change.column)) = \(change.value.sqlLiteral(engine: engine))")
        }
        var whereClauses: [String] = []
        for (i, col) in primaryKey.enumerated() {
            let value = pkValues[i]
            if case .null = value {
                whereClauses.append("\(quoteIdentifier(col)) IS NULL")
            } else {
                whereClauses.append("\(quoteIdentifier(col)) = \(value.sqlLiteral(engine: engine))")
            }
        }
        let sql = "UPDATE \(quoteIdentifier(table)) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClauses.joined(separator: " AND "))"
        return try await execute(sql)
    }

    func insertRow(table: String, values: [(column: String, value: SQLValue)]) async throws -> Int {
        guard !values.isEmpty else { return 0 }
        let cols = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let vals = values.map { $0.value.sqlLiteral(engine: engine) }.joined(separator: ", ")
        let sql = "INSERT INTO \(quoteIdentifier(table)) (\(cols)) VALUES (\(vals))"
        return try await execute(sql)
    }

    func deleteRow(table: String, primaryKey: [String], pkValues: [SQLValue]) async throws -> Int {
        guard primaryKey.count == pkValues.count else { return 0 }
        var whereClauses: [String] = []
        for (i, col) in primaryKey.enumerated() {
            let value = pkValues[i]
            if case .null = value {
                whereClauses.append("\(quoteIdentifier(col)) IS NULL")
            } else {
                whereClauses.append("\(quoteIdentifier(col)) = \(value.sqlLiteral(engine: engine))")
            }
        }
        let sql = "DELETE FROM \(quoteIdentifier(table)) WHERE \(whereClauses.joined(separator: " AND "))"
        return try await execute(sql)
    }
}
