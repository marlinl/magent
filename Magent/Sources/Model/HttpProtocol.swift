import Foundation
import NIOCore

/// HTTP CONNECT 的请求语义和本地响应。
///
/// HTTP request-line 与 headers 的语法解析由 NIOHTTP1 负责；这里不再维护第二套 HTTP parser。
internal struct HttpProtocol {
    internal let address: NetworkAddress
    internal let version: String
    internal let headers: [(name: String, value: String)]

    /// 校验 CONNECT 支持的 HTTP 版本及 Host 与 request-target 的一致性。
    internal func checkConnect() throws {
        guard version == "HTTP/1.0" || version == "HTTP/1.1" else {
            throw MagentError.malformedRequest("HTTP CONNECT version is not supported")
        }

        let hostHeaders = headers.filter { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        if version == "HTTP/1.1" {
            guard hostHeaders.count == 1 else {
                throw MagentError.malformedRequest("HTTP CONNECT request must contain exactly one Host header")
            }
        } else {
            guard hostHeaders.count <= 1 else {
                throw MagentError.malformedRequest("HTTP CONNECT request has multiple Host headers")
            }
        }

        if let host = hostHeaders.first?.value {
            guard !host.isEmpty else {
                throw MagentError.malformedRequest("HTTP CONNECT Host header is empty")
            }
            let hostAddress = try Self.parseAuthority(host)
            guard hostAddress.port == address.port,
                  hostAddress.host.caseInsensitiveCompare(address.host) == .orderedSame else {
                throw MagentError.malformedRequest("HTTP CONNECT Host does not match request-target")
            }
        }
    }

    /// 解析 CONNECT authority-form。
    internal static func parseAuthority(_ authority: String) throws -> NetworkAddress {
        let host: String
        let portText: String

        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]"),
                  authority.index(after: end) < authority.endIndex,
                  authority[authority.index(after: end)] == ":" else {
                throw MagentError.invalidAddress("invalid HTTP CONNECT IPv6 authority")
            }
            host = String(authority[authority.index(after: authority.startIndex)..<end])
            portText = String(authority[authority.index(end, offsetBy: 2)...])
        } else {
            guard let colon = authority.lastIndex(of: ":"), authority[..<colon].contains(":") == false else {
                throw MagentError.invalidAddress("invalid HTTP CONNECT authority")
            }
            host = String(authority[..<colon])
            portText = String(authority[authority.index(after: colon)...])
        }

        let portBytes = portText.utf8
        guard !host.isEmpty,
              !portBytes.isEmpty,
              portBytes.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText),
              (1...65535).contains(port) else {
            throw MagentError.invalidAddress("invalid HTTP CONNECT authority")
        }

        if let socketAddress = try? SocketAddress(ipAddress: host, port: port),
           let address = NetworkAddress(socketAddress) {
            if authority.hasPrefix("["), case .ipv6 = address {
                return address
            }
            if !authority.hasPrefix("["), case .ipv4 = address {
                return address
            }
        }
        guard !authority.hasPrefix("[") else {
            throw MagentError.invalidAddress("invalid HTTP CONNECT IPv6 authority")
        }
        return .domain(host, port: port)
    }
    static let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    static let badRequest = Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8)
    static let badGateway = Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8)
    static let gatewayTimeout = Data("HTTP/1.1 504 Gateway Timeout\r\nConnection: close\r\n\r\n".utf8)
}
