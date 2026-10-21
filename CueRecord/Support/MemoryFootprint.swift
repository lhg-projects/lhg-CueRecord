import Foundation

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
