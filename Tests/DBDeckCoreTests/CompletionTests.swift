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
        return SQLCompletion.suggestions(text: text, cursor: NSMaxRange(cursor), catalog: catalog).map(\.text)
    }

    private func itens(_ text: String, cursorAfter marcador: String) -> [SQLSuggestion] {
        let cursor = (text as NSString).range(of: marcador)
        return SQLCompletion.suggestions(text: text, cursor: NSMaxRange(cursor), catalog: catalog)
    }

    // MARK: - Tipo, categoria e ranking

    func testSugestaoTemCategoriaEDetalhe() {
        let tipado = SQLSchemaCatalog(
            tables: ["pedidos"],
            columns: ["pedidos": [SQLColumnInfo(name: "total", type: "NUMERIC(10,2)")]]
        )
        let sugeridas = SQLCompletion.suggestions(text: "SELECT t FROM pedidos p", cursor: 8, catalog: tipado)
        // Coluna traz o tipo (em minúsculas) como detalhe; tabela e keyword não têm detalhe.
        XCTAssertEqual(sugeridas.first, SQLSuggestion(text: "total", kind: .column, detail: "numeric(10,2)"))
        XCTAssertTrue(sugeridas.contains(SQLSuggestion(text: "TRUNCATE", kind: .keyword)))
    }

    func testApelidoESugeridoComATabelaComoDetalhe() {
        // "pe" e não "ped": sugerir exatamente o que já está digitado é descartado.
        let sugeridas = itens("SELECT pe FROM pedidos ped", cursorAfter: "SELECT pe")
        XCTAssertTrue(sugeridas.contains(SQLSuggestion(text: "ped", kind: .alias, detail: "pedidos")))
        // Vem depois das colunas da tabela e antes das tabelas do catálogo.
        let alias = sugeridas.firstIndex { $0.kind == .alias }!
        let tabela = sugeridas.firstIndex { $0.kind == .table }!
        XCTAssertLessThan(alias, tabela)
    }

    func testPrefixoVenceSubsequencia() {
        // "cli" é prefixo de cliente_id e subsequência de... nada aqui; mas "ci" casa
        // `cidade`? não está no catálogo. Usamos "ie": prefixo de nada, subsequência de
        // cliente_id/clientes — e "cl" prefixo de ambos. A ordem tem que pôr prefixo antes.
        let sugeridas = sugestoes("SELECT * FROM clientes WHERE cl", cursorAfter: "WHERE cl")
        XCTAssertEqual(sugeridas.first, "clientes")
        let porSubsequencia = sugestoes("SELECT * FROM clientes WHERE ie", cursorAfter: "WHERE ie")
        XCTAssertTrue(porSubsequencia.contains("clientes"))
        XCTAssertTrue(porSubsequencia.contains("cliente_id") == false, "cliente_id não é da tabela citada")
    }

    func testSubsequenciaSoComDoisCaracteres() {
        // Com um caractere só, subsequência casaria quase tudo: "e" está em pedidos,
        // clientes, SELECT… A lista viraria ruído.
        XCTAssertNil(SQLCompletion.match("pedidos", prefix: "e"))
        XCTAssertEqual(SQLCompletion.match("pedidos", prefix: "ed"), .subsequence)
        XCTAssertEqual(SQLCompletion.match("pedidos", prefix: "pe"), .exactPrefix)
        XCTAssertEqual(SQLCompletion.match("pedidos", prefix: "PE"), .prefix)
    }

    func testOffsetsCasadosParaNegrito() {
        XCTAssertEqual(SQLCompletion.matchedOffsets(in: "cliente_id", prefix: "cli"), [0, 1, 2])
        XCTAssertEqual(SQLCompletion.matchedOffsets(in: "cliente_id", prefix: "cid"), [0, 2, 9])
        XCTAssertEqual(SQLCompletion.matchedOffsets(in: "cliente_id", prefix: "xyz"), [])
    }

    // MARK: - Gatilho

    func testGatilhoAbreEmIdentificadorEDepoisDoPonto() {
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT c", cursor: 8), .identifier)
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT p.", cursor: 9), .afterDot)
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT p.no", cursor: 11), .afterDot)
    }

    func testGatilhoNaoAbreDepoisDeEspacoOuPontuacao() {
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT ", cursor: 7), .none)
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT a,", cursor: 9), .none)
        XCTAssertEqual(SQLCompletion.trigger(in: "", cursor: 0), .none)
    }

    func testGatilhoNaoAbreDentroDeStringOuComentario() {
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT 'ab", cursor: 10), .none)
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT 'it''s a", cursor: 15), .none, "'' continua a string")
        XCTAssertEqual(SQLCompletion.trigger(in: "SELECT 'x' , ab", cursor: 15), .identifier, "string fechada")
        XCTAssertEqual(SQLCompletion.trigger(in: "-- sel", cursor: 6), .none)
        XCTAssertEqual(SQLCompletion.trigger(in: "-- x\nsel", cursor: 8), .identifier, "comentário acabou na quebra")
        XCTAssertEqual(SQLCompletion.trigger(in: "/* sel", cursor: 6), .none)
        XCTAssertEqual(SQLCompletion.trigger(in: "/* a */ sel", cursor: 11), .identifier)
    }

    func testCatalogoLegadoPorNomesContinuaValido() {
        let legado = SQLSchemaCatalog(tables: ["t"], columns: ["t": ["a", "b"]])
        XCTAssertEqual(legado.columns(of: "T").map(\.name), ["a", "b"])
        XCTAssertNil(legado.columns(of: "t").first?.type)
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
        let sugeridas = SQLCompletion.suggestions(text: text, cursor: cursor, catalog: catalog).map(\.text)
        XCTAssertEqual(sugeridas, ["id", "nome", "email"])
    }
}
