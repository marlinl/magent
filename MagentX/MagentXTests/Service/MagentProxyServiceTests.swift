//
//  MagentProxyServiceTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for local proxy listener startup validation.
//

import Darwin
import Foundation
import Testing
@testable import MagentX

/// `MagentProxyService` 本地监听端口启动前校验的单元测试。
struct MagentProxyServiceTests {
    /// 验证代理端口已被其他监听 socket 占用时抛出统一的 app 层错误。
    @Test func startProxyServerRejectsOccupiedPort() async throws {
        let reservedPort = try ReservedTCPPort()
        let settings = GeneralSettings(proxyListenPort: reservedPort.port)
        let service = try await MainActor.run {
            try MagentProxyService(
                generalSettings: settings,
                makeMagentService: { threadNumber, eventLoopGroup, pacEndpoint in
                    MagentService(
                        threadNumber: threadNumber,
                        eventLoopGroup: eventLoopGroup,
                        pacEndpoint: pacEndpoint
                    )
                }
            )
        }

        do {
            try await service.startProxyServer()
            Issue.record("Expected occupied proxy port to fail before startup")
        } catch let error as MagentXError {
            #expect(error == .listenPortUnavailable(GeneralSettings.localhostAddress, reservedPort.port))
        } catch {
            Issue.record("Expected MagentXError.listenPortUnavailable, got \(error)")
        }
    }

    /// 验证 PAC HTTP 端口已被占用时，由 `MagentService` 返回统一的 app 层错误。
    @Test func startPACServerRejectsOccupiedPort() async throws {
        let reservedPort = try ReservedTCPPort()
        let settings = GeneralSettings(pacListenPort: reservedPort.port)
        let service = try await MainActor.run {
            try MagentProxyService(
                generalSettings: settings,
                makeMagentService: { threadNumber, eventLoopGroup, pacEndpoint in
                    MagentService(
                        threadNumber: threadNumber,
                        eventLoopGroup: eventLoopGroup,
                        pacEndpoint: pacEndpoint
                    )
                }
            )
        }

        do {
            try await service.startPacServer()
            Issue.record("Expected occupied PAC port to fail before startup")
        } catch let error as MagentXError {
            #expect(error == .listenPortUnavailable(GeneralSettings.localhostAddress, reservedPort.port))
        } catch {
            Issue.record("Expected MagentXError.listenPortUnavailable, got \(error)")
        }
    }
}

/// 测试用本地 TCP 端口占位器，生命周期内保持一个真实监听 socket。
private final class ReservedTCPPort {
    let port: Int
    private let descriptor: CInt

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Self.posixError()
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(GeneralSettings.localhostAddress))

        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else {
            Darwin.close(descriptor)
            throw Self.posixError()
        }
        guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            Darwin.close(descriptor)
            throw Self.posixError()
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &boundAddressLength)
            }
        }
        guard nameStatus == 0 else {
            Darwin.close(descriptor)
            throw Self.posixError()
        }

        self.descriptor = descriptor
        self.port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
