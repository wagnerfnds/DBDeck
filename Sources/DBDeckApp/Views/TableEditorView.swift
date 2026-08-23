import SwiftUI
import DBDeckCore

/// Conteúdo de uma aba de tabela: alterna entre Dados e Estrutura com um segmented control.
struct TableEditorView: View {
    let driver: any DatabaseDriver
    let tab: EditorTab
    let table: String
    /// Só a aba visível/selecionada registra atalhos (⌘S) — ver EditorArea.tabContent.
    var isActive: Bool = true

    enum Section: String, CaseIterable, Identifiable {
        case data = "Dados"
        case structure = "Estrutura"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .data: return "tablecells"
            case .structure: return "list.bullet.rectangle"
            }
        }
    }

    @State private var section: Section = .data

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)

            Divider()

            // ZStack com opacidade (mesmo padrão das abas do editor): alternar o segmento
            // não pode destruir o estado do grid — um switch recriava a TableDataView e
            // descartava edições não salvas, filtro, ordenação e página.
            ZStack {
                // ⌘S só vale com a aba selecionada E o segmento Dados visível — na
                // Estrutura o botão Salvar está oculto e o atalho não deve disparar.
                TableDataView(driver: driver, table: table, tab: tab, isActive: isActive && section == .data)
                    .opacity(section == .data ? 1 : 0)
                    .allowsHitTesting(section == .data)
                StructureView(driver: driver, table: table)
                    .opacity(section == .structure ? 1 : 0)
                    .allowsHitTesting(section == .structure)
            }
        }
    }
}
