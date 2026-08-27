import Foundation
@testable import Magent
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

/// `MagentTCPConnection` 协议探测和通用连接生命周期测试。
final class MagentTCPConnectionTests: XCTestCase {
    func testProxyProbeWaitsForFragmentedHTTPMethod() {
        XCTAssertEqual(ProxyProbe.detect(Data()), .incomplete)
        XCTAssertEqual(ProxyProbe.detect(Data("CON".utf8)), .incomplete)
        XCTAssertEqual(ProxyProbe.detect(Data("CONNECT ".utf8)), .httpConnect)
        XCTAssertEqual(ProxyProbe.detect(Data("GET ".utf8)), .incomplete)
        XCTAssertEqual(ProxyProbe.detect(Data("GET /".utf8)), .httpForward)
        XCTAssertEqual(ProxyProbe.detect(Data("PROPFIND /".utf8)), .httpForward)
        XCTAssertEqual(ProxyProbe.detect(Data("M-SEARCH http://example.com/".utf8)), .httpForward)
        XCTAssertEqual(ProxyProbe.detect(Data([0x04])), .socks4)
        XCTAssertEqual(ProxyProbe.detect(Data([0x05])), .socks5)
        XCTAssertEqual(ProxyProbe.detect(Data("UNKNOWN ".utf8)), .incomplete)
        XCTAssertEqual(ProxyProbe.detect(Data("UNKNOWN protocol".utf8)), .unsupported)
    }

    func testMagentTCPConnectionClosesUnsupportedProtocol() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()

        try writeInbound(Data("UNKNOWN protocol".utf8), to: channel)
        XCTAssertFalse(channel.isActive)
        XCTAssertNil(try readOutboundData(from: channel))
    }
}

func makeConnectionChannel() throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
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
    let shutdownPromise = channel.eventLoop.makePromise(of: Void.self)
    try channel.pipeline.addHandler(
        MagentTCPConnection(channel, core: core, dnsServers: [], shutdownFuture: shutdownPromise.futureResult)
    ).wait()
    return channel
}

final class TestInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

final class TestInputClosedRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let expectation: XCTestExpectation
    private var hasReceivedInputClosed = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event as? ChannelEvent == .inputClosed, !hasReceivedInputClosed {
            hasReceivedInputClosed = true
            expectation.fulfill()
        }
        context.fireUserInboundEventTriggered(event)
    }
}

final class TestDataCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let expectedByteCount: Int
    private let promise: EventLoopPromise<Data>
    private var bytes = Data()
    private var isCompleted = false

    init(expectedByteCount: Int, promise: EventLoopPromise<Data>) {
        self.expectedByteCount = expectedByteCount
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        bytes.append(contentsOf: input.readableBytesView)
        if !isCompleted, bytes.count >= expectedByteCount {
            isCompleted = true
            promise.succeed(bytes)
        }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isCompleted {
            isCompleted = true
            promise.fail(MagentError.connectionClosed)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !isCompleted {
            isCompleted = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }
}

/// 测试侧模拟 `autoRead = false` 的来源 Channel，每次 `read()` 只交付一个预置批次。
final class ManualTestReads: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let eventLoop: EventLoop
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private var batches: [Data] = []
    private var deliveredBatchCount = 0

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func read(context: ChannelHandlerContext) {
        pendingRead = true
        deliverNextIfPossible(context: context)
    }

    func enqueue(_ batches: [Data]) -> EventLoopFuture<Void> {
        eventLoop.submit {
            self.batches.append(contentsOf: batches)
            guard let context = self.context else {
                throw MagentError.connectionClosed
            }
            self.deliverNextIfPossible(context: context)
        }
    }

    func deliveredCount() -> EventLoopFuture<Int> {
        eventLoop.submit {
            self.deliveredBatchCount
        }
    }

    private func deliverNextIfPossible(context: ChannelHandlerContext) {
        guard pendingRead, !batches.isEmpty else {
            return
        }
        pendingRead = false
        let data = batches.removeFirst()
        deliveredBatchCount += 1
        var input = context.channel.allocator.buffer(capacity: data.count)
        input.writeBytes(data)
        context.fireChannelRead(wrapInboundOut(input))
        context.fireChannelReadComplete()
    }
}

/// 把指定代理 request 和紧随其后的 payload 拆成两个同步入站事件。
///
/// SOCKS5 可以先透传 greeting，再拆分 CONNECT request；SOCKS4、HTTP CONNECT 直接拆分首个 request。
final class SplitProxyRequest: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let requestLength: Int
    private var leadingRequestLengths: [Int]
    private var buffered = Data()
    private var hasSplit = false

    init(requestLength: Int, leadingRequestLengths: [Int] = []) {
        self.requestLength = requestLength
        self.leadingRequestLengths = leadingRequestLengths
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !hasSplit else {
            context.fireChannelRead(data)
            return
        }

        let input = unwrapInboundIn(data)
        buffered.append(contentsOf: input.readableBytesView)
        while let leadingLength = leadingRequestLengths.first, buffered.count >= leadingLength {
            var leadingRequest = context.channel.allocator.buffer(capacity: leadingLength)
            leadingRequest.writeBytes(buffered.prefix(leadingLength))
            buffered.removeFirst(leadingLength)
            leadingRequestLengths.removeFirst()
            context.fireChannelRead(wrapInboundOut(leadingRequest))
        }
        guard leadingRequestLengths.isEmpty else {
            return
        }
        guard buffered.count > requestLength else {
            return
        }

        hasSplit = true
        var request = context.channel.allocator.buffer(capacity: requestLength)
        request.writeBytes(buffered.prefix(requestLength))
        var payload = context.channel.allocator.buffer(capacity: buffered.count - requestLength)
        payload.writeBytes(buffered.dropFirst(requestLength))
        buffered.removeAll(keepingCapacity: false)

        context.fireChannelRead(wrapInboundOut(request))
        context.fireChannelRead(wrapInboundOut(payload))
    }
}

/// 延迟测试 proxy channel 的指定写入，使握手响应或 tunnel payload 的 Future 保持未完成。
final class DelayedTestWrites: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer

    private let eventLoop: EventLoop
    private let firstWritePromise: EventLoopPromise<Data>
    private let writesBeforeDelay: Int
    private var context: ChannelHandlerContext?
    private var pendingWrites: [(NIOAny, EventLoopPromise<Void>?)] = []
    private var hasPendingFlush = false
    private var isDelaying = true
    private var recordedWriteCount = 0

    init(eventLoop: EventLoop, firstWritePromise: EventLoopPromise<Data>, writesBeforeDelay: Int = 0) {
        self.eventLoop = eventLoop
        self.firstWritePromise = firstWritePromise
        self.writesBeforeDelay = writesBeforeDelay
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        recordedWriteCount += 1
        guard recordedWriteCount > writesBeforeDelay else {
            context.write(data, promise: promise)
            return
        }
        if recordedWriteCount == writesBeforeDelay + 1 {
            firstWritePromise.succeed(Data(unwrapOutboundIn(data).readableBytesView))
        }
        guard isDelaying else {
            context.write(data, promise: promise)
            return
        }
        pendingWrites.append((data, promise))
    }

    func flush(context: ChannelHandlerContext) {
        guard !pendingWrites.isEmpty else {
            context.flush()
            return
        }
        guard isDelaying else {
            context.flush()
            return
        }
        hasPendingFlush = true
    }

    func release() -> EventLoopFuture<Void> {
        eventLoop.submit {
            guard self.isDelaying, let context = self.context else {
                return
            }
            self.isDelaying = false
            let pendingWrites = self.pendingWrites
            self.pendingWrites.removeAll(keepingCapacity: false)
            for (data, promise) in pendingWrites {
                context.write(data, promise: promise)
            }
            if self.hasPendingFlush {
                self.hasPendingFlush = false
                context.flush()
            }
        }
    }

    func writeCount() -> EventLoopFuture<Int> {
        eventLoop.submit {
            self.recordedWriteCount
        }
    }
}

func writeInbound(_ data: Data, to channel: EmbeddedChannel) throws {
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    _ = try channel.writeInbound(buffer)
}

func readOutboundData(from channel: EmbeddedChannel) throws -> Data? {
    guard let buffer: ByteBuffer = try channel.readOutbound() else {
        return nil
    }
    return Data(buffer.readableBytesView)
}

func bindTCPProxy(
    group: EventLoopGroup,
    core: MagentCore,
    dnsServers: [SocketAddress] = [],
    shutdownFuture: EventLoopFuture<Void>,
    configurePipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void> = {
        $0.eventLoop.makeSucceededFuture(())
    }
) throws -> Channel {
    try ServerBootstrap(group: group)
        .childChannelOption(ChannelOptions.autoRead, value: false)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { channel in
            configurePipeline(channel).flatMap {
                channel.pipeline.addHandler(
                    MagentTCPConnection(
                        channel,
                        core: core,
                        dnsServers: dnsServers,
                        shutdownFuture: shutdownFuture
                    )
                )
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
}

func writeData(_ data: Data, to channel: Channel) throws {
    var output = channel.allocator.buffer(capacity: data.count)
    output.writeBytes(data)
    try channel.writeAndFlush(output).wait()
}

func shutdownTestChannels(_ channels: [Channel], group: MultiThreadedEventLoopGroup) {
    for channel in channels.reversed() {
        try? channel.close().wait()
    }
    try? group.syncShutdownGracefully()
}
