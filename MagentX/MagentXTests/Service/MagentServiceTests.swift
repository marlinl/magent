//
//  MagentServiceTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies Magent core service dependency-container lifetime semantics.
//

import FactoryKit
import Testing
@testable import MagentX

/// `MagentService` 的 Container 单例与独立构造行为测试。
struct MagentServiceTests {
    /// 验证 Container 解析两次时返回同一个核心服务 actor。
    @Test @MainActor func containerResolvesOneMagentService() {
        let firstService = Container.shared.magentService()
        let secondService = Container.shared.magentService()

        #expect(firstService === secondService)
    }

    /// 验证无参构造可为隔离测试创建不与 Container 共享的核心服务。
    @Test @MainActor func standaloneServiceIsDistinctFromContainerService() {
        let standaloneService = MagentService()
        let containerService = Container.shared.magentService()

        #expect(standaloneService !== containerService)
    }

}
