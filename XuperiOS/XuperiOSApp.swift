import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Paleta tomada de los recursos del APK (colorPrimary #FF0033, fondo color_0b0b0b).
extension Color {
    static let xuperRed = Color(red: 1, green: 0, blue: 0.2)
    static let xuperBackground = Color(red: 0.043, green: 0.043, blue: 0.043)
    static let xuperSurface = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let xuperRaised = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let xuperMuted = Color(red: 0.70, green: 0.70, blue: 0.70)
}

@main
struct XuperiOSApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(white: 0.03, alpha: 1)
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = UIColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1)
        navBar.shadowColor = .clear
        navBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
        UINavigationBar.appearance().compactAppearance = navBar
    }

    var body: some Scene {
        WindowGroup { LibraryView() }
    }
}

private struct Category: Identifiable {
    let name: String
    let streams: [Stream]
    var id: String { name }
}

private struct LibraryView: View {
    private enum Screen: Hashable {
        case home, live, search, lists, profile
    }

    private static let featured = "DESTACADOS"

    @State private var screen = Screen.home
    @State private var streams: [Stream] = []
    @State private var chip = LibraryView.featured
    @State private var search = ""
    @State private var selected: Stream?
    @State private var showsFiles = false
    @State private var addMode: AddMode?
    @State private var pendingAction: (() -> Void)?
    @State private var form = SourceForm()
    @State private var formError: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var didLoad = false
    @State private var lists: [SavedList] = []
    @State private var renaming: SavedList?
    @State private var renameText = ""

    private var addedSources: Set<String> {
        Set(lists.map(\.id))
    }

    private var categories: [Category] {
        Dictionary(grouping: streams) { $0.group.isEmpty ? "Sin categoría" : $0.group }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Category(name: $0.key, streams: $0.value) }
    }

    private var visibleStreams: [Stream] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? streams : streams.filter {
            $0.title.localizedStandardContains(query) || $0.group.localizedStandardContains(query)
        }
    }

    var body: some View {
        TabView(selection: $screen) {
            NavigationStack { home }
                .tabItem { Label("Inicio", systemImage: "house.fill") }
                .tag(Screen.home)

            NavigationStack { live }
                .tabItem { Label("TV", systemImage: "tv.fill") }
                .tag(Screen.live)

            NavigationStack { searchScreen }
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
                .tag(Screen.search)

            NavigationStack { listsScreen }
                .tabItem { Label("Listas", systemImage: "list.bullet.rectangle.portrait.fill") }
                .tag(Screen.lists)

            NavigationStack { profile }
                .tabItem { Label("Perfil", systemImage: "person.crop.circle.fill") }
                .tag(Screen.profile)
        }
        .preferredColorScheme(.dark)
        .tint(Color.xuperRed)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.xuperRed)
                    Text("Cargando lista…").font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.xuperSurface)
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            streams = LibraryStore.load()
            lists = LibraryStore.loadLists()
            await Guide.shared.refresh()
        }
        .sheet(item: $addMode, onDismiss: runPendingAction) { mode in addSheet(mode) }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item]) { result in
            do {
                let file = try result.get()
                let imported = try StreamCatalog.readFile(file)
                saveList(SavedList(id: UUID().uuidString, name: file.deletingPathExtension().lastPathComponent,
                                   url: nil, count: 0, updated: Date(), kind: .file), streams: imported)
                screen = .home
            } catch {
                self.error = importMessage(error)
            }
        }
        .fullScreenCover(item: $selected) { stream in
            PlaybackView(stream: stream)
        }
        .alert("Renombrar lista", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Nombre", text: $renameText)
            Button("Guardar") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renaming?.id, !name.isEmpty, let index = lists.firstIndex(where: { $0.id == id }) {
                    lists[index].name = name
                    LibraryStore.saveLists(lists)
                }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .alert("No se pudo abrir", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: Inicio

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                chipBar
                if streams.isEmpty {
                    heroCard(.demo)
                        .frame(height: 220)
                        .padding(.horizontal, 16)
                    emptyLibrary
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                } else if chip != Self.featured, let category = categories.first(where: { $0.name == chip }) {
                    PosterGrid(streams: category.streams) { selected = $0 }
                        .padding(.horizontal, 16)
                } else {
                    featuredContent
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color.xuperBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandMark() }
            sourceToolbar
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach([Self.featured] + categories.map(\.name), id: \.self) { name in
                    chipButton(name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func chipButton(_ name: String) -> some View {
        let isOn = chip == name
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { chip = name }
        } label: {
            Text(name.uppercased())
                .font(.footnote.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? Color.white : Color.xuperMuted)
                .background(isOn ? Color.xuperRed : Color.xuperRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var featuredContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            TabView {
                ForEach(Array(streams.prefix(6))) { stream in
                    heroCard(stream)
                        .padding(.horizontal, 16)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 240)

            ForEach(categories.prefix(12)) { category in
                categoryRow(category)
            }
        }
    }

    private func heroCard(_ stream: Stream) -> some View {
        Artwork(stream: stream, fit: false)
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if !stream.group.isEmpty {
                        Text(stream.group.uppercased())
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.xuperRed)
                    }
                    Text(stream.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Button {
                        selected = stream
                    } label: {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Color.xuperRed, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { selected = stream }
    }

    private func categoryRow(_ category: Category) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Rectangle()
                    .fill(Color.xuperRed)
                    .frame(width: 4, height: 18)
                Text(category.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Ver todo") {
                    withAnimation { chip = category.name }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(category.streams.prefix(20)) { stream in
                        PosterCard(stream: stream, width: 112) { selected = stream }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: TV en vivo

    private var live: some View {
        List {
            ForEach(categories) { category in
                Section {
                    ForEach(category.streams) { stream in
                        ChannelRow(stream: stream) { selected = stream }
                    }
                } header: {
                    Text(category.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.xuperRed)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.xuperBackground)
        .overlay {
            if streams.isEmpty { emptyLibrary }
        }
        .navigationTitle("Lista de canales")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sourceToolbar }
    }

    // MARK: Buscar

    private var searchScreen: some View {
        List(visibleStreams) { stream in
            ChannelRow(stream: stream) { selected = stream }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.xuperBackground)
        .overlay {
            if streams.isEmpty {
                emptyLibrary
            } else if visibleStreams.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Buscar")
        .searchable(text: $search, prompt: "Película, serie o canal")
        .toolbar { sourceToolbar }
    }

    // MARK: Perfil

    private var profile: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.xuperRed)
                    VStack(alignment: .leading, spacing: 4) {
                        BrandMark()
                        Text("\(streams.count) títulos en \(categories.count) categorías")
                            .font(.footnote)
                            .foregroundStyle(Color.xuperMuted)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.xuperSurface)

            Section("Biblioteca") {
                Button {
                    screen = .lists
                } label: {
                    Label("Gestionar mis listas", systemImage: "list.bullet.rectangle.portrait")
                }
                if !streams.isEmpty {
                    Button(role: .destructive) {
                        streams = []
                        lists = []
                        chip = Self.featured
                        LibraryStore.save([])
                        LibraryStore.saveLists([])
                    } label: {
                        Label("Borrar toda la biblioteca", systemImage: "trash")
                    }
                }
            }
            .listRowBackground(Color.xuperSurface)

            Section("Prueba") {
                Button {
                    selected = .demo
                } label: {
                    Label("Reproducir señal Bip Bop", systemImage: "play.rectangle.fill")
                }
            }
            .listRowBackground(Color.xuperSurface)

            Section {
                LabeledContent("Versión", value: appVersion)
            }
            .listRowBackground(Color.xuperSurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.xuperBackground)
        .navigationTitle("Perfil")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: Compartido

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Añade tu lista", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Carga canales gratuitos o usa tu propia lista M3U.")
        } actions: {
            Button {
                addSources(PublicSource.starter)
            } label: {
                Label("Canales gratis (Perú + Hispanoamérica)", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            HStack {
                Button("Pegar enlace") { present(.m3u) }
                    .buttonStyle(.bordered)
                Button("Importar archivo") { showsFiles = true }
                    .buttonStyle(.bordered)
            }
            .disabled(isLoading)
        }
    }

    private func addSheet(_ mode: AddMode) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(mode == .hls ? "Nombre del canal" : "Nombre de la lista (opcional)", text: $form.name)
                }
                switch mode {
                case .m3u, .hls, .custom:
                    Section {
                        TextField(mode == .hls ? "Enlace .m3u8 (ej. servidor.com/canal.m3u8)" : "Enlace (ej. midominio.com/lista.m3u)", text: $form.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(mode.help)
                    }
                    if mode == .custom {
                        Section {
                            TextField("User-Agent (opcional)", text: $form.userAgent)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Referer (opcional)", text: $form.referer)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } header: {
                            Text("Identificación personalizada")
                        } footer: {
                            Text("Algunos servidores solo responden si la app se identifica con un User-Agent o un Referer concretos. Se usan al descargar la lista y al reproducir.")
                        }
                    }
                case .xtream:
                    Section {
                        TextField("Servidor (ej. servidor.com:8080)", text: $form.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Usuario", text: $form.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Contraseña", text: $form.password)
                    } footer: {
                        Text(mode.help)
                    }
                    Section {
                        Toggle("TV en vivo", isOn: $form.live)
                        Toggle("Películas", isOn: $form.movies)
                    }
                }
                if let formError {
                    Text(formError)
                        .foregroundStyle(Color.xuperRed)
                }
                Section {
                    Button(mode == .hls ? "Guardar canal" : "Guardar y cargar") { submitForm(mode, playNow: false) }
                        .fontWeight(.semibold)
                    if mode == .hls {
                        Button("Reproducir sin guardar") { submitForm(mode, playNow: true) }
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { addMode = nil }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var sourceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(AddMode.allCases) { mode in
                    Button(mode.title, systemImage: mode.symbol) { present(mode) }
                }
                Button("Importar archivo M3U", systemImage: "doc") { showsFiles = true }
            } label: {
                Label("Añadir contenido", systemImage: "plus.circle.fill")
            }
            .disabled(isLoading)
        }
    }

    // MARK: Listas

    private var listsScreen: some View {
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(AddMode.allCases) { mode in
                        Button {
                            present(mode)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.symbol)
                                    .font(.title2)
                                Text(mode.title)
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.xuperRed, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    showsFiles = true
                } label: {
                    Label("Importar archivo M3U", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.xuperRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .disabled(isLoading)

            Section {
                if lists.isEmpty {
                    Text("Todavía no has guardado listas. Añade una con el botón de arriba o elige una gratuita.")
                        .font(.footnote)
                        .foregroundStyle(Color.xuperMuted)
                }
                ForEach(lists) { list in
                    savedListRow(list)
                }
            } header: {
                Text("Mis listas (\(lists.count))")
            } footer: {
                if !lists.isEmpty {
                    Text("Desliza una lista para actualizarla, renombrarla o eliminarla. También puedes mantenerla pulsada.")
                }
            }
            .listRowBackground(Color.xuperSurface)

            Section("Gratis") {
                NavigationLink {
                    sourcesScreen
                } label: {
                    Label("Listas gratuitas por país y categoría", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    addSources(PublicSource.starter)
                } label: {
                    Label("Cargar Perú + Hispanoamérica", systemImage: "bolt.fill")
                }
                .disabled(isLoading)
            }
            .listRowBackground(Color.xuperSurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.xuperBackground)
        .navigationTitle("Mis listas")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshAll() }
    }

    private func savedListRow(_ list: SavedList) -> some View {
        HStack(spacing: 12) {
            Image(systemName: list.symbol)
                .font(.title3)
                .foregroundStyle(Color.xuperRed)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(list.kindName) · \(list.count) canales · \(list.updated.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(Color.xuperMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteList(list)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
            Button {
                renameText = list.name
                renaming = list
            } label: {
                Label("Renombrar", systemImage: "pencil")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if list.canRefresh {
                Button {
                    refresh([list])
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if list.canRefresh {
                Button("Actualizar", systemImage: "arrow.clockwise") { refresh([list]) }
            }
            Button("Renombrar", systemImage: "pencil") {
                renameText = list.name
                renaming = list
            }
            Button("Eliminar", systemImage: "trash", role: .destructive) { deleteList(list) }
        }
    }

    /// Guarda (o reemplaza) una lista y sus canales en la biblioteca.
    private func saveList(_ template: SavedList, streams new: [Stream]) {
        let id = template.id
        let tagged = new.map { stream -> Stream in
            var copy = stream
            copy.sourceID = id
            return copy
        }
        streams = StreamCatalog.merge(streams.filter { $0.sourceID != id }, tagged)
        var entry = template
        entry.name = lists.first(where: { $0.id == id })?.name ?? (template.name.isEmpty ? "Lista" : template.name)
        entry.count = tagged.count
        entry.updated = Date()
        if let index = lists.firstIndex(where: { $0.id == id }) {
            lists[index] = entry
        } else {
            lists.append(entry)
        }
        search = ""
        LibraryStore.save(streams)
        LibraryStore.saveLists(lists)
    }

    private func deleteList(_ list: SavedList) {
        streams.removeAll { $0.sourceID == list.id }
        lists.removeAll { $0.id == list.id }
        LibraryStore.save(streams)
        LibraryStore.saveLists(lists)
    }

    private func refresh(_ targets: [SavedList]) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            await load(targets)
        }
    }

    private func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await load(lists.filter(\.canRefresh))
    }

    /// Descarga cada lista y la guarda. Devuelve true si todas cargaron.
    @discardableResult
    private func load(_ targets: [SavedList]) async -> Bool {
        var failed: [String] = []
        var lastError: Error?
        for list in targets {
            do {
                saveList(list, streams: try await StreamCatalog.fetch(list))
            } catch {
                failed.append(list.name)
                lastError = error
            }
        }
        if failed.count == 1, let lastError {
            self.error = "\(failed[0]): " + importMessage(lastError)
        } else if !failed.isEmpty {
            self.error = "No se pudo cargar: " + failed.joined(separator: ", ") + ". Revisa el enlace o tu conexión."
        }
        return failed.isEmpty
    }

    private var sourcesScreen: some View {
        List {
            Section {
                Text("Listas públicas de canales gratuitos en abierto (iptv-org y Free-TV). Toca una para añadirla a tu biblioteca. Algunos canales pueden estar caídos o bloqueados por región.")
                    .font(.footnote)
                    .foregroundStyle(Color.xuperMuted)
            }
            .listRowBackground(Color.xuperSurface)

            ForEach(PublicSource.sections) { section in
                Section(section.title) {
                    ForEach(section.sources) { source in
                        sourceRow(source)
                    }
                }
                .listRowBackground(Color.xuperSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.xuperBackground)
        .navigationTitle("Listas gratuitas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sourceRow(_ source: PublicSource) -> some View {
        let isAdded = addedSources.contains(source.id)
        return Button {
            addSources([source])
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                    Text(source.detail)
                        .font(.footnote)
                        .foregroundStyle(Color.xuperMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isAdded ? Color.green : Color.xuperRed)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func addSources(_ sources: [PublicSource]) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            await load(sources.map {
                SavedList(id: $0.id, name: $0.name, url: $0.url, count: 0, updated: Date(), kind: .free)
            })
        }
    }

    private func present(_ mode: AddMode) {
        form = SourceForm()
        formError = nil
        addMode = mode
    }

    private func runPendingAction() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    private func submitForm(_ mode: AddMode, playNow: Bool) {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: SavedList
        switch mode {
        case .xtream:
            let server = form.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let root = Xtream.root(server) else {
                formError = "Escribe la dirección del servidor, por ejemplo servidor.com:8080"
                return
            }
            guard !user.isEmpty, !form.password.isEmpty else {
                formError = "Escribe el usuario y la contraseña de tu cuenta."
                return
            }
            guard form.live || form.movies else {
                formError = "Activa TV en vivo, Películas o ambas."
                return
            }
            list = SavedList(id: UUID().uuidString, name: name.isEmpty ? (root.host ?? "Xtream") : name,
                             url: root, count: 0, updated: Date(), kind: .xtream,
                             xtream: Xtream.Login(server: server, username: user, password: form.password,
                                                  live: form.live, movies: form.movies))
        case .m3u, .hls, .custom:
            guard let url = Stream.userURL(form.url) else {
                formError = "Escribe un enlace válido, por ejemplo midominio.com/lista.m3u"
                return
            }
            var headers: [String: String] = [:]
            let agent = form.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            let referer = form.referer.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .custom, !agent.isEmpty { headers["User-Agent"] = agent }
            if mode == .custom, !referer.isEmpty { headers["Referer"] = referer }
            let fallback = mode == .hls ? (url.deletingPathExtension().lastPathComponent) : (url.host ?? "Lista")
            list = SavedList(id: UUID().uuidString, name: name.isEmpty ? fallback : name, url: url,
                             count: 0, updated: Date(), kind: mode.kind, headers: headers.isEmpty ? nil : headers)
        }

        let target = list
        if playNow, let url = target.url {
            pendingAction = { selected = Stream(title: target.name, group: "", url: url) }
        } else {
            pendingAction = {
                isLoading = true
                Task {
                    defer { isLoading = false }
                    if await load([target]) {
                        screen = mode == .hls ? .live : .home
                    }
                }
            }
        }
        addMode = nil
    }

    private func importMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Comprueba que la lista esté disponible y vuelve a intentarlo."
    }
}

private enum AddMode: String, CaseIterable, Identifiable {
    case m3u, hls, xtream, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m3u: "Lista M3U"
        case .hls: "Señal HLS"
        case .xtream: "Xtream Codes"
        case .custom: "Personalizado"
        }
    }

    var symbol: String {
        switch self {
        case .m3u: "list.bullet.rectangle"
        case .hls: "dot.radiowaves.left.and.right"
        case .xtream: "server.rack"
        case .custom: "slider.horizontal.3"
        }
    }

    var help: String {
        switch self {
        case .m3u: "Enlace directo a una lista .m3u o .m3u8 con varios canales. Si no pones https:// se añade solo."
        case .hls: "Enlace de un solo canal o video en HLS (.m3u8). Se guarda en TV."
        case .xtream: "Los datos que te dio tu proveedor IPTV: servidor con puerto, usuario y contraseña. Se cargan TV en vivo y películas."
        case .custom: "Lista M3U de un servidor que exige identificarse."
        }
    }

    var kind: SavedList.Kind {
        switch self {
        case .m3u: .m3u
        case .hls: .hls
        case .xtream: .xtream
        case .custom: .custom
        }
    }
}

private struct SourceForm {
    var name = ""
    var url = ""
    var username = ""
    var password = ""
    var userAgent = ""
    var referer = ""
    var live = true
    var movies = true
}

// MARK: Componentes

private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("XUPER").foregroundStyle(Color.xuperRed)
            Text("iOS").foregroundStyle(.white)
        }
        .font(.system(size: 20, weight: .black, design: .rounded))
        .accessibilityLabel("XuperiOS")
    }
}

/// Portada: usa tvg-logo si la lista lo trae; si no, un degradado con iniciales.
private struct Artwork: View {
    let stream: Stream
    var fit: Bool

    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [Color(hue: stream.hue, saturation: 0.6, brightness: 0.38), Color.xuperSurface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay {
                Text(stream.initials)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .overlay {
                if let logo = stream.logo {
                    AsyncImage(url: logo) { phase in
                        if let image = phase.image {
                            if fit {
                                image.resizable().scaledToFit().padding(6).background(Color.xuperRaised)
                            } else {
                                image.resizable().scaledToFill()
                            }
                        }
                    }
                }
            }
            .clipped()
    }
}

private struct PosterCard: View {
    let stream: Stream
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(stream: stream, fit: false)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(stream.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PosterGrid: View {
    let streams: [Stream]
    let action: (Stream) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 16) {
            ForEach(streams) { stream in
                GeometryReader { proxy in
                    PosterCard(stream: stream, width: proxy.size.width) { action(stream) }
                }
                .aspectRatio(0.52, contentMode: .fit)
            }
        }
    }
}

private struct ChannelRow: View {
    let stream: Stream
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Artwork(stream: stream, fit: true)
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let now = Guide.shared.schedule(for: stream).now {
                        Text("Ahora: \(now.t)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.xuperRed)
                            .lineLimit(1)
                    } else if !stream.group.isEmpty {
                        Text(stream.group)
                            .font(.footnote)
                            .foregroundStyle(Color.xuperMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.xuperRed)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.xuperBackground)
    }
}

// MARK: Reproductor

private struct PlaybackView: View {
    let stream: Stream
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var item: AVPlayerItem?
    @State private var status = AVPlayerItem.Status.unknown

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if status == .failed {
                ContentUnavailableView(
                    "No se pudo reproducir",
                    systemImage: "exclamationmark.circle",
                    description: Text("Comprueba que el enlace siga activo y sea compatible con iOS (HLS, MP4 o MOV).")
                )
            } else {
                if let player, let item {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                        .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) {
                            status = $0
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item
                        ).receive(on: DispatchQueue.main)) { _ in
                            status = .failed
                        }
                }
                if status == .unknown {
                    ProgressView()
                        .tint(Color.xuperRed)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("Cerrar")
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    let schedule = Guide.shared.schedule(for: stream)
                    if let now = schedule.now {
                        Text("Ahora: \(now.t) · hasta \(now.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.xuperRed)
                            .lineLimit(1)
                    }
                    if let next = schedule.next {
                        Text("Siguiente: \(next.t) · \(next.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .shadow(radius: 4)
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .task {
            guard player == nil else { return }
            var options: [String: Any] = [:]
            if let headers = stream.headers, !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            let asset = AVURLAsset(url: stream.url, options: options)
            let playbackItem = AVPlayerItem(asset: asset)
            let playback = AVPlayer(playerItem: playbackItem)
            item = playbackItem
            player = playback
            playback.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}
