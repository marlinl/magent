//
//  MagentServiceTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies Magent core service dependency-container lifetime semantics.
//

import Darwin
import FactoryKit
import Foundation
import Testing
@testable import MagentX

/// `MagentService` 的 Container 单例与独立构造行为测试。
@Suite(.serialized)
struct MagentServiceTests {
    /// 验证新建核心服务在尚未启动时处于空闲状态。
    @Test func newServiceStartsIdle() async {
        let service = MagentService()

        #expect(await service.state == .idle)
    }

    /// 验证启动参数校验失败后不会把核心服务留在运行状态。
    @Test func invalidStartKeepsServiceIdle() async {
        let service = MagentService()

        do {
            try await service.start(address: " ", port: 1086)
            Issue.record("Expected an invalid listen address error")
        } catch let error as MagentXError {
            #expect(error == .invalidListenAddress(" "))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await service.state == .idle)
    }

    /// 验证核心服务真实启动和关闭时依次进入运行与空闲状态。
    @Test func startAndStopUpdateState() async throws {
        let service = MagentService()
        let port = try availableLoopbackPort()

        try await service.start(address: "127.0.0.1", port: port)
        #expect(await service.state == .running)

        try await service.stop()
        #expect(await service.state == .idle)
    }

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

    /// 让系统分配一个当前可用的回环 TCP 端口，供真实启停用例使用。
    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}
