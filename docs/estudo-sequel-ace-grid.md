# Como o Sequel Ace carrega tabelas tão rápido — estudo e comparação com o DBDeck

Fonte: `github.com/Sequel-Ace/Sequel-Ace` (clone raso analisado em 2026-08-23).
Referências no formato `arquivo:linha` apontam para o repositório deles; as do DBDeck estão marcadas com **[DBDeck]**.

---

## 1. Resumo executivo

A velocidade do Sequel Ace **não vem da view**. Vem de três decisões de arquitetura que o DBDeck não tem hoje:

| # | Decisão | Efeito |
|---|---------|--------|
| 1 | **Nunca materializar o resultado como objetos.** As linhas ficam como bytes crus em um bloco de memória por linha; `NSString` só nasce quando a célula visível pede. | Abrir uma página é O(bytes recebidos), não O(células × alocação). |
| 2 | **Pedir só o preview.** A tabela pede `previewLength: 150` — um TEXT de 2 MB nunca vira string inteira para ser desenhado em 200 px. | Custo por célula fica constante, independente do tamanho do dado. |
| 3 | **Nunca bloquear no `COUNT(*)` nem no `information_schema`.** Contagem vem do `SHOW TABLE STATUS` (estimativa do InnoDB) e só vira `COUNT(1)` real se a tabela for pequena. Metadados vêm de `SHOW COLUMNS`. | Abrir uma tabela de 10 M linhas custa o mesmo que abrir uma de 10. |

Some-se a isso o **streaming progressivo** (as primeiras linhas aparecem em ~20 ms, muito antes do fim do download) e uma **NSTableView cell-based** em vez de view-based.

---

## 2. A arquitetura, camada por camada

### 2.1 Rede: `mysql_use_result`, 1 round-trip

`SPMySQLConnection Categories/Querying & Preparation.m:490`

```objc
case SPMySQLResultAsStreamingResultStore:
    mysqlResult = mysql_use_result(mySQLConnection);
    theResult = [[SPMySQLStreamingResultStore alloc] initWithMySQLResult:... ];
```

`mysql_use_result` **não baixa nada** — devolve o handle imediatamente e as linhas são puxadas depois com `mysql_fetch_row`. A conexão fica travada até o fim, mas a UI já pode desenhar.

Note também: é `mysql_query` (protocolo de **texto**), 1 ida-e-volta.

### 2.2 Armazenamento: um `malloc` por linha, zero objetos

`SPMySQLStreamingResultStore.m:668` (`_downloadAllData`, roda em thread própria)

Cada linha vira **um único bloco contíguo** com quatro seções:

```
[1 byte: tamanho do tipo de offset] [offsets de fim de campo] [flags NULL] [bytes crus das células]
```

O tipo do offset é escolhido pelo tamanho da linha — `unsigned char` se a linha ≤ 255 bytes, `short` se ≤ 65535, senão `long` (`SPMySQLStreamingResultStore.m:707-717`). Isso corta memória drasticamente em tabelas estreitas.

```objc
newRowStore = malloc_zone_malloc(storageMallocZone,
    1 + lengthOfMetadata + lengthOfNullRecords + (rowDataLength * sizeOfChar));
newRowStore[0] = sizeOfMetadata;
...
memcpy(newRowStore + dataCopiedLength, theRow[i], fieldLengths[i]);
```

O array de ponteiros de linha dobra de capacidade conforme cresce (`_increaseCapacity`, `:825`), começando em 100, dentro de uma `malloc_zone` própria — o `dealloc` destrói a zona inteira de uma vez em vez de liberar milhões de blocos.

**Custo de baixar uma linha: um `malloc` + N `memcpy`. Nenhum objeto Objective-C.**

### 2.3 Acesso: conversão sob demanda, truncada

`SPMySQLStreamingResultStore.m:336` (`cellPreviewAtRow:column:previewLength:`)

Lê os offsets do bloco (com o `switch` de tipo desenrolado à mão, `:355-390`), acha o ponteiro da célula e só então chama a conversão:

```objc
rawCellDataStart = rowData + ((sizeOfMetadata + sizeOfNullRecord) * numberOfFields) + dataStart;
cellData = SPMySQLResultGetObject(self, rawCellDataStart, dataLength, columnIndex, previewLength);
```

E a conversão respeita o `previewLength` (`SPMySQLResult Categories/Data Conversion.m:114`):

```objc
case SPMySQLResultFieldAsString:
    return _convertStringData(bytes, length, stringEncoding, previewLength);
case SPMySQLResultFieldAsBlob:
    if (previewLength != NSNotFound && previewLength < length) {
        NSMutableData *theData = [NSMutableData dataWithBytes:bytes length:previewLength];
        [theData replaceBytesInRange:NSMakeRange(previewLength - 3, 3) withBytes:"..."];
        return theData;
    }
```

`_convertStringData` (`:258`) faz o corte **contando caracteres, não bytes** — anda pelo UTF-8/UTF-16/CP932 byte a byte para não partir um caractere no meio.

Quem pede o preview é a data source da tabela — `SPTableContent.m:4276`:

```objc
- (id)_contentValueForTableColumn:(NSUInteger)columnIndex row:(NSUInteger)rowIndex asPreview:(BOOL)asPreview
{
    if (asPreview) return SPDataStoragePreviewAtRowAndColumn(tableValues, rowIndex, columnIndex, 150);
    return SPDataStorageObjectAtRowAndColumn(tableValues, rowIndex, columnIndex);
}
```

`asPreview: NO` **só** quando a célula está em edição (`SPTableContent.m:4144`). Ou seja: o valor completo de um JSON/TEXT gigante é lido do buffer uma única vez, quando o usuário clica para editar.

Todos os acessos em loop passam por ponteiros de método cacheados (`SPMySQLResultStorePreviewAtRowAndColumn`, `SPDataStorageObjectAtRowAndColumn` — `SPMySQLStreamingResultStore.h:76-108`), eliminando o `objc_msgSend` do caminho quente.

### 2.4 Proxy editável: `SPDataStorage`

`SPDataStorage.m` — camada fina entre o store imutável e a tabela:

- **Copy-on-write por linha**: linhas editadas vão para um `NSPointerArray editedRows`; o resto continua sendo proxy dos bytes crus (`cellPreviewAtRow:column:previewLength:`, `:179`).
- **Colunas não carregadas**: `setColumnAsUnloaded:` marca um `BOOL*`; a célula devolve o sentinela `SPNotLoaded`, que a tabela desenha como `(not loaded)`.

Isso conecta com a preferência `LoadBlobsAsNeeded` (`SPTableContent.m:3204`, `fieldListForQuery`):

```objc
if (dontLoadTextAndBlobs && [tableDataInstance columnIsBlobOrText:fieldName]) {
    [fields addObject:@"NULL"];   // placeholder — mantém a contagem de colunas
    continue;
}
[fields addObject:[fieldName backtickQuotedString]];
```

Ou seja, o SELECT **nem pede** as colunas BLOB/TEXT — manda `NULL` no lugar para preservar a posição. (Padrão é `false`, mas está lá para tabelas pesadas.)

### 2.5 View: NSTableView **cell-based**

`Source/Interfaces/DBView.xib` — `<tableView identifier="TableContentTableView" ... rowHeight="16" customClass="SPCopyTable">`, **sem** `viewBased="YES"`.

Confirmado pelo protocolo implementado em `SPTableContent.m`: `tableView:objectValueForTableColumn:row:` (`:4120`), `tableView:willDisplayCell:...` (`:4800`), `[column setDataCell:...]` (`:700`) — API exclusivamente cell-based.

Cada célula é um `SPTextAndLinkCell` (um `NSCell`) **compartilhado por coluna**: não há hierarquia de views, nem Auto Layout, nem `NSTextField` por célula. Desenhar 40 linhas × 30 colunas visíveis = 1200 chamadas de `drawWithFrame:`, não 1200 views com constraints.

`rowHeight = 16` (contra 26 no DBDeck) também significa ~60% mais linhas na tela — o que é UX, não performance, mas explica a sensação de "cabe tudo".

### 2.6 Progressão: o timer de 20 ms

`SPTableContent.m:1262` (`initTableLoadTimer`) e `:1290` (`tableLoadUpdate:`)

```objc
tableLoadTimer = [NSTimer scheduledTimerWithTimeInterval:0.02 target:self
                                               selector:@selector(tableLoadUpdate:) repeats:YES];
```

O timer roda na main thread enquanto a thread de download preenche o store. A cada tick:

1. `tableRowsCount = [tableValues count]` — o store devolve `rowDownloadIterator` enquanto baixa (`SPMySQLStreamingResultStore.m:287`), então a contagem cresce sozinha;
2. `[tableContentView noteNumberOfRowsChanged]` — a tabela redesenha com o que já chegou;
3. **a frequência cai sozinha**: intervalo 1 tick → 10 ticks → 25 ticks (`:1332-1340`), para não gastar CPU redesenhando no fim do download.

O autosize de colunas roda **exatamente duas vezes**: no primeiro lote e ao cruzar 200 linhas (`:1325`).

> **O usuário vê linhas em ~20 ms.** É isso que dá a impressão de "instantâneo" mesmo quando o download total leva 2 s.

### 2.7 Largura de coluna: amostragem, não varredura

`SPCopyTable.m:1009` (`autodetectWidthForColumnDefinition:maxRows:`), chamado com `maxRows: 100`:

```objc
if ([tableStorage count] < rowsToCheck) rowStep = 1;
else rowStep = floorf([tableStorage count] / rowsToCheck);
...
id contentString = SPDataStoragePreviewAtRowAndColumn(tableStorage, i, columnIndex, 500);
```

**Amostra ~100 linhas espalhadas** (não as 100 primeiras, e nunca as 1000), com preview de 500 chars. Depois (`autodetectColumnWidths`, `:957`) compara a soma das larguras com a largura visível e **reduz proporcionalmente** só as colunas acima de 200 px (`SP_MAX_CELL_WIDTH_MULTICOLUMN`).

### 2.8 Metadados e contagem: o ponto mais importante

**Metadados** (`SPTableData.m:652`, `:1042`): `SHOW COLUMNS FROM <t>` e `SHOW CREATE TABLE <t>`. Nada de `information_schema`.

**Contagem** (`SPTableContent.m:528`): ao trocar de tabela, `maxNumRows` vem de `[tableDataInstance statusValueForKey:@"Rows"]` — o valor do `SHOW TABLE STATUS LIKE '<t>'` (`SPTableData.m:1200`), que no InnoDB é **estimativa** e custa ~0 ms. É marcado com `maxNumRowsIsEstimate = YES` e a UI mostra `~1.234.567`.

O `COUNT(1)` real só acontece sob condição (`SPTableData.m:1323`, `updateAccurateNumberOfRowsForCurrentTableForcingUpdate:`):

```objc
SPRowCountQueryUsageLevels rowCountLevel = ...;   // padrão: SPRowCountFetchIfCheap (1)
NSInteger rowCountCheapBoundary = 5242880;         // 5 MiB

if (rowCountLevel == SPRowCountFetchNever
    || (rowCountLevel == SPRowCountFetchIfCheap
        && [[self statusValueForKey:@"Data_length"] integerValue] >= rowCountCheapBoundary))
{
    return YES;   // desiste — fica com a estimativa
}
...
SELECT COUNT(1) FROM <t>
```

**Tabela com mais de 5 MiB de dados nunca leva `COUNT(*)` por padrão.**

E quando o resultado não está filtrado nem paginado, nem isso é preciso: a contagem exata é simplesmente o número de linhas que voltou (`SPTableContent.m:3856`).

### 2.9 Paginação

`SPTableContent.m:914`: `LIMIT <offset>,<pageSize>` com `LimitResultsValue = 1000` por padrão (`PreferenceDefaults.plist:164`), `LimitResults = true`.

Aqui **não há mágica** — offset profundo é lento neles também. A diferença é que o custo do offset é o único custo, sem os 3 round-trips e o COUNT em cima.

---

## 3. Onde o DBDeck perde (diagnóstico)

### 3.1 Abrir uma tabela custa ~15 round-trips + um `COUNT(*)`

**[DBDeck]** `Sources/DBDeckApp/Views/TableDataView.swift:479` (`load()`):

```swift
columns = try await driver.columns(table: table)        // information_schema.columns
primaryKeys = try await driver.primaryKeys(table: table) // information_schema.key_column_usage
...
await loadPage(offset: 0, recount: true)                 // SELECT + COUNT(*)
```

E `MySQLDriver.columns(table:)` **[DBDeck]** `Sources/DBDeckCore/Drivers/MySQLDriver.swift:84` chama `primaryKeys()` internamente (`:94`) — ou seja, `key_column_usage` é consultado **duas vezes**.

Pior: cada `driver.query()` **[DBDeck]** `MySQLDriver.swift:141` usa `connection.query(...)` do MySQLNIO, que é **prepared statement**: `COM_STMT_PREPARE` → `COM_STMT_EXECUTE` → `COM_STMT_CLOSE` (`ThirdParty/mysql-nio/Sources/MySQLNIO/MySQLQueryCommand.swift:109,223`). **3 round-trips por consulta.**

Somando para abrir uma tabela:

| Consulta | RTTs |
|---|---|
| `information_schema.columns` | 3 |
| `information_schema.key_column_usage` (dentro de `columns`) | 3 |
| `information_schema.key_column_usage` (de novo, no `load`) | 3 |
| `SELECT * … LIMIT 500` | 3 |
| `SELECT COUNT(*)` | 3 |
| **Total** | **15** |

Contra ~4 do Sequel Ace (`SHOW CREATE TABLE`, `SHOW COLUMNS`, `SHOW TABLE STATUS`, `SELECT`), todos de 1 RTT.

Num banco remoto com 60 ms de latência: **900 ms contra 240 ms**, *antes* de qualquer trabalho de verdade.

### 3.2 `COUNT(*)` sem escapatória

**[DBDeck]** `Sources/DBDeckCore/Drivers/DatabaseDriver.swift:111`:

```swift
func countRows(table: String) async throws -> Int {
    let result = try await query("SELECT COUNT(*) FROM \(quoteIdentifier(table))")
```

Chamado com `recount: true` em **toda** abertura, reload (⌘R), filtro e limpeza de filtro (`TableDataView.swift:491,523,552,567,597,731`).

Em InnoDB isso é varredura completa do índice. Em 5 M linhas: **2 a 20 s** — e é *awaitado* dentro do `loadPage`, então o `isLoading` só cai depois dele.

> Este é, sozinho, o maior fator de "trava por segundos ao abrir a tabela".

### 3.3 Materialização integral de cada célula

**[DBDeck]** `Sources/DBDeckCore/Drivers/MySQLDriver.swift:189` e `:301`:

```swift
private static func decode(row: MySQLRow) -> [SQLValue] {
    zip(row.columnDefinitions, row.values).map { definition, buffer in
        SQLValue(mysqlData: MySQLData(...))
    }
}

private static func rawBytes(_ data: MySQLData) -> Data {
    guard let buffer = data.buffer else { return Data() }
    return Data(buffer.readableBytesView)     // cópia
}
```

Para cada célula de texto: **uma `Data` (cópia) + uma `String` (validação UTF-8 + alocação)**. Para 500 linhas × 60 colunas = 30.000 células = **60.000 alocações** por página — e todo esse trabalho acontece antes de qualquer pixel aparecer.

Se a tabela tem uma coluna `TEXT`/`JSON` com 50 KB por linha, são **25 MB de `String`** construídos para exibir 30 caracteres por célula.

O Sequel Ace nesse cenário faz: 500 `malloc` + `memcpy`, e depois ~40 `NSString` de 150 chars (só as visíveis).

### 3.4 Nada aparece antes do fim

**[DBDeck]** `MySQLDriver.swift:145`: `try await connection.query(sql).get()` — o future só resolve com **todas** as linhas. Depois `rows = result.rows` (`TableDataView.swift:520`) publica tudo de uma vez.

Existe `streamQuery` no protocolo (`DatabaseDriver.swift:50`), mas ele **só é usado no dump**, não no grid.

Não há equivalente do timer de 20 ms: a tela fica com o estado anterior (ou vazia) até o último byte chegar, ser decodificado e o `COUNT(*)` terminar.

### 3.5 Grid view-based

**[DBDeck]** `Sources/DBDeckApp/Views/DataGridView.swift:330` — `tableView(_:viewFor:row:)` devolve `GridTextCellView` (`:938`), um `NSTableCellView` com `NSTextField` + **3 constraints de Auto Layout**:

```swift
NSLayoutConstraint.activate([
    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
    label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
    label.centerYAnchor.constraint(equalTo: centerYAnchor)
])
```

Há reuso (`makeView(withIdentifier:)`), então não é catastrófico — mas com 30 colunas visíveis × 40 linhas são 1.200 views vivas resolvendo constraints a cada scroll e a cada `reloadData()`. O Sequel Ace faz o mesmo trabalho com ~30 `NSCell` reaproveitados e zero layout.

Some-se: `configure(value:numeric:)` (`:979`) chama `NSFontManager.shared.convert(...)` (`:984`) para **toda célula NULL** — criação de fonte no caminho quente.

### 3.6 Detalhes menores, mas reais

- `estimateWidth` **[DBDeck]** `DataGridView.swift:65` amostra só `rows.prefix(40)` — as **primeiras** 40, não espalhadas. Colunas ficam mal dimensionadas quando os dados variam ao longo da página. E não há o passo de "reduzir proporcionalmente para caber na largura visível".
- Página de **500** contra 1000 do Sequel Ace: mais cliques de paginação, e cada clique paga os 3 RTT + decode.
- Nenhuma opção de adiar BLOB/TEXT (`LoadBlobsAsNeeded`).
- `Theme.rowHeight = 26` contra 16: menos linhas por tela.

---

## 4. Plano de ataque, por retorno sobre esforço

> **Implementado.** Ver a seção 6 no fim deste documento para o que entrou e os números medidos.

### Nível 1 — muda tudo, esforço baixo

**1.1 Matar o `COUNT(*)` do caminho de abertura.**
Espelhar `updateAccurateNumberOfRowsForCurrentTableForcingUpdate:`:

- MySQL: `SHOW TABLE STATUS LIKE '<t>'` → usar `Rows` como estimativa e `Data_length` como gate. Se `Data_length < 5 MiB`, aí sim `SELECT COUNT(*)`.
- Postgres: `SELECT reltuples::bigint FROM pg_class WHERE oid = '<t>'::regclass` (estimativa instantânea) + `pg_total_relation_size` como gate.
- SQLite: `COUNT(*)` é barato, pode manter.
- Quando o resultado não está filtrado e voltou menos que `pageSize`, a contagem exata é `offset + rows.count` — sem consulta nenhuma.
- UI: mostrar `~1.234.567` quando estimado (igual ao `maxNumRowsIsEstimate`), com opção de clicar para contar de verdade.

**1.2 Trocar `information_schema` por `SHOW`.**
`SHOW FULL COLUMNS FROM <t>` devolve nome, tipo, null, default, **e** `Key` (`PRI`) — resolve colunas **e** PKs numa consulta só. Elimina 2 das 3 consultas de metadados.

**1.3 Usar `simpleQuery` (protocolo de texto) para SELECT.**
`MySQLConnection.simpleQuery(_:onRow:)` já está disponível (`ThirdParty/mysql-nio/Sources/MySQLNIO/MySQLSimpleQueryCommand.swift:11`) e **já é usado** no nosso `execute()` (`MySQLDriver.swift:206`). `SQLValue(mysqlData:)` já lida com `row.format`, então o decode não muda. Corta 3 RTT → 1 RTT em cada consulta.

**1.4 Não pedir PK duas vezes.** `columns()` já devolve a informação; `load()` deve derivar `primaryKeys` de `columns.filter(\.isPrimaryKey)`.

> Só o nível 1 deve levar a abertura de uma tabela grande de "segundos" para "uma ida ao servidor".

### Nível 2 — o salto arquitetural

**2.1 Grid alimentado por streaming, com progressão.**
Trocar `rows: [[SQLValue]]` por um store observável alimentado por `streamQuery`, e um timer (ou `DispatchSourceTimer`) de ~20 ms na main thread chamando `noteNumberOfRowsChanged` com a contagem já recebida — cópia direta de `tableLoadUpdate:`, incluindo a queda de frequência (1 → 10 → 25 ticks).

**2.2 Truncar na origem.**
Introduzir `SQLValue.textPreview` ou um `display(maxChars:)` e fazer o `GridTextCellView` pedir no máximo ~150 caracteres. Melhor ainda: guardar o `ByteBuffer`/`Data` cru na linha e só converter para `String` na hora de desenhar — versão Swift do `cellPreviewAtRow:column:previewLength:`.

**2.3 `LoadBlobsAsNeeded`.**
Construir a lista de campos do SELECT em vez de `SELECT *` (`TableDataView.swift:501`), trocando colunas BLOB/TEXT por `NULL` e marcando-as como "não carregadas" no grid, com carregamento sob demanda por PK ao clicar.

### Nível 3 — refinos

- Migrar o `DataGridView` para cell-based (`NSCell` custom desenhando o texto), ou ao menos trocar Auto Layout por `resizeSubviews(withOldSize:)` manual no `GridTextCellView`.
- Cachear as fontes (itálico do NULL) em `static let` em vez de `NSFontManager.convert` por célula.
- `estimateWidth`: amostrar espalhado (`stride`) e aplicar a redução proporcional para caber na largura visível (`autodetectColumnWidths`).
- Página padrão 1000; `rowHeight` 18–20.
- Paginação por keyset (`WHERE pk > ?`) quando há PK e o sort é pela PK, para não pagar offset profundo.

---

## 5. Arquivos-chave do Sequel Ace, para consulta

| Arquivo | O que tem |
|---|---|
| `Frameworks/SPMySQLFramework/Source/SPMySQLStreamingResultStore.{h,m}` | O store de bytes crus. `_downloadAllData:668`, `cellPreviewAtRow:336`, layout do bloco de linha `:694-760` |
| `Frameworks/SPMySQLFramework/Source/SPMySQLResult Categories/Data Conversion.m` | Conversão bytes → objeto com `previewLength`. `_getObjectFromBytes:114`, `_convertStringData:258` |
| `Source/Other/CategoryAdditions/SPDataStorage.{h,m}` | Proxy editável, COW por linha, colunas não carregadas |
| `Source/Controllers/MainViewControllers/TableContent/SPTableContent.m` | Orquestração. `loadTableValues:860`, `updateResultStore:1115`, `tableLoadUpdate:1290`, `fieldListForQuery:3204`, data source `:4120` |
| `Source/Views/TableViews/SPCopyTable.m` | `autodetectColumnWidths:957`, `autodetectWidthForColumnDefinition:1009` |
| `Source/Controllers/DataControllers/SPTableData.m` | `SHOW COLUMNS`/`SHOW CREATE TABLE`/`SHOW TABLE STATUS`, `updateAccurateNumberOfRows…:1323` |

---

## 6. O que foi implementado

Os três níveis do plano foram aplicados. Resumo por arquivo:

### Core

| Onde | Mudança |
|---|---|
| `Models.swift` | `SQLValue.truncated(prefix:byteCount:isBinary:)` — valor cortado na origem, com `isTruncated`, `cellDisplay` (teto de 300 chars para desenho) e `sqlLiteral` devolvendo `DEFAULT` (rede de segurança contra gravar prefixo). `DatabaseColumn.isBlobOrText`. `RowCountEstimate`. `SQLEngine.quote(_:)`. |
| `PageQuery.swift` (novo) | `PageCursor` + `PageQueryBuilder`: monta o SELECT da página, decide keyset × OFFSET, lista de campos com colunas adiadas e a consulta de célula avulsa. **Fica no core para ser testável** — é a lógica mais delicada da tela. |
| `DatabaseDriver.swift` | `query(_:previewLimit:)` e `streamQuery(_:batchSize:previewLimit:onBatch:)` (as versões antigas viraram atalhos com `nil`). `rowCount(table:allowExactScan:)`. `utf8SafePrefix` compartilhado. |
| `MySQLDriver.swift` | `simpleQuery` (protocolo de texto, **1 RTT** contra os 3 do statement preparado). `SHOW FULL COLUMNS` no lugar do `information_schema` (resolve colunas **e** PK). `SHOW KEYS` para a ordem da PK composta. `SHOW TABLE STATUS` para a contagem, com limiar de 5 MiB. Corte no `ByteBuffer` antes de decodificar. Leitura de resultados de `SHOW` por NOME de coluna, não por posição. |
| `PostgresDriver.swift` | `pg_class.reltuples` + `pg_total_relation_size` + `relkind` para a contagem (view não vira `COUNT(*)`). Corte no buffer por tipo. |
| `SQLiteDriver.swift` | Corte nos bytes do `sqlite3_column_text/blob`, sem construir a String grande. |

### App

| Onde | Mudança |
|---|---|
| `TableDataView.swift` | Uma só consulta de metadados na abertura (PK derivada de `columns()`). Página carregada por `streamQuery` com **publicação progressiva** (20 ms → 200 ms → 500 ms, a curva do `tableLoadUpdate`). Paginação por keyset. Contagem estimada com "~" e clique para contar exato. Botão de adiar TEXT/BLOB. Carga sob demanda do valor íntegro ao editar/copiar/exportar. Guarda de geração contra dois carregamentos sobrepostos. Página de 1000. |
| `DataGridView.swift` | `noteNumberOfRowsChanged` em vez de `reloadData` enquanto a página cresce. `GridTextCellView` sem Auto Layout (layout manual) e com fontes cacheadas. Amostragem espalhada + redução proporcional para caber na janela. Estados de célula truncada e "(não carregado)". Edição de célula cortada carrega o valor real antes de abrir o editor. Cópia delegada. |
| `GridKit.swift` / `Theme.swift` | `preferredMaxWidth` de 200 px. `RowInspector` não deixa editar prefixo. `rowHeight` 26 → 20. |

### Números medidos

SQLite local, tabela de 120 mil linhas × 63 colunas com uma coluna TEXT de 60 KB por linha:

| Operação | Antes | Depois |
|---|---|---|
| Decodificar uma página de 1000 linhas | 35 ms, **+65 MB de RSS** | 29 ms, **+0 MB** |
| Página no offset 100.000 | 186 ms | **28 ms** |
| Página com TEXT/BLOB adiados | — | **10 ms** |

A memória é o número que importa: **65 MB por página → 0**. É o efeito direto de não materializar o que não cabe na célula, que é a ideia central do `SPMySQLStreamingResultStore`.

Os ganhos de MySQL/Postgres **não aparecem aqui** porque o SQLite é local e não tem round-trip: eliminar 2 dos 3 RTT por consulta e reduzir a abertura de tabela de 5 consultas para 2 vale ~11 idas ao servidor a menos — a 60 ms de latência, cerca de **0,7 s** por abertura, além do `COUNT(*)` que deixou de acontecer.

### Cobertura

42 testes passando, 23 deles novos: `PageQueryTests` (17 casos cobrindo keyset, ordem invertida, filtro combinado, degradação para OFFSET, colunas adiadas, célula avulsa e sintaxe por engine) e 6 em `CoreTests` para o corte de valores, UTF-8 multibyte, blob, contagem e classificação de colunas.

### O que NÃO foi feito, e por quê

- **Grid cell-based (`NSCell`) como o Sequel Ace.** O ganho restante depois de tirar o Auto Layout é pequeno perto do custo: a máquina de edição inteira (field editor, Tab/Enter, type-to-edit, anéis de seleção) teria de ser reescrita sobre `editColumn:row:withEvent:select:`. Ficou o layout manual, que captura a maior parte do ganho.
- **Corte de valores no console SQL.** Ali os resultados ficam íntegros de propósito: o console não tem PK nem contexto para recarregar uma célula, e copiar um prefixo seria entregar dado incompleto em silêncio. O risco de travamento no desenho está coberto pelo `cellDisplay`, que nunca entrega mais de 300 caracteres ao `NSTextField`.

---

## 7. Pós-mortem: a regressão da 0.2.0 e a correção

A 0.2.0 ficou MAIS lenta que o código anterior em tabelas largas — o oposto do prometido.
Reproduzido com uma tabela de 150 colunas × 131k linhas no MySQL local: abrir a tabela
custava ~5,8 s com o main thread travado ~4,5 s (o código pré-0.2.0 fazia o mesmo em ~1 s).
O backend não tinha culpa (fluxo de rede/decodificação 5× mais rápido que o antigo, medido
isolado); os vilões eram todos da camada AppKit/SwiftUI, e se multiplicavam:

| # | Causa | Mecânica |
|---|---|---|
| 1 | **Animações implícitas em `NSTableColumn.width`** (o dominante: ~4,5 s) | O `updateNSView` roda dentro de uma transaction do SwiftUI com animação ativa. Cada `column.width =` reposiciona todas as células à direita em todas as rowViews via `_NSViewAnimator`, criando uma `CAAnimation` POR CÉLULA — 150 colunas × 31 linhas × ~75 células ≈ 350 mil animações. |
| 2 | **`reloadData` realoca tudo** | O reload completo descarta as rowViews; ~4.700 células (NSTextField!) realocadas a cada página. O pool de reuso do NSTableView não segura um reload completo. |
| 3 | **Seed de largura depois das células montadas, várias vezes** | O seed rodava a cada publicação do streaming (até 200 linhas) + o fit — cada onda de `setWidth` pagava o custo do item 1. |
| 4 | **`needsLayout` em massa** | O `configure()` invalidava o layout de cada célula; cada reload marcava ~6 mil views e o display cycle percorria a árvore inteira de novo. |
| 5 | **Medição de texto por célula** | O `layout()` manual chamava `intrinsicContentSize` (mede o texto) por célula por pass. |
| 6 | **`fittingSize` do SwiftUI** | O SwiftUI mede os layoutTraits do `NSViewRepresentable` via `systemLayoutSizeFittingSize`, que popula um engine de Auto Layout com a subárvore INTEIRA (~12 mil views) a cada reavaliação de layout. |

### As correções (DataGridView.swift)

1. **`withoutAnimation(batchOn:)`** — toda mudança de largura em lote roda com `NSAnimationContext` de duração 0 + `beginUpdates/endUpdates`.
2. **Seed ANTES das células existirem** — o seed de larguras roda no `updateNSView` antes do primeiro reload/append da página: mudar largura sem células montadas custa ~zero. E roda UMA vez por tabela.
3. **`softReloadRows`** — dados novos com colunas iguais reconfiguram as células já montadas in-place (zero destruição/alocação); `reloadData` só quando as colunas mudam.
4. **Append por prefixo** — `rows.prefix(n).elementsEqual(snapshot)` detecta acréscimo (fast-path por identidade de buffer): lotes do streaming e a publicação final viram só `noteNumberOfRowsChanged`.
5. **Sem `needsLayout` no configure** — o frame do label só depende do bounds da célula.
6. **Altura de label cacheada** — sem medição de texto por célula.
7. **Teto de publicações por largura** — tabela com ≥ 50 colunas publica 1 lote intermediário + o final.
8. **`sizeThatFits` no representable** — responde ao SwiftUI com o tamanho proposto, sem medir o conteúdo.

### Números depois da correção (app real, MySQL local)

| Cenário | 0.2.0 (regressão) | Corrigido |
|---|---|---|
| wide150 (150 col × 131k linhas): primeiras linhas na tela | ~0,3 s (e main travado depois) | **0,24 s** |
| wide150: página completa | 5,8 s (main travado ~4,5 s) | **1,3 s** (sem travar) |
| Tabelas reais 13–30 col, 2–4M linhas: primeiras linhas | — | **0,18 s** |
| Tabelas reais: load completo com contagem | — | **0,57–0,65 s** |
| Troca de página (150 col, harness) | ~2 s, hang ~900 ms | **0,43 s, zero hangs > 50 ms** |

### Método (fica para a próxima)

- Harness `GridBench` (target SwiftPM temporário com o grid real + NSHostingView + watchdog de hangs) — mediu o grid isolado sem UI manual.
- Harness `DBDECK_AUTO` (env var que auto-conectava e abria tabelas em sequência) — mediu o app inteiro sem cliques.
- `sample DBDeck` durante o carregamento + `SHOW PROCESSLIST` — foi o que separou "servidor lento" (não era) de "main thread ocupado" (era), e apontou `setWidth → _NSViewAnimator → CAAnimation` como o dominante.
- Armadilha que custou tempo: o harness compilava CÓPIAS dos arquivos do grid — símbolos iguais, código velho. Symlinks resolveram; benchmarks que não mudam quando você muda o código são o sinal.

---

## 8. Rodada 0.2.2: rolagem em tabela larga e o dump

Validado contra a tabela real do usuário (`leads`, **281 colunas**, importada localmente
a partir do dump — produção intocada).

### Rolagem (DataGridView)

| Causa | Correção |
|---|---|
| `tableColumns.firstIndex(of:)` no `viewFor` — busca LINEAR em 281 colunas POR CÉLULA (~240 mil comparações por passo de rolagem) | Mapa `identifier → posição` reconstruído no `rebuildColumns` (O(1) por célula). **Foi o fator dominante: p50 do passo vertical caiu 4,4×.** |
| Célula = NSTableCellView + NSTextField (2 views + cell machinery × ~280 células por linha nova) | **Célula draw-only**: uma NSView que desenha o texto com `NSString.draw` e atributos cacheados por estilo; anel de seleção/edição desenhado no `draw()`. A edição usa um NSTextField ÚNICO (overlay do Coordinator) montado sobre a célula só durante a edição. |

Medição (leads real, 1000×281, debug — release é melhor):

| Rolagem | Antes | Depois |
|---|---|---|
| Vertical, passo de 60 px | p50 15,0 ms · pior 436 ms | **p50 3,4 ms** · pior 102 ms |
| Horizontal, passo de 80 px | p50 1,7 ms | **p50 0,5 ms** |
| Diagonal | p50 14,7 ms | **p50 3,3 ms** |

### Dump

1. **Regressão da 0.2.0 confirmada e corrigida**: no protocolo de texto, datetime chega
   como string pronta; o decode fazia string → `MySQLTime` → `Date` (Calendar) →
   `DateFormatter` → string, por célula. Agora o texto cru passa direto (e preserva
   fracionários). Medido em release, 400k linhas × 3 timestamps: caminho antigo
   (0.1.x, prepared/binário) 4.300 ms → atual **731 ms — 6× mais rápido que ANTES da 0.2.0**.
2. **Bug de re-import corrigido**: o dump incluía colunas `GENERATED ALWAYS AS` nos
   INSERTs — o servidor recusa (ERROR 3105) e o dump não importava (o dump de produção
   do usuário expôs isso na tabela `leads`). Agora os três drivers marcam
   `DatabaseColumn.isGenerated` (MySQL: Extra `VIRTUAL/STORED GENERATED`; Postgres:
   `is_generated='ALWAYS'`; SQLite: `table_xinfo.hidden` 2/3) e o dump lista
   explicitamente só as colunas normais, como o mysqldump. Coberto por teste round-trip.

---

## 9. Rodada 0.2.4: o grid vira cell-based de verdade

O view-based otimizado ainda mostrava dois sintomas em tabelas muito largas (leads
real, 281 colunas): pop-in na rolagem horizontal (cada célula é uma layer desenhada
assincronamente) e peso na vertical (criação de ~280 views por linha nova). São limites
da arquitetura, não de implementação — então o DataGridView foi migrado para o
**NSTableView cell-based**, exatamente o `SPCopyTable` do Sequel Ace:

- **Um `NSCell` por COLUNA** desenha todas as células visíveis (`objectValueFor` +
  `willDisplayCell` aplicando estilo por célula antes de cada desenho). Zero views,
  zero layers, zero layout por célula.
- **Edição pelo field editor nativo** (`editColumn`), com o `textDidEndEditing`
  interceptado na subclasse — o movimento vira `illegal` antes de o super agir, e
  Return/Tab/Backtab navegam pelas NOSSAS regras (Enter desce a seleção, Tab pula
  BLOB/bool com wrap). É literalmente o truque do SPCopyTable.
- Checkbox de coluna bool virou display-only (NSButtonCell) com toggle no clique.
- `reloadData` voltou a ser "só redesenhe": sem views para destruir, a troca de página
  não aloca nada.

Números na leads real (1000×281, debug — release é 3-5× melhor; o harness de release
crasha num bug próprio do bench, não do app):

| Rolagem | view-based otimizado | cell-based |
|---|---|---|
| Vertical p50 / pior | 3,4 ms / 102 ms | 11,9 ms* / **50 ms** |
| Horizontal p50 | 0,5 ms (com pop-in) | **0,5 ms, sem pop-in** |
| Diagonal frames >16,7 ms | 1/120 | **0/120** |

*o p50 vertical maior em DEBUG é o decode não-otimizado por célula desenhada; o que
importa: o pior caso caiu pela metade, não há mais criação de views nem pop-in, e o
perfil é o mesmo do Sequel Ace.

## 10. Import de dump: erro visível e à prova de silêncio

Caso real: dump de 10 GB gerado pela 0.2.1 (com o bug das colunas geradas) importado
pelo app — TODOS os INSERTs da `leads` falhavam com ERROR 3105 e o usuário não via
nada até o fim (dezenas de minutos depois… se visse).

- O progresso agora mostra **os erros enquanto acontecem** ("N erros" em laranja).
- **Abort após 25 statements consecutivos falhando** (`DumpError.tooManyErrors`, com o
  último erro na mensagem): uma tabela inteira rejeitada aborta em segundos com
  explicação, em vez de "importar" em silêncio. Erros esparsos continuam tolerados.
- O toast final marca com ⚠ quando houve erros, e o alert traz os primeiros.

---

## 11. Rodada 0.2.5: exportação multi-formato, console e bancos

- **Exportação SQL/CSV/JSON** (`ResultExporter`, writers incrementais):
  - Grid da tabela: menu Exportar → página atual OU tabela inteira × formato. A página
    sai com valores íntegros (recarrega sem preview); a tabela inteira sai em
    STREAMING com backpressure, como o dump — nunca materializa a tabela.
  - Console: menu Exportar sobre o resultado atual (que já guarda valores íntegros).
  - JSON com tipos nativos (números/bool/null), blob em base64, ordem de chaves
    preservada; SQL com INSERTs multi-linha e teto de 1 MB por statement; CSV com BOM.
- **Console SQL**: editor com syntax highlight (NSTextView + regex, cores dinâmicas
  claro/escuro) e split arrastável editor/resultados — fração inicial de 50%,
  persistida por aba, clamp 15–85%.
- **Bancos**: toda conexão de servidor expande na sidebar para os demais bancos
  acessíveis, mesmo com banco fixo no cadastro — o fixo é só o padrão de entrada
  (marcado com ★). Trocar de banco recarrega a lista de tabelas e fecha abas do banco
  anterior, como já acontecia nas conexões sem banco fixo.
