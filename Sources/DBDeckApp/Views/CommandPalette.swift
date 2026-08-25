import AppKit
import SwiftUI
import DBDeckCore

/// Paleta de comandos (⌘P): por padrão navega tabelas do banco atual; "@" navega bancos do servidor.
struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    @State private var query = ""
    /// Seleção por identidade, não por índice: sobrevive a recargas e reordenações da lista.
    /// `nil` significa "primeiro resultado".
    @State private var selectedID: PaletteItem.ID?
    /// Monitor local de teclado: intercepta ↑/↓/⏎/Esc antes de o TextField consumi-los.
    @State private var keyMonitor: Any?
    /// Janela que hospeda esta paleta: o monitor é global no app, então eventos de outras
    /// janelas (⌘N abre mais de uma) precisam passar direto.
    @State private var hostWindow: NSWindow?
    /// Altura real do conteúdo da lista, medida via preference: o painel abraça o conteúdo
    /// até o teto em vez de ocupar altura fixa (que centralizava o campo em listas curtas).
    @State private var listHeight: CGFloat = 0
    @FocusState private var focused: Bool

    enum Mode { case tables, databases, connections }

    private var mode: Mode {
        if query.hasPrefix("@") { return .databases }
        return currentSession != nil ? .tables : .connections
    }

    /// Sessão da conexão selecionada, sem criar uma nova durante o render.
    private var currentSession: ConnectionSession? {
        guard let id = state.selectedConnectionID, state.active[id] != nil else { return nil }
        return state.sessions[id]
    }

    private var currentConnectionName: String? {
        state.selectedConnectionID.flatMap { state.config(for: $0)?.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultsList
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 120)
        .background(
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
        )
        .onAppear {
            hostWindow = NSApp.keyWindow
            // O @FocusState não toma o foco de um NSTextView do AppKit que está como
            // first responder (o editor SQL, na prática sempre). Solta o first responder
            // primeiro e pede o foco no ciclo seguinte, já com a hierarquia montada.
            hostWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            // Como o Spotlight: a paleta fecha quando sua janela perde o foco (e assim o
            // monitor não fica vivo capturando teclas com outra janela em primeiro plano).
            if let window = note.object as? NSWindow, window === hostWindow { close() }
        }
        .onChange(of: query) { _, q in
            selectedID = nil // cada tecla digitada volta a seleção ao topo
            if q.hasPrefix("@") { Task { await loadDatabasesIfNeeded() } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 15))
                .foregroundStyle(headerColor)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
            if mode == .tables, let name = currentConnectionName {
                Text(name)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(headerColor.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var headerIcon: String {
        switch mode {
        case .tables: return "tablecells"
        case .databases: return "cylinder.split.1x2"
        case .connections: return "server.rack"
        }
    }
    private var headerColor: Color {
        switch mode {
        case .tables: return .accentColor
        case .databases: return .purple
        case .connections: return .accentColor
        }
    }
    private var placeholder: String {
        switch mode {
        case .tables: return "Ir para tabela…   (@ para bancos)"
        case .databases: return "Ir para banco…"
        case .connections: return "Ir para conexão…   (@ para bancos)"
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let items = results
        if items.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
        } else {
            let currentIndex = selectedIndex(in: items)
            ScrollViewReader { proxy in
                ScrollView {
                    // VStack não-lazy de propósito: com ≤200 linhas o custo é baixo e o
                    // scrollTo alcança qualquer item, mesmo os fora da área visível.
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == currentIndex)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { activate(item) }
                        }
                    }
                    .padding(6)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PaletteListHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                // Abraça o conteúdo até o teto; antes da primeira medição, estima pela
                // contagem de linhas para não piscar com altura errada na abertura.
                .frame(height: min(listHeight > 0 ? listHeight : CGFloat(items.count) * 46 + 12, 372))
                .onPreferenceChange(PaletteListHeightKey.self) { [listHeight = $listHeight] height in
                    listHeight.wrappedValue = height
                }
                .onChange(of: selectedID) { _, id in
                    guard let target = id ?? items.first?.id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: items.map(\.id)) { _, ids in
                    // A lista muda por baixo da seleção (digitação ou carga assíncrona de
                    // bancos inserindo linhas acima): mantém a linha selecionada à vista.
                    if let selectedID, ids.contains(selectedID) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    } else if let first = ids.first {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        switch mode {
        case .databases: return "Nenhum banco listado — conecte ou expanda uma conexão na lateral"
        case .tables: return "Nenhuma tabela encontrada"
        case .connections: return "Nenhuma conexão"
        }
    }

    // MARK: - Resultados

    private var results: [PaletteItem] {
        switch mode {
        case .databases:
            let term = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            let connections = state.workspaces.flatMap(\.connections)
            // Conexões cujo nome casa com o termo delimitam o escopo: "@residente" lista só
            // os bancos da conexão "residente", sem misturar bancos das outras. Dentro do
            // escopo, bancos cujo PRÓPRIO nome também casa vêm primeiro (exato > prefixo >
            // contém), então "@residente" põe o banco "residente" no topo, acima dos irmãos.
            // Sem conexão casando, o termo filtra por nome de banco em todas as conexões.
            let namedMatches = term.isEmpty ? [] : connections.filter { $0.name.lowercased().contains(term) }
            var buckets: [[PaletteItem]] = Array(repeating: [], count: 4)
            for connection in (namedMatches.isEmpty ? connections : namedMatches) {
                for db in knownDatabases(of: connection) {
                    let rank = matchRank(of: db, against: term)
                    guard !namedMatches.isEmpty || term.isEmpty || rank < 3 else { continue }
                    buckets[rank].append(PaletteItem(kind: .database(name: db, connectionID: connection.id, connectionName: connection.name)))
                }
            }
            return Array(buckets.flatMap { $0 }.prefix(200))
        case .tables:
            let term = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard let session = currentSession else { return [] }
            return session.tables
                .filter { term.isEmpty || $0.name.lowercased().contains(term) }
                .prefix(60)
                .map { PaletteItem(kind: .table($0.name, isView: $0.kind == "view")) }
        case .connections:
            let term = query.trimmingCharacters(in: .whitespaces).lowercased()
            var items: [PaletteItem] = []
            for workspace in state.workspaces {
                for connection in workspace.connections where term.isEmpty || connection.name.lowercased().contains(term) || connection.displaySubtitle.lowercased().contains(term) {
                    items.append(PaletteItem(kind: .connection(connection, workspace: workspace.name)))
                }
            }
            return items
        }
    }

    /// Bancos conhecidos de uma conexão sem tocar no estado — criar sessões durante o
    /// render dispararia mutação de estado no meio do body.
    private func knownDatabases(of connection: ConnectionConfig) -> [String] {
        let live = state.sessions[connection.id]?.databases ?? []
        return live.isEmpty ? connection.databasesCache : live
    }

    /// Quão bem um nome casa com o termo: 0 = igual, 1 = prefixo, 2 = contém, 3 = não casa.
    private func matchRank(of name: String, against term: String) -> Int {
        guard !term.isEmpty else { return 3 }
        let lowered = name.lowercased()
        if lowered == term { return 0 }
        if lowered.hasPrefix(term) { return 1 }
        if lowered.contains(term) { return 2 }
        return 3
    }

    // MARK: - Seleção e teclado

    /// Índice efetivo da seleção: o item com `selectedID`, ou o primeiro quando ele não existe mais.
    private func selectedIndex(in items: [PaletteItem]) -> Int {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return 0 }
        return index
    }

    private func move(_ delta: Int) {
        let items = results
        guard !items.isEmpty else { return }
        let index = (selectedIndex(in: items) + delta + items.count) % items.count
        selectedID = items[index].id
    }

    /// O TextField focado consome ↑/↓ movendo o cursor; o monitor local intercepta o evento
    /// antes de ele chegar ao field editor, então a navegação funciona mesmo com texto digitado.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            let handled = MainActor.assumeIsolated { handleKey(event) }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Devolve true quando a tecla é da paleta (o evento não segue para o TextField).
    private func handleKey(_ event: NSEvent) -> Bool {
        // Eventos de outra janela não são nossos.
        guard hostWindow == nil || event.window === hostWindow else { return false }
        // Durante composição de acento/IME (texto marcado), ⏎/Esc/setas pertencem ao editor.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        switch event.keyCode {
        case 125: move(1); return true                 // ↓
        case 126: move(-1); return true                // ↑
        case 36, 76: activateSelection(); return true  // ⏎ e Enter do teclado numérico
        case 53: close(); return true                  // Esc
        default: return false
        }
    }

    private func activateSelection() {
        let items = results
        guard !items.isEmpty else { return }
        activate(items[selectedIndex(in: items)])
    }

    private func activate(_ item: PaletteItem) {
        switch item.kind {
        case .connection(let config, _):
            state.selectedConnectionID = config.id
            // O sync da sidebar só espelha a seleção; conectar é responsabilidade daqui —
            // inclusive quando a conexão ativada já era a selecionada (aí nem há onChange).
            if state.active[config.id] == nil {
                Task { _ = await state.connect(config.id) }
            }
        case .table(let name, _):
            currentSession?.openTable(name)
        case .database(let name, let connectionID, _):
            state.selectedConnectionID = connectionID
            Task {
                if state.active[connectionID] == nil { _ = await state.connect(connectionID) }
                _ = await state.switchDatabase(connectionID, to: name)
            }
        }
        close()
    }

    /// Carrega a lista de bancos de todas as conexões ativas (sem conectar às inativas, por segurança).
    private func loadDatabasesIfNeeded() async {
        for workspace in state.workspaces {
            for connection in workspace.connections {
                let session = state.session(for: connection.id)
                guard session.databases.isEmpty, let driver = state.active[connection.id] else { continue }
                if let list = try? await driver.databases() { state.setDatabases(list, for: connection.id) }
            }
        }
    }

    private func close() {
        query = ""
        selectedID = nil
        isPresented = false
    }
}

private struct PaletteListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PaletteItem: Identifiable {
    enum Kind {
        case connection(ConnectionConfig, workspace: String)
        case table(String, isView: Bool)
        case database(name: String, connectionID: UUID, connectionName: String)
    }
    let kind: Kind
    var id: String {
        switch kind {
        case .connection(let c, _): return "c-\(c.id)"
        case .table(let name, _): return "t-\(name)"
        case .database(let name, let cid, _): return "d-\(cid)-\(name)"
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .connection(let config, _):
            EngineBadge(engine: config.engine, size: 24)
        case .table(_, let isView):
            Image(systemName: isView ? "eye" : "tablecells")
                .foregroundStyle(selected ? .white : (isView ? Color.purple : Color.accentColor))
                .frame(width: 24)
        case .database:
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(selected ? .white : Color.purple)
                .frame(width: 24)
        }
    }

    private var title: String {
        switch item.kind {
        case .connection(let c, _): return c.name
        case .table(let name, _): return name
        case .database(let name, _, _): return name
        }
    }

    private var subtitle: String? {
        switch item.kind {
        case .connection(let c, let ws): return "\(ws) · \(c.displaySubtitle)"
        case .table(_, let isView): return isView ? "view" : "tabela"
        case .database(_, _, let connName): return connName
        }
    }
}
