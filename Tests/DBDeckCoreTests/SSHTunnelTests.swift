import Foundation
import XCTest
@testable import DBDeckCore

final class SSHTunnelTests: XCTestCase {
    private func base(_ method: SSHAuthMethod = .agent) -> SSHConfig {
        SSHConfig(enabled: true, host: "bastion.exemplo.com", port: 2222, username: "deploy", authMethod: method)
    }

    private func arguments(_ config: SSHConfig, usesAskpass: Bool = false) -> [String] {
        SSHTunnel.arguments(
            config: config,
            localPort: 54321,
            remoteHost: "db.interno",
            remotePort: 5432,
            usesAskpass: usesAskpass
        )
    }

    /// Índice do valor que segue uma flag (`-o`, `-i`, …).
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Encaminhamento

    func testEncaminhaAPortaLocalParaOHostRemoto() {
        let args = arguments(base())
        XCTAssertEqual(value(after: "-L", in: args), "127.0.0.1:54321:db.interno:5432")
        // Só encaminha: um shell remoto aberto seria um processo a mais e um risco a mais.
        XCTAssertTrue(args.contains("-N"))
        XCTAssertTrue(args.contains("-T"))
    }

    func testPortaEUsuarioDoServidorSSH() {
        let args = arguments(base())
        XCTAssertEqual(value(after: "-p", in: args), "2222")
        XCTAssertEqual(value(after: "-l", in: args), "deploy")
        XCTAssertEqual(args.last, "bastion.exemplo.com")
    }

    func testFalhaDeEncaminhamentoDerrubaOSSH() {
        // Sem isto, uma porta local ocupada deixaria um ssh vivo sem túnel nenhum e o
        // driver conectaria em qualquer coisa que estivesse escutando ali.
        XCTAssertTrue(arguments(base()).contains("ExitOnForwardFailure=yes"))
    }

    func testKeepaliveConfigurado() {
        // Túnel de banco fica horas aberto atrás de NAT.
        let args = arguments(base())
        XCTAssertTrue(args.contains("ServerAliveInterval=30"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
    }

    // MARK: - Autenticação

    func testAgenteNuncaAbrePrompt() {
        // Um prompt sem terminal seria um travamento silencioso até o timeout.
        let args = arguments(base(.agent))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("PreferredAuthentications=publickey,hostbased"))
    }

    func testChavePrivadaUsaSomenteAChaveEscolhida() {
        var config = base(.privateKey)
        config.privateKeyPath = "/Users/ana/.ssh/id_deploy"
        let args = arguments(config)
        XCTAssertEqual(value(after: "-i", in: args), "/Users/ana/.ssh/id_deploy")
        // Sem IdentitiesOnly o ssh oferece antes as chaves do agente e pode estourar
        // MaxAuthTries sem nunca chegar na chave escolhida.
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
    }

    func testChavePrivadaExpandeTil() {
        var config = base(.privateKey)
        config.privateKeyPath = "~/.ssh/id_ed25519"
        let esperado = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
        XCTAssertEqual(value(after: "-i", in: arguments(config)), esperado)
        XCTAssertFalse(esperado.hasPrefix("~"))
    }

    func testChaveComPassphraseNaoEntraEmBatchMode() {
        var config = base(.privateKey)
        config.privateKeyPath = "/tmp/k"
        // BatchMode desliga o askpass: com passphrase a autenticação nunca aconteceria.
        XCTAssertFalse(arguments(config, usesAskpass: true).contains("BatchMode=yes"))
        XCTAssertTrue(arguments(config, usesAskpass: false).contains("BatchMode=yes"))
    }

    func testSenhaDesligaChavePublicaEPedeUmaVezSo() {
        let args = arguments(base(.password))
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("PreferredAuthentications=password,keyboard-interactive"))
        // Senha errada falha na hora em vez de repetir o prompt três vezes.
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(args.contains("BatchMode=yes"))
    }

    func testSegredoNuncaVaiNaLinhaDeComando() {
        // A garantia central: `ps` mostra o argv de qualquer processo do usuário.
        var config = base(.password)
        config.privateKeyPath = "/tmp/k"
        let args = arguments(config, usesAskpass: true)
        XCTAssertFalse(args.contains { $0.lowercased().contains("password=") })
    }

    // MARK: - Validação

    func testDesligadoNaoValidaNada() {
        XCTAssertNil(SSHConfig().validationError)
    }

    func testExigeServidorUsuarioEChave() {
        var config = SSHConfig(enabled: true)
        XCTAssertNotNil(config.validationError)
        config.host = "bastion"
        XCTAssertNotNil(config.validationError)
        config.username = "deploy"
        XCTAssertNil(config.validationError)
        config.authMethod = .privateKey
        XCTAssertNotNil(config.validationError, "chave privada sem arquivo escolhido")
        config.privateKeyPath = "/tmp/k"
        XCTAssertNil(config.validationError)
    }

    func testPortaForaDaFaixaEInvalida() {
        var config = base()
        config.port = 0
        XCTAssertNotNil(config.validationError)
        config.port = 70000
        XCTAssertNotNil(config.validationError)
    }

    func testSomenteSenhaEChaveGuardamSegredo() {
        XCTAssertFalse(base(.agent).needsSecret)
        XCTAssertTrue(base(.password).needsSecret)
        XCTAssertTrue(base(.privateKey).needsSecret)
    }

    // MARK: - Config da conexão

    func testSQLiteNuncaUsaTunel() {
        // Arquivo local: não há porta para encaminhar.
        var config = ConnectionConfig(engine: .sqlite, sqlitePath: "/tmp/a.sqlite")
        config.ssh = base()
        XCTAssertFalse(config.usesSSHTunnel)
    }

    func testConexaoSemCampoSSHDecodificaComoDesligada() throws {
        // JSON gravado antes do recurso existir.
        let json = #"{"id":"\#(UUID().uuidString)","name":"antiga","engine":"postgres","host":"h","port":5432,"username":"u","password":"","database":"d","sqlitePath":"","useTLS":false}"#
        let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.usesSSHTunnel)
        XCTAssertEqual(config.sshConfig.port, 22)
    }

    func testSubtituloMostraOTunel() {
        var config = ConnectionConfig(engine: .postgres, host: "db.interno", port: 5432, database: "app")
        XCTAssertEqual(config.displaySubtitle, "db.interno:5432/app")
        config.ssh = base()
        XCTAssertTrue(config.displaySubtitle.contains("via ssh bastion.exemplo.com"))
    }

    // MARK: - Entrega do segredo

    /// Roda o helper SSH_ASKPASS como o `ssh` rodaria e devolve o que ele imprimiu.
    private func runAskpass(_ channel: AskpassChannel) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: channel.scriptURL.path)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testHelperEntregaOSegredoPeloFifo() throws {
        let channel = try AskpassChannel(secret: "s3nh4 com espaço")
        defer { channel.cleanUp() }
        channel.startServing()
        XCTAssertEqual(try runAskpass(channel), "s3nh4 com espaço\n")
    }

    func testHelperAtendeMaisDeUmPedido() throws {
        // O ssh pode pedir duas vezes (chave e depois senha): servir uma só travaria
        // o segundo pedido até o timeout.
        let channel = try AskpassChannel(secret: "abc")
        defer { channel.cleanUp() }
        channel.startServing()
        // O que o ssh consome é a primeira linha: cada pedido em série tem que
        // devolver o segredo, e não vazio nem o segredo de outro pedido.
        for tentativa in 1...5 {
            let entregue = try runAskpass(channel).split(separator: "\n").first.map(String.init)
            XCTAssertEqual(entregue, "abc", "pedido \(tentativa)")
        }
    }

    func testSegredoNaoEEscritoEmDisco() throws {
        // A razão de existir do FIFO: o script é um `cat`, não contém a senha.
        let channel = try AskpassChannel(secret: "supersecreta")
        defer { channel.cleanUp() }
        let script = try String(contentsOf: channel.scriptURL, encoding: .utf8)
        XCTAssertFalse(script.contains("supersecreta"))
    }

    func testArquivosDoCanalSaoPrivadosDoUsuario() throws {
        let channel = try AskpassChannel(secret: "abc")
        defer { channel.cleanUp() }
        let manager = FileManager.default
        let dirMode = try manager.attributesOfItem(atPath: channel.directory.path)[.posixPermissions] as? NSNumber
        let scriptMode = try manager.attributesOfItem(atPath: channel.scriptURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.int16Value, 0o700)
        XCTAssertEqual(scriptMode?.int16Value, 0o700)
    }

    func testLimpezaRemoveOCanal() throws {
        let channel = try AskpassChannel(secret: "abc")
        channel.startServing()
        let path = channel.directory.path
        channel.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Porta local

    // MARK: - Abertura de verdade

    func testServidorInalcancavelFalhaComMensagemDoSSH() async throws {
        // Sobe o `ssh` de verdade contra uma porta onde ninguém escuta: garante que a
        // falha volta como erro (com o texto do stderr) em vez de travar até o timeout.
        let config = SSHConfig(enabled: true, host: "127.0.0.1", port: 1, username: "ninguem", authMethod: .agent)
        do {
            let tunnel = try await SSHTunnel.open(
                config: config,
                remoteHost: "db.interno",
                remotePort: 5432,
                secret: nil,
                timeout: 15
            )
            tunnel.close()
            XCTFail("não deveria abrir túnel para uma porta sem servidor")
        } catch let error as SSHTunnelError {
            guard case .failed(let detail) = error else {
                return XCTFail("esperava .failed, veio \(error)")
            }
            // O texto vem do próprio ssh — é ele que diz o que houve.
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testConfigInvalidaFalhaAntesDeSubirProcesso() async {
        let config = SSHConfig(enabled: true, host: "", username: "", authMethod: .agent)
        do {
            _ = try await SSHTunnel.open(config: config, remoteHost: "h", remotePort: 5432, secret: nil)
            XCTFail("config sem servidor não deveria abrir")
        } catch let error as SSHTunnelError {
            guard case .failed(let detail) = error else { return XCTFail("esperava .failed") }
            XCTAssertTrue(detail.contains("servidor SSH"))
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
    }

    func testPortaLocalReservadaEUsavel() throws {
        let port = try SSHTunnel.reserveLocalPort()
        XCTAssertTrue((1024...65535).contains(port))
        // Reservar é soltar: ninguém está escutando ali até o ssh subir.
        XCTAssertFalse(SSHTunnel.canConnect(port: port))
    }
}
