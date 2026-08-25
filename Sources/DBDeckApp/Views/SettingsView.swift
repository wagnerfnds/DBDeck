import SwiftUI
import DBDeckCore

/// Janela de Preferências (⌘,): três abas e um "Restaurar padrões" comum.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("Geral", systemImage: "gearshape") }
                EditorSettingsTab()
                    .tabItem { Label("Editor", systemImage: "text.cursor") }
                DataSettingsTab()
                    .tabItem { Label("Dados", systemImage: "tablecells") }
            }
            HStack {
                Spacer()
                Button("Restaurar padrões") { settings.restoreDefaults() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Aparência", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Engine padrão para nova conexão", selection: $settings.defaultEngine) {
                ForEach(SQLEngine.allCases) { Text($0.displayName).tag($0) }
            }

            Stepper(
                "Histórico de consultas: \(settings.historyLimit)",
                value: $settings.historyLimit,
                in: AppSettings.historyLimitRange,
                step: 10
            )

            Toggle("Reconectar à última conexão ao abrir", isOn: $settings.reconnectLastOnLaunch)
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Stepper(
                    "Tamanho da fonte: \(Int(settings.editorFontSize)) pt",
                    value: $settings.editorFontSize,
                    in: AppSettings.fontSizeRange,
                    step: 1
                )
                Picker("Largura do Tab", selection: $settings.tabWidth) {
                    ForEach(TabWidth.allCases) { Text("\($0.rawValue) espaços").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Sugerir automaticamente ao digitar", isOn: $settings.autoCompletion)
                Toggle("Realçar o comando sob o cursor", isOn: $settings.highlightStatement)
                Toggle("Palavras reservadas em caixa alta ao formatar", isOn: $settings.formatUppercase)
            } footer: {
                Text("⌃Espaço sempre abre a lista de sugestões; ⇧⌥F formata a seleção ou a consulta inteira.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Linhas por página", selection: $settings.pageSize) {
                ForEach(AppSettings.pageSizeChoices, id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Altura da linha", selection: $settings.rowDensity) {
                ForEach(RowDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Prévia por célula", selection: $settings.previewLimit) {
                ForEach(AppSettings.previewLimitChoices, id: \.self) { Text("\($0.formatted()) caracteres").tag($0) }
            }
            Toggle("Listras zebra", isOn: $settings.zebraStripes)
        }
        .formStyle(.grouped)
    }
}
