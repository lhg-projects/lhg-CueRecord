import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// 缩放区间（学习 Screen Studio 的 ZoomRange：核心是"什么时候、
/// 对屏幕哪一块、放大多少、用什么缓动进出"）。时间轴 = 源视频时间轴。
nonisolated struct ZoomRange: Codable, Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    /// 聚焦中心，归一化到录制矩形（左上原点）
    var centerX: Double
    var centerY: Double
    var zoomScale: Double
    /// 进/出缓动时长（秒）
    var easingSeconds: Double

    init(
        startSeconds: Double,
        endSeconds: Double,
        centerX: Double,
        centerY: Double,
        zoomScale: Double = 2.0,
        easingSeconds: Double = 0.38
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.centerX = centerX
        self.centerY = centerY
        self.zoomScale = zoomScale
        self.easingSeconds = easingSeconds
    }
}

nonisolated struct ZoomRangeFile: Codable, Sendable, Equatable {
    var version: Int
    var source: String
    var ranges: [ZoomRange]

    init(version: Int = 1, source: String = "auto-clicks", ranges: [ZoomRange] = []) {
        self.version = version
        self.source = source
        self.ranges = ranges
    }
}

nonisolated enum ZoomRangeStore {
    static func zoomURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_zoom.json")
    }

    static func save(_ file: ZoomRangeFile, for outputURL: URL) {
        guard !file.ranges.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: zoomURL(for: outputURL), options: .atomic)
    }

    static func load(from url: URL) -> ZoomRangeFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ZoomRangeFile.self, from: data)
    }
}

/// 归一化裁切矩形（左上原点，0...1）
typealias NormalizedCrop = (x: Double, y: Double, w: Double, h: Double)

/// 时间线求值：给定 t 与区间集合，算出当前的归一化裁切矩形。
/// 坐标约定：归一化到源画面（左上原点）；裁切保持源宽高比
/// （归一化空间里 w == h 即可，见 ZoomTimeline.activeCrop 注释）。
nonisolated enum ZoomTimeline {
    static func easeOutCubic(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    static func easeInCubic(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * c
    }

    /// t 时刻的瞬时缩放倍率（1 = 不缩放）
    static func zoomFactor(at t: Double, range: ZoomRange) -> Double {
        guard t >= range.startSeconds, t <= range.endSeconds else { return 1 }
        let e = max(range.easingSeconds, 0)
        guard e > 0, range.endSeconds - range.startSeconds > e * 2 else {
            return range.zoomScale
        }
        if t < range.startSeconds + e {
            let p = easeOutCubic((t - range.startSeconds) / e)
            return 1 + (range.zoomScale - 1) * p
        }
        if t > range.endSeconds - e {
            let p = easeInCubic((range.endSeconds - t) / e)
            return 1 + (range.zoomScale - 1) * p
        }
        return range.zoomScale
    }

    /// t 时刻的归一化裁切矩形。归一化空间里宽 == 高即可保持源宽高比：
    /// 像素宽 = w*srcW、像素高 = h*srcH，w==h 时两者比例即源比例。
    static func activeCrop(at t: Double, ranges: [ZoomRange]) -> NormalizedCrop? {
        // 多个区间重叠时取缩放更强的那个
        let active = ranges
            .filter { t >= $0.startSeconds && t <= $0.endSeconds }
            .max { zoomFactor(at: t, range: $0) < zoomFactor(at: t, range: $1) }
        guard let range = active else { return nil }

        let factor = zoomFactor(at: t, range: range)
        guard factor > 1.0001 else { return nil }
        let size = min(1.0, 1.0 / factor)
        // 把中心钳制在 [size/2, 1-size/2]，保证裁切矩形完整落在画面内
        let cx = min(max(range.centerX, size / 2), 1 - size / 2)
        let cy = min(max(range.centerY, size / 2), 1 - size / 2)
        return (cx - size / 2, cy - size / 2, size, size)
    }

    /// 光标点透过裁切矩形的映射（裁切外的点返回 nil = 不画）。
    static func mapPointThroughCrop(x: Double, y: Double, crop: NormalizedCrop) -> (x: Double, y: Double)? {
        let rx = (x - crop.x) / crop.w
        let ry = (y - crop.y) / crop.h
        guard rx >= -0.05, rx <= 1.05, ry >= -0.05, ry <= 1.05 else { return nil }
        return (min(max(rx, 0), 1), min(max(ry, 0), 1))
    }
}

/// 自动缩放启发式（学习 Screen Studio：注意力 = 点击 + 停留）。
/// 纯函数，输入光标事件轨，输出缩放区间：
/// - 点击：点前 lead 秒开始放大（先到位、观感跟手），停点 hold 秒后退出
/// - 停留：光标在某处静置超过阈值（用户在读/在讲这块），温和放大；
///   采样器静止时不产样本，所以样本流里的"时间沟"就是停留时长，
///   时间轴是成片时间，暂停段天然不产生假停留
/// - 前导/尾部静默（开录没动鼠标、讲完停住）也算停留
/// - 点击与停留区间重叠时合并：跨度和中心取加权，倍率取点击（更强）
/// - 过短的区间丢弃（不值得缩）
nonisolated enum ZoomHeuristic {
    struct Configuration: Sendable {
        var leadSeconds: Double = 0.45
        var holdSeconds: Double = 1.7
        var mergeGapSeconds: Double = 1.4
        var mergeDistance: Double = 0.30
        var minimumRangeSeconds: Double = 1.4
        var zoomScale: Double = 1.9
        var easingSeconds: Double = 0.38
        // 停留（悬停阅读）参数
        var dwellRadius: Double = 0.03
        var dwellMinimumSeconds: Double = 1.8
        var dwellZoomScale: Double = 1.5
        var dwellHoldSeconds: Double = 0.8
        /// 停留开始后多久开始放大（不能一停就缩，那是指针在喘气不是在阅读）
        var dwellEngageDelayFraction: Double = 0.3
        /// 停在屏幕边缘（闲置搁放指针）不算阅读，不缩放
        var dwellEdgeMargin: Double = 0.04
    }

    static func ranges(
        from events: [CursorEventSample],
        totalDuration: Double? = nil,
        configuration: Configuration = Configuration()
    ) -> [ZoomRange] {
        let sorted = events.sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }
        let endTime = totalDuration ?? sorted[sorted.count - 1].t

        let clickRanges = clickRanges(from: sorted, configuration: configuration)
        let dwellRanges = dwellRanges(from: sorted, endTime: endTime, configuration: configuration)
        let merged = mergeRanges(clickRanges: clickRanges, dwellRanges: dwellRanges)

        return merged
            .filter { $0.endSeconds - $0.startSeconds >= configuration.minimumRangeSeconds }
            .map { range -> ZoomRange in
                var clamped = range
                clamped.startSeconds = max(0, range.startSeconds)
                // 只有明确知道片长才钳终点；不知道时不砍自然收尾
                if let totalDuration {
                    clamped.endSeconds = min(range.endSeconds, totalDuration)
                }
                return clamped
            }
    }

    /// 点击聚类 → 区间
    private static func clickRanges(
        from events: [CursorEventSample],
        configuration: Configuration
    ) -> [ZoomRange] {
        let clicks = events.filter { $0.c == 1 }
        guard !clicks.isEmpty else { return [] }

        struct Cluster {
            var times: [Double] = []
            var sumX: Double = 0
            var sumY: Double = 0
        }

        var clusters: [Cluster] = []
        for click in clicks {
            if var last = clusters.last,
               click.t - (last.times.max() ?? click.t) <= configuration.mergeGapSeconds,
               abs(click.x - last.sumX / Double(last.times.count)) <= configuration.mergeDistance
                || abs(click.y - last.sumY / Double(last.times.count)) <= configuration.mergeDistance {
                last.times.append(click.t)
                last.sumX += click.x
                last.sumY += click.y
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(times: [click.t], sumX: click.x, sumY: click.y))
            }
        }

        return clusters.map { cluster in
            let count = Double(cluster.times.count)
            return ZoomRange(
                startSeconds: (cluster.times.min() ?? 0) - configuration.leadSeconds,
                endSeconds: (cluster.times.max() ?? 0) + configuration.holdSeconds,
                centerX: cluster.sumX / count,
                centerY: cluster.sumY / count,
                zoomScale: configuration.zoomScale,
                easingSeconds: configuration.easingSeconds
            )
        }
    }

    /// 停留（悬停）→ 区间。时间沟两端位移在半径内才算真的停住了。
    private static func dwellRanges(
        from samples: [CursorEventSample],
        endTime: Double,
        configuration: Configuration
    ) -> [ZoomRange] {
        var candidates: [(start: Double, end: Double, x: Double, y: Double)] = []

        // 前导静默：开录后到首个样本之间光标没动过
        if let first = samples.first, first.t >= configuration.dwellMinimumSeconds {
            candidates.append((0, first.t, first.x, first.y))
        }

        // 相邻样本间的时间沟 = 停留
        for (a, b) in zip(samples, samples.dropFirst()) {
            let gap = b.t - a.t
            guard gap >= configuration.dwellMinimumSeconds else { continue }
            guard abs(a.x - b.x) <= configuration.dwellRadius,
                  abs(a.y - b.y) <= configuration.dwellRadius else { continue }
            candidates.append((a.t, b.t, (a.x + b.x) / 2, (a.y + b.y) / 2))
        }

        // 尾部静默：最后一个样本到录制结束之间光标没动（需要 totalDuration 才知道；
        // 没传时 endTime 即最后样本时刻，间距为 0，自然不触发）
        if let last = samples.last, endTime > last.t {
            let gap = endTime - last.t
            if gap >= configuration.dwellMinimumSeconds {
                candidates.append((last.t, endTime, last.x, last.y))
            }
        }

        let engageDelay = min(0.6, configuration.dwellMinimumSeconds * configuration.dwellEngageDelayFraction)
        let margin = configuration.dwellEdgeMargin
        return candidates
            .filter { candidate in
                candidate.x >= margin && candidate.x <= 1 - margin
                    && candidate.y >= margin && candidate.y <= 1 - margin
            }
            .map { candidate in
                ZoomRange(
                    startSeconds: candidate.start + engageDelay,
                    endSeconds: candidate.end + configuration.dwellHoldSeconds,
                    centerX: candidate.x,
                    centerY: candidate.y,
                    zoomScale: configuration.dwellZoomScale,
                    easingSeconds: configuration.easingSeconds
                )
            }
    }

    /// 点击与停留区间合并：重叠（或贴着 ≤0.3s）的并成一个，
    /// 时间取并集，倍率取大者，中心按"点击权重 3、停留权重 1"加权。
    private static func mergeRanges(
        clickRanges: [ZoomRange],
        dwellRanges: [ZoomRange],
        gapTolerance: Double = 0.3
    ) -> [ZoomRange] {
        struct Tagged {
            let range: ZoomRange
            let clickWeight: Double
        }

        let all: [Tagged] = clickRanges.map { Tagged(range: $0, clickWeight: 3) }
            + dwellRanges.map { Tagged(range: $0, clickWeight: 1) }
        guard !all.isEmpty else { return [] }

        let sorted = all.sorted { $0.range.startSeconds < $1.range.startSeconds }
        var merged: [ZoomRange] = []
        var current = sorted[0]
        for next in sorted.dropFirst() {
            if next.range.startSeconds <= current.range.endSeconds + gapTolerance {
                let weight = current.clickWeight + next.clickWeight
                current = Tagged(
                    range: ZoomRange(
                        startSeconds: min(current.range.startSeconds, next.range.startSeconds),
                        endSeconds: max(current.range.endSeconds, next.range.endSeconds),
                        centerX: (current.range.centerX * current.clickWeight + next.range.centerX * next.clickWeight) / weight,
                        centerY: (current.range.centerY * current.clickWeight + next.range.centerY * next.clickWeight) / weight,
                        zoomScale: max(current.range.zoomScale, next.range.zoomScale),
                        easingSeconds: max(current.range.easingSeconds, next.range.easingSeconds)
                    ),
                    clickWeight: weight
                )
            } else {
                merged.append(current.range)
                current = next
            }
        }
        merged.append(current.range)
        return merged
    }
}
