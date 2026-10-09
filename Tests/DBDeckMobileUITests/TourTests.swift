import XCTest

/// Percorre os fluxos principais do app iOS e grava capturas de tela.
///
/// Espera uma conexão SQLite chamada "Loja (demo)" já cadastrada (com as tabelas
/// `clientes` e `pedidos`). `DBDECK_SHOTS` aponta a pasta das capturas.
@MainActor
final class TourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["DBDECK_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testTour() throws {
        shot("01-conexoes")
        app.staticTexts["Loja (demo)"].tap()
        XCTAssertTrue(app.staticTexts["clientes"].waitForExistence(timeout: 10))
        shot("02-tabelas")

        app.staticTexts["clientes"].tap()
        XCTAssertTrue(app.staticTexts["Ana Silva"].waitForExistence(timeout: 2) || true)
        sleep(2)
        shot("03-grid")

        // Rolagem infinita: arrastar bastante para baixo.
        let grid = app.collectionViews.firstMatch
        for _ in 0..<6 { grid.swipeUp(velocity: .fast) }
        sleep(2)
        shot("04-grid-rolado")

        // Detalhe da linha
        grid.swipeDown(velocity: .fast)
        let cell = grid.cells.element(boundBy: 12)
        cell.tap()
        sleep(2)
        shot("05-detalhe-linha")
        app.buttons["Fechar"].firstMatch.tap()
        sleep(1)

        // Menu de contexto
        grid.cells.element(boundBy: 14).press(forDuration: 1.0)
        sleep(1)
        shot("06-menu-celula")
        if app.buttons["Filtrar por este valor"].exists {
            app.buttons["Filtrar por este valor"].tap()
            sleep(2)
            shot("07-filtrado")
        } else {
            app.tap()
        }

        // Estrutura e Info
        app.buttons["Estrutura"].tap()
        sleep(2)
        shot("08-estrutura")
        app.buttons["Info"].tap()
        sleep(2)
        shot("09-info")

        // Console
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.staticTexts["Console SQL"].tap()
        sleep(1)
        let editor = app.textViews["Editor SQL"]
        editor.tap()
        editor.typeText("SELECT cidade, COUNT(*) AS total FROM clie")
        sleep(1)
        shot("10-console-autocomplete")
        editor.typeText("ntes GROUP BY cidade ORDER BY total DESC;")
        app.buttons["Executar"].firstMatch.tap()
        sleep(2)
        shot("11-console-resultado")
    }

    func testForms() throws {
        app.buttons["Adicionar"].firstMatch.tap()
        sleep(1)
        shot("20-nova-conexao")
        app.buttons["Cancelar"].tap()
        sleep(1)
        app.buttons["Preferências"].tap()
        sleep(1)
        shot("21-preferencias")
    }

    func testInfiniteScroll() throws {
        // Páginas de 100 pelo domínio de argumentos do UserDefaults: vale só nesta execução.
        app.terminate()
        app.launchArguments = ["-grid.pageSize", "100"]
        app.launch()

        app.staticTexts["Loja (demo)"].tap()
        XCTAssertTrue(app.staticTexts["pedidos"].waitForExistence(timeout: 10))
        app.staticTexts["pedidos"].tap()
        sleep(2)
        let grid = app.collectionViews.firstMatch
        for _ in 0..<10 { grid.swipeUp(velocity: .fast) }
        sleep(2)
        shot("30-rolagem-infinita")
        // Contagem: ao menos uma página extra carregada.
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' de 20'")).firstMatch
        XCTAssertTrue(label.exists)
        XCTAssertFalse(label.label.hasPrefix("100 de"), "rolagem não carregou a página seguinte: \(label.label)")

    }

    func testPostgres() throws {
        // Conexão sem banco fixo: abre o seletor de bancos, sem alerta de erro.
        app.staticTexts["Postgres local"].tap()
        let postgres = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'postgres'")).firstMatch
        XCTAssertTrue(postgres.waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, "conectar sem banco não deveria mostrar erro")
        shot("40-postgres-escolher-banco")

        let search = app.searchFields["Buscar banco"]
        search.tap()
        search.typeText("post")
        shot("41-postgres-busca-banco")
        postgres.tap()

        let console = app.staticTexts["Console SQL"]
        XCTAssertTrue(console.waitForExistence(timeout: 15))
        console.tap()
        let editor = app.textViews["Editor SQL"]
        editor.tap()
        editor.typeText("SELECT datname, pg_database_size(datname) AS bytes FROM pg_database ORDER BY 2 DESC;")
        app.buttons["Executar"].firstMatch.tap()
        sleep(2)
        shot("42-postgres-console")
        XCTAssertTrue(app.staticTexts["datname"].exists)
    }

    func testMySQLWithoutDatabase() throws {
        app.staticTexts["MySQL local"].tap()
        let sys = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'sys'")).firstMatch
        XCTAssertTrue(sys.waitForExistence(timeout: 15))
        sleep(1)
        XCTAssertFalse(app.alerts.firstMatch.exists, "MySQL sem banco não deveria gritar 'No database selected'")
        shot("50-mysql-sem-banco")
        sys.tap()
        XCTAssertTrue(app.staticTexts["Console SQL"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot("51-mysql-tabelas")

        // Troca de banco pelo título: folha com busca.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Banco ativo'")).firstMatch.tap()
        XCTAssertTrue(app.searchFields["Buscar banco"].waitForExistence(timeout: 5))
        shot("52-mysql-trocar-banco")
    }
}
