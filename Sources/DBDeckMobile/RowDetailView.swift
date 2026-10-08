import SwiftUI
import DBDeckCore

struct FollowLink {
    var table: String
    var filter: TableLinkFilter
}

/// Uma linha inteira, um campo por linha — no telefone é assim que se lê e edita um
/// registro (o grid serve para varrer; o detalhe, para entender e alterar).
///
/// Edição é por linha: "Salvar" grava só os campos alterados com um UPDATE pela PK e
/// atualiza a linha no lugar. Sem o "alterações pendentes" do Mac — no toque, um
/// estado não salvo escondido atrás de uma folha fechada seria fácil de perder.
struct RowDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    let model: TableDataModel
    let target: RowDetailTarget
    var onFollowLink: (FollowLink) -> Void

    @State private var row: Int?
    @State private var draft: [SQLValue] = []
    @State private var baseline: [SQLValue] = []
    @State private var isSaving = false
    @State private var loadingFull = false
    @State private var confirmDelete = false
    @State private var highlighted: Int?
    @State private var viewing: ValueTarget?

    init(model: TableDataModel, target: RowDetailTarget, onFollowLink: @escaping (FollowLink) -> Void) {
        self.model = model
        self.target = target
        self.onFollowLink = onFollowLink
        _row = State(initialValue: target.row)
    }

    private var isNew: Bool { row == nil }
    private var editable: Bool { model.isEditable }
    private var hasChanges: Bool { draft != baseline }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if loadingFull {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Carregando valores completos…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                    if index < draft.count {
                        field(index: index, column: column)
                            .id(index)
                            .listRowBackground(highlighted == index ? Color.accentColor.opacity(0.10) : nil)
                    }
                }
                if !isNew && editable {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Excluir linha", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if let focus = target.focusColumn {
                    highlighted = focus
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(focus, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Nova linha" : "Linha \((row ?? 0) + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: row) { await prepare() }
        .navigationDestination(item: $viewing) { target in
            ValueViewer(
                title: target.column,
                text: target.text,
                editable: editable && target.editable,
                onCommit: { text in
                    if target.index < draft.count { draft[target.index] = .text(text) }
                }
            )
        }
        .confirmationDialog("Excluir esta linha?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                guard let row else { return }
                Task {
                    if await model.deleteRow(row) {
                        Haptics.success()
                        dismiss()
                    } else {
                        Haptics.error()
                    }
                }
            }
        } message: {
            Text("O DELETE executa imediatamente no servidor.")
        }
        .interactiveDismissDisabled(hasChanges)
    }

    // MARK: - Campo

    @ViewBuilder
    private func field(index: Int, column: DatabaseColumn) -> some View {
        let value = draft[index]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Text(column.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(column.type)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let key = model.linkColumns[index], value != .null, !value.isTruncated, !isNew {
                    Button {
                        onFollowLink(FollowLink(
                            table: key.referencedTable,
                            filter: TableLinkFilter(column: key.referencedColumns[0], value: value.display)
                        ))
                    } label: {
                        Label(key.referencedTable, systemImage: "arrow.up.forward.circle.fill")
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                }
                if editable && column.isNullable && !column.isPrimaryKey && value != .null {
                    Button("NULL") {
                        Haptics.tap()
                        draft[index] = .null
                    }
                    .font(.caption2.weight(.bold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Definir \(column.name) como NULL")
                }
            }
            editor(index: index, column: column, value: value)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                UIPasteboard.general.string = value.copyText
                Haptics.success()
            } label: { Label("Copiar valor", systemImage: "doc.on.doc") }
            Button {
                viewing = ValueTarget(index: index, column: column.name, text: value == .null ? "" : value.display, editable: !value.isTruncated)
            } label: { Label("Abrir em tela cheia", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
    }

    @ViewBuilder
    private func editor(index: Int, column: DatabaseColumn, value: SQLValue) -> some View {
        let isBool = column.type.lowercased().contains("bool") || column.type.lowercased() == "tinyint(1)"
        if case .blob(let data) = value {
            Chip(text: "BLOB · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))", systemImage: "shippingbox")
        } else if value.isTruncated {
            Text(value.display)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else if !editable {
            readOnlyValue(index: index, column: column, value: value)
        } else if isBool {
            Picker(column.name, selection: Binding(
                get: { boolState(value) },
                set: { draft[index] = $0 == "null" ? .null : .text($0) }
            )) {
                Text("true").tag("true")
                Text("false").tag("false")
                if column.isNullable { Text("NULL").tag("null") }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            HStack(alignment: .top, spacing: 6) {
                TextField(
                    value == .null ? (column.defaultValue.map { "default: \($0)" } ?? "NULL") : "",
                    text: Binding(
                        get: { value == .null ? "" : value.display },
                        set: { draft[index] = .text($0) }
                    ),
                    axis: .vertical
                )
                .font(.body.monospaced())
                .lineLimit(1...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(isNumeric(column) ? .numbersAndPunctuation : .default)
                if case .text(let text) = value, text.count > 120 || text.contains("\n") {
                    Button {
                        viewing = ValueTarget(index: index, column: column.name, text: text, editable: true)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Abrir em tela cheia")
                }
            }
        }
    }

    @ViewBuilder
    private func readOnlyValue(index: Int, column: DatabaseColumn, value: SQLValue) -> some View {
        if value == .null {
            Text("NULL").font(.body.monospaced().italic()).foregroundStyle(.tertiary)
        } else {
            let text = value.display
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if text.count > 120 || text.contains("\n") {
                        viewing = ValueTarget(index: index, column: column.name, text: text, editable: false)
                    }
                }
        }
    }

    private func isNumeric(_ column: DatabaseColumn) -> Bool {
        let type = column.type.lowercased()
        return ["int", "numeric", "decimal", "double", "real", "float"].contains { type.contains($0) }
    }

    private func boolState(_ value: SQLValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return number != 0 ? "true" : "false"
        case .text(let text): return ["true", "t", "1", "yes"].contains(text.lowercased()) ? "true" : "false"
        default: return "false"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(hasChanges ? "Descartar" : "Fechar") { dismiss() }
        }
        if editable {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(isNew ? "Inserir" : "Salvar").fontWeight(.semibold) }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        if !isNew {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    move(by: -1)
                } label: { Image(systemName: "chevron.up") }
                .disabled((row ?? 0) == 0 || hasChanges)
                .accessibilityLabel("Linha anterior")
                Button {
                    move(by: 1)
                } label: { Image(systemName: "chevron.down") }
                .disabled((row ?? 0) >= model.rows.count - 1 || hasChanges)
                .accessibilityLabel("Próxima linha")
                Spacer()
                Text(hasChanges ? "alterações não salvas" : "\((row ?? 0) + 1) de \(model.rows.count)")
                    .font(.caption)
                    .foregroundStyle(hasChanges ? .orange : .secondary)
                Spacer()
                Button {
                    guard let row else { return }
                    Task {
                        if let sql = await model.insertStatement(for: row) {
                            UIPasteboard.general.string = sql
                            Haptics.success()
                        }
                    }
                } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .accessibilityLabel("Copiar como INSERT")
            }
        }
    }

    // MARK: - Ações

    private func prepare() async {
        guard let row else {
            draft = Array(repeating: .null, count: model.columns.count)
            baseline = draft
            return
        }
        guard row < model.rows.count else { return }
        draft = model.rows[row]
        baseline = draft
        // Valores cortados/adiados viram íntegros antes de qualquer edição: gravar um
        // prefixo por cima do original seria perda de dado silenciosa.
        if model.columns.indices.contains(where: { model.needsFullValue(row: row, col: $0) }) {
            loadingFull = true
            await model.materializeRow(row)
            loadingFull = false
            guard row < model.rows.count, self.row == row else { return }
            draft = model.rows[row]
            baseline = draft
        }
    }

    private func move(by delta: Int) {
        guard let row else { return }
        let next = row + delta
        guard next >= 0, next < model.rows.count else { return }
        Haptics.selection()
        highlighted = nil
        self.row = next
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok: Bool
        if let row {
            ok = await model.saveRow(row, values: draft)
            if ok, row < model.rows.count {
                draft = model.rows[row]
                baseline = draft
            }
        } else {
            ok = await model.insertRow(values: draft)
        }
        if ok {
            Haptics.success()
            if isNew { dismiss() }
        } else {
            Haptics.error()
        }
    }
}

struct ValueTarget: Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var column: String
    var text: String
    var editable: Bool
}

/// Valor longo em tela cheia (JSON, textos, SQL guardado em coluna).
struct ValueViewer: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var text: String
    let editable: Bool
    var onCommit: (String) -> Void

    init(title: String, text: String, editable: Bool, onCommit: @escaping (String) -> Void) {
        self.title = title
        _text = State(initialValue: text)
        self.editable = editable
        self.onCommit = onCommit
    }

    private var prettyJSON: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8),
              string != text
        else { return nil }
        return string
    }

    var body: some View {
        Group {
            if editable {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    Text(text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let pretty = prettyJSON {
                    Button {
                        text = pretty
                    } label: { Label("Formatar JSON", systemImage: "curlybraces") }
                }
                Spacer()
                Text("\(text.count.formatted()) caracteres").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    Haptics.success()
                } label: { Label("Copiar", systemImage: "doc.on.doc") }
            }
            if editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onCommit(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
