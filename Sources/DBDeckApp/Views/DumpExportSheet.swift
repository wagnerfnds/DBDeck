import SwiftUI
import DBDeckCore

/// Exportação de dump estilo Sequel Ace: conecta um driver temporário ao banco alvo,
/// deixa escolher tabelas e opções (estrutura/dados/ambos), e acompanha o progresso
/// com cancelamento — nada de esperar o dump inteiro às cegas antes do save panel.
struct DumpExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let connectionID: UUID
    /// Banco alvo (nil = o fixo do cadastro / padrão do engine).
    let database: String?
    /// Rótulo exibido e nome sugerido do arquivo.
    let title: String

    private enum Phase: Equatable {
        case connecting
        case selecting
        case running
        case finished
    }

    @State private var phase: Phase = .connecting
    @State private var driver: (any DatabaseDriver)?
    @State private var tables: [DatabaseTable] = []
    @State private var selected: Set<String> = []
    @State private var tableFilter = ""
    @State private var loadError: String?
    @State private var options = DumpOptions()

    @State private var dumpTask: Task<Void, Never>?
    @State private var cancelToken: CancelToken?
    @State private var cancelling = false
    @State private var currentTable = ""
    @State private var tableIndex = 0
    @State private var tableCount = 0
    @State private var rowsWritten = 0
    @State private var bytesWritten = 0
    @State private var elapsed: TimeInterval = 0
    @State private var failure: String?
    @State private var savedURL: URL?

    private var filteredTables: [DatabaseTable] {
        let term = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return tables }
        return tables.filter { $0.name.lowercased().contains(term) }
    }

    private var engine: SQLEngine? { driver?.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dump de “\(title)”").font(.title3.bold())
                    Text(subtitleText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            content

            HStack {
                Spacer()
                switch phase {
                case .connecting, .selecting:
                    Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                    if phase == .selecting {
                        Button("Exportar…") { startExport() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(selected.isEmpty)
                    }
                case .running:
                    Button(cancelling ? "Cancelando…" : "Cancelar exportação") {
                        cancelling = true
                        cancelToken?.cancel()
                        dumpTask?.cancel()
                    }
                    .disabled(cancelling)
                    .keyboardShortcut(.cancelAction)
                case .finished:
                    if let savedURL {
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                        }
                    }
                    Button("Fechar") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .task { await connectAndList() }
        .onDisappear {
            cancelToken?.cancel()
            dumpTask?.cancel()
            let orphan = driver
            driver = nil
            if orphan != nil { state.releaseEphemeralTunnel(for: connectionID) }
            Task { await orphan?.disconnect() }
        }
    }

    private var subtitleText: String {
        switch phase {
        case .connecting: return "Conectando…"
        case .selecting: return "\(selected.count) de \(tables.count) tabelas selecionadas"
        case .running: return "Exportando…"
        case .finished: return failure == nil ? "Concluído" : "Falhou"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .connecting:
            VStack(spacing: 10) {
                if let loadError {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                    Text(loadError).font(.callout).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                    Text("Conectando ao banco…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .selecting:
            HStack(alignment: .top, spacing: 14) {
                tablePicker
                optionsPanel.frame(width: 210)
            }
        case .running:
            runningPanel
        case .finished:
            VStack(spacing: 10) {
                if let failure {
                    Image(systemName: "xmark.octagon.fill").font(.title).foregroundStyle(.red)
                    Text(failure).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                    Text("Dump salvo em \(savedURL?.lastPathComponent ?? "arquivo")").font(.callout)
                    Text("\(formatBytes(bytesWritten)) em \(formatDuration(elapsed))\(elapsed > 0 ? " · \(formatBytes(Int(Double(bytesWritten) / elapsed)))/s" : "")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tablePicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filtrar tabelas", text: $tableFilter)
                    .textFieldStyle(.plain).font(.system(size: 12))
                Button("Todas") { selected = Set(tables.map(\.name)) }.controlSize(.small)
                Button("Nenhuma") { selected = [] }.controlSize(.small)
            }
            List(filteredTables) { table in
                Toggle(isOn: toggleBinding(table.name)) {
                    Label {
                        Text(table.name).lineLimit(1)
                    } icon: {
                        Image(systemName: table.kind == "view" ? "eye" : "tablecells")
                            .foregroundStyle(table.kind == "view" ? Color.purple : Color.accentColor)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
        }
    }

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Conteúdo").font(.caption.bold()).foregroundStyle(.secondary)
                Picker("", selection: $options.content) {
                    ForEach(DumpOptions.Content.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Divider()

                Text("Opções").font(.caption.bold()).foregroundStyle(.secondary)
                Toggle("DROP antes do CREATE", isOn: $options.dropBeforeCreate)
                    .disabled(options.content == .dataOnly)
                Toggle("Incluir views", isOn: $options.includeViews)
                    .disabled(options.content == .dataOnly)
                if engine == .mysql {
                    Toggle("Incluir triggers e rotinas", isOn: $options.includeRoutines)
                        .disabled(options.content == .dataOnly)
                    Toggle("CREATE DATABASE + USE", isOn: $options.includeCreateDatabase)
                    Toggle("Remover DEFINER", isOn: $options.stripDefiner)
                        .help("Sem isso o import falha em outro servidor com “definer does not exist”.")
                }
                Toggle("INSERT com várias linhas", isOn: $options.extendedInserts)
                    .disabled(options.content == .structureOnly)
                    .help("Uma ordem de grandeza mais rápido no import. Desligue só para diffs linha a linha.")
                Toggle("Cabeçalho de compatibilidade", isOn: $options.compatibilityHeader)
                    .help("Desliga checagem de FK/unicidade e autocommit durante o restore.")
                Toggle("Leitura consistente", isOn: $options.consistentSnapshot)
                    .disabled(options.content == .structureOnly || engine != .mysql)
                    .help("Lê todas as tabelas do mesmo instante lógico, sem travar escritas.")
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            ProgressView(value: tableCount > 0 ? Double(tableIndex) / Double(tableCount) : 0)
            HStack {
                Text(currentTable.isEmpty ? "Preparando…" : currentTable)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text("tabela \(tableIndex)/\(tableCount)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("\(rowsWritten) linhas")
                Spacer()
                Text(formatBytes(bytesWritten))
                if elapsed > 0.5 {
                    Text("· \(formatBytes(Int(Double(bytesWritten) / elapsed)))/s")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { if $0 { selected.insert(name) } else { selected.remove(name) } }
        )
    }

    private func formatBytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        value < 60 ? String(format: "%.1fs", value) : String(format: "%dm %02ds", Int(value) / 60, Int(value) % 60)
    }

    // MARK: - Fluxo

    private func connectAndList() async {
        do {
            let driver = try await state.ephemeralDriver(for: connectionID, database: database)
            // O connect dos drivers não aborta com o cancelamento da .task: se o sheet já
            // fechou, a conexão chega "atrasada" e ninguém mais faria o disconnect — o
            // socket (e o event loop do driver) vazariam até o app fechar.
            if Task.isCancelled {
                await driver.disconnect()
                state.releaseEphemeralTunnel(for: connectionID)
                return
            }
            self.driver = driver
            tables = try await driver.tables()
            selected = Set(tables.map(\.name))
            phase = .selecting
        } catch {
            if !Task.isCancelled {
                loadError = error.localizedDescription
            }
        }
    }

    private func startExport() {
        guard let driver else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.sanitized)-dump.sql"
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let chosen = tables.filter { selected.contains($0.name) }
        phase = .running
        tableIndex = 0
        tableCount = chosen.filter { $0.kind == "table" }.count
        rowsWritten = 0
        bytesWritten = 0
        elapsed = 0
        currentTable = ""
        cancelling = false

        var runOptions = options
        runOptions.databaseName = database ?? title

        let token = CancelToken()
        cancelToken = token
        let startedAt = Date()

        // O dump roda fora do MainActor: o writer é @unchecked Sendable (chamadas seriais,
        // vindas da thread de I/O do driver) e o progresso volta para a UI num hop explícito.
        let applyProgress: @MainActor (DumpProgress) -> Void = { update in
            tableIndex = update.tableIndex
            tableCount = max(tableCount, update.tableCount)
            rowsWritten = update.rowsWritten
            bytesWritten = update.bytesWritten
            elapsed = Date().timeIntervalSince(startedAt)
            if !update.tableName.isEmpty { currentTable = update.tableName }
        }

        dumpTask = Task {
            do {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let writer = try DumpFileWriter(url: url)
                do {
                    try await SQLDump.dump(
                        driver: driver,
                        tables: chosen,
                        options: runOptions,
                        cancel: token,
                        write: { chunk in try writer.write(chunk) },
                        progress: { update in Task { @MainActor in applyProgress(update) } }
                    )
                    try writer.close()
                } catch {
                    try? writer.close()
                    throw error
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                bytesWritten = (attributes?[.size] as? Int) ?? bytesWritten
                elapsed = Date().timeIntervalSince(startedAt)
                savedURL = url
                failure = nil
                phase = .finished
            } catch is CancellationError {
                finishCancelled(url)
            } catch DumpError.cancelled {
                finishCancelled(url)
            } catch {
                // Cancelamento pode chegar embrulhado num erro de driver (a query em voo
                // falha ao ser cancelada) — se foi cancelado, é o mesmo fluxo.
                if token.isCancelled || Task.isCancelled {
                    finishCancelled(url)
                } else {
                    failure = error.localizedDescription
                    phase = .finished
                }
            }
        }
    }

    /// Cancelado pelo usuário: descarta o arquivo parcial e volta à seleção.
    private func finishCancelled(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        cancelToken = nil
        cancelling = false
        phase = .selecting
    }
}

/// Escrita bufferizada do dump. As chamadas de `write` são seriais (uma por chunk,
/// dentro do próprio dump), então o acesso ao FileHandle é seguro. O buffer evita
/// uma syscall por bloco — o dump emite muitos pedaços pequenos entre as tabelas.
private final class DumpFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let flushThreshold = 4 << 20

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(flushThreshold + (1 << 20))
    }

    func write(_ chunk: String) throws {
        buffer.append(contentsOf: chunk.utf8)
        if buffer.count >= flushThreshold { try flush() }
    }

    func close() throws {
        try flush()
        try? handle.close()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
