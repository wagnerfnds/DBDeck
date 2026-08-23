import Foundation
import XCTest
@testable import DBDeckCore

final class SQLiteDriverTests: XCTestCase {
    func testFullCycle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let config = ConnectionConfig(
            name: "teste",
            engine: .sqlite,
            sqlitePath: url.path
        )
        let driver = SQLiteDriver(config: config)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        try await driver.execute("""
            CREATE TABLE pessoas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nome TEXT NOT NULL,
                idade INTEGER,
                ativo BOOLEAN DEFAULT 1
            )
        """)
        try await driver.execute("INSERT INTO pessoas (nome, idade) VALUES ('João O''Brien', 30)")
        try await driver.execute("INSERT INTO pessoas (nome, idade, ativo) VALUES ('Maria', 25, 0)")

        let tables = try await driver.tables()
        XCTAssertEqual(tables.map(\.name), ["pessoas"])
        XCTAssertEqual(tables.first?.kind, "table")

        let columns = try await driver.columns(table: "pessoas")
        XCTAssertEqual(columns.map(\.name), ["id", "nome", "idade", "ativo"])
        XCTAssertTrue(columns.first?.isPrimaryKey == true)

        let pks = try await driver.primaryKeys(table: "pessoas")
        XCTAssertEqual(pks, ["id"])

        var result = try await driver.query("SELECT * FROM pessoas ORDER BY id")
        XCTAssertEqual(result.columns, ["id", "nome", "idade", "ativo"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0][1], .text("João O'Brien"))

        let updated = try await driver.updateRow(
            table: "pessoas",
            primaryKey: ["id"],
            pkValues: [.int(1)],
            changes: [("idade", .int(31))]
        )
        XCTAssertEqual(updated, 1)

        let inserted = try await driver.insertRow(
            table: "pessoas",
            values: [("nome", .text("Pedro")), ("idade", .int(40))]
        )
        XCTAssertEqual(inserted, 1)

        let deleted = try await driver.deleteRow(
            table: "pessoas",
            primaryKey: ["id"],
            pkValues: [.int(3)]
        )
        XCTAssertEqual(deleted, 1)

        result = try await driver.query("SELECT COUNT(*) AS total FROM pessoas")
        XCTAssertEqual(result.rows[0][0], .int(2))

        let dump = try await SQLDump.dump(driver: driver)
        XCTAssertTrue(dump.contains("CREATE TABLE"))
        XCTAssertTrue(dump.contains("João O''Brien"))

        let importURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: importURL) }
        let importDriver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: importURL.path))
        try await importDriver.connect()
        defer { Task { await importDriver.disconnect() } }

        let (statements, errors) = try await SQLDump.importSQL(dump, driver: importDriver)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertGreaterThanOrEqual(statements, 2)

        let importedCount = try await importDriver.countRows(table: "pessoas")
        XCTAssertEqual(importedCount, 2)
    }

    func testCSVEscaping() {
        let result = QueryResult(
            columns: ["a", "b"],
            rows: [[.text("x,y"), .text("com \"aspas\"")], [.int(1), .null]]
        )
        let csv = CSVExporter.export(result: result, fileName: "t")
        XCTAssertTrue(csv.contains("\"x,y\""))
        XCTAssertTrue(csv.contains("\"com \"\"aspas\"\"\""))
        XCTAssertTrue(csv.contains("1,"))
    }

    func testSplitStatements() {
        let sql = """
        -- comentário; com ponto e vírgula
        INSERT INTO t (a) VALUES ('a;b''c');
        /* bloco; comentário */
        SELECT 1;
        """
        let statements = SQLDump.splitStatements(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("'a;b''c'"))
        XCTAssertTrue(statements[1].contains("SELECT 1"))
    }

    func testDumpImportComFKIndexView() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-fk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        try await driver.execute("CREATE TABLE pais (id INTEGER PRIMARY KEY, nome TEXT NOT NULL)")
        try await driver.execute("""
            CREATE TABLE cidade (
                id INTEGER PRIMARY KEY,
                nome TEXT NOT NULL,
                pais_id INTEGER REFERENCES pais(id) ON DELETE CASCADE
            )
        """)
        try await driver.execute("INSERT INTO pais (id, nome) VALUES (1, 'Brasil')")
        try await driver.execute("INSERT INTO cidade (id, nome, pais_id) VALUES (1, 'São Paulo', 1)")
        try await driver.execute("CREATE INDEX idx_cidade_nome ON cidade(nome)")
        try await driver.execute("CREATE VIEW v_pais AS SELECT nome FROM pais")

        do {
            _ = try await driver.execute("INSERT INTO cidade (id, nome, pais_id) VALUES (99, 'X', 999)")
            XCTFail("FK deveria bloquear insert inválido")
        } catch {
            // esperado
        }

        let dump = try await SQLDump.dump(driver: driver)
        XCTAssertTrue(dump.contains("REFERENCES"))
        XCTAssertTrue(dump.contains("CREATE INDEX"))
        XCTAssertTrue(dump.contains("CREATE VIEW"))
        XCTAssertTrue(dump.contains("'Brasil'"))

        let importURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-fk-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: importURL) }
        let importDriver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: importURL.path))
        try await importDriver.connect()
        defer { Task { await importDriver.disconnect() } }

        let (statements, errors) = try await SQLDump.importSQL(dump, driver: importDriver)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(statements, 2)

        let count = try await importDriver.countRows(table: "cidade")
        XCTAssertEqual(count, 1)

        do {
            _ = try await importDriver.execute("INSERT INTO cidade (id, nome, pais_id) VALUES (99, 'X', 999)")
            XCTFail("FK deveria estar valendo no banco importado")
        } catch {
            // esperado
        }
    }

    // MARK: - Corte de valores na origem (previewLimit)

    /// Cria um banco temporário com uma tabela e devolve o driver conectado.
    private func makeDriver(_ setup: [String]) async throws -> (SQLiteDriver, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-preview-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        for statement in setup { try await driver.execute(statement) }
        return (driver, url)
    }

    func testPreviewLimitCortaTextoGrandeEPreservaOValorIntegro() async throws {
        let big = String(repeating: "a", count: 5000)
        let (driver, url) = try await makeDriver([
            "CREATE TABLE t (id INTEGER PRIMARY KEY, corpo TEXT)",
            "INSERT INTO t (id, corpo) VALUES (1, '\(big)')"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try await driver.query("SELECT corpo FROM t", previewLimit: 256)
        guard case .truncated(let prefix, let byteCount, let isBinary) = preview.rows[0][0] else {
            return XCTFail("valor grande deveria vir cortado, veio \(preview.rows[0][0])")
        }
        XCTAssertEqual(prefix.count, 256)
        XCTAssertEqual(byteCount, 5000)
        XCTAssertFalse(isBinary)
        XCTAssertEqual(preview.rows[0][0].display, prefix + "…")

        // Sem limite, o mesmo SELECT devolve o valor inteiro — é o caminho que a
        // edição/exportação usa.
        let full = try await driver.query("SELECT corpo FROM t", previewLimit: nil)
        XCTAssertEqual(full.rows[0][0], .text(big))

        // Valor abaixo do limite não é tocado.
        let small = try await driver.query("SELECT id FROM t", previewLimit: 256)
        XCTAssertEqual(small.rows[0][0], .int(1))

        await driver.disconnect()
    }

    func testPreviewLimitNaoParteCaractereMultibyte() async throws {
        // 200 caracteres de 3 bytes: o corte cru em 256 bytes cairia no meio de um "★".
        let big = String(repeating: "★", count: 200)
        let (driver, url) = try await makeDriver([
            "CREATE TABLE t (corpo TEXT)",
            "INSERT INTO t (corpo) VALUES ('\(big)')"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try await driver.query("SELECT corpo FROM t", previewLimit: 256)
        guard case .truncated(let prefix, let byteCount, _) = preview.rows[0][0] else {
            return XCTFail("valor grande deveria vir cortado, veio \(preview.rows[0][0])")
        }
        XCTAssertEqual(byteCount, 600)
        // 256 / 3 = 85 caracteres inteiros; o byte 256 partiria o 86º.
        XCTAssertEqual(prefix, String(repeating: "★", count: 85))
        XCTAssertFalse(prefix.isEmpty, "corte no meio do caractere devolveria string vazia")

        await driver.disconnect()
    }

    func testPreviewLimitMarcaBlobComoBinario() async throws {
        let (driver, url) = try await makeDriver([
            "CREATE TABLE t (dado BLOB)",
            "INSERT INTO t (dado) VALUES (randomblob(4096))"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try await driver.query("SELECT dado FROM t", previewLimit: 256)
        guard case .truncated(_, let byteCount, let isBinary) = preview.rows[0][0] else {
            return XCTFail("blob grande deveria vir cortado, veio \(preview.rows[0][0])")
        }
        XCTAssertEqual(byteCount, 4096)
        XCTAssertTrue(isBinary)
        XCTAssertTrue(preview.rows[0][0].display.contains("KB"))

        await driver.disconnect()
    }

    /// Rede de segurança: um prefixo nunca pode virar literal SQL — seria gravar dado
    /// cortado por cima do original.
    func testValorTruncadoNuncaViraLiteral() {
        let value = SQLValue.truncated(prefix: "abc", byteCount: 9999, isBinary: false)
        XCTAssertTrue(value.isTruncated)
        for engine in SQLEngine.allCases {
            XCTAssertEqual(value.sqlLiteral(engine: engine), "DEFAULT")
        }
        XCTAssertFalse(SQLValue.text("abc").isTruncated)
    }

    // MARK: - Contagem de linhas

    func testRowCountSQLiteEhExato() async throws {
        let (driver, url) = try await makeDriver([
            "CREATE TABLE t (id INTEGER PRIMARY KEY)",
            "INSERT INTO t (id) VALUES (1), (2), (3)"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try await driver.rowCount(table: "t", allowExactScan: false)
        XCTAssertEqual(count.value, 3)
        XCTAssertFalse(count.isEstimate)
        XCTAssertTrue(count.isKnown)
        XCTAssertFalse(RowCountEstimate.unknown.isKnown)

        await driver.disconnect()
    }

    // MARK: - Classificação de colunas

    func testIsBlobOrTextSeparaColunasGrandes() {
        func column(_ type: String) -> DatabaseColumn {
            DatabaseColumn(name: "c", type: type, isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, ordinal: 1)
        }
        for type in ["text", "LONGTEXT", "mediumtext", "blob", "LONGBLOB", "json", "jsonb", "bytea"] {
            XCTAssertTrue(column(type).isBlobOrText, "\(type) deveria contar como grande")
        }
        // varchar tem tamanho declarado e cabe na célula: adiá-la não compensaria.
        for type in ["varchar(255)", "character varying(64)", "int", "timestamp", "numeric(10,2)", "uuid"] {
            XCTAssertFalse(column(type).isBlobOrText, "\(type) NÃO deveria contar como grande")
        }
    }

    func testDumpIgnoraColunasGeradas() async throws {
        let (driver, url) = try await makeDriver([
            """
            CREATE TABLE precos (
                id INTEGER PRIMARY KEY,
                base REAL NOT NULL,
                taxa REAL NOT NULL,
                total REAL GENERATED ALWAYS AS (base * (1 + taxa)) STORED,
                total_virtual REAL GENERATED ALWAYS AS (base * 2) VIRTUAL
            )
            """,
            "INSERT INTO precos (id, base, taxa) VALUES (1, 100.0, 0.1), (2, 50.0, 0.2)"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        // O driver marca as geradas…
        let columns = try await driver.columns(table: "precos")
        XCTAssertEqual(columns.filter(\.isGenerated).map(\.name).sorted(), ["total", "total_virtual"])
        XCTAssertEqual(columns.count, 5, "geradas continuam listadas (grid/estrutura as mostram)")

        // …e o dump as deixa fora dos INSERTs.
        let dump = try await SQLDump.dumpTable(
            driver: driver,
            table: DatabaseTable(name: "precos", kind: "table")
        )
        XCTAssertTrue(dump.contains("INSERT INTO \"precos\""))
        let insertLine = dump.split(separator: "\n").first { $0.hasPrefix("INSERT INTO") } ?? ""
        XCTAssertFalse(insertLine.contains("total"), "INSERT não pode listar coluna gerada: \(insertLine)")

        // Round-trip: o dump importa limpo num banco novo e o servidor recalcula.
        let (importDriver, url2) = try await makeDriver([])
        defer { try? FileManager.default.removeItem(at: url2) }
        for statement in SQLDump.splitStatements(dump) {
            _ = try await importDriver.execute(statement)
        }
        let reimported = try await importDriver.query("SELECT total FROM precos ORDER BY id")
        XCTAssertEqual(reimported.rows.count, 2)
        guard case .double(let total) = reimported.rows[0][0] else {
            return XCTFail("total deveria ser double, veio \(reimported.rows[0][0])")
        }
        XCTAssertEqual(total, 110.0, accuracy: 0.0001)

        await driver.disconnect()
        await importDriver.disconnect()
    }

    /// Um dump onde uma tabela inteira falha não pode "importar" em silêncio: depois de
    /// N erros seguidos o import aborta com uma mensagem que aponta o statement.
    func testImportAbortaAposErrosConsecutivos() async throws {
        let (driver, url) = try await makeDriver(["CREATE TABLE ok (id INTEGER PRIMARY KEY)"])
        defer { try? FileManager.default.removeItem(at: url) }

        var script = "INSERT INTO ok (id) VALUES (1);\n"
        for i in 0..<(SQLDump.maxConsecutiveImportErrors + 10) {
            script += "INSERT INTO tabela_inexistente (x) VALUES (\(i));\n"
        }
        do {
            _ = try await SQLDump.importSQL(script, driver: driver)
            XCTFail("deveria abortar por erros consecutivos")
        } catch let error as DumpError {
            guard case .tooManyErrors(let consecutive, let sample) = error else {
                return XCTFail("erro inesperado: \(error)")
            }
            XCTAssertEqual(consecutive, SQLDump.maxConsecutiveImportErrors)
            XCTAssertTrue(sample.contains("tabela_inexistente"))
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription!.contains("interrompida"))
        }

        // Erros ESPARSOS continuam tolerados (idempotência de re-import).
        let sparse = """
        INSERT INTO nada1 (x) VALUES (1);
        INSERT INTO ok (id) VALUES (2);
        INSERT INTO nada2 (x) VALUES (1);
        INSERT INTO ok (id) VALUES (3);
        """
        let (statements, errors) = try await SQLDump.importSQL(sparse, driver: driver)
        XCTAssertEqual(statements, 2)
        XCTAssertEqual(errors.count, 2)

        await driver.disconnect()
    }

    // MARK: - Exportação (CSV/JSON/SQL)

    func testResultExporterFormatos() throws {
        let columns = ["id", "nome", "ativo", "nota", "dados"]
        let rows: [[SQLValue]] = [
            [.int(1), .text("Ana \"a\", linha\ndupla"), .bool(true), .double(4.5), .blob(Data([0xFF, 0x00]))],
            [.int(2), .null, .bool(false), .null, .null],
        ]

        // CSV: header + escape de aspas/vírgula/quebra + BOM.
        let csv = ResultExporter.export(format: .csv, columns: columns, rows: rows,
                                        tableName: "t", engine: .mysql)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}id,nome,ativo,nota,dados"))
        XCTAssertTrue(csv.contains("\"Ana \"\"a\"\", linha\ndupla\""))
        XCTAssertTrue(csv.contains("2,,false,,"))

        // JSON: array válido, tipos nativos, blob em base64, ordem das chaves.
        let json = ResultExporter.export(format: .json, columns: columns, rows: rows,
                                         tableName: "t", engine: .mysql)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["id"] as? Int, 1)
        XCTAssertEqual(parsed?[0]["ativo"] as? Bool, true)
        XCTAssertEqual(parsed?[0]["dados"] as? String, Data([0xFF, 0x00]).base64EncodedString())
        XCTAssertTrue(parsed?[1]["nome"] is NSNull)
        XCTAssertTrue(json.range(of: "\"id\":").map { json.distance(from: json.startIndex, to: $0.lowerBound) < json.range(of: "\"nome\":")!.lowerBound.utf16Offset(in: json) } ?? false)

        // SQL: INSERT com identificadores e literais do engine.
        let sql = ResultExporter.export(format: .sql, columns: columns, rows: rows,
                                        tableName: "minha tabela", engine: .mysql)
        XCTAssertTrue(sql.contains("INSERT INTO `minha tabela` (`id`, `nome`, `ativo`, `nota`, `dados`) VALUES"))
        XCTAssertTrue(sql.contains("(1,'Ana \"a\", linha\ndupla',TRUE,4.5,X'FF00')"))
        XCTAssertTrue(sql.contains("(2,NULL,FALSE,NULL,NULL);"))
    }

    func testExportTableStreaming() async throws {
        let (driver, url) = try await makeDriver([
            "CREATE TABLE t (id INTEGER PRIMARY KEY, nome TEXT)",
            """
            WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 5000)
            INSERT INTO t (id, nome) SELECT n, 'linha_' || n FROM s
            """
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        final class Sink: @unchecked Sendable { var text = ""; var lastProgress = 0 }
        let sink = Sink()
        let total = try await ResultExporter.exportTable(
            driver: driver, table: "t", format: .json, batchSize: 500,
            write: { sink.text += $0 },
            progress: { sink.lastProgress = $0 }
        )
        XCTAssertEqual(total, 5000)
        XCTAssertEqual(sink.lastProgress, 5000)
        let parsed = try JSONSerialization.jsonObject(with: Data(sink.text.utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 5000)
        XCTAssertEqual(parsed?.last?["nome"] as? String, "linha_5000")

        // Tabela vazia gera arquivo válido.
        _ = try await driver.execute("CREATE TABLE vazia (a TEXT)")
        let empty = Sink()
        let none = try await ResultExporter.exportTable(
            driver: driver, table: "vazia", format: .json,
            write: { empty.text += $0 }
        )
        XCTAssertEqual(none, 0)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(empty.text.utf8)))

        await driver.disconnect()
    }

    func testKeychain() throws {
        let uuid = UUID()
        defer { KeychainManager.deletePassword(for: uuid) }
        XCTAssertNil(KeychainManager.password(for: uuid))
        KeychainManager.setPassword("senha@123", for: uuid)
        XCTAssertEqual(KeychainManager.password(for: uuid), "senha@123")
        KeychainManager.deletePassword(for: uuid)
        XCTAssertNil(KeychainManager.password(for: uuid))
    }
}
