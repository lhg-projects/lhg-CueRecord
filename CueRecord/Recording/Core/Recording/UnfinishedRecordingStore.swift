import Foundation

/// 未完成录制的磁盘清单（学习 Screen Studio 的 unfinishedRecordings 设计）。
/// 录制开始即登记，停录成功后移除；应用启动时清单非空 = 上次异常退出，
/// 提示用户去查看素材，而不是让坏文件无声无息躺在文件夹里。
nonisolated struct UnfinishedRecordingEntry: Codable, Sendable, Equatable {
    var id: String
    var outputURLPath: String
    var startedAt: Date
    var lastUpdatedAt: Date
    var state: String

    init(
        id: String,
        outputURLPath: String,
        startedAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        state: String = "recording"
    ) {
        self.id = id
        self.outputURLPath = outputURLPath
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.state = state
    }
}

nonisolated enum UnfinishedRecordingStore {
    static let bundleIdentifier = "com.liulaoshi.llsstudio"
    static let fileName = "unfinished-recordings.json"

    static func defaultStoreURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load(from storeURL: URL) -> [UnfinishedRecordingEntry] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UnfinishedRecordingEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [UnfinishedRecordingEntry], to storeURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// 登记或更新一条录制。以 id（输出文件名）去重，保留同一文件先前的 startedAt。
    static func upsert(_ entry: UnfinishedRecordingEntry, to storeURL: URL) {
        var entries = load(from: storeURL)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var updated = entry
            updated.startedAt = entries[index].startedAt
            entries[index] = updated
        } else {
            entries.append(entry)
        }
        save(entries, to: storeURL)
    }

    static func remove(id: String, from storeURL: URL) {
        var entries = load(from: storeURL)
        entries.removeAll { $0.id == id }
        save(entries, to: storeURL)
    }

    /// 纯函数：清单里哪些条目已经没有可恢复的素材（文件不存在）。
    static func entryIDsWithoutOutput(
        _ entries: [UnfinishedRecordingEntry],
        fileManager: FileManager = .default
    ) -> [String] {
        entries
            .filter { !fileManager.fileExists(atPath: $0.outputURLPath) }
            .map(\.id)
    }

    static func removeEntries(ids: [String], from storeURL: URL) {
        guard !ids.isEmpty else { return }
        var entries = load(from: storeURL)
        entries.removeAll { ids.contains($0.id) }
        save(entries, to: storeURL)
    }
}
