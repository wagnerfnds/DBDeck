import SwiftUI
import DBDeckCore

// MARK: - Grid compartilhado (mesmo desenho da aba Estrutura)

/// Cabeçalho e células no estilo da `StructureView`, para as abas de metadados não
/// parecerem outro app.
private enum MetaGrid {
    static func header(_ titles: [(String, CGFloat)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, item in
                Text(item.0)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: item.1, height: Theme.headerHeight, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(Theme.headerBackground)
                    .overlay(alignment: .trailing) {
                        if index < titles.count - 1 { Rectangle().fill(Theme.gridLine).frame(width: 1) }
                    }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gridLine).frame(height: 1) }
    }

    static func cell(_ content: some View, width: CGFloat, rowHeight: CGFloat, last: Bool = false) -> some View {
        content
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .frame(width: width, height: rowHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.gridLine).frame(width: 1) } }
    }

    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.headerBackground.opacity(0.6))
    }

    static func emptyRow(_ text: String, rowHeight: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .italic()
            .frame(height: rowHeight)
            .padding(.horizontal, 10)
    }

    static func toast(_ notice: Binding<String?>) -> some View {
        Group {
            if let text = notice.wrappedValue {
                Text(text)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .padding(12)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { notice.wrappedValue = nil }
                    }
            }
        }
    }
}

// MARK: - Relações

/// Chaves estrangeiras da tabela, no grid da Estrutura: as que saem dela (editáveis) e as
/// que chegam nela (só leitura — pertencem à outra tabela).
struct RelationsView: View {
    @Environment(AppSettings.self) private var settings
    let driver: any DatabaseDriver
    let table: String
    var onOpenTable: (String) -> Void

    @State private var outgoing: [ForeignKey] = []
    @State private var incoming: [ForeignKey] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showingAddSheet = false
    @State private var editingKey: ForeignKey?
    @State private var deletingKey: ForeignKey?

    private let wName: CGFloat = 220
    private let wColumns: CGFloat = 170
    private let wTable: CGFloat = 220
    private let wRefColumns: CGFloat = 170
    private let wAction: CGFloat = 120
    private var totalWidth: CGFloat { wName + wColumns + wTable + wRefColumns + wAction * 2 }

    private var canEdit: Bool { driver.engine != .sqlite }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Carregando relações…")
                Spacer()
            } else {
                grid
            }
            Divider()
            bottomBar
        }
        .task { await reload() }
        .alert("Erro", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showingAddSheet) {
            RelationFormSheet(driver: driver, table: table, original: nil) { spec in
                await apply(spec, replacing: nil)
            }
        }
        .sheet(item: $editingKey) { key in
            RelationFormSheet(driver: driver, table: table, original: key) { spec in
                await apply(spec, replacing: key)
            }
        }
        .confirmationDialog(
            "Remover a relação “\(deletingKey?.name ?? "")”?",
            isPresented: .init(get: { deletingKey != nil }, set: { if !$0 { deletingKey = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover relação", role: .destructive) {
                if let key = deletingKey { Task { await drop(key) } }
                deletingKey = nil
            }
            Button("Cancelar", role: .cancel) { deletingKey = nil }
        } message: {
            Text("O ALTER TABLE executa imediatamente. Os dados ficam; só a restrição some.")
        }
        .overlay(alignment: .bottomTrailing) { MetaGrid.toast($notice) }
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    MetaGrid.header([
                        ("Nome", wName), ("Colunas", wColumns), ("Tabela FK", wTable),
                        ("Colunas FK", wRefColumns), ("On Update", wAction), ("On Delete", wAction),
                    ])
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if outgoing.isEmpty {
                            MetaGrid.emptyRow("Esta tabela não referencia nenhuma outra.", rowHeight: settings.rowHeight)
                        }
                        ForEach(Array(outgoing.enumerated()), id: \.element.id) { index, key in
                            row(key, index: index, from: key.columns, target: key.referencedTable, to: key.referencedColumns)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { if canEdit { editingKey = key } }
                                .contextMenu {
                                    Button("Abrir \(key.referencedTable)") { onOpenTable(key.referencedTable) }
                                    if canEdit {
                                        Divider()
                                        Button("Alterar relação…") { editingKey = key }
                                        Button("Remover relação…", role: .destructive) { deletingKey = key }
                                    }
                                }
                            Divider().opacity(0.4)
                        }
                        if !incoming.isEmpty {
                            MetaGrid.sectionLabel("Referenciada por (pertencem à outra tabela — altere lá)")
                            ForEach(Array(incoming.enumerated()), id: \.element.id) { index, key in
                                row(key, index: index, from: key.referencedColumns, target: key.table, to: key.columns, muted: true)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onOpenTable(key.table) }
                                    .contextMenu {
                                        Button("Abrir \(key.table)") { onOpenTable(key.table) }
                                    }
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                .frame(minWidth: max(totalWidth, geo.size.width), minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ key: ForeignKey, index: Int, from: [String], target: String, to: [String], muted: Bool = false) -> some View {
        let height = settings.rowHeight
        return HStack(spacing: 0) {
            MetaGrid.cell(Text(key.name).fontWeight(muted ? .regular : .medium).foregroundStyle(muted ? .secondary : .primary), width: wName, rowHeight: height)
            MetaGrid.cell(Text(from.joined(separator: ", ")), width: wColumns, rowHeight: height)
            MetaGrid.cell(
                HStack(spacing: 5) {
                    Image(systemName: muted ? "arrow.left" : "arrow.right").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                    Text(target).fontWeight(.medium)
                },
                width: wTable, rowHeight: height
            )
            MetaGrid.cell(Text(to.joined(separator: ", ")), width: wRefColumns, rowHeight: height)
            MetaGrid.cell(actionText(key.onUpdate), width: wAction, rowHeight: height)
            MetaGrid.cell(actionText(key.onDelete), width: wAction, rowHeight: height, last: true)
        }
        .background(index % 2 == 1 && settings.zebraStripes ? Theme.zebra : Color.clear)
    }

    private func actionText(_ action: String) -> some View {
        Text(action == "NO ACTION" || action.isEmpty ? "—" : action)
            .foregroundStyle(action == "NO ACTION" || action.isEmpty ? Theme.nullText : .secondary)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                showingAddSheet = true
            } label: {
                Label("Adicionar relação", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(!canEdit)
            .help(canEdit ? "Cria uma chave estrangeira (ALTER TABLE)" : "SQLite não altera chaves estrangeiras de tabela existente")

            Text(canEdit ? "duplo clique ou botão direito numa relação para alterar/remover" : "SQLite: relações só leitura")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(outgoing.count) relaç\(outgoing.count == 1 ? "ão" : "ões")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Ações

    private func reload() async {
        do {
            outgoing = try await SchemaMetadata.foreignKeys(driver: driver, table: table)
            incoming = try await SchemaMetadata.referencingKeys(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Editar é remover e criar: nenhum engine altera FK no lugar. Se o ADD falhar depois
    /// do DROP, a relação antiga já se foi — o erro diz isso para o usuário refazer.
    private func apply(_ spec: SchemaDDL.ForeignKeySpec, replacing old: ForeignKey?) async -> String? {
        do {
            if let old {
                _ = try await driver.execute(try SchemaDDL.dropForeignKey(engine: driver.engine, table: table, name: old.name))
            }
            do {
                _ = try await driver.execute(try SchemaDDL.addForeignKey(engine: driver.engine, table: table, spec: spec))
            } catch {
                if old != nil {
                    await reload()
                    return "A relação antiga foi removida, mas a nova falhou: \(error.localizedDescription)"
                }
                throw error
            }
            await reload()
            withAnimation { notice = old == nil ? "Relação criada" : "Relação alterada" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func drop(_ key: ForeignKey) async {
        do {
            _ = try await driver.execute(try SchemaDDL.dropForeignKey(engine: driver.engine, table: table, name: key.name))
            await reload()
            withAnimation { notice = "Relação removida" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Formulário de chave estrangeira (estilo Sequel Ace): coluna desta tabela → tabela e
/// coluna referenciadas, ações.
private struct RelationFormSheet: View {
    let driver: any DatabaseDriver
    let table: String
    let original: ForeignKey?
    let onSubmit: (SchemaDDL.ForeignKeySpec) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var column: String
    @State private var referencedTable: String
    @State private var referencedColumn: String
    @State private var onUpdate: String
    @State private var onDelete: String

    @State private var columns: [String] = []
    @State private var tables: [String] = []
    @State private var referencedColumns: [String] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(driver: any DatabaseDriver, table: String, original: ForeignKey?, onSubmit: @escaping (SchemaDDL.ForeignKeySpec) async -> String?) {
        self.driver = driver
        self.table = table
        self.original = original
        self.onSubmit = onSubmit
        _name = State(initialValue: original?.name ?? "")
        _column = State(initialValue: original?.columns.first ?? "")
        _referencedTable = State(initialValue: original?.referencedTable ?? "")
        _referencedColumn = State(initialValue: original?.referencedColumns.first ?? "")
        _onUpdate = State(initialValue: original?.onUpdate ?? "NO ACTION")
        _onDelete = State(initialValue: original?.onDelete ?? "NO ACTION")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Nome") {
                    TextField("Nome", text: $name, prompt: Text("gerado automaticamente"))
                }
                Section("Tabela \(table)") {
                    Picker("Coluna", selection: $column) {
                        ForEach(columns, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Referências") {
                    Picker("Tabela", selection: $referencedTable) {
                        Text("—").tag("")
                        ForEach(tables, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Coluna", selection: $referencedColumn) {
                        Text("—").tag("")
                        ForEach(referencedColumns, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(referencedColumns.isEmpty)
                }
                Section("Ação") {
                    Picker("On update", selection: $onUpdate) {
                        ForEach(SchemaDDL.referentialActions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("On delete", selection: $onDelete) {
                        ForEach(SchemaDDL.referentialActions, id: \.self) { Text($0).tag($0) }
                    }
                }
                if original != nil, let original, original.columns.count > 1 {
                    Section {
                        Text("Esta chave é composta (\(original.columns.joined(separator: ", "))). Alterar por aqui a recria com uma coluna só.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Adicionar" : "Alterar") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || column.isEmpty || referencedTable.isEmpty || referencedColumn.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480)
        .task { await loadChoices() }
        .onChange(of: referencedTable) { _, _ in Task { await loadReferencedColumns(keepSelection: false) } }
    }

    private func loadChoices() async {
        columns = (try? await driver.columns(table: table))?.map(\.name) ?? []
        if column.isEmpty { column = columns.first ?? "" }
        tables = (try? await driver.tables())?.filter { $0.kind == "table" }.map(\.name) ?? []
        await loadReferencedColumns(keepSelection: true)
    }

    private func loadReferencedColumns(keepSelection: Bool) async {
        guard !referencedTable.isEmpty else { referencedColumns = []; referencedColumn = ""; return }
        let loaded = (try? await driver.columns(table: referencedTable)) ?? []
        referencedColumns = loaded.map(\.name)
        if !keepSelection || !referencedColumns.contains(referencedColumn) {
            // A PK da tabela referenciada é quase sempre o alvo.
            referencedColumn = loaded.first(where: \.isPrimaryKey)?.name ?? referencedColumns.first ?? ""
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        let spec = SchemaDDL.ForeignKeySpec(
            name: name, columns: [column], referencedTable: referencedTable,
            referencedColumns: [referencedColumn], onUpdate: onUpdate, onDelete: onDelete
        )
        if let failure = await onSubmit(spec) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}

// MARK: - Triggers

struct TriggersView: View {
    @Environment(AppSettings.self) private var settings
    let driver: any DatabaseDriver
    let table: String

    @State private var triggers: [TableTrigger] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showingAddSheet = false
    @State private var editingTrigger: TableTrigger?
    @State private var deletingTrigger: TableTrigger?

    private let wName: CGFloat = 240
    private let wTiming: CGFloat = 110
    private let wEvent: CGFloat = 160
    private let wBody: CGFloat = 520
    private var totalWidth: CGFloat { wName + wTiming + wEvent + wBody }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Carregando triggers…")
                Spacer()
            } else {
                grid
            }
            Divider()
            bottomBar
        }
        .task { await reload() }
        .alert("Erro", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showingAddSheet) {
            TriggerFormSheet(engine: driver.engine, table: table, original: nil) { spec in
                await apply(spec, replacing: nil)
            }
        }
        .sheet(item: $editingTrigger) { trigger in
            TriggerFormSheet(engine: driver.engine, table: table, original: trigger) { spec in
                await apply(spec, replacing: trigger)
            }
        }
        .confirmationDialog(
            "Remover o trigger “\(deletingTrigger?.name ?? "")”?",
            isPresented: .init(get: { deletingTrigger != nil }, set: { if !$0 { deletingTrigger = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover trigger", role: .destructive) {
                if let trigger = deletingTrigger { Task { await drop(trigger) } }
                deletingTrigger = nil
            }
            Button("Cancelar", role: .cancel) { deletingTrigger = nil }
        } message: {
            Text("O DROP TRIGGER executa imediatamente.")
        }
        .overlay(alignment: .bottomTrailing) { MetaGrid.toast($notice) }
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    MetaGrid.header([("Nome", wName), ("Momento", wTiming), ("Evento", wEvent), ("Corpo", wBody)])
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if triggers.isEmpty {
                            MetaGrid.emptyRow("Nenhum trigger nesta tabela.", rowHeight: settings.rowHeight)
                        }
                        ForEach(Array(triggers.enumerated()), id: \.element.id) { index, trigger in
                            row(trigger, index: index)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { editingTrigger = trigger }
                                .contextMenu {
                                    Button("Alterar trigger…") { editingTrigger = trigger }
                                    Button("Copiar definição") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(trigger.body, forType: .string)
                                    }
                                    Divider()
                                    Button("Remover trigger…", role: .destructive) { deletingTrigger = trigger }
                                }
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(minWidth: max(totalWidth, geo.size.width), minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ trigger: TableTrigger, index: Int) -> some View {
        let height = settings.rowHeight
        let body = trigger.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 0) {
            MetaGrid.cell(
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    Text(trigger.name).fontWeight(.medium)
                },
                width: wName, rowHeight: height
            )
            MetaGrid.cell(Text(trigger.timing).foregroundStyle(.secondary), width: wTiming, rowHeight: height)
            MetaGrid.cell(Text(trigger.event).foregroundStyle(.secondary), width: wEvent, rowHeight: height)
            MetaGrid.cell(Text(body).foregroundStyle(.secondary), width: wBody, rowHeight: height, last: true)
        }
        .background(index % 2 == 1 && settings.zebraStripes ? Theme.zebra : Color.clear)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                showingAddSheet = true
            } label: {
                Label("Adicionar trigger", systemImage: "plus")
            }
            .controlSize(.small)

            Text("duplo clique ou botão direito num trigger para alterar/remover")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(triggers.count) trigger\(triggers.count == 1 ? "" : "s")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Ações

    private func reload() async {
        do {
            triggers = try await SchemaMetadata.triggers(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Editar é DROP + CREATE. Se o CREATE falhar, o trigger antigo já se foi — o erro avisa.
    private func apply(_ spec: SchemaDDL.TriggerSpec, replacing old: TableTrigger?) async -> String? {
        do {
            if let old {
                _ = try await driver.execute(SchemaDDL.dropTrigger(engine: driver.engine, table: table, name: old.name))
            }
            do {
                _ = try await driver.execute(try SchemaDDL.createTrigger(engine: driver.engine, table: table, spec: spec))
            } catch {
                if old != nil {
                    await reload()
                    return "O trigger antigo foi removido, mas o novo falhou: \(error.localizedDescription)"
                }
                throw error
            }
            await reload()
            withAnimation { notice = old == nil ? "Trigger criado" : "Trigger alterado" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func drop(_ trigger: TableTrigger) async {
        do {
            _ = try await driver.execute(SchemaDDL.dropTrigger(engine: driver.engine, table: table, name: trigger.name))
            await reload()
            withAnimation { notice = "Trigger removido" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TriggerFormSheet: View {
    let engine: SQLEngine
    let table: String
    let original: TableTrigger?
    let onSubmit: (SchemaDDL.TriggerSpec) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var timing: String
    @State private var events: Set<String>
    @State private var forEachRow = true
    @State private var triggerBody: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(engine: SQLEngine, table: String, original: TableTrigger?, onSubmit: @escaping (SchemaDDL.TriggerSpec) async -> String?) {
        self.engine = engine
        self.table = table
        self.original = original
        self.onSubmit = onSubmit
        _name = State(initialValue: original?.name ?? "")
        _timing = State(initialValue: original?.timing ?? "AFTER")
        _events = State(initialValue: Set(original?.event.components(separatedBy: " OR ") ?? ["INSERT"]))
        _triggerBody = State(initialValue: Self.editableBody(original, engine: engine))
    }

    /// Postgres devolve a definição inteira; para editar interessa só a parte executada.
    private static func editableBody(_ original: TableTrigger?, engine: SQLEngine) -> String {
        guard let original else { return "" }
        if engine == .postgres, let range = original.body.range(of: "EXECUTE ", options: .caseInsensitive) {
            return String(original.body[range.lowerBound...])
        }
        if engine != .postgres, let range = original.body.range(of: "FOR EACH ROW", options: .caseInsensitive) {
            return String(original.body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if engine == .sqlite, let range = original.body.range(of: "BEGIN", options: .caseInsensitive) {
            return String(original.body[range.lowerBound...])
        }
        return original.body
    }

    private var singleEvent: Bool { engine != .postgres }


    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Trigger") {
                    TextField("Nome", text: $name)
                    Picker("Momento", selection: $timing) {
                        ForEach(SchemaDDL.triggerTimings.filter { engine != .mysql || $0 != "INSTEAD OF" }, id: \.self) { Text($0).tag($0) }
                    }
                    if singleEvent {
                        Picker("Evento", selection: Binding(
                            get: { events.first ?? "INSERT" },
                            set: { events = [$0] }
                        )) {
                            ForEach(SchemaDDL.triggerEvents, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        HStack {
                            Text("Eventos")
                            Spacer()
                            ForEach(SchemaDDL.triggerEvents, id: \.self) { event in
                                Toggle(event, isOn: Binding(
                                    get: { events.contains(event) },
                                    set: { if $0 { events.insert(event) } else { events.remove(event) } }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                        Picker("Escopo", selection: $forEachRow) {
                            Text("Por linha").tag(true)
                            Text("Por statement").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    TextEditor(text: $triggerBody)
                        .font(Font(Theme.codeFont(size: 12)))
                        .frame(minHeight: 140)
                } header: {
                    Text(engine == .postgres ? "Função a executar" : "Corpo")
                } footer: {
                    Text(engine == .postgres
                         ? "Nome da função (`audita()`) ou a cláusula `EXECUTE FUNCTION …` inteira."
                         : "Um statement ou um bloco `BEGIN … END`. Use NEW.coluna / OLD.coluna.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Adicionar" : "Alterar") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty || events.isEmpty || triggerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        let spec = SchemaDDL.TriggerSpec(
            name: name, timing: timing,
            events: SchemaDDL.triggerEvents.filter { events.contains($0) },
            forEachRow: forEachRow, body: triggerBody
        )
        if let failure = await onSubmit(spec) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}

// MARK: - Info da tabela

struct TableInfoView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var info: TableInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carregando informações…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Não foi possível ler as informações", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(Array(info.facts.enumerated()), id: \.offset) { _, fact in
                                GridRow {
                                    Text(fact.label).foregroundStyle(.secondary)
                                    Text(fact.value).textSelection(.enabled)
                                }
                            }
                        }
                        HStack {
                            Text("DDL").font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(info.ddl, forType: .string)
                                copied = true
                                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                            } label: {
                                Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .controlSize(.small)
                        }
                        Text(AttributedString(SQLSyntaxHighlighter.attributed(info.ddl, fontSize: 12)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                    .padding(16)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await SchemaMetadata.tableInfo(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
