import Foundation
import NIOCore
import os

/// Prefixo de `limit` bytes que não parte um caractere UTF-8 ao meio — cortar no meio de
/// um caractere faria o decode ver bytes inválidos e classificar o texto como blob binário.
/// Usado pelos drivers para truncar valores grandes ANTES de virarem String.
func utf8SafePrefix(_ buffer: ByteBuffer, limit: Int) -> ByteBuffer {
    guard limit > 0, buffer.readableBytes > limit else { return buffer }
    let bytes = buffer.readableBytesView
    let base = bytes.startIndex
    var end = limit

    // Recua até o início do último caractere...
    var start = end
    while start > 0, (bytes[base + start - 1] & 0xC0) == 0x80 { start -= 1 }
    // ...e só o mantém se ele couber inteiro dentro do limite.
    if start > 0 {
        let lead = bytes[base + start - 1]
        let width: Int
        if lead & 0x80 == 0 { width = 1 }
        else if lead & 0xE0 == 0xC0 { width = 2 }
        else if lead & 0xF0 == 0xE0 { width = 3 }
        else if lead & 0xF8 == 0xF0 { width = 4 }
        else { width = 1 }
        if start - 1 + width > end { end = start - 1 }
    }
    return buffer.getSlice(at: buffer.readerIndex, length: end) ?? buffer
}

/// Lote de linhas entregue pelo streaming de resultados.
public struct RowBatch: Sendable {
    public let columns: [String]
    public let rows: [[SQLValue]]

    public init(columns: [String], rows: [[SQLValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// Sinalizador de cancelamento compartilhável com callbacks que rodam fora da Task
/// (o `onRow` do MySQLNIO roda no event loop, onde `Task.isCancelled` é sempre false).
public final class CancelToken: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isCancelled: Bool { state.withLock { $0 } }
    public func cancel() { state.withLock { $0 = true } }
}

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

    /// Para SELECT e comandos que retornam linhas. `previewLimit` corta texto/blob acima
    /// de N na decodificação (ver `SQLValue.truncatedForPreview`): o grid passa um limite,
    /// dump/export/edição passam `nil` e recebem o valor íntegro.
    func query(_ sql: String, previewLimit: Int?) async throws -> QueryResult
    /// Para INSERT/UPDATE/DELETE/DDL. Retorna linhas afetadas.
    func execute(_ sql: String) async throws -> Int

    func fetchRows(table: String, limit: Int, offset: Int) async throws -> QueryResult

    /// Total de linhas da tabela. `allowExactScan: false` obriga a usar as estatísticas do
    /// engine quando a tabela é grande — abrir uma tabela nunca deve esperar um COUNT(*).
    func rowCount(table: String, allowExactScan: Bool) async throws -> RowCountEstimate

    /// Percorre um SELECT entregando lotes de linhas conforme chegam do servidor, sem
    /// materializar o resultado inteiro. `onBatch` roda na thread de I/O do driver e
    /// bloqueá-la é o que dá backpressure natural (o servidor para de mandar enquanto
    /// o dump grava em disco). Lançar de dentro de `onBatch` aborta a leitura.
    func streamQuery(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws

    func quoteIdentifier(_ name: String) -> String
}

public extension DatabaseDriver {
    func quoteIdentifier(_ name: String) -> String {
        engine.quote(name)
    }

    func isSelectStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["select", "with", "show", "pragma", "describe", "explain", "values", "desc"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    func fetchRows(table: String, limit: Int = 500, offset: Int = 0) async throws -> QueryResult {
        try await query("SELECT * FROM \(quoteIdentifier(table)) LIMIT \(limit) OFFSET \(offset)")
    }

    /// Atalho para os chamadores que querem o valor íntegro (dump, export, edição).
    func query(_ sql: String) async throws -> QueryResult {
        try await query(sql, previewLimit: nil)
    }

    /// Fallback para drivers sem streaming nativo: lê tudo e fatia em lotes.
    func streamQuery(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws {
        let result = try await query(sql, previewLimit: previewLimit)
        var index = 0
        repeat {
            let end = min(index + batchSize, result.rows.count)
            try onBatch(RowBatch(columns: result.columns, rows: Array(result.rows[index..<end])))
            index = end
        } while index < result.rows.count
    }

    func streamQuery(
        _ sql: String,
        batchSize: Int,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws {
        try await streamQuery(sql, batchSize: batchSize, previewLimit: nil, onBatch: onBatch)
    }

    /// Contagem exata. Os drivers de MySQL/Postgres sobrescrevem para consultar as
    /// estatísticas do engine quando `allowExactScan` é falso ou a tabela é grande.
    func rowCount(table: String, allowExactScan: Bool) async throws -> RowCountEstimate {
        RowCountEstimate(value: try await countRows(table: table), isEstimate: false)
    }

    // MARK: - Bancos

    /// `CREATE DATABASE` com a sintaxe do engine. SQLite não tem o conceito (um arquivo = um banco).
    func createDatabase(named name: String, charset: String?) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DriverError.queryFailed("Informe um nome para o banco.")
        }
        switch engine {
        case .mysql:
            let encoding = charset?.isEmpty == false ? charset! : "utf8mb4"
            _ = try await execute("CREATE DATABASE \(quoteIdentifier(trimmed)) CHARACTER SET \(encoding)")
        case .postgres:
            // TEMPLATE template0 permite escolher encoding livremente mesmo quando o
            // template1 do servidor está em outro (senão o Postgres recusa com 22023).
            var sql = "CREATE DATABASE \(quoteIdentifier(trimmed))"
            if let charset, !charset.isEmpty {
                sql += " ENCODING '\(charset)' TEMPLATE template0"
            }
            _ = try await execute(sql)
        case .sqlite:
            throw DriverError.queryFailed("SQLite não tem múltiplos bancos: cada arquivo é um banco.")
        }
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
