import Testing
@testable import WeftKit

struct RuleEngineTests {
    @Test func builtinBundleRule() {
        let engine = RuleEngine(rules: BuiltinRules.all)
        let context = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
        #expect(engine.match(context)?.categoryKey == "code")
    }

    @Test func domainBeatsBrowserBundleRule() {
        let engine = RuleEngine(rules: BuiltinRules.all)
        let context = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://www.youtube.com/watch?v=1")
        #expect(context.domain == "youtube.com")
        #expect(engine.match(context)?.categoryKey == "entertainment")

        let blank = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome")
        #expect(engine.match(blank)?.categoryKey == "browsing")
    }

    @Test func subdomainMatchesAndLongestDomainWins() {
        let engine = RuleEngine(rules: BuiltinRules.all)
        let mail = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://mail.google.com/mail/u/0")
        #expect(engine.match(mail)?.categoryKey == "email")
        let search = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://www.google.com/search?q=x")
        #expect(engine.match(search)?.categoryKey == "research")
        let gist = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://gist.github.com/x")
        #expect(engine.match(gist)?.categoryKey == "code")
        // 不是 github.com，也不该被浏览器自己的规则兜住：它要交给模型判。
        let fake = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://notgithub.com/x")
        #expect(engine.match(fake) == nil)
    }

    @Test func userRulesOverrideBuiltins() {
        let user = Rule(field: .domain, pattern: "youtube.com", categoryKey: "learning", source: .user)
        let engine = RuleEngine(rules: BuiltinRules.all + [user])
        let context = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://youtube.com/watch")
        #expect(engine.match(context)?.categoryKey == "learning")
    }

    @Test func titleRuleIsMoreSpecificThanBundleRule() {
        let rules = [
            Rule(field: .bundleID, pattern: "com.apple.Terminal", categoryKey: "code", source: .user),
            Rule(field: .titleContains, pattern: "SSH", categoryKey: "admin", source: .user),
        ]
        let engine = RuleEngine(rules: rules)
        #expect(engine.match(ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal", title: "ssh prod"))?.categoryKey == "admin")
        #expect(engine.match(ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal", title: "zsh"))?.categoryKey == "code")
    }

    @Test func builtinRulesReferenceKnownCategories() {
        let keys = Set(CategoryDefinition.defaults.map(\.key))
        for rule in BuiltinRules.all {
            #expect(keys.contains(rule.categoryKey), "\(rule.pattern) → \(rule.categoryKey)")
        }
    }

    @Test func classificationKeyAndHostOnly() {
        let context = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://www.Example.com/a?b=1")
        #expect(context.classificationKey == "com.apple.Safari|example.com")
        #expect(ActivityContext.hostOnly("https://example.com/a/b?c=1#d") == "https://example.com")
        #expect(ActivityContext(bundleID: "x", appName: "X").classificationKey == "x")
    }
}
