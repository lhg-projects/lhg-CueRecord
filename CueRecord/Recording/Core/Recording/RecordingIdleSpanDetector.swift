import Foundation

/// 闲段检测（学习 HuaStudio 的 quietSpans：**没说话 ∧ 没操作**的段，
/// 剪掉或 3× 最安全）。数据源就是我们的两个侧车：
/// - `_transcript.json`（说话）
/// - `_cursor.json`（操作；光标静止时本来就不产样本，静止即闲）
/// 加上「开录头 1.5s 自动裁」的建议（HuaStudio segments s=1500，
/// 录制启动时的鼠标找位、窗口切换）。
nonisolated struct IdleSpan: Codable, Sendable, Equatable {
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

nonisolated struct IdleSuggestion: Codable, Sendable, Equatable {
    var span: IdleSpan
    /// cut = 建议整段剪掉；speed = 建议加速
    var action: String
    var speed: Double
}

nonisolated struct IdleSpanFile: Codable, Sendable, Equatable {
    var version: Int
    /// 开头自动裁剪建议（秒）。总是给出（时长足够时）。
    var suggestedTrimStart: Double?
    var suggestions: [IdleSuggestion]
    var hint: String
}

nonisolated enum RecordingIdleSpanDetector {
    struct Configuration: Sendable {
        /// 短于此不算闲段（HuaStudio 实测样例最短 1.65s）
        var minimumIdleSeconds: Double = 1.5
        /// 说话/操作前后各留保护边，防止切到字头/操作起手
        var guardSeconds: Double = 0.25
        /// 开录头裁剪建议（HuaStudio 实测 segments s=1500）
        var headTrimSeconds: Double = 1.5
        var suggestedSpeed: Double = 3
        /// 达到该时长才建议整段剪掉，否则建议加速
        var minimumCutSeconds: Double = 2.5
    }

    static func detect(
        totalDuration: Double,
        transcript: [TranscriptSegment],
        cursorEvents: [CursorEventSample],
        configuration: Configuration = Configuration()
    ) -> IdleSpanFile {
        // quietSpans 的定义要求"确认没说话"。转写缺失（提词器识别没开）
        // 时无法确认，宁缺毋滥：不给闲段建议，只给开头裁剪。
        guard !transcript.isEmpty else {
            return IdleSpanFile(
                version: 1,
                suggestedTrimStart: headTrim(totalDuration: totalDuration, configuration: configuration),
                suggestions: [],
                hint: "没有转写数据（录制时提词器识别未开启），无法确认\"没说话\"，不生成闲段建议；仅建议裁掉开头。"
            )
        }

        // 忙碌区间 = 说话段 ∪ 操作时刻，各加保护边
        var busy: [ClosedRange<Double>] = []
        for segment in transcript {
            busy.append((segment.start - configuration.guardSeconds)...(segment.end + configuration.guardSeconds))
        }
        for event in cursorEvents {
            busy.append((event.t - configuration.guardSeconds)...(event.t + configuration.guardSeconds))
        }

        let searchStart = headTrim(totalDuration: totalDuration, configuration: configuration) ?? 0
        let idleSpans = complement(
            of: busy,
            in: searchStart...(max(totalDuration - configuration.guardSeconds, searchStart)),
            minimumDuration: configuration.minimumIdleSeconds
        )

        let suggestions = idleSpans.map { span -> IdleSuggestion in
            if span.duration >= configuration.minimumCutSeconds {
                return IdleSuggestion(span: span, action: "cut", speed: configuration.suggestedSpeed)
            }
            return IdleSuggestion(span: span, action: "speed", speed: configuration.suggestedSpeed)
        }

        return IdleSpanFile(
            version: 1,
            suggestedTrimStart: headTrim(totalDuration: totalDuration, configuration: configuration),
            suggestions: suggestions,
            hint: "cut=没说话且没操作，剪掉最安全；speed=嫌短舍不得剪就 3× 加速。时间轴为成片时间（已扣除暂停段）。"
        )
    }

    private static func headTrim(totalDuration: Double, configuration: Configuration) -> Double? {
        guard totalDuration > configuration.headTrimSeconds + 1 else { return nil }
        return configuration.headTrimSeconds
    }

    /// 区间补集：把忙碌区间排序合并后取空隙，只保留 ≥ minimumDuration 的
    private static func complement(
        of busy: [ClosedRange<Double>],
        in scope: ClosedRange<Double>,
        minimumDuration: Double
    ) -> [IdleSpan] {
        let merged = busy
            .filter { $0.lowerBound <= scope.upperBound && $0.upperBound >= scope.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
            .reduce(into: [ClosedRange<Double>]()) { result, range in
                let clamped = max(range.lowerBound, scope.lowerBound)...min(range.upperBound, scope.upperBound)
                guard clamped.lowerBound <= clamped.upperBound else { return }
                if let last = result.last, clamped.lowerBound <= last.upperBound {
                    result[result.count - 1] = last.lowerBound...max(last.upperBound, clamped.upperBound)
                } else {
                    result.append(clamped)
                }
            }

        var spans: [IdleSpan] = []
        var cursor = scope.lowerBound
        for range in merged {
            if range.lowerBound - cursor >= minimumDuration {
                spans.append(IdleSpan(start: cursor, end: range.lowerBound))
            }
            cursor = max(cursor, range.upperBound)
        }
        if scope.upperBound - cursor >= minimumDuration {
            spans.append(IdleSpan(start: cursor, end: scope.upperBound))
        }
        return spans
    }
}

nonisolated enum IdleSpanStore {
    static func idleURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_idle.json")
    }

    static func save(_ file: IdleSpanFile, for outputURL: URL) {
        guard file.suggestedTrimStart != nil || !file.suggestions.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: idleURL(for: outputURL), options: .atomic)
    }

    static func load(from url: URL) -> IdleSpanFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IdleSpanFile.self, from: data)
    }
}
