import SwiftUI
import DBDeckCore

/// Filtros de conteúdo da tabela: linhas de coluna + operador + valor, combinadas com AND.
struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TableDataModel
    @FocusState private var focusedValue: UUID?

    var body: some View {
        Form {
            ForEach($model.filters) { $filter in
                Section {
                    Picker("Coluna", selection: $filter.column) {
                        ForEach(model.columns) { column in
                            HStack {
                                Text(column.name)
                                Text(column.type).foregroundStyle(.secondary)
                            }
                            .tag(column.name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Operador", selection: $filter.op) {
                        ForEach(RowFilterOperator.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if filter.op.needsValue {
                        TextField("valor", text: $filter.value)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedValue, equals: filter.id)
                            .submitLabel(.search)
                            .onSubmit { apply() }
                    }
                    Toggle("Ativo", isOn: $filter.enabled)
                } header: {
                    HStack {
                        Text(index(of: filter) == 0 ? "Filtro" : "E também")
                        Spacer()
                        if model.filters.count > 1 {
                            Button(role: .destructive) {
                                withAnimation { model.filters.removeAll { $0.id == filter.id } }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .accessibilityLabel("Remover filtro")
                        }
                    }
                }
            }

            Section {
                Button {
                    withAnimation {
                        let filter = model.newFilterRow()
                        model.filters.append(filter)
                        focusedValue = filter.id
                    }
                } label: {
                    Label("Adicionar condição", systemImage: "plus.circle")
                }
            } footer: {
                Text("“contém”, “começa com” e “termina com” tratam % e _ literalmente.")
            }
        }
        .navigationTitle("Filtros")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Limpar") {
                    Task { await model.clearFilters() }
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Filtrar") { apply() }
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            if model.filters.isEmpty { model.filters = [model.newFilterRow()] }
            if let first = model.filters.first(where: { $0.op.needsValue && $0.value.isEmpty }) {
                focusedValue = first.id
            }
        }
    }

    private func index(of filter: RowFilter) -> Int {
        model.filters.firstIndex { $0.id == filter.id } ?? 0
    }

    private func apply() {
        Haptics.tap()
        Task { await model.applyFilters() }
        dismiss()
    }
}
