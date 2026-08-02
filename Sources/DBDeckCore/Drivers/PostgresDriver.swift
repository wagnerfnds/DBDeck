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

    public func connect() async throws {
        let tls: PostgresClient.Configuration.TLS
        if config.useTLS {
            tls = .prefer(NIOSSL.TLSConfiguration.makeClientConfiguration())
        } else {
            tls = .disable
        }
        let clientConfig = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        let client = PostgresClient(configuration: clientConfig)
        runTask = Task { await client.run() }
        _ = try await client.query(PostgresQuery(unsafeSQL: "SELECT 1"))
        self.client = client
        lock.withLock { $0 = true }
    }

    public func disconnect() async {
        lock.withLock { $0 = false }
        runTask?.cancel()
        await runTask?.value
        runTask = nil
        client = nil
    }

    public func databases() async throws -> [String] {
        let result = try await query(
            "SELECT datname FROM pg_database WHERE datistemplate = FALSE ORDER BY datname"
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
            DatabaseTable(
                name: row.count > 0 ? row[0].display : "",
                kind: row.count > 1 ? row[1].display : "table"
            )
        }
    }

    public func columns(table: String) async throws -> [DatabaseColumn] {
        let safeName = table.replacingOccurrences(of: "'", with: "''")
        let result = try await query(
            """
            SELECT column_name, data_type, is_nullable, column_default, ordinal_position
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
                ordinal: row.count > 4 ? (Int(row[4].display) ?? 0) : 0
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

    public func query(_ sql: String) async throws -> QueryResult {
        guard let client else { throw DriverError.notConnected }
        do {
            let sequence = try await client.query(PostgresQuery(unsafeSQL: sql))
            let columnNames = sequence.columns.map(\.name)
            var rows: [[SQLValue]] = []
            for try await row in sequence {
                let randomRow = row.makeRandomAccess()
                rows.append(columnNames.map { SQLValue(postgresCell: randomRow[$0]) })
            }
            return QueryResult(columns: columnNames, rows: rows)
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String) async throws -> Int {
        guard let client else { throw DriverError.notConnected }
        do {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql))
            return 0
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }
}

extension SQLValue {
    init(postgresCell: PostgresCell) {
        if let value = try? postgresCell.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? postgresCell.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? postgresCell.decode(Int.self) {
            self = .int(Int64(value))
        } else if let value = try? postgresCell.decode(Double.self) {
            self = .double(value)
        } else if let value = try? postgresCell.decode(Data.self) {
            self = .blob(value)
        } else if let value = try? postgresCell.decode(UUID.self) {
            self = .text(value.uuidString)
        } else if let value = try? postgresCell.decode(Date.self) {
            self = .text(dbISOFormatter.string(from: value))
        } else if let value = try? postgresCell.decode(Decimal.self) {
            self = .text("\(value)")
        } else if let value = try? postgresCell.decode(String.self) {
            self = .text(value)
        } else {
            self = .null
        }
    }
}
