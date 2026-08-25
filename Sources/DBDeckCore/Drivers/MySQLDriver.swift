import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import os

public final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: SQLEngine = .mysql

    private let config: ConnectionConfig
    private var connection: MySQLConnection?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private let lock = OSAllocatedUnfairLock(initialState: false)
    /// `CONNECTION_ID()` desta sessão — o alvo do `KILL QUERY`. Lido fora do lock de
    /// propósito: o cancelamento chega enquanto a conexão está ocupada com a consulta.
    private let serverConnectionID = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    public init(config: ConnectionConfig) {
        self.config = config
    }

    public var isConnected: Bool {
        lock.withLock { $0 }
    }

    public func connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            // Banco vazio = conecta sem schema padrão (permite listar bancos do servidor).
            let database = config.database
            var tls: NIOSSL.TLSConfiguration?
            if config.useTLS {
                var clientTLS = NIOSSL.TLSConfiguration.makeClientConfiguration()
                // Bancos gerenciados (DigitalOcean/RDS) usam CA próprio: não verifica o certificado.
                clientTLS.certificateVerification = .none
                tls = clientTLS
            } else {
                tls = nil
            }
            let conn = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: database,
                password: config.password.isEmpty ? nil : config.password,
                tlsConfiguration: tls,
                on: group.next()
            ).get()
            self.eventLoopGroup = group
            self.connection = conn
            lock.withLock { $0 = true }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        // Só informativo: sem o id o cancelamento vira no-op, não um erro de conexão.
        if let row = try? await query("SELECT CONNECTION_ID()").rows.first?.first,
           case .int(let id) = row {
            serverConnectionID.withLock { $0 = UInt64(id) }
        }
    }

    /// `KILL QUERY` é o único jeito de abortar um statement no MySQL — e tem que vir de
    /// OUTRA conexão, porque esta está bloqueada servindo o resultado. A conexão auxiliar
    /// vive só o tempo do comando. A consulta interrompida termina com o erro 1317 do
    /// servidor, que o chamador trata como cancelamento.
    public func cancelRunningQuery() async {
        guard let id = serverConnectionID.withLock({ $0 }) else { return }
        let helper = MySQLDriver(config: config)
        guard (try? await helper.connect()) != nil else { return }
        _ = try? await helper.execute("KILL QUERY \(id)")
        await helper.disconnect()
    }

    public func disconnect() async {
        lock.withLock { $0 = false }
        if let connection {
            try? await connection.close().get()
        }
        connection = nil
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        eventLoopGroup = nil
    }

    public func databases() async throws -> [String] {
        let result = try await query("SHOW DATABASES")
        return result.rows.map { $0.first?.display ?? "" }.filter { !$0.isEmpty }
    }

    public func tables() async throws -> [DatabaseTable] {
        let result = try await query("SHOW FULL TABLES")
        return result.rows.map { row in
            let kind = (row.count > 1 ? row[1].display : "table").lowercased().contains("view") ? "view" : "table"
            return DatabaseTable(
                name: row.first?.display ?? "",
                kind: kind
            )
        }
    }

    /// `SHOW FULL COLUMNS` em vez de `information_schema.columns`: uma única consulta
    /// resolve nome/tipo/null/default/extra **e** a chave primária (coluna `Key = PRI`),
    /// e é lookup direto no dicionário de dados — o `information_schema` faz varredura de
    /// catálogo e chega a levar segundos em servidores com milhares de tabelas.
    public func columns(table: String) async throws -> [DatabaseColumn] {
        let result = try await query("SHOW FULL COLUMNS FROM \(quoteIdentifier(table))")
        let index = Self.columnIndex(in: result)
        return result.rows.enumerated().map { position, row in
            let value: (String) -> String = { key in
                guard let column = index[key], column < row.count else { return "" }
                return row[column].display
            }
            let extra = value("extra")
            return DatabaseColumn(
                name: value("field"),
                type: value("type"),
                isNullable: value("null") != "NO",
                isPrimaryKey: value("key") == "PRI",
                defaultValue: Self.normalizeDefault(value("default"), extra: extra),
                ordinal: position + 1,
                // "VIRTUAL GENERATED"/"STORED GENERATED" — cuidado: "DEFAULT_GENERATED"
                // (default de expressão) também contém a palavra e NÃO é coluna gerada.
                isGenerated: extra.localizedCaseInsensitiveContains("VIRTUAL GENERATED")
                    || extra.localizedCaseInsensitiveContains("STORED GENERATED")
            )
        }
    }

    /// Mapa `nome minúsculo da coluna → índice`, para ler resultados de `SHOW` por nome.
    /// A ordem das colunas do `SHOW` varia entre versões do MySQL/MariaDB; ler por
    /// posição fixa é o tipo de coisa que quebra em produção e não no desenvolvimento.
    private static func columnIndex(in result: QueryResult) -> [String: Int] {
        var index: [String: Int] = [:]
        for (position, name) in result.columns.enumerated() {
            index[name.lowercased()] = position
        }
        return index
    }

    /// `information_schema.COLUMN_DEFAULT` devolve literais SEM aspas ("abc" para DEFAULT 'abc').
    /// Reconstrói uma expressão SQL válida — senão um ALTER que re-emite o default quebra com 1064.
    private static func normalizeDefault(_ raw: String, extra: String) -> String? {
        guard !raw.isEmpty, raw != "NULL" else { return nil }
        // Defaults de expressão (MySQL 8.0.13+) vêm marcados em EXTRA e exigem parênteses no DDL.
        if extra.localizedCaseInsensitiveContains("DEFAULT_GENERATED") { return "(\(raw))" }
        let upper = raw.uppercased()
        if upper.hasPrefix("CURRENT_TIMESTAMP") { return raw }
        if upper.hasPrefix("B'") || upper.hasPrefix("X'") || raw.hasPrefix("'") { return raw }
        if Int64(raw) != nil || Double(raw) != nil { return raw }
        return "'\(raw.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// `SHOW KEYS` em vez de `information_schema.key_column_usage` — mesmo motivo do
    /// `columns()`, e `Seq_in_index` preserva a ordem real de uma PK composta (a coluna
    /// `Key = PRI` do `SHOW COLUMNS` viria só na ordem de declaração das colunas).
    public func primaryKeys(table: String) async throws -> [String] {
        let result = try await query("SHOW KEYS FROM \(quoteIdentifier(table)) WHERE Key_name = 'PRIMARY'")
        let index = Self.columnIndex(in: result)
        guard let nameColumn = index["column_name"] else { return [] }
        let sequenceColumn = index["seq_in_index"]
        return result.rows
            .compactMap { row -> (Int, String)? in
                guard nameColumn < row.count else { return nil }
                let name = row[nameColumn].display
                guard !name.isEmpty else { return nil }
                let sequence = sequenceColumn.flatMap { $0 < row.count ? Int(row[$0].display) : nil } ?? 0
                return (sequence, name)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Total de linhas via `SHOW TABLE STATUS`. Em InnoDB `Rows` é ESTIMATIVA (vem das
    /// estatísticas do índice) e custa ~0 ms; o `COUNT(*)` exato é varredura completa e
    /// só vale a pena em tabela pequena — o limiar de 5 MiB é o mesmo do Sequel Ace.
    public func rowCount(table: String, allowExactScan: Bool) async throws -> RowCountEstimate {
        let safeName = table.replacingOccurrences(of: "'", with: "''")
        let status = try await query("SHOW TABLE STATUS WHERE Name = '\(safeName)'")
        let index = Self.columnIndex(in: status)
        let field: (String) -> Int? = { key in
            guard let column = index[key], let row = status.rows.first, column < row.count else { return nil }
            switch row[column] {
            case .int(let value): return Int(value)
            case .text(let value): return Int(value)
            default: return nil
            }
        }
        let estimate = field("rows")
        let dataLength = field("data_length")

        // `Data_length` ausente = objeto sem estatística de tamanho (view, tabela de
        // engine exótico). Aí NÃO se assume que o COUNT(*) é barato: uma view sobre
        // milhões de linhas é exatamente o caso que trava a abertura. Fica desconhecido
        // até o usuário pedir a contagem.
        let isCheap = dataLength.map { $0 < Self.exactRowCountByteBoundary } ?? false
        if allowExactScan || isCheap, let exact = try? await countRows(table: table) {
            return RowCountEstimate(value: exact, isEstimate: false)
        }
        guard let estimate else { return .unknown }
        return RowCountEstimate(value: estimate, isEstimate: true)
    }

    /// Acima disto o COUNT(*) deixa de ser barato e a estimativa passa a valer mais que
    /// a exatidão (5 MiB de dados — o `TableRowCountCheapSizeBoundary` do Sequel Ace).
    private static let exactRowCountByteBoundary = 5 * 1024 * 1024

    /// Usa `simpleQuery` (COM_QUERY, protocolo de TEXTO) em vez de `query`. O `query` do
    /// MySQLNIO é statement preparado: COM_STMT_PREPARE + COM_STMT_EXECUTE + COM_STMT_CLOSE,
    /// **três** idas ao servidor por consulta. Abrir uma tabela dispara várias consultas —
    /// num banco remoto isso era a maior parte do tempo antes de qualquer linha chegar.
    /// A decodificação já era agnóstica de formato (`SQLValue(mysqlData:)` recebe
    /// `row.format`), então o resultado é idêntico.
    public func query(_ sql: String, previewLimit: Int?) async throws -> QueryResult {
        guard let connection else { throw DriverError.notConnected }
        do {
            let mysqlRows = try await connection.simpleQuery(sql).get()
            let columnNames = mysqlRows.first?.columnDefinitions.map(\.name) ?? []
            return QueryResult(
                columns: columnNames,
                rows: mysqlRows.map { Self.decode(row: $0, previewLimit: previewLimit) }
            )
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }

    public func streamQuery(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws {
        guard let connection else { throw DriverError.notConnected }
        // O onRow do MySQLNIO é @escaping e roda no event loop: o acumulador precisa
        // viver fora do frame async. As chamadas são seriais (uma thread só).
        final class Accumulator: @unchecked Sendable {
            var columns: [String] = []
            var rows: [[SQLValue]] = []
            var failure: (any Error)?
        }
        let accumulator = Accumulator()
        do {
            // `simpleQuery` não tem variante que propague erro do onRow, então o erro do
            // consumidor fica guardado e é relançado no fim — o result set continua sendo
            // drenado, que é o que mantém a conexão utilizável.
            try await connection.simpleQuery(sql, onRow: { row in
                if accumulator.failure != nil { return }
                if accumulator.columns.isEmpty {
                    accumulator.columns = row.columnDefinitions.map(\.name)
                }
                accumulator.rows.append(Self.decode(row: row, previewLimit: previewLimit))
                if accumulator.rows.count >= batchSize {
                    let batch = RowBatch(columns: accumulator.columns, rows: accumulator.rows)
                    accumulator.rows.removeAll(keepingCapacity: true)
                    do {
                        try onBatch(batch)
                    } catch {
                        accumulator.failure = error
                    }
                }
            }).get()
        } catch {
            throw error as? CancellationError ?? DriverError.queryFailed(String(describing: error))
        }
        if let failure = accumulator.failure { throw failure }
        if !accumulator.rows.isEmpty {
            try onBatch(RowBatch(columns: accumulator.columns, rows: accumulator.rows))
        }
    }

    /// Decodifica por POSIÇÃO. `MySQLRow.column(_:)` faz busca linear por nome a cada
    /// célula — O(colunas²) por linha, e ainda descarta colunas homônimas de um JOIN.
    private static func decode(row: MySQLRow, previewLimit: Int?) -> [SQLValue] {
        zip(row.columnDefinitions, row.values).map { definition, buffer in
            // O corte é feito NO BUFFER, antes de decodificar: decodificar e depois cortar
            // ainda alocaria a String de 2 MB — exatamente o custo que se quer evitar.
            var effective = buffer
            var fullByteCount: Int?
            if let previewLimit, let raw = buffer,
               raw.readableBytes > previewLimit,
               Self.isLargeValueType(definition.columnType) {
                fullByteCount = raw.readableBytes
                effective = utf8SafePrefix(raw, limit: previewLimit)
            }
            let value = SQLValue(mysqlData: MySQLData(
                type: definition.columnType,
                format: row.format,
                buffer: effective,
                isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
            ))
            guard let fullByteCount else { return value }
            switch value {
            case .text(let prefix):
                return .truncated(prefix: prefix, byteCount: fullByteCount, isBinary: false)
            case .blob:
                return .truncated(prefix: "", byteCount: fullByteCount, isBinary: true)
            default:
                return value
            }
        }
    }

    /// Tipos cujo payload pode ser arbitrariamente grande. Cortar o buffer de um
    /// datetime/decimal seria corromper o valor — e eles nunca chegam perto do limite.
    private static func isLargeValueType(_ type: MySQLProtocol.DataType) -> Bool {
        switch type {
        case .string, .varchar, .varString, .blob, .tinyBlob, .mediumBlob, .longBlob,
             .json, .geometry, .enum, .set:
            return true
        default:
            return false
        }
    }


    /// Usa o protocolo de TEXTO (não prepara statement). Comandos de sessão que o
    /// import precisa — `SET NAMES`, `USE`, `LOCK TABLES` — não podem ser preparados,
    /// e evitar o par prepare/close por statement acelera bastante restaurar um dump.
    public func execute(_ sql: String) async throws -> Int {
        guard let connection else { throw DriverError.notConnected }
        do {
            try await connection.simpleQuery(sql) { _ in }.get()
            return 0
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }
}

extension SQLValue {
    /// Decodifica pelo TIPO declarado da coluna, nunca por tentativa em cascata.
    /// Acessores genéricos corrompem strings: `.uuid` transforma qualquer valor de
    /// 16 bytes em UUID ("acao_responsavel" virava "6163616F-…") e `Decimal(string:)`
    /// aceita prefixo numérico ("0_tabela" virava "0") — nomes de tabela quebravam.
    init(mysqlData: MySQLData?) {
        guard let data = mysqlData, data.buffer != nil else {
            self = .null
            return
        }
        switch data.type {
        case .null:
            self = .null
        case .tiny, .short, .long, .int24, .longlong:
            if data.isUnsigned {
                if let uint = data.uint64 {
                    self = uint <= UInt64(Int64.max) ? .int(Int64(uint)) : .text(String(uint))
                } else {
                    self = .text(Self.utf8String(data) ?? "")
                }
            } else if let int64 = data.int64 {
                self = .int(int64)
            } else {
                self = .text(Self.utf8String(data) ?? "")
            }
        case .year:
            // YEAR não é coberto pelos acessores inteiros: texto = dígitos, binário = LE.
            if let text = Self.utf8String(data), let int64 = Int64(text) {
                self = .int(int64)
            } else {
                var value: UInt64 = 0
                for (index, byte) in Self.rawBytes(data).enumerated() where index < 8 {
                    value |= UInt64(byte) << (8 * index)
                }
                self = .int(Int64(value))
            }
        case .float, .double:
            if let double = data.double {
                self = .double(double)
            } else {
                self = .text(Self.utf8String(data) ?? "")
            }
        case .decimal, .newdecimal:
            // Preserva a precisão exata como texto (Decimal(string:) trunca/parseia prefixo).
            self = .text(Self.utf8String(data) ?? "")
        case .date, .newdate, .timestamp, .datetime, .timestamp2, .datetime2, .time, .time2:
            // Protocolo de TEXTO: o payload JÁ é a representação nativa do MySQL
            // ("2024-01-31 12:34:56[.ffffff]"). Reconstruí-la via MySQLTime → Date
            // (Calendar) → DateFormatter custava microssegundos POR CÉLULA — num dump de
            // milhões de linhas com colunas timestamp, isso eram MINUTOS — e ainda
            // descartava os fracionários. A string crua é fiel e de graça.
            if data.format == .text {
                self = .text(Self.utf8String(data) ?? "")
                return
            }
            // Binário (statements preparados): chega estruturado e precisa ser formatado.
            // Sem o "Z" do ISO: o servidor rejeita "…Z" em modo estrito, o que quebrava
            // o re-import dos dumps.
            switch data.type {
            case .date, .newdate:
                if let date = data.date {
                    self = .text(mysqlDateOnlyFormatter.string(from: date))
                } else {
                    self = .text(Self.utf8String(data) ?? "")
                }
            case .time, .time2:
                if let time = data.time {
                    self = .text(String(describing: time))
                } else {
                    self = .text(Self.utf8String(data) ?? "")
                }
            default:
                if let date = data.date {
                    self = .text(mysqlDateTimeFormatter.string(from: date))
                } else {
                    self = .text(Self.utf8String(data) ?? "")
                }
            }
        case .bit:
            // BIT(n) chega como bytes big-endian; os acessores inteiros leem só 1 byte.
            let bytes = Self.rawBytes(data)
            var value: UInt64 = 0
            if bytes.count <= 8 {
                for byte in bytes { value = value << 8 | UInt64(byte) }
                self = value <= UInt64(Int64.max) ? .int(Int64(value)) : .text(String(value))
            } else {
                self = .text("0x" + bytes.map { String(format: "%02X", $0) }.joined())
            }
        default:
            // varchar/varString/string/enum/set/json/blobs/geometry: texto quando o
            // payload é UTF-8 válido; caso contrário, blob binário de verdade.
            let bytes = Self.rawBytes(data)
            if let text = String(data: bytes, encoding: .utf8) {
                self = .text(text)
            } else {
                self = .blob(bytes)
            }
        }
    }

    private static func rawBytes(_ data: MySQLData) -> Data {
        guard let buffer = data.buffer else { return Data() }
        return Data(buffer.readableBytesView)
    }

    private static func utf8String(_ data: MySQLData) -> String? {
        String(data: rawBytes(data), encoding: .utf8)
    }
}
