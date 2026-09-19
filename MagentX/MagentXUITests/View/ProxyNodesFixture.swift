import Magent
import SwiftData
import SwiftUI

/// 隔离宿主的工具栏契约替身：只承接节点页发布的按钮，不编译或启动应用导航与服务。
/// 正式应用仍使用 ContentView.swift 中的定义，本文件不加入正式应用和 XCTest 模块。
struct ContentToolbarButton: Identifiable {
  var id: String { title }
  let title: String
  let systemImage: String
  let action: () -> Void
}

/// 直接承载正式节点页；这里只提供窗口工具栏和内存数据，不复制页面或 CRUD 实现。
struct ProxyNodesFixture: View {
  @State private var toolbarButtons: [ContentToolbarButton] = []

  var body: some View {
    ProxyNodesView(toolbarButtons: $toolbarButtons)
      .toolbar {
        ForEach(toolbarButtons) { button in
          Button(action: button.action) {
            Label(button.title, systemImage: button.systemImage)
          }
          .help(button.title)
          .accessibilityLabel(button.title)
        }
      }
      .frame(minWidth: 640, minHeight: 480)
  }

  /// 准备顺序可预测的真实节点模型，可选择为首个节点添加删除保护策略。
  static func makeContainer() throws -> ModelContainer {
    let schema = Schema([MagentProxyNode.self, MagentProxyPolicy.self])
    let container = try ModelContainer(
      for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let environment = ProcessInfo.processInfo.environment
    let count = Int(environment["NODE_COUNT"] ?? "425") ?? 425
    for index in 0..<count {
      let number = index + 1
      let id = UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", number))!
      container.mainContext.insert(
        MagentProxyNode(
          id: id, name: String(format: "Node %05d", number),
          type: ProxyNodeType.shadowsocks.rawValue,
          address: String(format: "node%05d.example", number), port: 8388,
          cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
          password: "fixture-password", timeout: 30,
          createdAt: .now, updatedAt: .now))
      if index == 0, environment["NODE_IN_USE"] == "1" {
        container.mainContext.insert(MagentProxyPolicy(id: 1, name: "测试策略", nodeID: id))
      }
    }
    try container.mainContext.save()
    return container
  }
}
