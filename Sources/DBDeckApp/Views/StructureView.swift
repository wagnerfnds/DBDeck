import SwiftUI
import DBDeckCore

struct StructureView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var columns: [DatabaseColumn] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Carregando estrutura…")
                Spacer()
            } else if columns.isEmpty {
                ContentUnavailableView("Sem colunas", systemImage: "list.bullet.rectangle")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("#").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Coluna").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Tipo").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("PK").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Nullable").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Default").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(columns) { column in
                        GridRow {
                            Text("\(column.ordinal)").font(.caption).foregroundStyle(.secondary)
                            Text(column.name).font(.system(.body, design: .monospaced))
                            Text(column.type).font(.system(.body, design: .monospaced))
                            Text(column.isPrimaryKey ? "✓" : "")
                            Text(column.isNullable ? "sim" : "não").font(.caption)
                            Text(column.defaultValue ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(table)
        .task {
            do {
                columns = try await driver.columns(table: table)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
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
}
