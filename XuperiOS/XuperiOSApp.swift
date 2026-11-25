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
    @State private var showsLink = false
    @State private var showsFiles = false
    @State private var address = ""
    @State private var linkError = false
    @State private var pendingLink: (URL, Bool)?
    @State private var isLoading = false
    @State private var error: String?
    @State private var didLoad = false
    @State private var lists: [SavedList] = []
    @State private var listName = ""
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
        .sheet(isPresented: $showsLink, onDismiss: openPendingLink) { linkSheet }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item]) { result in
            do {
                let file = try result.get()
                let imported = try StreamCatalog.readFile(file)
                saveList(name: file.deletingPathExtension().lastPathComponent, url: nil, streams: imported)
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
                Button("Pegar enlace") { presentLinkSheet() }
                    .buttonStyle(.bordered)
                Button("Importar archivo") { showsFiles = true }
                    .buttonStyle(.bordered)
            }
            .disabled(isLoading)
        }
    }

    private var linkSheet: some View {
        NavigationStack {
            Form {
                TextField("Nombre de la lista (opcional)", text: $listName)
                TextField("https://…", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Enlace")
                    .onChange(of: address) { linkError = false }
                if linkError {
                    Text("Introduce un enlace HTTP o HTTPS válido.")
                        .foregroundStyle(Color.xuperRed)
                }
                Button("Guardar y cargar lista M3U") { submitAddress(asPlaylist: true) }
                    .fontWeight(.semibold)
                Button("Reproducir video") { submitAddress(asPlaylist: false) }
            }
            .navigationTitle("Abrir enlace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { showsLink = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ToolbarContentBuilder
    private var sourceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Abrir enlace", systemImage: "link") { presentLinkSheet() }
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
                Button {
                    presentLinkSheet()
                } label: {
                    Label("Añadir lista por enlace (URL)", systemImage: "link.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.xuperRed, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
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
            Image(systemName: list.url == nil ? "doc.fill" : "link")
                .font(.title3)
                .foregroundStyle(Color.xuperRed)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(list.count) canales · \(list.updated.formatted(.relative(presentation: .named)))")
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
            if list.url != nil {
                Button {
                    refresh([list])
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if list.url != nil {
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
    private func saveList(id: String = UUID().uuidString, name: String, url: URL?, streams new: [Stream]) {
        let tagged = new.map { stream -> Stream in
            var copy = stream
            copy.sourceID = id
            return copy
        }
        streams = StreamCatalog.merge(streams.filter { $0.sourceID != id }, tagged)
        let entry = SavedList(
            id: id,
            name: lists.first(where: { $0.id == id })?.name ?? (name.isEmpty ? "Lista" : name),
            url: url,
            count: tagged.count,
            updated: Date()
        )
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
            await download(targets.compactMap { list in list.url.map { (id: list.id, name: list.name, url: $0) } })
        }
    }

    private func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await download(lists.compactMap { list in list.url.map { (id: list.id, name: list.name, url: $0) } })
    }

    private func download(_ items: [(id: String, name: String, url: URL)]) async {
        var failed: [String] = []
        for item in items {
            do {
                saveList(id: item.id, name: item.name, url: item.url, streams: try await StreamCatalog.download(item.url))
            } catch {
                failed.append(item.name)
            }
        }
        if !failed.isEmpty {
            self.error = "No se pudo cargar: " + failed.joined(separator: ", ") + ". Revisa el enlace o tu conexión."
        }
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
            await download(sources.map { (id: $0.id, name: $0.name, url: $0.url) })
        }
    }

    private func presentLinkSheet() {
        address = ""
        listName = ""
        linkError = false
        showsLink = true
    }

    private func submitAddress(asPlaylist: Bool) {
        guard let url = Stream.webURL(address) else {
            linkError = true
            return
        }
        pendingLink = (url, asPlaylist)
        showsLink = false
    }

    private func openPendingLink() {
        guard let (url, asPlaylist) = pendingLink else { return }
        pendingLink = nil
        if asPlaylist {
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    let name = listName.trimmingCharacters(in: .whitespacesAndNewlines)
                    saveList(name: name.isEmpty ? (url.host ?? "Lista") : name, url: url,
                             streams: try await StreamCatalog.download(url))
                    screen = .lists
                } catch {
                    self.error = importMessage(error)
                }
            }
        } else {
            let title = url.lastPathComponent.isEmpty ? url.host ?? "Video" : url.lastPathComponent
            selected = Stream(title: title, group: "", url: url)
        }
    }

    private func importMessage(_ error: Error) -> String {
        (error as? StreamCatalog.ImportError)?.errorDescription
            ?? "Comprueba que la lista esté disponible y vuelve a intentarlo."
    }
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
            let playbackItem = AVPlayerItem(url: stream.url)
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
