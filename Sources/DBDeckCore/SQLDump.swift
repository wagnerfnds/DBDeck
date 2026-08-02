import Foundation

public enum SQLDump {
    public static func dump(driver: any DatabaseDriver) async throws -> String {
        let tables = try await driver.tables()
        var output: [String] = []
        output.append("-- DBDeck dump - \(driver.engine.displayName)")
        output.append("-- Gerado em \(Date())")
        output.append("")

        for table in tables where table.kind == "table" {
            let columns = try await driver.columns(table: table.name)
            guard !columns.isEmpty else { continue }
            output.append(createTable(driver: driver, table: table.name, columns: columns))
            output.append("")

            var offset = 0
            let pageSize = 500
            while true {
                let result = try await driver.fetchRows(table: table.name, limit: pageSize, offset: offset)
                guard !result.rows.isEmpty else { break }
                appendInserts(driver: driver, table: table.name, columns: columns.map(\.name), result: result, output: &output)
                if result.rows.count < pageSize { break }
                offset += pageSize
            }
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    public static func importSQL(_ sql: String, driver: any DatabaseDriver) async throws -> (statements: Int, errors: [String]) {
        var errors: [String] = []
        var count = 0
        for statement in splitStatements(sql) {
            do {
                _ = try await driver.execute(statement)
                count += 1
            } catch {
                errors.append("\(statement.prefix(80))…\n  → \(error.localizedDescription)")
            }
        }
        return (count, errors)
    }

    // MARK: - Helpers

    private static func createTable(driver: any DatabaseDriver, table: String, columns: [DatabaseColumn]) -> String {
        var parts: [String] = []
        let pkColumns = columns.filter(\.isPrimaryKey).map(\.name)
        for column in columns {
            var part = "\(driver.quoteIdentifier(column.name)) \(column.type)"
            if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
                part += " DEFAULT \(defaultValue)"
            }
            if !column.isNullable && !column.isPrimaryKey {
                part += " NOT NULL"
            }
            parts.append(part)
        }
        if !pkColumns.isEmpty {
            let pk = pkColumns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pk))")
        }
        return "CREATE TABLE \(driver.quoteIdentifier(table)) (\n  \(parts.joined(separator: ",\n  "))\n);"
    }

    private static func appendInserts(
        driver: any DatabaseDriver,
        table: String,
        columns: [String],
        result: QueryResult,
        output: inout [String]
    ) {
        let colList = columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        var valuesChunks: [String] = []
        var currentChunk: [String] = []
        var chunkSize = 0
        for row in result.rows {
            var values: [String] = []
            for i in columns.indices {
                let value = i < row.count ? row[i] : .null
                if case .blob(let data) = value, data.isEmpty {
                    values.append("NULL")
                } else {
                    values.append(value.sqlLiteral(engine: driver.engine))
                }
            }
            currentChunk.append("(\(values.joined(separator: ", ")))")
            chunkSize += 1
            if chunkSize >= 200 {
                valuesChunks.append(currentChunk.joined(separator: ",\n"))
                currentChunk = []
                chunkSize = 0
            }
        }
        if !currentChunk.isEmpty {
            valuesChunks.append(currentChunk.joined(separator: ",\n"))
        }
        for chunk in valuesChunks {
            output.append("INSERT INTO \(driver.quoteIdentifier(table)) (\(colList)) VALUES\n\(chunk);")
        }
    }

    /// Divide SQL em statements respeitando aspas simples, duplas, crases e comentários.
    public static func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var quote: Character?
        var lineComment = false
        var blockComment = false
        var index = sql.startIndex

        func append(_ c: Character) { current.append(c) }

        while index < sql.endIndex {
            let c = sql[index]
            let next = sql.index(after: index)
            let nextChar = next < sql.endIndex ? sql[next] : nil

            if lineComment {
                append(c)
                if c == "\n" { lineComment = false }
                index = next
                continue
            }
            if blockComment {
                append(c)
                if c == "*", nextChar == "/" {
                    append("/")
                    index = sql.index(after: next)
                    blockComment = false
                    continue
                }
                index = next
                continue
            }
            if let q = quote {
                append(c)
                if c == q {
                    if nextChar == q {
                        append(q)
                        index = sql.index(after: next)
                        continue
                    }
                    quote = nil
                }
                index = next
                continue
            }
            switch c {
            case "-":
                if nextChar == "-" {
                    lineComment = true
                    append(c)
                } else {
                    append(c)
                }
            case "/":
                if nextChar == "*" {
                    blockComment = true
                    append(c)
                } else {
                    append(c)
                }
            case "'", "\"", "`":
                quote = c
                append(c)
            case ";":
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    statements.append(trimmed)
                }
                current = ""
            default:
                append(c)
            }
            index = next
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            statements.append(trimmed)
        }
        return statements
    }
}

public enum CSVExporter {
    public static func export(result: QueryResult, fileName: String) -> String {
        var lines: [String] = []
        lines.append(result.columns.map { escapeCSV($0) }.joined(separator: ","))
        for row in result.rows {
            var values: [String] = []
            for i in result.columns.indices {
                let value = i < row.count ? row[i].display : ""
                values.append(escapeCSV(value))
            }
            lines.append(values.joined(separator: ","))
        }
        // BOM para o Excel abrir UTF-8 corretamente
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
