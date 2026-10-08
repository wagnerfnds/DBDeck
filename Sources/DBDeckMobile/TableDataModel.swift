import Foundation
import Observation
import DBDeckCore

/// Operadores do filtro de conteúdo (os mesmos do Mac, estilo Sequel Ace).
enum RowFilterOperator: String, CaseIterable, Identifiable {
    case equals = "="
    case notEquals = "≠"
    case greater = ">"
    case greaterOrEqual = "≥"
    case less = "<"
    case lessOrEqual = "≤"
    case contains = "contém"
    case beginsWith = "começa com"
    case endsWith = "termina com"
    case isNull = "é NULL"
    case isNotNull = "não é NULL"

    var id: String { rawValue }
    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

struct RowFilter: Identifiable, Equatable {
    var id = UUID()
    var column: String = ""
    var op: RowFilterOperator = .equals
    var value: String = ""
    var enabled = true

    var summary: String {
        op.needsValue ? "\(column) \(op.rawValue) \(value)" : "\(column) \(op.rawValue)"
    }
}

/// Estado e regras da listagem de uma tabela no iOS.
///
/// É o `TableDataView` do Mac fora da View: a paginação por âncora (keyset), o
/// streaming com publicação progressiva, o corte de valores grandes na origem e as
/// colunas adiadas são os mesmos — o que muda é a navegação. No telefone não há botões
/// de página: o grid carrega a página seguinte quando a rolagem chega perto do fim
/// (rolagem infinita), ancorada na PK da última linha, então a página 50 custa o mesmo
/// que a primeira.
///
/// Classe, e não `@State` na View, para sobreviver à navegação: voltar a uma tabela
/// encontra as linhas, o filtro e a posição de onde se saiu.
@MainActor
@Observable
final class TableDataModel {
    let driver: any DatabaseDriver
    let table: String
    @ObservationIgnored let driverIdentity: ObjectIdentifier
    @ObservationIgnored private let settings: AppSettings

    private(set) var columns: [DatabaseColumn] = []
    private(set) var primaryKeys: [String] = []
    /// Linhas carregadas (todas as páginas já roladas).
    private(set) var rows: [[SQLValue]] = []
    /// Incrementado a cada mudança em `rows`: o grid UIKit compara isto em vez de
    /// comparar milhares de linhas para decidir se recarrega.
    private(set) var rowsVersion = 0
    /// Muda quando a listagem recomeça do topo (filtro, sort, recarga): o grid volta ao
    /// início em vez de ficar parado no meio de um resultado que não é mais o mesmo.
    private(set) var firstPageVersion = 0
    /// Índice da coluna → FK de coluna única (vira o ícone de link na célula).
    private(set) var linkColumns: [Int: ForeignKey] = [:]
    private(set) var deferredColumns: Set<Int> = []

    private(set) var totalCount: Int?
    private(set) var totalIsEstimate = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// A última página voltou curta: não há mais o que rolar.
    private(set) var reachedEnd = false
    var errorMessage: String?
    var notice: String?

    private(set) var sortColumn: String?
    private(set) var sortAscending = true

    var filters: [RowFilter] = []
    private(set) var appliedFilter: String?
    var deferBlobs = false

    /// Filtro com que a tabela abre (seguir uma chave estrangeira).
    @ObservationIgnored var initialFilter: TableLinkFilter?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadGeneration = 0
    /// Até onde a rolagem infinita acumula. Acima disso o pedido é filtrar — 50 mil
    /// linhas já são dezenas de MB de `SQLValue` num aparelho com memória apertada.
    @ObservationIgnored private let maxLoadedRows = 50_000
    @ObservationIgnored private let streamBatchSize = 100

    init(driver: any DatabaseDriver, table: String, settings: AppSettings) {
        self.driver = driver
        self.table = table
        self.settings = settings
        self.driverIdentity = ObjectIdentifier(driver as AnyObject)
    }

    var pageSize: Int { settings.pageSize }
    var previewLimit: Int { settings.previewLimit }
    var isEditable: Bool { !primaryKeys.isEmpty }
    var hasActiveFilter: Bool { appliedFilter != nil }
    var activeFilters: [RowFilter] { appliedFilter == nil ? [] : filters.filter { $0.enabled && whereClause(for: $0) != nil } }
    var canLoadMore: Bool { !reachedEnd && !isLoading && !isLoadingMore && rows.count < maxLoadedRows }

    var countLabel: String {
        guard !rows.isEmpty else { return isLoading ? "carregando…" : "0 linhas" }
        let loadedText = rows.count.formatted()
        guard let total = totalCount else { return reachedEnd ? "\(loadedText) linhas" : "\(loadedText) de ?" }
        if !totalIsEstimate && total == rows.count { return "\(loadedText) linhas" }
        return "\(loadedText) de \(totalIsEstimate ? "~" : "")\(total.formatted())"
    }

    // MARK: - Abertura

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        do {
            // Uma consulta de metadados só: `columns()` já marca a PK em todos os engines.
            columns = try await driver.columns(table: table)
            primaryKeys = columns.filter(\.isPrimaryKey).map(\.name)
            if let link = initialFilter {
                initialFilter = nil
                var first = RowFilter()
                first.column = link.column
                first.value = link.value
                filters = [first]
                appliedFilter = whereClause(for: first)
            } else if filters.isEmpty {
                var first = RowFilter()
                first.column = primaryKeys.first ?? columns.first?.name ?? ""
                filters = [first]
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadFirstPage(recount: true)
        // FKs depois da primeira página: o link é enfeite, os dados não esperam por ele.
        if let keys = try? await SchemaMetadata.foreignKeys(driver: driver, table: table) {
            var links: [Int: ForeignKey] = [:]
            for key in keys where key.isSingleColumn {
                if let index = columns.firstIndex(where: { $0.name == key.columns[0] }) { links[index] = key }
            }
            linkColumns = links
        }
    }

    // MARK: - Consulta

    private var queryBuilder: PageQueryBuilder {
        PageQueryBuilder(
            engine: driver.engine,
            table: table,
            columns: columns,
            primaryKeys: primaryKeys,
            sortColumn: sortColumn,
            sortAscending: sortAscending,
            filter: appliedFilter,
            pageSize: pageSize,
            deferBlobs: deferBlobs
        )
    }

    private func keysetValue(at rowIndex: Int) -> SQLValue? {
        guard let key = queryBuilder.keysetColumn,
              let column = columns.firstIndex(where: { $0.name == key }),
              rowIndex >= 0, rowIndex < rows.count, column < rows[rowIndex].count
        else { return nil }
        let value = rows[rowIndex][column]
        guard !value.isTruncated, value != .null else { return nil }
        return value
    }

    /// Ponte do `streamQuery` (callback na thread de I/O do driver) para o main actor.
    private func rowBatches(sql: String) -> AsyncThrowingStream<RowBatch, any Error> {
        let driver = self.driver
        let batchSize = streamBatchSize
        let limit = previewLimit
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await driver.streamQuery(sql, batchSize: batchSize, previewLimit: limit) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Recomeça do topo (abertura, sort, filtro, puxar para atualizar).
    func loadFirstPage(recount: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        isLoadingMore = false
        reachedEnd = false
        defer { if loadGeneration == generation { isLoading = false } }

        let page = queryBuilder.make(cursor: .absolute(0))
        deferredColumns = queryBuilder.deferredColumnIndexes
        firstPageVersion += 1

        do {
            var accumulated: [[SQLValue]] = []
            var resultColumns: [String] = []
            // Publicação progressiva: o primeiro lote aparece na hora (enche a tela) e
            // os seguintes vão espaçando — a mesma curva do Mac.
            var nextPublish = ContinuousClock.now
            var interval = Duration.milliseconds(20)
            var publishes = 0
            for try await batch in rowBatches(sql: page.sql) {
                guard loadGeneration == generation else { return }
                if resultColumns.isEmpty { resultColumns = batch.columns }
                accumulated.append(contentsOf: batch.rows)
                guard publishes < 3, ContinuousClock.now >= nextPublish else { continue }
                publish(accumulated)
                publishes += 1
                interval = interval == .milliseconds(20) ? .milliseconds(200) : .milliseconds(500)
                nextPublish = ContinuousClock.now + interval
            }
            guard loadGeneration == generation else { return }
            await resyncColumnsIfNeeded(resultColumns)
            guard loadGeneration == generation else { return }
            publish(accumulated)
            reachedEnd = accumulated.count < pageSize
            if recount { await refreshCount() }
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Próxima página, ancorada na PK da última linha (keyset) quando possível.
    func loadMore() async {
        guard canLoadMore, !rows.isEmpty else { return }
        let generation = loadGeneration
        isLoadingMore = true
        defer { if loadGeneration == generation { isLoadingMore = false } }

        let target = rows.count
        let cursor: PageCursor = keysetValue(at: rows.count - 1).map { .after($0, offset: target) } ?? .absolute(target)
        let page = queryBuilder.make(cursor: cursor)
        do {
            var accumulated: [[SQLValue]] = []
            for try await batch in rowBatches(sql: page.sql) {
                guard loadGeneration == generation else { return }
                accumulated.append(contentsOf: batch.rows)
            }
            guard loadGeneration == generation else { return }
            if page.reversed { accumulated.reverse() }
            rows.append(contentsOf: accumulated)
            original.append(contentsOf: accumulated)
            rowsVersion += 1
            reachedEnd = accumulated.count < pageSize
            if reachedEnd, appliedFilter != nil || totalCount == nil {
                totalCount = rows.count
                totalIsEstimate = false
            }
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Cópia do que veio do servidor — chaves para UPDATE/DELETE sem depender de edição local.
    @ObservationIgnored private var original: [[SQLValue]] = []

    private func publish(_ accumulated: [[SQLValue]]) {
        rows = accumulated
        original = accumulated
        rowsVersion += 1
    }

    /// ALTER TABLE feito na aba Estrutura com esta tabela aberta: colunas do resultado
    /// diferentes das conhecidas indexariam errado (crash) — ressincroniza antes.
    private func resyncColumnsIfNeeded(_ resultColumns: [String]) async {
        guard !resultColumns.isEmpty, resultColumns != columns.map(\.name) else { return }
        if let fresh = try? await driver.columns(table: table), !fresh.isEmpty {
            columns = fresh
            primaryKeys = fresh.filter(\.isPrimaryKey).map(\.name)
            deferredColumns = queryBuilder.deferredColumnIndexes
        }
    }

    /// Mudou a estrutura (aba Estrutura): recarrega metadados e dados.
    func reloadStructure() async {
        if let fresh = try? await driver.columns(table: table), !fresh.isEmpty {
            columns = fresh
            primaryKeys = fresh.filter(\.isPrimaryKey).map(\.name)
        }
        await loadFirstPage(recount: true)
    }

    private func refreshCount() async {
        if reachedEnd {
            totalCount = rows.count
            totalIsEstimate = false
            return
        }
        guard appliedFilter == nil else {
            totalCount = nil
            totalIsEstimate = false
            return
        }
        guard let estimate = try? await driver.rowCount(table: table, allowExactScan: false) else {
            totalCount = nil
            return
        }
        totalCount = estimate.isKnown ? estimate.value : nil
        totalIsEstimate = estimate.isEstimate
    }

    /// Contagem exata sob demanda — a varredura completa que a abertura evita.
    func countExactly() async {
        if let appliedFilter {
            let sql = "SELECT COUNT(*) FROM \(driver.quoteIdentifier(table)) WHERE \(appliedFilter)"
            guard let first = try? await driver.query(sql).rows.first?.first else { return }
            switch first {
            case .int(let value): totalCount = Int(value)
            case .text(let value): totalCount = Int(value)
            default: return
            }
            totalIsEstimate = false
            return
        }
        guard let exact = try? await driver.rowCount(table: table, allowExactScan: true) else { return }
        totalCount = exact.isKnown ? exact.value : nil
        totalIsEstimate = exact.isEstimate
    }

    // MARK: - Sort

    func toggleSort(_ column: String) async {
        if sortColumn == column {
            if sortAscending {
                sortAscending = false
            } else {
                // Terceiro toque volta à ordem natural — no toque não há "clique com ⌥".
                sortColumn = nil
                sortAscending = true
            }
        } else {
            sortColumn = column
            sortAscending = true
        }
        await loadFirstPage()
    }

    func setSort(_ column: String?, ascending: Bool) async {
        sortColumn = column
        sortAscending = ascending
        await loadFirstPage()
    }

    // MARK: - Filtro

    func applyFilters() async {
        let clauses = filters.filter(\.enabled).compactMap { whereClause(for: $0) }
        let newFilter = clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
        guard newFilter != appliedFilter else { return }
        appliedFilter = newFilter
        await loadFirstPage(recount: true)
    }

    func clearFilters() async {
        for index in filters.indices { filters[index].value = "" }
        if filters.count > 1 { filters = Array(filters.prefix(1)) }
        guard appliedFilter != nil else { return }
        appliedFilter = nil
        await loadFirstPage(recount: true)
    }

    func removeFilter(_ id: UUID) async {
        filters.removeAll { $0.id == id }
        if filters.isEmpty {
            var first = RowFilter()
            first.column = primaryKeys.first ?? columns.first?.name ?? ""
            filters = [first]
        }
        await applyFilters()
    }

    /// Atalho do menu da célula: "mostrar só linhas com este valor".
    func filter(column: String, value: SQLValue) async {
        var filter = RowFilter()
        filter.column = column
        if value == .null {
            filter.op = .isNull
        } else {
            filter.value = value.display
        }
        // Substitui um filtro vazio; senão acumula (AND) — é o refinamento progressivo
        // que se faz tocando em valores.
        if let index = filters.firstIndex(where: { whereClause(for: $0) == nil }) {
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        await applyFilters()
    }

    func newFilterRow() -> RowFilter {
        var filter = RowFilter()
        filter.column = primaryKeys.first ?? columns.first?.name ?? ""
        return filter
    }

    func whereClause(for filter: RowFilter) -> String? {
        guard !filter.column.isEmpty else { return nil }
        if filter.op.needsValue && filter.value.isEmpty { return nil }
        let column = driver.quoteIdentifier(filter.column)
        let escaped = literalEscaped(filter.value)
        let pattern = literalEscaped(
            filter.value
                .replacingOccurrences(of: "|", with: "||")
                .replacingOccurrences(of: "%", with: "|%")
                .replacingOccurrences(of: "_", with: "|_")
        )
        let textColumn = driver.engine == .postgres ? "CAST(\(column) AS TEXT)" : column
        switch filter.op {
        case .equals: return "\(column) = '\(escaped)'"
        case .notEquals: return "\(column) <> '\(escaped)'"
        case .greater: return "\(column) > '\(escaped)'"
        case .greaterOrEqual: return "\(column) >= '\(escaped)'"
        case .less: return "\(column) < '\(escaped)'"
        case .lessOrEqual: return "\(column) <= '\(escaped)'"
        case .contains: return "\(textColumn) LIKE '%\(pattern)%' ESCAPE '|'"
        case .beginsWith: return "\(textColumn) LIKE '\(pattern)%' ESCAPE '|'"
        case .endsWith: return "\(textColumn) LIKE '%\(pattern)' ESCAPE '|'"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        }
    }

    private func literalEscaped(_ value: String) -> String {
        var escaped = value
        if driver.engine == .mysql {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        return escaped.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Valores íntegros

    func needsFullValue(row: Int, col: Int) -> Bool {
        if deferredColumns.contains(col) { return true }
        guard row < rows.count, col < rows[row].count else { return false }
        return rows[row][col].isTruncated
    }

    /// Recarrega uma célula inteira do servidor (o grid trabalha com prefixos).
    @discardableResult
    func loadFullValue(row: Int, col: Int) async -> Bool {
        guard row < rows.count, col < columns.count, col < rows[row].count,
              let sql = singleCellQuery(row: row, column: columns[col]),
              let value = try? await driver.query(sql, previewLimit: nil).rows.first?.first
        else { return false }
        guard row < rows.count, col < rows[row].count else { return false }
        rows[row][col] = value
        if row < original.count, col < original[row].count { original[row][col] = value }
        rowsVersion += 1
        return true
    }

    private func singleCellQuery(row: Int, column: DatabaseColumn) -> String? {
        var keyValues: [(column: String, value: SQLValue)] = []
        if row < original.count {
            for key in primaryKeys {
                guard let index = columns.firstIndex(where: { $0.name == key }),
                      index < original[row].count else { return nil }
                keyValues.append((key, original[row][index]))
            }
        }
        return queryBuilder.singleCellQuery(column: column, primaryKeyValues: keyValues, absoluteRowIndex: row)
    }

    func materializeRow(_ row: Int) async {
        for col in columns.indices where needsFullValue(row: row, col: col) {
            await loadFullValue(row: row, col: col)
        }
    }

    // MARK: - Edição

    private func pkValues(row: Int) -> [SQLValue]? {
        guard row < original.count else { return nil }
        let values: [SQLValue] = primaryKeys.map { key in
            let index = columns.firstIndex { $0.name == key } ?? 0
            return index < original[row].count ? original[row][index] : .null
        }
        return values.contains(.null) ? nil : values
    }

    /// Grava as diferenças de uma linha (UPDATE só das colunas alteradas) e atualiza a
    /// linha no lugar — sem recarregar a página, a rolagem fica onde estava.
    func saveRow(_ row: Int, values edited: [SQLValue]) async -> Bool {
        guard row < rows.count else { return false }
        guard let keys = pkValues(row: row) else {
            errorMessage = "Linha sem chave primária utilizável — não foi possível atualizar."
            return false
        }
        var changes: [(column: String, value: SQLValue)] = []
        var normalizedRow = rows[row]
        for (index, column) in columns.enumerated() where index < edited.count && index < original[row].count {
            let newValue = edited[index]
            guard newValue != original[row][index], !newValue.isTruncated else { continue }
            let normalized = normalize(newValue, column: column)
            changes.append((column.name, normalized))
            normalizedRow[index] = normalized
        }
        guard !changes.isEmpty else { return true }
        do {
            _ = try await driver.updateRow(table: table, primaryKey: primaryKeys, pkValues: keys, changes: changes)
            guard row < rows.count else { return true }
            rows[row] = normalizedRow
            original[row] = normalizedRow
            rowsVersion += 1
            notice = changes.count == 1 ? "1 campo salvo" : "\(changes.count) campos salvos"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func insertRow(values: [SQLValue]) async -> Bool {
        var pairs: [(column: String, value: SQLValue)] = []
        for (index, column) in columns.enumerated() where index < values.count {
            let value = values[index]
            if case .null = value { continue }
            pairs.append((column.name, normalize(value, column: column)))
        }
        guard !pairs.isEmpty else {
            errorMessage = "Preencha ao menos um campo."
            return false
        }
        do {
            _ = try await driver.insertRow(table: table, values: pairs)
            notice = "Linha inserida"
            await loadFirstPage(recount: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteRow(_ row: Int) async -> Bool {
        guard let keys = pkValues(row: row) else {
            errorMessage = "Não é possível excluir: chave primária nula."
            return false
        }
        do {
            _ = try await driver.deleteRow(table: table, primaryKey: primaryKeys, pkValues: keys)
            if row < rows.count {
                rows.remove(at: row)
                original.remove(at: row)
                rowsVersion += 1
            }
            if let total = totalCount { totalCount = max(0, total - 1) }
            notice = "Linha excluída"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func normalize(_ value: SQLValue, column: DatabaseColumn) -> SQLValue {
        guard case .text(let text) = value else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return column.isNullable ? .null : .text("")
        }
        let type = column.type.lowercased()
        if type.contains("bool") {
            switch trimmed.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: return .text(trimmed)
            }
        }
        if type.contains("int") {
            if let value = Int64(trimmed) { return .int(value) }
        } else if type.contains("double") || type.contains("real") || type.contains("float") || type.contains("numeric") || type.contains("decimal") {
            if let value = Double(trimmed) { return .double(value) }
        }
        return .text(trimmed)
    }

    // MARK: - Cópia / export

    func insertStatement(for row: Int) async -> String? {
        guard row < rows.count else { return nil }
        await materializeRow(row)
        guard row < rows.count else { return nil }
        let names = columns.map { driver.quoteIdentifier($0.name) }.joined(separator: ", ")
        let values = columns.indices.map { index -> String in
            guard index < rows[row].count else { return "NULL" }
            return rows[row][index].sqlLiteral(engine: driver.engine)
        }.joined(separator: ", ")
        return "INSERT INTO \(driver.quoteIdentifier(table)) (\(names)) VALUES (\(values));"
    }

    /// Exporta as linhas carregadas com valores ÍNTEGROS (relê sem corte se preciso).
    func exportLoaded(format: ExportFormat) async -> URL? {
        var exportRows = rows
        let hasPartial = deferBlobs || rows.contains { $0.contains(where: \.isTruncated) }
        if hasPartial {
            var builder = queryBuilder
            builder.pageSize = max(rows.count, 1)
            let page = builder.make(cursor: .absolute(0), deferring: false)
            if let result = try? await driver.query(page.sql, previewLimit: nil) {
                exportRows = page.reversed ? result.rows.reversed() : result.rows
            }
        }
        let text = ResultExporter.export(
            format: format, columns: columns.map(\.name), rows: exportRows, tableName: table, engine: driver.engine
        )
        let url = ExportFiles.temporaryURL(named: table, ext: format.fileExtension)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tabela inteira em streaming direto para o arquivo.
    func exportWholeTable(format: ExportFormat, progress: @escaping @MainActor (Int) -> Void) async -> URL? {
        let url = ExportFiles.temporaryURL(named: table, ext: format.fileExtension)
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try await ResultExporter.exportTable(
                driver: driver, table: table, format: format,
                write: { chunk in try handle.write(contentsOf: Data(chunk.utf8)) },
                progress: { done in Task { @MainActor in progress(done) } }
            )
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
