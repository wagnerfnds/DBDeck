import Foundation

public enum SQLDump {
    // MARK: - Dump

    public static func dump(driver: any DatabaseDriver) async throws -> String {
        let tables = try await driver.tables()
        var output: [String] = []
        output.append("-- DBDeck dump - \(driver.engine.displayName)")
        output.append("-- Gerado em \(Date())")
        output.append("")

        // 1. DDL
        switch driver.engine {
        case .postgres:
            for table in tables where table.kind == "table" {
                let columns = try await driver.columns(table: table.name)
                guard !columns.isEmpty else { continue }
                output.append(createTablePostgres(driver: driver, table: table.name, columns: columns))
                output.append("")
            }
            for sequence in try await postgresSequences(driver: driver) {
                output.append("CREATE SEQUENCE IF NOT EXISTS \(driver.quoteIdentifier(sequence));")
                output.append("SELECT setval('\(driver.quoteIdentifier(sequence))', last_value, is_called) FROM \(driver.quoteIdentifier(sequence));")
                output.append("")
            }
            for view in tables where view.kind == "view" {
                output.append(await createViewPostgres(driver: driver, view: view.name))
                output.append("")
            }
        case .mysql:
            for table in tables {
                let ddl = try await querySingleValue(driver: driver, sql: "SHOW CREATE \(table.kind == "view" ? "VIEW" : "TABLE") `\(table.name)`")
                if let ddl {
                    output.append(ddl.hasSuffix(";") ? ddl : ddl + ";")
                    output.append("")
                }
            }
        case .sqlite:
            for entry in try await sqliteSchema(driver: driver) {
                output.append(entry)
                output.append("")
            }
        }

        // 2. Dados (apenas tabelas)
        for table in tables where table.kind == "table" {
            let columns = try await driver.columns(table: table.name)
            guard !columns.isEmpty else { continue }
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

        // 3. Foreign keys no Postgres (criadas por último para não bloquear os INSERTs)
        if driver.engine == .postgres {
            output.append(contentsOf: try await postgresForeignKeys(driver: driver))
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Import

    public static func importSQL(_ sql: String, driver: any DatabaseDriver) async throws -> (statements: Int, errors: [String]) {
        var errors: [String] = []
        var count = 0
        try? await setForeignKeyChecks(false, driver: driver)
        for statement in splitStatements(sql) {
            do {
                _ = try await driver.execute(statement)
                count += 1
            } catch {
                errors.append("\(statement.prefix(80))…\n  → \(error.localizedDescription)")
            }
        }
        try? await setForeignKeyChecks(true, driver: driver)
        return (count, errors)
    }

    private static func setForeignKeyChecks(_ enabled: Bool, driver: any DatabaseDriver) async throws {
        switch driver.engine {
        case .sqlite:
            _ = try await driver.execute(enabled ? "PRAGMA foreign_keys = ON" : "PRAGMA foreign_keys = OFF")
        case .mysql:
            _ = try await driver.execute(enabled ? "SET FOREIGN_KEY_CHECKS = 1" : "SET FOREIGN_KEY_CHECKS = 0")
        case .postgres:
            break
        }
    }

    // MARK: - Helpers

    private static func createTablePostgres(driver: any DatabaseDriver, table: String, columns: [DatabaseColumn]) -> String {
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

    private static func createViewPostgres(driver: any DatabaseDriver, view: String) async -> String {
        let safeName = view.replacingOccurrences(of: "'", with: "''")
        let definition = try? await querySingleValue(
            driver: driver,
            sql: "SELECT pg_get_viewdef('\(safeName)'::regclass, true)"
        )
        let body = definition ?? "-- falha ao obter definição"
        return "CREATE VIEW \(driver.quoteIdentifier(view)) AS \(body);"
    }

    private static func postgresSequences(driver: any DatabaseDriver) async throws -> [String] {
        let result = try await driver.query(
            """
            SELECT c.relname
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema() AND c.relkind = 'S'
            ORDER BY c.relname
            """
        )
        return result.rows.compactMap { row in
            if case .text(let name) = row.first { return name }
            return nil
        }
    }

    private static func postgresForeignKeys(driver: any DatabaseDriver) async throws -> [String] {
        let result = try await driver.query(
            """
            SELECT
              tc.table_name,
              kcu.column_name,
              ccu.table_name AS foreign_table,
              ccu.column_name AS foreign_column,
              rc.delete_rule,
              rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema
            JOIN information_schema.referential_constraints rc
              ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.constraint_schema
            JOIN information_schema.constraint_column_usage ccu
              ON ccu.constraint_name = rc.unique_constraint_name AND ccu.constraint_schema = rc.constraint_schema
            WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = current_schema()
            ORDER BY tc.table_name
            """
        )
        var statements: [String] = []
        for row in result.rows {
            guard row.count >= 5 else { continue }
            let table = driver.quoteIdentifier(row[0].display)
            let column = driver.quoteIdentifier(row[1].display)
            let foreignTable = driver.quoteIdentifier(row[2].display)
            let foreignColumn = driver.quoteIdentifier(row[3].display)
            var statement = "ALTER TABLE \(table) ADD FOREIGN KEY (\(column)) REFERENCES \(foreignTable) (\(foreignColumn))"
            let deleteRule = row[4].display
            let updateRule = row.count > 5 ? row[5].display : ""
            if deleteRule != "NO ACTION" {
                statement += " ON DELETE \(deleteRule)"
            }
            if updateRule != "NO ACTION" {
                statement += " ON UPDATE \(updateRule)"
            }
            statement += ";"
            statements.append(statement)
        }
        return statements
    }

    private static func sqliteSchema(driver: any DatabaseDriver) async throws -> [String] {
        let result = try await driver.query(
            """
            SELECT sql, type
            FROM sqlite_master
            WHERE type IN ('table','index','view','trigger')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END, name
            """
        )
        return result.rows.compactMap { row in
            let sql = row.first?.display ?? ""
            guard !sql.isEmpty else { return nil }
            return sql.hasSuffix(";") ? sql : sql + ";"
        }
    }

    private static func querySingleValue(driver: any DatabaseDriver, sql: String) async throws -> String? {
        let result = try await driver.query(sql)
        // SHOW CREATE TABLE retorna (Table, Create Table) — o DDL fica na última coluna.
        guard let row = result.rows.first, let value = row.last else { return nil }
        return value.display
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

    // MARK: - Splitter

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
