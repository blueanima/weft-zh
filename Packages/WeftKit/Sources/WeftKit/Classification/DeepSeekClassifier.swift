import Foundation
import os

public struct DeepSeekConfig: Sendable, Equatable {
    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"

    public var apiKey: String
    public var baseURL: String
    public var model: String
    /// V4.1 Flash 默认开启思考模式：更准，但更慢也更贵。分类、摘要这类短任务关掉更划算。
    public var thinking: Bool

    public init(
        apiKey: String = "",
        baseURL: String = DeepSeekConfig.defaultBaseURL,
        model: String = DeepSeekConfig.defaultModel,
        thinking: Bool = false
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.thinking = thinking
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `https://api.deepseek.com` → `https://api.deepseek.com/chat/completions`
    func endpoint(_ path: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let base = URL(string: trimmed), let scheme = base.scheme,
              scheme == "https" || scheme == "http", base.host != nil else { return nil }
        return base.appending(path: path)
    }
}

public enum DeepSeekError: LocalizedError, Equatable {
    case missingKey
    case invalidBaseURL
    case http(status: Int, message: String)
    case emptyResponse
    case badJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "还没有填写 DeepSeek API Key。"
        case .invalidBaseURL:
            "接口地址无效，需要形如 https://api.deepseek.com。"
        case .http(let status, let message):
            message.isEmpty ? "DeepSeek 返回 HTTP \(status)。" : "DeepSeek 返回 HTTP \(status)：\(message)"
        case .emptyResponse:
            "DeepSeek 没有返回内容。"
        case .badJSON(let text):
            "无法解析模型返回的 JSON：\(text)"
        }
    }
}

/// Classifies and summarizes activity with DeepSeek's OpenAI-compatible chat API.
/// The system prompts are kept byte-stable so DeepSeek's context cache keeps hitting.
public final class DeepSeekClassifier: AIClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var config: DeepSeekConfig
    private let session: URLSession
    private let logger = Logger(subsystem: "me.weishu.Weft", category: "DeepSeek")

    public init(config: DeepSeekConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    public var currentConfig: DeepSeekConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    public func update(config: DeepSeekConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    public func availability() -> AIAvailability {
        currentConfig.isConfigured ? .available : .unavailable("还没有填写 DeepSeek API Key。")
    }

    // MARK: Classification

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = categories.filter { !$0.isDoNotTrack && $0.key != CategoryDefinition.uncategorizedKey }
        let keys = Set(candidates.map(\.key))
        let categoryList = candidates.map { "- \($0.key)：\($0.hint)" }.joined(separator: "\n")

        let system = """
            你在为个人时间追踪器判断一个人此刻在 Mac 上做什么。
            只从下面的列表里选择一个分类 key：
            \(categoryList)

            按应用或网站本身的用途判断，不要被窗口标题里偶然出现的词带偏。
            只有当它是一个用途不明的网页浏览器标签页时才用 "browsing"，原生应用绝不要用。
            遇到不认识的原生应用，从它的名称和 bundle identifier 推断用途。
            只输出一个 JSON 对象，形如 {"category": "分类 key", "confidence": "high|medium|low"}，\
            不要输出解释、Markdown 或代码块。
            """

        var prompt = context.domain == nil
            ? "原生应用：\(context.appName)（bundle identifier \(context.bundleID)）"
            : "\(context.appName) 中的网页标签页"
        if context.domain == nil, let category = FoundationModelsClassifier.appStoreCategory(bundleID: context.bundleID) {
            prompt += "\nApp Store 分类：\(category)"
        }
        if let domain = context.domain { prompt += "\n网站：\(domain)" }
        if let title = context.title { prompt += "\n窗口标题：\(title.prefix(200))" }

        let text = try await chat(system: system, user: prompt, json: true, maxTokens: 120, temperature: 0)
        return try Self.parseClassification(text, keys: keys)
    }

    /// Pulls `{"category": …, "confidence": …}` out of the reply, tolerating markdown fences.
    static func parseClassification(_ text: String, keys: Set<String>) throws -> AIClassification {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["category"] as? String else {
            throw DeepSeekError.badJSON(String(text.prefix(200)))
        }
        guard keys.contains(key) else { throw ClassificationError.unknownCategory(key) }
        let confidence = AIConfidence(rawValue: (object["confidence"] as? String ?? "").lowercased()) ?? .low
        return AIClassification(categoryKey: key, confidence: confidence)
    }

    // MARK: Writing

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        let system = """
            你在为一份个人工时记录写条目。给你一段电脑使用过程中的应用、网站和窗口标题，\
            用一句简体中文（不超过 40 个字）说明这个人做了什么。覆盖其中最要紧的两三件事，\
            点出标题里具体的项目、话题或页面，并说明是怎么做的（例如在终端里、在 GitHub 上）。\
            不要提时长、百分比，也不要提到你自己。只输出这一句话。
            """
        let text = try await chat(system: system, user: facts, json: false, maxTokens: 200, temperature: 0.4)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func summarize(_ facts: String) async throws -> String {
        let system = """
            你是一位有耐心的效率教练。根据某一天电脑使用的统计数据，用简体中文写一段简短回顾：\
            先用两三句话说说这一天过得怎么样，再给出一个具体、可执行的明天建议。\
            不要用标题，不要用列表。
            """
        let text = try await chat(system: system, user: facts, json: false, maxTokens: 700, temperature: 0.6)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Account

    /// The model ids this key can actually use, so the settings page can offer them.
    public func listModels() async throws -> [String] {
        let config = currentConfig
        guard config.isConfigured else { throw DeepSeekError.missingKey }
        guard let url = config.endpoint("models") else { throw DeepSeekError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        struct Payload: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw DeepSeekError.badJSON(String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        return payload.data.map(\.id).sorted()
    }

    /// A one-token round trip so the user can tell "wrong key" from "wrong model name".
    public func ping() async throws -> String {
        try await chat(system: "你是连通性测试助手。", user: "只回复两个字：连接", json: false, maxTokens: 20, temperature: 0)
    }

    // MARK: Transport

    private func chat(system: String, user: String, json: Bool, maxTokens: Int, temperature: Double) async throws -> String {
        let config = currentConfig
        guard config.isConfigured else { throw DeepSeekError.missingKey }
        guard let url = config.endpoint("chat/completions") else { throw DeepSeekError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_tokens": maxTokens,
            "stream": false,
            "thinking": ["type": config.thinking ? "enabled" : "disabled"],
        ]
        if !config.thinking { body["temperature"] = temperature }
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        struct Payload: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let content = payload.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekError.emptyResponse
        }
        return content
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekError.http(status: http.statusCode, message: errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
            let message: String?
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else { return "" }
        return failure.error?.message ?? failure.message ?? ""
    }
}
