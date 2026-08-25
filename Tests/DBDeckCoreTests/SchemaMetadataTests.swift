import Foundation
import XCTest
@testable import DBDeckCore

/// Metadados (FK, triggers, info) contra um SQLite real — o único engine que roda no teste.
final class SchemaMetadataTests: XCTestCase {
    private func makeDriver() async throws -> SQLiteDriver {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-meta-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        for sql in [
            "CREATE TABLE clientes (id INTEGER PRIMARY KEY, nome TEXT)",
            "CREATE TABLE pedidos (id INTEGER PRIMARY KEY, cliente_id INTEGER REFERENCES clientes(id) ON DELETE CASCADE ON UPDATE RESTRICT, total REAL)",
            "CREATE TABLE itens (pedido_id INTEGER, seq INTEGER, PRIMARY KEY (pedido_id, seq), FOREIGN KEY (pedido_id) REFERENCES pedidos(id))",
            "CREATE TRIGGER tg_total AFTER INSERT ON pedidos BEGIN UPDATE pedidos SET total = 0 WHERE id = NEW.id AND total IS NULL; END",
            "INSERT INTO clientes (nome) VALUES ('a'), ('b')",
        ] {
            _ = try await driver.execute(sql)
        }
        return driver
    }

    func testChavesEstrangeirasDeSaida() async throws {
        let driver = try await makeDriver()
        let keys = try await SchemaMetadata.foreignKeys(driver: driver, table: "pedidos")
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["cliente_id"])
        XCTAssertEqual(keys[0].referencedTable, "clientes")
        XCTAssertEqual(keys[0].referencedColumns, ["id"])
        XCTAssertEqual(keys[0].onDelete, "CASCADE")
        XCTAssertEqual(keys[0].onUpdate, "RESTRICT")
        XCTAssertTrue(keys[0].isSingleColumn)
        await driver.disconnect()
    }

    func testChavesQueReferenciamATabela() async throws {
        let driver = try await makeDriver()
        // clientes é referenciada por pedidos; pedidos por itens.
        let paraClientes = try await SchemaMetadata.referencingKeys(driver: driver, table: "clientes")
        XCTAssertEqual(paraClientes.map(\.table), ["pedidos"])
        let paraPedidos = try await SchemaMetadata.referencingKeys(driver: driver, table: "pedidos")
        XCTAssertEqual(paraPedidos.map(\.table), ["itens"])
        let paraItens = try await SchemaMetadata.referencingKeys(driver: driver, table: "itens")
        XCTAssertTrue(paraItens.isEmpty)
        await driver.disconnect()
    }

    func testTriggers() async throws {
        let driver = try await makeDriver()
        let triggers = try await SchemaMetadata.triggers(driver: driver, table: "pedidos")
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].name, "tg_total")
        XCTAssertEqual(triggers[0].timing, "AFTER")
        XCTAssertEqual(triggers[0].event, "INSERT")
        XCTAssertTrue(triggers[0].body.contains("UPDATE pedidos"))
        let semTrigger = try await SchemaMetadata.triggers(driver: driver, table: "clientes")
        XCTAssertTrue(semTrigger.isEmpty)
        await driver.disconnect()
    }

    func testInfoDaTabela() async throws {
        let driver = try await makeDriver()
        let info = try await SchemaMetadata.tableInfo(driver: driver, table: "clientes")
        XCTAssertTrue(info.ddl.uppercased().hasPrefix("CREATE TABLE"))
        XCTAssertEqual(info.facts.first { $0.label == "Linhas" }?.value, "2")
        await driver.disconnect()
    }

    func testLeituraDeTimingEEventoDaDefinicao() {
        // O verbo do evento vem antes do ` ON tabela`; o corpo pode ter outros verbos.
        let postgres = "CREATE TRIGGER t AFTER INSERT OR UPDATE ON pedidos FOR EACH ROW EXECUTE FUNCTION f()"
        XCTAssertEqual(SchemaMetadata.parseTriggerDefinition(postgres).timing, "AFTER")
        XCTAssertEqual(SchemaMetadata.parseTriggerDefinition(postgres).event, "INSERT OR UPDATE")
        let sqlite = "CREATE TRIGGER t BEFORE DELETE ON x BEGIN INSERT INTO log VALUES (1); END"
        XCTAssertEqual(SchemaMetadata.parseTriggerDefinition(sqlite).timing, "BEFORE")
        XCTAssertEqual(SchemaMetadata.parseTriggerDefinition(sqlite).event, "DELETE")
        let view = "CREATE TRIGGER t INSTEAD OF INSERT ON v BEGIN SELECT 1; END"
        XCTAssertEqual(SchemaMetadata.parseTriggerDefinition(view).timing, "INSTEAD OF")
    }
}
