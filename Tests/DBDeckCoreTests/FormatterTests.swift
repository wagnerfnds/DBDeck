import Foundation
import XCTest
@testable import DBDeckCore

final class FormatterTests: XCTestCase {
    private func f(_ sql: String) -> String { SQLFormatter.format(sql) }

    func testSelectSimplesComJoinWhereEOrdenacao() {
        let entrada = "select p.id, c.nome from pedidos p inner join clientes c on c.id = p.cliente_id where p.total > 10 and c.ativo = 1 order by p.criado_em desc limit 100"
        let esperado = """
        SELECT
            p.id,
            c.nome
        FROM pedidos p
            INNER JOIN clientes c ON c.id = p.cliente_id
        WHERE p.total > 10
            AND c.ativo = 1
        ORDER BY p.criado_em DESC
        LIMIT 100
        """
        XCTAssertEqual(f(entrada), esperado)
    }

    func testSelectEstrelaFicaNaMesmaLinha() {
        XCTAssertEqual(f("select * from leads where id = 1"), "SELECT *\nFROM leads\nWHERE id = 1")
    }

    func testFuncoesEWildcardSemEspacos() {
        XCTAssertEqual(f("select count(*), max(p.total) from pedidos p"), "SELECT\n    count(*),\n    max(p.total)\nFROM pedidos p")
    }

    func testIdentificadoresEStringsNaoMudam() {
        // Só palavras reservadas sobem de caixa; o resto sai como entrou.
        let saida = f("select Nome, \"Cidade\", `tipo` from Clientes where email like 'A%select%'")
        XCTAssertEqual(saida, "SELECT\n    Nome,\n    \"Cidade\",\n    `tipo`\nFROM Clientes\nWHERE email LIKE 'A%select%'")
    }

    func testSubconsultaAbreBloco() {
        let saida = f("select id from pedidos where cliente_id in (select id from clientes where ativo = 1)")
        let esperado = """
        SELECT id
        FROM pedidos
        WHERE cliente_id IN (
            SELECT id
            FROM clientes
            WHERE ativo = 1
        )
        """
        XCTAssertEqual(saida, esperado)
    }

    func testListaInlineNaoAbreBloco() {
        XCTAssertEqual(f("select id from t where status in ('pago', 'pendente') and x = -1"),
                       "SELECT id\nFROM t\nWHERE status IN ('pago', 'pendente')\n    AND x = -1")
    }

    func testCaseWhen() {
        let saida = f("select case when total > 100 then 'grande' else 'pequeno' end as faixa from pedidos")
        let esperado = """
        SELECT
            CASE
                WHEN total > 100 THEN 'grande'
                ELSE 'pequeno'
            END AS faixa
        FROM pedidos
        """
        XCTAssertEqual(saida, esperado)
    }

    func testUpdateSetUmPorLinha() {
        XCTAssertEqual(f("update pedidos set status = 'pago', pago_em = now() where id = 5"),
                       "UPDATE pedidos\nSET\n    status = 'pago',\n    pago_em = now()\nWHERE id = 5")
    }

    func testInsertValues() {
        XCTAssertEqual(f("insert into t (a, b) values (1, 'x')"), "INSERT INTO t (a, b)\nVALUES (1, 'x')")
    }

    func testVariosStatementsSeparadosPorLinhaEmBranco() {
        XCTAssertEqual(f("select 1; select 2;"), "SELECT 1;\n\nSELECT 2;")
    }

    func testComentariosPreservados() {
        let saida = f("-- cabeçalho\nselect id -- trailing\nfrom t")
        XCTAssertEqual(saida, "-- cabeçalho\nSELECT id -- trailing\nFROM t")
    }

    func testCorpoDollarQuotedIntocado() {
        let corpo = "$$ BEGIN   select   1; END $$"
        XCTAssertTrue(f("create function f() returns int as \(corpo) language plpgsql").contains(corpo))
    }

    func testCreateTableUmaColunaPorLinha() {
        let saida = f("create table t (id int primary key, nome varchar(80) not null)")
        let esperado = """
        CREATE TABLE t (
            id int PRIMARY KEY,
            nome varchar(80) NOT NULL
        )
        """
        XCTAssertEqual(saida, esperado)
    }

    func testIdempotente() {
        let entrada = "select a, b from t where x = 1 and y in (select z from u) order by a"
        let uma = f(entrada)
        XCTAssertEqual(f(uma), uma)
    }

    func testCastEOperadoresCompostos() {
        XCTAssertEqual(f("select a::text, b <> c, d || e from t"), "SELECT\n    a::text,\n    b <> c,\n    d || e\nFROM t")
    }
}
