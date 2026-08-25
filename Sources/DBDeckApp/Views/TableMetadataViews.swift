import SwiftUI
import DBDeckCore

// MARK: - Relações

/// Chaves estrangeiras da tabela: as que saem dela e as que chegam nela. Clicar numa
/// linha abre a tabela do outro lado.
struct RelationsView: View {
    let driver: any DatabaseDriver
    let table: String
    var onOpenTable: (String) -> Void

    @State private var outgoing: [ForeignKey] = []
    @State private var incoming: [ForeignKey] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carregando relações…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Não foi possível ler as relações", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if outgoing.isEmpty && incoming.isEmpty {
                ContentUnavailableView("Sem relações", systemImage: "arrow.left.arrow.right", description: Text("Esta tabela não tem chaves estrangeiras nem é referenciada por outras."))
            } else {
                List {
                    if !outgoing.isEmpty {
                        Section("Esta tabela referencia") {
                            ForEach(outgoing) { key in
                                row(key, target: key.referencedTable, from: key.columns, to: key.referencedColumns)
                            }
                        }
                    }
                    if !incoming.isEmpty {
                        Section("Referenciada por") {
                            ForEach(incoming) { key in
                                row(key, target: key.table, from: key.referencedColumns, to: key.columns, reversed: true)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await load() }
    }

    private func row(_ key: ForeignKey, target: String, from: [String], to: [String], reversed: Bool = false) -> some View {
        Button {
            onOpenTable(target)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: reversed ? "arrow.left" : "arrow.right")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(from.joined(separator: ", "))
                            .font(Font(Theme.codeFont(size: 12)))
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(target).font(Font(Theme.codeFont(size: 12, weight: .semibold)))
                        Text("(\(to.joined(separator: ", ")))")
                            .font(Font(Theme.codeFont(size: 12)))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(key.name) · ON UPDATE \(key.onUpdate) · ON DELETE \(key.onDelete)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Abrir \(target)")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            outgoing = try await SchemaMetadata.foreignKeys(driver: driver, table: table)
            incoming = try await SchemaMetadata.referencingKeys(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Triggers

struct TriggersView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var triggers: [TableTrigger] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carregando triggers…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Não foi possível ler os triggers", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if triggers.isEmpty {
                ContentUnavailableView("Sem triggers", systemImage: "bolt", description: Text("Nenhum trigger definido nesta tabela."))
            } else {
                List {
                    ForEach(triggers) { trigger in
                        DisclosureGroup(isExpanded: binding(for: trigger.id)) {
                            Text(AttributedString(SQLSyntaxHighlighter.attributed(trigger.body, fontSize: 12)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.fill").foregroundStyle(.orange).frame(width: 16)
                                Text(trigger.name).font(Font(Theme.codeFont(size: 12, weight: .semibold)))
                                Text("\(trigger.timing) \(trigger.event)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await load() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            triggers = try await SchemaMetadata.triggers(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Info da tabela

struct TableInfoView: View {
    let driver: any DatabaseDriver
    let table: String

    @State private var info: TableInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carregando informações…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Não foi possível ler as informações", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(Array(info.facts.enumerated()), id: \.offset) { _, fact in
                                GridRow {
                                    Text(fact.label).foregroundStyle(.secondary)
                                    Text(fact.value).textSelection(.enabled)
                                }
                            }
                        }
                        HStack {
                            Text("DDL").font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(info.ddl, forType: .string)
                                copied = true
                                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                            } label: {
                                Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .controlSize(.small)
                        }
                        Text(AttributedString(SQLSyntaxHighlighter.attributed(info.ddl, fontSize: 12)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                    .padding(16)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await SchemaMetadata.tableInfo(driver: driver, table: table)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
