import Foundation
import SwiftUI

/// 轻量的内存足迹打点。排查内存暴涨时，用它把「哪个阶段在涨」变成数字。
enum MemoryFootprint {
    static func megabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    static func log(_ tag: String) {
        print("📊 \(tag): \(String(format: "%.1f", megabytes())) MB")
    }
}

// MARK: - 提词区外观（虚线框 + 虚化）

struct PromptFrameModifier: ViewModifier {
    var showFrame: Bool
    var blurAmount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blurAmount > 0 ? blurAmount : 0)
            .overlay {
                if showFrame {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// 提词文字与虚线框作为一个整体：虚化一起生效，虚线框不拦截点击。
    func promptFrame(showFrame: Bool, blurAmount: Double) -> some View {
        modifier(PromptFrameModifier(showFrame: showFrame, blurAmount: blurAmount))
    }
}

