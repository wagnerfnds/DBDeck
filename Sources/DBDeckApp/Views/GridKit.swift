import SwiftUI
import DBDeckCore

/// Constantes de largura compartilhadas do grid (usadas pelo DataGridView nativo).
enum GridStyle {
    static let defaultWidth: CGFloat = 160
    static let minWidth: CGFloat = 56
    static let maxWidth: CGFloat = 640
    static let indexWidth: CGFloat = 40
    /// Teto ao qual as colunas largas são espremidas quando a página não cabe na janela
    /// (o `SP_MAX_CELL_WIDTH_MULTICOLUMN` do Sequel Ace): numa tabela larga vale mais ver
    /// 20 colunas estreitas do que 6 largas. Não é limite de resize manual.
    static let preferredMaxWidth: CGFloat = 200
}

/// Painel lateral que mostra todos os campos da linha selecionada, um por linha (bom para tabelas largas).
struct RowInspector: View {
    let columns: [DatabaseColumn]
    let title: String
    let values: Binding<[SQLValue]>?
    var editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.headerHeight)
            .background(Theme.headerBackground)

            Divider()

            if let values {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(columns.indices, id: \.self) { index in
                            fieldRow(index, values: values)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Selecione uma linha")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func fieldRow(_ index: Int, values: Binding<[SQLValue]>) -> some View {
        // Guarda de bounds: após um ALTER TABLE na aba Estrutura, a linha selecionada
        // pode ter menos valores que `columns` — indexar direto seria crash.
        if index < values.wrappedValue.count {
            boundedFieldRow(index, values: values)
        }
    }

    @ViewBuilder
    private func boundedFieldRow(_ index: Int, values: Binding<[SQLValue]>) -> some View {
        let column = columns[index]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                }
                Text(column.name)
                    .font(.system(size: 11, weight: .semibold))
                Text(column.type)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if editable {
                    Button {
                        if index < values.wrappedValue.count {
                            values.wrappedValue[index] = .null
                        }
                    } label: {
                        Text("NULL").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Definir como NULL")
                }
            }

            let value = values.wrappedValue[index]
            if case .blob = value {
                Text("BLOB").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            } else if value.isTruncated {
                // Prefixo: nunca editável aqui. Gravar o que está na tela sobrescreveria
                // o valor do servidor por uma versão cortada — a edição do valor íntegro
                // acontece na célula do grid, que sabe recarregá-lo antes.
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.display)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("valor grande — abra a célula no grid para editar")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else if editable {
                TextField("", text: fieldBinding(values, index), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...6)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .topLeading) {
                        if case .null = value {
                            Text("NULL").font(.system(size: 11, design: .monospaced)).italic()
                                .foregroundStyle(Theme.nullText)
                                .padding(.horizontal, 10).padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text(value == .null ? "NULL" : value.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(value == .null ? Theme.nullText : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func fieldBinding(_ values: Binding<[SQLValue]>, _ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard index < values.wrappedValue.count else { return "" }
                if case .null = values.wrappedValue[index] { return "" }
                return values.wrappedValue[index].display
            },
            set: {
                guard index < values.wrappedValue.count else { return }
                values.wrappedValue[index] = .text($0)
            }
        )
    }
}
