import Foundation

/// Gera DDL de alteração de colunas por engine. Defaults são expressões SQL cruas
/// (ex.: `0`, `'texto'`, `CURRENT_TIMESTAMP`) — exatamente como digitadas.
public enum SchemaDDL {
    public struct ColumnSpec: Sendable {
        public var name: String
        public var type: String
        public var isNullable: Bool
        public var defaultExpression: String?

        public init(name: String, type: String, isNullable: Bool, defaultExpression: String?) {
            self.name = name
            self.type = type
            self.isNullable = isNullable
            self.defaultExpression = defaultExpression
        }
    }

    public enum DDLError: LocalizedError {
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let message): return message
            }
        }
    }

    /// ALTER TABLE … ADD COLUMN — sintaxe igual nos três engines.
    /// Tipo vazio é permitido (SQLite aceita coluna sem tipo declarado).
    public static func addColumn(engine: SQLEngine, table: String, column: ColumnSpec) -> String {
        var sql = "ALTER TABLE \(quote(engine, table)) ADD COLUMN \(quote(engine, column.name))"
        if !column.type.isEmpty { sql += " \(column.type)" }
        if !column.isNullable { sql += " NOT NULL" }
        if let expression = column.defaultExpression, !expression.isEmpty { sql += " DEFAULT \(expression)" }
        return sql
    }

    public static func dropColumn(engine: SQLEngine, table: String, column: String) -> String {
        "ALTER TABLE \(quote(engine, table)) DROP COLUMN \(quote(engine, column))"
    }

    /// Statements que transformam `original` em `edited` (renomear, tipo, nulidade, default).
    /// A ordem importa: renomeia primeiro, o resto referencia o nome novo.
    public static func alterColumn(
        engine: SQLEngine,
        table: String,
        original: DatabaseColumn,
        edited: ColumnSpec
    ) throws -> [String] {
        var statements: [String] = []
        let renamed = original.name != edited.name
        let typeChanged = original.type.lowercased() != edited.type.lowercased()
        let nullChanged = original.isNullable != edited.isNullable
        let defaultChanged = (original.defaultValue ?? "") != (edited.defaultExpression ?? "")

        switch engine {
        case .mysql:
            if renamed {
                statements.append("ALTER TABLE \(quote(engine, table)) RENAME COLUMN \(quote(engine, original.name)) TO \(quote(engine, edited.name))")
            }
            if typeChanged || nullChanged || defaultChanged {
                // MODIFY reescreve a definição inteira da coluna.
                var sql = "ALTER TABLE \(quote(engine, table)) MODIFY COLUMN \(quote(engine, edited.name)) \(edited.type)"
                sql += edited.isNullable ? " NULL" : " NOT NULL"
                if let expression = edited.defaultExpression, !expression.isEmpty { sql += " DEFAULT \(expression)" }
                statements.append(sql)
            }
        case .postgres:
            let table = quote(engine, table)
            if renamed {
                statements.append("ALTER TABLE \(table) RENAME COLUMN \(quote(engine, original.name)) TO \(quote(engine, edited.name))")
            }
            let column = quote(engine, edited.name)
            if typeChanged {
                statements.append("ALTER TABLE \(table) ALTER COLUMN \(column) TYPE \(edited.type)")
            }
            if nullChanged {
                statements.append("ALTER TABLE \(table) ALTER COLUMN \(column) \(edited.isNullable ? "DROP NOT NULL" : "SET NOT NULL")")
            }
            if defaultChanged {
                if let expression = edited.defaultExpression, !expression.isEmpty {
                    statements.append("ALTER TABLE \(table) ALTER COLUMN \(column) SET DEFAULT \(expression)")
                } else {
                    statements.append("ALTER TABLE \(table) ALTER COLUMN \(column) DROP DEFAULT")
                }
            }
        case .sqlite:
            if typeChanged || nullChanged || defaultChanged {
                throw DDLError.unsupported("SQLite não suporta alterar tipo/nulidade/default de coluna — apenas renomear, adicionar e remover.")
            }
            if renamed {
                statements.append("ALTER TABLE \(quote(engine, table)) RENAME COLUMN \(quote(engine, original.name)) TO \(quote(engine, edited.name))")
            }
        }
        return statements
    }

    private static func quote(_ engine: SQLEngine, _ name: String) -> String {
        switch engine {
        case .mysql: return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        case .postgres, .sqlite: return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }
}
