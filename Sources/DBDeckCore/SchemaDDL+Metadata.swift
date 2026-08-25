import Foundation

/// DDL de chaves estrangeiras e triggers. Nenhum engine altera uma FK ou um trigger "no
/// lugar": editar é remover e criar de novo — quem chama executa os dois statements.
public extension SchemaDDL {
    static let referentialActions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]

    struct ForeignKeySpec: Sendable, Equatable {
        /// Vazio = gerado (`fk_<tabela>_<coluna>`).
        public var name: String
        public var columns: [String]
        public var referencedTable: String
        public var referencedColumns: [String]
        public var onUpdate: String
        public var onDelete: String

        public init(name: String = "", columns: [String], referencedTable: String, referencedColumns: [String],
                    onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION") {
            self.name = name
            self.columns = columns
            self.referencedTable = referencedTable
            self.referencedColumns = referencedColumns
            self.onUpdate = onUpdate
            self.onDelete = onDelete
        }
    }

    static func foreignKeyName(table: String, spec: ForeignKeySpec) -> String {
        let trimmed = spec.name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return "fk_\(table)_\(spec.columns.joined(separator: "_"))"
    }

    /// `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` — MySQL e Postgres. SQLite não altera
    /// constraints depois de criar a tabela (só recriando-a), então recusa.
    static func addForeignKey(engine: SQLEngine, table: String, spec: ForeignKeySpec) throws -> String {
        guard engine != .sqlite else {
            throw DDLError.unsupported("SQLite não permite adicionar chave estrangeira a uma tabela existente — só recriando a tabela.")
        }
        guard !spec.columns.isEmpty, spec.columns.count == spec.referencedColumns.count else {
            throw DDLError.unsupported("A chave precisa de pelo menos uma coluna, e o mesmo número de colunas dos dois lados.")
        }
        guard !spec.referencedTable.isEmpty else {
            throw DDLError.unsupported("Escolha a tabela referenciada.")
        }
        let name = foreignKeyName(table: table, spec: spec)
        var sql = "ALTER TABLE \(engine.quote(table)) ADD CONSTRAINT \(engine.quote(name)) FOREIGN KEY ("
        sql += spec.columns.map { engine.quote($0) }.joined(separator: ", ")
        sql += ") REFERENCES \(engine.quote(spec.referencedTable)) ("
        sql += spec.referencedColumns.map { engine.quote($0) }.joined(separator: ", ")
        sql += ")"
        if !spec.onUpdate.isEmpty, spec.onUpdate != "NO ACTION" { sql += " ON UPDATE \(spec.onUpdate)" }
        if !spec.onDelete.isEmpty, spec.onDelete != "NO ACTION" { sql += " ON DELETE \(spec.onDelete)" }
        return sql
    }

    static func dropForeignKey(engine: SQLEngine, table: String, name: String) throws -> String {
        switch engine {
        case .mysql: "ALTER TABLE \(engine.quote(table)) DROP FOREIGN KEY \(engine.quote(name))"
        case .postgres: "ALTER TABLE \(engine.quote(table)) DROP CONSTRAINT \(engine.quote(name))"
        case .sqlite: throw DDLError.unsupported("SQLite não permite remover chave estrangeira de uma tabela existente — só recriando a tabela.")
        }
    }

    // MARK: - Triggers

    static let triggerTimings = ["BEFORE", "AFTER", "INSTEAD OF"]
    static let triggerEvents = ["INSERT", "UPDATE", "DELETE"]

    struct TriggerSpec: Sendable, Equatable {
        public var name: String
        public var timing: String
        /// MySQL e SQLite aceitam um evento; Postgres combina (`INSERT OR UPDATE`).
        public var events: [String]
        /// Postgres: só `FOR EACH ROW` ou `FOR EACH STATEMENT`. MySQL é sempre por linha.
        public var forEachRow: Bool
        /// MySQL/SQLite: os statements (com ou sem `BEGIN … END`). Postgres: a função a
        /// executar (`nome_da_funcao()`), ou a cláusula `EXECUTE FUNCTION …` inteira.
        public var body: String

        public init(name: String, timing: String = "AFTER", events: [String] = ["INSERT"], forEachRow: Bool = true, body: String = "") {
            self.name = name
            self.timing = timing
            self.events = events
            self.forEachRow = forEachRow
            self.body = body
        }
    }

    static func createTrigger(engine: SQLEngine, table: String, spec: TriggerSpec) throws -> String {
        let name = spec.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw DDLError.unsupported("Informe o nome do trigger.") }
        guard !spec.events.isEmpty else { throw DDLError.unsupported("Escolha o evento do trigger.") }
        let body = spec.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw DDLError.unsupported("Informe o corpo do trigger.") }

        switch engine {
        case .mysql:
            guard spec.events.count == 1 else { throw DDLError.unsupported("MySQL aceita um evento por trigger.") }
            guard spec.timing != "INSTEAD OF" else { throw DDLError.unsupported("MySQL não tem INSTEAD OF.") }
            return "CREATE TRIGGER \(engine.quote(name)) \(spec.timing) \(spec.events[0]) ON \(engine.quote(table)) FOR EACH ROW \(blockBody(body))"
        case .sqlite:
            guard spec.events.count == 1 else { throw DDLError.unsupported("SQLite aceita um evento por trigger.") }
            return "CREATE TRIGGER \(engine.quote(name)) \(spec.timing) \(spec.events[0]) ON \(engine.quote(table)) FOR EACH ROW \(blockBody(body))"
        case .postgres:
            let action = body.uppercased().hasPrefix("EXECUTE") ? body : "EXECUTE FUNCTION \(body)"
            let scope = spec.forEachRow ? "FOR EACH ROW" : "FOR EACH STATEMENT"
            return "CREATE TRIGGER \(engine.quote(name)) \(spec.timing) \(spec.events.joined(separator: " OR ")) ON \(engine.quote(table)) \(scope) \(action)"
        }
    }

    static func dropTrigger(engine: SQLEngine, table: String, name: String) -> String {
        switch engine {
        case .mysql, .sqlite: "DROP TRIGGER IF EXISTS \(engine.quote(name))"
        case .postgres: "DROP TRIGGER IF EXISTS \(engine.quote(name)) ON \(engine.quote(table))"
        }
    }

    /// Um statement solto vira bloco; um bloco já escrito passa direto. O `;` final do
    /// último statement é obrigatório dentro de `BEGIN … END`.
    private static func blockBody(_ body: String) -> String {
        if body.uppercased().hasPrefix("BEGIN") { return body }
        let terminated = body.hasSuffix(";") ? body : body + ";"
        return "BEGIN\n\(terminated)\nEND"
    }
}
