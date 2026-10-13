//
//  HttpConnectConnection.swift
//  Magent
//
//  Created by MarlinL on 2026/8/27.
//

import Foundation
import NIOCore
import NIOHTTP1

// MARK: - HTTP 编解码适配器

/// 同一 EventLoop 上的 NIO 解码结果暂存；协议语义和失败处理仍由 Connection 决定。
/// CONNECT 和 Forward 共用此适配器，每次请求各自创建实例，不共享可变状态。
internal final class HTTPRequestPartsHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart

  // Connection 在同步解码返回后读取这些结果，并负责消耗或清理 body。
  var head: HTTPRequestHead?
  var body: ByteBuffer?
  var ended = false
  var trailers: HTTPHeaders?
  /// 保留首个解析失败，避免后续报文事件掩盖原始原因。
  var failure: Error?

  /// 只收集有序的单请求报文事件；错误暂存后由 Connection 的统一失败入口处理。
  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard failure == nil else { return }
    switch unwrapInboundIn(data) {
    case .head(let head):
      guard self.head == nil, !ended else {
        failure = MagentError.malformedRequest("HTTP request head is duplicated")
        return
      }
      self.head = head
    case .body(var bytes):
      guard head != nil, !ended,
        bytes.readableBytes <= 64 * 1024 - (body?.readableBytes ?? 0)
      else {
        failure = MagentError.malformedRequest("HTTP request body exceeds its boundary")
        return
      }
      if body == nil { body = context.channel.allocator.buffer(capacity: bytes.readableBytes) }
      body?.writeBuffer(&bytes)
    case .end(let trailers):
      guard head != nil, !ended else {
        failure = MagentError.malformedRequest("HTTP request end is out of order")
        return
      }
      ended = true
      self.trailers = trailers
    }
  }

  /// NIO 解码错误不在适配器内关闭 Channel，由持有请求状态的 Connection 决定响应。
  internal func errorCaught(context: ChannelHandlerContext, error: Error) {
    if failure == nil { failure = error }
  }
}

/// 捕获真实 NIO 编码结果；这里完成的 promise 只代表编码，不能代替网络写入完成。
internal final class HTTPEncodedBytesHandler: ChannelOutboundHandler, @unchecked Sendable {
  typealias OutboundIn = IOData

  /// 每次编码调用的输出由 Connection 取走，再纳入真实网络写队列。
  var bytes: ByteBuffer?
  var failure: Error?

  /// 有界收集编码字节并完成编码 promise；不透传到 socket，避免绕过 Connection 的写序。
  internal func write(
    context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
  ) {
    if let failure {
      promise?.fail(failure)
      return
    }
    switch unwrapOutboundIn(data) {
    case .byteBuffer(var output):
      guard output.readableBytes <= 64 * 1024 - (bytes?.readableBytes ?? 0) else {
        let error = MagentError.invalidOptions("HTTP encoded output exceeds buffer limit")
        failure = error
        promise?.fail(error)
        return
      }
      if bytes == nil { bytes = context.channel.allocator.buffer(capacity: output.readableBytes) }
      bytes?.writeBuffer(&output)
      promise?.succeed(())
    case .fileRegion:
      let error = MagentError.invalidOptions("HTTP codec accepts ByteBuffer bodies only")
      failure = error
      promise?.fail(error)
    }
  }
}

// MARK: - CONNECT 连接

/// 一个 CONNECT 请求及其固定目标隧道；所有状态均由 accepted EventLoop 串行持有。
/// accepted 的最终清理由 MagentTCPConnection 负责，本类型只拥有下游和协议缓冲。
internal final class HttpConnectConnection: ChannelInboundHandler, ProxyConnection,
  @unchecked Sendable
{
  typealias InboundIn = ByteBuffer

  /// 200 完整写成是进入隧道的唯一条件；closed 是不可恢复的终态。
  private enum State {
    case handshaking
    case forwarding
    case closed
  }

  // accepted Channel 由 MagentTCPConnection 持有；这里只借用它回复与观察客户端事件。
  private let proxyChannel: Channel
  private let core: MagentCore
  private var state: State = .handshaking

  // 增量请求与临时 NIO 编解码上下文只在本连接使用，清理时一并释放。
  private var requestBuffer: ByteBuffer
  private var request: HttpProtocol?
  private var requestVersion: HTTPVersion = .http1_1
  private var headScanOffset = 0
  private var requestContext: ChannelHandlerContext?
  private var requestParts: HTTPRequestPartsHandler?
  private var responseEncoder: HTTPResponseEncoder?
  private var responseBytes: HTTPEncodedBytesHandler?
  private var responseContext: ChannelHandlerContext?
  /// 已编码响应和隧道字节从收集器之前写出，避免再次进入 HTTP 编码器。
  private var rawWriteContext: ChannelHandlerContext?

  // 一次路由决定 Wire 和下游；earlyRemote 在启动前存原始字节，在启动后存解码结果。
  private var wire: Wire?
  private var wireChannel: Channel?
  private var wireStarted = false
  private var earlyRemote: ByteBuffer
  private var replyCommitted = false

  // 输入 EOF、输出关闭中和输出关闭完成分别记录，保证在途写入先于半关闭完成。
  private var proxyInputEnded = false
  private var remoteInputEnded = false
  private var remoteFullyClosed = false
  private var wireInputFinished = false
  private var proxyOutputClosing = false
  private var remoteOutputClosing = false
  private var proxyOutputEnded = false
  private var remoteOutputEnded = false

  // 首因与幂等清理独立于协议状态，防止错误响应及迟到回调重复收尾。
  private var firstError: Error?
  private var didCleanUp = false

  // 两向 future 串联写序；计数覆盖尚未完成的写入，用于限制缓冲和恢复手动读取。
  private var clientWrite: EventLoopFuture<Void>
  private var remoteWrite: EventLoopFuture<Void>
  private var clientWriteBytes = 0
  private var remoteWriteBytes = 0
  private static let bufferLimit = 64 * 1024

  /// 仅建立 accepted EventLoop 上的连接状态；解析目标以后才创建下游 Channel。
  internal init(proxyChannel: Channel, core: MagentCore) {
    self.proxyChannel = proxyChannel
    self.core = core
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    earlyRemote = proxyChannel.allocator.buffer(capacity: 0)
    clientWrite = proxyChannel.eventLoop.makeSucceededFuture(())
    remoteWrite = proxyChannel.eventLoop.makeSucceededFuture(())
  }

  // MARK: - 客户端输入与清理

  /// 完整请求后到完整 200 之前不接受任何客户端业务；目标只从一次模型构造取得。
  internal func upstream(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed, firstError == nil else { return }
    var input = unwrapInboundIn(data)
    guard input.readableBytes > 0 else { return }
    do {
      switch state {
      case .handshaking:
        guard request == nil else {
          throw MagentError.malformedRequest("CONNECT data arrived before success")
        }
        guard input.readableBytes <= Self.bufferLimit - requestBuffer.readableBytes else {
          throw MagentError.malformedRequest("CONNECT request exceeds 64 KiB")
        }
        requestBuffer.writeBuffer(&input)
        requestContext = context
        guard let head = try parseRequestHead(&requestBuffer) else {
          context.read()
          return
        }
        if head.version == .http1_0 || head.version == .http1_1 {
          requestVersion = head.version
        }
        let model = try HttpProtocol(head: head)
        guard case .connect(let target, _) = model.request,
          requestBuffer.readableBytes == 0,
          requestParts?.ended == true,
          (requestParts?.body?.readableBytes ?? 0) == 0,
          requestParts?.trailers?.isEmpty != false
        else {
          throw MagentError.malformedRequest("CONNECT request contains unexpected data")
        }
        request = model
        // 等待下游和 200 时继续观察提前业务与 FIN；提前业务不能在回复后才被当作隧道载荷。
        context.read()
        let acceptedContext = context.loopBound
        let established = openTunnel(target: target).flatMap {
          self.writeSuccess()
        }
        established.whenSuccess {
          guard self.state == .forwarding, self.firstError == nil else { return }
          if self.proxyInputEnded {
            self.proxyInputClosed(context: acceptedContext.value)
          } else {
            self.proxyChannel.read()
          }
        }
        established.whenFailure { self.fail($0) }
      case .forwarding:
        try relayClient(input)
      case .closed:
        break
      }
    } catch {
      fail(error)
    }
  }

  /// 请求结束后的 FIN 等待启动和 200；已排队业务写成后才传播输出半关闭。
  internal func proxyInputClosed(context: ChannelHandlerContext) {
    guard state != .closed, firstError == nil else { return }
    proxyInputEnded = true
    guard request != nil else {
      fail(MagentError.malformedRequest("CONNECT request is truncated"))
      return
    }
    if remoteFullyClosed {
      do { try finishRemoteInput() } catch { fail(error) }
      return
    }
    guard state == .forwarding, !remoteOutputClosing else { return }
    remoteOutputClosing = true
    remoteWrite.flatMap { () -> EventLoopFuture<Void> in
      guard self.state != .closed, let channel = self.wireChannel else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      return channel.close(mode: .output)
    }.whenComplete { result in
      guard self.state != .closed else { return }
      switch result {
      case .success:
        self.remoteOutputEnded = true
        if self.proxyOutputEnded { self.proxyChannel.close(promise: nil) }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  /// 只释放本连接拥有的下游；先置终态，迟到建连/写回调不得恢复状态。
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
    earlyRemote = proxyChannel.allocator.buffer(capacity: 0)
    requestParts?.head = nil
    requestParts?.body = nil
    requestParts?.trailers = nil
    requestParts?.failure = nil
    requestParts = nil
    responseBytes?.bytes = nil
    responseBytes?.failure = nil
    responseBytes = nil
    responseEncoder = nil
    requestContext = nil
    responseContext = nil
    rawWriteContext = nil
  }

  // MARK: - 下游 Channel 回调

  /// 此 handler 安装在下游；accepted 的输入由 owner 经 upstream 传入。
  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed, firstError == nil else { return }
    do { try relayRemote(unwrapInboundIn(data)) } catch { fail(error) }
  }

  /// 下游输入半关闭仍允许反向发送，先执行 Wire EOF 校验再排空客户端写入。
  internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let event = event as? ChannelEvent, event == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }
    guard state != .closed, firstError == nil else { return }
    do { try finishRemoteInput() } catch { fail(error) }
  }

  /// 全关闭使在途输出不可继续；无在途写时仍需校验并排空已读入的反向字节。
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

  /// 原始下游错误交统一失败入口，已关闭连接不再触发递归清理。
  internal func errorCaught(context: ChannelHandlerContext, error: Error) {
    guard state != .closed else { return }
    fail(error)
  }

  // MARK: - 请求解析与隧道启动

  /// 先定位有界原始头并严格验证 UTF-8；不能让 NIO 的 String 转换替换非法字节。
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
          throw MagentError.malformedRequest("CONNECT head is not UTF-8")
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

  /// 一次路由固定 Wire 和拨号端点；迟到 Channel 只关闭自身，不继续启动。
  private func openTunnel(target: NetworkAddress) -> EventLoopFuture<Void> {
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
        // 先排空 start 前的原始输入，之后 earlyRemote 只保存已经解码的业务。
        let early = self.earlyRemote
        self.earlyRemote = self.proxyChannel.allocator.buffer(capacity: 0)
        try self.relayRemote(early)
        // 下游保持暂停；即使源站已发数据或 FIN，也等完整 200 写成后才发首个 read。
        if self.remoteInputEnded { try self.finishRemoteInput() }
        if let startup {
          var output = channel.allocator.buffer(capacity: startup.count)
          output.writeBytes(startup)
          return output
        }
        return channel.allocator.buffer(capacity: 0)
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
        if self.remoteInputEnded { try self.finishRemoteInput() }
      }
    }
  }

  /// 200 完整写成才进入转发；早到业务已解码，不再通过 Wire 重复解码。
  private func writeSuccess() -> EventLoopFuture<Void> {
    let loop = proxyChannel.eventLoop
    return loop.makeCompletedFuture {
      guard self.state != .closed, self.firstError == nil, !self.replyCommitted else {
        throw MagentError.connectionClosed
      }
      let collector = HTTPEncodedBytesHandler()
      var configuration = HTTPResponseEncoder.Configuration()
      configuration.automaticallySetFramingHeaders = false
      let encoder = HTTPResponseEncoder(configuration: configuration)
      try self.proxyChannel.pipeline.syncOperations.addHandlers(collector, encoder)
      let context = try self.proxyChannel.pipeline.syncOperations.context(handler: encoder)
      self.responseEncoder = encoder
      self.responseBytes = collector
      self.responseContext = context
      self.rawWriteContext = try self.proxyChannel.pipeline.syncOperations.context(
        handler: collector)
      let response = Self.localResponse(version: self.requestVersion, status: .ok)
      encoder.write(
        context: context, data: NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
      encoder.write(context: context, data: NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
      if let failure = collector.failure { throw failure }
      guard let output = collector.bytes, output.readableBytes > 0 else {
        throw MagentError.connectionClosed
      }
      collector.bytes = nil
      self.replyCommitted = true
      return output
    }.flatMap { self.writeClient($0) }.flatMap {
      guard self.state != .closed, self.firstError == nil else {
        return loop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.state = .forwarding
      let early = self.earlyRemote
      self.earlyRemote.clear()
      return self.writeClient(early)
    }.flatMapThrowing {
      guard self.state != .closed, self.firstError == nil else {
        throw MagentError.connectionClosed
      }
      if self.remoteInputEnded { try self.finishRemoteInput() } else { self.wireChannel?.read() }
    }
  }

  // MARK: - 双向转发与半关闭

  /// 有界串行客户端写队列；每批写成后才释放计数，错误交调用边界处理。
  private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void> {
    guard !didCleanUp, !proxyOutputClosing,
      data.readableBytes <= 128 * 1024 - clientWriteBytes
    else {
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

  /// 启动字节和编码业务共用同一写序；空启动表示无需网络写入。
  private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void> {
    guard state != .closed, firstError == nil, !remoteOutputClosing, let channel = wireChannel,
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

  /// 客户端业务只编码一次；下游写成后再继续读取，以网络写完成约束输入速度。
  private func relayClient(_ data: ByteBuffer) throws {
    guard state == .forwarding, data.readableBytes > 0 else { return }
    // 单批最多 64 KiB；手动读取保证前批写成后才进入这里。预留完整最坏输出及临时副本。
    guard data.readableBytes <= Self.bufferLimit, remoteWriteBytes == 0 else {
      throw MagentError.invalidOptions("CONNECT outbound buffer is full")
    }
    var output = data
    if let wire {
      var input = data
      output = proxyChannel.allocator.buffer(capacity: 4 * 16_452)
      while let part = input.readSlice(length: min(16 * 1024, input.readableBytes)),
        part.readableBytes > 0
      {
        let encoded = try wire.encodeOutbound(Data(part.readableBytesView), address: nil)
        guard encoded.count <= 16_452 else {
          throw MagentError.invalidOptions("TCP Wire exceeds supported encode capacity")
        }
        output.writeBytes(encoded)
      }
    }
    writeRemote(output).whenComplete { result in
      guard self.state != .closed, self.firstError == nil else { return }
      switch result {
      case .success:
        if !self.proxyInputEnded { self.proxyChannel.read() }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  /// 初始化前存原始字节；之后仅解码一次，200 之前保存业务结果。
  private func relayRemote(_ data: ByteBuffer) throws {
    guard state != .closed, firstError == nil else { return }
    guard data.readableBytes <= Self.bufferLimit - earlyRemote.readableBytes - clientWriteBytes
    else {
      throw MagentError.invalidOptions("CONNECT inbound buffer is full")
    }
    guard wireStarted else {
      var data = data
      earlyRemote.writeBuffer(&data)
      return
    }
    // 16 KiB 输入可能释放历史残留帧，故按每片 32 KiB 返回值预留，不能只用本次输入大小。
    // 单批输入/副本/最坏聚合输出/临时结果和在途写合计受 512 KiB 方向预算约束。
    guard data.readableBytes <= Self.bufferLimit,
      state != .forwarding || clientWriteBytes == 0
    else {
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
    guard state == .forwarding else {
      guard output.readableBytes <= Self.bufferLimit - earlyRemote.readableBytes else {
        throw MagentError.invalidOptions("CONNECT early response exceeds buffer limit")
      }
      earlyRemote.writeBuffer(&output)
      return
    }
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

  /// 零业务 FIN 同样等待启动与 200；Wire EOF 不覆盖先前失败，且每条流只检查一次。
  private func finishRemoteInput() throws {
    guard state != .closed, firstError == nil else { return }
    remoteInputEnded = true
    guard wireStarted else { return }
    if !wireInputFinished {
      try wire?.finishInbound()
      wireInputFinished = true
    }
    guard state == .forwarding, !proxyOutputClosing else { return }
    proxyOutputClosing = true
    clientWrite.flatMap {
      // accepted 两向都结束会触发 NIO 全关闭；先排空最后一批上行，不能提前清掉下游。
      self.proxyInputEnded
        ? self.remoteWrite : self.proxyChannel.eventLoop.makeSucceededFuture(())
    }.flatMap { () -> EventLoopFuture<Void> in
      guard self.state != .closed else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      return self.proxyChannel.close(mode: .output)
    }.whenComplete { result in
      guard self.state != .closed else { return }
      switch result {
      case .success:
        self.proxyOutputEnded = true
        if self.remoteOutputEnded || self.remoteFullyClosed {
          self.proxyChannel.close(promise: nil)
        }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  // MARK: - 本地响应与统一失败处理

  /// 只保存首因；错误响应失败不得覆盖原错，最终交 accepted owner 收尾。
  private func fail(_ error: Error) {
    guard state != .closed, firstError == nil else { return }
    firstError = error
    state = .closed
    guard !replyCommitted, proxyChannel.isActive, !proxyOutputEnded else {
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
      if responseEncoder == nil {
        let collector = HTTPEncodedBytesHandler()
        var configuration = HTTPResponseEncoder.Configuration()
        configuration.automaticallySetFramingHeaders = false
        let encoder = HTTPResponseEncoder(configuration: configuration)
        try proxyChannel.pipeline.syncOperations.addHandlers(collector, encoder)
        responseEncoder = encoder
        responseBytes = collector
        responseContext = try proxyChannel.pipeline.syncOperations.context(handler: encoder)
        rawWriteContext = try proxyChannel.pipeline.syncOperations.context(handler: collector)
      }
      guard let encoder = responseEncoder, let context = responseContext,
        let collector = responseBytes
      else { throw MagentError.connectionClosed }
      let response = Self.localResponse(version: requestVersion, status: status)
      encoder.write(
        context: context, data: NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
      encoder.write(context: context, data: NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
      if let failure = collector.failure { throw failure }
      guard let output = collector.bytes else { throw MagentError.connectionClosed }
      collector.bytes = nil
      replyCommitted = true
      writeClient(output).whenComplete { _ in
        guard !self.didCleanUp else { return }
        self.proxyChannel.pipeline.fireErrorCaught(error)
      }
    } catch {
      // 响应自身失败时保留 firstError，不用编码/写出失败覆盖首因。
      if let firstError { proxyChannel.pipeline.fireErrorCaught(firstError) }
    }
  }

  /// 唯一共享的无状态响应构造；200 不携带普通响应定界或关闭字段。
  internal static func localResponse(version: HTTPVersion, status: HTTPResponseStatus)
    -> HTTPResponseHead
  {
    let version = version == .http1_0 ? HTTPVersion.http1_0 : .http1_1
    var headers = HTTPHeaders()
    if status != .ok {
      headers.add(name: "Content-Length", value: "0")
      headers.add(name: "Connection", value: "close")
    }
    return HTTPResponseHead(version: version, status: status, headers: headers)
  }
}
