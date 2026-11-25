import Foundation

struct Stream: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let title: String
    let group: String
    let url: URL
    var logo: URL? = nil

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
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let url = Stream.webURL(line, relativeTo: hasHeader ? base : nil) {
                streams.append(Stream(
                    title: title.isEmpty ? url.lastPathComponent.nonEmpty ?? url.host ?? "Señal" : title,
                    group: group,
                    url: url,
                    logo: logo
                ))
            }
            title = ""
            group = ""
            logo = nil
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

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=\""),
              let end = line[range.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = String(line[range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Guarda la biblioteca en el iPhone para que siga ahí al volver a abrir la app.
enum LibraryStore {
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
