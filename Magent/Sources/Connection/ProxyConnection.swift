//
//  ProxyConnection.swift
//  Magent
//

import NIOCore

/// 主 handler 安装的具体本地协议连接；初始化解析与网络启动是两个独立阶段。
///
/// `MagentTCPConnection` 收齐首请求并交给具体初始化器，保存唯一 owner 后才调用 `start`。
/// 本协议只负责后续协议入口和下游资源；accepted Channel 的最终关闭权仍属于主 handler。
internal protocol ProxyConnection: AnyObject {
  /// 主 handler 固定协议、保存对象并清空首请求缓冲后调用一次；从这里开始网络工作。
  func start(context: ChannelHandlerContext)

  /// 只接收初始化之后的新字节；具体协议负责接收资格、容量以及手动续读。
  func upstream(context: ChannelHandlerContext, data: NIOAny)

  /// accepted 结束或出错时清理下游，不关闭 accepted、不回包，也不反向上报错误。
  /// nil 不区分正常结束与 runtime 关闭；已有尾写只按具体协议允许的窄条件有界排空。
  func closeConnection(error: Error?)

  /// 所有先到字节都已交付后的真实客户端 EOF，由具体协议决定截断或正常排空。
  func proxyInputClosed(context: ChannelHandlerContext)
}

// MARK: - 共享 TCP 传输契约

/// 具体 Connection 提供同一份方向状态，公共实现负责写入屏障、手动续读和 TCP 半关闭。
///
/// 所有入口和属性访问都在 accepted EventLoop 上进行；本协议没有独立存储或资源 owner。
/// 两个 Future 只表示启动、数据及下行尾校验的排空，不包含等待对向或传播 FIN 的流程。
/// 具体 Connection 在数据入口前预留容量，并在返回 Future 完成时同步释放该批预留。
internal protocol TCPTransfer: AnyObject, Sendable {
  var upstreamTransfer: EventLoopFuture<Void>? { get set }
  var downstreamTransfer: EventLoopFuture<Void>? { get set }
  var upstreamInputClosed: Bool { get set }
  var downstreamInputClosed: Bool { get set }

  /// 只借用当前 Channel 和既有终态；返回值不保存到成员，也不跨 Future 捕获。
  /// proxy 在终态后仍可提供 EventLoop；wire 未建立或清理后可为 nil，不能据此推断终态。
  func transferContext() -> (proxy: Channel, wire: Channel?, isClosed: Bool)

  /// 同步编码并提交本批全部下游写入，返回真实写完的 Future；同步错误原样转为失败 Future。
  /// 不处理续读、EOF 或对向等待，也不能推迟到此前写入完成后才提交本批。
  func writeUpstream(_ data: ByteBuffer) -> EventLoopFuture<Void>

  /// 非 nil 解码并实际写回客户端；nil 只执行 Wire 尾校验，DIRECT 返回成功。
  /// 空 ByteBuffer 仍是数据；尾校验不写客户端、不改变回复资格、不发送 FIN 或关闭连接。
  func writeDownstream(_ data: ByteBuffer?) -> EventLoopFuture<Void>

  /// nil 表示正常排空后主动结束；非 nil 将原错交给具体协议唯一失败边界。
  /// 首次调用先占终态，再按协议回复、清理或上报；后续调用不覆盖首错，不重新进入传输。
  func finishTransfer(error: Error?)
}

// MARK: - 启动与方向输入

extension TCPTransfer {
  /// 先登记启动屏障，再等待 Wire 启动和完整成功回复；调用者只安装一次。
  /// 成功检查延后一个 EventLoop 调度点，使同次 read 的数据、EOF 和容量释放先落定。
  func startUpstream(after ready: EventLoopFuture<Void>) {
    let context = transferContext()
    let eventLoop = context.proxy.eventLoop
    eventLoop.preconditionInEventLoop()
    guard !context.isClosed else { return }
    precondition(ready.eventLoop === eventLoop)
    upstreamTransfer = ready

    ready.whenComplete { [weak self] result in
      switch result {
      case .failure(let error):
        guard let self, !self.transferContext().isClosed else { return }
        self.finishTransfer(error: error)
      case .success:
        eventLoop.execute { [weak self] in
          guard let self else { return }
          let context = self.transferContext()
          guard !context.isClosed, self.upstreamTransfer === ready else { return }
          self.upstreamTransfer = nil
          guard !self.upstreamInputClosed else { return }
          context.proxy.read()
        }
      }
    }
  }

  /// 建连前安装下行屏障；早到数据可接在它之后，本地成功回复本身不能等待业务链。
  func startDownstream(after ready: EventLoopFuture<Void>) {
    let context = transferContext()
    let eventLoop = context.proxy.eventLoop
    eventLoop.preconditionInEventLoop()
    guard !context.isClosed else { return }
    precondition(ready.eventLoop === eventLoop)
    downstreamTransfer = ready

    ready.whenComplete { [weak self] result in
      switch result {
      case .failure(let error):
        guard let self, !self.transferContext().isClosed else { return }
        self.finishTransfer(error: error)
      case .success:
        eventLoop.execute { [weak self] in
          guard let self else { return }
          let context = self.transferContext()
          guard !context.isClosed, self.downstreamTransfer === ready else { return }
          self.downstreamTransfer = nil
          guard !self.downstreamInputClosed else { return }
          guard let wire = context.wire else {
            self.finishTransfer(error: MagentError.connectionClosed)
            return
          }
          wire.read()
        }
      }
    }
  }

  /// 非 nil 同步提交上行；nil 表示全部先到字节之后的真实 EOF，空缓冲不代表 EOF。
  /// 返回值只等待本方向排空；单向 FIN 和双向结束在局部回调中协调，不进入成员 Future。
  func transferUpstream(_ data: ByteBuffer?) -> EventLoopFuture<Void> {
    let context = transferContext()
    let eventLoop = context.proxy.eventLoop
    eventLoop.preconditionInEventLoop()
    guard !context.isClosed else { return eventLoop.makeFailedFuture(MagentError.connectionClosed) }
    if upstreamInputClosed {
      return data == nil
        ? upstreamTransfer ?? eventLoop.makeSucceededFuture(())
        : eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }

    guard let data else {
      upstreamInputClosed = true
      let drained = upstreamTransfer ?? eventLoop.makeSucceededFuture(())
      // 排空后才读取对向的最新 EOF，避免等待尾写期间对向也结束而沿用旧判断。
      drained.whenComplete { [weak self] result in
        guard let self else { return }
        let context = self.transferContext()
        guard !context.isClosed else { return }
        switch result {
        case .failure(let error):
          self.finishTransfer(error: error)
        case .success:
          if self.downstreamInputClosed {
            let reverse = self.downstreamTransfer ?? context.proxy.eventLoop.makeSucceededFuture(())
            reverse.whenComplete { [weak self] result in
              guard let self, !self.transferContext().isClosed else { return }
              switch result {
              case .success: self.finishTransfer(error: nil)
              case .failure(let error): self.finishTransfer(error: error)
              }
            }
          } else {
            guard let wire = context.wire else {
              self.finishTransfer(error: MagentError.connectionClosed)
              return
            }
            // 当前回调内直接发送单向 FIN，不等待尚未发生的对向 EOF。
            wire.close(mode: .output).whenFailure { [weak self] error in
              guard let self, !self.transferContext().isClosed else { return }
              self.finishTransfer(error: error)
            }
          }
        }
      }
      return drained
    }

    let previous = upstreamTransfer ?? eventLoop.makeSucceededFuture(())
    let batch = eventLoop.makePromise(of: Void.self)
    let drained = batch.futureResult
    // 先登记再提交，任何同步完成和可重入 I/O 都必须看见包含本批的新屏障。
    upstreamTransfer = drained
    drained.whenComplete { [weak self] result in
      switch result {
      case .failure(let error):
        guard let self, !self.transferContext().isClosed else { return }
        self.finishTransfer(error: error)
      case .success:
        eventLoop.execute { [weak self] in
          guard let self else { return }
          let context = self.transferContext()
          guard !context.isClosed, self.upstreamTransfer === drained else { return }
          self.upstreamTransfer = nil
          guard !self.upstreamInputClosed else { return }
          context.proxy.read()
        }
      }
    }
    // accepted 可能在随后 FIN 时直接 inactive；合法上行必须已提交给 NIO，不能排队补写。
    let written = writeUpstream(data)
    previous.and(written).map { _ in () }.cascade(to: batch)
    return drained
  }

  /// 非 nil 等待启动屏障及前批后交付下行；nil 把一次尾校验追加到全部已接收数据之后。
  /// HTTP forward 仅复用非 nil 数据入口，其有限请求/响应结束不使用这里的双向 EOF 流程。
  func transferDownstream(_ data: ByteBuffer?) -> EventLoopFuture<Void> {
    let context = transferContext()
    let eventLoop = context.proxy.eventLoop
    eventLoop.preconditionInEventLoop()
    guard !context.isClosed else { return eventLoop.makeFailedFuture(MagentError.connectionClosed) }
    if downstreamInputClosed {
      return data == nil
        ? downstreamTransfer ?? eventLoop.makeSucceededFuture(())
        : eventLoop.makeFailedFuture(MagentError.connectionClosed)
    }

    let isInputClosed = data == nil
    if isInputClosed { downstreamInputClosed = true }
    let previous = downstreamTransfer ?? eventLoop.makeSucceededFuture(())
    let batch = eventLoop.makePromise(of: Void.self)
    let drained = batch.futureResult
    // EOF 的校验完成口也先登记；对向观察到 EOF 时必须同时看见完整下行屏障。
    downstreamTransfer = drained
    drained.whenComplete { [weak self] result in
      switch result {
      case .failure(let error):
        guard let self, !self.transferContext().isClosed else { return }
        self.finishTransfer(error: error)
      case .success:
        eventLoop.execute { [weak self] in
          guard let self else { return }
          let context = self.transferContext()
          guard !context.isClosed, self.downstreamTransfer === drained else { return }
          self.downstreamTransfer = nil
          guard !self.downstreamInputClosed else { return }
          guard let wire = context.wire else {
            self.finishTransfer(error: MagentError.connectionClosed)
            return
          }
          wire.read()
        }

        guard isInputClosed, let self else { return }
        let context = self.transferContext()
        guard !context.isClosed else { return }
        // 这里只等待反向数据屏障，绝不将本段 FIN 协调写回任一方向，避免双方互等。
        if self.upstreamInputClosed {
          let reverse = self.upstreamTransfer ?? context.proxy.eventLoop.makeSucceededFuture(())
          reverse.whenComplete { [weak self] result in
            guard let self, !self.transferContext().isClosed else { return }
            switch result {
            case .success: self.finishTransfer(error: nil)
            case .failure(let error): self.finishTransfer(error: error)
            }
          }
        } else {
          context.proxy.close(mode: .output).whenFailure { [weak self] error in
            guard let self, !self.transferContext().isClosed else { return }
            self.finishTransfer(error: error)
          }
        }
      }
    }

    // 数据与尾校验都按前驱顺序执行；原前驱错误优先于 owner 消失或终态的关闭错误。
    previous.whenComplete { [weak self] result in
      switch result {
      case .failure(let error):
        batch.fail(error)
      case .success:
        guard let self, !self.transferContext().isClosed else {
          batch.fail(MagentError.connectionClosed)
          return
        }
        // 此批可能在 EOF 前合法登记，不能再次用输入 EOF 拒绝它；nil 只执行尾校验。
        self.writeDownstream(data).cascade(to: batch)
      }
    }
    return drained
  }
}
