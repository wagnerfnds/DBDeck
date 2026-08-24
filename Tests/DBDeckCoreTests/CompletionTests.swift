import Foundation
import XCTest
@testable import DBDeckCore

final class CompletionTests: XCTestCase {
    private let catalog = SQLSchemaCatalog(
        tables: ["pedidos", "pedido_itens", "clientes"],
        columns: [
            "pedidos": ["id", "cliente_id", "total", "criado_em"],
            "clientes": ["id", "nome", "email"],
        ]
    )

    private func sugestoes(_ text: String, cursorAfter marcador: String) -> [String] {
        let cursor = (text as NSString).range(of: marcador)
        XCTAssertNotEqual(cursor.location, NSNotFound, "marcador não encontrado")
        return SQLCompletion.suggestions(text: text, cursor: NSMaxRange(cursor), catalog: catalog)
    }

    // MARK: - Palavra sob o cursor

    func testPalavraParcialParaNoDelimitador() {
        let text = "SELECT cli"
        let range = SQLCompletion.partialWordRange(in: text, cursor: 10)
        XCTAssertEqual((text as NSString).substring(with: range), "cli")
    }

    func testCursorDepoisDeEspacoNaoTemPalavraParcial() {
        XCTAssertEqual(SQLCompletion.partialWordRange(in: "SELECT ", cursor: 7).length, 0)
    }

    func testPalavraParcialEmUTF16NaoDeslocaComAcento() {
        // O NSTextView substitui a faixa que devolvemos: errar a medida trocaria o
        // pedaço errado do texto em qualquer consulta com acento.
        let text = "SELECT 'ação', cli"
        let cursor = (text as NSString).length
        let range = SQLCompletion.partialWordRange(in: text, cursor: cursor)
        XCTAssertEqual((text as NSString).substring(with: range), "cli")
    }

    // MARK: - Tabelas citadas

    func testReconheceTabelaEApelido() {
        let refs = SQLCompletion.referencedTables(in: "SELECT * FROM pedidos p JOIN clientes AS c ON c.id = p.cliente_id")
        XCTAssertEqual(refs.map(\.table), ["pedidos", "clientes"])
        XCTAssertEqual(refs.map(\.alias), ["p", "c"])
    }

    func testPalavraReservadaNaoViraApelido() {
        // Sem isso `FROM pedidos WHERE` registraria "WHERE" como apelido.
        let refs = SQLCompletion.referencedTables(in: "SELECT * FROM pedidos WHERE id = 1")
        XCTAssertEqual(refs.first?.table, "pedidos")
        XCTAssertNil(refs.first?.alias)
    }

    func testIgnoraNomeDeTabelaDentroDeStringOuComentario() {
        let refs = SQLCompletion.referencedTables(in: "SELECT 'from tabela_falsa' -- from outra\nFROM pedidos")
        XCTAssertEqual(refs.map(\.table), ["pedidos"])
    }

    func testReconheceUpdateEInsertInto() {
        XCTAssertEqual(SQLCompletion.referencedTables(in: "UPDATE pedidos SET total = 1").map(\.table), ["pedidos"])
        XCTAssertEqual(SQLCompletion.referencedTables(in: "INSERT INTO clientes (nome) VALUES ('a')").map(\.table), ["clientes"])
    }

    // MARK: - Sugestões

    func testColunasDaTabelaCitadaVemAntesDoResto() {
        let sugeridas = sugestoes("SELECT cli FROM pedidos", cursorAfter: "cli")
        XCTAssertEqual(sugeridas.first, "cliente_id")
    }

    func testQualificadorPorApelidoTrazSoAsColunasDaquelaTabela() {
        let sugeridas = sugestoes("SELECT c.n FROM clientes c", cursorAfter: "c.n")
        XCTAssertEqual(sugeridas, ["nome"])
    }

    func testQualificadorPorNomeDeTabela() {
        let sugeridas = sugestoes("SELECT pedidos.to FROM pedidos", cursorAfter: "pedidos.to")
        XCTAssertEqual(sugeridas, ["total"])
    }

    func testDepoisDoPontoNaoSugerePalavraChave() {
        // "c." não pode oferecer CASE/COUNT: ali só cabe coluna.
        let sugeridas = sugestoes("SELECT c. FROM clientes c", cursorAfter: "c.")
        XCTAssertEqual(sugeridas, ["id", "nome", "email"])
    }

    func testTabelasAparecemDepoisDoFrom() {
        let sugeridas = sugestoes("SELECT * FROM ped", cursorAfter: "ped")
        XCTAssertEqual(Array(sugeridas.prefix(2)), ["pedidos", "pedido_itens"])
    }

    func testPalavrasChaveEntramQuandoNadaMaisCasa() {
        let sugeridas = sugestoes("SELECT * FROM pedidos WHE", cursorAfter: "WHE")
        XCTAssertEqual(sugeridas, ["WHERE", "WHEN"])
    }

    func testNaoSugereExatamenteOQueJaEstaEscrito() {
        let sugeridas = sugestoes("SELECT * FROM pedidos", cursorAfter: "pedidos")
        XCTAssertFalse(sugeridas.contains("pedidos"))
    }

    func testSugestoesNaoSeRepetem() {
        // "clientes" está no catálogo e o mesmo nome pode voltar por outro caminho.
        let sugeridas = sugestoes("SELECT * FROM cli", cursorAfter: "cli")
        XCTAssertEqual(sugeridas.count, Set(sugeridas.map { $0.lowercased() }).count)
    }

    func testEscopoDoStatementSobOCursor() {
        // Duas consultas na mesma aba: o `alias.` da segunda não pode oferecer colunas
        // da tabela citada só na primeira.
        let text = "SELECT * FROM pedidos p;\nSELECT c. FROM clientes c;"
        let cursor = NSMaxRange((text as NSString).range(of: "c."))
        let sugeridas = SQLCompletion.suggestions(text: text, cursor: cursor, catalog: catalog)
        XCTAssertEqual(sugeridas, ["id", "nome", "email"])
    }
}
