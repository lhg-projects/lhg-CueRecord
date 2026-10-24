import AppKit
import AVFoundation
import SwiftUI

/// Agent 剪辑窗口（学习 HuaStudio 的设计：提示词生成器 + edits.json 应用器，
/// 不内置 AI）。两步流：选录制文件 → 生成提示词粘给任意 AI；
/// AI 产出 edits.json 后选回来，应用即导出。缩放区间改写前自动备份。
struct AgentEditView: View {
    @ObservedObject private var controller = RecordingController.shared
    @ObservedObject private var interfaceLanguage = InterfaceLanguageSettings.shared
    @State private var selectedURL: URL?
    @State private var summary: String?
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Agent Edit"))
                .font(.title2.bold())

            Text(t("Agent Edit intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(t("Choose recording")) { chooseRecording() }
                if let selectedURL {
                    Text(selectedURL.lastPathComponent)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let summary {
                Text(summary)
                    .font(.callout.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Button(t("Generate prompt")) { generatePrompt() }
                    .disabled(selectedURL == nil)
                Button(t("Apply edits.json")) { applyEdits() }
                    .disabled(selectedURL == nil || controller.isExporting)
                if controller.isExporting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let statusText {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private func t(_ english: String) -> String {
        interfaceLanguage.text(english)
    }

    private func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = t("Choose the screen recording (.mov)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedURL = url
        statusText = nil

        let asset = AVURLAsset(url: url)
        let duration = asset.duration.isValid ? asset.duration.seconds : 0
        let transcript = TranscriptSRTSerializer.loadTranscript(for: url)
        let markers = RecordingMarkerStore.load(from: RecordingMarkerStore.markersURL(for: url))
        let idle = IdleSpanStore.load(from: IdleSpanStore.idleURL(for: url))
        let zoom = ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: url))?.ranges ?? []
        let cameraURL = URL(fileURLWithPath: url.deletingPathExtension().path + "_camera.mov")

        summary = String(
            format: "%.1fs · 转写 %d 段 · 标记 %d 个 · 闲段建议 %d 条 · 缩放 %d 段 · 摄像头%@",
            duration,
            transcript.count,
            markers.count,
            idle?.suggestions.count ?? 0,
            zoom.count,
            FileManager.default.fileExists(atPath: cameraURL.path) ? "有" : "无"
        )
    }

    private func generatePrompt() {
        guard let selectedURL else { return }
        let asset = AVURLAsset(url: selectedURL)
        let duration = asset.duration.isValid ? asset.duration.seconds : 0
        let size = asset.tracks(withMediaType: .video).first.flatMap {
            Self.normalizedVideoSizeLabel(for: $0)
        } ?? "未知"

        let cameraURL = URL(fileURLWithPath: selectedURL.deletingPathExtension().path + "_camera.mov")
        let context = AgentEditContext(
            outputFileName: selectedURL.lastPathComponent,
            durationSeconds: duration,
            resolution: size,
            hasCameraTrack: FileManager.default.fileExists(atPath: cameraURL.path),
            markers: RecordingMarkerStore.load(from: RecordingMarkerStore.markersURL(for: selectedURL)),
            transcript: TranscriptSRTSerializer.loadTranscript(for: selectedURL),
            idleSuggestions: IdleSpanStore.load(from: IdleSpanStore.idleURL(for: selectedURL)),
            zoomRanges: ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: selectedURL))?.ranges ?? []
        )

        let prompt = AgentEditPromptBuilder.prompt(for: context)
        let promptURL = URL(fileURLWithPath: selectedURL.deletingPathExtension().path + "_agent-prompt.md")
        try? prompt.data(using: .utf8)?.write(to: promptURL, options: .atomic)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        statusText = t("Prompt copied and saved: \(promptURL.lastPathComponent)")
    }

    private func applyEdits() {
        guard let selectedURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = t("Choose the edits.json produced by the AI")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else {
            statusText = t("Could not read edits.json")
            return
        }

        do {
            let spec = try JSONDecoder().decode(AgentEditSpec.self, from: data)
            let existing = ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: selectedURL))?.ranges ?? []
            let application = try AgentEditApplier.apply(spec, existingZoomRanges: existing)
            let capturedOutput = CapturedRecordingOutput(discovering: selectedURL)
            guard let capturedOutput else {
                statusText = t("Could not read edits.json")
                return
            }
            controller.applyAgentEdits(application, to: capturedOutput)
            statusText = t("Applied. Exporting…")
        } catch {
            statusText = t("Invalid edits.json: \(error.localizedDescription)")
        }
    }

    private static func normalizedVideoSizeLabel(for track: AVAssetTrack) -> String? {
        let size = track.naturalSize.applying(track.preferredTransform)
        guard abs(size.width) > 0, abs(size.height) > 0 else { return nil }
        return "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
    }
}

/// 菜单入口用的窗口控制器：AppKit 托管，避免 SwiftUI Window 场景的
/// openWindow 通知迂回。
@MainActor
final class AgentEditWindowController {
    static let shared = AgentEditWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = NSHostingView(rootView: AgentEditView())
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = InterfaceLanguageSettings.shared.text("Agent Edit")
            newWindow.contentView = content
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
