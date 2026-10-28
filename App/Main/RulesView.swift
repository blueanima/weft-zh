import WeftKit
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var field: RuleField = .domain
    @State private var pattern = ""
    @State private var categoryKey = "code"

    var body: some View {
        Form {
            Section("添加规则") {
                Picker("匹配方式", selection: $field) {
                    ForEach(RuleField.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                }
                TextField("匹配内容", text: $pattern, prompt: Text(Self.placeholder(for: field)))
                    .onSubmit(add)
                Picker("分类", selection: $categoryKey) {
                    ForEach(model.classifier.categories) { Text($0.name).tag($0.key) }
                }
                HStack {
                    Spacer()
                    Button("添加规则", action: add)
                        .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if model.classifier.userRules.isEmpty {
                    Text("还没有规则。修改某个应用或网站的分类时，也会自动生成规则。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.classifier.userRules) { rule in
                    HStack {
                        Text(Self.label(for: rule.field)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(rule.pattern).font(.body.monospaced())
                        Spacer()
                        CategoryChip(category: model.classifier.category(rule.categoryKey))
                        Button {
                            model.classifier.deleteRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除规则并重新分类匹配的活动")
                    }
                }
            } header: {
                Text("你的规则")
            } footer: {
                Text("你的规则优先于 \(BuiltinRules.all.count) 条内置规则。越具体的匹配优先级越高：标题和网址高于域名，域名高于应用。没有规则匹配的活动交给设备端模型分类。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("规则")
    }

    private func add() {
        model.classifier.addRule(field: field, pattern: pattern, categoryKey: categoryKey)
        pattern = ""
    }

    static func label(for field: RuleField) -> String {
        switch field {
        case .bundleID: "应用 Bundle ID"
        case .domain: "域名"
        case .titleContains: "标题包含"
        case .urlContains: "网址包含"
        }
    }

    static func placeholder(for field: RuleField) -> String {
        switch field {
        case .bundleID: "com.apple.dt.Xcode"
        case .domain: "github.com"
        case .titleContains: "拉取请求"
        case .urlContains: "/watch?v="
        }
    }
}
