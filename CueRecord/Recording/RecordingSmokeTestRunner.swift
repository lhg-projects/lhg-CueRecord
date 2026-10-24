import AVFoundation
import Foundation
import AppKit

/// 内置自测入口（学习 HuaStudio 的 --smoke-* 设计）。
///
/// 用 `open LLSStudio.app --args --smoke-record` 启动后自动执行：
/// 录 3s → 打标记 → 暂停 3s → 恢复 3s → 停止 → 导出 → 校验。
/// 不依赖任何外部 UI 驱动，正好闭环「暂停是否真的剪掉那段」这个
/// 悬了很久的验证（HANDOVER 第 11/13 节）。
///
/// 结果写 /tmp/llsstudio-smoke-report.json，全部通过后应用自动退出，
/// 退出码由报告的 allOk 决定（脚本可据此判绿）。
@MainActor
enum RecordingSmokeTestRunner {
    static let argument = "--smoke-record"
    static let reportPath = "/tmp/llsstudio-smoke-report.json"

    private static var didRun = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static func runIfNeeded() async {
        guard isRequested, !didRun else { return }
        didRun = true
        await run()
    }

    private static func run() async {
        var report: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "scenario": "record3s-pause3s-resume3s-stop-export"
        ]
        var allOk = true

        let controller = RecordingController.shared
        // 自测要确定性：全屏模式、摄像头关闭（避免无人值守时录到人脸）。
        // 用户原设置事后恢复。
        let previousMode = controller.recordingState.captureMode
        let previousCamera = controller.recordingState.cameraOverlayEnabled
        controller.recordingState.captureMode = .fullScreen
        controller.recordingState.cameraOverlayEnabled = false
        defer {
            controller.recordingState.captureMode = previousMode
            controller.recordingState.cameraOverlayEnabled = previousCamera
        }

        print("🧪 [smoke] 开始：录 3s → 暂停 3s → 恢复 3s → 停止 → 导出")

        // 1. 开录
        let started = await withCheckedContinuation { continuation in
            controller.startConfiguredRecording { started in
                continuation.resume(returning: started)
            }
        }
        guard started else {
            fail(&report, &allOk, "start", "开录失败: \(controller.lastError ?? "未知")")
            finish(report, allOk)
            return
        }
        report["started"] = true
        let outputURL = controller.recordingState.outputURL

        // 2. 录 3s，中途打一个标记
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let marker = controller.addMarkerAtCurrentTime()
        report["markerAdded"] = marker != nil
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 3. 暂停 3s（这段不应进入成片）
        let wallClockBeforePause = Date()
        controller.togglePauseRecording()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        controller.togglePauseRecording()
        let pauseWallSeconds = Date().timeIntervalSince(wallClockBeforePause)

        // 4. 恢复再录 3s，然后停止
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let stopped = await withCheckedContinuation { continuation in
            controller.stopRecording {
                continuation.resume(returning: true)
            }
        }
        report["stopped"] = stopped
        guard stopped, let captured = controller.pendingCapturedRecording else {
            fail(&report, &allOk, "stop", "停录后没有可用的录制产物")
            finish(report, allOk)
            return
        }

        // 5. 校验原始屏幕轨：约 6s（3+3），暂停段必须不在里面
        let rawDuration = assetDuration(of: captured.outputURL)
        report["rawOutputURL"] = captured.outputURL.path
        report["rawDurationSeconds"] = rawDuration
        if let rawDuration {
            // 墙钟约 9s+（3+3+3 加操作余量）；成片应显著小于墙钟且接近 6s
            if rawDuration > 7.5 || rawDuration < 3.5 {
                fail(&report, &allOk, "pauseCut", String(format: "屏幕轨 %.2fs，暂停段疑似未被剪掉（期望约 6s）", rawDuration))
            } else {
                report["pauseCut"] = String(format: "ok（%.2fs，墙钟暂停段 %.2fs 未计入）", rawDuration, pauseWallSeconds)
            }
        } else {
            fail(&report, &allOk, "pauseCut", "屏幕轨不可读——录制产物损坏")
        }

        // 6. 侧车齐全性
        let cursorExists = FileManager.default.fileExists(atPath: CursorEventStore.cursorURL(for: captured.outputURL).path)
        report["cursorTrack"] = cursorExists
        if !cursorExists {
            fail(&report, &allOk, "cursorTrack", "缺少 _cursor.json")
        }
        let markers = RecordingMarkerStore.load(from: RecordingMarkerStore.markersURL(for: captured.outputURL))
        report["markerCount"] = markers.count
        if markers.count != 1 {
            fail(&report, &allOk, "markers", "应有 1 个标记，实际 \(markers.count)")
        }

        // 7. 导出（.all = 原始合成模式）
        controller.renderPendingCapturedRecording(mode: .all, exportSettings: .default)
        let exportDeadline = Date().addingTimeInterval(180)
        var exportedURL: URL?
        while Date() < exportDeadline {
            if !controller.isExporting, let url = controller.lastOutputURL {
                exportedURL = url
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let exportedURL {
            let exportDuration = assetDuration(of: exportedURL)
            report["exportedURL"] = exportedURL.path
            report["exportDurationSeconds"] = exportDuration
            if let exportDuration, exportDuration > 0.5 {
                report["export"] = String(format: "ok（%.2fs）", exportDuration)
            } else {
                fail(&report, &allOk, "export", "导出文件不可读或时长异常")
            }
        } else {
            fail(&report, &allOk, "export", "导出超时（180s）")
        }

        finish(report, allOk)
    }

    private static func assetDuration(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        guard asset.tracks(withMediaType: .video).count > 0,
              asset.duration.isValid, asset.duration.seconds > 0 else { return nil }
        return asset.duration.seconds
    }

    private static func fail(
        _ report: inout [String: Any],
        _ allOk: inout Bool,
        _ key: String,
        _ message: String
    ) {
        report[key] = "FAIL: \(message)"
        allOk = false
        print("🧪 [smoke] FAIL \(key): \(message)")
    }

    private static func finish(_ report: [String: Any], _ allOk: Bool) {
        var final = report
        final["allOk"] = allOk
        final["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        print("🧪 [smoke] \(allOk ? "PASS 全部通过" : "FAIL 存在失败项")，报告: \(reportPath)")
        Task { @MainActor in
            // 给 stdout 一点落盘时间再退出
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }
}
