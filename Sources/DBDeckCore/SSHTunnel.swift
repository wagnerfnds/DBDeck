import Foundation

// MARK: - Configuração

/// Como autenticar no servidor SSH.
public enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Chaves do `ssh-agent` e do `~/.ssh/config`. Cobre chave com passphrase já
    /// destravada, ProxyJump e 2FA — e o app nunca vê segredo nenhum.
    case agent
    /// Arquivo de chave privada escolhido na conexão.
    case privateKey
    /// Senha (guardada no Keychain, como a do banco).
    case password

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agent: "Agente SSH / ~/.ssh/config"
        case .privateKey: "Chave privada"
        case .password: "Senha"
        }
    }
}

/// Túnel SSH de uma conexão. Opcional em `ConnectionConfig` para os JSONs antigos
/// continuarem decodificando.
public struct SSHConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    /// Caminho do arquivo de chave (`~` é expandido). Vazio usa as chaves padrão do ssh.
    public var privateKeyPath: String

    public init(
        enabled: Bool = false,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .agent,
        privateKeyPath: String = ""
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }

    /// `true` quando o método escolhido precisa de um segredo guardado pelo app.
    public var needsSecret: Bool {
        authMethod == .password || authMethod == .privateKey
    }

    /// Erro de preenchimento, ou nil quando dá para tentar conectar.
    public var validationError: String? {
        guard enabled else { return nil }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Informe o servidor SSH." }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Informe o usuário SSH." }
        if !(1...65535).contains(port) { return "Porta SSH inválida." }
        if authMethod == .privateKey, privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Escolha o arquivo da chave privada."
        }
        return nil
    }
}

public enum SSHTunnelError: LocalizedError {
    case sshUnavailable
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .sshUnavailable:
            return "O executável /usr/bin/ssh não foi encontrado."
        case .failed(let detail):
            return detail.isEmpty ? "Não foi possível abrir o túnel SSH." : "Túnel SSH: \(detail)"
        case .timedOut:
            return "O túnel SSH não respondeu a tempo."
        }
    }
}

// MARK: - Túnel

/// Encaminhamento de porta local por SSH, tocado pelo `ssh` do sistema.
///
/// Por que o binário do sistema e não uma biblioteca SSH em processo: o `ssh` já traz
/// agente, `~/.ssh/config`, `ProxyJump`, `known_hosts`, chave protegida por passphrase e
/// 2FA. Reimplementar isso dentro do app seria refazer — pior — justamente a parte onde
/// um cliente de banco não pode errar. É a mesma escolha do Sequel Ace.
///
/// O segredo (senha ou passphrase) chega ao `ssh` por um FIFO servido a um helper
/// `SSH_ASKPASS`, nunca por argumento nem variável de ambiente: `ps` mostra o argv e o
/// ambiente dos processos do próprio usuário.
public final class SSHTunnel: @unchecked Sendable {
    /// Porta em 127.0.0.1 que o driver deve usar no lugar da porta remota.
    public let localPort: Int

    private let process: Process
    private let askpass: AskpassChannel?
    private let errorLog: ErrorLog
    private var closed = false
    private let lock = NSLock()

    private init(localPort: Int, process: Process, askpass: AskpassChannel?, errorLog: ErrorLog) {
        self.localPort = localPort
        self.process = process
        self.askpass = askpass
        self.errorLog = errorLog
    }

    deinit { close() }

    /// Abre o túnel e só volta quando a porta local está aceitando conexão — quem chama
    /// pode conectar o driver em seguida sem corrida.
    public static func open(
        config: SSHConfig,
        remoteHost: String,
        remotePort: Int,
        secret: String?,
        timeout: TimeInterval = 20
    ) async throws -> SSHTunnel {
        guard FileManager.default.isExecutableFile(atPath: sshExecutable) else {
            throw SSHTunnelError.sshUnavailable
        }
        if let problem = config.validationError {
            throw SSHTunnelError.failed(problem)
        }

        let localPort = try reserveLocalPort()
        let usableSecret = (secret?.isEmpty == false && config.needsSecret) ? secret : nil
        let askpass = try usableSecret.map { try AskpassChannel(secret: $0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutable)
        process.arguments = arguments(
            config: config,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            usesAskpass: askpass != nil
        )
        var environment = ProcessInfo.processInfo.environment
        if let askpass {
            environment["SSH_ASKPASS"] = askpass.scriptURL.path
            // Sem REQUIRE=force o ssh só usa o askpass quando não há terminal — e o
            // "não há terminal" do app é o suficiente na maioria dos casos, mas não em
            // todos. DISPLAY é exigido pelo OpenSSH anterior ao 8.4.
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        }
        process.environment = environment

        let errorLog = ErrorLog()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        // Sem isto o ssh pode tentar ler uma senha da entrada padrão herdada.
        process.standardInput = FileHandle.nullDevice
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorLog.append(data) }
        }

        askpass?.startServing()
        do {
            try process.run()
        } catch {
            askpass?.shutDown()
            throw SSHTunnelError.failed(error.localizedDescription)
        }

        let tunnel = SSHTunnel(localPort: localPort, process: process, askpass: askpass, errorLog: errorLog)
        do {
            try await tunnel.waitUntilReady(timeout: timeout)
        } catch {
            tunnel.close()
            throw error
        }
        // Autenticado: o segredo não é mais necessário e o servidor do FIFO some com ele.
        askpass?.shutDown()
        return tunnel
    }

    /// Derruba o túnel. Idempotente — o `deinit` chama de novo.
    public func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }

        askpass?.shutDown()
        if let pipe = process.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if process.isRunning { process.terminate() }
        askpass?.cleanUp()
    }

    /// `true` enquanto o `ssh` está de pé. Um túnel caído derruba a conexão do banco
    /// junto, então vale a UI conseguir perguntar.
    public var isRunning: Bool { process.isRunning }

    // MARK: - Argumentos

    static let sshExecutable = "/usr/bin/ssh"

    /// Linha de comando do encaminhamento. Separada do lançamento porque é a parte que
    /// dá para cobrir por teste — subir um servidor SSH num teste unitário, não.
    static func arguments(
        config: SSHConfig,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        usesAskpass: Bool
    ) -> [String] {
        var arguments = [
            "-N",                                        // só encaminha, não abre shell
            "-T",                                        // sem pty
            "-o", "ExitOnForwardFailure=yes",            // porta ocupada é erro, não túnel mudo
            "-o", "StrictHostKeyChecking=accept-new",    // confia no primeiro encontro, avisa se mudar
            "-o", "ConnectTimeout=10",
            // Túnel de banco fica horas aberto atrás de NAT: sem keepalive ele morre calado.
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-p", String(config.port),
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
        ]

        switch config.authMethod {
        case .agent:
            arguments += ["-o", "PreferredAuthentications=publickey,hostbased"]
            // Nada a digitar: qualquer prompt aqui seria um travamento silencioso.
            arguments += ["-o", "BatchMode=yes"]
        case .privateKey:
            let path = (config.privateKeyPath as NSString).expandingTildeInPath
            if !path.isEmpty {
                // IdentitiesOnly impede o ssh de oferecer antes as chaves do agente e
                // estourar MaxAuthTries sem nunca chegar na chave escolhida.
                arguments += ["-i", path, "-o", "IdentitiesOnly=yes"]
            }
            arguments += ["-o", "PreferredAuthentications=publickey"]
            if !usesAskpass { arguments += ["-o", "BatchMode=yes"] }
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                // Senha errada é para falhar na hora, não repetir o prompt três vezes.
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }

        let user = config.username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { arguments += ["-l", user] }
        arguments.append(config.host.trimmingCharacters(in: .whitespaces))
        return arguments
    }

    // MARK: - Prontidão

    private func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // O ssh só abre a escuta local DEPOIS de autenticar: conseguir conectar é a
            // prova de que o túnel está de pé, e não depende de casar texto do stderr.
            if Self.canConnect(port: localPort) { return }
            guard process.isRunning else {
                throw SSHTunnelError.failed(errorLog.summary())
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { throw CancellationError() }
        }
        throw process.isRunning ? SSHTunnelError.timedOut : SSHTunnelError.failed(errorLog.summary())
    }

    static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Porta livre em 127.0.0.1, obtida deixando o kernel escolher. Entre soltar a porta
    /// e o ssh escutá-la há uma fresta em que outro processo pode tomá-la — é o que o
    /// `ExitOnForwardFailure` transforma em erro visível em vez de túnel mudo.
    static func reserveLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SSHTunnelError.failed("Sem socket local disponível.") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SSHTunnelError.failed("Sem porta local disponível.") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw SSHTunnelError.failed("Sem porta local disponível.") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

// MARK: - stderr do ssh

/// Acumula o stderr do `ssh` para virar mensagem de erro ("Permission denied (publickey)"
/// diz muito mais do que "falhou").
private final class ErrorLog: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Um servidor tagarela (banner, debug) não pode virar megabytes na memória.
        guard data.count < 8 * 1024 else { return }
        data.append(chunk)
    }

    /// As últimas linhas relevantes, sem o ruído de aviso conhecido.
    func summary() -> String {
        lock.lock()
        let text = String(decoding: data, as: UTF8.self)
        lock.unlock()
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.suffix(3).joined(separator: " · ")
    }
}

// MARK: - Askpass

/// Serve o segredo ao helper `SSH_ASKPASS` por um FIFO.
///
/// O script é um `cat` no FIFO: o segredo não é escrito em disco, não aparece no argv e
/// não vai no ambiente. O FIFO é servido em laço porque o `ssh` pode pedir mais de uma
/// vez (chave e depois senha), e para de servir assim que o túnel autentica.
final class AskpassChannel: @unchecked Sendable {
    let scriptURL: URL
    let directory: URL
    private let fifoURL: URL
    private let secret: String
    private let queue = DispatchQueue(label: "br.dev.dbdeck.ssh-askpass")
    private var serving = false
    private let lock = NSLock()

    init(secret: String) throws {
        self.secret = secret
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdeck-ssh-\(UUID().uuidString)", isDirectory: true)
        scriptURL = directory.appendingPathComponent("askpass")
        fifoURL = directory.appendingPathComponent("secret.fifo")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            throw SSHTunnelError.failed("Não foi possível preparar o canal da senha.")
        }
        // Aspas simples no caminho: o UUID não tem aspas, mas o TMPDIR do usuário pode
        // ter espaço.
        let script = "#!/bin/sh\nexec cat '\(fifoURL.path)'\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    func startServing() {
        lock.lock()
        serving = true
        lock.unlock()
        queue.async { [self] in
            while isServing {
                // Abertura BLOQUEANTE: volta quando (e só quando) alguém abre o FIFO para
                // ler — é o que sincroniza um segredo por pedido do askpass.
                let descriptor = open(fifoURL.path, O_WRONLY)
                guard descriptor >= 0 else { break }
                // O leitor pode desistir no meio: sem isto o write vira SIGPIPE e derruba
                // o app inteiro, não só esta thread.
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                guard isServing else {
                    Darwin.close(descriptor)
                    break
                }
                let bytes = Array((secret + "\n").utf8)
                _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
                Darwin.close(descriptor)
                // Dá ao leitor o tempo de drenar e fechar antes de reabrir. Sem a pausa,
                // o `open` da volta seguinte reencontra o MESMO leitor ainda aberto e
                // escreve o segredo de novo; o `ssh` lê só a primeira linha e ignora o
                // resto, então o pior caso é ruído — mas ruído desnecessário.
                // (Detectar a saída do leitor por `poll` não serve: na ponta de escrita
                // de um FIFO o macOS não reporta POLLHUP.)
                usleep(50_000)
            }
        }
    }

    private var isServing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serving
    }

    func shutDown() {
        lock.lock()
        let wasServing = serving
        serving = false
        lock.unlock()
        guard wasServing else { return }
        // Destrava o open(O_WRONLY) que está esperando um leitor: abrir para leitura
        // basta, e a thread sai do laço vendo `serving` falso.
        let descriptor = open(fifoURL.path, O_RDONLY | O_NONBLOCK)
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func cleanUp() {
        shutDown()
        try? FileManager.default.removeItem(at: directory)
    }
}
