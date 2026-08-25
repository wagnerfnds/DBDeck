import Foundation

// MARK: - Modelos

/// Uma chave estrangeira: `table.columns` → `referencedTable.referencedColumns`.
public struct ForeignKey: Sendable, Equatable, Identifiable {
    public var name: String
    public var table: String
    public var columns: [String]
    public var referencedTable: String
    public var referencedColumns: [String]
    /// `NO ACTION`, `RESTRICT`, `CASCADE`, `SET NULL`, `SET DEFAULT` (normalizado em caixa alta).
    public var onUpdate: String
    public var onDelete: String

    public var id: String { "\(table).\(name)" }

    public init(name: String, table: String, columns: [String], referencedTable: String,
                referencedColumns: [String], onUpdate: String, onDelete: String) {
        self.name = name
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    /// FK de uma coluna só — a única que vira "setinha" no grid (compostas não têm um
    /// valor para filtrar).
    public var isSingleColumn: Bool { columns.count == 1 && referencedColumns.count == 1 }
}

public struct TableTrigger: Sendable, Equatable, Identifiable {
    public var name: String
    /// `BEFORE` / `AFTER` / `INSTEAD OF`.
    public var timing: String
    /// `INSERT` / `UPDATE` / `DELETE` (Postgres pode combinar: `INSERT OR UPDATE`).
    public var event: String
    /// Corpo (MySQL/SQLite) ou definição completa (Postgres, `pg_get_triggerdef`).
    public var body: String

    public var id: String { name }

    public init(name: String, timing: String, event: String, body: String) {
        self.name = name
        self.timing = timing
        self.event = event
        self.body = body
    }
}

public struct TableInfo: Sendable, Equatable {
    /// Pares rótulo/valor na ordem de exibição — cada engine tem os seus.
    public var facts: [(label: String, value: String)]
    public var ddl: String

    public init(facts: [(label: String, value: String)], ddl: String) {
        self.facts = facts
        self.ddl = ddl
    }

    public static func == (lhs: TableInfo, rhs: TableInfo) -> Bool {
        lhs.ddl == rhs.ddl && lhs.facts.map(\.label) == rhs.facts.map(\.label) && lhs.facts.map(\.value) == rhs.facts.map(\.value)
    }
}

// MARK: - Consultas

/// Metadados de uma tabela além das colunas: chaves estrangeiras, triggers e informações
/// gerais. Uma consulta de catálogo por engine; nada é cacheado — quem chama decide.
public enum SchemaMetadata {
    /// FKs que SAEM desta tabela (ela referencia outras).
    public static func foreignKeys(driver: any DatabaseDriver, table: String) async throws -> [ForeignKey] {
        switch driver.engine {
        case .mysql:
            return try await mysqlForeignKeys(driver: driver, where: "k.TABLE_NAME = '\(escape(table))'")
        case .postgres:
            return try await postgresForeignKeys(driver: driver, where: "c.conrelid = \(regclass(driver, table))")
        case .sqlite:
            return try await sqliteForeignKeys(driver: driver, table: table)
        }
    }

    /// FKs que CHEGAM nesta tabela (outras a referenciam).
    public static func referencingKeys(driver: any DatabaseDriver, table: String) async throws -> [ForeignKey] {
        switch driver.engine {
        case .mysql:
            return try await mysqlForeignKeys(driver: driver, where: "k.REFERENCED_TABLE_NAME = '\(escape(table))'")
        case .postgres:
            return try await postgresForeignKeys(driver: driver, where: "c.confrelid = \(regclass(driver, table))")
        case .sqlite:
            // SQLite não tem catálogo inverso: percorre as tabelas. São poucas num arquivo.
            var found: [ForeignKey] = []
            for other in try await driver.tables() where other.kind == "table" && other.name != table {
                let keys = try await sqliteForeignKeys(driver: driver, table: other.name)
                found += keys.filter { $0.referencedTable.caseInsensitiveCompare(table) == .orderedSame }
            }
            return found
        }
    }

    public static func triggers(driver: any DatabaseDriver, table: String) async throws -> [TableTrigger] {
        switch driver.engine {
        case .mysql:
            let result = try await driver.query("""
                SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
                FROM information_schema.TRIGGERS
                WHERE TRIGGER_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = '\(escape(table))'
                ORDER BY ACTION_ORDER, TRIGGER_NAME
                """)
            return result.rows.map { row in
                TableTrigger(name: text(row, 0), timing: text(row, 1).uppercased(), event: text(row, 2).uppercased(), body: text(row, 3))
            }
        case .postgres:
            let result = try await driver.query("""
                SELECT t.tgname, pg_catalog.pg_get_triggerdef(t.oid, true)
                FROM pg_catalog.pg_trigger t
                WHERE t.tgrelid = \(regclass(driver, table)) AND NOT t.tgisinternal
                ORDER BY t.tgname
                """)
            return result.rows.map { row in
                let definition = text(row, 1)
                let (timing, event) = parseTriggerDefinition(definition)
                return TableTrigger(name: text(row, 0), timing: timing, event: event, body: definition)
            }
        case .sqlite:
            let result = try await driver.query("""
                SELECT name, sql FROM sqlite_master
                WHERE type = 'trigger' AND tbl_name = '\(escape(table))' ORDER BY name
                """)
            return result.rows.map { row in
                let sql = text(row, 1)
                let (timing, event) = parseTriggerDefinition(sql)
                return TableTrigger(name: text(row, 0), timing: timing, event: event, body: sql)
            }
        }
    }

    public static func tableInfo(driver: any DatabaseDriver, table: String) async throws -> TableInfo {
        switch driver.engine {
        case .mysql:
            let stats = try await driver.query("""
                SELECT ENGINE, TABLE_COLLATION, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH,
                       AUTO_INCREMENT, CREATE_TIME, UPDATE_TIME, TABLE_COMMENT
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(escape(table))'
                """)
            var facts: [(String, String)] = []
            if let row = stats.rows.first {
                facts.append(("Engine", text(row, 0)))
                facts.append(("Collation", text(row, 1)))
                facts.append(("Linhas (estimativa)", formatCount(text(row, 2))))
                facts.append(("Dados", formatBytes(text(row, 3))))
                facts.append(("Índices", formatBytes(text(row, 4))))
                if !text(row, 5).isEmpty { facts.append(("Próximo auto-incremento", text(row, 5))) }
                if !text(row, 6).isEmpty { facts.append(("Criada em", text(row, 6))) }
                if !text(row, 7).isEmpty { facts.append(("Atualizada em", text(row, 7))) }
                if !text(row, 8).isEmpty { facts.append(("Comentário", text(row, 8))) }
            }
            let ddlResult = try await driver.query("SHOW CREATE TABLE \(driver.quoteIdentifier(table))")
            let ddl = ddlResult.rows.first.map { text($0, 1) } ?? ""
            return TableInfo(facts: facts, ddl: ddl)

        case .postgres:
            let target = regclass(driver, table)
            let stats = try await driver.query("""
                SELECT c.reltuples::bigint,
                       pg_catalog.pg_table_size(c.oid),
                       pg_catalog.pg_indexes_size(c.oid),
                       pg_catalog.obj_description(c.oid, 'pg_class'),
                       pg_catalog.pg_get_userbyid(c.relowner),
                       n.nspname
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE c.oid = \(target)
                """)
            var facts: [(String, String)] = []
            if let row = stats.rows.first {
                facts.append(("Schema", text(row, 5)))
                facts.append(("Dono", text(row, 4)))
                let estimate = Int(text(row, 0)) ?? -1
                facts.append(("Linhas (estimativa)", estimate < 0 ? "desconhecida (sem ANALYZE)" : formatCount(text(row, 0))))
                facts.append(("Dados", formatBytes(text(row, 1))))
                facts.append(("Índices", formatBytes(text(row, 2))))
                if !text(row, 3).isEmpty { facts.append(("Comentário", text(row, 3))) }
            }
            let ddl = try await SQLDump.createTablePostgres(driver: driver, table: table)
            return TableInfo(facts: facts, ddl: ddl)

        case .sqlite:
            let ddlResult = try await driver.query("""
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(escape(table))'
                """)
            let ddl = ddlResult.rows.first.map { text($0, 0) } ?? ""
            var facts: [(String, String)] = []
            let count = try await driver.countRows(table: table)
            facts.append(("Linhas", formatCount(String(count))))
            let indexes = try await driver.query("PRAGMA index_list(\(driver.quoteIdentifier(table)))")
            facts.append(("Índices", String(indexes.rows.count)))
            return TableInfo(facts: facts, ddl: ddl)
        }
    }

    // MARK: - MySQL

    private static func mysqlForeignKeys(driver: any DatabaseDriver, where condition: String) async throws -> [ForeignKey] {
        // KEY_COLUMN_USAGE tem uma linha por coluna; REFERENTIAL_CONSTRAINTS tem as regras.
        let result = try await driver.query("""
            SELECT k.CONSTRAINT_NAME, k.TABLE_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME,
                   k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE, k.ORDINAL_POSITION
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.CONSTRAINT_SCHEMA = DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL AND \(condition)
            ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        return group(result.rows.map { row in
            (name: text(row, 0), table: text(row, 1), column: text(row, 2), refTable: text(row, 3),
             refColumn: text(row, 4), onUpdate: text(row, 5).uppercased(), onDelete: text(row, 6).uppercased())
        })
    }

    // MARK: - Postgres

    private static func postgresForeignKeys(driver: any DatabaseDriver, where condition: String) async throws -> [ForeignKey] {
        // `unnest … WITH ORDINALITY` preserva a ordem das colunas da chave composta.
        let result = try await driver.query("""
            SELECT c.conname,
                   c.conrelid::regclass::text,
                   a.attname,
                   c.confrelid::regclass::text,
                   ra.attname,
                   c.confupdtype::text,
                   c.confdeltype::text,
                   k.ord
            FROM pg_catalog.pg_constraint c
            CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(attnum, refattnum, ord)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
            JOIN pg_catalog.pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = k.refattnum
            WHERE c.contype = 'f' AND \(condition)
            ORDER BY 2, 1, k.ord
            """)
        return group(result.rows.map { row in
            (name: text(row, 0), table: unquote(text(row, 1)), column: text(row, 2), refTable: unquote(text(row, 3)),
             refColumn: text(row, 4), onUpdate: postgresRule(text(row, 5)), onDelete: postgresRule(text(row, 6)))
        })
    }

    private static func postgresRule(_ code: String) -> String {
        switch code {
        case "a": "NO ACTION"
        case "r": "RESTRICT"
        case "c": "CASCADE"
        case "n": "SET NULL"
        case "d": "SET DEFAULT"
        default: code.uppercased()
        }
    }

    /// `regclass` devolve `schema.tabela` quando fora do search_path e cita quando preciso.
    private static func unquote(_ name: String) -> String {
        let bare = name.split(separator: ".").last.map(String.init) ?? name
        guard bare.hasPrefix("\""), bare.hasSuffix("\""), bare.count >= 2 else { return bare }
        return String(bare.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    // MARK: - SQLite

    private static func sqliteForeignKeys(driver: any DatabaseDriver, table: String) async throws -> [ForeignKey] {
        // Colunas: id, seq, table, from, to, on_update, on_delete, match
        let result = try await driver.query("PRAGMA foreign_key_list(\(driver.quoteIdentifier(table)))")
        return group(result.rows.map { row in
            (name: "fk_\(table)_\(text(row, 0))", table: table, column: text(row, 3), refTable: text(row, 2),
             refColumn: text(row, 4), onUpdate: text(row, 5).uppercased(), onDelete: text(row, 6).uppercased())
        })
    }

    // MARK: - Utilidades

    private typealias KeyColumn = (name: String, table: String, column: String, refTable: String, refColumn: String, onUpdate: String, onDelete: String)

    /// Junta as linhas por (tabela, constraint) mantendo a ordem de chegada.
    private static func group(_ rows: [KeyColumn]) -> [ForeignKey] {
        var keys: [ForeignKey] = []
        for row in rows {
            if let index = keys.firstIndex(where: { $0.name == row.name && $0.table == row.table }) {
                keys[index].columns.append(row.column)
                keys[index].referencedColumns.append(row.refColumn)
            } else {
                keys.append(ForeignKey(name: row.name, table: row.table, columns: [row.column], referencedTable: row.refTable,
                                       referencedColumns: [row.refColumn], onUpdate: row.onUpdate, onDelete: row.onDelete))
            }
        }
        return keys
    }

    /// `BEFORE INSERT`, `AFTER INSERT OR UPDATE`, `INSTEAD OF DELETE` — extraídos da definição.
    static func parseTriggerDefinition(_ definition: String) -> (timing: String, event: String) {
        let upper = definition.uppercased()
        let timing: String
        if upper.contains("INSTEAD OF") { timing = "INSTEAD OF" }
        else if upper.contains(" AFTER ") || upper.hasPrefix("AFTER ") { timing = "AFTER" }
        else { timing = "BEFORE" }
        var events: [String] = []
        for event in ["INSERT", "UPDATE", "DELETE", "TRUNCATE"] {
            // O evento vem antes do ` ON tabela`; o mesmo verbo pode aparecer no corpo.
            if let onRange = upper.range(of: " ON "), upper[..<onRange.lowerBound].contains(event) {
                events.append(event)
            }
        }
        return (timing, events.isEmpty ? "?" : events.joined(separator: " OR "))
    }

    private static func regclass(_ driver: any DatabaseDriver, _ table: String) -> String {
        "'\(escape(driver.quoteIdentifier(table)))'::regclass"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func text(_ row: [SQLValue], _ index: Int) -> String {
        index < row.count ? row[index].display : ""
    }

    private static func formatCount(_ value: String) -> String {
        guard let number = Int(value) else { return value }
        return number.formatted()
    }

    private static func formatBytes(_ value: String) -> String {
        guard let number = Int64(value) else { return value }
        return ByteCountFormatter.string(fromByteCount: number, countStyle: .file)
    }
}
