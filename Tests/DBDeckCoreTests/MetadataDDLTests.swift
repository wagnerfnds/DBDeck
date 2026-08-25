import Foundation
import XCTest
@testable import DBDeckCore

final class MetadataDDLTests: XCTestCase {
    private let spec = SchemaDDL.ForeignKeySpec(columns: ["cliente_id"], referencedTable: "clientes", referencedColumns: ["id"], onUpdate: "CASCADE", onDelete: "SET NULL")

    func testAddForeignKeyMySQLEPostgres() throws {
        XCTAssertEqual(
            try SchemaDDL.addForeignKey(engine: .mysql, table: "pedidos", spec: spec),
            "ALTER TABLE `pedidos` ADD CONSTRAINT `fk_pedidos_cliente_id` FOREIGN KEY (`cliente_id`) REFERENCES `clientes` (`id`) ON UPDATE CASCADE ON DELETE SET NULL"
        )
        XCTAssertEqual(
            try SchemaDDL.addForeignKey(engine: .postgres, table: "pedidos", spec: spec),
            "ALTER TABLE \"pedidos\" ADD CONSTRAINT \"fk_pedidos_cliente_id\" FOREIGN KEY (\"cliente_id\") REFERENCES \"clientes\" (\"id\") ON UPDATE CASCADE ON DELETE SET NULL"
        )
    }

    func testNoActionNaoEEscrito() throws {
        var plain = spec
        plain.onUpdate = "NO ACTION"
        plain.onDelete = "NO ACTION"
        plain.name = "minha_fk"
        let sql = try SchemaDDL.addForeignKey(engine: .mysql, table: "pedidos", spec: plain)
        XCTAssertFalse(sql.contains("ON UPDATE"))
        XCTAssertTrue(sql.contains("CONSTRAINT `minha_fk`"))
    }

    func testSQLiteRecusaAlterarChave() {
        XCTAssertThrowsError(try SchemaDDL.addForeignKey(engine: .sqlite, table: "t", spec: spec))
        XCTAssertThrowsError(try SchemaDDL.dropForeignKey(engine: .sqlite, table: "t", name: "x"))
    }

    func testDropForeignKeyPorEngine() throws {
        XCTAssertEqual(try SchemaDDL.dropForeignKey(engine: .mysql, table: "t", name: "fk"), "ALTER TABLE `t` DROP FOREIGN KEY `fk`")
        XCTAssertEqual(try SchemaDDL.dropForeignKey(engine: .postgres, table: "t", name: "fk"), "ALTER TABLE \"t\" DROP CONSTRAINT \"fk\"")
    }

    func testCreateTriggerEnvolveStatementSoltoEmBloco() throws {
        let trigger = SchemaDDL.TriggerSpec(name: "tg", timing: "AFTER", events: ["INSERT"], body: "UPDATE t SET a = 1")
        let mysql = try SchemaDDL.createTrigger(engine: .mysql, table: "t", spec: trigger)
        XCTAssertEqual(mysql, "CREATE TRIGGER `tg` AFTER INSERT ON `t` FOR EACH ROW BEGIN\nUPDATE t SET a = 1;\nEND")
        // Bloco já escrito passa direto.
        let block = SchemaDDL.TriggerSpec(name: "tg", body: "BEGIN SELECT 1; END")
        XCTAssertTrue(try SchemaDDL.createTrigger(engine: .sqlite, table: "t", spec: block).hasSuffix("FOR EACH ROW BEGIN SELECT 1; END"))
    }

    func testCreateTriggerPostgres() throws {
        let trigger = SchemaDDL.TriggerSpec(name: "tg", timing: "BEFORE", events: ["INSERT", "UPDATE"], forEachRow: true, body: "audita()")
        XCTAssertEqual(
            try SchemaDDL.createTrigger(engine: .postgres, table: "t", spec: trigger),
            "CREATE TRIGGER \"tg\" BEFORE INSERT OR UPDATE ON \"t\" FOR EACH ROW EXECUTE FUNCTION audita()"
        )
        let explicit = SchemaDDL.TriggerSpec(name: "tg", events: ["DELETE"], forEachRow: false, body: "EXECUTE PROCEDURE f()")
        XCTAssertTrue(try SchemaDDL.createTrigger(engine: .postgres, table: "t", spec: explicit).hasSuffix("FOR EACH STATEMENT EXECUTE PROCEDURE f()"))
    }

    func testMySQLRecusaVariosEventosEInsteadOf() {
        XCTAssertThrowsError(try SchemaDDL.createTrigger(engine: .mysql, table: "t", spec: .init(name: "x", events: ["INSERT", "UPDATE"], body: "SELECT 1")))
        XCTAssertThrowsError(try SchemaDDL.createTrigger(engine: .mysql, table: "t", spec: .init(name: "x", timing: "INSTEAD OF", body: "SELECT 1")))
    }

    func testDropTrigger() {
        XCTAssertEqual(SchemaDDL.dropTrigger(engine: .mysql, table: "t", name: "tg"), "DROP TRIGGER IF EXISTS `tg`")
        XCTAssertEqual(SchemaDDL.dropTrigger(engine: .postgres, table: "t", name: "tg"), "DROP TRIGGER IF EXISTS \"tg\" ON \"t\"")
    }

    func testCriarEDerrubarTriggerNoSQLiteDeVerdade() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dbdeck-trg-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (a INTEGER, b INTEGER)")
        let spec = SchemaDDL.TriggerSpec(name: "tg_b", timing: "AFTER", events: ["INSERT"], body: "UPDATE t SET b = 1 WHERE rowid = NEW.rowid")
        _ = try await driver.execute(try SchemaDDL.createTrigger(engine: .sqlite, table: "t", spec: spec))
        _ = try await driver.execute("INSERT INTO t (a) VALUES (5)")
        let value = try await driver.query("SELECT b FROM t").rows.first?.first
        XCTAssertEqual(value, .int(1))
        var triggers = try await SchemaMetadata.triggers(driver: driver, table: "t")
        XCTAssertEqual(triggers.map(\.name), ["tg_b"])
        _ = try await driver.execute(SchemaDDL.dropTrigger(engine: .sqlite, table: "t", name: "tg_b"))
        triggers = try await SchemaMetadata.triggers(driver: driver, table: "t")
        XCTAssertTrue(triggers.isEmpty)
        await driver.disconnect()
    }
}
