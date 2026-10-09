import SwiftUI
import UniformTypeIdentifiers
import DBDeckCore

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings

    @State private var config: ConnectionConfig
    @State private var workspaceID: UUID?
    private let isNew: Bool

    @State private var testing = false
    @State private var testResult: TestOutcome?
    @State private var databases: [String] = []
    @State private var pickingDatabase = false
    @State private var loadingDatabases = false
    @State private var showImporter = false
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var fileError: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, host, port, user, password, database }

    private enum TestOutcome: Equatable {
        case success(String)
        case failure(String)
    }

    init(draft: ConnectionDraft) {
        var config = draft.config
        if draft.isNew {
            // Conexão nova não tem segredo guardado; a senha vai ser digitada aqui.
            config.password = ""
            config.name = ""
        } else {
            config.password = KeychainManager.password(for: config.id) ?? ""
        }
        _config = State(initialValue: config)
        _workspaceID = State(initialValue: draft.workspaceID)
        isNew = draft.isNew
    }

    var body: some View {
        Form {
            Section {
                enginePicker
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            Section("Identificação") {
                TextField("Nome (ex.: Produção, Loja local)", text: $config.name)
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = config.engine == .sqlite ? nil : .host }
                colorPicker
                if state.workspaces.count > 1 {
                    Picker("Workspace", selection: $workspaceID) {
                        ForEach(state.workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                }
            }

            if config.engine == .sqlite {
                sqliteSection
            } else {
                serverSection
                credentialsSection
                databaseSection
                sshSection
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Label("Testar conexão", systemImage: "bolt.horizontal")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
                if let testResult {
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label {
                            Text(message).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Nova conexão" : "Editar conexão")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy, value: config.engine)
        .animation(.snappy, value: testResult)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Salvar") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.sqliteTypes,
            allowsMultipleSelection: false
        ) { result in
            importFile(result)
        }
        .alert("Novo banco SQLite", isPresented: $showNewFile) {
            TextField("nome", text: $newFileName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Criar") {
                let url = SQLiteFileStore.newDatabaseURL(named: newFileName)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                config.sqlitePath = url.path
                if config.name.isEmpty { config.name = url.deletingPathExtension().lastPathComponent }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O arquivo fica em Arquivos › No meu iPhone › DBDeck › Databases.")
        }
        .errorAlert($fileError)
        .navigationDestination(isPresented: $pickingDatabase) {
            DatabaseList(
                databases: databases,
                current: config.database.isEmpty ? nil : config.database,
                recents: RecentDatabases.list(for: config.id),
                engine: config.engine,
                onPick: { name in
                    config.database = name
                    pickingDatabase = false
                },
                onRefresh: { await loadDatabases() }
            )
            .navigationTitle("Banco padrão")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if isNew, config.engine != settings.defaultEngine, config.host == "localhost" {
                config.engine = settings.defaultEngine
                config.port = settings.defaultEngine.defaultPort
            }
        }
    }

    // MARK: - Seções

    private var enginePicker: some View {
        HStack(spacing: 10) {
            ForEach(SQLEngine.allCases) { engine in
                let selected = config.engine == engine
                Button {
                    guard !selected else { return }
                    Haptics.selection()
                    // A porta só acompanha o engine se o usuário não a mudou.
                    if config.port == config.engine.defaultPort || config.port == 0 {
                        config.port = engine.defaultPort
                    }
                    config.engine = engine
                    testResult = nil
                } label: {
                    VStack(spacing: 8) {
                        EngineBadge(engine: engine, size: 34)
                        Text(engine.displayName)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? engine.accent : Color.clear, lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var colorPicker: some View {
        HStack {
            Text("Cor")
            Spacer()
            HStack(spacing: 6) {
                ForEach(ConnectionColor.presets, id: \.name) { preset in
                    let selected = config.color == preset.name
                    Circle()
                        .fill(preset.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.selection()
                            config.color = selected ? nil : preset.name
                        }
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var serverSection: some View {
        Section("Servidor") {
            LabeledContent("Host") {
                TextField("localhost", text: $config.host)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focused = .port }
            }
            LabeledContent("Porta") {
                TextField("\(config.engine.defaultPort)", value: $config.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .focused($focused, equals: .port)
            }
            Toggle("Usar TLS", isOn: $config.useTLS)
        }
    }

    private var credentialsSection: some View {
        Section {
            LabeledContent("Usuário") {
                TextField("usuário", text: $config.username)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused, equals: .user)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
            LabeledContent("Senha") {
                SecureField("senha", text: $config.password)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focused = .database }
            }
        } header: {
            Text("Credenciais")
        } footer: {
            Text("A senha fica no Keychain do iOS — nunca em arquivo.")
        }
    }

    private var databaseSection: some View {
        Section {
            LabeledContent("Banco") {
                TextField(config.engine == .postgres ? "postgres" : "opcional", text: $config.database)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused, equals: .database)
                    .submitLabel(.done)
            }
            if !databases.isEmpty {
                Button {
                    pickingDatabase = true
                } label: {
                    HStack {
                        Text("Escolher da lista").foregroundStyle(.primary)
                        Spacer()
                        Text("\(databases.count) bancos").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            Button {
                Task { await loadDatabases() }
            } label: {
                HStack {
                    Label("Listar bancos do servidor", systemImage: "list.bullet.rectangle")
                    Spacer()
                    if loadingDatabases { ProgressView() }
                }
            }
            .disabled(loadingDatabases || config.host.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Banco de dados")
        } footer: {
            Text("Vazio abre o servidor sem banco fixo — dá para trocar de banco depois, na lista de tabelas.")
        }
    }

    @ViewBuilder
    private var sshSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Túnel SSH")
                    Text(config.sshConfig.enabled
                        ? "Configurado no Mac (\(config.sshConfig.host)) — não disponível no iOS."
                        : "Ainda não disponível no iOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
            }
            if config.sshConfig.enabled {
                Button("Conectar sem o túnel") {
                    var ssh = config.sshConfig
                    ssh.enabled = false
                    config.ssh = ssh
                }
            }
        } footer: {
            Text("Para servidores atrás de um bastion, use uma VPN (ex.: Tailscale, WireGuard) e aponte o host para o endereço privado.")
        }
    }

    private var sqliteSection: some View {
        Section {
            if !config.sqlitePath.isEmpty {
                let url = URL(fileURLWithPath: SQLiteFileStore.resolve(config.sqlitePath))
                LabeledContent {
                    Text(SQLiteFileStore.sizeLabel(url)).foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "doc.fill").foregroundStyle(SQLEngine.sqlite.accent)
                    }
                }
            }
            let files = SQLiteFileStore.files()
            if !files.isEmpty {
                Menu {
                    ForEach(files, id: \.self) { url in
                        Button {
                            config.sqlitePath = url.path
                            if config.name.isEmpty { config.name = url.deletingPathExtension().lastPathComponent }
                        } label: {
                            Text(url.lastPathComponent)
                            Text(SQLiteFileStore.sizeLabel(url))
                        }
                    }
                } label: {
                    Label("Bancos no app", systemImage: "tray.full")
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("Importar do app Arquivos…", systemImage: "folder")
            }
            Button {
                newFileName = ""
                showNewFile = true
            } label: {
                Label("Criar banco vazio…", systemImage: "plus.rectangle.on.folder")
            }
        } header: {
            Text("Arquivo")
        } footer: {
            Text("Arquivos importados são copiados para o app. Também dá para copiá-los pelo Finder ou pelo app Arquivos, na pasta DBDeck.")
        }
    }

    // MARK: - Ações

    private static let sqliteTypes: [UTType] = {
        var types: [UTType] = [.database]
        for ext in ["sqlite", "sqlite3", "db", "db3"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.data)
        return types
    }()

    private var canSave: Bool {
        switch config.engine {
        case .sqlite: !config.sqlitePath.isEmpty
        default: !config.host.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func importFile(_ result: Result<[URL], any Error>) {
        do {
            guard let source = try result.get().first else { return }
            let copied = try SQLiteFileStore.importFile(from: source)
            config.sqlitePath = copied.path
            if config.name.isEmpty { config.name = copied.deletingPathExtension().lastPathComponent }
            Haptics.success()
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func makeDriver(_ config: ConnectionConfig) -> any DatabaseDriver {
        switch config.engine {
        case .postgres: PostgresDriver(config: config)
        case .mysql: MySQLDriver(config: config)
        case .sqlite: SQLiteDriver(config: config)
        }
    }

    private var liveConfig: ConnectionConfig {
        var live = config
        live.sqlitePath = SQLiteFileStore.resolve(live.sqlitePath)
        return live
    }

    private func testConnection() async {
        focused = nil
        testing = true
        testResult = nil
        defer { testing = false }
        if config.usesSSHTunnel {
            testResult = .failure(SSHTunnelError.sshUnavailable.localizedDescription)
            Haptics.error()
            return
        }
        let driver = makeDriver(liveConfig)
        do {
            try await driver.connect()
            await driver.disconnect()
            testResult = .success("Conectou com sucesso")
            Haptics.success()
        } catch {
            await driver.disconnect()
            testResult = .failure(error.localizedDescription)
            Haptics.error()
        }
    }

    private func loadDatabases() async {
        focused = nil
        loadingDatabases = true
        testResult = nil
        defer { loadingDatabases = false }
        let driver = makeDriver(liveConfig)
        do {
            try await driver.connect()
            let list = try await driver.databases()
            await driver.disconnect()
            databases = list
            config.cachedDatabases = list
            if list.isEmpty {
                testResult = .failure("Nenhum banco listado.")
            } else {
                testResult = .success("\(list.count) bancos encontrados")
                // Não preenche nada sozinho: banco vazio é uma escolha válida (abre o
                // servidor e escolhe depois). A lista abre para quem quiser fixar um.
                if !pickingDatabase { pickingDatabase = true }
                Haptics.success()
            }
        } catch {
            await driver.disconnect()
            testResult = .failure(error.localizedDescription)
            Haptics.error()
        }
    }

    /// Nome sugerido quando o campo fica vazio: o que identifica a conexão na lista.
    private var defaultName: String {
        switch config.engine {
        case .sqlite:
            let file = (config.sqlitePath as NSString).lastPathComponent
            return file.isEmpty ? "SQLite" : (file as NSString).deletingPathExtension
        default:
            let host = config.host.trimmingCharacters(in: .whitespaces)
            return config.database.isEmpty ? host : "\(config.database) @ \(host)"
        }
    }

    private func save() {
        let trimmed = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.name = trimmed.isEmpty ? defaultName : trimmed
        config.host = config.host.trimmingCharacters(in: .whitespaces)
        if isNew {
            if state.workspaces.isEmpty { state.addWorkspace(named: "Conexões") }
            guard let target = workspaceID ?? state.workspaces.first?.id else { return }
            state.addConnection(config, to: target)
        } else {
            state.updateConnection(config)
            if let workspaceID, state.workspace(for: config.id)?.id != workspaceID {
                var stored = config
                stored.password = ""
                for index in state.workspaces.indices {
                    state.workspaces[index].connections.removeAll { $0.id == config.id }
                }
                if let index = state.workspaces.firstIndex(where: { $0.id == workspaceID }) {
                    state.workspaces[index].connections.append(stored)
                }
                WorkspaceStore.save(state.workspaces)
            }
        }
        Haptics.success()
        dismiss()
    }
}
