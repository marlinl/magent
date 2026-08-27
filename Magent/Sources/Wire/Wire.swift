//
//  Wire.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import Foundation
import NIOCore

/// Wire 协议解码后交回 Connection 的入站数据。
internal struct InboundData {
    /// 解码后的明文数据。
    internal let data: Data

    /// 这段数据对应的远端地址。
    internal let address: NetworkAddress
}

/// 出站 Wire 协议的握手与双向编解码接口。
///
/// Wire 不持有 Channel，由 Connection 在所属 EventLoop 上按顺序调用。
internal protocol Wire {

    /// channel 建立后需要先发给出站节点的启动字节。
    ///
    /// `address` 是本次握手的目标地址，包含 host / port。
    /// 对不需要启动帧的协议，可以忽略该参数并返回空 `Data`。
    ///
    /// Shadowsocks TCP 会在这里生成 `[salt + AEAD(ATYP + ADDR + PORT)]`。
    /// 不需要启动帧的协议返回空 `Data`。
    func start(handshake address: NetworkAddress) throws -> Data?

    /// 返回当前 Wire 对应的代理节点地址，用于发送编码后的出站数据。
    func getTargetAddress() -> SocketAddress

    /// 返回当前 Wire 对应代理节点的动态连接超时时间，单位为毫秒。
    func getTimeout() -> Int64

    /// 编码一段出站请求，返回可直接写入 channel 的出站协议字节。
    ///
    /// `data` 是待编码的明文数据。
    /// `address` 是这段数据的目标地址；TCP 后续 payload 可为空。
    func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data

    /// 解码从 channel 收到的 Wire 协议字节，返回明文和对应的远端地址。
    ///
    /// 流式协议可以内部缓存半帧。
    func decodeInbound(_ bytes: Data) throws -> InboundData
}
