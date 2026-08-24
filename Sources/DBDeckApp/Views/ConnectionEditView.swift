import SwiftUI
import DBDeckCore

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    @State private var config: ConnectionConfig
    let workspaceID: UUID?

    init(config: ConnectionConfig, workspaceID: UUID?) {
        _config = State(initialValue: config)
        self.workspaceID = workspaceID
    }

    /// Senha ou passphrase do SSH digitada agora. Vazio significa "manter o que já está
    /// no Keychain" — o mesmo contrato do campo de senha do banco.
    @State private var sshSecret = ""

    @State private var testing = false
    @State private var testResult: String?
    @State private var databases: [String] = []
    @State private var loadingDatabases = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                EngineBadge(engine: config.engine, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Editar conexão" : "Nova conexão")
                        .font(.title2.bold())
                    Text(config.engine.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Form {
                TextField("Nome", text: $config.name)

                colorPicker

                Picker("Banco", selection: $config.engine) {
                    ForEach(SQLEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: config.engine) { _, newEngine in
                    config.port = newEngine.defaultPort
                }

                if config.engine == .sqlite {
                    HStack {
                        TextField("Caminho do arquivo", text: $config.sqlitePath)
                            .font(.system(.body, design: .monospaced))
                        Button("Procurar…") {
                            browseForSQLiteFile()
                        }
                    }
                } else {
                    HStack {
                        TextField("Host", text: $config.host)
                        TextField("Porta", value: $config.port, format: .number.grouping(.never))
                            .frame(width: 90)
                    }
                    TextField("Usuário", text: $config.username)
                    SecureField("Senha", text: $config.password)
                    databaseField
                    Toggle("Usar TLS", isOn: $config.useTLS)
                }

                if config.engine != .sqlite {
                    sshSection
                }
            }
            .formStyle(.grouped)

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Testar conexão") {
                    Task { await testConnection() }
                }
                .disabled(testing)
                Button("Salvar") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 480)
        .padding(.top, 20)
    }

    /// `config.ssh` é opcional (JSONs antigos não têm o campo); aqui ele é sempre um
    /// valor concreto para os campos do formulário.
    private var ssh: Binding<SSHConfig> {
        Binding(get: { config.sshConfig }, set: { config.ssh = $0 })
    }

    @ViewBuilder
    private var sshSection: some View {
        Section("Túnel SSH") {
            Toggle("Conectar por um túnel SSH", isOn: ssh.enabled)
            if config.sshConfig.enabled {
                HStack {
                    TextField("Servidor SSH", text: ssh.host)
                    TextField("Porta", value: ssh.port, format: .number.grouping(.never))
                        .frame(width: 90)
                }
                TextField("Usuário SSH", text: ssh.username)
                Picker("Autenticação", selection: ssh.authMethod) {
                    ForEach(SSHAuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                switch config.sshConfig.authMethod {
                case .agent:
                    Text("Usa as chaves do ssh-agent e as opções do ~/.ssh/config (inclusive ProxyJump). O app não guarda senha nenhuma.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .privateKey:
                    HStack {
                        TextField("Arquivo da chave", text: ssh.privateKeyPath)
                            .font(.system(.body, design: .monospaced))
                        Button("Procurar…") { browseForPrivateKey() }
                    }
                    SecureField("Passphrase da chave (se houver)", text: $sshSecret)
                case .password:
                    SecureField("Senha SSH", text: $sshSecret)
                }
                Text("O banco é alcançado como \(config.host.isEmpty ? "host" : config.host):\(config.port) a partir do servidor SSH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var colorPicker: some View {
        HStack {
            Text("Cor")
            Spacer()
            ForEach(ConnectionColor.presets, id: \.name) { preset in
                Circle()
                    .fill(preset.color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: config.color == preset.name ? 2.5 : 0))
                    .contentShape(Circle())
                    .onTapGesture { config.color = (config.color == preset.name) ? nil : preset.name }
            }
        }
    }

    private var databaseField: some View {
        HStack(spacing: 6) {
            TextField("Banco de dados", text: $config.database)
            if !databases.isEmpty {
                Picker("", selection: $config.database) {
                    if !databases.contains(config.database) && !config.database.isEmpty {
                        Text(config.database).tag(config.database)
                    }
                    ForEach(databases, id: \.self) { db in
                        Text(db).tag(db)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            Button {
                Task { await loadDatabases() }
            } label: {
                if loadingDatabases {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Listar", systemImage: "arrow.down.circle")
                }
            }
            .help("Conectar ao host e listar os bancos disponíveis")
            .disabled(loadingDatabases || config.host.isEmpty)
        }
    }

    private func loadDatabases() async {
        loadingDatabases = true
        testResult = nil
        defer { loadingDatabases = false }
        let live: ConnectionConfig
        let tunnel: SSHTunnel?
        do {
            (live, tunnel) = try await TestConnection.prepare(config, sshSecret: sshSecret)
        } catch {
            testResult = "✗ \(error.localizedDescription)"
            return
        }
        defer { tunnel?.close() }
        // Postgres precisa de um banco para conectar; sem banco escolhido o driver tenta
        // `postgres` e depois o banco homônimo do usuário.
        let driver: any DatabaseDriver
        switch live.engine {
        case .postgres: driver = PostgresDriver(config: live)
        case .mysql: driver = MySQLDriver(config: live)
        case .sqlite: driver = SQLiteDriver(config: live)
        }
        do {
            try await driver.connect()
            let list = try await driver.databases()
            await driver.disconnect()
            databases = list
            config.cachedDatabases = list
            if list.isEmpty {
                testResult = "Nenhum banco listado."
            } else {
                testResult = "✓ \(list.count) bancos encontrados"
                if config.database.isEmpty, let first = list.first { config.database = first }
            }
        } catch {
            await driver.disconnect()
            testResult = "✗ \(error.localizedDescription)"
        }
    }

    private var isEditing: Bool {
        config.id != UUID() && workspaceID != nil && state.config(for: config.id) != nil
    }

    private func save() {
        let trimmedName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.name = trimmedName.isEmpty ? "Sem nome" : trimmedName
        // Campo vazio não apaga o segredo guardado: só substitui quando algo foi digitado.
        let secret = sshSecret.isEmpty ? nil : sshSecret
        if isEditing {
            state.updateConnection(config, sshSecret: secret)
        } else if let workspaceID {
            state.addConnection(config, sshSecret: secret, to: workspaceID)
        }
        dismiss()
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let result = await TestConnection.run(config: config, sshSecret: sshSecret)
        testResult = result
        testing = false
    }

    private func browseForPrivateKey() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // As chaves moram em ~/.ssh, que o painel esconde por padrão.
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            ssh.wrappedValue.privateKeyPath = url.path
        }
        #endif
    }

    private func browseForSQLiteFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .init(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            config.sqlitePath = url.path
        }
        #endif
    }
}

enum TestConnection {
    /// Config pronta para conectar — senha hidratada e, quando há SSH, apontando para um
    /// túnel avulso. O túnel devolvido é de quem chamou fechar.
    ///
    /// Avulso de propósito: o formulário pode estar editando outro host/porta/credencial,
    /// e reaproveitar o túnel da conexão ativa testaria o servidor errado.
    static func prepare(_ config: ConnectionConfig, sshSecret: String?) async throws -> (ConnectionConfig, SSHTunnel?) {
        var live = config
        // A senha digitada agora vence a do Keychain: senão, testar uma senha nova numa
        // conexão já salva testaria silenciosamente a antiga.
        if live.password.isEmpty {
            live.password = KeychainManager.password(for: config.id) ?? ""
        }
        guard live.usesSSHTunnel else { return (live, nil) }
        let secret = (sshSecret?.isEmpty == false)
            ? sshSecret
            : KeychainManager.password(for: config.id, kind: .ssh)
        let tunnel = try await SSHTunnel.open(
            config: live.sshConfig,
            remoteHost: live.host,
            remotePort: live.port,
            secret: secret
        )
        live.host = "127.0.0.1"
        live.port = tunnel.localPort
        return (live, tunnel)
    }

    static func run(config: ConnectionConfig, sshSecret: String? = nil) async -> String {
        let live: ConnectionConfig
        let tunnel: SSHTunnel?
        do {
            (live, tunnel) = try await prepare(config, sshSecret: sshSecret)
        } catch {
            return "✗ \(error.localizedDescription)"
        }
        defer { tunnel?.close() }
        let driver: any DatabaseDriver
        switch live.engine {
        case .postgres: driver = PostgresDriver(config: live)
        case .mysql: driver = MySQLDriver(config: live)
        case .sqlite: driver = SQLiteDriver(config: live)
        }
        do {
            try await driver.connect()
            await driver.disconnect()
            return "✓ Conectou com sucesso"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }
}
