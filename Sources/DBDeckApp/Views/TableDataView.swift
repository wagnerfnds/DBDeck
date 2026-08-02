import SwiftUI
import DBDeckCore

struct TableDataView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var columns: [DatabaseColumn] = []
    @State private var primaryKeys: [String] = []
    @State private var rows: [[SQLValue]] = []
    @State private var original: [[SQLValue]] = []
    @State private var offset = 0
    @State private var totalCount: Int?
    @State private var isNewRow = false
    @State private var selectedRow: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var notice: String?

    private let pageSize = 500
    private let cellWidth: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            if primaryKeys.isEmpty && !isLoading {
                HStack {
                    Label(
                        "Tabela sem chave primária — edição desabilitada (consulta e export continuam).",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }

            if rows.isEmpty && !isLoading {
                Spacer()
                ContentUnavailableView("Nenhum dado", systemImage: "tablecells", description: Text("Página vazia ou tabela sem registros."))
                Spacer()
            } else {
                grid
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    Task { await loadPage(offset: 0) }
                } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }

                Button {
                    startNewRow()
                } label: {
                    Label("Nova linha", systemImage: "plus")
                }
                .disabled(primaryKeys.isEmpty)

                Button {
                    Task { await saveChanges() }
                } label: {
                    Label("Salvar alterações", systemImage: "checkmark.circle")
                }
                .disabled(primaryKeys.isEmpty)

                Button {
                    Task { await deleteSelected() }
                } label: {
                    Label("Excluir linha", systemImage: "trash")
                }
                .disabled(selectedRow == nil || primaryKeys.isEmpty)

                Spacer()

                Button {
                    Task { await exportCSV() }
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                }

                HStack(spacing: 4) {
                    Button {
                        Task { await loadPage(offset: max(0, offset - pageSize)) }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(offset == 0)

                    Text("\(offset + 1)–\(offset + rows.count)\(totalCount.map { " de \($0)" } ?? "")")
                        .font(.caption)
                        .monospacedDigit()

                    Button {
                        Task { await loadPage(offset: offset + pageSize) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(rows.count < pageSize)
                }
            }
            .padding(8)
        }
        .task { await load() }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial)
                    .padding(8)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        self.notice = nil
                    }
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        rowView(rowIndex)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 24, height: 28)
            ForEach(columns, id: \.name) { column in
                Text(column.name)
                    .font(.caption.bold())
                    .frame(width: cellWidth, height: 28, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(Color.gray.opacity(0.1))
                    .help("\(column.name) — \(column.type)")
            }
        }
    }

    private func rowView(_ rowIndex: Int) -> some View {
        let isNew = isNewRow && rowIndex == rows.count - 1
        let isSelected = selectedRow == rowIndex
        return HStack(spacing: 0) {
            Image(systemName: isNew ? "sparkles" : "\(rowIndex + 1).circle")
                .font(.caption)
                .foregroundStyle(isNew ? Color.purple : .secondary)
                .frame(width: 24)
                .contentShape(Rectangle())
                .onTapGesture { selectedRow = rowIndex }
            ForEach(columns.indices, id: \.self) { columnIndex in
                cell(rowIndex, columnIndex)
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : (isNew ? Color.purple.opacity(0.06) : Color.clear))
    }

    private func cell(_ rowIndex: Int, _ columnIndex: Int) -> some View {
        let column = columns[columnIndex]
        let value = rows[rowIndex][columnIndex]
        return Group {
            if case .blob = value {
                Text("‹blob›")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if column.type.lowercased().contains("bool") {
                Toggle("", isOn: boolBinding(rowIndex, columnIndex))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                TextField("", text: textBinding(rowIndex, columnIndex))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .frame(width: cellWidth, height: 26, alignment: .leading)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectedRow = rowIndex }
    }

    private func textBinding(_ rowIndex: Int, _ columnIndex: Int) -> Binding<String> {
        Binding(
            get: { rows[rowIndex][columnIndex].display },
            set: { newValue in
                rows[rowIndex][columnIndex] = .text(newValue)
            }
        )
    }

    private func boolBinding(_ rowIndex: Int, _ columnIndex: Int) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value) = rows[rowIndex][columnIndex] {
                    return value
                }
                return rows[rowIndex][columnIndex].display == "true" || rows[rowIndex][columnIndex].display == "1"
            },
            set: { newValue in
                rows[rowIndex][columnIndex] = .bool(newValue)
            }
        )
    }

    // MARK: - Ações

    private func load() async {
        await loadPage(offset: 0)
        do {
            columns = try await driver.columns(table: table)
            primaryKeys = try await driver.primaryKeys(table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPage(offset: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await driver.fetchRows(table: table, limit: pageSize, offset: offset)
            rows = result.rows
            original = result.rows
            self.offset = offset
            isNewRow = false
            selectedRow = nil
            totalCount = try? await driver.countRows(table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startNewRow() {
        if isNewRow { return }
        rows.append(Array(repeating: .null, count: columns.count))
        isNewRow = true
        selectedRow = rows.count - 1
    }

    private func saveChanges() async {
        do {
            var updated = 0
            var inserted = 0
            var deleted = 0
            var problems: [String] = []

            let dataRowsCount = isNewRow ? rows.count - 1 : rows.count
            for i in 0..<dataRowsCount where i < original.count {
                var changes: [(column: String, value: SQLValue)] = []
                for (j, column) in columns.enumerated() {
                    let newValue = i < rows.count ? rows[i][j] : .null
                    let oldValue = i < original.count ? original[i][j] : .null
                    if newValue != oldValue {
                        changes.append((column.name, normalize(newValue, column: column)))
                    }
                }
                if !changes.isEmpty {
                    let pkValues = primaryKeys.map { key in
                        let index = columns.firstIndex { $0.name == key } ?? 0
                        return i < original.count ? original[i][index] : .null
                    }
                    if pkValues.contains(.null) {
                        problems.append("Linha \(i + 1): chave primária nula — não foi possível atualizar.")
                    } else {
                        updated += try await driver.updateRow(
                            table: table,
                            primaryKey: primaryKeys,
                            pkValues: pkValues,
                            changes: changes
                        )
                    }
                }
            }

            if isNewRow, let newIndex = rows.indices.last {
                var values: [(column: String, value: SQLValue)] = []
                for (j, column) in columns.enumerated() {
                    let value = rows[newIndex][j]
                    if case .null = value { continue }
                    values.append((column.name, normalize(value, column: column)))
                }
                if !values.isEmpty {
                    inserted += try await driver.insertRow(table: table, values: values)
                }
            }

            for (i, row) in original.enumerated() {
                let pkValues = primaryKeys.map { key in
                    let index = columns.firstIndex { $0.name == key } ?? 0
                    return row[index]
                }
                if pkValues.contains(.null) { continue }
                let isGone = rows.count < original.count
                if isGone && i >= rows.count - (isNewRow ? 1 : 0) {
                    deleted += try await driver.deleteRow(table: table, primaryKey: primaryKeys, pkValues: pkValues)
                }
            }

            await loadPage(offset: self.offset)
            notice = "Salvo: \(updated) atualizados, \(inserted) inseridos, \(deleted) excluídos"
            if !problems.isEmpty {
                errorMessage = problems.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let selectedRow, selectedRow < original.count else {
            if let selectedRow, isNewRow, selectedRow == rows.count - 1 {
                rows.removeLast()
                isNewRow = false
                self.selectedRow = nil
            }
            return
        }
        let pkValues = primaryKeys.map { key in
            let index = columns.firstIndex { $0.name == key } ?? 0
            return original[selectedRow][index]
        }
        guard !pkValues.contains(.null) else {
            errorMessage = "Não é possível excluir: chave primária nula."
            return
        }
        do {
            _ = try await driver.deleteRow(table: table, primaryKey: primaryKeys, pkValues: pkValues)
            await loadPage(offset: self.offset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalize(_ value: SQLValue, column: DatabaseColumn) -> SQLValue {
        guard case .text(let text) = value else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return column.isNullable ? .null : .text("")
        }
        let type = column.type.lowercased()
        if type.contains("bool") {
            switch trimmed.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: return .text(trimmed)
            }
        }
        if type.contains("int") {
            if let value = Int64(trimmed) { return .int(value) }
        } else if type.contains("double") || type.contains("real") || type.contains("float") || type.contains("numeric") || type.contains("decimal") {
            if let value = Double(trimmed) { return .double(value) }
        }
        return .text(trimmed)
    }

    private func exportCSV() async {
        #if os(macOS)
        let result = QueryResult(
            columns: columns.map(\.name),
            rows: isNewRow ? Array(rows.dropLast()) : rows
        )
        let csv = CSVExporter.export(result: result, fileName: table)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            notice = "CSV salvo"
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }
}
