import SwiftUI
import DBDeckCore

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Aparência") {
                Picker("Tema", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Densidade das linhas", selection: $settings.rowDensity) {
                    ForEach(RowDensity.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Linhas zebradas", isOn: $settings.zebraStripes)
                Picker("Linhas por página", selection: $settings.pageSize) {
                    ForEach(AppSettings.pageSizeChoices, id: \.self) { Text($0.formatted()).tag($0) }
                }
                Picker("Prévia por célula", selection: $settings.previewLimit) {
                    ForEach(AppSettings.previewLimitChoices, id: \.self) { Text("\($0) caracteres").tag($0) }
                }
            } header: {
                Text("Dados")
            } footer: {
                Text("A rolagem carrega a página seguinte sozinha. Valores maiores que a prévia são cortados na origem e carregados inteiros ao abrir a linha — é o que mantém tabelas com JSON e TEXT rápidas.")
            }

            Section("Editor SQL") {
                Stepper(value: $settings.editorFontSize, in: AppSettings.fontSizeRange, step: 1) {
                    LabeledContent("Tamanho da fonte") {
                        Text("\(Int(settings.editorFontSize)) pt").monospacedDigit()
                    }
                }
                Text("SELECT * FROM pedidos;")
                    .font(.system(size: settings.editorFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                Toggle("Sugestões de autocomplete", isOn: $settings.autoCompletion)
                Picker("Indentação", selection: $settings.tabWidth) {
                    ForEach(TabWidth.allCases) { Text("\($0.rawValue) espaços").tag($0) }
                }
                Toggle("Formatar com MAIÚSCULAS", isOn: $settings.formatUppercase)
            }

            Section {
                Picker("Banco padrão", selection: $settings.defaultEngine) {
                    ForEach(SQLEngine.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $settings.historyLimit, in: AppSettings.historyLimitRange, step: 10) {
                    LabeledContent("Histórico", value: "\(settings.historyLimit) consultas")
                }
                Toggle("Reabrir a última conexão", isOn: $settings.reconnectLastOnLaunch)
            } header: {
                Text("Geral")
            }

            Section {
                Button("Restaurar padrões", role: .destructive) { confirmReset = true }
            } footer: {
                Text("DBDeck \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .navigationTitle("Preferências")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }.fontWeight(.semibold)
            }
        }
        .confirmationDialog("Restaurar todas as preferências?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restaurar", role: .destructive) { settings.restoreDefaults() }
        }
    }
}
