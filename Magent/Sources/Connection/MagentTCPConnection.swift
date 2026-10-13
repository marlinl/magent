//
//  MagentTCPConnection.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import NIOCore

/// Magent accepted Channel 上的协议探针和连接生命周期所有者。
///
/// accepted Channel 默认关闭自动读取；本类型启动首读并在协议探测数据不足时续读。
/// 识别出具体协议后，读取许可由具体 `ProxyConnection` 的流控规则接管。
/// 所有成员和协议调用在 accepted EventLoop 串行访问；Sendable 不开放跨线程修改。
internal final class MagentTCPConnection: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  /// 协议状态只表示已经选定对象，不代表请求完整、下游就绪或成功回复写成。
  private enum State {
    case detecting
    case socks4
    case socks5
    case httpConnect
    case httpForward
    case closed
  }

  private let serverChannel: Channel
  private let core: MagentCore
  private var detectBuffer: ByteBuffer
  private var state: State = .detecting
  private var proxyConnection: ProxyConnection? = nil

  /// 持有 accepted Channel 的协议探测状态，并订阅所属运行周期的关闭通知。
  internal init(
    _ serverChannel: Channel, core: MagentCore,
    shutdownFuture: EventLoopFuture<Void>
  ) {
    self.serverChannel = serverChannel
    self.core = core
    self.detectBuffer = serverChannel.allocator.buffer(capacity: 0)
    // 通知只请求旧 accepted 关闭，不持有 handler；终态和下游清理由 NIO 回调收敛。
    shutdownFuture.whenComplete { [weak serverChannel] _ in
      serverChannel?.close(promise: nil)
    }
  }

  /// accepted Channel 激活后发出第一次手动读取，启动协议探测。
  func channelActive(context: ChannelHandlerContext) {
    context.fireChannelActive()
    guard state == .detecting else {
      return
    }
    context.read()
  }

  /// 探测期累计有界原字节；选定协议后只交付给同一对象，由它接管读许可。
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch state {
    case .detecting:
      do {
        var input = unwrapInboundIn(data)
        // 沿用入站请求的 64 KiB 上限，先检查再追加；方法 token 的 32 字节不是整批限额。
        let maximum = 64 * 1024
        guard input.readableBytes <= maximum - detectBuffer.readableBytes else {
          throw MagentError.invalidOptions("Proxy protocol detection exceeds 64 KiB")
        }
        detectBuffer.writeBuffer(&input)
        let proxy = try detectProxyProtocol()
        guard proxy != .detecting else {
          context.read()
          return
        }
        installProxyConnection(proxy, context: context)
      } catch {
        // 本 handler 是探测失败的最高拥有边界，不能向后传播而跳过自身清理。
        errorCaught(context: context, error: error)
      }
    case .socks4, .socks5, .httpConnect, .httpForward:
      guard let proxyConnection else {
        errorCaught(
          context: context,
          error: MagentError.invalidOptions("Selected proxy protocol has no connection"))
        return
      }
      proxyConnection.upstream(context: context, data: data)
    case .closed:
      return
    }
  }

  /// accepted 完整失效时先固定终态，再清理下游一次；重复事件仍向后传播。
  func channelInactive(context: ChannelHandlerContext) {
    guard state != .closed else {
      context.fireChannelInactive()
      return
    }
    state = .closed
    proxyConnection?.closeConnection(error: nil)
    context.fireChannelInactive()
  }

  /// 探测期 EOF 结束 accepted；分类后由具体协议决定半关闭或关联终止。
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }

    switch state {
    case .detecting:
      context.close(promise: nil)
    case .socks4, .socks5, .httpConnect, .httpForward:
      guard let proxyConnection else {
        errorCaught(
          context: context,
          error: MagentError.invalidOptions("Selected proxy protocol has no connection"))
        return
      }
      proxyConnection.proxyInputClosed(context: context)
    case .closed:
      return
    }
  }

  /// 原始错误只走此入口；先置 closed 防止下游清理回调重入，再关闭 accepted。
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    guard state != .closed else {
      context.close(promise: nil)
      return
    }
    state = .closed
    proxyConnection?.closeConnection(error: error)
    context.close(promise: nil)
  }

  /// 只读取原始前缀并选择协议；不足时保留 detecting，不支持则将原始错误交上层。
  private func detectProxyProtocol() throws -> State {
    let data = detectBuffer.readableBytesView
    guard let first = data.first else {
      return .detecting
    }

    switch first {
    case 0x04:
      return .socks4
    case 0x05:
      return .socks5
    default:
      break
    }

    let connectMethod = "CONNECT ".utf8
    if data.starts(with: connectMethod) {
      return .httpConnect
    }
    if connectMethod.starts(with: data) {
      return .detecting
    }

    let isHTTPToken: (UInt8) -> Bool = { byte in
      switch byte {
      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
        0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
        0x5E, 0x5F, 0x60, 0x7C, 0x7E:
        return true
      default:
        return false
      }
    }
    guard let space = data.prefix(33).firstIndex(of: 0x20) else {
      guard data.count <= 32, data.allSatisfy(isHTTPToken) else {
        throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP method")
      }
      return .detecting
    }

    let method = data[..<space]
    guard !method.isEmpty, method.allSatisfy(isHTTPToken) else {
      throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP method")
    }
    let target = data[data.index(after: space)...]
    guard let firstTargetByte = target.first else {
      return .detecting
    }
    if firstTargetByte == 0x2F || firstTargetByte == 0x2A {
      return .httpForward
    }

    // 只按 ASCII 比较方案前缀，不解码目标或同批余量，避免 UTF-8 分片改变分类结果。
    let targetPrefix = target.prefix(8).map { byte in
      (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }
    let httpPrefix = "http://".utf8
    let httpsPrefix = "https://".utf8
    if targetPrefix.starts(with: httpPrefix) || targetPrefix.starts(with: httpsPrefix) {
      return .httpForward
    }
    if httpPrefix.starts(with: targetPrefix) || httpsPrefix.starts(with: targetPrefix) {
      return .detecting
    }
    throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP target prefix")
  }

  /// 保存唯一对象并固定协议状态，清空探测缓冲后才对外交付全部字节，避免重入重放。
  private func installProxyConnection(_ proxy: State, context: ChannelHandlerContext) {
    guard state == .detecting, proxyConnection == nil else {
      errorCaught(
        context: context,
        error: MagentError.invalidOptions("Proxy connection is already installed or closed"))
      return
    }

    let connection: ProxyConnection
    switch proxy {
    case .socks4:
      connection = Socks4Connection(proxyChannel: serverChannel, core: core)
    case .socks5:
      connection = Socks5Connection(proxyChannel: serverChannel, core: core, dnsAddress: nil)
    case .httpConnect:
      connection = HttpConnectConnection(proxyChannel: serverChannel, core: core)
    case .httpForward:
      connection = HttpForwardConnection(proxyChannel: serverChannel, core: core)
    case .detecting, .closed:
      errorCaught(
        context: context,
        error: MagentError.invalidOptions("Cannot install an unresolved or closed proxy protocol"))
      return
    }

    // 四种协议共用同一交接顺序，不在保存对象到固定状态之间调用外部代码。
    proxyConnection = connection
    state = proxy
    let initialData = detectBuffer
    detectBuffer.clear()
    connection.upstream(context: context, data: NIOAny(initialData))
  }
}
