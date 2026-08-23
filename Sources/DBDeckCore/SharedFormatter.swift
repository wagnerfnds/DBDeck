import Foundation
import os

/// Formatter global compartilhado entre drivers (marcado como não-Sendable de forma segura).
nonisolated(unsafe) let dbISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Formato nativo do MySQL para DATETIME/TIMESTAMP. O sufixo "Z" do ISO 8601 é rejeitado
/// pelo servidor em modo estrito (ERROR 1292) — dumps com "Z" não reimportavam.
let mysqlDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

/// Formato nativo do Postgres para timestamp. `ISO8601DateFormatter` acrescenta o "Z",
/// que num `timestamp without time zone` seria descartado em silêncio — a forma sem
/// sufixo diz exatamente o que está armazenado.
let postgresTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
    return formatter
}()

/// Formato nativo do MySQL para DATE (sem hora).
let mysqlDateOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
