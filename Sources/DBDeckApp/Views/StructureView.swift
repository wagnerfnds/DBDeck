import SwiftUI
import DBDeckCore

struct StructureView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var columns: [DatabaseColumn] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: String?

    @State private var showingAddSheet = false
    @State private var editingColumn: DatabaseColumn?
    @State private var deletingColumn: DatabaseColumn?

    private let wIdx: CGFloat = 46
    private let wName: CGFloat = 260
    private let wType: CGFloat = 200
    private let wPK: CGFloat = 50
    private let wNull: CGFloat = 90
    private let wDefault: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Carregando estrutura…")
                Spacer()
            } else if columns.isEmpty {
                Spacer()
                ContentUnavailableView("Sem colunas", systemImage: "list.bullet.rectangle")
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
            ColumnFormSheet(engine: driver.engine, table: table, original: nil) { spec in
                await apply(spec, original: nil)
            }
        }
        .sheet(item: $editingColumn) { column in
            ColumnFormSheet(engine: driver.engine, table: table, original: column) { spec in
                await apply(spec, original: column)
            }
        }
        .confirmationDialog(
            "Remover a coluna “\(deletingColumn?.name ?? "")”?",
            isPresented: .init(get: { deletingColumn != nil }, set: { if !$0 { deletingColumn = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover coluna", role: .destructive) {
                if let column = deletingColumn { Task { await dropColumn(column) } }
                deletingColumn = nil
            }
            Button("Cancelar", role: .cancel) { deletingColumn = nil }
        } message: {
            Text("Os dados desta coluna serão perdidos — o ALTER TABLE executa imediatamente.")
        }
        .overlay(alignment: .bottomTrailing) { noticeToast }
    }

    private var totalWidth: CGFloat { wIdx + wName + wType + wPK + wNull + wDefault }

    private var grid: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            row(index: index, column: column)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { editingColumn = column }
                                .contextMenu {
                                    Button("Alterar coluna…") { editingColumn = column }
                                    Divider()
                                    Button("Remover coluna…", role: .destructive) { deletingColumn = column }
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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                showingAddSheet = true
            } label: {
                Label("Adicionar coluna", systemImage: "plus")
            }
            .controlSize(.small)

            Text("duplo clique ou botão direito numa coluna para alterar/remover")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(columns.count) colunas")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell("#", width: wIdx)
            headerCell("Coluna", width: wName)
            headerCell("Tipo", width: wType)
            headerCell("PK", width: wPK)
            headerCell("Nulo?", width: wNull)
            headerCell("Default", width: wDefault, last: true)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gridLine).frame(height: 1) }
    }

    private func headerCell(_ title: String, width: CGFloat, last: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, height: Theme.headerHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Theme.headerBackground)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.gridLine).frame(width: 1) } }
    }

    private func row(index: Int, column: DatabaseColumn) -> some View {
        HStack(spacing: 0) {
            cell(Text("\(column.ordinal)").foregroundStyle(.tertiary), width: wIdx)
            cell(
                HStack(spacing: 5) {
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                    Text(column.name).fontWeight(.medium)
                },
                width: wName
            )
            cell(Text(column.type).foregroundStyle(.secondary), width: wType)
            cell(column.isPrimaryKey ? AnyView(Image(systemName: "checkmark").foregroundStyle(.green)) : AnyView(Text("")), width: wPK)
            cell(Text(column.isNullable ? "sim" : "não").foregroundStyle(column.isNullable ? .secondary : .primary), width: wNull)
            cell(
                Text(column.defaultValue ?? "NULL")
                    .foregroundStyle(column.defaultValue == nil ? Theme.nullText : .secondary)
                    .italic(column.defaultValue == nil),
                width: wDefault, last: true
            )
        }
        .background(index % 2 == 1 ? Theme.zebra : Color.clear)
    }

    private func cell(_ content: some View, width: CGFloat, last: Bool = false) -> some View {
        content
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .frame(width: width, height: Theme.rowHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.gridLine).frame(width: 1) } }
    }

    private var noticeToast: some View {
        Group {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .padding(12)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.notice = nil }
                    }
            }
        }
    }

    // MARK: - Ações

    private func reload() async {
        do { columns = try await driver.columns(table: table) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    /// Executa os ALTERs de criação/alteração. Devolve mensagem de erro (o sheet mostra) ou nil.
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
                // Sem transação: statements anteriores já valeram. Recarrega para o grid
                // refletir o estado real e avisa que a alteração pode ter sido parcial.
                await reload()
                let partial = executed > 0 ? "\n(Atenção: \(executed) alteração(ões) já aplicadas — feche o formulário e confira o estado atual.)" : ""
                return error.localizedDescription + partial
            }
            await reload()
            withAnimation { notice = original == nil ? "Coluna adicionada" : "Coluna alterada" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func dropColumn(_ column: DatabaseColumn) async {
        do {
            _ = try await driver.execute(SchemaDDL.dropColumn(engine: driver.engine, table: table, column: column.name))
            await reload()
            withAnimation { notice = "Coluna removida" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sheet de coluna (nova ou alteração)

private struct ColumnFormSheet: View {
    let engine: SQLEngine
    let table: String
    /// nil = nova coluna.
    let original: DatabaseColumn?
    /// Executa os ALTERs; devolve mensagem de erro ou nil em caso de sucesso.
    let onSubmit: (SchemaDDL.ColumnSpec) async -> String?

    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Nova coluna em “\(table)”" : "Alterar coluna “\(original?.name ?? "")”")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Nome")
                    TextField("nome_da_coluna", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Tipo")
                    HStack(spacing: 6) {
                        TextField(engine == .postgres ? "ex.: varchar(255), integer" : "ex.: varchar(255), int", text: $type)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(typeSuggestions, id: \.self) { suggestion in
                                Button(suggestion) { type = suggestion }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Default")
                    TextField("expressão SQL — ex.: 0, 'texto', CURRENT_TIMESTAMP", text: $defaultExpression)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("")
                    Toggle("Permite NULL", isOn: $nullable)
                }
            }

            if engine == .mysql, original != nil {
                Text("MySQL: alterar tipo/nulo/default reescreve a definição da coluna (MODIFY) — atributos extras como AUTO_INCREMENT precisam constar no tipo.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if engine == .sqlite, original != nil {
                Text("SQLite só permite renomear colunas — tipo, nulidade e default não podem mudar.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Adicionar" : "Salvar") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty || (typeRequired && type.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    /// SQLite aceita colunas sem tipo declarado (e o rename — único alter suportado —
    /// precisa funcionar nelas); nos demais engines o tipo é obrigatório.
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

    private func submit() {
        let spec = SchemaDDL.ColumnSpec(
            name: name.trimmingCharacters(in: .whitespaces),
            type: type.trimmingCharacters(in: .whitespaces),
            isNullable: nullable,
            defaultExpression: defaultExpression.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : defaultExpression.trimmingCharacters(in: .whitespaces)
        )
        isSaving = true
        Task {
            let error = await onSubmit(spec)
            isSaving = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }
}
