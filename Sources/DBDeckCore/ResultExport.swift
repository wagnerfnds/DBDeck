import Foundation

/// Formatos de exportação de dados (tabela ou resultado de consulta), no espírito do
/// Sequel Ace: SQL (INSERTs prontos para re-importar), CSV (planilha) e JSON (integração).
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case json
    case sql

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sql: "SQL"
        }
    }

    public var fileExtension: String { rawValue }
}

/// Gera exportações a partir de linhas já em memória (página atual, resultado de
/// consulta) ou de uma tabela inteira em streaming — nunca materializando a tabela.
public enum ResultExporter {
    // MARK: - Em memória

    public static func export(
        format: ExportFormat,
        columns: [String],
        rows: [[SQLValue]],
        tableName: String,
        engine: SQLEngine
    ) -> String {
        var out = ""
        var writer = makeWriter(format: format, columns: columns, tableName: tableName, engine: engine)
        writer.begin(&out)
        writer.append(rows: rows, to: &out)
        writer.end(&out)
        return out
    }

    // MARK: - Tabela inteira (streaming)

    /// Exporta a tabela completa lendo em lotes com valores ÍNTEGROS (sem o corte de
    /// preview do grid). `write` roda na thread de I/O do driver — gravar no arquivo
    /// ali mesmo é o que dá backpressure natural, como no dump.
    /// Devolve o total de linhas exportadas.
    @discardableResult
    public static func exportTable(
        driver: any DatabaseDriver,
        table: String,
        format: ExportFormat,
        batchSize: Int = 2_000,
        cancel: CancelToken? = nil,
        write: @escaping @Sendable (String) throws -> Void,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        let engine = driver.engine
        let sql = "SELECT * FROM \(driver.quoteIdentifier(table))"

        final class State: @unchecked Sendable {
            var writer: ExportWriter?
            var total = 0
        }
        let state = State()

        try await driver.streamQuery(sql, batchSize: batchSize, previewLimit: nil) { batch in
            if cancel?.isCancelled == true { throw DumpError.cancelled }
            var chunk = ""
            if state.writer == nil {
                var writer = makeWriter(
                    format: format, columns: batch.columns, tableName: table, engine: engine
                )
                writer.begin(&chunk)
                state.writer = writer
            }
            state.writer?.append(rows: batch.rows, to: &chunk)
            state.total += batch.rows.count
            try write(chunk)
            progress(state.total)
        }

        var tail = ""
        if state.writer == nil {
            // Tabela vazia: ainda assim emite um arquivo válido (header/colchetes).
            var writer = makeWriter(
                format: format,
                columns: (try? await driver.columns(table: table).map(\.name)) ?? [],
                tableName: table,
                engine: engine
            )
            writer.begin(&tail)
            writer.end(&tail)
        } else {
            state.writer?.end(&tail)
        }
        if !tail.isEmpty { try write(tail) }
        return state.total
    }

    private static func makeWriter(
        format: ExportFormat, columns: [String], tableName: String, engine: SQLEngine
    ) -> ExportWriter {
        switch format {
        case .csv: CSVWriter(columns: columns)
        case .json: JSONWriter(columns: columns)
        case .sql: SQLInsertWriter(columns: columns, tableName: tableName, engine: engine)
        }
    }
}

// MARK: - Writers incrementais

/// Um formato = um writer com header, lotes de linhas e rodapé — a mesma interface
/// serve a string em memória e o arquivo em streaming.
private protocol ExportWriter {
    mutating func begin(_ out: inout String)
    mutating func append(rows: [[SQLValue]], to out: inout String)
    mutating func end(_ out: inout String)
}

// MARK: CSV

private struct CSVWriter: ExportWriter {
    let columns: [String]

    func begin(_ out: inout String) {
        // BOM para o Excel abrir UTF-8 corretamente.
        out += "\u{FEFF}"
        out += columns.map(Self.escape).joined(separator: ",")
        out += "\r\n"
    }

    func append(rows: [[SQLValue]], to out: inout String) {
        for row in rows {
            for index in columns.indices {
                if index > 0 { out += "," }
                let value = index < row.count ? row[index] : .null
                out += Self.escape(value.display)
            }
            out += "\r\n"
        }
    }

    func end(_ out: inout String) {}

    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

// MARK: JSON

private struct JSONWriter: ExportWriter {
    let columns: [String]
    private var wroteRow = false
    /// Chaves já escapadas uma vez — o escape por linha × coluna dominaria o custo.
    private var escapedKeys: [String] = []

    init(columns: [String]) {
        self.columns = columns
        escapedKeys = columns.map { Self.escapeString($0) }
    }

    func begin(_ out: inout String) {
        out += "[\n"
    }

    mutating func append(rows: [[SQLValue]], to out: inout String) {
        for row in rows {
            if wroteRow { out += ",\n" }
            wroteRow = true
            out += "  {"
            for index in columns.indices {
                if index > 0 { out += ", " }
                out += escapedKeys[index]
                out += ": "
                Self.appendJSONValue(index < row.count ? row[index] : .null, to: &out)
            }
            out += "}"
        }
    }

    func end(_ out: inout String) {
        out += wroteRow ? "\n]\n" : "]\n"
    }

    /// Valores com o tipo nativo do JSON: números como números, bool como bool,
    /// NULL como null. Binário vira base64 (o JSON não tem tipo binário).
    static func appendJSONValue(_ value: SQLValue, to out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .int(let number):
            out += String(number)
        case .double(let number):
            // JSON não representa não-finitos; null é o que um consumidor espera.
            out += number.isFinite ? String(number) : "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .text(let text):
            out += escapeString(text)
        case .blob(let data):
            out += escapeString(data.base64EncodedString())
        case .truncated:
            // Exportações usam valores íntegros; se um prefixo escapar, melhor o texto
            // visível do que dado que PARECE completo.
            out += escapeString(value.display)
        }
    }

    static func escapeString(_ value: String) -> String {
        var out = "\""
        out.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

// MARK: SQL (INSERTs)

private struct SQLInsertWriter: ExportWriter {
    let columns: [String]
    let tableName: String
    let engine: SQLEngine
    /// Teto por statement — 1 MB fica bem abaixo do max_allowed_packet padrão.
    let maxStatementBytes = 1_000_000

    private var prefix = ""
    private var rowsInStatement = 0
    /// Bytes do statement CORRENTE — `out` acumula statements anteriores (e, no modo
    /// em memória, o arquivo inteiro), então medir `out` fecharia statements errados.
    private var statementBytes = 0

    init(columns: [String], tableName: String, engine: SQLEngine) {
        self.columns = columns
        self.tableName = tableName
        self.engine = engine
        let columnList = columns.map { engine.quote($0) }.joined(separator: ", ")
        prefix = "INSERT INTO \(engine.quote(tableName)) (\(columnList)) VALUES\n"
    }

    func begin(_ out: inout String) {
        out += "-- DBDeck export — \(engine.displayName)\n\n"
    }

    mutating func append(rows: [[SQLValue]], to out: inout String) {
        for row in rows {
            let before = out.utf8.count
            out += rowsInStatement == 0 ? prefix : ",\n"
            out += "("
            for index in columns.indices {
                if index > 0 { out += "," }
                let value = index < row.count ? row[index] : .null
                // Blob vazio vira NULL: `X''` não é literal válido no MySQL.
                if case .blob(let data) = value, data.isEmpty {
                    out += "NULL"
                } else {
                    value.appendSQLLiteral(engine: engine, to: &out)
                }
            }
            out += ")"
            rowsInStatement += 1
            statementBytes += out.utf8.count - before
            if statementBytes >= maxStatementBytes {
                out += ";\n"
                rowsInStatement = 0
                statementBytes = 0
            }
        }
    }

    mutating func end(_ out: inout String) {
        if rowsInStatement > 0 {
            out += ";\n"
            rowsInStatement = 0
            statementBytes = 0
        }
    }
}
