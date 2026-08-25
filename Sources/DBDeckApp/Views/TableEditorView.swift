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
        case relations = "Relações"
        case triggers = "Triggers"
        case info = "Info"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .data: return "tablecells"
            case .structure: return "list.bullet.rectangle"
            case .relations: return "arrow.left.arrow.right"
            case .triggers: return "bolt"
            case .info: return "info.circle"
            }
        }
    }

    @Environment(AppState.self) private var state
    @State private var section: Section = .data
    /// Segmentos de metadados só nascem na primeira visita: cada um é uma consulta de
    /// catálogo, e abrir uma tabela não pode custar quatro.
    @State private var visited: Set<Section> = [.data, .structure]

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
                if visited.contains(.relations) {
                    RelationsView(driver: driver, table: table) { other in
                        session?.openTable(other, newTab: true)
                    }
                    .opacity(section == .relations ? 1 : 0)
                    .allowsHitTesting(section == .relations)
                }
                if visited.contains(.triggers) {
                    TriggersView(driver: driver, table: table)
                        .opacity(section == .triggers ? 1 : 0)
                        .allowsHitTesting(section == .triggers)
                }
                if visited.contains(.info) {
                    TableInfoView(driver: driver, table: table)
                        .opacity(section == .info ? 1 : 0)
                        .allowsHitTesting(section == .info)
                }
            }
        }
        .onChange(of: section) { _, new in visited.insert(new) }
    }

    private var session: ConnectionSession? {
        state.selectedConnectionID.map { state.session(for: $0) }
    }
}
