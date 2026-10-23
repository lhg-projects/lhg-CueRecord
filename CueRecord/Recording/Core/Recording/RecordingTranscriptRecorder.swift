import Foundation

/// 录制转写落盘（学习 Screen Studio 的 transcript/SRT 能力，但识别用
/// 本地已有的 paraformer 流式识别，不加新依赖）。
/// 分段语义：ASR 的 onTextUpdate 是"当前分段内累计文本"，onNewSegment
/// 即 endpoint（该段定稿）。时间轴用成片时间（已扣除暂停段）。
nonisolated struct TranscriptSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

nonisolated struct RecordingTranscriptAccumulator: Sendable {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var currentText: String = ""
    private(set) var currentStart: Double?
    private(set) var currentLastUpdate: Double?

    mutating func ingestUpdate(_ text: String, at elapsed: Double) {
        if currentStart == nil { currentStart = elapsed }
        currentText = text
        currentLastUpdate = elapsed
    }

    mutating func closeSegment(at elapsed: Double) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let start = currentStart {
            let end = max(elapsed, currentLastUpdate ?? elapsed, start)
            segments.append(TranscriptSegment(start: start, end: end, text: trimmed))
        }
        currentText = ""
        currentStart = nil
        currentLastUpdate = nil
    }
}

nonisolated enum TranscriptSRTSerializer {
    static func transcriptURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_transcript.json")
    }

    static func srtURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base).srt")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds * 1000))
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func srtText(from segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let blocks = segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(segment.end))\n\(segment.text)"
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func saveTranscript(_ segments: [TranscriptSegment], for outputURL: URL) {
        guard !segments.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(segments) {
            try? data.write(to: transcriptURL(for: outputURL), options: .atomic)
        }
        let srt = srtText(from: segments)
        try? srt.data(using: .utf8)?.write(to: srtURL(for: outputURL), options: .atomic)
    }
}
