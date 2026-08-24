import Foundation
import Observation
import SwiftUI
import DBDeckCore

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    var workspaces: [Workspace] = WorkspaceStore.load()
    /// Consultas salvas pelo usuário (globais, persistidas em disco).
    var savedQueries: [SavedQuery] = SavedQueryStore.load()
    var selectedConnectionID: UUID?
    var active: [UUID: any DatabaseDriver] = [:]
    var connectionStatus: [UUID: ConnectionStatus] = [:]
    var sessions: [UUID: ConnectionSession] = [:]
    /// Conexões em andamento: chamadas concorrentes ao mesmo id compartilham a tentativa
    /// (ex.: ⌘P e a sidebar disparando juntos) — senão cada uma abriria um driver e o
    /// perdedor ficaria conectado para sempre.
    private var connecting: [UUID: Task<(any DatabaseDriver)?, Never>] = [:]
    /// Túneis SSH abertos, por conexão, com contagem de usuários: o dump abre um driver
    /// avulso para o mesmo servidor e não pode derrubar o túnel da conexão ao terminar.
    private var tunnels: [UUID: (tunnel: SSHTunnel, users: Int)] = [:]
    /// Aberturas em curso — como em `connecting`, chamadas concorrentes compartilham a
    /// tentativa em vez de subir dois processos `ssh` para o mesmo servidor.
    private var openingTunnels: [UUID: Task<SSHTunnel, any Error>] = [:]

    init() {
        migrateLegacyPasswords()
    }

    /// Sessão de abas de uma conexão (criada sob demanda, persiste entre trocas de conexão).
    func session(for connectionID: UUID) -> ConnectionSession {
        if let existing = sessions[connectionID] { return existing }
        let created = ConnectionSession(connectionID: connectionID)
        // Semeia com os bancos memorizados para funcionar no ⌘P mesmo desconectado.
        created.databases = config(for: connectionID)?.databasesCache ?? []
        created.databasesLoaded = !created.databases.isEmpty
        sessions[connectionID] = created
        return created
    }

    /// Guarda os bancos do servidor na sessão e memoriza no disco para buscas futuras.
    func setDatabases(_ list: [String], for connectionID: UUID) {
        let session = session(for: connectionID)
        session.databases = list
        session.databasesLoaded = true
        for workspaceIndex in workspaces.indices {
            if let connectionIndex = workspaces[workspaceIndex].connections.firstIndex(where: { $0.id == connectionID }) {
                workspaces[workspaceIndex].connections[connectionIndex].cachedDatabases = list
                persist()
                return
            }
        }
    }

    /// Senhas antigas salvas em texto plano no JSON: migra para o Keychain e limpa o arquivo.
    private func migrateLegacyPasswords() {
        var changed = false
        for workspaceIndex in workspaces.indices {
            for connectionIndex in workspaces[workspaceIndex].connections.indices {
                let connection = workspaces[workspaceIndex].connections[connectionIndex]
                if !connection.password.isEmpty {
                    KeychainManager.setPassword(connection.password, for: connection.id)
                    workspaces[workspaceIndex].connections[connectionIndex].password = ""
                    changed = true
                }
            }
        }
        if changed {
            persist()
        }
    }

    // MARK: - Workspaces

    func addWorkspace(named name: String) {
        workspaces.append(Workspace(name: name))
        persist()
    }

    func deleteWorkspace(_ workspace: Workspace) {
        for connection in workspace.connections {
            disconnect(connection.id)
        }
        workspaces.removeAll { $0.id == workspace.id }
        persist()
    }

    func workspace(for connectionID: UUID) -> Workspace? {
        workspaces.first { $0.connections.contains { $0.id == connectionID } }
    }

    // MARK: - Conexões

    func addConnection(_ config: ConnectionConfig, sshSecret: String? = nil, to workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        KeychainManager.setPassword(config.password, for: config.id)
        if let sshSecret { KeychainManager.setPassword(sshSecret, for: config.id, kind: .ssh) }
        var stored = config
        stored.password = ""
        workspaces[index].connections.append(stored)
        persist()
    }

    /// `sshSecret` nil significa "não mexer no que está guardado" — editar o nome da
    /// conexão não pode apagar a senha do túnel.
    func updateConnection(_ config: ConnectionConfig, sshSecret: String? = nil) {
        guard
            let workspaceIndex = workspaces.firstIndex(where: { $0.connections.contains { $0.id == config.id } }),
            let connectionIndex = workspaces[workspaceIndex].connections.firstIndex(where: { $0.id == config.id })
        else { return }
        if let driver = active[config.id] {
            Task { await driver.disconnect() }
            active[config.id] = nil
            connectionStatus[config.id] = .disconnected
            // O túnel foi aberto para o host/porta antigos: mantê-lo apontaria a conexão
            // reconectada para o servidor errado.
            releaseTunnel(config.id)
        }
        KeychainManager.setPassword(config.password, for: config.id)
        if let sshSecret { KeychainManager.setPassword(sshSecret, for: config.id, kind: .ssh) }
        var stored = config
        stored.password = ""
        workspaces[workspaceIndex].connections[connectionIndex] = stored
        persist()
    }

    func deleteConnection(_ config: ConnectionConfig) {
        disconnect(config.id)
        KeychainManager.deletePassword(for: config.id)
        KeychainManager.deletePassword(for: config.id, kind: .ssh)
        sessions[config.id] = nil
        for index in workspaces.indices {
            workspaces[index].connections.removeAll { $0.id == config.id }
        }
        if selectedConnectionID == config.id {
            selectedConnectionID = nil
        }
        persist()
    }

    // MARK: - Conexão ativa

    func config(for connectionID: UUID) -> ConnectionConfig? {
        for workspace in workspaces {
            if let config = workspace.connections.first(where: { $0.id == connectionID }) {
                return config
            }
        }
        return nil
    }

    /// Config com a senha hidratada do Keychain (o JSON guarda apenas o campo vazio).
    func liveConfig(for connectionID: UUID) -> ConnectionConfig? {
        guard var config = config(for: connectionID) else { return nil }
        config.password = KeychainManager.password(for: config.id) ?? ""
        return config
    }

    func driver(for config: ConnectionConfig) async -> (any DatabaseDriver)? {
        if let existing = active[config.id] {
            return existing
        }
        if let inFlight = connecting[config.id] {
            return await inFlight.value
        }
        let attempt = Task { await openDriver(config) }
        connecting[config.id] = attempt
        let result = await attempt.value
        connecting[config.id] = nil
        return result
    }

    private func makeDriver(_ config: ConnectionConfig) -> any DatabaseDriver {
        switch config.engine {
        case .postgres: return PostgresDriver(config: config)
        case .mysql: return MySQLDriver(config: config)
        case .sqlite: return SQLiteDriver(config: config)
        }
    }

    /// Driver temporário conectado a um banco específico, sem mexer na conexão ativa
    /// (usado por dumps via menu de contexto). Quem chama é responsável pelo `disconnect()`.
    func ephemeralDriver(for connectionID: UUID, database: String?) async throws -> any DatabaseDriver {
        guard var config = liveConfig(for: connectionID) else { throw DriverError.notConnected }
        if let database, !database.isEmpty { config.database = database }
        // Reaproveita o túnel da conexão quando já existe; quem chama devolve com
        // `releaseEphemeralTunnel(for:)`.
        let usesTunnel = config.usesSSHTunnel
        let routed = try await routeThroughTunnel(config)
        // Sem banco escolhido o PostgresDriver decide sozinho (postgres → nome do usuário).
        let driver = makeDriver(routed)
        do {
            try await driver.connect()
        } catch {
            // Sem isso o PostgresDriver deixa um client re-tentando para sempre em background.
            await driver.disconnect()
            if usesTunnel { releaseTunnel(connectionID) }
            throw error
        }
        return driver
    }

    private func openDriver(_ config: ConnectionConfig) async -> (any DatabaseDriver)? {
        connectionStatus[config.id] = .connecting
        let routed: ConnectionConfig
        do {
            routed = try await routeThroughTunnel(config)
        } catch {
            connectionStatus[config.id] = .failed(error.localizedDescription)
            return nil
        }
        // Postgres exige um banco para conectar; sem banco fixo, o driver tenta `postgres`
        // e depois o banco homônimo do usuário (servidor remoto costuma liberar só esse).
        let driver = makeDriver(routed)
        do {
            try await driver.connect()
            active[config.id] = driver
            connectionStatus[config.id] = .connected
            return driver
        } catch {
            connectionStatus[config.id] = .failed(error.localizedDescription)
            await driver.disconnect()
            if config.usesSSHTunnel { releaseTunnel(config.id) }
            return nil
        }
    }

    // MARK: - Túnel SSH

    /// Devolve a config apontando para a ponta local do túnel. Sem SSH, devolve como está.
    private func routeThroughTunnel(_ config: ConnectionConfig) async throws -> ConnectionConfig {
        guard config.usesSSHTunnel else { return config }
        let tunnel = try await acquireTunnel(config)
        var routed = config
        routed.host = "127.0.0.1"
        routed.port = tunnel.localPort
        return routed
    }

    private func acquireTunnel(_ config: ConnectionConfig) async throws -> SSHTunnel {
        if let existing = tunnels[config.id], existing.tunnel.isRunning {
            tunnels[config.id] = (existing.tunnel, existing.users + 1)
            return existing.tunnel
        }
        if let inFlight = openingTunnels[config.id] {
            let tunnel = try await inFlight.value
            if let entry = tunnels[config.id], entry.tunnel === tunnel {
                tunnels[config.id] = (tunnel, entry.users + 1)
            }
            return tunnel
        }
        // Túnel morto (rede caiu, servidor derrubou): não adianta reaproveitar.
        tunnels[config.id]?.tunnel.close()
        tunnels[config.id] = nil

        let sshConfig = config.sshConfig
        let remoteHost = config.host
        let remotePort = config.port
        let secret = sshConfig.needsSecret
            ? KeychainManager.password(for: config.id, kind: .ssh)
            : nil
        let attempt = Task {
            try await SSHTunnel.open(
                config: sshConfig,
                remoteHost: remoteHost,
                remotePort: remotePort,
                secret: secret
            )
        }
        openingTunnels[config.id] = attempt
        defer { openingTunnels[config.id] = nil }
        let tunnel = try await attempt.value
        tunnels[config.id] = (tunnel, 1)
        return tunnel
    }

    /// Solta um usuário do túnel; o último a sair fecha o processo `ssh`.
    private func releaseTunnel(_ connectionID: UUID) {
        guard let entry = tunnels[connectionID] else { return }
        if entry.users <= 1 {
            entry.tunnel.close()
            tunnels[connectionID] = nil
        } else {
            tunnels[connectionID] = (entry.tunnel, entry.users - 1)
        }
    }

    /// Par do `ephemeralDriver`: quem pediu o driver avulso devolve o túnel ao terminar.
    func releaseEphemeralTunnel(for connectionID: UUID) {
        guard config(for: connectionID)?.usesSSHTunnel == true else { return }
        releaseTunnel(connectionID)
    }

    func connect(_ connectionID: UUID) async -> Bool {
        guard let config = liveConfig(for: connectionID) else { return false }
        return await driver(for: config) != nil
    }

    /// Reabre a conexão apontando para outro banco do mesmo servidor (não persiste no config salvo).
    @discardableResult
    func switchDatabase(_ connectionID: UUID, to database: String) async -> Bool {
        guard var config = liveConfig(for: connectionID) else { return false }
        config.database = database
        if let existing = active[connectionID] {
            await existing.disconnect()
        }
        active[connectionID] = nil
        connectionStatus[connectionID] = .connecting
        // O túnel continua servindo o mesmo servidor: trocar de banco não o derruba,
        // só toma mais um usuário dele (o anterior é solto no fim).
        let routed: ConnectionConfig
        do {
            routed = try await routeThroughTunnel(config)
        } catch {
            connectionStatus[connectionID] = .failed(error.localizedDescription)
            return false
        }
        let driver = makeDriver(routed)
        do {
            try await driver.connect()
            active[connectionID] = driver
            connectionStatus[connectionID] = .connected
            let session = session(for: connectionID)
            session.activeDatabase = database
            session.tables = []
            session.tablesLoaded = false
            // As abas de tabela pertencem ao banco antigo — fechadas aqui para não
            // recarregarem contra o novo banco ("Table doesn't exist").
            session.closeTableTabs()
            // A conexão anterior já foi fechada: o usuário dela sai da contagem agora.
            if config.usesSSHTunnel { releaseTunnel(connectionID) }
            return true
        } catch {
            connectionStatus[connectionID] = .failed(error.localizedDescription)
            await driver.disconnect()
            if config.usesSSHTunnel { releaseTunnel(connectionID) }
            return false
        }
    }

    /// Cria um banco no servidor da conexão e atualiza a lista de bancos da sessão.
    /// Conecta antes se preciso — dá para criar o banco sem ter aberto nenhum.
    func createDatabase(named name: String, charset: String?, on connectionID: UUID) async throws {
        var driver = active[connectionID]
        if driver == nil {
            _ = await connect(connectionID)
            driver = active[connectionID]
        }
        guard let driver else {
            if case .failed(let message) = connectionStatus[connectionID] {
                throw DriverError.queryFailed(message)
            }
            throw DriverError.notConnected
        }
        try await driver.createDatabase(named: name, charset: charset)
        if let list = try? await driver.databases() {
            setDatabases(list, for: connectionID)
        } else {
            let session = session(for: connectionID)
            session.databases = (session.databases + [name]).sorted()
        }
    }

    func disconnect(_ connectionID: UUID) {
        Task {
            if let driver = active[connectionID] {
                await driver.disconnect()
            }
            active[connectionID] = nil
            connectionStatus[connectionID] = .disconnected
            releaseTunnel(connectionID)
            // O banco trocado em sessão morre com a conexão: reconectar volta ao banco do
            // cadastro — sem limpar, chip/subtítulo/tabelas mentiriam sobre o banco aberto.
            if let session = sessions[connectionID] {
                session.activeDatabase = nil
                session.tables = []
                session.tablesLoaded = false
            }
        }
    }

    private func persist() {
        WorkspaceStore.save(workspaces)
    }

    // MARK: - Consultas salvas

    func addSavedQuery(title: String, sql: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = SavedQuery(title: trimmed.isEmpty ? "Sem título" : trimmed, sql: sql)
        savedQueries.insert(query, at: 0)
        SavedQueryStore.save(savedQueries)
    }

    func removeSavedQuery(_ id: UUID) {
        savedQueries.removeAll { $0.id == id }
        SavedQueryStore.save(savedQueries)
    }
}
