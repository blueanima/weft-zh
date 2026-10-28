import AppKit
import Foundation

/// 给规则不认识、又没有模型可问的应用和网站一个粗略分类。原生应用看它自己声明的
/// App Store 分类，网站看域名里的词。猜得经常不准，所以结果只在「待确认」里等你过一眼，
/// 模型一旦可用就会被正式答案替换掉。
public enum CategoryGuess {
    public static func category(for context: ActivityContext, appStoreCategory: String?) -> String {
        if let domain = context.domain { return category(forDomain: domain) }
        guard let appStoreCategory else { return "miscellaneous" }
        if appStoreCategory.hasSuffix("games") { return "gaming" }
        return appCategories[appStoreCategory] ?? "miscellaneous"
    }

    /// `public.app-category.developer-tools` → `developer-tools`，取自应用的 Info.plist。
    public static func appStoreCategory(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let type = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
              type.hasPrefix("public.app-category.") else { return nil }
        return String(type.dropFirst("public.app-category.".count))
    }

    static func category(forDomain domain: String) -> String {
        if domain.hasSuffix(".edu") || domain.contains(".edu.") { return "learning" }
        // 顶级域名说明不了什么：`.dev` 和 `.io` 上什么站都有，所以先去掉再看。
        var labels = domain.split(separator: ".")
        if labels.count > 1 { labels.removeLast() }
        let words = Set(labels.flatMap { $0.split(separator: "-") }.map(String.init))
        for (category, keywords) in domainKeywords where !words.isDisjoint(with: keywords) {
            return category
        }
        return "browsing"
    }

    private static let appCategories: [String: String] = [
        "business": "productivity",
        "developer-tools": "code",
        "education": "learning",
        "entertainment": "entertainment",
        "finance": "finance",
        "graphics-design": "design",
        "healthcare-fitness": "personal",
        "lifestyle": "personal",
        "medical": "personal",
        "music": "entertainment",
        "news": "entertainment",
        "photography": "design",
        "productivity": "productivity",
        "reference": "research",
        "social-networking": "social_media",
        "sports": "entertainment",
        "travel": "personal",
        "utilities": "utility",
        "video": "entertainment",
        "weather": "utility",
    ]

    /// 按顺序检查，第一个有词命中的分类胜出。
    private static let domainKeywords: [(String, Set<String>)] = [
        ("email", ["mail", "webmail", "inbox"]),
        ("video_conferencing", ["meet", "meeting", "zoom", "webex"]),
        ("messaging", ["chat", "messenger"]),
        ("code", ["git", "gitlab", "dev", "developer", "developers", "api", "console", "localhost"]),
        ("documenting", ["docs", "doc", "wiki", "documentation", "manual", "handbook"]),
        ("learning", ["learn", "course", "courses", "academy", "school", "tutorial", "edu", "university", "study"]),
        ("research", ["search", "scholar", "paper", "papers", "journal", "dictionary", "translate"]),
        ("finance", ["bank", "banking", "pay", "invest", "stock", "stocks", "finance", "tax", "wallet"]),
        ("shopping", ["shop", "store", "mall", "buy", "deals", "cart", "outlet"]),
        ("gaming", ["game", "games", "gaming"]),
        ("entertainment", ["tv", "video", "videos", "movie", "movies", "film", "anime", "manga", "comic", "music",
                           "radio", "live", "stream", "news"]),
        ("social_media", ["social", "forum", "bbs", "community"]),
        ("admin", ["account", "accounts", "login", "signin", "sso", "auth", "admin"]),
    ]
}
