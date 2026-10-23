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

/// 自动缩放启发式（学习 Screen Studio：点击 = 注意力焦点）。
/// 纯函数，输入光标事件轨，输出缩放区间：
/// - 点击前 lead 秒开始放大（点之前就到位，观感跟手）
/// - 停止点击 hold 秒后开始退出
/// - 间隔短、距离近的连续点击并成一个区间（质心）
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
    }

    static func ranges(from events: [CursorEventSample], configuration: Configuration = Configuration()) -> [ZoomRange] {
        let clicks = events.filter { $0.c == 1 }.sorted { $0.t < $1.t }
        guard !clicks.isEmpty else { return [] }

        struct Cluster {
            var times: [Double]
            var sumX: Double
            var sumY: Double
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

        var result: [ZoomRange] = []
        for cluster in clusters {
            let count = Double(cluster.times.count)
            let start = (cluster.times.min() ?? 0) - configuration.leadSeconds
            let end = (cluster.times.max() ?? 0) + configuration.holdSeconds
            // 相邻区间重叠时前一个提前收尾，避免缩放来回抖
            if let previousEnd = result.last?.endSeconds, start < previousEnd {
                result[result.count - 1].endSeconds = max(start - 0.05, result[result.count - 1].startSeconds + configuration.easingSeconds * 2)
            }
            guard end - start >= configuration.minimumRangeSeconds else { continue }
            result.append(ZoomRange(
                startSeconds: max(0, start),
                endSeconds: end,
                centerX: cluster.sumX / count,
                centerY: cluster.sumY / count,
                zoomScale: configuration.zoomScale,
                easingSeconds: configuration.easingSeconds
            ))
        }
        return result
    }
}
