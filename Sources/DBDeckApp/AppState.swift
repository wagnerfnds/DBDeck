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
    var selectedConnectionID: UUID?
    var active: [UUID: any DatabaseDriver] = [:]
    var connectionStatus: [UUID: ConnectionStatus] = [:]

    init() {
        migrateLegacyPasswords()
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

    func addConnection(_ config: ConnectionConfig, to workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        KeychainManager.setPassword(config.password, for: config.id)
        var stored = config
        stored.password = ""
        workspaces[index].connections.append(stored)
        persist()
    }

    func updateConnection(_ config: ConnectionConfig) {
        guard
            let workspaceIndex = workspaces.firstIndex(where: { $0.connections.contains { $0.id == config.id } }),
            let connectionIndex = workspaces[workspaceIndex].connections.firstIndex(where: { $0.id == config.id })
        else { return }
        if let driver = active[config.id] {
            Task { await driver.disconnect() }
            active[config.id] = nil
            connectionStatus[config.id] = .disconnected
        }
        KeychainManager.setPassword(config.password, for: config.id)
        var stored = config
        stored.password = ""
        workspaces[workspaceIndex].connections[connectionIndex] = stored
        persist()
    }

    func deleteConnection(_ config: ConnectionConfig) {
        disconnect(config.id)
        KeychainManager.deletePassword(for: config.id)
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
        connectionStatus[config.id] = .connecting
        let driver: any DatabaseDriver
        switch config.engine {
        case .postgres: driver = PostgresDriver(config: config)
        case .mysql: driver = MySQLDriver(config: config)
        case .sqlite: driver = SQLiteDriver(config: config)
        }
        do {
            try await driver.connect()
            active[config.id] = driver
            connectionStatus[config.id] = .connected
            return driver
        } catch {
            connectionStatus[config.id] = .failed(error.localizedDescription)
            await driver.disconnect()
            return nil
        }
    }

    func connect(_ connectionID: UUID) async -> Bool {
        guard let config = liveConfig(for: connectionID) else { return false }
        return await driver(for: config) != nil
    }

    func disconnect(_ connectionID: UUID) {
        Task {
            if let driver = active[connectionID] {
                await driver.disconnect()
            }
            active[connectionID] = nil
            connectionStatus[connectionID] = .disconnected
        }
    }

    private func persist() {
        WorkspaceStore.save(workspaces)
    }
}
