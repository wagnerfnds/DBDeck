import Foundation
import PostgresNIO
import NIOSSL
import os

public final class PostgresDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: SQLEngine = .postgres

    private let config: ConnectionConfig
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    private let lock = OSAllocatedUnfairLock(initialState: false)

    public init(config: ConnectionConfig) {
        self.config = config
    }

    public var isConnected: Bool {
        lock.withLock { $0 }
    }

    /// Banco em que a conexão realmente abriu (pode não ser o do config quando ele vem vazio).
    public private(set) var openDatabase: String = ""

    /// TLS do NIO compartilhado pelas duas configurações do PostgresNIO (pool e conexão avulsa).
    private var tlsConfiguration: NIOSSL.TLSConfiguration? {
        guard config.useTLS else { return nil }
        var clientTLS = NIOSSL.TLSConfiguration.makeClientConfiguration()
        // Bancos gerenciados usam CA próprio: não verifica o certificado.
        clientTLS.certificateVerification = .none
        return clientTLS
    }

    /// Bancos a tentar quando a conexão não fixa um. `postgres` existe em quase todo
    /// servidor, mas hospedagens com `pg_hba.conf` restrito liberam só o banco do
    /// próprio usuário — aí a segunda tentativa é o que salva a conexão remota.
    private var candidateDatabases: [String] {
        let chosen = config.database.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return [chosen] }
        var candidates = ["postgres"]
        if !config.username.isEmpty && config.username != "postgres" {
            candidates.append(config.username)
        }
        return candidates
    }

    public func connect() async throws {
        var lastError: (any Error)?
        for database in candidateDatabases {
            do {
                try await open(database: database)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DriverError.queryFailed("Não foi possível conectar ao servidor.")
    }

    private func open(database: String) async throws {
        let clientConfig = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: database,
            tls: tlsConfiguration.map { .prefer($0) } ?? .disable
        )
        let client = PostgresClient(configuration: clientConfig)
        let task = Task { await client.run() }
        do {
            _ = try await client.query(PostgresQuery(unsafeSQL: "SELECT 1"))
        } catch {
            task.cancel()
            await task.value
            throw await diagnose(error, database: database)
        }
        runTask = task
        self.client = client
        openDatabase = database
        lock.withLock { $0 = true }
    }

    /// O pool do `PostgresClient` engole o erro do servidor e devolve
    /// `connectionCreationCircuitBreakerTripped` — que vira "The operation couldn't be
    /// completed" na tela e não diz nada. Refaz um handshake avulso só para recuperar a
    /// mensagem real (ex.: "no pg_hba.conf entry for host ..., database ...").
    private func diagnose(_ error: any Error, database: String) async -> any Error {
        if error is PSQLError { return DriverError.queryFailed(Self.describe(error)) }
        // A conexão avulsa quer um NIOSSLContext pronto (o pool aceita a TLSConfiguration crua).
        let connectionTLS: PostgresConnection.Configuration.TLS
        if let tlsConfiguration, let context = try? NIOSSLContext(configuration: tlsConfiguration) {
            connectionTLS = .prefer(context)
        } else {
            connectionTLS = .disable
        }
        let connectionConfig = PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: database,
            tls: connectionTLS
        )
        var logger = Logger(label: "dbdeck.postgres")
        logger.logLevel = .critical
        do {
            let connection = try await PostgresConnection.connect(
                configuration: connectionConfig,
                id: 0,
                logger: logger
            )
            try? await connection.close()
            // O handshake avulso passou: o erro do pool era transitório, mostra o que veio.
            return DriverError.queryFailed(Self.describe(error))
        } catch {
            return DriverError.queryFailed(Self.describe(error))
        }
    }

    public func disconnect() async {
        lock.withLock { $0 = false }
        runTask?.cancel()
        await runTask?.value
        runTask = nil
        client = nil
    }

    public func databases() async throws -> [String] {
        // Só os bancos em que este usuário consegue entrar: listar os demais leva a
        // "no pg_hba.conf entry"/"permission denied" ao clicar neles.
        let result = try await query(
            """
            SELECT datname FROM pg_database
            WHERE datistemplate = FALSE
              AND datallowconn
              AND has_database_privilege(current_user, datname, 'CONNECT')
            ORDER BY datname
            """
        )
        return result.rows.compactMap { row in
            if case .text(let name) = row.first {
                return name
            }
            return nil
        }
    }

    public func tables() async throws -> [DatabaseTable] {
        let result = try await query(
            """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = current_schema()
            ORDER BY table_name
            """
        )
        return result.rows.map { row in
            let kind = (row.count > 1 ? row[1].display : "table").lowercased().contains("view") ? "view" : "table"
            return DatabaseTable(
                name: row.count > 0 ? row[0].display : "",
                kind: kind
            )
        }
    }

    public func columns(table: String) async throws -> [DatabaseColumn] {
        let safeName = table.replacingOccurrences(of: "'", with: "''")
        let result = try await query(
            """
            SELECT column_name, data_type, is_nullable, column_default, ordinal_position, is_generated
            FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = '\(safeName)'
            ORDER BY ordinal_position
            """
        )
        let pks = Set(try await primaryKeys(table: table))
        return result.rows.map { row in
            DatabaseColumn(
                name: row.count > 0 ? row[0].display : "",
                type: row.count > 1 ? row[1].display : "",
                isNullable: row.count > 2 ? row[2].display != "NO" : true,
                isPrimaryKey: row.count > 0 ? pks.contains(row[0].display) : false,
                defaultValue: row.count > 3 && !row[3].display.isEmpty ? row[3].display : nil,
                ordinal: row.count > 4 ? (Int(row[4].display) ?? 0) : 0,
                isGenerated: row.count > 5 && row[5].display == "ALWAYS"
            )
        }
    }

    public func primaryKeys(table: String) async throws -> [String] {
        let safeName = table.replacingOccurrences(of: "\"", with: "\"\"")
        let result = try await query(
            """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = '"\(safeName)"'::regclass AND i.indisprimary
            ORDER BY array_position(i.indkey, a.attnum)
            """
        )
        return result.rows.compactMap { row in
            if case .text(let name) = row.first {
                return name
            }
            return nil
        }
    }

    public func query(_ sql: String, previewLimit: Int?) async throws -> QueryResult {
        guard let client else { throw DriverError.notConnected }
        do {
            let sequence = try await client.query(PostgresQuery(unsafeSQL: sql))
            let columnNames = sequence.columns.map(\.name)
            var rows: [[SQLValue]] = []
            for try await row in sequence {
                rows.append(Self.decode(row: row, columns: columnNames.count, previewLimit: previewLimit))
            }
            return QueryResult(columns: columnNames, rows: rows)
        } catch {
            // Cancelamento não é falha: precisa atravessar sem virar queryFailed, senão
            // quem cancela (ex.: exportação de dump) não reconhece e trata como erro.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw DriverError.queryFailed(Self.describe(error))
        }
    }

    public func streamQuery(
        _ sql: String,
        batchSize: Int,
        previewLimit: Int?,
        onBatch: @escaping @Sendable (RowBatch) throws -> Void
    ) async throws {
        guard let client else { throw DriverError.notConnected }
        do {
            let sequence = try await client.query(PostgresQuery(unsafeSQL: sql))
            let columnNames = sequence.columns.map(\.name)
            var buffer: [[SQLValue]] = []
            buffer.reserveCapacity(batchSize)
            for try await row in sequence {
                buffer.append(Self.decode(row: row, columns: columnNames.count, previewLimit: previewLimit))
                if buffer.count >= batchSize {
                    try onBatch(RowBatch(columns: columnNames, rows: buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try onBatch(RowBatch(columns: columnNames, rows: buffer))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is DriverError || error is DumpError { throw error }
            throw DriverError.queryFailed(Self.describe(error))
        }
    }

    public func execute(_ sql: String) async throws -> Int {
        guard let client else { throw DriverError.notConnected }
        do {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql))
            return 0
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw DriverError.queryFailed(Self.describe(error))
        }
    }

    /// Decodifica por POSIÇÃO. A leitura por NOME (`makeRandomAccess()[nome]`) devolve
    /// sempre a MESMA célula para colunas homônimas — e consultas de catálogo com vários
    /// `COALESCE(...)` (ou um JOIN com colunas de mesmo nome) recebiam o valor errado
    /// em todas as posições repetidas.
    private static func decode(row: PostgresRow, columns: Int, previewLimit: Int?) -> [SQLValue] {
        let randomRow = row.makeRandomAccess()
        return (0..<min(columns, randomRow.count)).map {
            SQLValue(postgresCell: randomRow[$0], previewLimit: previewLimit)
        }
    }

    /// Total de linhas via `pg_class.reltuples` — a estimativa que o planner usa, mantida
    /// pelo autovacuum e lida em O(1). O `COUNT(*)` do Postgres é sempre varredura completa
    /// (não há contador de linhas por causa do MVCC), então só é usado em tabela pequena.
    public func rowCount(table: String, allowExactScan: Bool) async throws -> RowCountEstimate {
        let safeName = table.replacingOccurrences(of: "\"", with: "\"\"")
        let result = try? await query(
            """
            SELECT c.reltuples::bigint, pg_total_relation_size(c.oid), c.relkind
            FROM pg_class c WHERE c.oid = '"\(safeName)"'::regclass
            """
        )
        let number: (Int) -> Int? = { position in
            guard let row = result?.rows.first, position < row.count else { return nil }
            switch row[position] {
            case .int(let value): return Int(value)
            case .text(let value): return Int(value)
            default: return nil
            }
        }
        // reltuples é -1 quando a relação nunca passou por ANALYZE (PG 14+): a estimativa
        // não vale nada. 0 é aceito — tabela vazia de verdade existe.
        let estimate = number(0).flatMap { $0 >= 0 ? $0 : nil }
        let totalSize = number(1)
        // Só relações COM armazenamento próprio têm tamanho: view comum ('v') sempre
        // reporta 0, e tratar isso como "tabela pequena" mandaria um COUNT(*) numa view
        // sobre milhões de linhas — exatamente o que se quer evitar na abertura.
        let isStored = ["r", "m", "p", "t", "f"].contains(result?.rows.first?.last?.display ?? "")

        let isCheap = isStored && (totalSize ?? Int.max) < Self.exactRowCountByteBoundary
        if allowExactScan || isCheap, let exact = try? await countRows(table: table) {
            return RowCountEstimate(value: exact, isEstimate: false)
        }
        guard let estimate else { return .unknown }
        return RowCountEstimate(value: estimate, isEstimate: true)
    }

    private static let exactRowCountByteBoundary = 5 * 1024 * 1024

    /// `PSQLError.description` é deliberadamente vago ("Generic description to prevent
    /// accidental leakage of sensitive data") — inútil numa caixa de erro. A descrição
    /// reflexiva traz a mensagem real do servidor, que é o que o usuário precisa ver.
    private static func describe(_ error: any Error) -> String {
        if let psqlError = error as? PSQLError {
            if let message = psqlError.serverInfo?[.message] {
                if let detail = psqlError.serverInfo?[.detail], !detail.isEmpty {
                    return "\(message)\n\(detail)"
                }
                return message
            }
            // Erro de transporte/handshake: o `underlying` (recusa de conexão, timeout,
            // falha de TLS) diz muito mais que o código genérico do PSQLError.
            if let underlying = psqlError.underlying {
                return "\(psqlError.code): \(underlying.localizedDescription)"
            }
            return "\(psqlError.code)"
        }
        if let ioError = error as? IOError {
            return ioError.localizedDescription
        }
        return String(reflecting: error)
    }
}

extension SQLValue {
    /// Decodifica pelo TIPO declarado da coluna, nunca por tentativa em cascata.
    ///
    /// A cascata anterior (`try? decode(Bool)` → `Int64` → … → `Data` → `String`)
    /// classificava como `Data` todo tipo sem decoder registrado — inclusive os
    /// domínios do `information_schema` (`sql_identifier`, `character_data`). Na
    /// prática TODA consulta de metadados do Postgres devolvia "‹blob›" no lugar dos
    /// nomes de tabelas e colunas.
    /// Variante com corte na origem para o grid: valores acima de `previewLimit` bytes
    /// param no prefixo e nunca viram String inteira. Ver `SQLValue.truncated`.
    init(postgresCell cell: PostgresCell, previewLimit: Int?) {
        if let previewLimit,
           let buffer = cell.bytes,
           buffer.readableBytes > previewLimit,
           Self.isLargePostgresType(cell.dataType) {
            let fullByteCount = buffer.readableBytes
            // Binário não tem prefixo legível para mostrar — só o tamanho.
            if cell.dataType == .bytea {
                self = .truncated(prefix: "", byteCount: fullByteCount, isBinary: true)
                return
            }
            var body = buffer
            // Mesmo ajuste do caminho normal: o jsonb binário carrega um byte de versão.
            if cell.dataType == .jsonb, cell.format == .binary,
               body.getInteger(at: body.readerIndex, as: UInt8.self) == 1 {
                body.moveReaderIndex(forwardBy: 1)
            }
            if case .text(let prefix) = Self.textOrBlob(utf8SafePrefix(body, limit: previewLimit)) {
                self = .truncated(prefix: prefix, byteCount: fullByteCount, isBinary: false)
            } else {
                self = .truncated(prefix: "", byteCount: fullByteCount, isBinary: true)
            }
            return
        }
        self.init(postgresCell: cell)
    }

    /// Tipos cujo payload pode ser arbitrariamente grande. Cortar o buffer de um numeric
    /// ou timestamp binário seria corromper o valor — e eles nunca chegam perto do limite.
    private static func isLargePostgresType(_ type: PostgresDataType) -> Bool {
        switch type {
        case .text, .varchar, .bpchar, .name, .json, .jsonb, .xml, .bytea: return true
        default: return false
        }
    }

    init(postgresCell cell: PostgresCell) {
        guard let buffer = cell.bytes else {
            self = .null
            return
        }
        switch cell.dataType {
        case .bool:
            if let value = try? cell.decode(Bool.self) { self = .bool(value); return }
        case .int2, .int4, .int8, .oid, .regproc:
            if let value = try? cell.decode(Int64.self) { self = .int(value); return }
        case .float4, .float8:
            if let value = try? cell.decode(Double.self) { self = .double(value); return }
        case .numeric:
            // Texto preserva a precisão exata (Double arredondaria valores monetários).
            // Via `Decimal` a escala se perde — 203080756.00 vira "203080756"; a
            // representação nativa do numeric guarda o dscale.
            let data = PostgresData(type: .numeric, formatCode: cell.format, value: buffer)
            if let numeric = data.numeric { self = .text(numeric.string); return }
            if let value = try? cell.decode(Decimal.self) { self = .text("\(value)"); return }
        case .bytea:
            if let value = try? cell.decode(Data.self) { self = .blob(value); return }
        case .uuid:
            if let value = try? cell.decode(UUID.self) { self = .text(value.uuidString); return }
        case .date:
            if let value = try? cell.decode(Date.self) {
                self = .text(mysqlDateOnlyFormatter.string(from: value))
                return
            }
        case .timestamp, .timestamptz:
            if let value = try? cell.decode(Date.self) {
                self = .text(postgresTimestampFormatter.string(from: value))
                return
            }
        case .jsonb:
            // O formato binário do jsonb carrega um byte de versão antes do JSON.
            var body = buffer
            if cell.format == .binary, body.getInteger(at: body.readerIndex, as: UInt8.self) == 1 {
                body.moveReaderIndex(forwardBy: 1)
            }
            self = Self.textOrBlob(body)
            return
        default:
            break
        }
        // Tipos textuais (text/varchar/name/char/enum/json/xml/domínios) chegam como
        // UTF-8 puro nos dois formatos; o que não for UTF-8 válido é binário de verdade.
        self = Self.textOrBlob(buffer)
    }

    private static func textOrBlob(_ buffer: ByteBuffer) -> SQLValue {
        let bytes = Data(buffer.readableBytesView)
        if let text = String(data: bytes, encoding: .utf8) { return .text(text) }
        return .blob(bytes)
    }
}
