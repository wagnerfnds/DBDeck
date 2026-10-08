import SwiftUI
import UIKit
import DBDeckCore

// MARK: - Háptica

/// Retorno tátil discreto nos pontos em que o toque muda dados ou conclui algo: no
/// telefone ele substitui o "clique" que o Mac dá pelo cursor.
@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Toast

/// Aviso efêmero no rodapé ("Salvo", "Copiado"). Some sozinho em 2,5 s.
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(message)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(.snappy) { self.message = nil }
                    }
                    .onTapGesture { withAnimation(.snappy) { self.message = nil } }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.snappy, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }

    /// Alerta de erro ligado a uma mensagem opcional.
    func errorAlert(_ message: Binding<String?>, title: String = "Erro") -> some View {
        alert(title, isPresented: .init(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

// MARK: - Status

struct StatusDot: View {
    let status: ConnectionStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if status == .connecting {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(1.8)
                        .phaseAnimator([0.4, 1.0]) { view, phase in view.opacity(phase) }
                }
            }
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        default: Color.secondary.opacity(0.35)
        }
    }

    private var label: String {
        switch status {
        case .connected: "Conectado"
        case .connecting: "Conectando"
        case .failed: "Falhou"
        default: "Desconectado"
        }
    }
}

// MARK: - Compartilhar arquivo

/// Arquivo pronto para a folha de compartilhamento (exportações, dumps).
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    func shareSheet(_ file: Binding<SharedFile?>) -> some View {
        sheet(item: file) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

enum ExportFiles {
    /// Arquivo temporário com nome amigável — é o nome que aparece no AirDrop/Arquivos.
    static func temporaryURL(named name: String, ext: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = folder.appending(path: "\(safe).\(ext)")
        try? FileManager.default.removeItem(at: url)
        return url
    }
}

// MARK: - Valores

extension SQLValue {
    /// Texto para copiar: NULL explícito (colar vazio esconderia a diferença).
    var copyText: String { self == .null ? "NULL" : display }

    var isNumeric: Bool {
        switch self {
        case .int, .double: true
        default: false
        }
    }
}

extension String {
    /// SQL numa linha só, para prévias em listas.
    var flattenedSQL: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Selos

/// Chip compacto com ícone + texto (banco ativo, contagens).
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2.weight(.semibold))
            }
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
