import Foundation

/// Agent 剪辑接口（学习 HuaStudio「Agent 剪辑」的设计：不做内置 AI，
/// 做 AI 能用的接口）。分两层：
///
/// 1. `AgentEditPromptBuilder`：把一条录制的全部侧车汇总成一段提示词，
///    用户粘给任意 AI；提示词自带完整操作规范，AI 不需要别的文档。
/// 2. `AgentEditApplier`：把 AI 产出的 edits.json 安全地映射回
///    RecordingEditDecision + 缩放区间，导出仍走应用自己的渲染管线——
///    AI 只能改参数，碰不到渲染，出错最多"剪得难看"，不会产出坏文件。
nonisolated struct AgentEditContext: Sendable, Equatable {
    var outputFileName: String
    var durationSeconds: Double
    var resolution: String
    var hasCameraTrack: Bool
    var markers: [RecordingMarker]
    var transcript: [TranscriptSegment]
    var idleSuggestions: IdleSpanFile?
    var zoomRanges: [ZoomRange]
}

nonisolated enum AgentEditPromptBuilder {
    static func prompt(for context: AgentEditContext) -> String {
        var lines: [String] = []
        lines.append("# 录课台 · Agent 剪辑任务")
        lines.append("")
        lines.append("你是一名视频剪辑师。下面是一条屏幕录制的信息和一份可执行的操作规范。")
        lines.append("请依据素材信息与剪辑常识，输出**一个 JSON 对象**（不要多余解释），即 edits.json。")
        lines.append("")
        lines.append("## 素材信息")
        lines.append("- 文件：\(context.outputFileName)")
        lines.append(String(format: "- 时长：%.1f 秒（成片时间轴，已扣除录制暂停段）", context.durationSeconds))
        lines.append("- 画面：\(context.resolution)")
        lines.append("- 摄像头轨：\(context.hasCameraTrack ? "有" : "无")")
        lines.append("")

        lines.append("### 讲话内容（时间 → 文本）")
        if context.transcript.isEmpty {
            lines.append("-（无转写：录制时提词器识别未开启）")
        } else {
            for segment in context.transcript {
                lines.append(String(format: "- [%.1f–%.1fs] %@", segment.start, segment.end, segment.text))
            }
        }
        lines.append("")

        lines.append("### 手动标记（录制时讲师特意打的点）")
        if context.markers.isEmpty {
            lines.append("-（无）")
        } else {
            for marker in context.markers {
                lines.append(String(format: "- [%.1fs] 标记 %d", marker.elapsedSeconds, marker.index + 1))
            }
        }
        lines.append("")

        if let idle = context.idleSuggestions {
            lines.append("### 应用内置的闲段检测（没说话∧没操作的段，可信度高）")
            if let trim = idle.suggestedTrimStart {
                lines.append(String(format: "- 建议裁掉开头 %.1fs（录制启动的鼠标找位）", trim))
            }
            for suggestion in idle.suggestions {
                let action = suggestion.action == "cut" ? "建议剪掉" : "建议 \(Int(suggestion.speed))× 加速"
                lines.append(String(format: "- [%.1f–%.1fs] %@", suggestion.span.start, suggestion.span.end, action))
            }
            if idle.suggestions.isEmpty {
                lines.append("-（未检出闲段）")
            }
            lines.append("")
        }

        if !context.zoomRanges.isEmpty {
            lines.append("### 已有的自动缩放区间（点击/停留触发，可覆盖或补充）")
            for range in context.zoomRanges {
                lines.append(String(
                    format: "- [%.1f–%.1fs] 中心(%.2f, %.2f) 倍率 %.1f",
                    range.startSeconds, range.endSeconds, range.centerX, range.centerY, range.zoomScale
                ))
            }
            lines.append("")
        }

        lines.append("## edits.json 规范（严格遵守）")
        lines.append("```json")
        lines.append("{")
        lines.append("  \"cuts\": [")
        lines.append("    { \"startTime\": 0, \"endTime\": 1.5 }")
        lines.append("  ],")
        lines.append("  \"zoom\": [")
        lines.append("    { \"startSeconds\": 2.0, \"endSeconds\": 5.0, \"centerX\": 0.3, \"centerY\": 0.3,")
        lines.append("      \"zoomScale\": 1.6, \"easingSeconds\": 0.38 }")
        lines.append("  ],")
        lines.append("  \"zoomMode\": \"replace\",")
        lines.append("  \"export\": { \"resolution\": \"p1080\", \"cropTo16x9\": true }")
        lines.append("}")
        lines.append("```")
        lines.append("")
        lines.append("规则：")
        lines.append("1. `cuts` 必须按时间升序、首尾相接覆盖 0 到片尾，不留缝隙、不重叠；开头闲段直接从 `startTime > 0` 开始裁掉。")
        lines.append("2. `zoom` 段之间不重叠；单段 1.5–4s；倍率 1.4–2.2；`centerX/centerY` 是 0–1 归一化坐标（左上原点），聚焦点向上偏一点让出按钮周围的内容。")
        lines.append("3. `zoomMode`：`replace` 覆盖自动区间，`merge` 与自动区间合并；不需要运镜就给空数组 + `replace`。")
        lines.append("4. 讲师标记处的内容必须保留在 cuts 里，不允许落在被裁掉的段里。")
        lines.append("5. 时间一律用成片时间轴（与上面素材信息一致）。不支持变速——冗长段只能剪掉，不能加速。")
        lines.append("6. `export.resolution` 可选 `p720` / `p1080` / `p4K`；`cropTo16x9` 是否裁成 16:9。")
        lines.append("")
        lines.append("现在输出 edits.json。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - edits.json 模型与应用

nonisolated struct AgentEditSpecCut: Codable, Sendable, Equatable {
    var startTime: Double
    var endTime: Double
}

nonisolated struct AgentEditSpecExport: Codable, Sendable, Equatable {
    var resolution: String?
    var cropTo16x9: Bool?
}

nonisolated struct AgentEditSpec: Codable, Sendable, Equatable {
    var cuts: [AgentEditSpecCut]
    var zoom: [ZoomRange]?
    /// replace = 覆盖自动区间（默认）；merge = 合并
    var zoomMode: String?
    var export: AgentEditSpecExport?
}

nonisolated struct AgentEditApplication: Sendable, Equatable {
    var editDecision: RecordingEditDecision
    var exportSettings: RecordingExportSettings
    var zoomRanges: [ZoomRange]
}

nonisolated enum AgentEditApplier {
    enum ApplyError: Error, Equatable, Sendable {
        case emptyCuts
        case invalidCutRange(index: Int)
    }

    static func apply(
        _ spec: AgentEditSpec,
        existingZoomRanges: [ZoomRange] = []
    ) throws -> AgentEditApplication {
        guard !spec.cuts.isEmpty else { throw ApplyError.emptyCuts }

        let cuts = try spec.cuts.enumerated().map { index, cut -> RecordingEditCut in
            guard cut.endTime > cut.startTime else {
                throw ApplyError.invalidCutRange(index: index)
            }
            // 当前只支持纯屏幕布局；摄像头画中画跟随录制时的设置，不靠 AI 指定
            return RecordingEditCut(
                startTime: cut.startTime,
                endTime: cut.endTime,
                layoutMode: .screenFullScreen,
                cameraFrame: .defaultCameraFrame,
                cameraShape: .circle
            )
        }

        // zoomMode：replace = 覆盖自动区间；merge = 合并。
        // spec.zoom 为 nil 表示"AI 没提运镜"，保留自动区间；空数组 = 明确不要。
        let zoomRanges: [ZoomRange]
        if spec.zoomMode == "merge", let specZoom = spec.zoom {
            zoomRanges = (existingZoomRanges + specZoom).sorted { $0.startSeconds < $1.startSeconds }
        } else if let specZoom = spec.zoom {
            zoomRanges = specZoom
        } else {
            zoomRanges = existingZoomRanges
        }

        var exportSettings = RecordingExportSettings.default
        if let export = spec.export {
            if let resolution = export.resolution,
               let preset = RecordingExportResolutionPreset(rawValue: resolution) {
                exportSettings.resolutionPreset = preset
            }
            if let crop = export.cropTo16x9 {
                exportSettings.cropTo16x9 = crop
            }
        }

        return AgentEditApplication(
            editDecision: RecordingEditDecision(cuts: cuts),
            exportSettings: exportSettings,
            zoomRanges: zoomRanges
        )
    }
}
