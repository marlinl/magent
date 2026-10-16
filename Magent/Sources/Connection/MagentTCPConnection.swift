//
//  MagentTCPConnection.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import Foundation
import NIOCore
import NIOHTTP1

/// Magent accepted Channel 上的协议探针和连接生命周期所有者。
///
/// accepted Channel 默认关闭自动读取；本类型启动首读并在协议探测数据不足时续读。
/// 收齐首请求并安装具体协议后，读取许可由 `ProxyConnection.start` 接管。
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
  /// HTTP 头定界后只保存总长度；readerIndex 是扫描进度，原字节始终从 0 开始保留。
  private var requestLength: Int? = nil

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

  /// 收齐首请求再安装；已确定非法的前缀提前交具体对象生成失败回复。
  /// 定界不构造业务模型，且不以 readerIndex 后的余量代替完整请求。
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch state {
    case .detecting:
      do {
        var input = unwrapInboundIn(data)
        let first: UInt8?
        do {
          // NIO 的绝对索引读取也受 readerIndex 限制；只复位临时副本，保留主缓冲扫描进度。
          // 此副本在追加前释放，避免每个分片都触发完整前缀的 copy-on-write。
          var prefix = detectBuffer
          prefix.moveReaderIndex(to: 0)
          first =
            prefix.getInteger(at: 0, as: UInt8.self)
            ?? input.getInteger(at: input.readerIndex, as: UInt8.self)
        }
        // SOCKS5 首批就使用 greeting 上限；只在超限拒绝时截取上限 + 1 的真实证据。
        let maximum = first == 0x05 ? 257 : 64 * 1024
        if input.readableBytes > maximum - detectBuffer.writerIndex {
          var evidence = input.readSlice(length: maximum + 1 - detectBuffer.writerIndex)!
          detectBuffer.writeBuffer(&evidence)
          installProxyConnection(try detectProxyProtocol(), context: context)
          return
        }
        detectBuffer.writeBuffer(&input)
        var received = detectBuffer
        received.moveReaderIndex(to: 0)

        // 定界仅借用原始前缀，直到完整或已知失败才进行协议分派。
        switch first {
        case 0x04:
          if let command = received.getInteger(at: 1, as: UInt8.self), command != 0x01 {
            installProxyConnection(try detectProxyProtocol(), context: context)
            return
          }
          if let port = received.getInteger(at: 2, as: UInt16.self), port == 0 {
            installProxyConnection(try detectProxyProtocol(), context: context)
            return
          }
          guard detectBuffer.writerIndex >= 8 else {
            context.read()
            return
          }
          let isSocks4a =
            received.getInteger(at: 4, as: UInt32.self).map { (1...255).contains($0) }!
          if detectBuffer.readerIndex < 8 {
            detectBuffer.moveReaderIndex(to: 8)
          }
          // 4a 固定头末字节非零；只有 USERID 的 NUL 能让游标前一字节变零。
          // 因而长 USERID 只扫描一次，不需要保存额外字段阶段或 DOMAIN 起点。
          if !isSocks4a
            || received.getInteger(at: detectBuffer.readerIndex - 1, as: UInt8.self) != 0
          {
            while detectBuffer.readerIndex < detectBuffer.writerIndex {
              let byte = detectBuffer.readInteger(as: UInt8.self)!
              if byte == 0 {
                if !isSocks4a {
                  installProxyConnection(try detectProxyProtocol(), context: context)
                  return
                }
                break
              }
            }
          }
          if isSocks4a,
            received.getInteger(at: detectBuffer.readerIndex - 1, as: UInt8.self) == 0
          {
            // 游标停在 DOMAIN 起点；窗口含最多 254 字节名称及一个 NUL。
            let domain = detectBuffer.readableBytesView.prefix(255)
            if domain.contains(0) || domain.count == 255 {
              installProxyConnection(try detectProxyProtocol(), context: context)
              return
            }
          }
          context.read()
          return

        case 0x05:
          guard let count = received.getInteger(at: 1, as: UInt8.self),
            detectBuffer.writerIndex >= 2 + Int(count)
          else {
            context.read()
            return
          }
          // count == 0 同样立即交接，由 SOCKS5 的初始化解析保存失败。
          installProxyConnection(try detectProxyProtocol(), context: context)
          return

        default:
          break
        }

        if let requestLength {
          // 头已解码过；body 是不透明字节，不重扫头也不按 body 内容判断结束。
          if detectBuffer.writerIndex >= requestLength {
            installProxyConnection(try detectProxyProtocol(), context: context)
          } else {
            context.read()
          }
          return
        }

        guard detectBuffer.writerIndex > 0 else {
          context.read()
          return
        }
        let prefix = received.readableBytesView.prefix(33)
        let method = prefix.prefix(while: { $0 != 0x20 })
        // 已知非法 token 不等待头结束；最终分类仍独立校验 EOF 等提前交接的原始前缀。
        let validMethod = method.allSatisfy { byte in
          switch byte {
          case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
            0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
            0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return true
          default:
            return false
          }
        }
        guard !method.isEmpty, method.count <= 32, validMethod else {
          throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP method")
        }
        var headLength: Int? = nil
        var offset = detectBuffer.readerIndex
        while offset + 4 <= detectBuffer.writerIndex {
          if received.getInteger(at: offset, as: UInt32.self) == 0x0D0A_0D0A {
            headLength = offset + 4
            break
          }
          offset += 1
        }
        guard let headLength else {
          // 最后三个字节留给下一批的跨界 CRLFCRLF 检查。
          detectBuffer.moveReaderIndex(to: max(0, detectBuffer.writerIndex - 3))
          context.read()
          return
        }
        detectBuffer.moveReaderIndex(to: headLength)
        let headData = received.getSlice(at: 0, length: headLength)!
        guard String(bytes: headData.readableBytesView, encoding: .utf8) != nil else {
          installProxyConnection(try detectProxyProtocol(), context: context)
          return
        }

        let output: HTTPRequestPartsHandler.Output
        do {
          output = try HttpConnectConnection.decodeRequest(headData, on: serverChannel)
        } catch {
          // 原始 codec 错误交给具体 HTTP 失败边界，不重新解码制造替代错误。
          installProxyConnection(
            try detectProxyProtocol(), context: context, initialError: error)
          return
        }
        let head: HTTPRequestHead
        switch output {
        case .head(let decoded, _), .complete(let decoded, _):
          head = decoded
        case .failed(let decoded, let error):
          let version = decoded?.version
          installProxyConnection(
            try detectProxyProtocol(), context: context, initialError: error,
            initialVersion: version == .http1_0 ? .http1_0 : .http1_1)
          return
        case .empty:
          // 已有头结束符但没有完整 head，交具体 init 按原始数据确认失败。
          installProxyConnection(try detectProxyProtocol(), context: context)
          return
        }

        let lengths = head.headers["content-length"]
        guard lengths.count <= 1,
          !head.headers.contains(name: "transfer-encoding"),
          !head.headers.contains(name: "expect"),
          !head.headers.contains(name: "trailer"),
          !head.headers.contains(name: "upgrade")
        else {
          installProxyConnection(try detectProxyProtocol(), context: context)
          return
        }
        var bodyLength = 0
        if let value = lengths.first {
          // 只裁剪字段 OWS；不让 Int 接受符号，也不合并重复或逗号 CL。
          let digits = value.utf8.drop(while: { $0 == 0x20 || $0 == 0x09 })
            .reversed().drop(while: { $0 == 0x20 || $0 == 0x09 }).reversed()
          guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }),
            let length = Int(String(decoding: digits, as: UTF8.self)),
            length <= maximum - headLength,
            head.method != .CONNECT || length == 0
          else {
            installProxyConnection(try detectProxyProtocol(), context: context)
            return
          }
          bodyLength = length
        }
        requestLength = headLength + bodyLength
        if detectBuffer.writerIndex >= headLength + bodyLength {
          installProxyConnection(try detectProxyProtocol(), context: context)
        } else {
          context.read()
        }
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
    detectBuffer.clear()
    requestLength = nil
    proxyConnection?.closeConnection(error: nil)
    context.fireChannelInactive()
  }

  /// 截断的已识别 SOCKS4/HTTP 仍交具体对象回复；安装后 EOF 由协议处理。
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }

    switch state {
    case .detecting:
      // inactive 的资源释放由 channelInactive 负责，不在失效通道上构造回复对象。
      guard serverChannel.isActive else {
        context.close(promise: nil)
        return
      }
      do {
        let proxy = try detectProxyProtocol()
        guard proxy != .socks5 else {
          context.close(promise: nil)
          return
        }
        installProxyConnection(proxy, context: context)
        // start 可能同步失败并回到本 handler；终态后不能再交 EOF。
        if state != .closed {
          proxyConnection?.proxyInputClosed(context: context)
        }
      } catch {
        errorCaught(context: context, error: error)
      }
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
    detectBuffer.clear()
    requestLength = nil
    proxyConnection?.closeConnection(error: error)
    context.close(promise: nil)
  }

  /// 只在收齐或提前失败时分类；扫描游标之前的原始前缀仍参与判断。
  private func detectProxyProtocol() throws -> State {
    var received = detectBuffer
    received.moveReaderIndex(to: 0)
    let data = received.readableBytesView
    guard let first = data.first else {
      throw MagentError.invalidOptions("Empty proxy protocol prefix")
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
      throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP method")
    }

    let method = data[..<space]
    guard !method.isEmpty, method.allSatisfy(isHTTPToken) else {
      throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP method")
    }
    let target = data[data.index(after: space)...]
    guard let firstTargetByte = target.first else {
      throw MagentError.invalidOptions("Missing HTTP target prefix")
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
    throw MagentError.invalidOptions("Unsupported proxy protocol or HTTP target prefix")
  }

  /// 先固定协议，纯解析构造并保存唯一对象；清空首包后 start，不向 upstream 重放。
  private func installProxyConnection(
    _ proxy: State, context: ChannelHandlerContext,
    initialError: Error? = nil, initialVersion: HTTPVersion = .http1_1
  ) {
    guard state == .detecting, proxyConnection == nil else {
      errorCaught(
        context: context,
        error: MagentError.invalidOptions("Proxy connection is already installed or closed"))
      return
    }

    guard proxy != .detecting, proxy != .closed else {
      errorCaught(
        context: context,
        error: MagentError.invalidOptions("Cannot install an unresolved or closed proxy protocol"))
      return
    }
    state = proxy
    var initialData = detectBuffer
    initialData.moveReaderIndex(to: 0)
    let connection: ProxyConnection
    switch proxy {
    case .socks4:
      connection = Socks4Connection(
        proxyChannel: serverChannel, core: core, initialData: initialData)
    case .socks5:
      connection = Socks5Connection(
        proxyChannel: serverChannel, core: core, dnsAddress: nil, initialData: initialData)
    case .httpConnect:
      if let initialError {
        connection = HttpConnectConnection(
          proxyChannel: serverChannel, core: core, initialData: initialData,
          initialError: initialError, initialVersion: initialVersion)
      } else {
        connection = HttpConnectConnection(
          proxyChannel: serverChannel, core: core, initialData: initialData)
      }
    case .httpForward:
      if let initialError {
        connection = HttpForwardConnection(
          proxyChannel: serverChannel, core: core, initialData: initialData,
          initialError: initialError, initialVersion: initialVersion)
      } else {
        connection = HttpForwardConnection(
          proxyChannel: serverChannel, core: core, initialData: initialData)
      }
    case .detecting, .closed:
      errorCaught(
        context: context,
        error: MagentError.invalidOptions("Cannot install an unresolved or closed proxy protocol"))
      return
    }

    // init 没有 I/O 或回调；start 之前引用及缓冲必须已经完成交接。
    proxyConnection = connection
    detectBuffer.clear()
    requestLength = nil
    connection.start(context: context)
  }
}
