import AppKit
import Foundation
import Observation
import DBDeckCore

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Escuro"
        }
    }
}

enum RowDensity: String, CaseIterable, Identifiable {
    case compact, normal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "Compacta"
        case .normal: "Normal"
        }
    }

    /// 20 pt é o compacto do projeto (ver `Theme.rowHeight`); 24 é a altura padrão do AppKit.
    var height: CGFloat {
        switch self {
        case .compact: Theme.rowHeight
        case .normal: 24
        }
    }
}

enum TabWidth: Int, CaseIterable, Identifiable {
    case two = 2, four = 4
    var id: Int { rawValue }
}

/// Preferências do app, persistidas em UserDefaults.
///
/// É uma classe observável, e não `@AppStorage` espalhado pelas views, porque quem consome
/// as preferências são sobretudo `NSViewRepresentable` (editor, grid) e classes fora de
/// View (`ConnectionSession`, `AppState`) — `@AppStorage` só vive em View e re-renderiza a
/// cada tecla. Com `@Observable`, cada view acompanha só a propriedade que lê.
///
/// Cada propriedade grava no `didSet`; o `init` lê tudo com fallback nos padrões.
@MainActor
@Observable
final class AppSettings {
    enum Key: String, CaseIterable {
        case editorFontSize = "editor.fontSize"
        case tabWidth = "editor.tabWidth"
        case autoCompletion = "editor.autoCompletion"
        case highlightStatement = "editor.highlightStatement"
        case formatUppercase = "editor.formatUppercase"
        case pageSize = "grid.pageSize"
        case rowDensity = "grid.rowDensity"
        case previewLimit = "grid.previewLimit"
        case zebraStripes = "grid.zebra"
        case appearance = "general.appearance"
        case historyLimit = "general.historyLimit"
        case defaultEngine = "general.defaultEngine"
        case reconnectLastOnLaunch = "general.reconnectOnLaunch"
        case lastConnectionID = "general.lastConnectionID"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Editor

    var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize.rawValue) } }
    var tabWidth: TabWidth { didSet { defaults.set(tabWidth.rawValue, forKey: Key.tabWidth.rawValue) } }
    var autoCompletion: Bool { didSet { defaults.set(autoCompletion, forKey: Key.autoCompletion.rawValue) } }
    var highlightStatement: Bool { didSet { defaults.set(highlightStatement, forKey: Key.highlightStatement.rawValue) } }
    var formatUppercase: Bool { didSet { defaults.set(formatUppercase, forKey: Key.formatUppercase.rawValue) } }

    // MARK: Dados

    var pageSize: Int { didSet { defaults.set(pageSize, forKey: Key.pageSize.rawValue) } }
    var rowDensity: RowDensity { didSet { defaults.set(rowDensity.rawValue, forKey: Key.rowDensity.rawValue) } }
    var previewLimit: Int { didSet { defaults.set(previewLimit, forKey: Key.previewLimit.rawValue) } }
    var zebraStripes: Bool { didSet { defaults.set(zebraStripes, forKey: Key.zebraStripes.rawValue) } }

    // MARK: Geral

    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance.rawValue)
            applyAppearance()
        }
    }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Key.historyLimit.rawValue) } }
    var defaultEngine: SQLEngine { didSet { defaults.set(defaultEngine.rawValue, forKey: Key.defaultEngine.rawValue) } }
    var reconnectLastOnLaunch: Bool { didSet { defaults.set(reconnectLastOnLaunch, forKey: Key.reconnectLastOnLaunch.rawValue) } }
    /// Gravada pelo app ao conectar; não aparece na janela de preferências.
    var lastConnectionID: UUID? {
        didSet { defaults.set(lastConnectionID?.uuidString, forKey: Key.lastConnectionID.rawValue) }
    }

    // MARK: Padrões

    static let defaultFontSize = 13.0
    static let fontSizeRange = 9.0...24.0
    static let pageSizeChoices = [100, 500, 1000, 5000]
    static let previewLimitChoices = [128, 256, 1024, 4096]
    static let historyLimitRange = 10...200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ key: Key, _ fallback: Int) -> Int { defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.integer(forKey: key.rawValue) }
        func bool(_ key: Key, _ fallback: Bool) -> Bool { defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.bool(forKey: key.rawValue) }

        let size = defaults.object(forKey: Key.editorFontSize.rawValue) == nil ? Self.defaultFontSize : defaults.double(forKey: Key.editorFontSize.rawValue)
        editorFontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        tabWidth = TabWidth(rawValue: int(.tabWidth, 4)) ?? .four
        autoCompletion = bool(.autoCompletion, true)
        highlightStatement = bool(.highlightStatement, true)
        formatUppercase = bool(.formatUppercase, true)

        pageSize = int(.pageSize, 1000)
        rowDensity = RowDensity(rawValue: defaults.string(forKey: Key.rowDensity.rawValue) ?? "") ?? .compact
        previewLimit = int(.previewLimit, 256)
        zebraStripes = bool(.zebraStripes, true)

        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance.rawValue) ?? "") ?? .system
        historyLimit = int(.historyLimit, 30)
        defaultEngine = SQLEngine(rawValue: defaults.string(forKey: Key.defaultEngine.rawValue) ?? "") ?? .postgres
        reconnectLastOnLaunch = bool(.reconnectLastOnLaunch, false)
        lastConnectionID = defaults.string(forKey: Key.lastConnectionID.rawValue).flatMap(UUID.init(uuidString:))
    }

    /// Apaga as chaves e reatribui os padrões — reatribuir é o que faz a UI observável reagir.
    func restoreDefaults() {
        for key in Key.allCases where key != .lastConnectionID {
            defaults.removeObject(forKey: key.rawValue)
        }
        editorFontSize = Self.defaultFontSize
        tabWidth = .four
        autoCompletion = true
        highlightStatement = true
        formatUppercase = true
        pageSize = 1000
        rowDensity = .compact
        previewLimit = 256
        zebraStripes = true
        appearance = .system
        historyLimit = 30
        defaultEngine = .postgres
        reconnectLastOnLaunch = false
    }

    // MARK: Derivados

    var indentUnit: String { String(repeating: " ", count: tabWidth.rawValue) }
    var rowHeight: CGFloat { rowDensity.height }
    var formatterOptions: SQLFormatter.Options {
        SQLFormatter.Options(indentUnit: indentUnit, uppercaseKeywords: formatUppercase)
    }

    /// `NSApp.appearance`, e não `.preferredColorScheme`: este só afeta a hierarquia SwiftUI,
    /// e o painel do autocomplete, a barra de busca e os menus do grid são AppKit — herdam
    /// do app. As cores do Theme são semânticas e acompanham sozinhas.
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
