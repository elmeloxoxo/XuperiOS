import Foundation
import Observation

struct Stream: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let title: String
    let group: String
    let url: URL
    var logo: URL? = nil
    var tvgID: String? = nil
    /// Lista guardada de la que viene (SavedList.id).
    var sourceID: String? = nil

    /// País (dos letras) a partir del tvg-id, por ejemplo "ATV.pe@SD" -> "pe".
    var country: String? {
        guard let tvgID, let base = tvgID.split(separator: "@").first,
              let suffix = base.split(separator: ".").last, suffix.count == 2, base.contains(".") else { return nil }
        return suffix.lowercased()
    }

    /// Nombre simplificado para cruzar con la guía. Debe coincidir con normalize() en scripts/build_epg.py.
    static func normalizedName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let cleaned = folded.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        let drop: Set<String> = ["hd", "sd", "fhd", "uhd", "4k", "tv", "television", "channel", "canal"]
        return cleaned
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+")) })
            .map(String.init)
            .filter { !drop.contains($0) }
            .joined()
    }

    static let demo = Stream(
        title: "Bip Bop",
        group: "Señal de prueba",
        url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
    )

    /// Acepta enlaces HTTP y HTTPS (Info.plist permite HTTP porque muchas listas IPTV lo usan).
    static func webURL(_ text: String, relativeTo base: URL? = nil) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              let url = URL(string: input, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Iniciales para la portada cuando la lista no trae imagen.
    var initials: String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }

    /// Tono estable derivado del título para dar color a las portadas sin imagen.
    var hue: Double {
        let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(sum % 360) / 360
    }
}

enum StreamCatalog {
    static let byteLimit = 16 * 1024 * 1024

    enum ImportError: LocalizedError {
        case invalidFile, emptyList, tooLarge, serverResponse, localHLS

        var errorDescription: String? {
            switch self {
            case .invalidFile: "El archivo no es una lista M3U válida."
            case .emptyList: "La lista no contiene enlaces HTTP o HTTPS compatibles."
            case .tooLarge: "La lista supera los 16 MB."
            case .serverResponse: "El servidor no devolvió una lista válida."
            case .localHLS: "Abre el enlace del video para reproducir este manifiesto HLS."
            }
        }
    }

    static func parse(_ data: Data, base: URL? = nil) throws -> [Stream] {
        guard data.count <= byteLimit else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { throw ImportError.invalidFile }

        let lines = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .split(whereSeparator: \.isNewline)
        let header = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces)
        let hasHeader = header?.hasPrefix("#EXTM3U") == true
        guard hasHeader || header.flatMap({ Stream.webURL($0) }) != nil else {
            throw ImportError.invalidFile
        }

        var streams: [Stream] = []
        var title = ""
        var group = ""
        var logo: URL?
        var tvgID: String?
        var isHLS = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-") {
                isHLS = true
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                title = entryTitle(line)
                group = attribute("group-title", in: line) ?? ""
                logo = attribute("tvg-logo", in: line).flatMap { Stream.webURL($0) }
                tvgID = attribute("tvg-id", in: line)
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let url = Stream.webURL(line, relativeTo: hasHeader ? base : nil), isPlayable(url) {
                streams.append(Stream(
                    title: title.isEmpty ? url.lastPathComponent.nonEmpty ?? url.host ?? "Señal" : title,
                    group: group,
                    url: url,
                    logo: logo,
                    tvgID: tvgID
                ))
            }
            title = ""
            group = ""
            logo = nil
            tvgID = nil
        }
        if isHLS {
            guard let base else { throw ImportError.localHLS }
            return [Stream(title: base.lastPathComponent.nonEmpty ?? "Video", group: "HLS", url: base)]
        }
        guard !streams.isEmpty else { throw ImportError.emptyList }
        return streams
    }

    static func download(_ url: URL) async throws -> [Stream] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let target = http.url.flatMap({ Stream.webURL($0.absoluteString) }) else {
            throw ImportError.serverResponse
        }
        guard http.expectedContentLength <= Int64(byteLimit) else { throw ImportError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < byteLimit else { throw ImportError.tooLarge }
            data.append(byte)
        }
        return try parse(data, base: target)
    }

    static func readFile(_ url: URL) throws -> [Stream] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try parse(file.read(upToCount: byteLimit + 1) ?? Data())
    }

    private static func entryTitle(_ line: String) -> String {
        var inQuotes = false
        for index in line.indices {
            switch line[index] {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                return line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return ""
    }

    /// AVPlayer no reproduce páginas de YouTube ni Twitch, así que se omiten.
    private static func isPlayable(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return !["youtube.com", "youtu.be", "twitch.tv", "dailymotion.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=\""),
              let end = line[range.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = String(line[range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Una lista que el usuario añadió (por enlace, archivo o desde Listas gratuitas).
struct SavedList: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var url: URL?
    var count: Int
    var updated: Date
}

/// Guarda la biblioteca en el iPhone para que siga ahí al volver a abrir la app.
enum LibraryStore {
    private static var listsURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("lists.json")
    }

    static func loadLists() -> [SavedList] {
        guard let data = try? Data(contentsOf: listsURL) else { return [] }
        return (try? JSONDecoder().decode([SavedList].self, from: data)) ?? []
    }

    static func saveLists(_ lists: [SavedList]) {
        if let data = try? JSONEncoder().encode(lists) {
            try? data.write(to: listsURL, options: .atomic)
        }
    }

    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("library.json")
    }

    static func load() -> [Stream] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Stream].self, from: data)) ?? []
    }

    static func save(_ streams: [Stream]) {
        if streams.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else if let data = try? JSONEncoder().encode(streams) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Listas públicas y gratuitas de iptv-org (canales libres en abierto) y Free-TV/IPTV.
struct PublicSource: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let url: URL

    init(_ id: String, _ name: String, _ detail: String, path: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.url = URL(string: "https://raw.githubusercontent.com/iptv-org/iptv/gh-pages/" + path)!
    }

    init(_ id: String, _ name: String, _ detail: String, url: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.url = URL(string: url)!
    }

    struct Section: Identifiable {
        let title: String
        let sources: [PublicSource]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Perú y Latinoamérica", sources: [
            PublicSource("pe", "Perú", "~220 canales", path: "countries/pe.m3u"),
            PublicSource("hispam", "Hispanoamérica", "~2100 canales de la región", path: "regions/hispam.m3u"),
            PublicSource("spa", "Todo en español", "~2400 canales", path: "languages/spa.m3u"),
            PublicSource("mx", "México", "~180 canales", path: "countries/mx.m3u"),
            PublicSource("ar", "Argentina", "~220 canales", path: "countries/ar.m3u"),
            PublicSource("co", "Colombia", "~170 canales", path: "countries/co.m3u"),
            PublicSource("cl", "Chile", "~220 canales", path: "countries/cl.m3u"),
            PublicSource("ec", "Ecuador", "~120 canales", path: "countries/ec.m3u"),
            PublicSource("ve", "Venezuela", "~100 canales", path: "countries/ve.m3u"),
            PublicSource("es", "España", "~300 canales", path: "countries/es.m3u"),
        ]),
        Section(title: "Free-TV (canales oficiales en abierto)", sources: [
            PublicSource.freeTV("ftv-pe", "Perú (Free-TV)", "Canales nacionales en abierto", "peru"),
            PublicSource.freeTV("ftv-mx", "México (Free-TV)", "Canales nacionales en abierto", "mexico"),
            PublicSource.freeTV("ftv-ar", "Argentina (Free-TV)", "Canales nacionales en abierto", "argentina"),
            PublicSource.freeTV("ftv-cl", "Chile (Free-TV)", "Canales nacionales en abierto", "chile"),
            PublicSource.freeTV("ftv-ve", "Venezuela (Free-TV)", "Canales nacionales en abierto", "venezuela"),
            PublicSource.freeTV("ftv-py", "Paraguay (Free-TV)", "Canales nacionales en abierto", "paraguay"),
            PublicSource.freeTV("ftv-cr", "Costa Rica (Free-TV)", "Canales nacionales en abierto", "costa_rica"),
            PublicSource.freeTV("ftv-do", "República Dominicana (Free-TV)", "Canales nacionales en abierto", "dominican_republic"),
            PublicSource.freeTV("ftv-es", "España (Free-TV)", "TDT y autonómicas", "spain"),
            PublicSource.freeTV("ftv-esvod", "España a la carta (Free-TV)", "Contenido bajo demanda gratuito", "spain_vod"),
            PublicSource.freeTV("ftv-movies", "Películas (Free-TV)", "Canales de cine gratuitos", "zz_movies"),
            PublicSource.freeTV("ftv-newses", "Noticias en español (Free-TV)", "Canales de noticias", "zz_news_es"),
            PublicSource.freeTV("ftv-docs", "Documentales (Free-TV)", "Canales documentales", "zz_documentaries_en"),
            PublicSource.freeTV("ftv-usvod", "EE. UU. a la carta (Free-TV)", "Contenido bajo demanda gratuito", "usa_vod"),
        ]),
        Section(title: "Por categoría (todos los idiomas)", sources: [
            PublicSource("movies", "Películas", "~770 canales", path: "categories/movies.m3u"),
            PublicSource("series", "Series", "~480 canales", path: "categories/series.m3u"),
            PublicSource("kids", "Kids", "~450 canales", path: "categories/kids.m3u"),
            PublicSource("animation", "Animación", "~170 canales", path: "categories/animation.m3u"),
            PublicSource("sports", "Deportes", "~520 canales", path: "categories/sports.m3u"),
            PublicSource("documentary", "Documentales", "~240 canales", path: "categories/documentary.m3u"),
            PublicSource("comedy", "Comedia", "~190 canales", path: "categories/comedy.m3u"),
            PublicSource("classic", "Clásicos", "~80 canales", path: "categories/classic.m3u"),
            PublicSource("entertainment", "Entretenimiento", "~900 canales", path: "categories/entertainment.m3u"),
            PublicSource("music", "Música", "~800 canales", path: "categories/music.m3u"),
            PublicSource("news", "Noticias", "~1050 canales", path: "categories/news.m3u"),
        ]),
        Section(title: "Mundo", sources: [
            PublicSource("us", "Estados Unidos", "~1500 canales", path: "countries/us.m3u"),
            PublicSource("freetv", "Free-TV (selección mundial)", "~2200 canales en abierto", url: "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8"),
        ]),
    ]

    static func freeTV(_ id: String, _ name: String, _ detail: String, _ file: String) -> PublicSource {
        PublicSource(id, name, detail, url: "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_\(file).m3u8")
    }

    /// Lo que se carga con un toque desde la pantalla vacía.
    static var starter: [PublicSource] {
        sections.flatMap(\.sources).filter { ["pe", "hispam", "ftv-pe"].contains($0.id) }
    }
}

extension StreamCatalog {
    /// Une listas sin repetir enlaces.
    static func merge(_ current: [Stream], _ new: [Stream]) -> [Stream] {
        var seen = Set(current.map(\.url))
        return current + new.filter { seen.insert($0.url).inserted }
    }
}

// MARK: Guía de programación

struct Programme: Codable, Hashable, Sendable {
    let s: Double
    let e: Double
    let t: String

    var start: Date { Date(timeIntervalSince1970: s) }
    var end: Date { Date(timeIntervalSince1970: e) }
}

struct GuideFile: Codable, Sendable {
    let generated: Double
    let channels: [String: [Programme]]
    let aliases: [String: String]?
}

/// Guía "Ahora / Siguiente". El archivo lo genera .github/workflows/epg.yml.
@Observable
@MainActor
final class Guide {
    static let shared = Guide()
    static let url = URL(string: "https://github.com/elmeloxoxo/XuperiOS/releases/download/epg/epg.json")!

    private(set) var channels: [String: [Programme]] = [:]
    private var aliases: [String: String] = [:]
    private var loadedAt: Date?

    private static var cacheURL: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("epg.json")
    }

    func refresh() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 3 * 3600 { return }
        if channels.isEmpty, let cached = await Self.decode(contentsOf: Self.cacheURL) {
            channels = cached.channels
            aliases = cached.aliases ?? [:]
        }
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let file = await Self.decode(data) else { return }
        channels = file.channels
        aliases = file.aliases ?? [:]
        loadedAt = Date()
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    func schedule(for stream: Stream, at date: Date = Date()) -> (now: Programme?, next: Programme?) {
        guard !channels.isEmpty else { return (nil, nil) }
        let name = Stream.normalizedName(stream.title)
        guard !name.isEmpty else { return (nil, nil) }
        let exact = stream.country.flatMap { channels["\(name)|\($0)"] }
        guard let list = exact ?? aliases[name].flatMap({ channels[$0] }) else { return (nil, nil) }
        let time = date.timeIntervalSince1970
        guard let index = list.firstIndex(where: { $0.e > time }) else { return (nil, nil) }
        let current = list[index].s <= time ? list[index] : nil
        let nextIndex = current == nil ? index : index + 1
        return (current, nextIndex < list.count ? list[nextIndex] : nil)
    }

    nonisolated private static func decode(contentsOf url: URL) async -> GuideFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await decode(data)
    }

    nonisolated private static func decode(_ data: Data) async -> GuideFile? {
        await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(GuideFile.self, from: data)
        }.value
    }
}
