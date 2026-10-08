import SwiftUI
import DBDeckCore

/// Colunas (com adicionar/alterar/remover), relações e triggers da tabela.
struct StructurePane: View {
    @Environment(Navigator.self) private var navigator
    let driver: any DatabaseDriver
    let table: String
    /// A estrutura mudou: a aba de dados precisa reler colunas.
    var onChange: () -> Void

    @State private var columns: [DatabaseColumn] = []
    @State private var foreignKeys: [ForeignKey] = []
    @State private var referencing: [ForeignKey] = []
    @State private var triggers: [TableTrigger] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var editing: ColumnFormTarget?
    @State private var dropping: DatabaseColumn?

    var body: some View {
        List {
            Section {
                ForEach(columns) { column in
                    ColumnRow(column: column)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = ColumnFormTarget(original: column) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { dropping = column } label: {
                                Label("Remover", systemImage: "trash")
                            }
                            Button { editing = ColumnFormTarget(original: column) } label: {
                                Label("Alterar", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button { editing = ColumnFormTarget(original: column) } label: {
                                Label("Alterar coluna", systemImage: "pencil")
                            }
                            Button {
                                UIPasteboard.general.string = column.name
                            } label: { Label("Copiar nome", systemImage: "doc.on.doc") }
                            Divider()
                            Button(role: .destructive) { dropping = column } label: {
                                Label("Remover coluna", systemImage: "trash")
                            }
                        }
                }
                Button {
                    editing = ColumnFormTarget(original: nil)
                } label: {
                    Label("Adicionar coluna", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("\(columns.count) colunas")
            }

            if !foreignKeys.isEmpty {
                Section("Referencia") {
                    ForEach(foreignKeys) { key in
                        relationRow(key, from: key.columns, target: key.referencedTable, to: key.referencedColumns)
                    }
                }
            }
            if !referencing.isEmpty {
                Section("Referenciada por") {
                    ForEach(referencing) { key in
                        relationRow(key, from: key.referencedColumns, target: key.table, to: key.columns)
                    }
                }
            }
            if !triggers.isEmpty {
                Section("Triggers") {
                    ForEach(triggers) { trigger in
                        DisclosureGroup {
                            Text(trigger.body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trigger.name).font(.body.monospaced())
                                Text("\(trigger.timing) \(trigger.event)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if isLoading && columns.isEmpty { ProgressView() } }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $editing) { target in
            NavigationStack {
                ColumnFormView(engine: driver.engine, table: table, original: target.original) { spec in
                    await apply(spec, original: target.original)
                }
            }
        }
        .confirmationDialog(
            "Remover a coluna “\(dropping?.name ?? "")”?",
            isPresented: .init(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover coluna", role: .destructive) {
                if let column = dropping { Task { await drop(column) } }
                dropping = nil
            }
        } message: {
            Text("Os dados desta coluna serão perdidos — o ALTER TABLE executa imediatamente.")
        }
        .errorAlert($errorMessage)
        .toast($notice)
    }

    private func relationRow(_ key: ForeignKey, from: [String], target: String, to: [String]) -> some View {
        Button {
            navigator.open(table: target)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(from.joined(separator: ", ")) → \(target)(\(to.joined(separator: ", ")))")
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                    Text("\(key.name) · ON DELETE \(key.onDelete) · ON UPDATE \(key.onUpdate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            columns = try await driver.columns(table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
        foreignKeys = (try? await SchemaMetadata.foreignKeys(driver: driver, table: table)) ?? []
        referencing = (try? await SchemaMetadata.referencingKeys(driver: driver, table: table)) ?? []
        triggers = (try? await SchemaMetadata.triggers(driver: driver, table: table)) ?? []
    }

    private func apply(_ spec: SchemaDDL.ColumnSpec, original: DatabaseColumn?) async -> String? {
        do {
            let statements: [String]
            if let original {
                statements = try SchemaDDL.alterColumn(engine: driver.engine, table: table, original: original, edited: spec)
            } else {
                statements = [SchemaDDL.addColumn(engine: driver.engine, table: table, column: spec)]
            }
            guard !statements.isEmpty else { return nil }
            var executed = 0
            do {
                for sql in statements {
                    _ = try await driver.execute(sql)
                    executed += 1
                }
            } catch {
                await reload()
                onChange()
                let partial = executed > 0 ? "\n(Atenção: \(executed) alteração(ões) já aplicadas.)" : ""
                return error.localizedDescription + partial
            }
            await reload()
            onChange()
            notice = original == nil ? "Coluna adicionada" : "Coluna alterada"
            Haptics.success()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func drop(_ column: DatabaseColumn) async {
        do {
            _ = try await driver.execute(SchemaDDL.dropColumn(engine: driver.engine, table: table, column: column.name))
            await reload()
            onChange()
            notice = "Coluna removida"
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

private struct ColumnRow: View {
    let column: DatabaseColumn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(column.ordinal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(column.name).font(.body.monospaced().weight(.medium))
                }
                HStack(spacing: 6) {
                    Text(column.type)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if !column.isNullable {
                        Text("NOT NULL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    if column.isGenerated {
                        Text("GERADA")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.purple)
                    }
                }
                if let defaultValue = column.defaultValue {
                    Text("default \(defaultValue)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ColumnFormTarget: Identifiable {
    var id: String { original?.name ?? "new" }
    var original: DatabaseColumn?
}

/// Nova coluna ou alteração de uma existente.
struct ColumnFormView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SQLEngine
    let table: String
    let original: DatabaseColumn?
    let onSubmit: (SchemaDDL.ColumnSpec) async -> String?

    @State private var name: String
    @State private var type: String
    @State private var nullable: Bool
    @State private var defaultExpression: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(engine: SQLEngine, table: String, original: DatabaseColumn?, onSubmit: @escaping (SchemaDDL.ColumnSpec) async -> String?) {
        self.engine = engine
        self.table = table
        self.original = original
        self.onSubmit = onSubmit
        _name = State(initialValue: original?.name ?? "")
        _type = State(initialValue: original?.type ?? "")
        _nullable = State(initialValue: original?.isNullable ?? true)
        _defaultExpression = State(initialValue: original?.defaultValue ?? "")
    }

    private var typeRequired: Bool { engine != .sqlite }

    private var typeSuggestions: [String] {
        switch engine {
        case .postgres:
            return ["text", "varchar(255)", "integer", "bigint", "boolean", "numeric(12,2)", "double precision", "timestamptz", "date", "jsonb", "uuid"]
        case .mysql:
            return ["varchar(255)", "text", "int", "bigint", "tinyint(1)", "decimal(12,2)", "double", "datetime", "date", "json"]
        case .sqlite:
            return ["TEXT", "INTEGER", "REAL", "NUMERIC", "BLOB"]
        }
    }

    var body: some View {
        Form {
            Section("Coluna") {
                TextField("nome_da_coluna", text: $name)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("tipo", text: $type)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(typeSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                Haptics.selection()
                                type = suggestion
                            }
                            .font(.caption.monospaced())
                            .buttonStyle(.bordered)
                            .tint(type == suggestion ? .accentColor : .secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            Section {
                TextField("expressão SQL", text: $defaultExpression)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Permite NULL", isOn: $nullable)
            } header: {
                Text("Default e nulidade")
            } footer: {
                if engine == .mysql, original != nil {
                    Text("MySQL: a alteração reescreve a definição (MODIFY) — atributos como AUTO_INCREMENT precisam constar no tipo.")
                } else if engine == .sqlite, original != nil {
                    Text("SQLite só permite renomear colunas — tipo, nulidade e default não podem mudar.")
                } else {
                    Text("Ex.: 0, 'texto', CURRENT_TIMESTAMP")
                }
            }
            if let errorMessage {
                Section {
                    Label {
                        Text(errorMessage).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(original == nil ? "Nova coluna" : "Alterar \(original?.name ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    submit()
                } label: {
                    if isSaving { ProgressView() } else { Text(original == nil ? "Adicionar" : "Salvar").fontWeight(.semibold) }
                }
                .disabled(isSaving
                    || name.trimmingCharacters(in: .whitespaces).isEmpty
                    || (typeRequired && type.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    private func submit() {
        let trimmedDefault = defaultExpression.trimmingCharacters(in: .whitespaces)
        let spec = SchemaDDL.ColumnSpec(
            name: name.trimmingCharacters(in: .whitespaces),
            type: type.trimmingCharacters(in: .whitespaces),
            isNullable: nullable,
            defaultExpression: trimmedDefault.isEmpty ? nil : trimmedDefault
        )
        isSaving = true
        Task {
            let error = await onSubmit(spec)
            isSaving = false
            if let error {
                errorMessage = error
                Haptics.error()
            } else {
                dismiss()
            }
        }
    }
}

// MARK: - Info

struct TableInfoPane: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var info: TableInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var sharedFile: SharedFile?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Sem informações", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let info {
                List {
                    Section {
                        ForEach(Array(info.facts.enumerated()), id: \.offset) { _, fact in
                            LabeledContent(fact.label) {
                                Text(fact.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Section {
                        // Formatado para leitura: no telefone, uma linha de 400 colunas
                        // rolando de lado é ilegível. Copiar/compartilhar levam o original.
                        Text(AttributedString(SQLSyntaxHighlighter.attributed(SQLFormatter.format(info.ddl), fontSize: 12)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } header: {
                        HStack {
                            Text("DDL")
                            Spacer()
                            Button {
                                UIPasteboard.general.string = info.ddl
                                notice = "DDL copiado"
                                Haptics.success()
                            } label: { Label("Copiar", systemImage: "doc.on.doc") }
                            .font(.caption)
                            Button {
                                let url = ExportFiles.temporaryURL(named: "\(table)-ddl", ext: "sql")
                                try? info.ddl.write(to: url, atomically: true, encoding: .utf8)
                                sharedFile = SharedFile(url: url)
                            } label: { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                            .font(.caption)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .task { await load() }
        .toast($notice)
        .shareSheet($sharedFile)
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
