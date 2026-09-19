import SwiftData
import SwiftUI

/// 在真实内存 SwiftData 上下文中演示公共字段的只读、草稿、密码及菜单编辑。
struct EditableFieldFormFixture: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \MagentProxyNode.id) private var nodes: [MagentProxyNode]
  @State private var draftName = ""
  @State private var password = "123456"
  @State private var choice = "1"
  @State private var outsideText = ""
  @State private var editable = true
  @State private var allowsBeginning = true
  @State private var commits = 0
  @State private var storedName = "Node 00001"
  @State private var error = ""

  var body: some View {
    Form {
      if let node = nodes.first {
        LabeledContent("只读字段") {
          EditableFieldFormView(isEditable: false) {
            Label("Read only", systemImage: "lock")
              .accessibilityIdentifier("readonly-display")
          } editor: { focus, _ in
            TextField("Read only", text: $draftName)
              .focused(focus)
              .accessibilityIdentifier("readonly-editor")
          }
        }
        LabeledContent("名称") {
          EditableFieldFormView(
            isEditable: editable,
            onEditingBegan: {
              guard allowsBeginning else { return false }
              draftName = node.name
              return true
            },
            onEditingEnded: {
              commits += 1
              do {
                node.name = draftName
                try modelContext.save()
                // 从另一上下文读取，验证保存由调用方执行，而非只改变了展示文本。
                let context = ModelContext(modelContext.container)
                storedName = try context.fetch(FetchDescriptor<MagentProxyNode>()).first?.name ?? ""
              } catch {
                self.error = error.localizedDescription
              }
            }
          ) {
            Text(node.name)
          } editor: { focus, _ in
            TextField("名称", text: $draftName)
              .focused(focus)
          }
          .accessibilityIdentifier("editable-name")
        }
        LabeledContent("密码") {
          EditableFieldFormView {
            Text("••••••")
          } editor: { focus, _ in
            SecureField("密码", text: $password)
              .focused(focus)
          }
          .accessibilityIdentifier("editable-password")
        }
        LabeledContent("选项") {
          EditableFieldFormView(endsOnFocusLoss: false) {
            Text("Choice \(choice)")
          } editor: { _, finish in
            Picker("选项", selection: $choice) {
              Text("Option 1").tag("1")
              Text("Option 2").tag("2")
            }
            .pickerStyle(.menu)
            .onChange(of: choice) { _, _ in finish() }
          }
          .accessibilityIdentifier("editable-choice")
        }
      }
      Section("测试控制") {
        TextField("外部输入", text: $outsideText)
          .accessibilityIdentifier("outside-input")
        Toggle("允许编辑", isOn: $editable)
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("allow-edit")
        Toggle("允许进入", isOn: $allowsBeginning)
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("allow-begin")
        Text("Outside").accessibilityIdentifier("outside")
        Text("commits:\(commits)|stored:\(storedName)")
          .accessibilityIdentifier("commit-state")
        Text(error).accessibilityIdentifier("fixture-error")
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 640, minHeight: 480)
  }
}
