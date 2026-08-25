import Foundation
import XCTest
@testable import DBDeckCore

final class CancelQueryTests: XCTestCase {
    func testInterrupcaoAbortaConsultaLongaNoSQLite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-cancel-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        // Sem interrupção isto leva dezenas de segundos: é o que o teste precisa para
        // distinguir "cancelou" de "terminou rápido de qualquer jeito".
        let heavy = """
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n LIMIT 40000000)
        SELECT count(*) FROM n
        """
        let start = Date()
        let reading = Task { try await driver.query(heavy) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await driver.cancelRunningQuery()

        do {
            _ = try await reading.value
            XCTFail("a consulta deveria ter sido interrompida")
        } catch {
            // O SQLite responde ao interrupt com erro — é o que o console traduz em
            // "cancelado" quando o token já foi acionado.
            XCTAssertTrue(error.localizedDescription.lowercased().contains("interrupt"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "o cancel não interrompeu a consulta")
    }

    func testCancelSemConsultaEmCursoEInofensivo() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-cancel-\(UUID().uuidString).sqlite")
        let driver = SQLiteDriver(config: ConnectionConfig(engine: .sqlite, sqlitePath: url.path))
        try await driver.connect()
        await driver.cancelRunningQuery()
        // A conexão continua utilizável depois de um cancel à toa.
        let result = try await driver.query("SELECT 1")
        XCTAssertEqual(result.rows.first?.first, .int(1))
        await driver.disconnect()
        // E depois de desconectar o cancel não toca num handle fechado.
        await driver.cancelRunningQuery()
    }
}
