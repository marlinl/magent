//
//  Socks4Connection.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//

import Foundation
import NIOCore

/// Owns one SOCKS4/4a CONNECT session on the accepted Channel's EventLoop.
///
/// The accepted Channel remains owned by MagentTCPConnection. This handler owns its
/// downstream Channel, one selected Wire, and the two ordered write directions.
internal final class Socks4Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  /// Establishment and the local reply share handshaking; only a complete reply enables forwarding.
  private enum State {
    case handshaking
    case forwarding
    case closed
  }

  private let proxyChannel: Channel
  private let core: MagentCore
  private var state: State = .handshaking
  private var wireChannel: Channel?
  private var wire: Wire?

  // A scan cursor visits each variable-length header byte once, including fragmented NULs.
  private var initialBuffer: ByteBuffer
  private var scanOffset = 8
  private var userIDEndOffset: Int?
  private var requestAccepted = false
  private var hasSocks4Version = false
  private var replyStarted = false
  private var wireInitialized = false

  // Raw bytes and decoded business bytes have separate ownership: neither is decoded twice.
  private var earlyWireBytes: ByteBuffer
  private var earlyProxyBytes = Data()
  private var wireWriteTail: EventLoopFuture<Void>
  private var proxyWriteTail: EventLoopFuture<Void>
  private var pendingWireBytes = 0
  private var pendingProxyBytes = 0

  // EOF may precede asynchronous connect/start/reply completion. These barriers also
  // carry cancellation so half-close continuations cannot outlive this connection.
  private let wireReady: EventLoopFuture<Void>
  private var wireReadyPromise: EventLoopPromise<Void>?
  private let tunnelReady: EventLoopFuture<Void>
  private var tunnelReadyPromise: EventLoopPromise<Void>?
  private var proxyInputEnded = false
  private var wireInputEnded = false
  private var wireEOFChecked = false
  private var proxyOutputEnded = false
  private var wireOutputEnded = false
  // Failure may mark the state closed before the owner invokes cleanup. Keep the first
  // error, its report, and actual resource release separate so each completes at most once.
  private var firstError: Error?
  private var errorReported = false
  private var resourcesReleased = false

  /// Creates an inert session; request validation precedes all routing and network work.
  internal init(proxyChannel: Channel, core: MagentCore) {
    self.proxyChannel = proxyChannel
    self.core = core
    self.initialBuffer = proxyChannel.allocator.buffer(capacity: 0)
    self.earlyWireBytes = proxyChannel.allocator.buffer(capacity: 0)
    self.wireWriteTail = proxyChannel.eventLoop.makeSucceededFuture(())
    self.proxyWriteTail = proxyChannel.eventLoop.makeSucceededFuture(())
    let wireReady = proxyChannel.eventLoop.makePromise(of: Void.self)
    self.wireReadyPromise = wireReady
    self.wireReady = wireReady.futureResult
    let tunnelReady = proxyChannel.eventLoop.makePromise(of: Void.self)
    self.tunnelReadyPromise = tunnelReady
    self.tunnelReady = tunnelReady.futureResult
  }

  // MARK: - Accepted Channel input

  /// Accepts exactly one request, then forwards payload only after the complete success reply.
  func upstream(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed else { return }
    var input = unwrapInboundIn(data)
    guard input.readableBytes > 0 else {
      if !proxyInputEnded { context.read() }
      return
    }

    do {
      switch state {
      case .handshaking:
        guard !requestAccepted else {
          throw MagentError.malformedRequest("SOCKS4 payload received before granted")
        }
        // Copy only the available header budget, even if this read includes a large
        // forbidden payload. The parser returns the header's actual boundary first.
        let copyCount = min(
          input.readableBytes, Self.maximumRequestSize - initialBuffer.readableBytes)
        if var part = input.readSlice(length: copyCount) {
          initialBuffer.writeBuffer(&part)
        }
        hasSocks4Version =
          initialBuffer.getInteger(at: initialBuffer.readerIndex, as: UInt8.self) == 4
        guard let length = try paserLength(initialBuffer) else {
          guard input.readableBytes == 0, initialBuffer.readableBytes < Self.maximumRequestSize
          else {
            throw MagentError.malformedRequest("SOCKS4 request is too large")
          }
          context.read()
          return
        }
        guard length == initialBuffer.readableBytes, input.readableBytes == 0 else {
          throw MagentError.malformedRequest("SOCKS4 payload received before granted")
        }
        let (command, address) = try Self.paserSocks4(initialBuffer)
        requestAccepted = true
        initialBuffer = proxyChannel.allocator.buffer(capacity: 0)
        try installWireChannel(command: command, address: address)
        // Continue observing FIN and forbidden pre-reply bytes while connect is pending.
        if state == .handshaking, !proxyInputEnded { context.read() }
      case .forwarding:
        try outbound(input)
      case .closed:
        break
      }
    } catch {
      fail(error)
    }
  }

  /// A complete request followed by FIN still establishes the tunnel before ending its output.
  func proxyInputClosed(context: ChannelHandlerContext) {
    guard state != .closed, !proxyInputEnded else { return }
    proxyInputEnded = true
    guard requestAccepted else {
      fail(MagentError.malformedRequest("truncated SOCKS4 request"))
      return
    }
    tunnelReady.flatMap {
      self.wireWriteTail
    }.flatMap {
      guard self.state == .forwarding, let channel = self.wireChannel else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      guard !self.wireOutputEnded else { return channel.eventLoop.makeSucceededFuture(()) }
      self.wireOutputEnded = true
      return channel.close(mode: .output)
    }.whenFailure { error in
      self.fail(error)
    }
  }

  /// Releases downstream resources once, including when fail already marked the session closed.
  func closeConnection(error: Error?) {
    guard !resourcesReleased else { return }
    resourcesReleased = true
    state = .closed
    if firstError == nil { firstError = error }
    let terminalError = firstError ?? MagentError.connectionClosed
    let wireReadyPromise = self.wireReadyPromise
    self.wireReadyPromise = nil
    let tunnelReadyPromise = self.tunnelReadyPromise
    self.tunnelReadyPromise = nil
    wireReadyPromise?.fail(terminalError)
    tunnelReadyPromise?.fail(terminalError)
    wireChannel?.close(promise: nil)
    wireChannel = nil
    wire = nil
    initialBuffer = proxyChannel.allocator.buffer(capacity: 0)
    earlyWireBytes = proxyChannel.allocator.buffer(capacity: 0)
    earlyProxyBytes.removeAll(keepingCapacity: false)
  }

  // MARK: - Downstream Channel callbacks

  /// Buffers raw early input until Wire initialization; decoded input waits for the local reply.
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed else { return }
    var input = unwrapInboundIn(data)
    do {
      if wireInitialized {
        try inbound(input)
      } else {
        guard input.readableBytes <= Self.maximumPendingBytes - earlyWireBytes.readableBytes else {
          throw MagentError.malformedRequest("SOCKS4 early downstream buffer exceeded")
        }
        earlyWireBytes.writeBuffer(&input)
      }
    } catch {
      fail(error)
    }
  }

  /// Checks normal downstream EOF once and propagates it only after startup, reply and writes.
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }
    guard state != .closed, !wireInputEnded else { return }
    wireInputEnded = true
    wireReady.flatMapThrowing {
      guard self.state != .closed else { throw MagentError.connectionClosed }
      // wireReady follows the drain of all raw bytes received before initialization.
      if !self.wireEOFChecked {
        try self.wire?.finishInbound()
        self.wireEOFChecked = true
      }
    }.flatMap {
      self.tunnelReady
    }.flatMap {
      self.proxyWriteTail
    }.flatMap {
      guard self.state == .forwarding else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.proxyOutputEnded = true
      return self.proxyChannel.close(mode: .output)
    }.whenFailure { error in
      self.fail(error)
    }
    context.fireUserInboundEventTriggered(event)
  }

  /// A full downstream close drains the reply and reverse bytes, then ends the accepted Channel.
  func channelInactive(context: ChannelHandlerContext) {
    guard state != .closed else {
      context.fireChannelInactive()
      return
    }
    guard pendingWireBytes == 0 else {
      fail(MagentError.connectionClosed)
      context.fireChannelInactive()
      return
    }
    if !wireInputEnded {
      userInboundEventTriggered(context: context, event: ChannelEvent.inputClosed)
    }
    // An inactive Channel cannot accept the still-open client direction. Preserve the
    // success/reverse-write barriers, but do not leave the accepted input open afterwards.
    tunnelReady.flatMap {
      guard self.state != .closed else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      return self.proxyWriteTail
    }.flatMap {
      guard self.state != .closed else {
        return self.proxyChannel.eventLoop.makeSucceededFuture(())
      }
      return self.proxyChannel.close()
    }.whenFailure { error in
      if self.state != .closed { self.fail(error) }
    }
    context.fireChannelInactive()
  }

  /// Leaves protocol response and accepted-Channel termination to the owning error boundary.
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(error)
  }

  // MARK: - Request parsing and establishment

  /// Advances the variable-header scan without revisiting bytes or counting trailing business data.
  private func paserLength(_ input: ByteBuffer) throws -> Int? {
    let count = input.readableBytes
    let base = input.readerIndex
    if count >= 1, input.getInteger(at: base, as: UInt8.self) != 4 {
      throw MagentError.malformedRequest("invalid SOCKS4 version")
    }
    if count >= 2, input.getInteger(at: base + 1, as: UInt8.self) != Socks4Command.connect.rawValue
    {
      throw MagentError.invalidOptions("SOCKS4 command is not supported")
    }
    if count >= 4, input.getInteger(at: base + 2, as: UInt16.self) == 0 {
      throw MagentError.invalidAddress("invalid SOCKS4 port")
    }
    guard count >= 8 else { return nil }
    let isSocks4a =
      input.getInteger(at: base + 4, as: UInt32.self).map { (1...255).contains($0) } == true
    while scanOffset < count {
      let offset = scanOffset
      scanOffset += 1
      let byte = input.getInteger(at: base + offset, as: UInt8.self)!
      if let userIDEndOffset {
        if byte == 0 { return offset + 1 }
        guard offset - userIDEndOffset <= 254 else {
          throw MagentError.invalidAddress("SOCKS4a domain is too long")
        }
      } else if byte == 0 {
        userIDEndOffset = offset
        if !isSocks4a { return offset + 1 }
      }
    }
    return nil
  }

  /// Validates the exact request and constructs the logical target through the shared model.
  private static func paserSocks4(_ input: ByteBuffer)
    throws -> (command: Socks4Command, address: NetworkAddress)
  {
    let bytes = Array(input.readableBytesView)
    guard bytes.count >= 9, bytes.count <= maximumRequestSize, bytes[0] == 4 else {
      throw MagentError.malformedRequest("invalid SOCKS4 request")
    }
    guard let command = Socks4Command(rawValue: bytes[1]), command == .connect else {
      throw MagentError.invalidOptions("SOCKS4 command is not supported")
    }
    let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    guard port != 0 else { throw MagentError.invalidAddress("invalid SOCKS4 port") }
    guard let userIDEnd = bytes[8...].firstIndex(of: 0) else {
      throw MagentError.malformedRequest("incomplete SOCKS4 USERID")
    }
    // USERID is an opaque, ignored field in the no-auth profile, never an IDENT request.
    let isSocks4a = bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] != 0
    if isSocks4a {
      let start = userIDEnd + 1
      guard start < bytes.count, let end = bytes[start...].firstIndex(of: 0),
        end + 1 == bytes.count,
        (1...254).contains(end - start),
        let host = String(bytes: bytes[start..<end], encoding: .ascii), !host.contains(":")
      else {
        throw MagentError.invalidAddress("invalid SOCKS4a domain")
      }
      return (command, try NetworkAddress(host: host, port: port))
    }
    guard userIDEnd + 1 == bytes.count else {
      throw MagentError.malformedRequest("SOCKS4 payload received before granted")
    }
    let socket = try SocketAddress(
      packedIPAddress: ByteBuffer(bytes: bytes[4..<8]), port: Int(port))
    guard let host = socket.ipAddress else {
      throw MagentError.invalidAddress("SOCKS4 target must be a numeric IPv4 address")
    }
    return (command, try NetworkAddress(host: host, port: port))
  }

  /// Selects one route and preserves the same Wire for endpoint, startup and the entire TCP stream.
  private func installWireChannel(command: Socks4Command, address: NetworkAddress) throws {
    guard command == .connect else {
      throw MagentError.invalidOptions("SOCKS4 command is not supported")
    }
    wire = try core.routeTCPWire(address)
    let connected: EventLoopFuture<Channel>
    if let wire {
      connected = core.createTCPClientChannel(
        eventLoop: proxyChannel.eventLoop, address: wire.getEndpoint(),
        timeout: wire.getTimeout(), handler: self)
    } else {
      connected = core.createTCPClientChannel(
        eventLoop: proxyChannel.eventLoop, address: address,
        timeout: core.defaultTimeout, handler: self)
    }
    connected.flatMap { channel -> EventLoopFuture<Void> in
      guard self.state != .closed, self.proxyChannel.isActive else {
        channel.close(promise: nil)
        return channel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.wireChannel = channel
      do {
        let startup = try self.wire?.start(handshake: address)
        if let startup, startup.isEmpty {
          throw MagentError.invalidOptions("Wire startup must return bytes or nil")
        }
        self.wireInitialized = true
        let early = self.earlyWireBytes
        self.earlyWireBytes = self.proxyChannel.allocator.buffer(capacity: 0)
        try self.inbound(early)
        let ready = self.wireReadyPromise
        self.wireReadyPromise = nil
        ready?.succeed(())
        let startupWrite =
          startup.map(self.requestWireChannel)
          ?? channel.eventLoop.makeSucceededFuture(())
        return startupWrite.flatMap { self.startTunnel(channel) }
      } catch {
        return channel.eventLoop.makeFailedFuture(error)
      }
    }.whenFailure { error in
      self.fail(error)
    }
  }

  /// A complete eight-byte success write is the only transition that enables tunnel delivery.
  private func startTunnel(_ channel: Channel) -> EventLoopFuture<Void> {
    guard state != .closed, proxyChannel.isActive, channel.isActive else {
      channel.close(promise: nil)
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    guard let reply = respondProxyChannelOnce(Self.granted) else {
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    return reply.flatMap {
      guard self.state != .closed, self.proxyChannel.isActive else {
        return channel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      self.state = .forwarding
      let early = self.earlyProxyBytes
      self.earlyProxyBytes.removeAll(keepingCapacity: false)
      // Already decoded bytes bypass inbound so their Wire state is not advanced twice.
      let drain =
        early.isEmpty
        ? channel.eventLoop.makeSucceededFuture(()) : self.respondProxyChannel(early)
      let ready = self.tunnelReadyPromise
      self.tunnelReadyPromise = nil
      ready?.succeed(())
      if !self.proxyInputEnded, channel.isActive { self.proxyChannel.read() }
      drain.whenSuccess {
        if self.state == .forwarding, !self.wireInputEnded, self.pendingProxyBytes == 0 {
          channel.read()
        }
      }
      return drain
    }
  }

  // MARK: - Terminal error and ordered transport

  /// Preserves the original first failure; even a failed best-effort reply reports that same error.
  private func fail(_ error: Error) {
    guard firstError == nil, !resourcesReleased else { return }
    firstError = error
    state = .closed
    let wireReadyPromise = self.wireReadyPromise
    self.wireReadyPromise = nil
    let tunnelReadyPromise = self.tunnelReadyPromise
    self.tunnelReadyPromise = nil
    wireReadyPromise?.fail(error)
    tunnelReadyPromise?.fail(error)
    let reply: EventLoopFuture<Void>?
    if hasSocks4Version, proxyChannel.isActive, !proxyOutputEnded {
      reply = respondProxyChannelOnce(Self.rejected)
    } else {
      reply = nil
    }
    (reply ?? proxyChannel.eventLoop.makeSucceededFuture(())).whenComplete { _ in
      guard !self.errorReported, !self.resourcesReleased else { return }
      self.errorReported = true
      self.proxyChannel.pipeline.fireErrorCaught(error)
    }
  }

  /// Encodes one business batch; the next upstream read waits until this direction's writes drain.
  private func outbound(_ data: ByteBuffer) throws {
    guard state == .forwarding, data.readableBytes > 0 else { return }
    guard let channel = wireChannel, channel.isActive else {
      throw MagentError.connectionClosed
    }
    guard data.readableBytes <= Self.maximumPendingBytes - pendingWireBytes else {
      throw MagentError.malformedRequest("SOCKS4 upstream buffer exceeded")
    }
    // TODO: Reserve Wire's documented worst-case expansion before encode. This first
    // version bounds queued output; concrete Wire capacity guarantees still need migration.
    let plain = Data(data.readableBytesView)
    let encoded = try wire?.encodeOutbound(plain, address: nil) ?? plain
    requestWireChannel(encoded).whenComplete { result in
      switch result {
      case .success:
        if self.state == .forwarding, !self.proxyInputEnded, self.pendingWireBytes == 0,
          channel.isActive
        {
          self.proxyChannel.read()
        }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  /// Decodes initialized stream input and retains early plaintext behind the complete-reply barrier.
  private func inbound(_ data: ByteBuffer) throws {
    guard state != .closed, wireInitialized else { return }
    guard data.readableBytes <= Self.maximumPendingBytes - pendingProxyBytes - earlyProxyBytes.count
    else {
      throw MagentError.malformedRequest("SOCKS4 downstream buffer exceeded")
    }
    // TODO: Include Wire's retained partial frame and worst-case plaintext release in
    // the pre-call reservation once the concrete decoder capacity contract is migrated.
    let bytes = Data(data.readableBytesView)
    let decoded = bytes.isEmpty ? Data() : (try wire?.decodeInbound(bytes).data ?? bytes)
    guard decoded.count <= Self.maximumPendingBytes - pendingProxyBytes - earlyProxyBytes.count
    else {
      throw MagentError.malformedRequest("SOCKS4 decoded buffer exceeded")
    }
    if state == .handshaking {
      earlyProxyBytes.append(decoded)
      return
    }
    guard !decoded.isEmpty else {
      if !wireInputEnded, pendingProxyBytes == 0 { wireChannel?.read() }
      return
    }
    respondProxyChannel(decoded).whenComplete { result in
      switch result {
      case .success:
        if self.state == .forwarding, !self.wireInputEnded, self.pendingProxyBytes == 0 {
          self.wireChannel?.read()
        }
      case .failure(let error):
        self.fail(error)
      }
    }
  }

  /// Orders startup and encoded business writes; missing or cancelled downstreams fail unchanged.
  private func requestWireChannel(_ data: Data) -> EventLoopFuture<Void> {
    guard state != .closed, let channel = wireChannel else {
      return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }
    guard data.count <= Self.maximumPendingBytes - pendingWireBytes else {
      return proxyChannel.eventLoop.makeFailedFuture(
        MagentError.malformedRequest("SOCKS4 downstream write buffer exceeded"))
    }
    pendingWireBytes += data.count
    let write = wireWriteTail.flatMap {
      guard self.state != .closed else {
        return channel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      var buffer = channel.allocator.buffer(capacity: data.count)
      buffer.writeBytes(data)
      return channel.writeAndFlush(buffer)
    }
    wireWriteTail = write
    write.whenComplete { _ in self.pendingWireBytes -= data.count }
    return write
  }

  /// Orders local replies and already decoded business bytes without taking the reply right.
  private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void> {
    guard data.count <= Self.maximumPendingBytes - pendingProxyBytes else {
      return proxyChannel.eventLoop.makeFailedFuture(
        MagentError.malformedRequest("SOCKS4 accepted write buffer exceeded"))
    }
    let isFailureReply = state == .closed && firstError != nil
    pendingProxyBytes += data.count
    let write = proxyWriteTail.flatMap {
      guard self.proxyChannel.isActive,
        self.state != .closed || (isFailureReply && !self.resourcesReleased)
      else {
        return self.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
      }
      var buffer = self.proxyChannel.allocator.buffer(capacity: data.count)
      buffer.writeBytes(data)
      return self.proxyChannel.writeAndFlush(buffer)
    }
    proxyWriteTail = write
    write.whenComplete { _ in self.pendingProxyBytes -= data.count }
    return write
  }

  /// Accepted EventLoop confinement makes acquiring the one reply right atomic for this session.
  private func respondProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>? {
    guard !replyStarted else { return nil }
    replyStarted = true
    return respondProxyChannel(data)
  }

  private static let maximumRequestSize = 64 * 1024
  private static let maximumPendingBytes = 256 * 1024
  private static let granted = Data([0x00, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  private static let rejected = Data([0x00, 0x5B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
}

/// Decoded SOCKS4 command values; this connection accepts CONNECT and rejects BIND before routing.
internal enum Socks4Command: UInt8 {
  case connect = 0x01
  case bind = 0x02
}
