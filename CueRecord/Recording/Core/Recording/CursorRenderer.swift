import CoreGraphics
import CoreImage
import Foundation

/// 事件轨采样器：给定成片时间，线性插值出光标位置。
/// 渲染循环按时间单调推进，内部维护游标索引，整体 O(n)。
nonisolated struct CursorEventSampler {
    private let samples: [CursorEventSample]
    private var index = 0

    init(samples: [CursorEventSample]) {
        self.samples = samples.sorted { $0.t < $1.t }
    }

    var isEmpty: Bool { samples.isEmpty }

    mutating func position(at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }

        while index + 1 < samples.count, samples[index + 1].t <= t { index += 1 }
        while index > 0, samples[index].t > t { index -= 1 }
        guard index + 1 < samples.count else { return (last.x, last.y) }

        let a = samples[index]
        let b = samples[index + 1]
        let span = b.t - a.t
        guard span > 0 else { return (a.x, a.y) }
        let f = (t - a.t) / span
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    /// 最近一次仍在波纹窗口内的点击
    func activeRipple(at t: Double, duration: Double = CursorRenderer.rippleDuration) -> CursorEventSample? {
        samples.last { $0.c == 1 && t >= $0.t && t < $0.t + duration }
    }
}

/// 导出端自绘光标（学习 Screen Studio：源画面不烧系统光标，导出时用
/// 事件轨画一个更大、更平滑的光标 + 点击波纹，教学视频更醒目）。
/// 坐标约定：事件轨归一化到录制矩形（左上原点）；CIImage 是左下原点，
/// 应用前统一换算。屏幕画面在 outputExtent 内 aspect-fit，光标只画在
/// fit 后的内容矩形内，否则裁切/留边后会整体偏移。
nonisolated enum CursorRenderer {
    /// 光标高度占内容画面高度的比例。0.052 约为原生观感的 1.4 倍。
    static let relativeCursorHeight = 0.052
    /// 点击波纹时长（秒）
    static let rippleDuration = 0.45

    /// aspect-fit 后的内容矩形（与 ScreenRecorder.aspectFit 同公式）。
    static func contentRect(sourceExtent: CGRect, in target: CGRect) -> CGRect {
        guard sourceExtent.width > 0, sourceExtent.height > 0,
              target.width > 0, target.height > 0 else { return target }
        let scale = min(target.width / sourceExtent.width, target.height / sourceExtent.height)
        let width = sourceExtent.width * scale
        let height = sourceExtent.height * scale
        return CGRect(
            x: target.midX - width / 2,
            y: target.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// 归一化（左上原点）→ 内容矩形内的 CIImage 坐标（左下原点）
    static func contentPoint(x: Double, y: Double, in contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + x * contentRect.width,
            y: contentRect.minY + (1 - y) * contentRect.height
        )
    }

    /// 手绘 macOS 风格箭头（白底黑边）。用 CoreGraphics 而非 NSCursor：
    /// 渲染在后台线程，不碰 AppKit。
    static func arrowCGImage(pixelSize: Int = 128) -> CGImage? {
        let size = CGFloat(pixelSize)
        let margin = size * 0.05
        let scale = size - margin * 2

        // 箭头多边形，屏幕坐标系（y 向下），顶点（热点）在 (0,0)
        let unit: [(CGFloat, CGFloat)] = [
            (0.00, 0.00),
            (0.00, 0.86),
            (0.22, 0.67),
            (0.36, 0.96),
            (0.50, 0.89),
            (0.37, 0.61),
            (0.65, 0.61)
        ]
        let points = unit.map { screenPoint in
            CGPoint(
                x: margin + screenPoint.0 * scale,
                y: margin + (1 - screenPoint.1) * scale
            )
        }

        guard let cg = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.setLineWidth(size * 0.055)
        cg.setStrokeColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.addLines(between: points)
        cg.closePath()
        cg.drawPath(using: .fillStroke)

        // 描边内侧再补一圈细的深色描边，缩放大后边缘不发虚
        cg.setLineWidth(size * 0.02)
        cg.addLines(between: points)
        cg.closePath()
        cg.strokePath()

        return cg.makeImage()
    }

    /// 点击波纹圆环（白色描边 + 柔和发光）
    static func rippleCGImage(pixelSize: Int = 256, lineWidthRatio: CGFloat = 0.06) -> CGImage? {
        let size = CGFloat(pixelSize)
        guard let cg = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let radius = size / 2 - size * lineWidthRatio
        cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.setShadow(
            offset: .zero,
            blur: size * 0.06,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        )
        cg.setLineWidth(size * lineWidthRatio)
        cg.strokeEllipse(in: CGRect(
            x: size / 2 - radius,
            y: size / 2 - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return cg.makeImage()
    }

    /// 把光标（和进行中的点击波纹）合成到帧上。光标画在相机画中画之上。
    /// crop 非空时表示当前处于缩放区间内，光标/波纹坐标先透过裁切矩形映射，
    /// 落在放大区外的箭头不画。
    static func applyCursor(
        to image: CIImage,
        sampler: inout CursorEventSampler,
        at t: Double,
        contentRect: CGRect,
        cursorCI: CIImage,
        rippleCI: CIImage,
        crop: NormalizedCrop? = nil
    ) -> CIImage {
        guard let point = sampler.position(at: t) else { return image }
        let mappedPoint: (x: Double, y: Double)? = crop.map {
            ZoomTimeline.mapPointThroughCrop(x: point.x, y: point.y, crop: $0)
        } ?? point

        var result = image
        if let click = sampler.activeRipple(at: t) {
            let mappedClick: (x: Double, y: Double)? = crop.map {
                ZoomTimeline.mapPointThroughCrop(x: click.x, y: click.y, crop: $0)
            } ?? (click.x, click.y)
            if let mappedClick {
                let progress = (t - click.t) / rippleDuration
                let clickPoint = contentPoint(x: mappedClick.x, y: mappedClick.y, in: contentRect)
                let ringSize = contentRect.height * (0.056 + progress * 0.11) * 1.12
                let scaledRipple = rippleCI
                    .transformed(by: CGAffineTransform(
                        scaleX: ringSize / rippleCI.extent.width,
                        y: ringSize / rippleCI.extent.height
                    ))
                    .transformed(by: CGAffineTransform(
                        translationX: clickPoint.x - ringSize / 2,
                        y: clickPoint.y - ringSize / 2
                    ))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.95 * (1 - progress)))
                    ])
                result = scaledRipple.composited(over: result)
            }
        }

        guard let mappedPoint else { return result }
        // 箭头热点在左上角
        let cursorPoint = contentPoint(x: mappedPoint.x, y: mappedPoint.y, in: contentRect)
        let cursorHeight = contentRect.height * relativeCursorHeight
        let cursorWidth = cursorHeight * (cursorCI.extent.width / max(cursorCI.extent.height, 1))
        let scaledCursor = cursorCI
            .transformed(by: CGAffineTransform(
                scaleX: cursorWidth / cursorCI.extent.width,
                y: cursorHeight / cursorCI.extent.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: cursorPoint.x,
                y: cursorPoint.y - cursorHeight
            ))
        return scaledCursor.composited(over: result)
    }
}
