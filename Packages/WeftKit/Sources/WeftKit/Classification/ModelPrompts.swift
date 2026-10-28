import Foundation

/// 每个模型后端共用的提示词，只此一份：Apple 端靠 `GenerationSchema` 约束输出，
/// 远端模型则在末尾追加一句「只输出 JSON」。改措辞只需要改这里。
enum ModelPrompts {
    static func candidates(_ categories: [CategoryDefinition]) -> [CategoryDefinition] {
        categories.filter { !$0.isDoNotTrack && $0.key != CategoryDefinition.uncategorizedKey }
    }

    static func classifyInstructions(_ candidates: [CategoryDefinition]) -> String {
        let list = candidates.map { "- \($0.key)：\($0.hint)" }.joined(separator: "\n")
        return """
            你在为个人时间追踪器判断一个人此刻在 Mac 上做什么。
            只从下面的列表里选择一个分类 key：
            \(list)

            按应用或网站本身的用途判断，不要被窗口标题里偶然出现的词带偏。
            只有当它是一个用途不明的网页浏览器标签页时才用 "browsing"，原生应用绝不要用。
            遇到不认识的原生应用，从它的名称和 bundle identifier 推断用途。
            """
    }

    /// 分类的 user prompt。能拿到 App Store 分类时一并给它，比只给应用名准得多。
    static func classifyPrompt(_ context: ActivityContext) -> String {
        var prompt = context.domain == nil
            ? "原生应用：\(context.appName)（bundle identifier \(context.bundleID)）"
            : "\(context.appName) 中的网页标签页"
        if context.domain == nil, let category = CategoryGuess.appStoreCategory(bundleID: context.bundleID) {
            prompt += "\nApp Store 分类：\(category.replacingOccurrences(of: "-", with: " "))"
        }
        if let domain = context.domain { prompt += "\n网站：\(domain)" }
        if let title = context.title { prompt += "\n窗口标题：\(title.prefix(200))" }
        return prompt
    }

    /// 远端模型没有 schema 可依，得自己保证格式。
    static let classifyReplyFormat = """
        只输出一个 JSON 对象，形如 {"category": "分类 key", "confidence": "high|medium|low"}，\
        不要输出解释、Markdown 或代码块。
        """

    /// `language` 在中文版里固定为简体中文，保留参数是为了和协议签名一致。
    static func describeInstructions(language: String) -> String {
        """
        你在为一份个人工时记录写条目。给你一段电脑使用过程中的应用、网站和窗口标题，\
        用一句\(language)（不超过 40 个字）说明这个人做了什么。覆盖其中最要紧的两三件事，\
        点出标题里具体的项目、话题或页面，并说明是怎么做的（例如在终端里、在 GitHub 上）。\
        不要提时长、百分比，也不要提到你自己。要写得像母语者自然会说的一句话，例如：
        在终端里开发 weft 应用，在 GitHub 上查看 ActivityWatch 仓库，并调研了时间追踪工具的替代方案。
        """
    }

    static let summarizeInstructions = """
        你是一位有耐心的效率教练。根据某一天电脑使用的统计数据，用简体中文写一段简短回顾：\
        先用两三句话说说这一天过得怎么样，再给出一个具体、可执行的明天建议。\
        不要用标题，不要用列表。
        """
}
