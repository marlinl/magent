//
//  ProxyPolicyView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays the proxy policy management surface.
//

import SwiftUI

/// 代理策略页面，后续承载规则命中后的策略编排。
struct ProxyPolicyView: View {
    @Binding var toolbarButtons: [ContentToolbarButton]

    var body: some View {
        ContentUnavailableView(
            "代理策略尚未接入",
            systemImage: "arrow.triangle.branch",
            description: Text("这里会配置规则命中后的策略编排、节点选择和默认出口。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            toolbarButtons = []
        }
    }
}
