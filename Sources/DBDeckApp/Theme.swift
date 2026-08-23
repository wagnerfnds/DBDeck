import SwiftUI
import DBDeckCore

/// Tokens visuais compartilhados para dar coesão de produto à interface.
enum Theme {
    /// Linha compacta: cabem ~30% mais registros por tela sem perder legibilidade
    /// (o Sequel Ace usa 16 pt; 20 mantém a respiração do resto da interface).
    static let rowHeight: CGFloat = 20
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 6

    static let gridLine = Color.primary.opacity(0.06)
    static let headerBackground = Color.primary.opacity(0.04)
    static let zebra = Color.primary.opacity(0.025)
    static let selection = Color.accentColor.opacity(0.18)
    static let nullText = Color.secondary.opacity(0.55)
}

extension SQLEngine {
    /// Cor de marca por engine — usada em selos e ícones de conexão.
    var accent: Color {
        switch self {
        case .postgres: return Color(red: 0.20, green: 0.47, blue: 0.68) // azul Postgres
        case .mysql: return Color(red: 0.90, green: 0.55, blue: 0.13)     // laranja MySQL
        case .sqlite: return Color(red: 0.24, green: 0.56, blue: 0.36)    // verde SQLite
        }
    }

    var shortName: String {
        switch self {
        case .postgres: return "PG"
        case .mysql: return "SQL"
        case .sqlite: return "LITE"
        }
    }
}

/// Rótulos de cor para identificar conexões visualmente.
enum ConnectionColor {
    static let presets: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("green", .green), ("blue", .blue), ("purple", .purple),
        ("pink", .pink), ("gray", .gray)
    ]
    static func color(for name: String?) -> Color? {
        guard let name else { return nil }
        return presets.first { $0.name == name }?.color
    }
}

/// Selo colorido do engine (usado na sidebar e nas abas).
struct EngineBadge: View {
    let engine: SQLEngine
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(engine.accent.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: engine.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: engine.accent.opacity(0.35), radius: 1, y: 0.5)
    }
}
