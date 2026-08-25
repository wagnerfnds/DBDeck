import Foundation

// MARK: - Opções

/// Opções de exportação, no espírito do Sequel Ace: o que entra no arquivo e como
/// os INSERTs são gerados.
public struct DumpOptions: Sendable, Equatable {
    public enum Content: String, CaseIterable, Sendable, Identifiable {
        /// DDL + dados (padrão).
        case structureAndData
        /// Só o esquema — para versionar ou recriar um banco vazio.
        case structureOnly
        /// Só os INSERTs — para repopular um banco que já tem o esquema.
        case dataOnly

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .structureAndData: "Estrutura e dados"
            case .structureOnly: "Somente estrutura"
            case .dataOnly: "Somente dados"
            }
        }

        var includesStructure: Bool { self != .dataOnly }
        var includesData: Bool { self != .structureOnly }
    }

    public var content: Content = .structureAndData
    /// `DROP TABLE IF EXISTS` antes de cada CREATE (dump que sobrescreve um banco existente).
    public var dropBeforeCreate = true
    /// `CREATE DATABASE IF NOT EXISTS` + `USE` no topo (MySQL).
    public var includeCreateDatabase = false
    /// Nome usado no CREATE DATABASE. nil = o banco corrente da conexão.
    public var databaseName: String?
    /// INSERT com várias linhas por statement (uma ordem de grandeza mais rápido no import).
    public var extendedInserts = true
    /// Teto de bytes por INSERT. 1 MB fica bem abaixo do `max_allowed_packet` padrão (4/64 MB).
    public var maxStatementBytes = 1_000_000
    /// Linhas lidas por lote no streaming. Só afeta memória/latência, não o arquivo.
    public var batchSize = 2_000
    /// Cabeçalho de compatibilidade (desliga checagem de FK, chaves únicas e autocommit
    /// durante o import). É o que faz um restore levar minutos em vez de horas.
    public var compatibilityHeader = true
    /// Lê tudo numa transação consistente (MySQL: `WITH CONSISTENT SNAPSHOT`).
    public var consistentSnapshot = true
    /// `ALTER TABLE … DISABLE KEYS` em volta dos dados (MyISAM; ignorado pelo InnoDB).
    public var disableKeys = true
    /// Remove `DEFINER=…` de views/triggers/rotinas — sem isso o import falha em outro
    /// servidor com "The user specified as a definer does not exist".
    public var stripDefiner = true
    /// Triggers, procedures e functions (MySQL).
    public var includeRoutines = true
    /// Views.
    public var includeViews = true

    public init() {}
}

/// Progresso do dump: uma chamada por tabela e por lote de linhas.
public struct DumpProgress: Sendable {
    public let tableIndex: Int
    public let tableCount: Int
    public let tableName: String
    public let rowsWritten: Int
    public let bytesWritten: Int
    public let finished: Bool

    public init(
        tableIndex: Int,
        tableCount: Int,
        tableName: String,
        rowsWritten: Int,
        bytesWritten: Int = 0,
        finished: Bool
    ) {
        self.tableIndex = tableIndex
        self.tableCount = tableCount
        self.tableName = tableName
        self.rowsWritten = rowsWritten
        self.bytesWritten = bytesWritten
        self.finished = finished
    }
}

public enum DumpError: Error, LocalizedError {
    case cancelled
    /// O import foi abortado: statements demais falhando EM SEQUÊNCIA — tipicamente uma
    /// tabela inteira rejeitando INSERTs (schema incompatível, coluna gerada, collation).
    /// Continuar só acumularia milhares do mesmo erro em silêncio.
    case tooManyErrors(consecutive: Int, sample: String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Importação cancelada."
        case .tooManyErrors(let consecutive, let sample):
            return "Importação interrompida: \(consecutive) statements seguidos falharam.\n\nÚltimo erro:\n\(sample)"
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

public enum SQLDump {
    // MARK: - Dump

    /// Dump completo em memória (conveniência; testes e chamadas pequenas).
    public static func dump(
        driver: any DatabaseDriver,
        options: DumpOptions = DumpOptions()
    ) async throws -> String {
        final class Buffer: @unchecked Sendable { var text = "" } // chamadas de write são seriais
        let buffer = Buffer()
        try await dump(driver: driver, tables: nil, options: options, write: { buffer.text += $0 })
        return buffer.text
    }

    /// Dump em streaming: `write` recebe blocos de SQL na ordem final (dá para gravar direto
    /// em disco sem manter o dump inteiro em memória) e `progress` acompanha tabela a tabela.
    ///
    /// As linhas são lidas com UMA query por tabela, consumida conforme chega do servidor.
    /// A versão anterior paginava com `LIMIT/OFFSET`: como o servidor precisa varrer e
    /// descartar as `offset` primeiras linhas em cada página, o custo é quadrático no
    /// número de linhas — era isso que transformava um banco de 200 MB em meia hora.
    ///
    /// Cancelamento: `cancel` é consultado dentro do streaming (o callback de linhas roda
    /// fora da Task, onde `Task.isCancelled` não enxerga nada), e `Task.checkCancellation`
    /// cobre as fronteiras entre tabelas.
    public static func dump(
        driver: any DatabaseDriver,
        tables selection: [DatabaseTable]?,
        options: DumpOptions = DumpOptions(),
        cancel: CancelToken? = nil,
        write: @escaping @Sendable (String) throws -> Void,
        progress: @escaping @Sendable (DumpProgress) -> Void = { _ in }
    ) async throws {
        let allTables = try await driver.tables()
        let selectedNames = selection.map { Set($0.map(\.name)) }
        let tables = selectedNames.map { names in allTables.filter { names.contains($0.name) } } ?? allTables
        let dataTables = tables.filter { $0.kind == "table" }
        let views = options.includeViews ? tables.filter { $0.kind == "view" } : []
        let engine = driver.engine

        // Contador de bytes: alimenta a velocidade mostrada na UI.
        final class Meter: @unchecked Sendable { var bytes = 0 }
        let meter = Meter()
        let emit: @Sendable (String) throws -> Void = { chunk in
            meter.bytes += chunk.utf8.count
            try write(chunk)
        }

        try emit("-- DBDeck dump — \(engine.displayName)\n-- Gerado em \(Date())\n")
        if let name = options.databaseName, !name.isEmpty {
            try emit("-- Banco: \(name)\n")
        }
        try emit("\n")

        if options.compatibilityHeader {
            try emit(sessionHeader(engine: engine, content: options.content))
        }
        if options.includeCreateDatabase, engine == .mysql, let name = options.databaseName, !name.isEmpty {
            let quoted = driver.quoteIdentifier(name)
            try emit("CREATE DATABASE IF NOT EXISTS \(quoted) CHARACTER SET utf8mb4;\nUSE \(quoted);\n\n")
        }

        // Snapshot consistente: os dados saem todos do mesmo instante lógico.
        // (No Postgres o driver usa um POOL de conexões — um BEGIN não gruda numa
        // conexão específica, então não há transação a abrir aqui.)
        var snapshotOpen = false
        if options.consistentSnapshot, options.content.includesData, engine == .mysql {
            _ = try? await driver.execute("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            if (try? await driver.execute("START TRANSACTION WITH CONSISTENT SNAPSHOT")) != nil {
                snapshotOpen = true
            }
        }
        defer {
            if snapshotOpen {
                let releasing = driver
                Task { _ = try? await releasing.execute("COMMIT") }
            }
        }

        // Postgres: sequences antes das tabelas (defaults `nextval` dependem delas).
        var deferredSequenceStatements: [String] = []
        if engine == .postgres, options.content.includesStructure {
            deferredSequenceStatements = try await writePostgresSequences(
                driver: driver, tables: tables, selectedNames: selectedNames, emit: emit
            )
        }

        // Tabela a tabela: DDL e dados juntos. Interleavar mantém o arquivo legível e
        // evita uma segunda passada de metadados no fim da exportação.
        for (index, table) in dataTables.enumerated() {
            try Task.checkCancellation()
            if cancel?.isCancelled == true { throw DumpError.cancelled }
            progress(DumpProgress(
                tableIndex: index + 1, tableCount: dataTables.count, tableName: table.name,
                rowsWritten: 0, bytesWritten: meter.bytes, finished: false
            ))

            if options.content.includesStructure {
                try emit("-- ----------------------------\n-- Tabela: \(table.name)\n-- ----------------------------\n")
                if options.dropBeforeCreate {
                    // CASCADE no Postgres: sem ele o DROP falha se outra tabela do dump
                    // (ainda não recriada) referenciar esta por FK.
                    let cascade = engine == .postgres ? " CASCADE" : ""
                    try emit("DROP TABLE IF EXISTS \(driver.quoteIdentifier(table.name))\(cascade);\n")
                }
                let ddl = try await createStatement(driver: driver, table: table, options: options)
                try emit(ddl + "\n\n")
            }

            guard options.content.includesData else { continue }

            let quoted = driver.quoteIdentifier(table.name)
            if options.disableKeys, engine == .mysql {
                try emit("/*!40000 ALTER TABLE \(quoted) DISABLE KEYS */;\n")
            }
            let rows = try await writeTableData(
                driver: driver, table: table.name, options: options, cancel: cancel, emit: emit
            ) { written in
                progress(DumpProgress(
                    tableIndex: index + 1, tableCount: dataTables.count, tableName: table.name,
                    rowsWritten: written, bytesWritten: meter.bytes, finished: false
                ))
            }
            if options.disableKeys, engine == .mysql {
                try emit("/*!40000 ALTER TABLE \(quoted) ENABLE KEYS */;\n")
            }
            if rows > 0 { try emit("\n") }
        }

        // Views depois das tabelas: a definição referencia as tabelas base.
        if options.content.includesStructure {
            for view in views {
                try Task.checkCancellation()
                let ddl = try await createStatement(driver: driver, table: view, options: options)
                try emit(ddl + "\n\n")
            }
            // Postgres: índices e constraints (unique/FK/check) por último, para não
            // frear os INSERTs nem depender da ordem de criação das tabelas.
            if engine == .postgres {
                try await writePostgresConstraints(driver: driver, only: selectedNames, emit: emit)
                if !deferredSequenceStatements.isEmpty {
                    // Contadores das colunas IDENTITY: a sequence só existe depois do CREATE TABLE.
                    try emit("-- Contadores de IDENTITY\n" + deferredSequenceStatements.joined(separator: "\n") + "\n\n")
                }
            }
            if engine == .mysql, options.includeRoutines {
                try await writeMySQLRoutines(driver: driver, options: options, only: selectedNames, emit: emit)
            }
        }

        if options.compatibilityHeader {
            try emit(sessionFooter(engine: engine, content: options.content))
        }
        progress(DumpProgress(
            tableIndex: dataTables.count, tableCount: dataTables.count, tableName: "",
            rowsWritten: 0, bytesWritten: meter.bytes, finished: true
        ))
    }

    /// Dump de UMA tabela (DDL + dados) — exportação pelo menu de contexto da lista de tabelas.
    public static func dumpTable(
        driver: any DatabaseDriver,
        table: DatabaseTable,
        options: DumpOptions = DumpOptions()
    ) async throws -> String {
        final class Buffer: @unchecked Sendable { var text = "" }
        let buffer = Buffer()
        var scoped = options
        // Uma tabela só: cabeçalho de sessão e CREATE DATABASE não fazem sentido.
        scoped.includeCreateDatabase = false
        try await dump(driver: driver, tables: [table], options: scoped, write: { buffer.text += $0 })
        return buffer.text
    }

    // MARK: - Dados

    /// Escreve os INSERTs de uma tabela lendo o resultado em streaming. Devolve o total de linhas.
    private static func writeTableData(
        driver: any DatabaseDriver,
        table: String,
        options: DumpOptions,
        cancel: CancelToken?,
        emit: @escaping @Sendable (String) throws -> Void,
        onRows: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        let engine = driver.engine
        let quoted = driver.quoteIdentifier(table)

        // Colunas GERADAS ficam fora do dump: o servidor calcula o valor e RECUSA
        // recebê-lo num INSERT (ERROR 3105 no MySQL) — um dump com elas não re-importa.
        // Com alguma gerada, o SELECT lista as colunas normais explicitamente (o
        // mysqldump faz o mesmo); sem nenhuma, segue o `*`.
        let allColumns = (try? await driver.columns(table: table)) ?? []
        let fieldList: String
        if allColumns.contains(where: \.isGenerated) {
            let names = allColumns
                .filter { !$0.isGenerated }
                .map { driver.quoteIdentifier($0.name) }
            fieldList = names.isEmpty ? "*" : names.joined(separator: ", ")
        } else {
            fieldList = "*"
        }

        // SQL_NO_CACHE: um dump varre a tabela inteira uma vez; poluir o cache do
        // servidor com ela só prejudica a carga normal (é o que o mysqldump faz).
        let sql = engine == .mysql
            ? "SELECT /*!40001 SQL_NO_CACHE */ \(fieldList) FROM \(quoted)"
            : "SELECT \(fieldList) FROM \(quoted)"

        final class State: @unchecked Sendable {
            var buffer = ""
            var prefix = ""
            var rowsInStatement = 0
            var total = 0
        }
        let state = State()
        state.buffer.reserveCapacity(options.maxStatementBytes + 8_192)
        let limit = options.extendedInserts ? options.maxStatementBytes : 0

        try await driver.streamQuery(sql, batchSize: options.batchSize) { batch in
            if cancel?.isCancelled == true { throw DumpError.cancelled }
            if state.prefix.isEmpty, !batch.columns.isEmpty {
                let columnList = batch.columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
                state.prefix = "INSERT INTO \(quoted) (\(columnList)) VALUES\n"
            }
            for row in batch.rows {
                state.buffer += state.rowsInStatement == 0 ? state.prefix : ",\n"
                state.buffer += "("
                for (position, value) in row.enumerated() {
                    if position > 0 { state.buffer += "," }
                    // Blob vazio vira NULL: `X''` não é literal válido no MySQL.
                    if case .blob(let data) = value, data.isEmpty {
                        state.buffer += "NULL"
                    } else {
                        value.appendSQLLiteral(engine: engine, to: &state.buffer)
                    }
                }
                state.buffer += ")"
                state.rowsInStatement += 1
                // `utf8.count` é O(1) numa String nativa — dá para checar a cada linha.
                if state.buffer.utf8.count >= limit {
                    state.buffer += ";\n"
                    try emit(state.buffer)
                    state.buffer.removeAll(keepingCapacity: true)
                    state.rowsInStatement = 0
                }
            }
            state.total += batch.rows.count
            onRows(state.total)
        }

        if state.rowsInStatement > 0 {
            state.buffer += ";\n"
            try emit(state.buffer)
        }
        return state.total
    }

    // MARK: - DDL

    private static func createStatement(
        driver: any DatabaseDriver,
        table: DatabaseTable,
        options: DumpOptions
    ) async throws -> String {
        switch driver.engine {
        case .mysql:
            let keyword = table.kind == "view" ? "VIEW" : "TABLE"
            let ddl = try await queryValue(
                driver: driver,
                sql: "SHOW CREATE \(keyword) \(driver.quoteIdentifier(table.name))",
                column: 1
            )
            guard var ddl else { return "-- falha ao obter DDL de \(table.name)" }
            if options.stripDefiner { ddl = removeDefiner(ddl) }
            if table.kind == "view", options.dropBeforeCreate {
                ddl = "DROP VIEW IF EXISTS \(driver.quoteIdentifier(table.name));\n" + ddl
            }
            return ddl.hasSuffix(";") ? ddl : ddl + ";"
        case .postgres:
            if table.kind == "view" {
                let definition = try? await queryValue(
                    driver: driver,
                    sql: "SELECT pg_get_viewdef('\(escapeLiteral(table.name))'::regclass, true)",
                    column: 0
                )
                // pg_get_viewdef já devolve a definição terminada em ";".
                let body = ((definition ?? nil) ?? "-- falha ao obter definição")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingSuffix(";")
                let drop = options.dropBeforeCreate
                    ? "DROP VIEW IF EXISTS \(driver.quoteIdentifier(table.name)) CASCADE;\n" : ""
                return drop + "CREATE VIEW \(driver.quoteIdentifier(table.name)) AS \(body);"
            }
            return try await createTablePostgres(driver: driver, table: table.name)
        case .sqlite:
            let entries = try await driver.query(
                """
                SELECT sql FROM sqlite_master
                WHERE tbl_name = '\(escapeLiteral(table.name))' AND sql IS NOT NULL
                ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 ELSE 2 END
                """
            )
            let statements = entries.rows.compactMap { row -> String? in
                let sql = row.first?.display ?? ""
                guard !sql.isEmpty else { return nil }
                return sql.hasSuffix(";") ? sql : sql + ";"
            }
            return statements.joined(separator: "\n")
        }
    }

    /// CREATE TABLE do Postgres a partir do `pg_catalog`.
    ///
    /// O `information_schema.columns.data_type` devolve o tipo SEM os modificadores
    /// ("character varying" em vez de "varchar(50)", "numeric" sem precisão): dumps
    /// gerados a partir dele perdiam silenciosamente os limites das colunas no import.
    /// `format_type(atttypid, atttypmod)` devolve o tipo exato como o próprio Postgres
    /// o escreveria.
    private static func createTablePostgres(driver: any DatabaseDriver, table: String) async throws -> String {
        let regclass = "'\(escapeLiteral(driver.quoteIdentifier(table)))'::regclass"
        let result = try await driver.query(
            """
            SELECT a.attname,
                   pg_catalog.format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid),
                   a.attidentity
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(regclass) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        )
        guard !result.rows.isEmpty else { return "-- tabela \(table) sem colunas legíveis" }

        var parts: [String] = []
        for row in result.rows {
            let name = row.count > 0 ? row[0].display : ""
            let type = row.count > 1 ? row[1].display : ""
            let notNull = row.count > 2 && isTrue(row[2])
            let defaultExpression = row.count > 3 ? row[3].display : ""
            let identity = row.count > 4 ? row[4].display : ""
            var part = "\(driver.quoteIdentifier(name)) \(type)"
            if identity == "a" {
                part += " GENERATED ALWAYS AS IDENTITY"
            } else if identity == "d" {
                part += " GENERATED BY DEFAULT AS IDENTITY"
            } else if !defaultExpression.isEmpty {
                part += " DEFAULT \(defaultExpression)"
            }
            if notNull { part += " NOT NULL" }
            parts.append(part)
        }

        let pk = try await driver.primaryKeys(table: table)
        if !pk.isEmpty {
            parts.append("PRIMARY KEY (\(pk.map { driver.quoteIdentifier($0) }.joined(separator: ", ")))")
        }
        return "CREATE TABLE \(driver.quoteIdentifier(table)) (\n  \(parts.joined(separator: ",\n  "))\n);"
    }

    /// Sequences do Postgres. Devolve os statements que só podem rodar DEPOIS das tabelas:
    /// as sequences de colunas `IDENTITY` são criadas pelo próprio `CREATE TABLE`, então
    /// aqui só resta reposicionar o contador delas.
    private static func writePostgresSequences(
        driver: any DatabaseDriver,
        tables: [DatabaseTable],
        selectedNames: Set<String>?,
        emit: @escaping @Sendable (String) throws -> Void
    ) async throws -> [String] {
        // deptype 'i' = sequence interna de uma coluna IDENTITY (recriada pelo CREATE TABLE);
        // 'a' = sequence de um serial (precisa de CREATE SEQUENCE explícito).
        let result = try await driver.query(
            """
            SELECT c.relname, COALESCE(dep.deptype, ''), COALESCE(t.relname, ''), COALESCE(a.attname, '')
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_depend dep
              ON dep.objid = c.oid
             AND dep.classid = 'pg_class'::regclass
             AND dep.deptype IN ('a', 'i')
            LEFT JOIN pg_catalog.pg_class t ON t.oid = dep.refobjid
            LEFT JOIN pg_catalog.pg_attribute a
              ON a.attrelid = dep.refobjid AND a.attnum = dep.refobjsubid
            WHERE n.nspname = current_schema() AND c.relkind = 'S'
            ORDER BY c.relname
            """
        )

        // Numa seleção parcial, sequences sem dono só entram se algum default as citar.
        var referenced: Set<String> = []
        if selectedNames != nil {
            for table in tables where table.kind == "table" {
                let columns = try await driver.columns(table: table.name)
                for sequence in sequencesReferenced(by: columns) {
                    referenced.insert(sequence.replacingOccurrences(of: "\"", with: ""))
                }
            }
        }

        var deferred: [String] = []
        var wroteAny = false
        for row in result.rows where row.count >= 4 {
            try Task.checkCancellation()
            let name = row[0].display
            let deptype = row[1].display
            let ownerTable = row[2].display
            let ownerColumn = row[3].display
            if let selectedNames {
                let ownedBySelected = !ownerTable.isEmpty && selectedNames.contains(ownerTable)
                guard ownedBySelected || referenced.contains(name) else { continue }
            }
            let quoted = driver.quoteIdentifier(name)
            let counter = await sequenceCounter(driver: driver, sequenceRef: quoted)
            if deptype == "i", !ownerTable.isEmpty, !ownerColumn.isEmpty {
                guard let counter else { continue }
                deferred.append(
                    "SELECT setval(pg_get_serial_sequence('\(escapeLiteral(ownerTable))', '\(escapeLiteral(ownerColumn))'), \(counter.last), \(counter.isCalled));"
                )
                continue
            }
            try emit("CREATE SEQUENCE IF NOT EXISTS \(quoted);\n")
            if let counter {
                try emit("SELECT setval('\(escapeLiteral(quoted))', \(counter.last), \(counter.isCalled));\n")
            }
            wroteAny = true
        }
        if wroteAny { try emit("\n") }
        return deferred
    }

    /// Índices e constraints (unique/FK/check) do Postgres.
    private static func writePostgresConstraints(
        driver: any DatabaseDriver,
        only names: Set<String>?,
        emit: @escaping @Sendable (String) throws -> Void
    ) async throws {
        let constraints = try await driver.query(
            """
            SELECT rel.relname, con.conname, pg_catalog.pg_get_constraintdef(con.oid)
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = current_schema() AND con.contype IN ('u', 'f', 'c')
            ORDER BY con.contype DESC, rel.relname, con.conname
            """
        )
        var statements: [String] = []
        for row in constraints.rows where row.count >= 3 {
            let table = row[0].display
            if let names, !names.contains(table) { continue }
            statements.append(
                "ALTER TABLE \(driver.quoteIdentifier(table)) ADD CONSTRAINT \(driver.quoteIdentifier(row[1].display)) \(row[2].display);"
            )
        }

        // Índices que não pertencem a uma constraint (esses já saem no ADD CONSTRAINT
        // e no PRIMARY KEY do CREATE TABLE — emiti-los duas vezes falharia o import).
        let indexes = try await driver.query(
            """
            SELECT i.tablename, i.indexdef
            FROM pg_catalog.pg_indexes i
            WHERE i.schemaname = current_schema()
              AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_constraint c
                JOIN pg_catalog.pg_class ic ON ic.oid = c.conindid
                WHERE ic.relname = i.indexname
              )
            ORDER BY i.tablename, i.indexname
            """
        )
        var indexStatements: [String] = []
        for row in indexes.rows where row.count >= 2 {
            if let names, !names.contains(row[0].display) { continue }
            let definition = row[1].display
            guard !definition.isEmpty else { continue }
            indexStatements.append(definition.hasSuffix(";") ? definition : definition + ";")
        }

        guard !statements.isEmpty || !indexStatements.isEmpty else { return }
        try emit("-- Índices e constraints\n")
        if !indexStatements.isEmpty { try emit(indexStatements.joined(separator: "\n") + "\n") }
        if !statements.isEmpty { try emit(statements.joined(separator: "\n") + "\n") }
        try emit("\n")
    }

    /// Triggers, procedures e functions do MySQL. Saem entre `DELIMITER ;;` porque o
    /// corpo tem `;` interno — o splitter do import entende a diretiva.
    private static func writeMySQLRoutines(
        driver: any DatabaseDriver,
        options: DumpOptions,
        only names: Set<String>?,
        emit: @escaping @Sendable (String) throws -> Void
    ) async throws {
        var blocks: [String] = []

        let triggers = try await driver.query(
            """
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_STATEMENT
            FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = DATABASE()
            ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER
            """
        )
        for row in triggers.rows where row.count >= 5 {
            if let names, !names.contains(row[3].display) { continue }
            let name = driver.quoteIdentifier(row[0].display)
            blocks.append("""
            DROP TRIGGER IF EXISTS \(name);
            CREATE TRIGGER \(name) \(row[1].display) \(row[2].display) ON \(driver.quoteIdentifier(row[3].display))
            FOR EACH ROW \(row[4].display)
            """)
        }

        // Procedures e functions não pertencem a nenhuma tabela: só entram no dump
        // do banco inteiro, nunca na exportação de tabelas escolhidas a dedo.
        let routines = names == nil ? try await driver.query(
            """
            SELECT ROUTINE_NAME, ROUTINE_TYPE
            FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA = DATABASE()
            ORDER BY ROUTINE_TYPE, ROUTINE_NAME
            """
        ) : QueryResult(columns: [], rows: [])
        for row in routines.rows where row.count >= 2 {
            let name = row[0].display
            let kind = row[1].display.uppercased() == "FUNCTION" ? "FUNCTION" : "PROCEDURE"
            // SHOW CREATE PROCEDURE/FUNCTION: (Name, sql_mode, "Create …", …) — DDL na 3ª coluna.
            guard var ddl = try await queryValue(
                driver: driver,
                sql: "SHOW CREATE \(kind) \(driver.quoteIdentifier(name))",
                column: 2
            ) else { continue }
            if options.stripDefiner { ddl = removeDefiner(ddl) }
            blocks.append("DROP \(kind) IF EXISTS \(driver.quoteIdentifier(name));\n\(ddl)")
        }

        guard !blocks.isEmpty else { return }
        try emit("-- Triggers e rotinas\nDELIMITER ;;\n")
        for block in blocks {
            try emit(block.trimmingCharacters(in: .whitespacesAndNewlines) + ";;\n")
        }
        try emit("DELIMITER ;\n\n")
    }

    /// Remove `DEFINER=\`user\`@\`host\`` de um DDL do MySQL.
    static func removeDefiner(_ ddl: String) -> String {
        guard let range = ddl.range(of: #"\s*DEFINER\s*=\s*(`(?:[^`]|``)*`|'(?:[^']|'')*'|\S+)@(`(?:[^`]|``)*`|'(?:[^']|'')*'|\S+)"#,
                                    options: [.regularExpression, .caseInsensitive]) else { return ddl }
        return ddl.replacingCharacters(in: range, with: "")
    }

    // MARK: - Sessão

    private static func sessionHeader(engine: SQLEngine, content: DumpOptions.Content) -> String {
        switch engine {
        case .mysql:
            // Sem isto o restore paga uma verificação de FK, de unicidade e um fsync
            // POR statement — é a diferença entre minutos e horas num banco grande.
            return """
            SET NAMES utf8mb4;
            SET @OLD_FOREIGN_KEY_CHECKS = @@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS = 0;
            SET @OLD_UNIQUE_CHECKS = @@UNIQUE_CHECKS, UNIQUE_CHECKS = 0;
            SET @OLD_SQL_MODE = @@SQL_MODE, SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';
            SET @OLD_AUTOCOMMIT = @@AUTOCOMMIT, AUTOCOMMIT = 0;

            """
        case .sqlite:
            return """
            PRAGMA foreign_keys = OFF;
            BEGIN TRANSACTION;

            """
        case .postgres:
            // Sem BEGIN/COMMIT, como no formato plano do pg_dump. Envolver o arquivo
            // numa transação seria pior que inútil aqui: o PostgresClient trabalha
            // sobre um POOL, então o BEGIN, os INSERTs e o COMMIT podem cair em
            // conexões diferentes — o restore terminaria "sem erros" e sem ter
            // gravado nada. (Quem quiser atomicidade usa `psql --single-transaction`.)
            //
            // Um dump completo já cria as FKs DEPOIS dos dados, então também não
            // precisa desligar gatilhos; só o dump de dados puros, contra um esquema
            // que já tem as constraints, precisa — e aí `session_replication_role`
            // exige superusuário, o que num banco gerenciado falha.
            return content == .dataOnly ? "SET session_replication_role = 'replica';\n\n" : ""
        }
    }

    private static func sessionFooter(engine: SQLEngine, content: DumpOptions.Content) -> String {
        switch engine {
        case .mysql:
            return """

            COMMIT;
            SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS;
            SET UNIQUE_CHECKS = @OLD_UNIQUE_CHECKS;
            SET SQL_MODE = @OLD_SQL_MODE;
            SET AUTOCOMMIT = @OLD_AUTOCOMMIT;

            """
        case .sqlite:
            return """

            COMMIT;
            PRAGMA foreign_keys = ON;

            """
        case .postgres:
            return content == .dataOnly ? "\nSET session_replication_role = 'origin';\n" : ""
        }
    }

    // MARK: - Import

    /// Importa um arquivo .sql sem carregá-lo inteiro na memória (um dump de 200 MB
    /// viraria ~400 MB de String só para começar).
    /// Statements que podem falhar EM SEQUÊNCIA antes de o import abortar. Um dump onde
    /// uma tabela inteira é rejeitada gera dezenas de milhares do MESMO erro — sem o
    /// teto, o import "continuava" por minutos em silêncio e o usuário só descobria no
    /// fim (quando descobria). Erros esparsos (trigger opcional, DEFINER ausente)
    /// passam bem abaixo do limite.
    public static let maxConsecutiveImportErrors = 25

    @discardableResult
    public static func importSQL(
        fileURL: URL,
        driver: any DatabaseDriver,
        cancel: CancelToken? = nil,
        progress: @Sendable (_ statements: Int, _ bytesRead: Int, _ errors: Int) -> Void = { _, _, _ in }
    ) async throws -> (statements: Int, errors: [String]) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let splitter = StatementSplitter()
        var errors: [String] = []
        var consecutive = 0
        var count = 0
        var bytesRead = 0
        var pending = Data()

        try? await setForeignKeyChecks(false, driver: driver)
        do {
            while true {
                if cancel?.isCancelled == true { throw DumpError.cancelled }
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                bytesRead += chunk.count
                pending.append(chunk)
                // Um chunk pode partir um caractere multibyte ao meio: só decodifica o
                // prefixo válido e guarda o resto (no máximo 3 bytes) para o próximo.
                let (text, leftover) = decodeUTF8Prefix(pending)
                pending = leftover
                for statement in splitter.feed(text) {
                    try await run(statement.sql, driver: driver, count: &count, errors: &errors, consecutive: &consecutive)
                }
                progress(count, bytesRead, errors.count)
            }
            if !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) {
                for statement in splitter.feed(tail) {
                    try await run(statement.sql, driver: driver, count: &count, errors: &errors, consecutive: &consecutive)
                }
            }
            for statement in splitter.finish() {
                try await run(statement.sql, driver: driver, count: &count, errors: &errors, consecutive: &consecutive)
            }
        } catch {
            // Aborto (erros em série ou cancelamento): restaura a sessão antes de sair —
            // deixar FOREIGN_KEY_CHECKS=0 pendurado na conexão seria pior que o erro.
            if driver.engine == .mysql { _ = try? await driver.execute("COMMIT") }
            try? await setForeignKeyChecks(true, driver: driver)
            throw error
        }
        // O dump abre uma transação no cabeçalho; arquivos de terceiros podem não fechar.
        if driver.engine == .mysql { _ = try? await driver.execute("COMMIT") }
        try? await setForeignKeyChecks(true, driver: driver)
        progress(count, bytesRead, errors.count)
        return (count, errors)
    }

    public static func importSQL(_ sql: String, driver: any DatabaseDriver) async throws -> (statements: Int, errors: [String]) {
        var errors: [String] = []
        var consecutive = 0
        var count = 0
        try? await setForeignKeyChecks(false, driver: driver)
        let splitter = StatementSplitter()
        do {
            for statement in splitter.feed(sql) + splitter.finish() {
                try await run(statement.sql, driver: driver, count: &count, errors: &errors, consecutive: &consecutive)
            }
        } catch {
            if driver.engine == .mysql { _ = try? await driver.execute("COMMIT") }
            try? await setForeignKeyChecks(true, driver: driver)
            throw error
        }
        if driver.engine == .mysql { _ = try? await driver.execute("COMMIT") }
        try? await setForeignKeyChecks(true, driver: driver)
        return (count, errors)
    }

    private static func run(
        _ statement: String,
        driver: any DatabaseDriver,
        count: inout Int,
        errors: inout [String],
        consecutive: inout Int
    ) async throws {
        do {
            _ = try await driver.execute(statement)
            count += 1
            consecutive = 0
        } catch {
            let described = "\(statement.prefix(80))…\n  → \(error.localizedDescription)"
            errors.append(described)
            consecutive += 1
            if consecutive >= maxConsecutiveImportErrors {
                throw DumpError.tooManyErrors(consecutive: consecutive, sample: described)
            }
        }
    }

    /// Decodifica o maior prefixo UTF-8 válido, devolvendo o resto dos bytes.
    private static func decodeUTF8Prefix(_ data: Data) -> (String, Data) {
        if let text = String(data: data, encoding: .utf8) { return (text, Data()) }
        // Recua no máximo 3 bytes: nenhuma sequência UTF-8 é maior que 4 bytes.
        for back in 1...3 where data.count > back {
            let head = data.prefix(data.count - back)
            if let text = String(data: head, encoding: .utf8) {
                return (text, data.suffix(back))
            }
        }
        return ("", data)
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

    /// Contador capturado NA ORIGEM durante o dump. (A forma antiga,
    /// `setval(..., last_value) FROM seq`, lia o valor no DESTINO na hora do import —
    /// num banco novo isso é 1, e o primeiro INSERT colidiria com os ids importados.)
    private static func sequenceCounter(
        driver: any DatabaseDriver,
        sequenceRef: String
    ) async -> (last: String, isCalled: String)? {
        guard let row = try? await driver.query("SELECT last_value, is_called FROM \(sequenceRef)").rows.first,
              row.count >= 2 else { return nil }
        let isCalled = row[1].display
        return (row[0].display, isCalled == "true" || isCalled == "t" || isCalled == "1" ? "true" : "false")
    }

    /// Nomes de sequence citados em defaults `nextval('…'::regclass)` das colunas.
    private static func sequencesReferenced(by columns: [DatabaseColumn]) -> [String] {
        columns.compactMap { column in
            guard let expression = column.defaultValue,
                  let match = expression.firstMatch(of: /nextval\('([^']+)'/) else { return nil }
            return String(match.1)
        }
    }

    private static func queryValue(driver: any DatabaseDriver, sql: String, column: Int) async throws -> String? {
        let result = try await driver.query(sql)
        guard let row = result.rows.first else { return nil }
        let value = column < row.count ? row[column] : row.last
        return value?.display
    }

    private static func isTrue(_ value: SQLValue) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .text(let text): return text == "t" || text.lowercased() == "true" || text == "1"
        default: return false
        }
    }

    private static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Splitter

    /// Divide SQL em statements respeitando aspas simples, duplas, crases e comentários.
    public static func splitStatements(_ sql: String) -> [String] {
        statements(in: sql).map(\.sql)
    }

    /// Igual ao `splitStatements`, mas preservando onde cada statement está no texto —
    /// o console usa a faixa para achar o comando sob o cursor e para apontar o que falhou.
    public static func statements(in sql: String) -> [SQLStatement] {
        let splitter = StatementSplitter()
        return splitter.feed(sql) + splitter.finish()
    }
}

/// Um statement com a faixa que ele ocupa no texto original.
///
/// A faixa vem em unidades UTF-16 (a mesma medida do `NSRange` do `NSTextView`), então o
/// console consegue casar o cursor com o statement sob ele sem reconverter índices — e
/// consegue apontar exatamente qual comando de um script falhou.
public struct SQLStatement: Sendable, Equatable {
    /// SQL já sem os brancos das pontas e sem o delimitador.
    public let sql: String
    public let location: Int
    public let length: Int

    public init(sql: String, location: Int, length: Int) {
        self.sql = sql
        self.location = location
        self.length = length
    }

    public var endLocation: Int { location + length }

    /// `true` quando o cursor está dentro do statement — inclusive encostado nas pontas,
    /// que é onde o cursor fica depois de digitar o comando.
    public func contains(_ offset: Int) -> Bool {
        offset >= location && offset <= endLocation
    }
}

/// Splitter incremental: aceita o SQL em pedaços (para importar arquivos grandes sem
/// carregá-los inteiros) e devolve os statements completos de cada pedaço.
/// Entende aspas, crases, comentários de linha/bloco e a diretiva `DELIMITER`
/// (necessária para triggers e procedures, cujo corpo tem `;` interno).
public final class StatementSplitter {
    private var current = ""
    private var quote: Character?
    /// Próximo caractere está escapado por `\` dentro de uma string (MySQL).
    private var escapeNext = false
    private var lineComment = false
    private var blockComment = false
    /// Caracteres já consumidos do comentário de bloco: impede que `/*/` feche cedo.
    private var blockCommentBody = 0
    private var delimiter: [Character] = [";"]
    /// Quantos caracteres do delimitador já casaram (delimitadores multi-caractere
    /// como `;;` podem vir partidos entre dois chunks do arquivo).
    private var matched = 0
    /// Linha corrente, limitada: só serve para reconhecer a diretiva `DELIMITER`.
    private var lineBuffer = ""
    /// Lendo o valor de uma diretiva `DELIMITER` até o fim da linha.
    private var collectingDirective = false
    private var directiveValue = ""
    /// Corpo dollar-quoted do Postgres (`$$…$$`, `$body$…$body$`). Dentro dele NADA é
    /// interpretado — nem aspas, nem comentários, nem o delimitador: o `;` que separa os
    /// comandos de uma function/procedure/DO block é parte do corpo. Sem isto o splitter
    /// partia a function no primeiro `;` interno e o import morria no fragmento.
    /// Guarda o delimitador de fechamento inteiro (`$body$`), não só o rótulo.
    private var dollarQuote: [Character]?
    /// Quantos caracteres do fechamento já casaram.
    private var dollarMatched = 0
    /// Rótulo em formação entre o primeiro `$` e o segundo (`$body$` → "body").
    /// `nil` fora de um rótulo; `""` logo depois do `$` de abertura.
    private var pendingDollarTag: String?
    /// Posição UTF-16 do caractere sendo consumido. Mantida entre chunks: um arquivo
    /// lido em pedaços continua produzindo faixas relativas ao texto inteiro.
    private var position = 0
    /// Onde o statement corrente começou (antes de aparar os brancos). Aparar por
    /// caractere custaria um teste de whitespace por byte do dump; medir só na emissão
    /// é O(statement) uma vez, não O(arquivo).
    private var rawStart: Int?

    public init() {}

    public func feed(_ text: String) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        for character in text {
            consume(character, into: &statements)
            position += character.utf16.count
        }
        return statements
    }

    public func finish() -> [SQLStatement] {
        var statements: [SQLStatement] = []
        releaseMatched()
        emit(into: &statements)
        return statements
    }

    /// Fecha o statement acumulado e o publica com a faixa que ocupa no texto original.
    private func emit(into statements: inout [SQLStatement]) {
        let raw = current
        let start = rawStart
        current = ""
        rawStart = nil
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let start else { return }
        // Quanto do começo era branco — o que separa `rawStart` do primeiro caractere real.
        let leading = raw.utf16.count - raw.drop(while: { $0.isWhitespace }).utf16.count
        statements.append(SQLStatement(sql: trimmed, location: start + leading, length: trimmed.utf16.count))
    }

    private func consume(_ character: Character, into statements: inout [SQLStatement]) {
        if lineComment {
            append(character)
            if character == "\n" { lineComment = false }
            return
        }
        if blockComment {
            append(character)
            blockCommentBody += 1
            if blockCommentBody >= 2, current.hasSuffix("*/") { blockComment = false }
            return
        }
        if let open = quote {
            append(character)
            if escapeNext {
                escapeNext = false
            } else if character == "\\", open != "`" {
                // No MySQL `\` escapa dentro de string; dumps de terceiros usam `\'`.
                escapeNext = true
            } else if character == open {
                // Aspa dobrada ('') fecha e reabre — efeito idêntico ao escape.
                quote = nil
            }
            return
        }

        // Dentro do corpo dollar-quoted só interessa achar o fechamento.
        if let closing = dollarQuote {
            append(character)
            if character == closing[dollarMatched] {
                dollarMatched += 1
                if dollarMatched == closing.count {
                    dollarQuote = nil
                    dollarMatched = 0
                }
            } else {
                // Um rótulo não pode conter `$`, então um casamento parcial que falha só
                // pode recomeçar no próprio `$` (`$a$` dentro de um corpo `$ab$`).
                dollarMatched = character == closing[0] ? 1 : 0
            }
            return
        }

        // Rótulo em formação: caracteres válidos seguem acumulando, qualquer outro
        // desiste — é assim que o `$1` de um parâmetro do Postgres não abre corpo nenhum.
        if let tag = pendingDollarTag, character != "$" {
            if Self.isTagCharacter(character, isFirst: tag.isEmpty) {
                pendingDollarTag = tag + String(character)
                append(character)
                return
            }
            pendingDollarTag = nil
        }

        // Diretiva `DELIMITER xx`: o valor vem ANTES de qualquer outra interpretação,
        // senão o `;;` do `DELIMITER ;;` seria lido como fim de statement.
        if collectingDirective {
            if character == "\n" || character == "\r" {
                let value = directiveValue.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { delimiter = Array(value) }
                collectingDirective = false
                current.append(character)
                lineBuffer = ""
            } else {
                directiveValue.append(character)
            }
            return
        }
        if character == " " || character == "\t",
           lineBuffer.trimmingCharacters(in: .whitespaces).uppercased() == "DELIMITER" {
            current.removeLast(min(lineBuffer.count, current.count))
            collectingDirective = true
            directiveValue = ""
            return
        }

        // Delimitador de statement (";" ou o definido por DELIMITER).
        if character == delimiter[matched] {
            matched += 1
            if matched == delimiter.count {
                matched = 0
                lineBuffer = ""
                emit(into: &statements)
            }
            // Os caracteres do delimitador nunca entram no statement.
            return
        }
        releaseMatched()

        switch character {
        case "-" where current.hasSuffix("-"):
            lineComment = true
            append(character)
        case "*" where current.hasSuffix("/"):
            blockComment = true
            blockCommentBody = 0
            append(character)
        case "$":
            if let tag = pendingDollarTag {
                // Segundo `$`: fecha o rótulo e abre o corpo.
                append(character)
                dollarQuote = Array("$" + tag + "$")
                dollarMatched = 0
                pendingDollarTag = nil
            } else {
                // `$` colado num identificador (`meu$campo`, `tab$1`) não abre corpo:
                // o Postgres só reconhece dollar-quote começando fora de um token.
                let previous = current.last
                if previous == nil || !Self.isTagCharacter(previous!, isFirst: false) {
                    pendingDollarTag = ""
                }
                append(character)
            }
        case "'", "\"", "`":
            quote = character
            append(character)
        case "\n", "\r":
            append(character)
            lineBuffer = ""
        default:
            append(character)
        }
    }

    /// Caracteres aceitos num rótulo de dollar-quote — as mesmas regras de um
    /// identificador do Postgres: letra ou `_` no começo, dígitos também depois.
    private static func isTagCharacter(_ character: Character, isFirst: Bool) -> Bool {
        if character == "_" || character.isLetter { return true }
        return !isFirst && character.isNumber
    }

    private func append(_ character: Character) {
        // Primeiro caractere depois do delimitador anterior: aqui começa o statement.
        if current.isEmpty { rawStart = position }
        current.append(character)
        // Uma diretiva DELIMITER é curta; passando disso a linha não é uma.
        if lineBuffer.count < 64 { lineBuffer.append(character) }
    }

    /// Devolve ao statement os caracteres segurados por um casamento parcial do delimitador.
    private func releaseMatched() {
        guard matched > 0 else { return }
        // Os caracteres segurados terminam no caractere corrente: devolvê-los com a
        // posição de agora deslocaria a faixa do statement pelo tamanho do delimitador.
        let base = position - matched
        let current = position
        for index in 0..<matched {
            position = base + index
            append(delimiter[index])
        }
        position = current
        matched = 0
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
