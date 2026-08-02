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

    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Editar conexão" : "Nova conexão")
                .font(.title2.bold())
                .padding(.bottom, 16)

            Form {
                TextField("Nome", text: $config.name)

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
                        TextField("Porta", value: $config.port, format: .number)
                            .frame(width: 90)
                    }
                    TextField("Usuário", text: $config.username)
                    SecureField("Senha", text: $config.password)
                    TextField("Banco de dados", text: $config.database)
                    Toggle("Usar TLS", isOn: $config.useTLS)
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

    private var isEditing: Bool {
        config.id != UUID() && workspaceID != nil && state.config(for: config.id) != nil
    }

    private func save() {
        let trimmedName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.name = trimmedName.isEmpty ? "Sem nome" : trimmedName
        if isEditing {
            state.updateConnection(config)
        } else if let workspaceID {
            state.addConnection(config, to: workspaceID)
        }
        dismiss()
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let result = await TestConnection.run(config: config)
        testResult = result
        testing = false
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
    static func run(config: ConnectionConfig) async -> String {
        let driver: any DatabaseDriver
        switch config.engine {
        case .postgres: driver = PostgresDriver(config: config)
        case .mysql: driver = MySQLDriver(config: config)
        case .sqlite: driver = SQLiteDriver(config: config)
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
