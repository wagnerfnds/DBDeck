import SwiftUI
import DBDeckCore

struct SQLConsoleView: View {
    let driver: any DatabaseDriver

    @State private var sql = ""
    @State private var result: QueryResult?
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var isShowingEditor = true

    private let cellWidth: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Consulta SQL")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation { isShowingEditor.toggle() }
                    } label: {
                        Image(systemName: isShowingEditor ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.borderless)
                }
                if isShowingEditor {
                    TextEditor(text: $sql)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if sql.isEmpty {
                                Text("SELECT * FROM minha_tabela LIMIT 100;")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 6)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                HStack {
                    Button {
                        Task { await run() }
                    } label: {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Executar", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if result != nil {
                        Button {
                            exportCSV()
                        } label: {
                            Label("Exportar CSV", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            if let errorMessage {
                HStack {
                    Text(errorMessage)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
            } else if let result {
                if result.columns.isEmpty {
                    Spacer()
                    Text("Comando executado sem resultado de linhas.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    readOnlyGrid(result)
                }
            } else {
                Spacer()
                ContentUnavailableView(
                    "Console SQL",
                    systemImage: "terminal",
                    description: Text("Escreva uma consulta e clique em Executar (⌘⏎).")
                )
                Spacer()
            }
        }
        .alert("Erro", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        result = nil
        message = nil
        defer { isRunning = false }
        do {
            let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if driver.isSelectStatement(statement) {
                result = try await driver.query(statement)
            } else {
                let affected = try await driver.execute(statement)
                message = "Comando executado. \(affected) linhas afetadas."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func readOnlyGrid(_ result: QueryResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(result.columns, id: \.self) { column in
                        Text(column)
                            .font(.caption.bold())
                            .frame(width: cellWidth, height: 28, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(Color.gray.opacity(0.1))
                    }
                }
                Divider()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(result.rows.indices, id: \.self) { rowIndex in
                        readonlyRow(result, rowIndex)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func readonlyRow(_ result: QueryResult, _ rowIndex: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(result.rows[rowIndex].indices, id: \.self) { columnIndex in
                readonlyCell(result, rowIndex, columnIndex)
            }
        }
        .background(rowIndex % 2 == 1 ? Color.gray.opacity(0.04) : Color.clear)
    }

    private func readonlyCell(_ result: QueryResult, _ rowIndex: Int, _ columnIndex: Int) -> some View {
        let value = result.rows[rowIndex][columnIndex]
        return Text(value.display)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(value == .null ? Color.secondary.opacity(0.5) : .primary)
            .frame(width: cellWidth, height: 24, alignment: .leading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .textSelection(.enabled)
    }

    private func exportCSV() {
        #if os(macOS)
        guard let result else { return }
        let csv = CSVExporter.export(result: result, fileName: "consulta")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "consulta.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }
}
