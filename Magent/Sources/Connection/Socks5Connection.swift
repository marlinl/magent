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
  private static let maximumDatagramBytes = 65_507
  private static let maximumAssociationRecords = 1_024

  /// 关联资源跟随控制 TCP 的生命周期；共享 UDP Wire 不归此处关闭。
  private var udpV4Channel: Channel?
  private var udpV6Channel: Channel?
  private var dnsClient: DNSClient?
  /// hint 保存经过数值身份比较的 IPv4 IP 和可选端口；client 保留实际回包端点。
  private var sourceHint: SocketAddress?
  private var udpClient: SocketAddress?
  private var resolvedAddresses: [NetworkAddress: SocketAddress] = [:]
  /// 字典的存在性与可选 value 分开：nil value 是 DIRECT，缺少 key 是未知来源。
  private var backendWires: [SocketAddress: Wire?] = [:]

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
    udpV4Channel?.close(promise: nil)
    udpV6Channel?.close(promise: nil)
    _ = dnsClient?.close()
    wireChannel = nil
    wire = nil
    udpV4Channel = nil
    udpV6Channel = nil
    dnsClient = nil
    sourceHint = nil
    udpClient = nil
    backendWires.removeAll()
    resolvedAddresses.removeAll()
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

  /// 一个完成的消息只推进一个阶段；回复在途继续观察客户端，提前数据统一失败。
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
      writeReply(ByteBuffer(bytes: [0x05, 0x00])).whenComplete { result in
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
      operation.flatMap { bound -> EventLoopFuture<Void> in
        guard self.state != .closed else {
          return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        // BND 是实际端点；缺失时仅 CONNECT 可使用协议规定的零地址。
        var reply = ByteBuffer(bytes: [0x05, 0x00, 0x00])
        if let bound, let port = bound.port, let encodedPort = UInt16(exactly: port) {
          switch bound {
          case .v4(let address):
            reply.writeInteger(UInt8(0x01))
            withUnsafeBytes(of: address.address.sin_addr) { reply.writeBytes($0) }
          case .v6(let address):
            reply.writeInteger(UInt8(0x04))
            withUnsafeBytes(of: address.address.sin6_addr) { reply.writeBytes($0) }
          case .unixDomainSocket:
            return self.proxyChannel.eventLoop.makeFailedFuture(
              MagentError.invalidAddress("SOCKS5 bound address must be numeric"))
          }
          reply.writeInteger(encodedPort)
        } else {
          reply.writeBytes([UInt8(0x01), 0, 0, 0, 0, 0, 0])
        }
        return self.writeReply(reply)
      }.whenComplete { result in
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
            self.udpV4Channel?.read()
            self.udpV6Channel?.read()
            self.proxyChannel.read()
          }
        case .failure(let error): self.fail(error)
        }
      }
    }
    if state != .closed, !proxyInputEnded { proxyChannel.read() }
  }

  /// 一次选路所得 Wire 同时决定拨号端点、超时和流状态；启动输出写成才完成 future。
  private func openTCP(target: NetworkAddress) -> EventLoopFuture<Void> {
    let eventLoop = proxyChannel.eventLoop
    let connection: EventLoopFuture<Channel>
    do {
      wire = try core.routeTCPWire(target)
      if let wire {
        connection = core.createTCPClientChannel(
          eventLoop: eventLoop, address: wire.getEndpoint(), timeout: wire.getTimeout(),
          handler: self)
      } else {
        connection = core.createTCPClientChannel(
          eventLoop: eventLoop, address: target, timeout: core.defaultTimeout, handler: self)
      }
    } catch { return eventLoop.makeFailedFuture(error) }
    return connection.flatMap { channel -> EventLoopFuture<Void> in
      guard self.state != .closed, self.proxyChannel.isActive else {
        channel.close(promise: nil)
        return eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.wireChannel = channel
      do {
        let startup = try self.wire?.start(handshake: target)
        self.wireInitialized = true
        let input = self.earlyRemoteInput
        self.earlyRemoteInput = self.proxyChannel.allocator.buffer(capacity: 0)
        try self.relayRemote(input)
        try self.finishRemoteInput()
        if let startup {
          return channel.writeAndFlush(ByteBuffer(bytes: startup))
        }
        return eventLoop.makeSucceededFuture(())
      } catch { return eventLoop.makeFailedFuture(error) }
    }.map {
      guard self.state != .closed else { return }
      self.startupComplete = true
    }
  }

  /// 两个 Channel 和 DNS client 逐个归当前 owner；后续失败由 fail 触发同一个清理入口。
  private func openAssociation(hint: SocketAddress) -> EventLoopFuture<SocketAddress> {
    let eventLoop = proxyChannel.eventLoop
    let localIP: String
    let v4Bind: SocketAddress
    let v6Bind: SocketAddress
    do {
      guard let local = proxyChannel.localAddress, case .v4 = local,
        let host = local.ipAddress, host != "0.0.0.0",
        let peer = proxyChannel.remoteAddress, case .v4 = peer, let peerIP = peer.ipAddress,
        let hintIP = hint.ipAddress, let hintPort = hint.port
      else {
        throw MagentError.invalidAddress("SOCKS5 UDP requires a concrete IPv4 control endpoint")
      }
      // parseHandshake 已通过模型将 mapped IPv6 hint 归一为 IPv4；零 IPv6 hint 同样允许。
      guard hintIP == "0.0.0.0" || hintIP == "::" || hintIP == peerIP else {
        throw MagentError.invalidAddress("SOCKS5 UDP source hint differs from the TCP peer")
      }
      localIP = host
      sourceHint = try SocketAddress(ipAddress: peerIP, port: hintPort)
      v4Bind = try SocketAddress(ipAddress: "0.0.0.0", port: 0)
      v6Bind = try SocketAddress(ipAddress: "::", port: 0)
    } catch { return eventLoop.makeFailedFuture(error) }
    return core.createUDPClientChannel(
      eventLoop: eventLoop, address: v4Bind, handler: DatagramHandler(owner: self)
    ).flatMap { channel -> EventLoopFuture<Channel> in
      guard self.state != .closed, self.proxyChannel.isActive else {
        channel.close(promise: nil)
        return eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.udpV4Channel = channel
      return self.core.createUDPClientChannel(
        eventLoop: eventLoop, address: v6Bind, handler: DatagramHandler(owner: self))
    }.flatMap { channel -> EventLoopFuture<Void> in
      guard self.state != .closed, self.proxyChannel.isActive else {
        channel.close(promise: nil)
        return eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.udpV6Channel = channel
      guard let dnsAddress = self.dnsAddress else { return eventLoop.makeSucceededFuture(()) }
      return DNSClient.connect(on: eventLoop, config: [dnsAddress]).flatMapThrowing { client in
        guard self.state != .closed, self.proxyChannel.isActive else {
          _ = client.close()
          throw MagentError.connectionClosed
        }
        self.dnsClient = client
      }
    }.flatMapThrowing {
      guard self.state != .closed, let port = self.udpV4Channel?.localAddress?.port, port > 0 else {
        throw MagentError.connectionClosed
      }
      return try SocketAddress(ipAddress: localIP, port: port)
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
      guard !wireOutputEnded, !remoteChannelInactive,
        data.readableBytes <= Self.maximumBufferedBytes - pendingClientBytes
      else { throw MagentError.connectionClosed }
      // TODO: 与具体 Wire 的固定输入/最坏输出上界一起完成调用前容量预留；不新增预算接口。
      let output =
        try wire?.encodeOutbound(Data(data.readableBytesView), address: nil)
        ?? Data(data.readableBytesView)
      guard output.count <= Self.maximumBufferedBytes - pendingClientBytes else {
        throw MagentError.invalidOptions("SOCKS5 outbound buffer limit exceeded")
      }
      pendingClientWrites += 1
      pendingClientBytes += output.count
      channel.writeAndFlush(ByteBuffer(bytes: output)).whenComplete { result in
        guard self.state != .closed else { return }
        self.pendingClientWrites -= 1
        self.pendingClientBytes -= output.count
        switch result {
        case .success:
          do { try self.relayClient(self.proxyChannel.allocator.buffer(capacity: 0)) } catch {
            self.fail(error)
          }
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
      guard data.readableBytes <= Self.maximumBufferedBytes - earlyRemoteInput.readableBytes else {
        throw MagentError.invalidOptions("SOCKS5 early remote input limit exceeded")
      }
      var input = data
      earlyRemoteInput.writeBuffer(&input)
      return
    }
    if data.readableBytes > 0 {
      guard !remoteInputChecked,
        data.readableBytes <= Self.maximumBufferedBytes - pendingRemoteBytes
          - pendingRemoteInput.readableBytes
      else { throw MagentError.invalidOptions("SOCKS5 remote input limit exceeded") }
      // TODO: 具体 Wire 尚未声明固定最坏解码返回值；此处只有结果与 owner 队列限额检查。
      let output =
        try wire?.decodeInbound(Data(data.readableBytesView)).data
        ?? Data(data.readableBytesView)
      guard
        output.count <= Self.maximumBufferedBytes - pendingRemoteBytes
          - pendingRemoteInput.readableBytes
      else {
        throw MagentError.invalidOptions("SOCKS5 decoded output limit exceeded")
      }
      pendingRemoteInput.writeBytes(output)
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
      pendingRemoteWrites == 0, !proxyOutputEnded
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

  /// 单包最高边界：解析/编解码/容量失败丢包；路由、DNS 与不可用资源保留原始失败。
  /// 三段分别处理来源和解码、路由和解析、登记和写入，保持规范要求的单一 future 生命周期。
  private func handleDatagram(_ packet: AddressedEnvelope<ByteBuffer>, channel: Channel)
    -> EventLoopFuture<Void>
  {
    let eventLoop = proxyChannel.eventLoop
    guard state == .udpAssociated else { return eventLoop.makeSucceededFuture(()) }
    guard packet.data.readableBytes <= Self.maximumDatagramBytes,
      let hint = sourceHint, let sourcePort = packet.remoteAddress.port, sourcePort > 0
    else { return eventLoop.makeSucceededFuture(()) }
    let fromClient: Bool
    if let udpClient {
      fromClient = channel === udpV4Channel && packet.remoteAddress == udpClient
    } else {
      fromClient =
        channel === udpV4Channel && packet.remoteAddress.ipAddress == hint.ipAddress
        && (hint.port == 0 || hint.port == sourcePort)
    }
    if !fromClient {
      guard let client = udpClient, let relay = udpV4Channel,
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
      return relay.writeAndFlush(AddressedEnvelope(remoteAddress: client, data: response))
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
    if udpClient == nil { udpClient = packet.remoteAddress }
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
        guard output.count <= Self.maximumDatagramBytes else {
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
        if let cached = resolvedAddresses[decoded.target] {
          endpoint = eventLoop.makeSucceededFuture(cached)
        } else {
          guard resolvedAddresses.count < Self.maximumAssociationRecords else {
            return eventLoop.makeSucceededFuture(())
          }
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
            guard self.state == .udpAssociated else { throw MagentError.connectionClosed }
            guard let address = v4Addresses.first ?? v6Addresses.first else {
              throw MagentError.invalidAddress("DNS returned no address for the UDP target")
            }
            self.resolvedAddresses[decoded.target] = address
            return address
          }
        }
      }
    }
    return endpoint.flatMap { address -> EventLoopFuture<Void> in
      guard self.state == .udpAssociated else { return eventLoop.makeSucceededFuture(()) }
      // 节点保留实际地址族；仅比较方向身份时把 mapped IPv6 与 IPv4 客户端视为同一端点。
      var isClientEndpoint = address == self.udpClient
      if case .v6(let backend) = address, case .v4(let client)? = self.udpClient,
        address.port == self.udpClient?.port
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
        switch (self.backendWires[entry].value, selectedWire) {
        case (nil, nil): break
        case (let previous?, let current?) where previous === current: break
        default: return eventLoop.makeSucceededFuture(())
        }
      } else {
        guard self.backendWires.count < Self.maximumAssociationRecords else {
          return eventLoop.makeSucceededFuture(())
        }
        self.backendWires.updateValue(selectedWire, forKey: address)
      }
      let outbound: Channel?
      switch address {
      case .v4: outbound = self.udpV4Channel
      case .v6: outbound = self.udpV6Channel
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
    guard input.readableBytes <= maximumDatagramBytes,
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
        withUnsafeBytes(of: address.address.sin_addr) { output.writeBytes($0) }
      case .v6(let address):
        output.writeInteger(UInt8(0x04))
        withUnsafeBytes(of: address.address.sin6_addr) { output.writeBytes($0) }
      case .unixDomainSocket:
        throw MagentError.invalidAddress("SOCKS5 UDP response source must be numeric")
      }
    }
    output.writeInteger(port)
    guard payload.readableBytes <= maximumDatagramBytes - output.readableBytes else {
      throw MagentError.malformedRequest("SOCKS5 UDP response exceeds the packet limit")
    }
    var payload = payload
    output.writeBuffer(&payload)
    return output
  }

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
    completion.whenComplete { _ in
      guard !self.didCleanUp else { return }
      // 回复写失败不覆盖首次错误；accepted owner 收到原始错误后调用 closeConnection。
      self.proxyChannel.pipeline.fireErrorCaught(error)
    }
  }

  /// 只适配现有 UDP Channel；资源、路由和生命周期都保存在控制连接 owner。
  private final class DatagramHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private weak var owner: Socks5Connection?

    /// Channel 不延长控制连接寿命；资源归属与关联状态只保留在 owner。
    init(owner: Socks5Connection) {
      self.owner = owner
    }

    /// 当前包的 DNS 和写入 future 完成后才续读，避免为同一 Channel 堆积无界操作。
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      guard let owner, owner.state == .udpAssociated else { return }
      // TODO: 通过 NIO 通用接口识别数据报截断；仅凭接收长度等于容量不能证明包完整。
      let channel = context.channel
      owner.handleDatagram(unwrapInboundIn(data), channel: channel).whenComplete { result in
        guard owner.state == .udpAssociated else { return }
        switch result {
        case .success: if channel.isActive { channel.read() }
        case .failure(let error): owner.fail(error)
        }
      }
    }

    /// 非清理期间的资源失效会终结关联；owner 已关闭时只继续传播事件。
    func channelInactive(context: ChannelHandlerContext) {
      if let owner, owner.state != .closed { owner.fail(MagentError.connectionClosed) }
      context.fireChannelInactive()
    }

    /// 报文过大只丢当前包并续读；其他资源错误交控制连接的统一失败边界。
    func errorCaught(context: ChannelHandlerContext, error: Error) {
      guard let owner, owner.state != .closed else { return }
      if let channelError = error as? ChannelError, channelError == .writeMessageTooLarge {
        if owner.state == .udpAssociated { context.read() }
      } else {
        owner.fail(error)
      }
    }
  }
}
