//
//  HttpForwardConnection.swift
//  Magent
//
//  Created by MarlinL on 2026/8/27.
//

import Foundation
import NIOCore
import NIOHTTP1

/// 完整接收并转发唯一 HTTP 请求；目标/头语义由模型决定，响应始终保持不透明字节流。
/// accepted EventLoop 串行持有本连接，下游资源随主 handler 的 closeConnection 释放。
internal final class HttpForwardConnection: ChannelInboundHandler, ProxyConnection,
  @unchecked Sendable
{
  typealias InboundIn = ByteBuffer

  /// forward 表示下游已启动，可接收响应；请求是否写完由 requestSent 单独记录。
  private enum State {
    case request
    case forward
    case closed
  }

  // accepted Channel 的最终关闭由 MagentTCPConnection 管理，Core 只负责当前 runtime 的选路。
  private let proxyChannel: Channel
  private let core: MagentCore
  private var state: State = .request

  // 请求头和完整 body 在拨号前验证；扫描位置跨读取保留，避免重复扫描整个头部。
  private var requestBuffer: ByteBuffer
  private var requestBody: ByteBuffer
  private var request: HttpProtocol?
  private var requestVersion: HTTPVersion = .http1_1
  private var headScanOffset = 0

  // NIO 适配器负责报文与字节转换；Connection 保留上下文，以统一安排实际网络写入。
  private var requestContext: ChannelHandlerContext?
  private var requestParts: HTTPRequestPartsHandler?
  private var requestEncoder: HTTPRequestEncoder?
  private var requestEncodedBytes: HTTPEncodedBytesHandler?
  private var requestEncoderContext: ChannelHandlerContext?
  private var responseEncoder: HTTPResponseEncoder?
  private var responseEncodedBytes: HTTPEncodedBytesHandler?
  private var responseEncoderContext: ChannelHandlerContext?
  /// 源站响应和本地错误响应已是字节，从收集器之前写出以避免重复编码。
  private var rawWriteContext: ChannelHandlerContext?

  // 接收完成与发送完成分开记录，完整请求后的客户端 FIN 必须等 end 写成后向下游传播。
  private var requestBytes = 0
  private var requestComplete = false
  private var requestSent = false

  // 一次选路固定目标与 Wire；启动完成前到达的响应先暂存为原始字节。
  private var wire: Wire?
  private var wireChannel: Channel?
  private var wireStarted = false
  private var earlyRemote: ByteBuffer

  // 两向 EOF 与响应提交分别追踪；源站首字节提交后不能再插入本地 HTTP 错误响应。
  private var proxyInputEnded = false
  private var remoteInputEnded = false
  private var remoteFullyClosed = false
  private var remoteOutputEnded = false
  private var wireInputFinished = false
  private var finishing = false
  private var responseStarted = false

  // 首个失败控制统一收尾；清理标记拦截迟到的建连和写入回调。
  private var firstError: Error?
  private var didCleanUp = false

  // 写入按 future 串联；字节数在实际完成后扣除，约束等待网络的内存占用。
  private var clientWrite: EventLoopFuture<Void>
  private var remoteWrite: EventLoopFuture<Void>
  private var clientWriteBytes = 0
  private var remoteWriteBytes = 0
  private static let bufferLimit = 64 * 1024

  /// 初始化本连接的有界缓冲和写队列；目标尚未解析，此时不创建下游资源。
  internal init(proxyChannel: Channel, core: MagentCore) {
    self.proxyChannel = proxyChannel
    self.core = core
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    requestBody = proxyChannel.allocator.buffer(capacity: 0)
    earlyRemote = proxyChannel.allocator.buffer(capacity: 0)
    clientWrite = proxyChannel.eventLoop.makeSucceededFuture(())
    remoteWrite = proxyChannel.eventLoop.makeSucceededFuture(())
  }

  // MARK: - 客户端输入与清理

  /// 头和完整 body 均通过后才能拨号；任何后续请求数据都拒绝，模型只构造一次。
  internal func upstream(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed, firstError == nil else { return }
    var input = unwrapInboundIn(data)
    guard input.readableBytes > 0 else { return }
    do {
      guard state == .request, !requestComplete else {
        throw MagentError.malformedRequest("HTTP forward supports one request only")
      }
      guard input.readableBytes <= Self.bufferLimit - requestBytes else {
        throw MagentError.malformedRequest("HTTP request exceeds 64 KiB")
      }
      requestBytes += input.readableBytes
      requestBuffer.writeBuffer(&input)
      requestContext = context
      if request == nil {
        guard let head = try parseRequestHead(&requestBuffer) else {
          context.read()
          return
        }
        if head.version == .http1_0 || head.version == .http1_1 { requestVersion = head.version }
        request = try HttpProtocol(head: head)
      }
      guard let request, case .forward(let target, let head, _) = request.request else {
        throw MagentError.malformedRequest("HTTP forward received a CONNECT request")
      }
      guard try consumeRequestBody(&requestBuffer) else {
        context.read()
        return
      }
      requestComplete = true
      // 建连/发送阶段继续观察额外请求与 FIN，不能等发完后才把 socket 余量当作新输入。
      context.read()
      let acceptedContext = context.loopBound
      let sent = openOutbound(target: target).flatMap {
        self.forwardRequest(.head(head))
      }.flatMap {
        self.forwardRequest(.body(.byteBuffer(self.requestBody)))
      }.flatMap {
        self.forwardRequest(.end(nil))
      }
      sent.whenSuccess {
        guard self.state != .closed, self.firstError == nil else { return }
        self.requestBody.clear()
        if self.remoteInputEnded {
          do { try self.finishRemoteInput() } catch { self.fail(error) }
        }
        if self.proxyInputEnded {
          self.proxyInputClosed(context: acceptedContext.value)
        } else {
          self.proxyChannel.read()
        }
      }
      sent.whenFailure { self.fail($0) }
    } catch {
      fail(error)
    }
  }

  /// 完整请求后 FIN 允许继续等待响应；请求 end 真正写成后才关闭下游输出。
  internal func proxyInputClosed(context: ChannelHandlerContext) {
    guard state != .closed, firstError == nil else { return }
    proxyInputEnded = true
    guard requestComplete else {
      fail(MagentError.malformedRequest("HTTP request is truncated"))
      return
    }
    if remoteFullyClosed {
      do { try finishRemoteInput() } catch { fail(error) }
      return
    }
    guard requestSent, !remoteOutputEnded else { return }
    remoteOutputEnded = true
    remoteWrite.flatMap { () -> EventLoopFuture<Void> in
      guard self.state != .closed, let channel = self.wireChannel else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      return channel.close(mode: .output)
    }.whenFailure { self.fail($0) }
  }

  /// 先置终态，再释放下游；accepted 的关闭和错误上报不属于这个清理入口。
  internal func closeConnection(error: Error?) {
    guard !didCleanUp else { return }
    state = .closed
    didCleanUp = true
    if firstError == nil { firstError = error }
    wireChannel?.close(promise: nil)
    wireChannel = nil
    wire = nil
    request = nil
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    requestBody = proxyChannel.allocator.buffer(capacity: 0)
    earlyRemote = proxyChannel.allocator.buffer(capacity: 0)
    requestParts?.head = nil
    requestParts?.body = nil
    requestParts?.trailers = nil
    requestParts?.failure = nil
    requestParts = nil
    requestEncodedBytes?.bytes = nil
    requestEncodedBytes?.failure = nil
    responseEncodedBytes?.bytes = nil
    responseEncodedBytes?.failure = nil
    requestEncodedBytes = nil
    responseEncodedBytes = nil
    requestEncoder = nil
    responseEncoder = nil
    requestContext = nil
    requestEncoderContext = nil
    responseEncoderContext = nil
    rawWriteContext = nil
  }

  // MARK: - 下游 Channel 回调

  /// 此 handler 只接收下游字节；客户端请求由 accepted owner 调用 upstream 交付。
  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed, firstError == nil else { return }
    do { try relayRemote(unwrapInboundIn(data)) } catch { fail(error) }
  }

  /// 输入半关闭先校验 Wire 尾部，响应排空以后才结束本次单请求连接。
  internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let event = event as? ChannelEvent, event == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }
    guard state != .closed, firstError == nil else { return }
    do { try finishRemoteInput() } catch { fail(error) }
  }

  /// 全关闭不能丢弃尚未写成的请求；无在途写时仍需检查并排空已接收响应。
  internal func channelInactive(context: ChannelHandlerContext) {
    defer { context.fireChannelInactive() }
    guard state != .closed, firstError == nil else { return }
    remoteFullyClosed = true
    guard remoteWriteBytes == 0 else {
      fail(MagentError.connectionClosed)
      return
    }
    do { try finishRemoteInput() } catch { fail(error) }
  }

  /// 保留原始下游错误，交统一响应与关闭路径处理。
  internal func errorCaught(context: ChannelHandlerContext, error: Error) {
    guard state != .closed else { return }
    fail(error)
  }

  // MARK: - 请求解析与出站发送

  /// 仅扫描新收到的头字节；头部完成后先验证原始 UTF-8，再交 NIO 保留重复字段。
  private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead? {
    let bytes = input.readableBytesView
    let start = max(0, headScanOffset - 3)
    for offset in start..<max(start, bytes.count - 3) {
      let index = bytes.index(bytes.startIndex, offsetBy: offset)
      if bytes[index] == 13, bytes[bytes.index(index, offsetBy: 1)] == 10,
        bytes[bytes.index(index, offsetBy: 2)] == 13,
        bytes[bytes.index(index, offsetBy: 3)] == 10
      {
        guard String(bytes: bytes.prefix(offset + 4), encoding: .utf8) != nil else {
          throw MagentError.malformedRequest("HTTP request head is not UTF-8")
        }
        guard let context = requestContext,
          let headBytes = input.readSlice(length: offset + 4)
        else { throw MagentError.connectionClosed }
        let parts = HTTPRequestPartsHandler()
        try context.pipeline.syncOperations.addHandlers(
          ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .fireError)), parts)
        requestParts = parts
        context.fireChannelRead(NIOAny(headBytes))
        if let failure = parts.failure { throw failure }
        guard let head = parts.head else {
          throw MagentError.malformedRequest("NIO did not produce a complete HTTP head")
        }
        return head
      }
    }
    headScanOffset = bytes.count
    return nil
  }

  /// 请求体长度仅采用模型结果；未收齐不得拨号，多余字节不得变成第二个请求。
  private func consumeRequestBody(_ input: inout ByteBuffer) throws -> Bool {
    guard let request, case .forward(_, _, let framing) = request.request else {
      throw MagentError.malformedRequest("HTTP forward request head is missing")
    }
    let expected: UInt64
    switch framing {
    case .none: expected = 0
    case .fixedLength(let count): expected = count
    }
    let headBytes = requestBytes - input.readableBytes - requestBody.readableBytes
    guard headBytes <= Self.bufferLimit,
      expected <= UInt64(Self.bufferLimit - headBytes),
      UInt64(requestBody.readableBytes) <= expected,
      UInt64(input.readableBytes) <= expected - UInt64(requestBody.readableBytes)
    else {
      throw MagentError.malformedRequest("HTTP body or trailing bytes exceed declared length")
    }
    guard let context = requestContext, let parts = requestParts else {
      throw MagentError.connectionClosed
    }
    if let body = input.readSlice(length: input.readableBytes), body.readableBytes > 0 {
      context.fireChannelRead(NIOAny(body))
    }
    if let failure = parts.failure { throw failure }
    if var body = parts.body {
      requestBody.writeBuffer(&body)
      parts.body = nil
    }
    guard UInt64(requestBody.readableBytes) == expected else { return false }
    guard parts.ended, parts.trailers?.isEmpty != false else {
      throw MagentError.malformedRequest("HTTP request end is missing or contains trailers")
    }
    return true
  }

  /// 建连、Wire.start 和启动写成构成出站屏障；就绪后立即允许响应，不等待请求发送完。
  private func openOutbound(target: NetworkAddress) -> EventLoopFuture<Void> {
    let loop = proxyChannel.eventLoop
    return loop.makeCompletedFuture {
      self.wire = try self.core.routeTCPWire(target)
    }.flatMap { () -> EventLoopFuture<Channel> in
      guard self.state != .closed, self.firstError == nil else {
        return loop.makeFailedFuture(MagentError.connectionClosed)
      }
      if let wire = self.wire {
        return self.core.createTCPClientChannel(
          eventLoop: loop, address: wire.getEndpoint(), timeout: wire.getTimeout(), handler: self)
      }
      return self.core.createTCPClientChannel(
        eventLoop: loop, address: target, timeout: self.core.defaultTimeout, handler: self)
    }.flatMap { channel -> EventLoopFuture<Void> in
      guard self.state != .closed, self.firstError == nil, self.proxyChannel.isActive else {
        channel.close(promise: nil)
        return loop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.wireChannel = channel
      return loop.makeCompletedFuture {
        let startup = try self.wire?.start(handshake: target)
        self.wireStarted = true
        var output = channel.allocator.buffer(capacity: startup?.count ?? 0)
        if let startup { output.writeBytes(startup) }
        return output
      }.flatMap { startup -> EventLoopFuture<Void> in
        guard startup.readableBytes <= 325 else {
          return loop.makeFailedFuture(
            MagentError.invalidOptions("TCP Wire startup exceeds supported capacity"))
        }
        // 本次启动操作拥有计时器；底层写成功、失败或关闭均取消它，不跨连接保留任务。
        let deadline = loop.scheduleTask(
          in: .milliseconds(self.wire?.getTimeout() ?? self.core.defaultTimeout)
        ) { [weak self = self] in
          self?.fail(MagentError.channelConnectionTimedOut)
        }
        let written = self.writeRemote(startup)
        written.whenComplete { _ in deadline.cancel() }
        // cleanup 关闭下游即取消；不依赖任意 outbound handler 一定兑现其写 promise。
        channel.closeFuture.whenComplete { _ in deadline.cancel() }
        return written
      }.flatMapThrowing {
        guard self.state != .closed, self.firstError == nil else {
          throw MagentError.connectionClosed
        }
        self.state = .forward
        let early = self.earlyRemote
        self.earlyRemote.clear()
        try self.relayRemote(early)
        if self.remoteInputEnded { try self.finishRemoteInput() }
      }
    }
  }

  /// 只发送完整请求的 head/body/end；NIO 编码和网络写完成是两个独立的完成边界。
  private func forwardRequest(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void> {
    let loop = proxyChannel.eventLoop
    return loop.makeCompletedFuture {
      guard self.state == .forward, self.firstError == nil, !self.requestSent else {
        throw MagentError.connectionClosed
      }
      if self.requestEncoder == nil {
        let collector = HTTPEncodedBytesHandler()
        var configuration = HTTPRequestEncoder.Configuration()
        configuration.automaticallySetFramingHeaders = false
        let encoder = HTTPRequestEncoder(configuration: configuration)
        try self.proxyChannel.pipeline.syncOperations.addHandlers(collector, encoder)
        self.requestEncoder = encoder
        self.requestEncodedBytes = collector
        self.requestEncoderContext = try self.proxyChannel.pipeline.syncOperations.context(
          handler: encoder)
        self.rawWriteContext = try self.proxyChannel.pipeline.syncOperations.context(
          handler: collector)
      }
      guard let encoder = self.requestEncoder, let context = self.requestEncoderContext,
        let collector = self.requestEncodedBytes
      else { throw MagentError.connectionClosed }
      encoder.write(context: context, data: NIOAny(part), promise: nil)
      if let failure = collector.failure { throw failure }
      var output = collector.bytes ?? self.proxyChannel.allocator.buffer(capacity: 0)
      collector.bytes = nil
      // 请求批次最大 64 KiB，前一 part 已写成；先预留四片的最坏编码输出。
      guard output.readableBytes <= Self.bufferLimit, self.remoteWriteBytes == 0 else {
        throw MagentError.invalidOptions("HTTP outbound transfer budget is exhausted")
      }
      if let wire = self.wire, output.readableBytes > 0 {
        var input = output
        output = self.proxyChannel.allocator.buffer(capacity: 4 * 16_452)
        while let bytes = input.readSlice(length: min(16 * 1024, input.readableBytes)),
          bytes.readableBytes > 0
        {
          let encoded = try wire.encodeOutbound(Data(bytes.readableBytesView), address: nil)
          guard encoded.count <= 16_452 else {
            throw MagentError.invalidOptions("TCP Wire exceeds supported encode capacity")
          }
          output.writeBytes(encoded)
        }
      }
      return output
    }.flatMap { self.writeRemote($0) }.flatMapThrowing {
      guard self.state != .closed, self.firstError == nil else {
        throw MagentError.connectionClosed
      }
      if case .end = part { self.requestSent = true }
    }
  }

  // MARK: - 响应转发与结束

  /// 响应只按 Wire 解码后透传；不解析源站状态、framing、字符集或 Upgrade。
  private func relayRemote(_ data: ByteBuffer) throws {
    guard state != .closed, firstError == nil else { return }
    guard data.readableBytes <= Self.bufferLimit - earlyRemote.readableBytes - clientWriteBytes
    else {
      throw MagentError.invalidOptions("HTTP response buffer is full")
    }
    guard wireStarted, state == .forward else {
      var data = data
      earlyRemote.writeBuffer(&data)
      return
    }
    // 16 KiB 输入可能释放历史残留帧，故按每片 32 KiB 返回值预留，不能只用本次输入大小。
    // 单批输入/副本/最坏聚合输出/临时结果和在途写合计受 512 KiB 方向预算约束。
    guard data.readableBytes <= Self.bufferLimit, clientWriteBytes == 0 else {
      throw MagentError.invalidOptions("HTTP inbound transfer budget is exhausted")
    }
    var output = data
    if let wire, data.readableBytes > 0 {
      var input = data
      output = proxyChannel.allocator.buffer(capacity: 128 * 1024)
      while let part = input.readSlice(length: min(16 * 1024, input.readableBytes)),
        part.readableBytes > 0
      {
        let decoded = try wire.decodeInbound(Data(part.readableBytesView)).data
        guard decoded.count <= 32 * 1024 else {
          throw MagentError.invalidOptions("TCP Wire exceeds supported decode capacity")
        }
        output.writeBytes(decoded)
      }
    }
    guard output.readableBytes > 0 else {
      if !remoteInputEnded { wireChannel?.read() }
      return
    }
    responseStarted = true
    writeClient(output).whenComplete { result in
      guard self.state != .closed, self.firstError == nil else { return }
      switch result {
      case .success:
        if !self.remoteInputEnded { self.wireChannel?.read() }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  /// 下游 EOF 只检查 Wire 完整性；排空已提交响应后结束唯一请求，不伪造 HTTP 完整性。
  private func finishRemoteInput() throws {
    guard state != .closed, firstError == nil else { return }
    remoteInputEnded = true
    guard wireStarted, state == .forward else { return }
    if !wireInputFinished {
      try wire?.finishInbound()
      wireInputFinished = true
    }
    // 源站可在请求发送期间结束响应；仍要等整个 head/body/end 链写成，不能只等当前 part。
    guard requestSent, !finishing else { return }
    finishing = true
    clientWrite.whenComplete { result in
      guard self.state != .closed, self.firstError == nil else { return }
      switch result {
      case .success: self.proxyChannel.close(promise: nil)
      case .failure(let error): self.fail(error)
      }
    }
  }

  // MARK: - 统一失败处理与有序写入

  /// 本地响应只允许在源站首字节提交前产生；所有失败保留同一个原始首因。
  private func fail(_ error: Error) {
    guard state != .closed, firstError == nil else { return }
    firstError = error
    state = .closed
    guard !responseStarted, proxyChannel.isActive else {
      proxyChannel.pipeline.fireErrorCaught(error)
      return
    }
    let status: HTTPResponseStatus
    switch error {
    case HttpProtocol.Failure.unsupportedVersion: status = .httpVersionNotSupported
    case HttpProtocol.Failure.unsupportedFeature: status = .notImplemented
    case HttpProtocol.Failure.unsupportedExpectation: status = .expectationFailed
    case HttpProtocol.Failure.invalidRequest, MagentError.malformedRequest,
      MagentError.invalidAddress, is HTTPParserError, is ByteToMessageDecoderError:
      status = .badRequest
    case ChannelError.connectTimeout, MagentError.channelConnectionTimedOut:
      status = .gatewayTimeout
    default: status = .badGateway
    }
    do {
      let collector = HTTPEncodedBytesHandler()
      var configuration = HTTPResponseEncoder.Configuration()
      configuration.automaticallySetFramingHeaders = false
      let encoder = HTTPResponseEncoder(configuration: configuration)
      try proxyChannel.pipeline.syncOperations.addHandlers(collector, encoder)
      let context = try proxyChannel.pipeline.syncOperations.context(handler: encoder)
      responseEncoder = encoder
      responseEncodedBytes = collector
      responseEncoderContext = context
      if rawWriteContext == nil {
        rawWriteContext = try proxyChannel.pipeline.syncOperations.context(handler: collector)
      }
      let response = HttpConnectConnection.localResponse(version: requestVersion, status: status)
      encoder.write(
        context: context, data: NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
      encoder.write(context: context, data: NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
      if let failure = collector.failure { throw failure }
      guard let output = collector.bytes else { throw MagentError.connectionClosed }
      collector.bytes = nil
      responseStarted = true
      writeClient(output).whenComplete { _ in
        guard !self.didCleanUp else { return }
        self.proxyChannel.pipeline.fireErrorCaught(error)
      }
    } catch {
      // 编码/错误响应写出失败不覆盖原始首因。
      if let firstError { proxyChannel.pipeline.fireErrorCaught(firstError) }
    }
  }

  /// Wire 启动和请求内容共用写序；实际写成后释放持有字节，不把数据无限排入 NIO。
  private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void> {
    guard state != .closed, firstError == nil, !remoteOutputEnded, let channel = wireChannel,
      data.readableBytes <= 128 * 1024 - remoteWriteBytes
    else {
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    guard data.readableBytes > 0 else { return remoteWrite }
    let count = data.readableBytes
    remoteWriteBytes += count
    remoteWrite = remoteWrite.flatMap { () -> EventLoopFuture<Void> in
      guard self.state != .closed, self.firstError == nil else {
        return channel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      return channel.writeAndFlush(data)
    }
    remoteWrite.whenComplete { _ in self.remoteWriteBytes -= count }
    return remoteWrite
  }

  /// 客户端写保持源站字节顺序；本地错误由 fail 的 responseStarted 屏障隔离。
  private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void> {
    guard !didCleanUp, data.readableBytes <= 128 * 1024 - clientWriteBytes else {
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    guard data.readableBytes > 0 else { return clientWrite }
    let count = data.readableBytes
    clientWriteBytes += count
    clientWrite = clientWrite.flatMap { () -> EventLoopFuture<Void> in
      guard !self.didCleanUp else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      if let context = self.rawWriteContext { return context.writeAndFlush(NIOAny(data)) }
      return self.proxyChannel.writeAndFlush(data)
    }
    clientWrite.whenComplete { _ in self.clientWriteBytes -= count }
    return clientWrite
  }
}
