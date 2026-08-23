import Foundation
import SQLite3

public final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: SQLEngine = .sqlite

    private let config: ConnectionConfig
    private let queue = DispatchQueue(label: "dbdeck.sqlite.\(UUID().uuidString)")
    private var db: OpaquePointer?

    public init(config: ConnectionConfig) {
        self.config = config
    }

    public var isConnected: Bool {
        queue.sync { db != nil }
    }

    public func connect() async throws {
        let path = config.sqlitePath
        guard !path.isEmpty else {
            throw DriverError.queryFailed("Caminho do arquivo SQLite vazio.")
        }
        var handle: OpaquePointer?
        let code = sqlite3_open(path, &handle)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Falha ao abrir \(path)"
            if let handle { sqlite3_close(handle) }
            throw DriverError.queryFailed(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        queue.sync { db = handle }
        _ = try? await execute("PRAGMA foreign_keys = ON")
    }

    public func disconnect() async {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    public func databases() async throws -> [String] {
        []
    }

    public func tables() async throws -> [DatabaseTable] {
        let result = try await query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        return result.rows.map { row in
            DatabaseTable(
                name: row.first?.display ?? "",
                kind: row.count > 1 ? row[1].display : "table"
            )
        }
    }

    public func columns(table: String) async throws -> [DatabaseColumn] {
        let safeName = table.replacingOccurrences(of: "\"", with: "\"\"")
        // `table_xinfo` (não `table_info`): a coluna `hidden` marca as geradas
        // (2 = VIRTUAL, 3 = STORED) — o dump precisa deixá-las fora dos INSERTs.
        let result = try await query("PRAGMA table_xinfo(\"\(safeName)\")")
        return result.rows.compactMap { row in
            let hidden = row.count > 6 ? (Int(row[6].display) ?? 0) : 0
            // 1 = coluna oculta de verdade (rowid alias etc.) — não aparece no SELECT *.
            guard hidden != 1 else { return nil }
            return DatabaseColumn(
                name: row.count > 1 ? row[1].display : "",
                type: row.count > 2 ? row[2].display : "",
                isNullable: row.count > 3 ? row[3].display == "0" : true,
                isPrimaryKey: row.count > 5 ? row[5].display != "0" : false,
                defaultValue: row.count > 4 && !row[4].display.isEmpty ? row[4].display : nil,
                ordinal: row.count > 0 ? (Int(row[0].display) ?? 0) : 0,
                isGenerated: hidden == 2 || hidden == 3
            )
        }
    }

    public func primaryKeys(table: String) async throws -> [String] {
        try await columns(table: table).filter(\.isPrimaryKey).map(\.name)
    }

    public func query(_ sql: String, previewLimit: Int?) async throws -> QueryResult {
        try queue.sync {
            var columns: [String] = []
            var rows: [[SQLValue]] = []
            try step(sql, batchSize: .max, previewLimit: previewLimit) { batch in
                columns = batch.columns
                rows.append(contentsOf: batch.rows)
            }
            return QueryResult(columns: columns, rows: rows)
        }
    }

    public func streamQuery(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws {
        try queue.sync {
            try step(sql, batchSize: batchSize, previewLimit: previewLimit, onBatch: onBatch)
        }
    }

    /// Percorre o statement entregando lotes. Precisa ser chamado dentro de `queue.sync`.
    private func step(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: (RowBatch) throws -> Void
    ) throws {
        guard let db else { throw DriverError.notConnected }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DriverError.queryFailed(lastError(db))
        }
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        var rows: [[SQLValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            if columns.isEmpty {
                columns = (0..<count).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
            }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(count))
            for i in 0..<count {
                let index = Int32(i)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL:
                    row.append(.null)
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        // O corte é feito NOS BYTES do SQLite: `String(cString:)` de um
                        // TEXT de megabytes é a alocação que se quer evitar no grid.
                        let byteCount = Int(sqlite3_column_bytes(statement, index))
                        if let previewLimit, byteCount > previewLimit {
                            let head = Data(bytes: text, count: previewLimit)
                            let prefix = String(data: Self.utf8SafePrefix(head), encoding: .utf8) ?? ""
                            row.append(.truncated(prefix: prefix, byteCount: byteCount, isBinary: false))
                        } else {
                            row.append(.text(String(cString: text)))
                        }
                    } else {
                        row.append(.null)
                    }
                case SQLITE_BLOB:
                    if let blob = sqlite3_column_blob(statement, index) {
                        let bytes = Int(sqlite3_column_bytes(statement, index))
                        if let previewLimit, bytes > previewLimit {
                            row.append(.truncated(prefix: "", byteCount: bytes, isBinary: true))
                        } else {
                            row.append(.blob(Data(bytes: blob, count: bytes)))
                        }
                    } else {
                        row.append(.null)
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
            if rows.count >= batchSize {
                try onBatch(RowBatch(columns: columns, rows: rows))
                rows.removeAll(keepingCapacity: true)
            }
        }
        // Sempre entrega o último lote, mesmo vazio: quem chama usa as colunas dele.
        try onBatch(RowBatch(columns: columns, rows: rows))
    }

    public func execute(_ sql: String) async throws -> Int {
        try queue.sync {
            guard let db else { throw DriverError.notConnected }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw DriverError.queryFailed(lastError(db))
            }
            return Int(sqlite3_changes(db))
        }
    }

    private func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    /// Descarta os bytes finais que formariam um caractere UTF-8 incompleto — o corte
    /// cru no meio de um caractere faria `String(data:encoding:.utf8)` devolver nil.
    private static func utf8SafePrefix(_ data: Data) -> Data {
        var end = data.count
        while end > 0, (data[data.startIndex + end - 1] & 0xC0) == 0x80 { end -= 1 }
        guard end > 0 else { return Data() }
        let lead = data[data.startIndex + end - 1]
        let width: Int
        if lead & 0x80 == 0 { width = 1 }
        else if lead & 0xE0 == 0xC0 { width = 2 }
        else if lead & 0xF0 == 0xE0 { width = 3 }
        else if lead & 0xF8 == 0xF0 { width = 4 }
        else { width = 1 }
        if end - 1 + width > data.count { end -= 1 }
        return data.prefix(end)
    }
}
