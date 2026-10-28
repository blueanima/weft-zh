import WeftKit
import SwiftUI

/// The four category flags are mutually exclusive in practice, so they are presented as one
/// type per category.
enum CategoryType: CaseIterable, Identifiable {
    case focus, meeting, neutral, distracting, doNotTrack

    var id: Self { self }

    init(_ category: CategoryDefinition) {
        if category.isDoNotTrack { self = .doNotTrack }
        else if category.isMeeting { self = .meeting }
        else if category.blockInFocus { self = .distracting }
        else if category.isFocusTime { self = .focus }
        else { self = .neutral }
    }

    var title: String {
        switch self {
        case .focus: "专注"
        case .meeting: "会议"
        case .neutral: "中性"
        case .distracting: "分心"
        case .doNotTrack: "不追踪"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "scope"
        case .meeting: "person.2"
        case .neutral: "circle.dashed"
        case .distracting: "hand.raised"
        case .doNotTrack: "eye.slash"
        }
    }

    var explanation: String {
        switch self {
        case .focus: "计入专注时间，并提升专注分。"
        case .meeting: "单独统计；开会时即使不操作也不会算作离开。"
        case .neutral: "会被记录，但既不算专注也不算分心。"
        case .distracting: "会降低专注分，并在专注时段触发拦截。"
        case .doNotTrack: "活动会被丢弃，不会保存。"
        }
    }

    func apply(to category: inout CategoryDefinition) {
        category.isFocusTime = self == .focus
        category.isMeeting = self == .meeting
        category.blockInFocus = self == .distracting
        category.isDoNotTrack = self == .doNotTrack
    }
}

struct CategoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.classifier.categories.filter { $0.key != CategoryDefinition.uncategorizedKey }
        Form {
            ForEach(CategoryType.allCases) { type in
                let members = categories.filter { CategoryType($0) == type }
                Section {
                    if members.isEmpty {
                        Text("暂无分类").foregroundStyle(.tertiary)
                    }
                    ForEach(members) { category in
                        CategoryRow(category: category, type: type)
                    }
                } header: {
                    Label(type.title, systemImage: type.symbol)
                } footer: {
                    Text(type.explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("分类")
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CategoryDefinition
    let type: CategoryType
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(category.color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name)
                if !category.hint.isEmpty {
                    Text(category.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("编辑") { isEditing = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                    CategoryEditor(category: category) { model.classifier.updateCategory($0) }
                }
            Menu {
                ForEach(CategoryType.allCases.filter { $0 != type }) { target in
                    Button {
                        var updated = category
                        target.apply(to: &updated)
                        model.classifier.updateCategory(updated)
                    } label: {
                        Label(target.title, systemImage: target.symbol)
                    }
                }
            } label: {
                Text("移动到")
            }
            .fixedSize()
        }
    }
}

private struct CategoryEditor: View {
    @State private var draft: CategoryDefinition
    let onSave: (CategoryDefinition) -> Void
    @Environment(\.dismiss) private var dismiss

    init(category: CategoryDefinition, onSave: @escaping (CategoryDefinition) -> Void) {
        _draft = State(initialValue: category)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("名称", text: $draft.name)
            ColorPicker("颜色", selection: Binding(
                get: { draft.color },
                set: { draft.colorHex = $0.hexString }
            ), supportsOpacity: false)
            TextField("描述", text: $draft.hint, prompt: Text("这类包含什么"), axis: .vertical)
                .lineLimit(2...4)
            Text("这段描述会帮助设备端模型判断哪些活动归入此分类。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}
