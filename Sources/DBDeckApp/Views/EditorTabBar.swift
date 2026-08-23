import SwiftUI
import DBDeckCore

/// Barra de abas horizontal estilo TablePlus: pílulas com ícone, título e botão de fechar.
struct EditorTabBar: View {
    let session: ConnectionSession
    var onNewQuery: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.tabs) { tab in
                        TabPill(
                            tab: tab,
                            isSelected: tab.id == session.selectedTabID,
                            isSplit: tab.id == session.splitTabID,
                            onSelect: { session.select(tab) },
                            onClose: { session.close(tab) }
                        )
                        .contextMenu {
                            Button("Abrir ao lado") { session.openBeside(tab) }
                            if tab.id == session.splitTabID {
                                Button("Remover do lado") { session.closeSplit() }
                            }
                            Divider()
                            Button("Fechar aba") { session.close(tab) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider().frame(height: 22)

            Button(action: onNewQuery) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Nova consulta SQL (⌘T)")
        }
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabPill: View {
    let tab: EditorTab
    let isSelected: Bool
    var isSplit: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            if isSplit {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            // Botão de fechar aparece no hover ou quando selecionada.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.primary.opacity(0.12) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .frame(maxWidth: 200)
    }
}
