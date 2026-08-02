import Foundation
import os

/// Formatter global compartilhado entre drivers (marcado como não-Sendable de forma segura).
nonisolated(unsafe) let dbISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()
