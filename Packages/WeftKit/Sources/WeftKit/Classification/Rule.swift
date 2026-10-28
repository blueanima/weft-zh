import Foundation

public enum RuleField: String, Codable, Sendable, CaseIterable {
    case bundleID
    case domain
    case titleContains
    case urlContains

    /// More specific matches win over broader ones.
    var specificity: Int {
        switch self {
        case .bundleID: 0
        case .domain: 1
        case .titleContains, .urlContains: 2
        }
    }
}

public enum RuleSource: String, Codable, Sendable {
    case user
    case builtin
}

public struct Rule: Hashable, Sendable {
    public var field: RuleField
    public var pattern: String
    public var categoryKey: String
    public var source: RuleSource

    public init(field: RuleField, pattern: String, categoryKey: String, source: RuleSource) {
        self.field = field
        self.pattern = pattern.lowercased()
        self.categoryKey = categoryKey
        self.source = source
    }

    public func matches(_ context: ActivityContext) -> Bool {
        switch field {
        case .bundleID:
            // 内置的 app 规则说明的是「这个应用是干什么的」；到了浏览器标签页里，该由网站决定，
            // 否则不认识的全被当成浏览网页，根本轮不到模型。用户自己给浏览器建的规则仍然管所有标签页。
            guard source == .user || context.domain == nil else { return false }
            return context.bundleID.lowercased() == pattern
        case .domain:
            // `github.com` matches `github.com` and `gist.github.com`.
            guard let domain = context.domain else { return false }
            return domain == pattern || domain.hasSuffix("." + pattern)
        case .titleContains:
            return context.title?.lowercased().contains(pattern) ?? false
        case .urlContains:
            return context.url?.lowercased().contains(pattern) ?? false
        }
    }
}

/// Picks the best matching rule: user rules beat built-in ones, then the most specific
/// field wins, then the longest pattern.
public struct RuleEngine: Sendable {
    private let ordered: [Rule]

    public init(rules: [Rule]) {
        ordered = rules.sorted { a, b in
            if a.source != b.source { return a.source == .user }
            if a.field.specificity != b.field.specificity { return a.field.specificity > b.field.specificity }
            return a.pattern.count > b.pattern.count
        }
    }

    public func match(_ context: ActivityContext) -> Rule? {
        ordered.first { $0.matches(context) }
    }
}
