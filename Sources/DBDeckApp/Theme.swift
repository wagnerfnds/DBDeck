import SwiftUI
import DBDeckCore
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// Tokens visuais compartilhados para dar coesão de produto à interface.
enum Theme {
    /// Linha compacta: cabem ~30% mais registros por tela sem perder legibilidade
    /// (o Sequel Ace usa 16 pt; 20 mantém a respiração do resto da interface).
    #if os(macOS)
    static let rowHeight: CGFloat = 20
    static let rowHeightNormal: CGFloat = 24
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 6
    #else
    /// No toque a linha precisa de alvo: 34 pt ainda mostra ~20 registros num iPhone, e
    /// o "normal" é o 44 pt das diretrizes de interface do iOS.
    static let rowHeight: CGFloat = 34
    static let rowHeightNormal: CGFloat = 44
    static let headerHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 10
    #endif

    static let gridLine = Color.primary.opacity(0.06)
    static let headerBackground = Color.primary.opacity(0.04)
    static let zebra = Color.primary.opacity(0.025)
    static let selection = Color.accentColor.opacity(0.18)
    static let nullText = Color.secondary.opacity(0.55)

    // MARK: Código

    /// Cores de sintaxe do editor SQL e da biblioteca de consultas. Cores de sistema
    /// para acompanharem claro/escuro e o realce de acessibilidade sem trabalho nosso.
    static let syntaxKeyword = PlatformColor.systemPurple
    static let syntaxString = PlatformColor.systemRed
    static let syntaxNumber = PlatformColor.systemBlue
    #if os(macOS)
    static let syntaxPlain = NSColor.labelColor
    static let syntaxComment = NSColor.secondaryLabelColor
    /// Fundo do comando sob o cursor — é o que o ⌘⇧⏎ vai executar.
    static let statementBackground = NSColor.controlAccentColor.withAlphaComponent(0.07)
    /// Linha do cursor, no gutter.
    static let currentLineBackground = NSColor.labelColor.withAlphaComponent(0.05)
    static let gutterText = NSColor.tertiaryLabelColor
    static let gutterCurrentLineText = NSColor.labelColor
    #else
    static let syntaxPlain = UIColor.label
    static let syntaxComment = UIColor.secondaryLabel
    static let statementBackground = UIColor.tintColor.withAlphaComponent(0.07)
    static let currentLineBackground = UIColor.label.withAlphaComponent(0.05)
    static let gutterText = UIColor.tertiaryLabel
    static let gutterCurrentLineText = UIColor.label
    #endif

    static func codeFont(size: CGFloat) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func codeFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
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
