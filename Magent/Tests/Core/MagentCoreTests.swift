import Foundation
@testable import Magent
import NIOCore
import NIOPosix
import XCTest

/// `MagentCore` 节点、规则、Wire 路由和客户端 Channel 创建测试。
final class MagentCoreTests: XCTestCase {
    private var core: MagentCore!

    override func setUpWithError() throws {
        core = try makeCore()
    }

    override func tearDownWithError() throws {
        core = nil
    }

    func testDirectRouteReturnsNoWire() throws {
        let target = NetworkAddress.domain("direct.example", port: 443)

        XCTAssertNil(try core.routeTCPWire(target))
        XCTAssertNil(try core.routeUDPWire(target))
    }

    func testTCPProxyRouteUsesRegisteredNodeAddress() throws {
        let node = makeProxyNode(id: UUID(), host: "192.0.2.10")
        let target = NetworkAddress.domain("target.example", port: 443)
        core = try makeCore(rules: [
            try ProxyRule(
                matchType: .exactDomain,
                matchValue: "target.example",
                decision: .proxy(node.id),
                order: 0
            ),
        ])
        try core.putProxyNode(node)

        let wire = try XCTUnwrap(core.routeTCPWire(target))

        XCTAssertEqual(wire.getTargetAddress(), node.address)
    }

    func testTCPProxyRouteThrowsWhenNodeIsMissing() throws {
        let missingNodeID = UUID()
        let target = NetworkAddress.domain("missing.example", port: 443)
        core = try makeCore(rules: [
            try ProxyRule(
                matchType: .exactDomain,
                matchValue: "missing.example",
                decision: .proxy(missingNodeID),
                order: 0
            ),
        ])

        XCTAssertThrowsError(try core.routeTCPWire(target)) { error in
            XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(missingNodeID))
        }
    }

    func testUDPProxyRouteThrowsWhenNodeIsMissing() throws {
        let missingNodeID = UUID()
        let target = NetworkAddress.domain("missing.example", port: 53)
        core = try makeCore(rules: [
            try ProxyRule(
                matchType: .exactDomain,
                matchValue: "missing.example",
                decision: .proxy(missingNodeID),
                order: 0
            ),
        ])

        XCTAssertThrowsError(try core.routeUDPWire(target)) { error in
            XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(missingNodeID))
        }
    }

    func testUDPRouteUsesRegisteredWire() throws {
        let node = makeProxyNode(id: UUID(), host: "192.0.2.11")
        let target = NetworkAddress.domain("dns.example", port: 53)
        core = try makeCore(rules: [
            try ProxyRule(
                matchType: .exactDomain,
                matchValue: "dns.example",
                decision: .proxy(node.id),
                order: 0
            ),
        ])
        try core.putProxyNode(node)

        let routeWire = try XCTUnwrap(core.routeUDPWire(target))

        XCTAssertEqual(routeWire.getTargetAddress(), node.address)
    }

    func testPutAllProxyNodesUsesLastNodeForDuplicateID() throws {
        let nodeID = UUID()
        let first = makeProxyNode(id: nodeID, host: "192.0.2.12")
        let last = makeProxyNode(id: nodeID, host: "192.0.2.13")
        let target = NetworkAddress.domain("target.example", port: 443)
        core = try makeCore(rules: [
            try ProxyRule(
                matchType: .exactDomain,
                matchValue: "target.example",
                decision: .proxy(nodeID),
                order: 0
            ),
        ])
        try core.putAllProxyNodes([first, last])

        XCTAssertEqual(try core.routeTCPWire(target)?.getTargetAddress(), last.address)
        XCTAssertEqual(try core.routeUDPWire(target)?.getTargetAddress(), last.address)
    }

    func testPutProxyNodeRejectsDuplicateAddressForDifferentIDs() throws {
        let address = try SocketAddress(ipAddress: "192.0.2.14", port: 8388)
        let first = ProxyNode(
            id: UUID(),
            address: address,
            cipher: .aes128Gcm,
            password: "first-password"
        )
        let second = ProxyNode(
            id: UUID(),
            address: address,
            cipher: .aes256Gcm,
            password: "second-password"
        )
        try core.putProxyNode(first)

        XCTAssertThrowsError(try core.putProxyNode(second)) { error in
            guard case MagentError.invalidPolicy(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("192.0.2.14"))
        }
    }

    func testDomainRulesUseOrderBeforeSpecificity() throws {
        let suffixNode = makeRoutingNode(host: "192.0.2.20")
        let exactNode = makeRoutingNode(host: "192.0.2.21")
        let core = try makeRoutingCore(
            rules: [
                try ProxyRule(
                    matchType: .exactDomain,
                    matchValue: "api.example.com",
                    decision: .proxy(exactNode.id),
                    order: 10
                ),
                try ProxyRule(
                    matchType: .domainSuffix,
                    matchValue: "example.com",
                    decision: .proxy(suffixNode.id),
                    order: 0
                ),
            ],
            nodes: [suffixNode, exactNode]
        )

        let wire = try XCTUnwrap(core.routeTCPWire(.domain("API.EXAMPLE.COM", port: 443)))

        XCTAssertEqual(wire.getTargetAddress(), suffixNode.address)
    }

    func testDomainRulesUseSpecificityWhenOrderMatches() throws {
        let suffixNode = makeRoutingNode(host: "192.0.2.20")
        let exactNode = makeRoutingNode(host: "192.0.2.21")
        let core = try makeRoutingCore(
            rules: [
                try ProxyRule(
                    matchType: .domainSuffix,
                    matchValue: "example.com",
                    decision: .proxy(suffixNode.id),
                    order: 0
                ),
                try ProxyRule(
                    matchType: .exactDomain,
                    matchValue: "api.example.com",
                    decision: .proxy(exactNode.id),
                    order: 0
                ),
            ],
            nodes: [suffixNode, exactNode]
        )

        XCTAssertEqual(
            try core.routeTCPWire(.domain("api.example.com", port: 443))?.getTargetAddress(),
            exactNode.address
        )
        XCTAssertEqual(
            try core.routeTCPWire(.domain("www.example.com", port: 443))?.getTargetAddress(),
            suffixNode.address
        )
        XCTAssertNil(try core.routeTCPWire(.domain("example.org", port: 443)))
    }

    func testDuplicateNormalizedRuleUsesLastValue() throws {
        let firstNode = makeRoutingNode(host: "192.0.2.22")
        let lastNode = makeRoutingNode(host: "192.0.2.23")
        let core = try makeRoutingCore(
            rules: [
                try ProxyRule(
                    matchType: .exactDomain,
                    matchValue: "example.com",
                    decision: .proxy(firstNode.id),
                    order: 0
                ),
                try ProxyRule(
                    matchType: .exactDomain,
                    matchValue: "EXAMPLE.COM.",
                    decision: .proxy(lastNode.id),
                    order: 0
                ),
            ],
            nodes: [firstNode, lastNode]
        )

        XCTAssertEqual(
            try core.routeTCPWire(.domain("example.com", port: 80))?.getTargetAddress(),
            lastNode.address
        )
    }

    func testCIDRMatchesIPv4AndIPv6() throws {
        let ipv4Node = makeRoutingNode(host: "192.0.2.24")
        let ipv6Node = makeRoutingNode(host: "192.0.2.25")
        let core = try makeRoutingCore(
            rules: [
                try ProxyRule(
                    matchType: .ipCIDR,
                    matchValue: "10.0.0.0/8",
                    decision: .proxy(ipv4Node.id),
                    order: 0
                ),
                try ProxyRule(
                    matchType: .ipCIDR,
                    matchValue: "2001:db8::/32",
                    decision: .proxy(ipv6Node.id),
                    order: 0
                ),
            ],
            nodes: [ipv4Node, ipv6Node]
        )

        XCTAssertEqual(
            try core.routeTCPWire(.ipv4(Data([10, 20, 30, 40]), port: 53))?.getTargetAddress(),
            ipv4Node.address
        )
        XCTAssertNil(try core.routeTCPWire(.ipv4(Data([11, 20, 30, 40]), port: 53)))
        XCTAssertEqual(
            try core.routeTCPWire(
                .ipv6(Data([0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 12)), port: 443)
            )?.getTargetAddress(),
            ipv6Node.address
        )
    }

    func testUnsupportedRuleFailsCoreInitialization() throws {
        let unsupported = try ProxyRule(matchType: .urlRegex, matchValue: ".*", decision: .direct, order: 0)

        XCTAssertThrowsError(
            try MagentCore(
                defaultDecision: .direct,
                defaultProxyNode: makeRoutingNode(host: "192.0.2.254"),
                enableMatchTable: true,
                defaultTimeout: 10_000,
                rules: [unsupported]
            )
        ) { error in
            XCTAssertEqual(error as? MagentError, .invalidPolicy("urlRegex is not supported by MagentRouter"))
        }
    }

    /// TCP client Future 必须能在创建它的 EventLoop 上完成，不能由 handler 同步等待。
    func testTCPClientChannelCompletesOnSingleEventLoop() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(TestInboundHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer {
            try? server.close().wait()
            try? group.syncShutdownGracefully()
        }

        let port = try XCTUnwrap(server.localAddress?.port)
        let loop = group.next()
        let promise = loop.makePromise(of: Channel.self)
        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: true,
            defaultTimeout: 10_000,
            rules: []
        )
        loop.execute {
            core.createTCPClientChannel(
                group: loop,
                address: .domain("127.0.0.1", port: port),
                timeout: 1_000,
                handler: TestInboundHandler()
            )
                .cascade(to: promise)
        }

        let client = try promise.futureResult.wait()
        XCTAssertTrue(client.isActive)
        XCTAssertFalse(try client.getOption(ChannelOptions.autoRead).wait())
        XCTAssertEqual(try client.getOption(ChannelOptions.maxMessagesPerRead).wait(), 1)
        try client.close().wait()
    }

    func testTCPClientChannelRejectsNonPositiveTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: true,
            defaultTimeout: 10_000,
            rules: []
        )

        let future = core.createTCPClientChannel(
            group: group,
            address: .domain("127.0.0.1", port: 1),
            timeout: 0,
            handler: TestInboundHandler()
        )

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(
                error as? MagentError,
                .invalidOptions("TCP connection timeout must be greater than zero")
            )
        }
    }

    /// UDP bind Future 必须能在创建它的 EventLoop 上完成，不能由 datagram handler 同步等待。
    func testUDPClientChannelBindCompletesOnSingleEventLoop() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let promise = loop.makePromise(of: Channel.self)
        loop.execute {
            DatagramBootstrap(group: loop)
                .channelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
                .bind(host: "0.0.0.0", port: 0)
                .cascade(to: promise)
        }

        let channel = try promise.futureResult.wait()
        defer {
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
        }
        XCTAssertTrue(channel.isActive)
    }
}

private func makeCore(rules: [ProxyRule] = []) throws -> MagentCore {
    try MagentCore(
        defaultDecision: .direct,
        defaultProxyNode: makeProxyNode(id: UUID(), host: "192.0.2.254"),
        enableMatchTable: true,
        defaultTimeout: 10_000,
        rules: rules
    )
}

private func makeProxyNode(id: UUID, host: String) -> ProxyNode {
    ProxyNode(
        id: id,
        address: try! SocketAddress(ipAddress: host, port: 8388),
        cipher: .aes128Gcm,
        password: "test-password"
    )
}

private func makeRoutingCore(rules: [ProxyRule], nodes: [ProxyNode]) throws -> MagentCore {
    let core = try MagentCore(
        defaultDecision: .direct,
        defaultProxyNode: makeRoutingNode(host: "192.0.2.254"),
        enableMatchTable: true,
        defaultTimeout: 10_000,
        rules: rules
    )
    try core.putAllProxyNodes(nodes)
    return core
}

private func makeRoutingNode(host: String) -> ProxyNode {
    ProxyNode(
        address: try! SocketAddress(ipAddress: host, port: 8388),
        cipher: .aes128Gcm,
        password: "test-password"
    )
}
