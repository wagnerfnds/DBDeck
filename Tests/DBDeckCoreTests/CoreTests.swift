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
}
