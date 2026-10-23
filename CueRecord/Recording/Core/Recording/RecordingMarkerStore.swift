import Foundation

/// 录制中打的标记（学习 Screen Studio 的 addMarker）。
/// 写在 <输出>_markers.json，时间取成片时间轴（已扣除暂停段），
/// 剪辑/重录时按标记快速定位"这段要"或"这段重来"。
nonisolated struct RecordingMarker: Codable, Sendable, Equatable {
    var index: Int
    var elapsedSeconds: Double
    var createdAt: Date
}

nonisolated enum RecordingMarkerStore {
    static func markersURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_markers.json")
    }

    static func load(from url: URL) -> [RecordingMarker] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingMarker].self, from: data)) ?? []
    }

    static func save(_ markers: [RecordingMarker], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(markers) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func append(elapsedSeconds: TimeInterval, to url: URL) -> RecordingMarker {
        var markers = load(from: url)
        let marker = RecordingMarker(
            index: markers.count,
            elapsedSeconds: elapsedSeconds,
            createdAt: Date()
        )
        markers.append(marker)
        save(markers, to: url)
        return marker
    }
}
