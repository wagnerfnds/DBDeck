import SwiftUI
import DBDeckCore

/// Criação de banco no servidor da conexão. Sem isto, começar um import num banco
/// novo exigia abrir um console e rodar o CREATE DATABASE na mão.
struct NewDatabaseSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let connection: ConnectionConfig
    /// Chamado com o nome criado (para já selecionar o banco novo).
    var onCreated: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var charset: String
    @State private var isBusy = false
    @State private var errorMessage: String?

    init(connection: ConnectionConfig, onCreated: @escaping (String) -> Void = { _ in }) {
        self.connection = connection
        self.onCreated = onCreated
        _charset = State(initialValue: connection.engine == .mysql ? "utf8mb4" : "UTF8")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(connection.engine.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Novo banco de dados").font(.title3.bold())
                    Text(connection.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Form {
                TextField("Nome", text: $name)
                    .onSubmit { create() }
                TextField(connection.engine == .mysql ? "Charset" : "Encoding", text: $charset)
                    .help(connection.engine == .mysql
                          ? "utf8mb4 cobre emoji e todos os caracteres Unicode."
                          : "Deixe vazio para herdar o encoding do template do servidor.")
            }
            .formStyle(.grouped)
            .frame(height: 90)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isBusy ? "Criando…" : "Criar") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isBusy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func create() {
        let target = trimmedName
        guard !target.isEmpty, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await state.createDatabase(named: target, charset: charset, on: connection.id)
                onCreated(target)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
