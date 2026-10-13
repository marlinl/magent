//
//  ProxyConnection.swift
//  Magent
//

import NIOCore

/// 主连接识别本地代理协议后创建的具体代理连接。
///
/// 每个实现对应一种已经确定的本地代理协议，例如 SOCKS4。`MagentTCPConnection` 持有当前
/// `ProxyConnection`，并把 server channel 收到的完整首包以及后续数据持续交给它。
///
/// `ProxyConnection` 负责接管协议识别之后的业务，包括解析本地代理请求、创建并持有
/// wire channel、把 server channel 数据转换后写入 wire channel，以及把 wire channel
/// 返回的数据转换后写回 server channel。它同时维护具体协议连接的状态和生命周期，
/// 并在 server channel 断开或连接发生错误时释放对应的 wire 资源。
///
/// 该协议描述的是完整的代理连接职责，不只是 NIO handler。具体实现可以同时作为 wire
/// channel 的 handler，但 handler 只是其接收 wire 数据的一种方式。
internal protocol ProxyConnection: AnyObject {
  /// 接收 server channel 的下一段数据。
  ///
  /// 第一次调用包含 `MagentTCPConnection` 在探测阶段累计的完整数据；后续调用包含同一条
  /// server channel 上继续收到的数据。具体实现负责根据自己的协议状态判断数据属于
  /// 握手请求还是已经建立连接后的转发 payload。使用手动读取的实现还负责在当前批次
  /// 消费完成后发起下一次读取。
  func upstream(context: ChannelHandlerContext, data: NIOAny)

  /// 上游 `MagentTCPConnection` 关闭具体代理连接持有的下游 channel、任务和协议状态。
  ///
  /// 此方法只供 `MagentTCPConnection` 在 accepted proxy channel 结束或出错时调用。
  /// 具体协议连接不得用它执行自我关闭，也不得在此关闭 accepted proxy channel。
  /// `error` 为空表示 accepted channel 正常结束，非空时保留原始错误。
  /// 此入口不发送协议回复，也不反向上报错误，避免清理重新进入主连接。
  func closeConnection(error: Error?)

  /// accepted proxy channel 的输入方向已经关闭。
  ///
  /// 具体协议决定截断检查、TCP 半关闭、HTTP 请求/响应排空或 SOCKS5 UDP 关联结束。
  /// 各具体类必须自行实现，不能用默认完整关闭覆盖其 EOF 语义。
  func proxyInputClosed(context: ChannelHandlerContext)
}
