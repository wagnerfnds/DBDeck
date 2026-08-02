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
            let database = config.database.isEmpty ? config.username : config.database
            let tls: NIOSSL.TLSConfiguration? = config.useTLS
                ? NIOSSL.TLSConfiguration.makeClientConfiguration()
                : nil
            let conn = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: database,
                password: config.password,
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
            DatabaseTable(
                name: row.first?.display ?? "",
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
            WHERE table_schema = DATABASE() AND table_name = '\(safeName)'
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
        let safeName = table.replacingOccurrences(of: "'", with: "''")
        let result = try await query(
            """
            SELECT column_name
            FROM information_schema.key_column_usage
            WHERE table_schema = DATABASE() AND table_name = '\(safeName)' AND constraint_name = 'PRIMARY'
            ORDER BY ordinal_position
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
        guard let connection else { throw DriverError.notConnected }
        do {
            let mysqlRows = try await connection.query(sql).get()
            let columnNames = mysqlRows.first?.columnDefinitions.map(\.name) ?? []
            let rows = mysqlRows.map { row in
                row.columnDefinitions.map { SQLValue(mysqlData: row.column($0.name)) }
            }
            return QueryResult(columns: columnNames, rows: rows)
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String) async throws -> Int {
        guard let connection else { throw DriverError.notConnected }
        do {
            _ = try await connection.query(sql).get()
            return 0
        } catch {
            throw DriverError.queryFailed(String(describing: error))
        }
    }
}

extension SQLValue {
    init(mysqlData: MySQLData?) {
        guard let data = mysqlData else {
            self = .null
            return
        }
        if let bool = data.bool {
            self = .bool(bool)
        } else if let double = data.double {
            self = .double(double)
        } else if let float = data.float {
            self = .double(Double(float))
        } else if let int64 = data.int64 {
            self = .int(int64)
        } else if let int = data.int {
            self = .int(Int64(int))
        } else if let decimal = data.decimal {
            self = .text("\(decimal)")
        } else if let uuid = data.uuid {
            self = .text(uuid.uuidString)
        } else if let date = data.date {
            self = .text(dbISOFormatter.string(from: date))
        } else if let time = data.time {
            self = .text(String(describing: time))
        } else if let string = data.string {
            self = .text(string)
        } else {
            self = .text(data.description)
        }
    }
}
