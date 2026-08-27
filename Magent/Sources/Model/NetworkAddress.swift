//
//  NetworkAddress.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation

import NIOCore

/// SOCKS 协议端口字段使用 network byte order，即 big-endian。
internal extension UInt16 {
    var bigEndianBytes: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

/// 读取 SOCKS 地址中的 2 字节网络序端口；调用方先完成边界检查。
internal extension Data {
    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}

// MARK: - NetworkAddress

/// 网络地址。
///
/// 这是 Transport、Core、Wire 共享的地址表示，不属于 HTTP/SOCKS，
/// 也不属于某个具体节点协议。出站请求和 UDP 入站响应都可以携带它。
public enum NetworkAddress: Sendable, Equatable, Hashable, Codable {
    /// IPv4 地址。
    ///
    /// `Data` 必须是 4 字节，`port` 通常使用 `1...65535`；绑定时 `0` 表示由系统分配端口。
    case ipv4(Data, port: Int)

    /// IPv6 地址。
    ///
    /// `Data` 必须是 16 字节，`port` 使用普通网络端口范围 `1...65535`。
    case ipv6(Data, port: Int)

    /// 域名地址。
    ///
    /// 具体节点协议决定是否远端解析域名。
    case domain(String, port: Int)

    /// IPv4 未指定地址和系统分配端口，用于绑定 `0.0.0.0:0`。
    public static let unspecifiedIPv4 = Self.ipv4(Data(repeating: 0, count: 4), port: 0)

    /// 可展示或用于建立连接的 host 字符串。
    public var host: String {
        switch self {
        case .ipv4(let data, _):
            return data.map(String.init).joined(separator: ".")

        case .ipv6(let data, _):
            guard data.count == 16 else { return "" }
            return stride(from: 0, to: 16, by: 2)
                .map { index in
                    let high = UInt16(data[index]) << 8
                    let low = UInt16(data[index + 1])
                    return String(format: "%x", high | low)
                }
                .joined(separator: ":")

        case .domain(let host, _):
            return host
        }
    }

    /// 网络端口。
    public var port: Int {
        switch self {
        case let .ipv4(_, port),
             let .ipv6(_, port),
             let .domain(_, port):
            return port
        }
    }

    /// 从 NIO `SocketAddress` 构造。
    ///
    /// `SocketAddress.IPv4Address.address` 是 `sockaddr_in`，IP 在 `.sin_addr`；IPv6 在
    /// `sockaddr_in6.sin6_addr`。两者在内存里都是网络序字节，`withUnsafeBytes` 直接取
    /// 原始字节，不依赖宿主机字节序。端口取 `SocketAddress.port`（`Int?`）。
    /// unix domain socket 没有 IP 表示，返回 nil。
    internal init?(_ address: SocketAddress) {
        let port = address.port ?? 0
        switch address {
        case .v4(let ipv4):
            let bytes = withUnsafeBytes(of: ipv4.address.sin_addr) { Data($0) }
            self = .ipv4(bytes, port: port)

        case .v6(let ipv6):
            let bytes = withUnsafeBytes(of: ipv6.address.sin6_addr) { Data($0) }
            self = .ipv6(bytes, port: port)

        case .unixDomainSocket:
            return nil
        }
    }

    /// 构造 NIO 可写入的 socket address。
    internal func socketAddress() throws -> SocketAddress {
        switch self {
        case .ipv4, .ipv6:
            return try SocketAddress(ipAddress: host, port: port)
        case .domain(let host, let port):
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }
}
