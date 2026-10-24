import AppKit
import Foundation

/// 光标事件轨（学习 Screen Studio 的光标数据设计）。
/// 采样归一化到录制矩形（左上原点，0...1），与输出分辨率解耦；
/// 导出端乘以视频尺寸即可。时间轴为成片时间（已扣除暂停段）。
nonisolated struct CursorEventSample: Codable, Sendable, Equatable {
    /// 成片时间轴上的秒
    var t: Double
    /// 归一化坐标（相对录制矩形，左上原点）
    var x: Double
    var y: Double
    /// 1 = 该时刻发生点击
    var c: Int

    init(t: Double, x: Double, y: Double, c: Int = 0) {
        self.t = t
        self.x = x
        self.y = y
        self.c = c
    }
}

nonisolated struct CursorEventTrack: Codable, Sendable, Equatable {
    var version: Int
    var recordingRect: CursorEventRect?
    var events: [CursorEventSample]

    init(version: Int = 1, recordingRect: CursorEventRect? = nil, events: [CursorEventSample] = []) {
        self.version = version
        self.recordingRect = recordingRect
        self.events = events
    }
}

nonisolated struct CursorEventRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated enum CursorGeometry {
    /// 全局屏幕坐标（AppKit 左下原点）→ 录制矩形内归一化坐标（左上原点）。
    /// 落在矩形外超过 5% 判为不在录制画面内，返回 nil。
    static func normalizedPoint(globalX: Double, globalY: Double, in rect: CGRect) -> (x: Double, y: Double)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let relX = (globalX - rect.minX) / rect.width
        let relY = 1 - (globalY - rect.minY) / rect.height
        let tolerance = 0.05
        guard relX >= -tolerance, relX <= 1 + tolerance,
              relY >= -tolerance, relY <= 1 + tolerance else { return nil }
        return (min(max(relX, 0), 1), min(max(relY, 0), 1))
    }

    /// 移动事件的采样决策：至少间隔 minInterval，且确实动了才记。
    /// 静止光标不产生新样本，暂停期间时间不前进，自然停止采样。
    static func shouldRecordMove(
        lastSample: CursorEventSample?,
        t: Double,
        x: Double,
        y: Double,
        minInterval: Double = 0.03,
        minDistance: Double = 0.002
    ) -> Bool {
        guard let lastSample else { return true }
        guard t - lastSample.t >= minInterval else { return false }
        let dx = abs(x - lastSample.x)
        let dy = abs(y - lastSample.y)
        return dx >= minDistance || dy >= minDistance
    }
}

nonisolated enum CursorEventStore {
    static func cursorURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_cursor.json")
    }

    static func save(_ track: CursorEventTrack, for outputURL: URL) {
        guard !track.events.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(track) else { return }
        try? data.write(to: cursorURL(for: outputURL), options: .atomic)
    }

    static func load(from url: URL) -> CursorEventTrack? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CursorEventTrack.self, from: data)
    }
}

/// 录制期间的光标监听。NSEvent 监听不需要辅助功能权限。
/// elapsed 返回负数表示当前不该采样（未在录制 / 暂停中）。
@MainActor
final class CursorEventTracker {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var track = CursorEventTrack()
    private var lastMoveSample: CursorEventSample?
    private var elapsedProvider: () -> Double = { -1 }

    var isActive: Bool {
        globalMonitor != nil
    }

    func start(recordingRect: CGRect, elapsedProvider: @escaping () -> Double) {
        stop()
        track = CursorEventTrack(recordingRect: CursorEventRect(recordingRect))
        lastMoveSample = nil
        self.elapsedProvider = elapsedProvider

        // leftMouseDragged 让"框选/选中文字"的拖拽路径也产生移动样本，
        // 停留检测才能在选中后停在的位置放大
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    /// 停录后落盘。返回事件数（0 表示没有可写的内容，不产生文件）。
    @discardableResult
    func stopSavingOutput(_ outputURL: URL) -> Int {
        stop()
        defer {
            track = CursorEventTrack()
            lastMoveSample = nil
        }
        let count = track.events.count
        CursorEventStore.save(track, for: outputURL)
        if count > 0 {
            print("🖱️ 光标事件已保存: \(count) 条 → \(outputURL.deletingPathExtension().lastPathComponent)_cursor.json")
        }
        return count
    }

    private func handle(_ event: NSEvent) {
        guard isActive else { return }
        let elapsed = elapsedProvider()
        guard elapsed >= 0, let rect = track.recordingRect?.cgRect else { return }

        let location = NSEvent.mouseLocation
        guard let normalized = CursorGeometry.normalizedPoint(
            globalX: location.x,
            globalY: location.y,
            in: rect
        ) else { return }

        let isClick: Bool
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            isClick = true
        default:
            isClick = false
        }

        let sample = CursorEventSample(
            t: (elapsed * 1000).rounded() / 1000,
            x: (normalized.x * 10_000).rounded() / 10_000,
            y: (normalized.y * 10_000).rounded() / 10_000,
            c: isClick ? 1 : 0
        )

        if isClick {
            track.events.append(sample)
            lastMoveSample = sample
            return
        }

        guard CursorGeometry.shouldRecordMove(
            lastSample: lastMoveSample,
            t: sample.t,
            x: sample.x,
            y: sample.y
        ) else { return }
        track.events.append(sample)
        lastMoveSample = sample
    }
}
