import Foundation

/// 开录前体检与导出闸门。两者都在拦同一类事故：
/// writer 中途失败 → 文件不可解码 → 用户直到导出才看到黑屏（见 HANDOVER 第 12 节）。
nonisolated enum RecordingPreflight {
    /// 低于该值拒绝开录。磁盘写满是 writer 失败的已知成因之一。
    /// 全屏录制约 8.6 GB/小时，5 GB 大致够 35 分钟，足以在开录前拦住危险。
    static let minimumFreeSpaceBytes: Int64 = 5 * 1024 * 1024 * 1024

    static func availableCapacity(on directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// 磁盘余量是否够开录。返回 nil 表示通过；读不出余量时也不拦录，避免误伤。
    static func freeSpaceIssue(
        availableBytes: Int64?,
        minimumBytes: Int64 = minimumFreeSpaceBytes
    ) -> String? {
        guard let availableBytes else { return nil }
        guard availableBytes >= minimumBytes else {
            let availableGB = Double(availableBytes) / 1_073_741_824
            let minimumGB = Double(minimumBytes) / 1_073_741_824
            return String(
                format: "磁盘剩余空间不足（当前 %.1f GB，至少需要 %.0f GB）。为避免录制中途损坏，请先清理磁盘再开录。",
                availableGB,
                minimumGB
            )
        }
        return nil
    }

    /// 导出闸门：屏幕轨 damaged 的 take 拒绝导出。
    /// 不拦的话导出会"成功"产出一个全黑成片，用户反而以为录废了重录。
    static func exportBlockReason(for validation: RecordingOutputValidation) -> String? {
        guard validation.health == .damaged else { return nil }
        let issues = validation.issues.isEmpty ? "屏幕轨不可解码" : validation.issues.joined(separator: "；")
        return "此条录制的屏幕轨已损坏（\(issues)），导出只会得到全黑画面。原文件仍保留在原处，未做改动。"
    }
}
