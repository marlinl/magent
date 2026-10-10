//
//  Wire.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import Foundation
import NIOCore

/// Wire 解码后的业务字节及逻辑来源，不携带连接状态或需要反向发送的控制字节。
internal struct InboundData {
  /// 解码后的明文数据。
  let data: Data

  /// 这段数据对应的远端地址。
  let address: NetworkAddress
}

/// 出站 Wire 协议的握手与双向编解码接口。
///
/// TCP 实例由单条 Connection 独占，在所属 EventLoop 上串行使用；UDP 仅在逐包独立且
/// 并发安全时共享。Wire 不拥有 Channel，不访问 DNS，不发送本地回复，也不自行执行网络 I/O。
/// 所有同步操作的错误原样交给 Connection；独立 UDP 编解码失败只拒绝当前包。
///
/// TODO(refactor): 本轮仅迁移抽象接口；具体后端随后实现 getEndpoint / finishInbound 及
/// Wire SPEC 的输入输出上限。这里不提供兼容 getter 或默认 EOF 实现来掩盖未完成的校验。
internal protocol Wire: AnyObject {

  /// 实际节点端点，保留地址族和 IPv6 作用域；不是客户端请求的业务目标。
  /// 同一实例内稳定，读取不进行名称解析。
  func getEndpoint() -> SocketAddress

  /// 连接节点的正整数毫秒超时；不代表会话时长或 UDP 响应期限。
  func getTimeout() -> Int64

  /// 固定本 TCP 连接的业务目标，返回直接写入节点的启动字节；无需发送时返回 nil。
  /// 启动字节不得再经过 encodeOutbound。UDP 路径不依赖启动，调用时返回 nil。
  func start(handshake target: NetworkAddress) throws -> Data?

  /// 编码业务字节，返回由 Connection 直接写下游的全部编码输出。
  ///
  /// TCP 使用启动时固定的目标，address 必须为 nil；空输入不推进流状态。
  /// UDP 每次传入本包的业务目标，空载荷仍是有效数据报；不拆包、不保留跨包状态。
  func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data

  /// 解码节点输入，只返回已经验证的业务字节与逻辑来源。
  ///
  /// TCP 空 data 表示尚无完整业务字节，不是 EOF；不完整编码只保存在实现的有界缓冲中。
  /// UDP 输入是一整个后端包，失败后仍须能够独立处理下一包。
  func decodeInbound(_ bytes: Data) throws -> InboundData

  /// 正常输入确实结束时验证 TCP 编码是否截断，不关闭 Channel 或结束反向发送。
  /// 网络错误和取消不借此覆盖首因；UDP 无跨包残留，实现为无副作用的空操作。
  func finishInbound() throws
}
