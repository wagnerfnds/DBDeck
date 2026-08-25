import Foundation
import XCTest
@testable import DBDeckCore

final class DumpTests: XCTestCase {
    private func makeDriver(_ file: StaticString = #filePath) async throws -> (SQLiteDriver, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-dump-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        return (driver, url)
    }

    // MARK: - Literais

    func testEscapaBarraInvertidaSomenteNoMySQL() {
        let value = SQLValue.text(#"C:\Users\ana's"#)
        // MySQL trata `\` como escape: sem dobrar, o re-import corrompe o valor.
        XCTAssertEqual(value.sqlLiteral(engine: .mysql), #"'C:\\Users\\ana''s'"#)
        // Postgres/SQLite: barra é literal, dobrar quebraria o dado.
        XCTAssertEqual(value.sqlLiteral(engine: .postgres), #"'C:\Users\ana''s'"#)
        XCTAssertEqual(value.sqlLiteral(engine: .sqlite), #"'C:\Users\ana''s'"#)
    }

    func testLiteralSemEscapeMantemTextoIntacto() {
        XCTAssertEqual(SQLValue.text("são paulo 🇧🇷").sqlLiteral(engine: .mysql), "'são paulo 🇧🇷'")
    }

    func testLiteralDeBlobEmHex() {
        let value = SQLValue.blob(Data([0x00, 0x0F, 0xFF]))
        XCTAssertEqual(value.sqlLiteral(engine: .mysql), "X'000FFF'")
        XCTAssertEqual(value.sqlLiteral(engine: .postgres), "decode('000FFF', 'hex')")
    }

    // MARK: - Splitter

    func testSplitterEntendeDelimiterDeTrigger() {
        let sql = """
        INSERT INTO t VALUES (1);
        DELIMITER ;;
        CREATE TRIGGER tg BEFORE INSERT ON t FOR EACH ROW BEGIN
          SET NEW.a = 1;
          SET NEW.b = 2;
        END;;
        DELIMITER ;
        SELECT 1;
        """
        let statements = SQLDump.splitStatements(sql)
        XCTAssertEqual(statements.count, 3)
        XCTAssertTrue(statements[0].contains("INSERT INTO t"))
        // O corpo do trigger sai inteiro, com os `;` internos preservados.
        XCTAssertTrue(statements[1].contains("SET NEW.a = 1;"))
        XCTAssertTrue(statements[1].contains("END"))
        XCTAssertTrue(statements[2].contains("SELECT 1"))
    }

    func testSplitterRespeitaBarraInvertidaDentroDeString() {
        // Dumps do mysqldump usam `\'` — fechar a string ali partiria o statement no meio.
        let statements = SQLDump.splitStatements(#"INSERT INTO t VALUES ('a\'; b'); SELECT 2;"#)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains(#"'a\'; b'"#))
    }

    func testSplitterMantemCorpoDollarQuotedInteiro() {
        let sql = """
        CREATE FUNCTION soma(a int, b int) RETURNS int AS $$
        BEGIN
          RAISE NOTICE 'somando; com ponto e vírgula';
          RETURN a + b;
        END;
        $$ LANGUAGE plpgsql;
        SELECT soma(1, 2);
        """
        let statements = SQLDump.splitStatements(sql)
        // O corpo tem três `;` internos: partir em qualquer um deles gera fragmentos inválidos.
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("RETURN a + b;"))
        XCTAssertTrue(statements[0].hasSuffix("LANGUAGE plpgsql"))
        XCTAssertTrue(statements[1].contains("SELECT soma(1, 2)"))
    }

    func testSplitterFechaDollarQuoteSomenteNoRotuloCorreto() {
        // `$a$` dentro de um corpo `$ab$` não fecha nada — o fechamento é o rótulo inteiro.
        let statements = SQLDump.splitStatements("DO $ab$ SELECT $a$ x; $ab$; SELECT 1;")
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("$a$ x;"))
        XCTAssertTrue(statements[1].contains("SELECT 1"))
    }

    func testSplitterNaoConfundeCifraoDeParametroOuIdentificador() {
        // `$1` (parâmetro) e `meu$campo` (identificador) não abrem corpo dollar-quoted:
        // se abrissem, o `;` seguinte seria engolido e os statements virariam um só.
        let statements = SQLDump.splitStatements("SELECT $1, meu$campo FROM t; SELECT 2;")
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("$1"))
        XCTAssertTrue(statements[1].contains("SELECT 2"))
    }

    func testSplitterIncrementalAceitaDollarQuotePartidoEntreChunks() {
        // O import lê o arquivo em pedaços: o corpo pode ser cortado em qualquer ponto.
        let splitter = StatementSplitter()
        var statements = splitter.feed("DO $$ BEGIN RAISE NOTICE 'a; b';")
        XCTAssertTrue(statements.isEmpty)
        statements += splitter.feed(" END $$; SELECT 1;")
        statements += splitter.finish()
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("RAISE NOTICE 'a; b';"))
    }

    // MARK: - Faixas dos statements

    func testFaixaDoStatementRecortaOTextoOriginal() {
        let sql = "SELECT 1;\n\n  UPDATE t SET a = 2;  \nDELETE FROM t;"
        let statements = SQLDump.statements(in: sql)
        XCTAssertEqual(statements.count, 3)
        // A faixa tem que recortar exatamente o statement — é ela que o console usa
        // para destacar/reexecutar o comando sob o cursor.
        let text = sql as NSString
        for statement in statements {
            XCTAssertEqual(text.substring(with: NSRange(location: statement.location, length: statement.length)), statement.sql)
        }
        XCTAssertEqual(statements[1].sql, "UPDATE t SET a = 2")
    }

    func testFaixaEmUTF16AcompanhaTextoMultibyte() {
        // O NSTextView mede em UTF-16: contar Characters deslocaria a faixa em qualquer
        // consulta com acento ou emoji, e o console recortaria o statement errado.
        let sql = "SELECT 'ação 🇧🇷';\nSELECT 2;"
        let statements = SQLDump.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        let text = sql as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: statements[1].location, length: statements[1].length)),
            "SELECT 2"
        )
    }

    func testStatementSobOCursor() {
        let sql = "SELECT 1;\nSELECT 2;"
        let statements = SQLDump.statements(in: sql)
        // Cursor encostado no fim do primeiro comando (onde ele fica ao acabar de digitar).
        XCTAssertTrue(statements[0].contains(8))
        XCTAssertFalse(statements[1].contains(8))
        XCTAssertTrue(statements[1].contains(12))
    }

    func testFaixaIncrementalUsaPosicaoAbsolutaDoTextoInteiro() {
        let splitter = StatementSplitter()
        var statements = splitter.feed("SELECT 1; SEL")
        statements += splitter.feed("ECT 2;")
        statements += splitter.finish()
        XCTAssertEqual(statements.count, 2)
        // O segundo statement começa depois do primeiro chunk: a posição não pode
        // reiniciar a cada pedaço lido do arquivo.
        XCTAssertEqual(statements[1].location, 10)
        XCTAssertEqual(statements[1].sql, "SELECT 2")
    }

    func testSplitterNaoFechaComentarioDeBlocoCedo() {
        let statements = SQLDump.splitStatements("/*/ ainda comentário; */ SELECT 1;")
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].hasSuffix("SELECT 1"))
    }

    func testSplitterIncrementalAceitaCorteNoMeioDoStatement() {
        let splitter = StatementSplitter()
        var statements = splitter.feed("SELECT 'a;b")
        XCTAssertTrue(statements.isEmpty)
        statements += splitter.feed("c'; SELECT 2;")
        statements += splitter.finish()
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("'a;bc'"))
    }

    func testRemoveDefiner() {
        let ddl = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v` AS SELECT 1"
        let cleaned = SQLDump.removeDefiner(ddl)
        XCTAssertFalse(cleaned.contains("DEFINER=`root`"))
        XCTAssertTrue(cleaned.contains("VIEW `v`"))
    }

    // MARK: - Opções de dump

    func testSomenteEstruturaESomenteDados() async throws {
        let (driver, url) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: url) }
        try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, nome TEXT)")
        try await driver.execute("INSERT INTO t (id, nome) VALUES (1, 'ana')")

        var options = DumpOptions()
        options.content = .structureOnly
        let structure = try await SQLDump.dump(driver: driver, options: options)
        XCTAssertTrue(structure.contains("CREATE TABLE"))
        XCTAssertFalse(structure.contains("INSERT INTO"))

        options.content = .dataOnly
        let data = try await SQLDump.dump(driver: driver, options: options)
        XCTAssertFalse(data.contains("CREATE TABLE"))
        XCTAssertTrue(data.contains("INSERT INTO"))
        XCTAssertTrue(data.contains("'ana'"))

        await driver.disconnect()
    }

    func testDropBeforeCreateEExtendedInsert() async throws {
        let (driver, url) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: url) }
        try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        for id in 1...5 {
            try await driver.execute("INSERT INTO t (id) VALUES (\(id))")
        }

        var options = DumpOptions()
        options.dropBeforeCreate = true
        let dump = try await SQLDump.dump(driver: driver, options: options)
        XCTAssertTrue(dump.contains("DROP TABLE IF EXISTS \"t\";"))
        // Extended insert: as 5 linhas cabem num único statement.
        XCTAssertEqual(dump.components(separatedBy: "INSERT INTO").count - 1, 1)

        options.extendedInserts = false
        let single = try await SQLDump.dump(driver: driver, options: options)
        XCTAssertEqual(single.components(separatedBy: "INSERT INTO").count - 1, 5)

        await driver.disconnect()
    }

    func testInsertRespeitaTetoDeBytes() async throws {
        let (driver, url) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: url) }
        try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, texto TEXT)")
        let padding = String(repeating: "x", count: 200)
        for id in 1...20 {
            try await driver.execute("INSERT INTO t VALUES (\(id), '\(padding)')")
        }

        var options = DumpOptions()
        options.maxStatementBytes = 600
        let dump = try await SQLDump.dump(driver: driver, options: options)
        let inserts = dump.components(separatedBy: "INSERT INTO").count - 1
        XCTAssertGreaterThan(inserts, 1, "o teto deve quebrar em vários statements")
        XCTAssertLessThan(inserts, 20, "ainda deve agrupar mais de uma linha por statement")

        // E o resultado continua importável.
        let (importDriver, importURL) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: importURL) }
        let (_, errors) = try await SQLDump.importSQL(dump, driver: importDriver)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        let count = try await importDriver.countRows(table: "t")
        XCTAssertEqual(count, 20)

        await driver.disconnect()
        await importDriver.disconnect()
    }

    // MARK: - Streaming

    func testStreamQueryEntregaTodasAsLinhasEmLotes() async throws {
        let (driver, url) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: url) }
        try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        for id in 1...250 {
            try await driver.execute("INSERT INTO t (id) VALUES (\(id))")
        }

        final class Collector: @unchecked Sendable {
            var batches = 0
            var rows = 0
        }
        let collector = Collector()
        try await driver.streamQuery("SELECT * FROM t ORDER BY id", batchSize: 100) { batch in
            if !batch.rows.isEmpty { collector.batches += 1 }
            collector.rows += batch.rows.count
        }
        XCTAssertEqual(collector.rows, 250)
        XCTAssertEqual(collector.batches, 3)

        await driver.disconnect()
    }

    // MARK: - Import a partir de arquivo

    func testImportDeArquivoComMultibyte() async throws {
        let (driver, url) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: url) }
        try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, nome TEXT)")
        // Texto com acentos e emoji: o leitor lê em blocos e pode cortar um caractere ao meio.
        for id in 1...300 {
            try await driver.execute("INSERT INTO t VALUES (\(id), 'ação nº\(id) 🇧🇷 çãéü')")
        }
        let dump = try await SQLDump.dump(driver: driver)

        let dumpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-dump-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: dumpURL) }
        try dump.write(to: dumpURL, atomically: true, encoding: .utf8)

        let (importDriver, importURL) = try await makeDriver()
        defer { try? FileManager.default.removeItem(at: importURL) }
        let (statements, errors) = try await SQLDump.importSQL(fileURL: dumpURL, driver: importDriver)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertGreaterThan(statements, 1)

        let rows = try await importDriver.query("SELECT nome FROM t WHERE id = 300")
        XCTAssertEqual(rows.rows.first?.first, .text("ação nº300 🇧🇷 çãéü"))
        let total = try await importDriver.countRows(table: "t")
        XCTAssertEqual(total, 300)

        await driver.disconnect()
        await importDriver.disconnect()
    }
}
