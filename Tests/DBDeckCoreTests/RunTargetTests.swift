import Foundation
import XCTest
@testable import DBDeckCore

/// Regras do ⌘⏎ (executar) e do ⌘⇧⏎ (comando sob o cursor) do console.
final class RunTargetTests: XCTestCase {
    private let script = """
    SELECT 1;
    UPDATE t SET a = 2;
    DELETE FROM t;
    """

    // MARK: - Executar

    func testSemSelecaoExecutaOScriptInteiro() {
        let statements = SQLRunTarget.statements(in: script, selection: nil)
        XCTAssertEqual(statements.map(\.sql), ["SELECT 1", "UPDATE t SET a = 2", "DELETE FROM t"])
    }

    func testSelecaoVaziaContaComoSemSelecao() {
        // Um cursor é uma seleção de comprimento zero: não pode virar "executar nada".
        let cursor = NSRange(location: 4, length: 0)
        XCTAssertEqual(SQLRunTarget.statements(in: script, selection: cursor).count, 3)
    }

    func testExecutaSomenteOTrechoSelecionado() {
        let text = script as NSString
        let selection = text.range(of: "UPDATE t SET a = 2;")
        let statements = SQLRunTarget.statements(in: script, selection: selection)
        XCTAssertEqual(statements.map(\.sql), ["UPDATE t SET a = 2"])
    }

    func testFaixaDoTrechoSelecionadoApontaParaOTextoInteiro() {
        // A faixa volta relativa ao editor, não ao recorte: é ela que seleciona o
        // comando que falhou, e relativa ao recorte apontaria para o topo do editor.
        let text = script as NSString
        let selection = text.range(of: "UPDATE t SET a = 2;\nDELETE FROM t;")
        let statements = SQLRunTarget.statements(in: script, selection: selection)
        XCTAssertEqual(statements.count, 2)
        for statement in statements {
            let recorte = text.substring(with: NSRange(location: statement.location, length: statement.length))
            XCTAssertEqual(recorte, statement.sql)
        }
    }

    func testSelecaoParcialSemPontoEVirgulaAindaExecuta() {
        // Selecionar só um pedaço no meio da linha é o uso mais comum do "executar seleção".
        let text = "SELECT a, b FROM tabela WHERE a > 1" as NSString
        let selection = text.range(of: "SELECT a, b FROM tabela")
        let statements = SQLRunTarget.statements(in: text as String, selection: selection)
        XCTAssertEqual(statements.map(\.sql), ["SELECT a, b FROM tabela"])
    }

    func testSelecaoForaDoTextoCaiParaOScriptInteiro() {
        // O texto pode ter mudado por baixo (biblioteca/histórico) entre a seleção e o
        // atalho: recortar uma faixa inválida seria pior que executar tudo.
        let selection = NSRange(location: 500, length: 20)
        XCTAssertEqual(SQLRunTarget.statements(in: script, selection: selection).count, 3)
    }

    func testSelecaoDeApenasBrancosNaoGeraComando() {
        let text = script as NSString
        let selection = text.range(of: ";\n")
        XCTAssertTrue(SQLRunTarget.statements(in: script, selection: selection).isEmpty)
    }

    // MARK: - Comando sob o cursor

    func testCursorDentroDoComandoEscolheEle() {
        let cursor = (script as NSString).range(of: "SET a").location
        XCTAssertEqual(SQLRunTarget.statement(in: script, at: cursor)?.sql, "UPDATE t SET a = 2")
    }

    func testCursorLogoDepoisDoPontoEVirgulaEscolheOComandoAnterior() {
        // Onde o cursor fica ao acabar de digitar o comando.
        let cursor = (script as NSString).range(of: "SELECT 1;").length
        XCTAssertEqual(SQLRunTarget.statement(in: script, at: cursor)?.sql, "SELECT 1")
    }

    func testCursorNaLinhaEmBrancoDepoisDoScriptEscolheOUltimo() {
        let texto = script + "\n\n"
        XCTAssertEqual(SQLRunTarget.statement(in: texto, at: (texto as NSString).length)?.sql, "DELETE FROM t")
    }

    func testCursorAntesDoPrimeiroComandoEscolheOPrimeiro() {
        let texto = "\n\n" + script
        XCTAssertEqual(SQLRunTarget.statement(in: texto, at: 0)?.sql, "SELECT 1")
    }

    func testTextoVazioNaoGeraComando() {
        XCTAssertNil(SQLRunTarget.statement(in: "   \n  ", at: 2))
        XCTAssertTrue(SQLRunTarget.statements(in: "   \n  ", selection: nil).isEmpty)
    }

    func testComandoSobOCursorRespeitaCorpoDollarQuoted() {
        // O cursor dentro do corpo tem que pegar a function inteira, não um fragmento.
        let texto = "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$;\nSELECT 9;"
        let cursor = (texto as NSString).range(of: "PERFORM 2").location
        XCTAssertEqual(SQLRunTarget.statement(in: texto, at: cursor)?.sql, "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$")
    }
}
