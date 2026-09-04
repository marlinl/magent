//
//  MagentXContainer.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/4.
//

import FactoryKit
import Foundation
@preconcurrency import NIOCore

/// 创建一套独立 Magent 核心运行服务的工厂闭包。
typealias MagentServiceFactory = @Sendable (
    _ threadNumber: Int,
    _ eventLoopGroup: EventLoopGroup,
    _ pacEndpoint: MagentProxyService.ListenEndpoint
) -> MagentService

extension Container {
    /// 提供创建独立 Magent 核心运行服务的闭包；每次调用闭包都会生成新运行实例。
    @MainActor
    var magentServiceFactory: Factory<MagentServiceFactory> {
        self {
            { threadNumber, eventLoopGroup, pacEndpoint in
                MagentService(
                    threadNumber: threadNumber,
                    eventLoopGroup: eventLoopGroup,
                    pacEndpoint: pacEndpoint
                )
            }
        }
        .cached
    }

    /// 提供绑定当前 SwiftData 容器的代理规则服务；应用启动时必须先注册实际实例。
    @MainActor
    var magentProxyRuleService: Factory<MagentProxyRuleService> {
        self {
            preconditionFailure("MagentProxyRuleService must be registered during application startup")
        }
        .onPreview {
            do {
                let modelContainer = try MagentXApp.makeModelContainer(isStoredInMemoryOnly: true)
                return MagentProxyRuleService(modelContainer: modelContainer)
            } catch {
                preconditionFailure("Failed to create preview model container: \(error.localizedDescription)")
            }
        }
        .cached
    }
}
