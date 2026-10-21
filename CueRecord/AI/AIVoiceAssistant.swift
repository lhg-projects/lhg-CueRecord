import Foundation

/// 一条语音口令归一化后的动作。
enum AIVoiceAction: Equatable {
    case nextPage
    case previousPage
    case firstPage
    case lastPage
    case jumpPage(Int)
    case pauseScroll
    case resumeScroll
    case finishRecording
    case none
}

/// 口令识别的结果，带来源，方便在界面上告诉用户"这句是靠规则认出来的，还是模型认出来的"。
struct AIVoiceDecision: Equatable {
    enum Origin: Equatable {
        case rule
        case model
        case none
    }

    var action: AIVoiceAction
    var confidence: Double
    var origin: Origin
    var utterance: String
    var note: String?

    static func none(_ utterance: String, origin: Origin = .none, note: String? = nil) -> AIVoiceDecision {
        AIVoiceDecision(action: .none, confidence: 0, origin: origin, utterance: utterance, note: note)
    }
}

/// 语音口令解析。规则先跑（离线、零延迟），规则认不出来再交给第三方模型（默认 DeepSeek）做语义归一。
final class AIVoiceAssistant {
    static let shared = AIVoiceAssistant()

    enum Keys {
        static let commandsEnabled = "cueRecord.ai.voice.commands.enabled"
        static let modelAssistEnabled = "cueRecord.ai.voice.modelAssist.enabled"
    }

    /// 超过这个字数的句子不当作口令，避免把正文朗读误判成命令。
    static let maxCommandLength = 14

    private let defaults: UserDefaults
    private let client = AIChatCompletionsClient()
    private let keyStore = AIProviderAPIKeyStore.shared

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCommandRecognitionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.commandsEnabled) == nil { return false }
            return defaults.bool(forKey: Keys.commandsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.commandsEnabled) }
    }

    var isModelAssistEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.modelAssistEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.modelAssistEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.modelAssistEnabled) }
    }

    var hasModelAPIKey: Bool {
        guard let configuration = modelConfiguration() else { return false }
        return keyStore.hasAPIKey(for: configuration.keychainAccount)
    }

    /// 当前选中的第三方接口（默认 DeepSeek），复用 AI 断句那套 provider / 模型选择。
    func modelConfiguration() -> AIChatModelConfiguration? {
        let providerID = AIScriptModelSelectionStorage.selectedProviderID()
        let provider = AIScriptProviderCatalog.provider(for: providerID)
        let endpoint: URL?
        if provider.id == AIScriptProviderCatalog.customProviderID {
            endpoint = AIChatEndpoint.chatCompletionsURL(from: AIScriptModelSelectionStorage.customBaseURL())
        } else {
            endpoint = provider.endpointURL
        }
        guard let endpoint else { return nil }

        let modelID: String
        if provider.id == AIScriptProviderCatalog.customProviderID {
            modelID = AIScriptModelSelectionStorage.customModelID()
        } else {
            modelID = AIScriptModelSelectionStorage.selectedModelID()
        }
        guard !modelID.isEmpty else { return nil }

        let displayName = provider.modelPreset(for: modelID)?.displayName ?? modelID
        return AIChatModelConfiguration(
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            modelID: modelID,
            modelDisplayName: displayName,
            endpoint: endpoint,
            apiKeyLabel: provider.apiKeyLabel,
            requiresAPIKey: provider.id == AIScriptProviderCatalog.customProviderID
                ? AIScriptModelSelectionStorage.customProviderRequiresAPIKey()
                : provider.requiresAPIKey,
            keychainAccount: provider.id
        )
    }

    // MARK: - 入口

    /// 判断这句话值不值得送去解析：太长的句子是正文，不拦截。
    static func isCommandCandidate(_ utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.count <= maxCommandLength
    }

    func interpret(_ utterance: String, pageCount: Int, currentPage: Int) async -> AIVoiceDecision {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none(trimmed) }

        if let rule = Self.ruleDecision(for: trimmed, pageCount: pageCount) {
            return rule
        }

        guard isModelAssistEnabled, let configuration = modelConfiguration() else {
            return .none(trimmed)
        }

        let apiKey = keyStore.loadAPIKey(for: configuration.keychainAccount)
        if configuration.requiresAPIKey && (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return .none(trimmed, note: "缺少 \(configuration.providerDisplayName) 的 API Key")
        }

        do {
            let raw = try await client.complete(
                systemPrompt: Self.systemPrompt,
                userPrompt: Self.userPrompt(utterance: trimmed, pageCount: pageCount, currentPage: currentPage),
                model: configuration,
                apiKey: apiKey
            )
            return Self.parse(raw, utterance: trimmed, pageCount: pageCount)
                ?? .none(trimmed, origin: .model, note: "模型返回的内容不是口令")
        } catch {
            return .none(trimmed, origin: .model, note: error.localizedDescription)
        }
    }

    // MARK: - 规则层

    /// 离线规则：认得出就立刻执行，不必等网络。
    static func ruleDecision(for utterance: String, pageCount: Int) -> AIVoiceDecision? {
        let text = normalize(utterance)
        guard !text.isEmpty else { return nil }

        if let page = jumpTarget(in: text, pageCount: pageCount) {
            return AIVoiceDecision(action: .jumpPage(page), confidence: 0.95, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["结束录制", "结束", "收工", "停录", "录完了", "finish", "stop recording"]) {
            return AIVoiceDecision(action: .finishRecording, confidence: 0.9, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["暂停", "停一下", "等一下", "慢点", "pause", "hold on"]) {
            return AIVoiceDecision(action: .pauseScroll, confidence: 0.85, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["继续", "接着说", "恢复", "resume", "continue", "go on"]) {
            return AIVoiceDecision(action: .resumeScroll, confidence: 0.85, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["第一页", "从头", "回到开头", "first page"]) {
            return AIVoiceDecision(action: .jumpPage(0), confidence: 0.9, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["最后一页", "最后", "末尾", "last page"]) {
            return AIVoiceDecision(action: .lastPage, confidence: 0.9, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["上一页", "往回", "回上一页", "previous page", "back"]) {
            return AIVoiceDecision(action: .previousPage, confidence: 0.9, origin: .rule, utterance: utterance, note: nil)
        }
        if matches(text, any: ["下一页", "翻页", "下一个", "往下", "next page", "next"]) {
            return AIVoiceDecision(action: .nextPage, confidence: 0.9, origin: .rule, utterance: utterance, note: nil)
        }
        return nil
    }

    private static func matches(_ text: String, any options: [String]) -> Bool {
        options.contains { text.contains(normalize($0)) }
    }

    private static func normalize(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
        return stripped.lowercased()
    }

    /// 认「第 3 页」「跳到第 3 页」「page 3」这类带页码的口令。
    /// 注意：中文数字「一」也是数字，所以必须先排除「下一页 / 上一页」这类方向词，
    /// 否则「下一页」会被解析成第 1 页。
    static func jumpTarget(in text: String, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        if text.contains("下一页") || text.contains("上一页") || text.contains("下一张") { return nil }

        var region: String?
        for lead in ["第", "跳到", "跳去", "goto", "to page", "page"] {
            if let range = text.range(of: lead) {
                region = String(text[range.upperBound...])
                break
            }
        }
        guard var tail = region else { return nil }
        if let pageRange = tail.range(of: "页") {
            tail = String(tail[..<pageRange.lowerBound])
        }

        let digits = tail.compactMap { $0.wholeNumberValue }
        guard let first = digits.first else { return nil }
        var value = first
        for digit in digits.dropFirst() {
            value = value * 10 + digit
            if value > 999 { break }
        }
        guard value >= 1 else { return nil }
        return min(value, pageCount) - 1
    }

    // MARK: - 模型层

    static let systemPrompt = """
    你是「录课台」的语音口令解析器。用户正在对着提词器讲课，会用一两个短句下达控制命令。
    只输出一个 JSON 对象，不要解释，不要代码围栏：
    {"action":"next_page|previous_page|first_page|last_page|jump_page|pause|resume|finish|none","page":数字或null,"confidence":0到1的小数}
    判断原则：拿不准就返回 none；不要把讲稿正文当成命令。
    """

    static func userPrompt(utterance: String, pageCount: Int, currentPage: Int) -> String {
        """
        口令原文：「\(utterance)」
        总页数：\(pageCount)
        当前页：\(currentPage + 1)
        """
    }

    /// 解析模型返回的 JSON。容忍代码围栏、前后多余文字、中文动作名。
    static func parse(_ raw: String, utterance: String, pageCount: Int) -> AIVoiceDecision? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let actionName = (object["action"] as? String ?? "").lowercased()
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0.6
        let page = (object["page"] as? NSNumber)?.intValue

        var action: AIVoiceAction
        switch actionName {
        case "next_page", "next", "下一页":
            action = .nextPage
        case "previous_page", "previous", "上一页":
            action = .previousPage
        case "first_page", "第一页":
            action = .jumpPage(0)
        case "last_page", "最后一页":
            action = .lastPage
        case "jump_page", "跳到":
            guard let page, pageCount > 0 else { return nil }
            action = .jumpPage(min(max(page, 1), pageCount) - 1)
        case "pause", "暂停":
            action = .pauseScroll
        case "resume", "继续":
            action = .resumeScroll
        case "finish", "结束":
            action = .finishRecording
        default:
            return nil
        }

        guard confidence >= 0.4 else { return nil }
        return AIVoiceDecision(action: action, confidence: confidence, origin: .model, utterance: utterance, note: nil)
    }

    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(raw[start...end])
    }
}
