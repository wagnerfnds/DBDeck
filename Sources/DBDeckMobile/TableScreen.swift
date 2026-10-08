import SwiftUI
import UIKit
import DBDeckCore

/// Uma tabela aberta: dados, estrutura e informações em abas segmentadas.
struct TableScreen: View {
    @Environment(Navigator.self) private var navigator
    @Environment(AppSettings.self) private var settings
    let connectionID: UUID
    let driver: any DatabaseDriver
    let table: String

    enum Pane: String, CaseIterable, Identifiable {
        case data = "Dados"
        case structure = "Estrutura"
        case info = "Info"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .data

    var body: some View {
        let model = navigator.model(for: table, driver: driver, settings: settings)
        VStack(spacing: 0) {
            switch pane {
            case .data:
                TableDataPane(model: model)
            case .structure:
                StructurePane(driver: driver, table: table) {
                    Task { await model.reloadStructure() }
                }
            case .info:
                TableInfoPane(driver: driver, table: table)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Painel", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dados

private struct TableDataPane: View {
    @Environment(Navigator.self) private var navigator
    @Environment(AppSettings.self) private var settings
    @Bindable var model: TableDataModel

    @State private var detail: RowDetailTarget?
    @State private var showFilters = false
    @State private var sharedFile: SharedFile?
    @State private var exportProgress: String?
    @State private var deletingRow: Int?

    var body: some View {
        VStack(spacing: 0) {
            if !model.columns.isEmpty && !model.isEditable {
                readOnlyBanner
            }
            if model.hasActiveFilter {
                filterChips
            }
            ZStack {
                if model.rows.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    grid
                }
                if model.isLoading && model.rows.isEmpty {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .task { await model.loadIfNeeded() }
        .sheet(item: $detail) { target in
            NavigationStack {
                RowDetailView(model: model, target: target) { link in
                    detail = nil
                    navigator.open(table: link.table, filter: link.filter)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                FilterSheet(model: model)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .shareSheet($sharedFile)
        .errorAlert($model.errorMessage)
        .toast($model.notice)
        .confirmationDialog(
            "Excluir esta linha?",
            isPresented: .init(get: { deletingRow != nil }, set: { if !$0 { deletingRow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Excluir", role: .destructive) {
                if let row = deletingRow {
                    Task {
                        if await model.deleteRow(row) { Haptics.success() } else { Haptics.error() }
                    }
                }
                deletingRow = nil
            }
        } message: {
            Text("O DELETE executa imediatamente no servidor.")
        }
    }

    // MARK: Grid

    private var grid: some View {
        DataGrid(
            columns: model.columns.map(GridColumn.init(column:)),
            rows: model.rows,
            rowsVersion: model.rowsVersion,
            scrollResetToken: model.firstPageVersion,
            sortColumn: model.sortColumn,
            sortAscending: model.sortAscending,
            deferredColumns: model.deferredColumns,
            linkColumns: Set(model.linkColumns.keys),
            rowHeight: settings.rowHeight,
            zebra: settings.zebraStripes,
            selectedRow: detail?.row,
            onTapCell: { row, col in
                Haptics.selection()
                detail = RowDetailTarget(row: row, focusColumn: col)
            },
            onTapHeader: { col in
                guard col < model.columns.count else { return }
                Task { await model.toggleSort(model.columns[col].name) }
            },
            onNearEnd: {
                Task { await model.loadMore() }
            },
            onRefresh: {
                await model.loadFirstPage(recount: true)
            },
            cellMenu: { row, col in cellMenu(row: row, col: col) },
            headerMenu: { col in headerMenu(col: col) }
        )
        .overlay(alignment: .bottom) {
            if model.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Carregando mais…").font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.isLoadingMore)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.hasActiveFilter ? "Nada encontrado" : "Tabela vazia", systemImage: model.hasActiveFilter ? "line.3.horizontal.decrease.circle" : "tray")
        } description: {
            Text(model.hasActiveFilter ? "Nenhuma linha atende ao filtro." : "Esta tabela ainda não tem linhas.")
        } actions: {
            if model.hasActiveFilter {
                Button("Limpar filtro") { Task { await model.clearFilters() } }
                    .buttonStyle(.bordered)
            } else if model.isEditable {
                Button {
                    detail = RowDetailTarget(row: nil, focusColumn: nil)
                } label: { Label("Inserir linha", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("Sem chave primária — somente leitura")
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.activeFilters) { filter in
                    HStack(spacing: 6) {
                        Text(filter.summary)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                        Button {
                            Haptics.tap()
                            Task { await model.removeFilter(filter.id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel("Remover filtro \(filter.summary)")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { showFilters = true }
                }
                Button("Limpar") { Task { await model.clearFilters() } }
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: Rodapé

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button {
                showFilters = true
            } label: {
                Image(systemName: model.hasActiveFilter
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Filtros")

            if model.isEditable {
                Button {
                    detail = RowDetailTarget(row: nil, focusColumn: nil)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Inserir linha")
            }

            Spacer(minLength: 4)

            Button {
                Task { await model.countExactly() }
            } label: {
                VStack(spacing: 1) {
                    Text(exportProgress ?? model.countLabel)
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                    if let sort = model.sortColumn {
                        Text("\(sort) \(model.sortAscending ? "↑" : "↓")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.totalIsEstimate {
                        Text("toque para contar")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(!model.totalIsEstimate && model.totalCount != nil)

            Spacer(minLength: 4)

            Menu {
                Section("Linhas carregadas (\(model.rows.count))") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) { Task { await exportLoaded(format) } }
                    }
                }
                Section("Tabela inteira") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) { Task { await exportWhole(format) } }
                    }
                }
                if model.columns.contains(where: \.isBlobOrText) {
                    Section {
                        Toggle(isOn: Binding(
                            get: { model.deferBlobs },
                            set: { value in
                                model.deferBlobs = value
                                Task { await model.loadFirstPage() }
                            }
                        )) {
                            Label("Adiar TEXT/BLOB", systemImage: "doc.richtext")
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Exportar")

            Button {
                Task { await model.loadFirstPage(recount: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Recarregar")
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Menus

    private func cellMenu(row: Int, col: Int) -> UIMenu? {
        guard row < model.rows.count, col < model.columns.count, col < model.rows[row].count else { return nil }
        let column = model.columns[col]
        let value = model.rows[row][col]
        var actions: [UIMenuElement] = []

        actions.append(UIAction(title: "Copiar valor", image: UIImage(systemName: "doc.on.doc")) { _ in
            Task { @MainActor in
                if model.needsFullValue(row: row, col: col) { await model.loadFullValue(row: row, col: col) }
                guard row < model.rows.count, col < model.rows[row].count else { return }
                UIPasteboard.general.string = model.rows[row][col].copyText
                model.notice = "Valor copiado"
            }
        })
        actions.append(UIAction(title: "Copiar linha", image: UIImage(systemName: "doc.on.clipboard")) { _ in
            Task { @MainActor in
                await model.materializeRow(row)
                guard row < model.rows.count else { return }
                UIPasteboard.general.string = model.rows[row].map(\.copyText).joined(separator: "\t")
                model.notice = "Linha copiada"
            }
        })
        actions.append(UIAction(title: "Copiar como INSERT", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
            Task { @MainActor in
                if let sql = await model.insertStatement(for: row) {
                    UIPasteboard.general.string = sql
                    model.notice = "INSERT copiado"
                }
            }
        })

        var navigation: [UIMenuElement] = []
        if !value.isTruncated, !model.deferredColumns.contains(col) {
            navigation.append(UIAction(
                title: value == .null ? "Filtrar: \(column.name) é NULL" : "Filtrar por este valor",
                image: UIImage(systemName: "line.3.horizontal.decrease.circle")
            ) { _ in
                Task { await model.filter(column: column.name, value: value) }
            })
        }
        if let key = model.linkColumns[col], value != .null, !value.isTruncated {
            navigation.append(UIAction(
                title: "Abrir \(key.referencedTable)",
                image: UIImage(systemName: "arrow.up.forward.circle")
            ) { _ in
                navigator.open(
                    table: key.referencedTable,
                    filter: TableLinkFilter(column: key.referencedColumns[0], value: value.display)
                )
            })
        }

        var edit: [UIMenuElement] = [
            UIAction(title: "Ver linha", image: UIImage(systemName: "list.bullet.rectangle")) { _ in
                detail = RowDetailTarget(row: row, focusColumn: col)
            },
        ]
        if model.isEditable {
            edit.append(UIAction(title: "Excluir linha", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                deletingRow = row
            })
        }

        return UIMenu(title: column.name, children: [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: navigation),
            UIMenu(options: .displayInline, children: edit),
        ])
    }

    private func headerMenu(col: Int) -> UIMenu? {
        guard col < model.columns.count else { return nil }
        let column = model.columns[col]
        return UIMenu(title: "\(column.name) · \(column.type)", children: [
            UIAction(title: "Ordem crescente", image: UIImage(systemName: "arrow.up")) { _ in
                Task { await model.setSort(column.name, ascending: true) }
            },
            UIAction(title: "Ordem decrescente", image: UIImage(systemName: "arrow.down")) { _ in
                Task { await model.setSort(column.name, ascending: false) }
            },
            UIAction(title: "Ordem natural", image: UIImage(systemName: "arrow.up.arrow.down"),
                     attributes: model.sortColumn == nil ? .disabled : []) { _ in
                Task { await model.setSort(nil, ascending: true) }
            },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Filtrar coluna…", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
                    if let index = model.filters.firstIndex(where: { model.whereClause(for: $0) == nil }) {
                        model.filters[index].column = column.name
                    } else {
                        var filter = model.newFilterRow()
                        filter.column = column.name
                        model.filters.append(filter)
                    }
                    showFilters = true
                },
                UIAction(title: "Copiar nome", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = column.name
                    model.notice = "Nome copiado"
                },
            ]),
        ])
    }

    // MARK: Export

    private func exportLoaded(_ format: ExportFormat) async {
        exportProgress = "Exportando…"
        defer { exportProgress = nil }
        if let url = await model.exportLoaded(format: format) {
            sharedFile = SharedFile(url: url)
        }
    }

    private func exportWhole(_ format: ExportFormat) async {
        exportProgress = "Exportando…"
        defer { exportProgress = nil }
        if let url = await model.exportWholeTable(format: format, progress: { done in
            exportProgress = "Exportando · \(done.formatted()) linhas"
        }) {
            sharedFile = SharedFile(url: url)
        }
    }
}

/// O que o detalhe de linha abre: uma linha existente (`row`) ou uma nova (`nil`).
struct RowDetailTarget: Identifiable {
    var id: String { row.map(String.init) ?? "new" }
    var row: Int?
    var focusColumn: Int?
}
