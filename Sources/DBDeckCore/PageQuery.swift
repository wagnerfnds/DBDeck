import Foundation

/// Como localizar a página pedida na listagem de uma tabela.
///
/// `OFFSET` fica caro em tabela grande: o servidor precisa varrer e descartar as N linhas
/// puladas, então a página 5.000 custa milhares de vezes mais que a primeira. Quando há
/// chave primária de coluna única e a ordenação é por ela, a navegação ancora no VALOR da
/// PK (`WHERE pk > ...`), que usa o índice direto — custo igual em qualquer página.
public enum PageCursor: Sendable, Equatable {
    /// `LIMIT n OFFSET k` — usado quando não há âncora possível.
    case absolute(Int)
    /// `pk >= v` — recarrega a MESMA página (⌘R, depois de salvar/excluir).
    case atOrAfter(SQLValue, offset: Int)
    /// `pk > v` — próxima página.
    case after(SQLValue, offset: Int)
    /// `pk < v` lido em ordem invertida; o resultado é revirado antes de exibir.
    case before(SQLValue, offset: Int)

    /// Posição da primeira linha da página no conjunto total (numeração da régua e rótulo).
    public var offset: Int {
        switch self {
        case .absolute(let value): return value
        case .atOrAfter(_, let value), .after(_, let value), .before(_, let value): return value
        }
    }

    public var isKeyset: Bool {
        if case .absolute = self { return false }
        return true
    }
}

public struct PageQuery: Sendable, Equatable {
    public let sql: String
    /// O cursor leu para trás: as linhas precisam ser reviradas antes de exibir.
    public let reversed: Bool

    public init(sql: String, reversed: Bool) {
        self.sql = sql
        self.reversed = reversed
    }
}

/// Monta o SELECT de uma página da listagem de tabela.
public struct PageQueryBuilder: Sendable {
    public var engine: SQLEngine
    public var table: String
    public var columns: [DatabaseColumn]
    public var primaryKeys: [String]
    public var sortColumn: String?
    public var sortAscending: Bool
    /// Cláusula WHERE já montada pela barra de filtros (sem a palavra `WHERE`).
    public var filter: String?
    public var pageSize: Int
    /// Não pedir colunas TEXT/BLOB — elas viram `NULL AS col` e são carregadas sob demanda.
    public var deferBlobs: Bool

    public init(
        engine: SQLEngine,
        table: String,
        columns: [DatabaseColumn] = [],
        primaryKeys: [String] = [],
        sortColumn: String? = nil,
        sortAscending: Bool = true,
        filter: String? = nil,
        pageSize: Int = 1000,
        deferBlobs: Bool = false
    ) {
        self.engine = engine
        self.table = table
        self.columns = columns
        self.primaryKeys = primaryKeys
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.filter = filter
        self.pageSize = pageSize
        self.deferBlobs = deferBlobs
    }

    /// Coluna usável como âncora de keyset: PK de coluna única, sem ordenação explícita
    /// ou ordenada por ela mesma. Fora disso a paginação continua por OFFSET.
    public var keysetColumn: String? {
        guard primaryKeys.count == 1 else { return nil }
        let key = primaryKeys[0]
        guard sortColumn == nil || sortColumn == key else { return nil }
        return key
    }

    /// Índices (em `columns`) das colunas que o SELECT não vai pedir.
    public var deferredColumnIndexes: Set<Int> {
        guard deferBlobs else { return [] }
        return Set(columns.indices.filter { columns[$0].isBlobOrText })
    }

    /// Lista de campos do SELECT. Com `deferBlobs`, colunas TEXT/BLOB viram `NULL AS col`:
    /// o servidor nem lê o valor. É o `LoadBlobsAsNeeded` do Sequel Ace — o alias mantém
    /// os nomes das colunas batendo com `columns`, de que depende o resync pós-ALTER TABLE.
    public func selectList(deferring: Bool? = nil) -> String {
        guard deferring ?? deferBlobs, !columns.isEmpty else { return "*" }
        return columns.map { column in
            let quoted = engine.quote(column.name)
            return column.isBlobOrText ? "NULL AS \(quoted)" : quoted
        }.joined(separator: ", ")
    }

    /// Um cursor de keyset só vale com uma coluna âncora; sem ela a condição seria
    /// descartada e a página voltaria em silêncio para o começo da tabela.
    public func normalize(_ cursor: PageCursor) -> PageCursor {
        if !cursor.isKeyset || keysetColumn != nil { return cursor }
        return .absolute(cursor.offset)
    }

    public func make(cursor requested: PageCursor, deferring: Bool? = nil) -> PageQuery {
        let cursor = normalize(requested)
        var conditions: [String] = []
        if let filter, !filter.isEmpty { conditions.append("(\(filter))") }

        var orderColumn = sortColumn
        var ascending = sortAscending
        var reversed = false

        if let key = keysetColumn {
            // ORDER BY pela PK é forçado mesmo na página absoluta: sem ordem estável, a
            // âncora tirada da última linha desta página não teria relação com a página
            // seguinte — linhas seriam puladas ou repetidas. Em InnoDB isso não muda nada
            // (o índice clusterizado JÁ é essa ordem); no Postgres troca a ordem do heap
            // por uma ordem previsível, que é o comportamento desejável de qualquer forma.
            orderColumn = key
            let quoted = engine.quote(key)
            switch cursor {
            case .absolute:
                break
            case .atOrAfter(let value, _):
                conditions.append("\(quoted) \(sortAscending ? ">=" : "<=") \(value.sqlLiteral(engine: engine))")
            case .after(let value, _):
                conditions.append("\(quoted) \(sortAscending ? ">" : "<") \(value.sqlLiteral(engine: engine))")
            case .before(let value, _):
                conditions.append("\(quoted) \(sortAscending ? "<" : ">") \(value.sqlLiteral(engine: engine))")
                ascending = !sortAscending
                reversed = true
            }
        }

        var sql = "SELECT \(selectList(deferring: deferring)) FROM \(engine.quote(table))"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if let orderColumn {
            sql += " ORDER BY \(engine.quote(orderColumn)) \(ascending ? "ASC" : "DESC")"
        }
        sql += " LIMIT \(pageSize)"
        if case .absolute(let value) = cursor, value > 0 { sql += " OFFSET \(value)" }
        return PageQuery(sql: sql, reversed: reversed)
    }

    /// SELECT de uma única célula, para materializar um valor cortado ou não carregado.
    /// Endereça a linha pela PK; sem PK (tabela somente leitura) cai para a posição.
    public func singleCellQuery(
        column: DatabaseColumn,
        primaryKeyValues: [(column: String, value: SQLValue)],
        absoluteRowIndex: Int
    ) -> String? {
        let field = engine.quote(column.name)
        let from = engine.quote(table)

        if !primaryKeyValues.isEmpty {
            var conditions: [String] = []
            for entry in primaryKeyValues {
                guard !entry.value.isTruncated, entry.value != .null else { return nil }
                conditions.append("\(engine.quote(entry.column)) = \(entry.value.sqlLiteral(engine: engine))")
            }
            return "SELECT \(field) FROM \(from) WHERE \(conditions.joined(separator: " AND ")) LIMIT 1"
        }

        var sql = "SELECT \(field) FROM \(from)"
        if let filter, !filter.isEmpty { sql += " WHERE \(filter)" }
        if let sortColumn {
            sql += " ORDER BY \(engine.quote(sortColumn)) \(sortAscending ? "ASC" : "DESC")"
        } else if let key = keysetColumn {
            // Mesma ordem que `make` impõe — senão a posição não corresponde à da página.
            sql += " ORDER BY \(engine.quote(key)) \(sortAscending ? "ASC" : "DESC")"
        }
        sql += " LIMIT 1 OFFSET \(absoluteRowIndex)"
        return sql
    }
}
