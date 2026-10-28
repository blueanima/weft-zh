import Foundation

/// Value snapshot of a category and the flags that drive metrics, idle detection and blocking.
public struct CategoryDefinition: Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var colorHex: String
    /// Counts towards focus time and the Focus Score.
    public var isFocusTime: Bool
    /// Counts as meeting time; idle detection is suspended while in a meeting.
    public var isMeeting: Bool
    /// Triggers the distraction blocker during focus sessions.
    public var blockInFocus: Bool
    /// Matching activity is not recorded at all.
    public var isDoNotTrack: Bool
    /// One-line hint for the classifier.
    public var hint: String

    public var id: String { key }

    public init(
        key: String, name: String, colorHex: String,
        isFocusTime: Bool = false, isMeeting: Bool = false,
        blockInFocus: Bool = false, isDoNotTrack: Bool = false, hint: String = ""
    ) {
        self.key = key
        self.name = name
        self.colorHex = colorHex
        self.isFocusTime = isFocusTime
        self.isMeeting = isMeeting
        self.blockInFocus = blockInFocus
        self.isDoNotTrack = isDoNotTrack
        self.hint = hint
    }

    /// True for categories that should be avoided during focus — used for the distraction metric.
    public var isDistracting: Bool { blockInFocus }
}

public extension CategoryDefinition {
    static let uncategorizedKey = "uncategorized"

    /// 中文版之前用的英文默认名。只在升级已有数据库时用来判断这个分类还没被用户改过。
    static let legacyEnglishNames: [String: String] = [
        "code": "Code",
        "design": "Design",
        "writing": "Writing",
        "documenting": "Documenting",
        "research": "Research",
        "learning": "Learning",
        "product": "Product",
        "productivity": "Productivity",
        "admin": "Admin",
        "finance": "Finance",
        "marketing": "Marketing",
        "sales": "Sales",
        "customer_support": "Customer Support",
        "email": "Email",
        "messaging": "Messaging",
        "meetings": "Meetings",
        "video_conferencing": "Video Conferencing",
        "browsing": "Browsing",
        "utility": "Utility",
        "entertainment": "Entertainment",
        "gaming": "Gaming",
        "shopping": "Shopping",
        "social_media": "Social Media",
        "personal": "Personal",
        "miscellaneous": "Miscellaneous",
        uncategorizedKey: "Uncategorized",
    ]

    /// Mirrors the category keys Rize uses so habits and mental models carry over.
    static let defaults: [CategoryDefinition] = [
        .init(key: "code", name: "代码", colorHex: "#4F7CFF", isFocusTime: true, hint: "IDE、终端、代码评审、开发者文档"),
        .init(key: "design", name: "设计", colorHex: "#C356F0", isFocusTime: true, hint: "Figma、Sketch、图片与视频剪辑"),
        .init(key: "writing", name: "写作", colorHex: "#2BB8A4", isFocusTime: true, hint: "写文章、笔记、草稿"),
        .init(key: "documenting", name: "文档", colorHex: "#36A3D9", isFocusTime: true, hint: "文档、Wiki、规格说明"),
        .init(key: "research", name: "调研", colorHex: "#5FB760", isFocusTime: true, hint: "为工作搜索、阅读文章和论文"),
        .init(key: "learning", name: "学习", colorHex: "#8DBF3E", isFocusTime: true, hint: "课程、教程、学习"),
        .init(key: "product", name: "产品", colorHex: "#E58A2E", isFocusTime: true, hint: "需求管理、路线图、产品工作"),
        .init(key: "productivity", name: "效率", colorHex: "#E2B93B", isFocusTime: true, hint: "日历、待办、笔记、表格"),
        .init(key: "admin", name: "行政", colorHex: "#9A8C7A", hint: "账户设置、人事、事务性工作"),
        .init(key: "finance", name: "财务", colorHex: "#3E9E73", hint: "银行、记账、发票"),
        .init(key: "marketing", name: "市场", colorHex: "#EF6F8E", hint: "广告、数据分析、营销活动"),
        .init(key: "sales", name: "销售", colorHex: "#D9534F", hint: "客户管理、拓展客户"),
        .init(key: "customer_support", name: "客户支持", colorHex: "#E07B53", hint: "工单系统、客服邮箱"),
        .init(key: "email", name: "邮件", colorHex: "#5C6BC0", hint: "邮件客户端和网页邮箱"),
        .init(key: "messaging", name: "即时通讯", colorHex: "#7E57C2", hint: "工作沟通和私人聊天应用"),
        .init(key: "meetings", name: "会议", colorHex: "#00ACC1", isMeeting: true, hint: "正在进行的日程"),
        .init(key: "video_conferencing", name: "视频会议", colorHex: "#0097A7", isMeeting: true, hint: "Zoom、Meet、Teams、FaceTime"),
        .init(key: "browsing", name: "浏览网页", colorHex: "#90A4AE", hint: "没有明确目的的网页浏览"),
        .init(key: "utility", name: "工具", colorHex: "#78909C", hint: "系统设置、访达、文件管理、启动器"),
        .init(key: "entertainment", name: "娱乐", colorHex: "#F44336", blockInFocus: true, hint: "视频、音乐、资讯娱乐"),
        .init(key: "gaming", name: "游戏", colorHex: "#E91E63", blockInFocus: true, hint: "游戏和游戏平台"),
        .init(key: "shopping", name: "购物", colorHex: "#FF7043", blockInFocus: true, hint: "网上商城"),
        .init(key: "social_media", name: "社交媒体", colorHex: "#FF5252", blockInFocus: true, hint: "微博、小红书、X、Reddit、Instagram、TikTok"),
        .init(key: "personal", name: "个人", colorHex: "#BCAAA4", blockInFocus: true, hint: "与工作无关的私人事务"),
        .init(key: "miscellaneous", name: "其他", colorHex: "#B0BEC5", hint: "放不进其他分类的内容"),
        .init(key: uncategorizedKey, name: "未分类", colorHex: "#CFD8DC", hint: "尚未分类"),
    ]
}
