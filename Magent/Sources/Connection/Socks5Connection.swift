//
//  Socks5Connection.swift
//  Magent
//
//  Created by MarlinL on 2026/8/27.
//

import DNSClient
import Foundation
import NIOCore

/// 一个 accepted EventLoop 上的 SOCKS5 会话。accepted Channel 由 MagentTCPConnection 关闭；
/// 本类型拥有下游 TCP、UDP 关联的两个 Channel、DNS client 和对应的在途操作。
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  /// 握手回复写成才进入下一阶段；TCP 转发与 UDP 关联互斥，closed 后不再创建资源。
  private enum State {
    case negotiating
    case requesting
    case tcpRelay
    case udpAssociated
    case closed
  }

  /// 只描述当前阶段已解析的消息，不保存网络资源或替代会话状态。
  private enum HandshakeMessage {
    case greeting(methods: [UInt8])
    case request(command: UInt8, address: NetworkAddress)
    case unsupportedCommand(UInt8)
  }

  private let proxyChannel: Channel
  private let core: MagentCore
  private let dnsAddress: SocketAddress?
  private var state: State = .negotiating
  private var requestBuffer: ByteBuffer
  /// 两次握手各有独立回复权；提交后即占用，写失败也不能追加另一条回复。
  private var greetingReplyStarted = false
  private var commandReplyStarted = false
  private var acceptedCommand: UInt8?
  private var firstError: Error?
  private var errorReported = false
  /// fail 会先封闭状态；独立清理标记确保 accepted owner 随后仍能实际释放资源。
  private var didCleanUp = false

  /// 选中的 TCP Wire 独占本连接；初始化允许解码，启动写成与本地回复共同允许业务转发。
  private var wireChannel: Channel?
  private var wire: Wire?
  private var wireInitialized = false
  private var startupComplete = false
  /// 输入 EOF、输出半关闭和 Channel 全关闭分开记录，避免尚可写的方向被提前终止。
  private var proxyInputEnded = false
  private var remoteInputEnded = false
  private var remoteInputChecked = false
  private var remoteChannelInactive = false
  private var proxyOutputEnded = false
  private var wireOutputEnded = false
  /// 计数包含已提交但尚未完成的写入；归零才续读源 Channel 或传播对应 FIN。
  private var pendingClientWrites = 0
  private var pendingRemoteWrites = 0
  private var pendingClientBytes = 0
  private var pendingRemoteBytes = 0
  /// Wire 初始化前保存原始输入；初始化后保存已解码业务，直到本地成功回复写成。
  private var earlyRemoteInput: ByteBuffer
  private var pendingRemoteInput: ByteBuffer
  private static let maximumBufferedBytes = 256 * 1024

  /// 父对象强持有唯一 UDP 资源 owner；它弱持有父对象，随控制连接一起结束。
  private var udpConnection: Socks5UDPConnection?

  /// 构造只保存当前 runtime 依赖，不创建网络资源。
  internal init(proxyChannel: Channel, core: MagentCore, dnsAddress: SocketAddress?) {
    self.proxyChannel = proxyChannel
    self.core = core
    self.dnsAddress = dnsAddress
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    earlyRemoteInput = proxyChannel.allocator.buffer(capacity: 0)
    pendingRemoteInput = proxyChannel.allocator.buffer(capacity: 0)
  }

  // MARK: - Accepted connection entry points

  /// 严格区分当前握手消息、成功回复后的 TCP 业务和只用于保活的 UDP 控制连接。
  internal func upstream(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed else { return }
    var input = unwrapInboundIn(data)
    do {
      switch state {
      case .negotiating, .requesting:
        guard !greetingReplyStarted || state == .requesting,
          acceptedCommand == nil, !commandReplyStarted
        else {
          if input.readableBytes > 0 {
            throw MagentError.malformedRequest("SOCKS5 bytes arrived before the reply completed")
          }
          return
        }
        let maximum = state == .negotiating ? 257 : 262
        guard input.readableBytes <= maximum - requestBuffer.readableBytes else {
          throw MagentError.malformedRequest("SOCKS5 handshake exceeds its message limit")
        }
        requestBuffer.writeBuffer(&input)
        try consumeHandshake()
      case .tcpRelay:
        try relayClient(input)
      case .udpAssociated:
        guard input.readableBytes == 0 else {
          throw MagentError.malformedRequest("SOCKS5 UDP control connection cannot carry data")
        }
        if !proxyInputEnded { context.read() }
      case .closed:
        break
      }
    } catch {
      fail(error)
    }
  }

  /// 完整 CONNECT 后的 FIN 可等待两个成功屏障；其他未完成握手或 UDP 控制 EOF 结束会话。
  internal func proxyInputClosed(context: ChannelHandlerContext) {
    guard state != .closed, !proxyInputEnded else { return }
    proxyInputEnded = true
    switch state {
    case .requesting where acceptedCommand == 0x01:
      break
    case .tcpRelay:
      // relayClient 的写完成回调再次进入空输入路径，确保在途业务先写完。
      do { try relayClient(proxyChannel.allocator.buffer(capacity: 0)) } catch { fail(error) }
    case .udpAssociated:
      state = .closed
      context.close(promise: nil)
    case .negotiating, .requesting:
      fail(MagentError.connectionClosed)
    case .closed:
      break
    }
  }

  /// 先封闭状态再释放下游资源；失败边界已经置 closed 也必须执行一次真实清理。
  internal func closeConnection(error: Error?) {
    guard !didCleanUp else { return }
    didCleanUp = true
    state = .closed
    if firstError == nil { firstError = error }
    wireChannel?.close(promise: nil)
    udpConnection?.closeConnection()
    wireChannel = nil
    wire = nil
    udpConnection = nil
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    earlyRemoteInput = proxyChannel.allocator.buffer(capacity: 0)
    pendingRemoteInput = proxyChannel.allocator.buffer(capacity: 0)
    // NIO connect/bind/DNS futures 没有单独取消句柄；所有完成点检查 closed 并释放迟到资源。
  }

  // MARK: - Downstream TCP callbacks

  /// 下游数据统一经过 relayRemote，由成功回复屏障决定暂存还是交付。
  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed else { return }
    do { try relayRemote(unwrapInboundIn(data)) } catch { fail(error) }
  }

  /// 正常输入 EOF 检查 Wire 尾部并排空反向写；其他事件不改变协议状态。
  internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let event = event as? ChannelEvent, event == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }
    guard state != .closed else { return }
    remoteInputEnded = true
    do { try finishRemoteInput() } catch { fail(error) }
    context.fireUserInboundEventTriggered(event)
  }

  /// 全关闭不能继续承接上行写；补做 EOF 检查，并保留已接收业务的排空机会。
  internal func channelInactive(context: ChannelHandlerContext) {
    guard state != .closed else {
      context.fireChannelInactive()
      return
    }
    remoteChannelInactive = true
    remoteInputEnded = true
    do { try finishRemoteInput() } catch { fail(error) }
    context.fireChannelInactive()
  }

  /// 网络错误直接交统一失败边界，避免通过正常 EOF 检查覆盖首因。
  internal func errorCaught(context: ChannelHandlerContext, error: Error) {
    guard state != .closed else { return }
    fail(error)
  }

  // MARK: - Handshake and downstream setup

  /// 固定长度字段增量读取；未齐不消费，不把下一阶段或业务字节当成本消息的一部分。
  private func parseHandshake(_ input: ByteBuffer)
    throws -> (message: HandshakeMessage?, consumed: Int, minimumAdditional: Int)
  {
    let start = input.readerIndex
    let count = input.readableBytes
    guard count >= 1 else { return (nil, 0, 1) }
    guard input.getInteger(at: start, as: UInt8.self) == 0x05 else {
      throw MagentError.malformedRequest("invalid SOCKS5 version")
    }
    guard count >= 2 else { return (nil, 0, 2 - count) }
    let second = input.getInteger(at: start + 1, as: UInt8.self)!
    if state == .negotiating {
      let length = 2 + Int(second)
      guard count >= length else { return (nil, 0, length - count) }
      return (.greeting(methods: input.getBytes(at: start + 2, length: Int(second))!), length, 0)
    }
    guard state == .requesting else { throw MagentError.connectionClosed }
    // 不支持的命令无需等待无用地址体；已到达的 RSV 仍须校验。
    if count >= 3, input.getInteger(at: start + 2, as: UInt8.self) != 0 {
      throw MagentError.malformedRequest("invalid SOCKS5 reserved byte")
    }
    guard second == 0x01 || second == 0x03 else {
      return (.unsupportedCommand(second), count, 0)
    }
    guard count >= 4 else { return (nil, 0, 4 - count) }
    let atyp = input.getInteger(at: start + 3, as: UInt8.self)!
    let addressStart: Int
    let addressLength: Int
    switch atyp {
    case 0x01:
      addressStart = start + 4
      addressLength = 4
    case 0x04:
      addressStart = start + 4
      addressLength = 16
    case 0x03:
      // ASSOCIATE 必须保留原始 ATYP 的限制；数字外观的 domain hint 也拒绝。
      guard second != 0x03 else {
        throw MagentError.invalidAddress("SOCKS5 ASSOCIATE requires a numeric source hint")
      }
      guard count >= 5 else { return (nil, 0, 5 - count) }
      addressLength = Int(input.getInteger(at: start + 4, as: UInt8.self)!)
      guard addressLength > 0 else { throw MagentError.invalidAddress("empty SOCKS5 domain") }
      addressStart = start + 5
    default:
      throw MagentError.invalidAddress("unsupported SOCKS5 address type")
    }
    let length = addressStart - start + addressLength + 2
    guard count >= length else { return (nil, 0, length - count) }
    let port = input.getInteger(at: addressStart + addressLength, as: UInt16.self)!
    guard second == 0x03 || port > 0 else {
      throw MagentError.invalidAddress("SOCKS5 target port must be nonzero")
    }
    let host: String
    if atyp == 0x03 {
      let bytes = input.getBytes(at: addressStart, length: addressLength)!
      guard let name = String(bytes: bytes, encoding: .ascii), !name.contains(":") else {
        throw MagentError.invalidAddress("SOCKS5 domain must be ASCII and cannot contain IPv6 text")
      }
      host = name
    } else {
      let packed = input.getSlice(at: addressStart, length: addressLength)!
      let socket = try SocketAddress(packedIPAddress: packed, port: Int(port))
      guard let numericHost = socket.ipAddress else {
        throw MagentError.invalidAddress("SOCKS5 address must be numeric")
      }
      host = numericHost
    }
    return (
      .request(command: second, address: try NetworkAddress(host: host, port: port)), length, 0
    )
  }

  /// 一个完成的消息只推进一个阶段；回复写成前暂停 accepted 读取，已送达的提前数据仍失败。
  private func consumeHandshake() throws {
    let parsed = try parseHandshake(requestBuffer)
    guard let message = parsed.message else {
      if !proxyInputEnded { proxyChannel.read() }
      return
    }
    guard parsed.consumed == requestBuffer.readableBytes else {
      throw MagentError.malformedRequest("SOCKS5 bytes follow a complete handshake message")
    }
    requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    switch message {
    case .greeting(let methods):
      guard methods.contains(0x00) else {
        throw MagentError.invalidOptions("SOCKS5 no-auth method is unavailable")
      }
      let deadline = proxyChannel.eventLoop.scheduleTask(in: .milliseconds(core.defaultTimeout)) {
        self.fail(MagentError.channelConnectionTimedOut)
      }
      proxyChannel.closeFuture.whenComplete { _ in deadline.cancel() }
      writeReply(ByteBuffer(bytes: [0x05, 0x00])).whenComplete { result in
        deadline.cancel()
        guard self.state != .closed else { return }
        switch result {
        case .success:
          guard !self.proxyInputEnded else {
            self.fail(MagentError.connectionClosed)
            return
          }
          self.state = .requesting
          self.proxyChannel.read()
        case .failure(let error): self.fail(error)
        }
      }
    case .unsupportedCommand(let command):
      acceptedCommand = command
      throw MagentError.invalidOptions("unsupported SOCKS5 command")
    case .request(let command, let address):
      acceptedCommand = command
      let operation: EventLoopFuture<SocketAddress?>
      if command == 0x01 {
        operation = openTCP(target: address).map { self.wireChannel?.localAddress }
      } else {
        guard case .ip(let hint) = address.address else {
          throw MagentError.invalidAddress("SOCKS5 ASSOCIATE requires a numeric source hint")
        }
        operation = openAssociation(hint: hint).map { Optional($0) }
      }
      // UDP 装配使用 Core 期限；TCP 的选定 Wire 期限由 openTCP 独立负责。
      let deadline: Scheduled<Void>? =
        command == 0x03
        ? proxyChannel.eventLoop.scheduleTask(in: .milliseconds(core.defaultTimeout)) {
          self.fail(MagentError.channelConnectionTimedOut)
        } : nil
      proxyChannel.closeFuture.whenComplete { _ in deadline?.cancel() }
      operation.flatMap { bound -> EventLoopFuture<Void> in
        deadline?.cancel()
        guard self.state != .closed else {
          return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        // BND 是实际端点；缺失时仅 CONNECT 可使用协议规定的零地址。
        var reply = ByteBuffer(bytes: [0x05, 0x00, 0x00])
        if let bound, let port = bound.port, let encodedPort = UInt16(exactly: port) {
          switch bound {
          case .v4(let address):
            reply.writeInteger(UInt8(0x01))
            _ = withUnsafeBytes(of: address.address.sin_addr) { reply.writeBytes($0) }
          case .v6(let address):
            reply.writeInteger(UInt8(0x04))
            _ = withUnsafeBytes(of: address.address.sin6_addr) { reply.writeBytes($0) }
          case .unixDomainSocket:
            return self.proxyChannel.eventLoop.makeFailedFuture(
              MagentError.invalidAddress("SOCKS5 bound address must be numeric"))
          }
          reply.writeInteger(encodedPort)
        } else {
          reply.writeBytes([UInt8(0x01), 0, 0, 0, 0, 0, 0])
        }
        let written = self.writeReply(reply)
        let replyDeadline = self.proxyChannel.eventLoop.scheduleTask(
          in: .milliseconds(self.wire?.getTimeout() ?? self.core.defaultTimeout)
        ) { self.fail(MagentError.channelConnectionTimedOut) }
        written.whenComplete { _ in replyDeadline.cancel() }
        self.proxyChannel.closeFuture.whenComplete { _ in replyDeadline.cancel() }
        return written
      }.whenComplete { result in
        deadline?.cancel()
        guard self.state != .closed else { return }
        switch result {
        case .success:
          if command == 0x01 {
            self.state = .tcpRelay
            do {
              try self.relayRemote(self.proxyChannel.allocator.buffer(capacity: 0))
              try self.relayClient(self.proxyChannel.allocator.buffer(capacity: 0))
              try self.finishRemoteInput()
            } catch { self.fail(error) }
          } else {
            self.state = .udpAssociated
            self.udpConnection?.activate()
            self.proxyChannel.read()
          }
        case .failure(let error): self.fail(error)
        }
      }
    }
    // 当前完整消息的回复或装配 Future 持有推进权；只有成功完成回调恢复读取。
  }

  /// 一次选路所得 Wire 同时决定拨号端点、超时和流状态；启动输出写成才完成 future。
  private func openTCP(target: NetworkAddress) -> EventLoopFuture<Void> {
    let eventLoop = proxyChannel.eventLoop
    return eventLoop.makeCompletedFuture {
      self.wire = try self.core.routeTCPWire(target)
    }.flatMap { _ -> EventLoopFuture<Void> in
      // 已完成 Future 也可能延后调度；发起拨号前重新确认 accepted 仍属于活动会话。
      guard self.state != .closed, self.proxyChannel.isActive else {
        return eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      let timeout = self.wire?.getTimeout() ?? self.core.defaultTimeout
      let connection: EventLoopFuture<Channel>
      if let wire = self.wire {
        connection = self.core.createTCPClientChannel(
          eventLoop: eventLoop, address: wire.getEndpoint(), timeout: timeout, handler: self)
      } else {
        connection = self.core.createTCPClientChannel(
          eventLoop: eventLoop, address: target, timeout: timeout, handler: self)
      }
      let established = connection.flatMap { channel -> EventLoopFuture<Void> in
        guard self.state != .closed, self.proxyChannel.isActive else {
          channel.close(promise: nil)
          return eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        self.wireChannel = channel
        return eventLoop.makeCompletedFuture {
          guard 2 * 325 + 2 * self.earlyRemoteInput.readableBytes <= Self.maximumBufferedBytes
          else {
            throw MagentError.invalidOptions("SOCKS5 startup capacity reservation failed")
          }
          let startup = try self.wire?.start(handshake: target)
          if let startup, startup.isEmpty || startup.count > 325 {
            throw MagentError.invalidOptions("Wire exceeded its fixed startup capacity")
          }
          self.wireInitialized = true
          let input = self.earlyRemoteInput
          self.earlyRemoteInput = self.proxyChannel.allocator.buffer(capacity: 0)
          try self.relayRemote(input)
          try self.finishRemoteInput()
          return startup
        }.flatMap { startup -> EventLoopFuture<Void> in
          if let startup { return channel.writeAndFlush(ByteBuffer(bytes: startup)) }
          return eventLoop.makeSucceededFuture(())
        }
      }.map {
        guard self.state != .closed else { return }
        self.startupComplete = true
      }
      // 期限在 Wire 选定后覆盖连接和启动写，不能提前套用较短的 Core 默认值。
      let deadline = eventLoop.scheduleTask(in: .milliseconds(timeout)) {
        self.fail(MagentError.channelConnectionTimedOut)
      }
      established.whenComplete { _ in deadline.cancel() }
      self.proxyChannel.closeFuture.whenComplete { _ in deadline.cancel() }
      return established
    }
  }

  /// 规范化来源提示后保存唯一 UDP owner；装配失败只经返回 Future 到统一失败边界。
  private func openAssociation(hint: SocketAddress) -> EventLoopFuture<SocketAddress> {
    let eventLoop = proxyChannel.eventLoop
    return eventLoop.makeCompletedFuture {
      guard let local = self.proxyChannel.localAddress, case .v4 = local,
        let host = local.ipAddress, host != "0.0.0.0",
        let peer = self.proxyChannel.remoteAddress, case .v4 = peer, let peerIP = peer.ipAddress,
        let hintIP = hint.ipAddress, let hintPort = hint.port
      else {
        throw MagentError.invalidAddress("SOCKS5 UDP requires a concrete IPv4 control endpoint")
      }
      guard hintIP == "0.0.0.0" || hintIP == "::" || hintIP == peerIP else {
        throw MagentError.invalidAddress("SOCKS5 UDP source hint differs from the TCP peer")
      }
      let connection = Socks5UDPConnection(
        owner: self, hint: try SocketAddress(ipAddress: peerIP, port: hintPort))
      self.udpConnection = connection
      return connection
    }.flatMap { connection in
      connection.openAssociation(dnsAddress: self.dnsAddress)
    }
  }

  /// greeting 和命令各有一次提交权。开始写入即占用，部分写失败不能换另一个回复。
  private func writeReply(_ data: ByteBuffer) -> EventLoopFuture<Void> {
    guard proxyChannel.isActive else {
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    if data.readableBytes == 2 {
      guard !greetingReplyStarted else {
        return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      greetingReplyStarted = true
    } else {
      guard !commandReplyStarted else {
        return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      commandReplyStarted = true
    }
    return proxyChannel.writeAndFlush(data)
  }

  // MARK: - TCP relay and EOF barriers

  /// 每次写完才恢复 accepted 读取；FIN 等已提交业务全部写完才传播给下游输出。
  private func relayClient(_ data: ByteBuffer) throws {
    guard state == .tcpRelay, startupComplete, let channel = wireChannel else { return }
    if data.readableBytes > 0 {
      guard !wireOutputEnded, !remoteChannelInactive else { throw MagentError.connectionClosed }
      let count = data.readableBytes
      guard count <= 64 * 1024 else {
        throw MagentError.invalidOptions("SOCKS5 client read exceeds 64 KiB")
      }
      let chunks = (count + 16 * 1024 - 1) / (16 * 1024)
      let maximumOutput = wire == nil ? count : chunks * 16_452
      // 整批预留输入、一个分片副本、编码结果和 I/O 副本，再逐个 16 KiB 调用 Wire。
      guard
        count + min(count, 16 * 1024) + 2 * maximumOutput
          <= Self.maximumBufferedBytes - 2 * pendingClientBytes
      else { throw MagentError.invalidOptions("SOCKS5 outbound capacity reservation failed") }
      var input = data
      var output = proxyChannel.allocator.buffer(capacity: maximumOutput)
      while input.readableBytes > 0 {
        let part = input.readSlice(length: min(input.readableBytes, 16 * 1024))!
        let plain = Data(part.readableBytesView)
        let encoded = try wire?.encodeOutbound(plain, address: nil) ?? plain
        guard encoded.count <= 16_452 else {
          throw MagentError.invalidOptions("Wire exceeded its fixed encode capacity")
        }
        output.writeBytes(encoded)
      }
      let outputCount = output.readableBytes
      pendingClientWrites += 1
      pendingClientBytes += outputCount
      channel.writeAndFlush(output).whenComplete { result in
        guard self.state != .closed else { return }
        self.pendingClientWrites -= 1
        self.pendingClientBytes -= outputCount
        switch result {
        case .success:
          do {
            try self.relayClient(self.proxyChannel.allocator.buffer(capacity: 0))
            try self.finishRemoteInput()
          } catch { self.fail(error) }
        case .failure(let error): self.fail(error)
        }
      }
    }
    guard pendingClientWrites == 0 else { return }
    if remoteChannelInactive {
      // 全关闭只剩已收业务的反向排空；不能再次关闭下游输出或继续准许客户端上行。
      try finishRemoteInput()
      return
    }
    if proxyInputEnded {
      // 两个输入都结束时，NIO 的第二次半关闭可能升级为全关闭；先排空反向写。
      guard !remoteInputEnded || (pendingRemoteWrites == 0 && pendingRemoteInput.readableBytes == 0)
      else { return }
      guard !wireOutputEnded else { return }
      wireOutputEnded = true
      channel.close(mode: .output).whenComplete { result in
        guard self.state != .closed else { return }
        switch result {
        case .success:
          if self.proxyOutputEnded { self.proxyChannel.close(promise: nil) }
        case .failure(let error): self.fail(error)
        }
      }
    } else {
      proxyChannel.read()
    }
  }

  /// 早到输入只经过一次 Wire；成功回复前缓存业务，写回完成后才恢复下游读取。
  private func relayRemote(_ data: ByteBuffer) throws {
    guard state != .closed else { return }
    if !wireInitialized {
      guard data.readableBytes <= 64 * 1024 - earlyRemoteInput.readableBytes else {
        throw MagentError.invalidOptions("SOCKS5 early remote input limit exceeded")
      }
      var input = data
      earlyRemoteInput.writeBuffer(&input)
      return
    }
    if data.readableBytes > 0 {
      let count = data.readableBytes
      guard !remoteInputChecked, count <= 64 * 1024 else {
        throw MagentError.invalidOptions("SOCKS5 remote read exceeds its limit")
      }
      // 解码结果还可能释放上次保留的一个 16383 字节帧，不能只按本批输入估计。
      let maximumOutput = wire == nil ? count : count + 16_383
      guard
        count + min(count, 16 * 1024) + 2 * maximumOutput
          <= Self.maximumBufferedBytes - 2 * pendingRemoteBytes - 2
          * pendingRemoteInput.readableBytes
      else { throw MagentError.invalidOptions("SOCKS5 inbound capacity reservation failed") }
      let buffered = pendingRemoteInput.readableBytes
      var input = data
      while input.readableBytes > 0 {
        let part = input.readSlice(length: min(input.readableBytes, 16 * 1024))!
        let encoded = Data(part.readableBytesView)
        let decoded = try wire?.decodeInbound(encoded).data ?? encoded
        guard decoded.count <= 32_768,
          decoded.count <= maximumOutput - (pendingRemoteInput.readableBytes - buffered)
        else { throw MagentError.invalidOptions("Wire exceeded its fixed decode capacity") }
        pendingRemoteInput.writeBytes(decoded)
      }
    }
    guard state == .tcpRelay, startupComplete else { return }
    if pendingRemoteInput.readableBytes > 0 {
      let output = pendingRemoteInput
      pendingRemoteInput = proxyChannel.allocator.buffer(capacity: 0)
      pendingRemoteWrites += 1
      pendingRemoteBytes += output.readableBytes
      proxyChannel.writeAndFlush(output).whenComplete { result in
        guard self.state != .closed else { return }
        self.pendingRemoteWrites -= 1
        self.pendingRemoteBytes -= output.readableBytes
        switch result {
        case .success:
          do {
            try self.relayRemote(self.proxyChannel.allocator.buffer(capacity: 0))
            try self.finishRemoteInput()
          } catch { self.fail(error) }
        case .failure(let error): self.fail(error)
        }
      }
    } else if pendingRemoteWrites == 0, !remoteInputEnded {
      wireChannel?.read()
    }
  }

  /// 正常 EOF 只检查一次；零业务也必须等启动及完整成功回复，然后排空反向输出。
  private func finishRemoteInput() throws {
    guard state != .closed, remoteInputEnded, wireInitialized else { return }
    if !remoteInputChecked {
      remoteInputChecked = true
      try wire?.finishInbound()
    }
    guard state == .tcpRelay, startupComplete, pendingRemoteInput.readableBytes == 0,
      pendingRemoteWrites == 0, !proxyOutputEnded,
      !proxyInputEnded || pendingClientWrites == 0
    else { return }
    proxyOutputEnded = true
    proxyChannel.close(mode: .output).whenComplete { result in
      guard self.state != .closed else { return }
      switch result {
      case .success:
        // 全关闭的下游已不能接收客户端业务；不能把它伪装成可继续写的半关闭。
        if self.wireOutputEnded || self.remoteChannelInactive {
          self.proxyChannel.close(promise: nil)
        }
      case .failure(let error): self.fail(error)
      }
    }
  }

  // MARK: - Control-connection-owned UDP association

  /// 固定首因与本阶段回复资格；清理后的重复错误不会产生第二个回复或递归关闭。
  private func fail(_ error: Error) {
    guard state != .closed else { return }
    let failedState = state
    firstError = error
    state = .closed
    let response: ByteBuffer?
    if failedState == .negotiating, !greetingReplyStarted {
      response = ByteBuffer(bytes: [0x05, 0xff])
    } else if failedState == .requesting, !commandReplyStarted {
      let code: UInt8
      switch error {
      case MagentError.invalidAddress: code = 0x08
      case MagentError.invalidPolicy, MagentError.proxyNodeNotFound: code = 0x03
      case MagentError.channelConnectionTimedOut, ChannelError.connectTimeout: code = 0x04
      case MagentError.invalidOptions
      where acceptedCommand != nil && acceptedCommand != 0x01 && acceptedCommand != 0x03:
        code = 0x07
      default: code = 0x01
      }
      response = ByteBuffer(bytes: [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    } else {
      response = nil
    }
    let completion =
      response.map { writeReply($0) } ?? proxyChannel.eventLoop.makeSucceededFuture(())
    // 尽力失败回复也有有限寿命；超时仍报告原始错误，不改写首因。
    let deadline = proxyChannel.eventLoop.scheduleTask(in: .milliseconds(core.defaultTimeout)) {
      guard !self.didCleanUp, !self.errorReported else { return }
      self.errorReported = true
      self.proxyChannel.pipeline.fireErrorCaught(error)
    }
    proxyChannel.closeFuture.whenComplete { _ in deadline.cancel() }
    completion.whenComplete { _ in
      deadline.cancel()
      guard !self.didCleanUp, !self.errorReported else { return }
      self.errorReported = true
      self.proxyChannel.pipeline.fireErrorCaught(error)
    }
  }

  /// 一条控制 TCP 专属的 UDP 关联。父对象持有它；Channel 回调不能延长父对象寿命。
  private final class Socks5UDPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private enum State {
      case preparing
      case ready
      case awaitingClient
      case forwarding
      case closed
    }

    private weak var owner: Socks5Connection?
    private let core: MagentCore
    private var state: State = .preparing
    private var ipv4Channel: Channel? = nil
    private var ipv6Channel: Channel? = nil
    private var dnsClient: DNSClient? = nil
    private var clientEndpoint: SocketAddress
    private var backendWires: [SocketAddress: Wire?] = [:]

    /// hint 已与控制对端比较并规范化；尚未观测客户端，不进行网络操作。
    init(owner: Socks5Connection, hint: SocketAddress) {
      self.owner = owner
      self.core = owner.core
      self.clientEndpoint = hint
    }

    /// 父对象保存子对象后立即调用一次；两次 bind 和可选 DNS 都成功才允许回复 BND。
    func openAssociation(dnsAddress: SocketAddress?) -> EventLoopFuture<SocketAddress> {
      // 只有强持有本子对象的父对象能开始装配；异步链随后仅依赖控制 Channel 局部引用。
      guard let owner else {
        preconditionFailure("The parent must own the association while beginning setup")
      }
      let control = owner.proxyChannel
      let eventLoop = control.eventLoop
      guard let localIP = control.localAddress?.ipAddress else {
        return eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      let addresses = eventLoop.makeCompletedFuture {
        (
          try SocketAddress(ipAddress: "0.0.0.0", port: 0),
          try SocketAddress(ipAddress: "::", port: 0)
        )
      }
      return addresses.flatMap { ipv4, ipv6 -> EventLoopFuture<SocketAddress> in
        // 在首次 bind 前也检查终态，不能仅依赖 bind 返回后的迟到资源回收。
        guard self.state == .preparing, control.isActive else {
          return eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        return self.core.createUDPClientChannel(eventLoop: eventLoop, address: ipv4, handler: self)
          .flatMap { channel -> EventLoopFuture<Channel> in
            guard self.state == .preparing, control.isActive else {
              channel.close(promise: nil)
              return eventLoop.makeFailedFuture(MagentError.connectionClosed)
            }
            self.ipv4Channel = channel
            return self.core.createUDPClientChannel(
              eventLoop: eventLoop, address: ipv6, handler: self)
          }.flatMap { channel -> EventLoopFuture<Void> in
            guard self.state == .preparing, control.isActive else {
              channel.close(promise: nil)
              return eventLoop.makeFailedFuture(MagentError.connectionClosed)
            }
            self.ipv6Channel = channel
            guard let dnsAddress else { return eventLoop.makeSucceededFuture(()) }
            return DNSClient.connect(on: eventLoop, config: [dnsAddress]).flatMapThrowing {
              client in
              guard self.state == .preparing, control.isActive else {
                _ = client.close()
                throw MagentError.connectionClosed
              }
              self.dnsClient = client
            }
          }.flatMapThrowing {
            guard self.state == .preparing, let port = self.ipv4Channel?.localAddress?.port,
              port > 0
            else { throw MagentError.connectionClosed }
            let bound = try SocketAddress(ipAddress: localIP, port: port)
            self.state = .ready
            return bound
          }
      }.flatMapError { error in
        // 装配错误只通过 Future 返回父对象，避免同时 owner.fail 导致双重上报。
        self.closeConnection()
        return eventLoop.makeFailedFuture(error)
      }
    }

    /// 完整 ASSOCIATE 成功回复写成后调用一次；资源就绪本身不授予读许可。
    func activate() {
      guard state == .ready else { return }
      state = .awaitingClient
      ipv4Channel?.read()
      ipv6Channel?.read()
    }

    /// 先封闭状态并移除持有关系，再提交资源关闭；回调重入不再次通知父对象。
    func closeConnection() {
      guard state != .closed else { return }
      state = .closed
      let ipv4 = ipv4Channel
      let ipv6 = ipv6Channel
      let client = dnsClient
      ipv4Channel = nil
      ipv6Channel = nil
      dnsClient = nil
      backendWires.removeAll()
      ipv4?.close(promise: nil)
      ipv6?.close(promise: nil)
      _ = client?.close()
    }

    /// 当前包的 DNS 和写 Future 完成后才续读，避免为一个 Channel 堆积操作。
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      guard state == .awaitingClient || state == .forwarding else { return }
      // Core 的 65535 字节接收缓冲大于 65507 协议上限；超大包在解析前丢弃。
      let channel = context.channel
      handleDatagram(unwrapInboundIn(data), channel: channel).whenComplete { result in
        guard self.state == .awaitingClient || self.state == .forwarding else { return }
        switch result {
        case .success: if channel.isActive { channel.read() }
        case .failure(let error):
          self.closeConnection()
          self.owner?.fail(error)
        }
      }
    }

    /// 活动资源意外失效结束所属关联；正常清理回调不反向报告错误。
    func channelInactive(context: ChannelHandlerContext) {
      if state != .closed {
        closeConnection()
        // 独立资源失效即刻终结；装配链后续失败由父终态去重，不继续等待其他资源。
        owner?.fail(MagentError.connectionClosed)
      }
      context.fireChannelInactive()
    }

    /// 报文过大仅丢包，其余不可恢复错误先封闭关联再保留原始错误通知父对象。
    func errorCaught(context: ChannelHandlerContext, error: Error) {
      guard state != .closed else { return }
      if let channelError = error as? ChannelError, channelError == .writeMessageTooLarge {
        if state == .awaitingClient || state == .forwarding { context.read() }
      } else {
        closeConnection()
        // 即使其他 bind/DNS 仍在途，也先保存独立资源回调的真实首因。
        owner?.fail(error)
      }
    }

    /// 单包最高边界：解析/编解码/容量失败丢包；路由、DNS 与不可用资源保留原始失败。
    /// 三段分别处理来源和解码、路由和解析、登记和写入，保持规范要求的单一 future 生命周期。
    private func handleDatagram(_ packet: AddressedEnvelope<ByteBuffer>, channel: Channel)
      -> EventLoopFuture<Void>
    {
      let eventLoop = channel.eventLoop
      guard state == .awaitingClient || state == .forwarding else {
        return eventLoop.makeSucceededFuture(())
      }
      guard packet.data.readableBytes <= 65_507,
        let sourcePort = packet.remoteAddress.port, sourcePort > 0
      else { return eventLoop.makeSucceededFuture(()) }
      let fromClient: Bool
      if state == .forwarding {
        fromClient = channel === ipv4Channel && packet.remoteAddress == clientEndpoint
      } else {
        fromClient =
          channel === ipv4Channel && packet.remoteAddress.ipAddress == clientEndpoint.ipAddress
          && (clientEndpoint.port == 0 || clientEndpoint.port == sourcePort)
      }
      if !fromClient {
        guard state == .forwarding, let relay = ipv4Channel,
          let entry = backendWires.index(forKey: packet.remoteAddress)
        else { return eventLoop.makeSucceededFuture(()) }
        let response: ByteBuffer
        do {
          if let selectedWire = backendWires[entry].value {
            let decoded = try selectedWire.decodeInbound(Data(packet.data.readableBytesView))
            response = try Self.encodeDatagram(
              payload: ByteBuffer(bytes: decoded.data), source: decoded.address.address)
          } else {
            response = try Self.encodeDatagram(
              payload: packet.data, source: .ip(packet.remoteAddress))
          }
        } catch { return eventLoop.makeSucceededFuture(()) }
        return relay.writeAndFlush(AddressedEnvelope(remoteAddress: clientEndpoint, data: response))
          .flatMapError { error in
            // NIO 将底层报文过大错误统一为 ChannelError；只丢本包，关联继续服务。
            if let channelError = error as? ChannelError, channelError == .writeMessageTooLarge {
              return eventLoop.makeSucceededFuture(())
            }
            return eventLoop.makeFailedFuture(error)
          }
      }

      let decoded: (target: NetworkAddress, payload: ByteBuffer)
      do { decoded = try Self.decodeDatagram(packet.data) } catch {
        return eventLoop.makeSucceededFuture(())
      }
      // 只有完整且合法的首个包才能占用来源；保留它的实际端点用于回包。
      if state == .awaitingClient {
        clientEndpoint = packet.remoteAddress
        state = .forwarding
      }
      let selectedWire: Wire?
      do { selectedWire = try core.routeUDPWire(decoded.target) } catch {
        return eventLoop.makeFailedFuture(error)
      }
      let payload: ByteBuffer
      let endpoint: EventLoopFuture<SocketAddress>
      if let selectedWire {
        do {
          let output = try selectedWire.encodeOutbound(
            Data(decoded.payload.readableBytesView), address: decoded.target)
          guard output.count <= 65_507 else {
            return eventLoop.makeSucceededFuture(())
          }
          payload = ByteBuffer(bytes: output)
        } catch { return eventLoop.makeSucceededFuture(()) }
        endpoint = eventLoop.makeSucceededFuture(selectedWire.getEndpoint())
      } else {
        payload = decoded.payload
        switch decoded.target.address {
        case .ip(let address): endpoint = eventLoop.makeSucceededFuture(address)
        case .domain(let host, let port):
          guard let dnsClient else {
            return eventLoop.makeFailedFuture(
              MagentError.invalidOptions("direct UDP domain target requires dnsListener"))
          }
          let timeout = TimeAmount.milliseconds(core.defaultTimeout)
          let v4 = dnsClient.sendQuery(forHost: host, type: .a, timeout: timeout).flatMapThrowing {
            message in
            try message.answers.compactMap { answer -> SocketAddress? in
              guard case .a(let record) = answer else { return nil }
              return try SocketAddress(ipAddress: record.resource.stringAddress, port: Int(port))
            }
          }
          let v6 = dnsClient.sendQuery(forHost: host, type: .aaaa, timeout: timeout).flatMapThrowing
          { message in
            try message.answers.compactMap { answer -> SocketAddress? in
              guard case .aaaa(let record) = answer else { return nil }
              return try SocketAddress(ipAddress: record.resource.stringAddress, port: Int(port))
            }
          }
          endpoint = v4.and(v6).flatMapThrowing { v4Addresses, v6Addresses in
            guard self.state == .forwarding else { throw MagentError.connectionClosed }
            guard let address = v4Addresses.first ?? v6Addresses.first else {
              throw MagentError.invalidAddress("DNS returned no address for the UDP target")
            }
            return address
          }
        }
      }
      // Wire 仅在该 EventLoop 的单包完成链中使用，不把共享协议伪装成跨线程 Sendable。
      let selectedWireOnLoop = NIOLoopBound(selectedWire, eventLoop: eventLoop)
      return endpoint.flatMap { address -> EventLoopFuture<Void> in
        guard self.state == .forwarding else { return eventLoop.makeSucceededFuture(()) }
        // 节点保留实际地址族；仅比较方向身份时把 mapped IPv6 与 IPv4 客户端视为同一端点。
        var isClientEndpoint = address == self.clientEndpoint
        if case .v6(let backend) = address, case .v4(let client) = self.clientEndpoint,
          address.port == self.clientEndpoint.port
        {
          isClientEndpoint = withUnsafeBytes(of: backend.address.sin6_addr) { backendBytes in
            withUnsafeBytes(of: client.address.sin_addr) { clientBytes in
              backendBytes.prefix(10).allSatisfy { $0 == 0 }
                && backendBytes[10] == 0xff && backendBytes[11] == 0xff
                && backendBytes.suffix(4).elementsEqual(clientBytes)
            }
          }
        }
        guard !isClientEndpoint, let port = address.port, port > 0 else {
          return eventLoop.makeSucceededFuture(())
        }
        if let entry = self.backendWires.index(forKey: address) {
          switch (self.backendWires[entry].value, selectedWireOnLoop.value) {
          case (nil, nil): break
          case (let previous?, let current?) where previous === current: break
          default: return eventLoop.makeSucceededFuture(())
          }
        } else {
          guard self.backendWires.count < 1_024 else {
            return eventLoop.makeSucceededFuture(())
          }
          self.backendWires.updateValue(selectedWireOnLoop.value, forKey: address)
        }
        let outbound: Channel?
        switch address {
        case .v4: outbound = self.ipv4Channel
        case .v6: outbound = self.ipv6Channel
        case .unixDomainSocket: return eventLoop.makeSucceededFuture(())
        }
        guard let outbound, outbound.isActive else {
          return eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        return outbound.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: payload))
      }.flatMapError { error in
        // 使用 NIO 的传输错误，不在协议层读取系统 errno 或硬编码平台错误码。
        if let channelError = error as? ChannelError, channelError == .writeMessageTooLarge {
          return eventLoop.makeSucceededFuture(())
        }
        return eventLoop.makeFailedFuture(error)
      }
    }

    /// UDP 保留完整包边界；与 TCP 解析的重复字段逻辑服务于不同的截断/端口/包级错误语义。
    private static func decodeDatagram(_ data: ByteBuffer)
      throws -> (target: NetworkAddress, payload: ByteBuffer)
    {
      var input = data
      guard input.readableBytes <= 65_507,
        input.readInteger(as: UInt16.self) == 0, input.readInteger(as: UInt8.self) == 0,
        let atyp = input.readInteger(as: UInt8.self)
      else { throw MagentError.malformedRequest("invalid or fragmented SOCKS5 UDP packet") }
      let host: String
      switch atyp {
      case 0x01, 0x04:
        guard let packed = input.readSlice(length: atyp == 0x01 ? 4 : 16) else {
          throw MagentError.invalidAddress("truncated SOCKS5 UDP numeric address")
        }
        let socket = try SocketAddress(packedIPAddress: packed, port: 0)
        guard let numericHost = socket.ipAddress else {
          throw MagentError.invalidAddress("invalid UDP IP address")
        }
        host = numericHost
      case 0x03:
        guard let length = input.readInteger(as: UInt8.self), length > 0,
          let bytes = input.readBytes(length: Int(length)),
          let name = String(bytes: bytes, encoding: .ascii),
          !name.contains(":")
        else { throw MagentError.invalidAddress("invalid SOCKS5 UDP domain") }
        host = name
      default: throw MagentError.invalidAddress("unsupported SOCKS5 UDP address type")
      }
      guard let port = input.readInteger(as: UInt16.self), port > 0 else {
        throw MagentError.invalidAddress("SOCKS5 UDP target port must be nonzero")
      }
      return (try NetworkAddress(host: host, port: port), input)
    }

    /// 回复头直接消费实际数值端点或 Wire 提供的逻辑域名；不解析 DNS 或重建逻辑目标。
    private static func encodeDatagram(payload: ByteBuffer, source: NetworkAddress.Address) throws
      -> ByteBuffer
    {
      var output = ByteBuffer(bytes: [0x00, 0x00, 0x00])
      let port: UInt16
      switch source {
      case .domain(let host, let domainPort):
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 255, bytes.allSatisfy({ $0 < 128 }), domainPort > 0
        else {
          throw MagentError.invalidAddress("invalid SOCKS5 UDP response domain")
        }
        port = domainPort
        output.writeInteger(UInt8(0x03))
        output.writeInteger(UInt8(bytes.count))
        output.writeBytes(bytes)
      case .ip(let socket):
        guard let value = socket.port, let numericPort = UInt16(exactly: value), numericPort > 0
        else {
          throw MagentError.invalidAddress("invalid SOCKS5 UDP response port")
        }
        port = numericPort
        switch socket {
        case .v4(let address):
          output.writeInteger(UInt8(0x01))
          _ = withUnsafeBytes(of: address.address.sin_addr) { output.writeBytes($0) }
        case .v6(let address):
          output.writeInteger(UInt8(0x04))
          _ = withUnsafeBytes(of: address.address.sin6_addr) { output.writeBytes($0) }
        case .unixDomainSocket:
          throw MagentError.invalidAddress("SOCKS5 UDP response source must be numeric")
        }
      }
      output.writeInteger(port)
      guard payload.readableBytes <= 65_507 - output.readableBytes else {
        throw MagentError.malformedRequest("SOCKS5 UDP response exceeds the packet limit")
      }
      var payload = payload
      output.writeBuffer(&payload)
      return output
    }
  }
}
