import Foundation
import XCTest
@testable import DBDeckCore

/// Cobertura do SELECT de página — em especial da paginação por âncora (keyset), que é
/// onde um erro silencioso pularia ou repetiria linhas em vez de dar erro visível.
final class PageQueryTests: XCTestCase {
    private func column(_ name: String, _ type: String = "int", pk: Bool = false) -> DatabaseColumn {
        DatabaseColumn(name: name, type: type, isNullable: !pk, isPrimaryKey: pk,
                       defaultValue: nil, ordinal: 1)
    }

    private func builder(
        engine: SQLEngine = .mysql,
        primaryKeys: [String] = ["id"],
        sortColumn: String? = nil,
        sortAscending: Bool = true,
        filter: String? = nil,
        deferBlobs: Bool = false
    ) -> PageQueryBuilder {
        PageQueryBuilder(
            engine: engine,
            table: "pedidos",
            columns: [column("id", pk: true), column("nome", "varchar(80)"), column("corpo", "longtext")],
            primaryKeys: primaryKeys,
            sortColumn: sortColumn,
            sortAscending: sortAscending,
            filter: filter,
            pageSize: 1000,
            deferBlobs: deferBlobs
        )
    }

    // MARK: - Página absoluta

    func testPrimeiraPaginaComPKOrdenaPelaPK() {
        // A ordem estável é o que torna a âncora da próxima página válida.
        let page = builder().make(cursor: .absolute(0))
        XCTAssertEqual(page.sql, "SELECT * FROM `pedidos` ORDER BY `id` ASC LIMIT 1000")
        XCTAssertFalse(page.reversed)
    }

    func testSemPKUsaOffset() {
        let page = builder(primaryKeys: []).make(cursor: .absolute(3000))
        XCTAssertEqual(page.sql, "SELECT * FROM `pedidos` LIMIT 1000 OFFSET 3000")
    }

    func testPKCompostaNaoUsaKeyset() {
        let subject = builder(primaryKeys: ["loja_id", "id"])
        XCTAssertNil(subject.keysetColumn)
        XCTAssertEqual(
            subject.make(cursor: .absolute(2000)).sql,
            "SELECT * FROM `pedidos` LIMIT 1000 OFFSET 2000"
        )
    }

    func testOrdenacaoPorOutraColunaDesligaOKeyset() {
        let subject = builder(sortColumn: "nome")
        XCTAssertNil(subject.keysetColumn)
        XCTAssertEqual(
            subject.make(cursor: .absolute(1000)).sql,
            "SELECT * FROM `pedidos` ORDER BY `nome` ASC LIMIT 1000 OFFSET 1000"
        )
    }

    // MARK: - Keyset

    func testProximaPaginaAncoraNaPKSemOffset() {
        let page = builder().make(cursor: .after(.int(4321), offset: 1000))
        XCTAssertEqual(page.sql, "SELECT * FROM `pedidos` WHERE `id` > 4321 ORDER BY `id` ASC LIMIT 1000")
        XCTAssertFalse(page.sql.contains("OFFSET"), "o ponto do keyset é justamente não pagar OFFSET")
    }

    func testPaginaAnteriorLeAoContrarioEPedeInversao() {
        let page = builder().make(cursor: .before(.int(4321), offset: 1000))
        XCTAssertEqual(page.sql, "SELECT * FROM `pedidos` WHERE `id` < 4321 ORDER BY `id` DESC LIMIT 1000")
        XCTAssertTrue(page.reversed)
    }

    func testRecarregarMesmaPaginaUsaMaiorOuIgual() {
        let page = builder().make(cursor: .atOrAfter(.int(9), offset: 8000))
        XCTAssertEqual(page.sql, "SELECT * FROM `pedidos` WHERE `id` >= 9 ORDER BY `id` ASC LIMIT 1000")
    }

    func testOrdemDescendenteInverteOsComparadores() {
        let subject = builder(sortColumn: "id", sortAscending: false)
        XCTAssertEqual(
            subject.make(cursor: .after(.int(50), offset: 1000)).sql,
            "SELECT * FROM `pedidos` WHERE `id` < 50 ORDER BY `id` DESC LIMIT 1000"
        )
        let previous = subject.make(cursor: .before(.int(50), offset: 0))
        XCTAssertEqual(
            previous.sql,
            "SELECT * FROM `pedidos` WHERE `id` > 50 ORDER BY `id` ASC LIMIT 1000"
        )
        XCTAssertTrue(previous.reversed)
    }

    func testKeysetCombinaComOFiltro() {
        let page = builder(filter: "`nome` LIKE '%ana%'").make(cursor: .after(.int(7), offset: 1000))
        XCTAssertEqual(
            page.sql,
            "SELECT * FROM `pedidos` WHERE (`nome` LIKE '%ana%') AND `id` > 7 ORDER BY `id` ASC LIMIT 1000"
        )
    }

    func testAncoraDeTextoViraLiteralEscapado() {
        var subject = builder(primaryKeys: ["nome"])
        subject.columns = [column("nome", "varchar(80)", pk: true)]
        XCTAssertEqual(
            subject.make(cursor: .after(.text("O'Brien"), offset: 1000)).sql,
            "SELECT * FROM `pedidos` WHERE `nome` > 'O''Brien' ORDER BY `nome` ASC LIMIT 1000"
        )
    }

    /// Sem coluna âncora o cursor de keyset TEM de virar OFFSET: descartar a condição
    /// devolveria a primeira página em silêncio, com o rótulo dizendo outra coisa.
    func testCursorDeKeysetSemAncoraViraOffset() {
        let subject = builder(primaryKeys: [])
        XCTAssertEqual(subject.normalize(.after(.int(7), offset: 5000)), .absolute(5000))
        XCTAssertEqual(
            subject.make(cursor: .after(.int(7), offset: 5000)).sql,
            "SELECT * FROM `pedidos` LIMIT 1000 OFFSET 5000"
        )
    }

    // MARK: - Colunas adiadas

    func testDeferBlobsTrocaColunasGrandesPorNullComAlias() {
        let subject = builder(deferBlobs: true)
        XCTAssertEqual(subject.selectList(), "`id`, `nome`, NULL AS `corpo`")
        XCTAssertEqual(subject.deferredColumnIndexes, [2])
        // O alias mantém os nomes do resultado batendo com `columns` — é disso que
        // depende o resync depois de um ALTER TABLE em outra aba.
        XCTAssertTrue(subject.make(cursor: .absolute(0)).sql.hasPrefix("SELECT `id`, `nome`, NULL AS `corpo` FROM"))
        // A exportação pede tudo, ignorando o adiamento.
        XCTAssertEqual(subject.selectList(deferring: false), "*")
    }

    func testSemDeferBlobsPedeTudo() {
        XCTAssertEqual(builder().selectList(), "*")
        XCTAssertTrue(builder().deferredColumnIndexes.isEmpty)
    }

    // MARK: - Célula avulsa

    func testSingleCellQueryUsaAPK() {
        let sql = builder().singleCellQuery(
            column: column("corpo", "longtext"),
            primaryKeyValues: [("id", .int(42))],
            absoluteRowIndex: 5
        )
        XCTAssertEqual(sql, "SELECT `corpo` FROM `pedidos` WHERE `id` = 42 LIMIT 1")
    }

    func testSingleCellQuerySemPKUsaPosicaoNaMesmaOrdem() {
        let sql = builder(primaryKeys: [], sortColumn: "nome").singleCellQuery(
            column: column("corpo", "longtext"),
            primaryKeyValues: [],
            absoluteRowIndex: 1234
        )
        XCTAssertEqual(sql, "SELECT `corpo` FROM `pedidos` ORDER BY `nome` ASC LIMIT 1 OFFSET 1234")
    }

    /// Um prefixo não endereça linha nenhuma: melhor não consultar do que consultar errado.
    func testSingleCellQueryRecusaPKTruncadaOuNula() {
        let subject = builder()
        XCTAssertNil(subject.singleCellQuery(
            column: column("corpo", "longtext"),
            primaryKeyValues: [("id", .truncated(prefix: "ab", byteCount: 900, isBinary: false))],
            absoluteRowIndex: 0
        ))
        XCTAssertNil(subject.singleCellQuery(
            column: column("corpo", "longtext"),
            primaryKeyValues: [("id", .null)],
            absoluteRowIndex: 0
        ))
    }

    // MARK: - Sintaxe por engine

    func testIdentificadoresSeguemOEngine() {
        XCTAssertEqual(SQLEngine.mysql.quote("cli`ente"), "`cli``ente`")
        XCTAssertEqual(SQLEngine.postgres.quote("cli\"ente"), "\"cli\"\"ente\"")
        XCTAssertEqual(SQLEngine.sqlite.quote("cliente"), "\"cliente\"")
        XCTAssertEqual(
            builder(engine: .postgres).make(cursor: .after(.int(3), offset: 1000)).sql,
            "SELECT * FROM \"pedidos\" WHERE \"id\" > 3 ORDER BY \"id\" ASC LIMIT 1000"
        )
    }
}
