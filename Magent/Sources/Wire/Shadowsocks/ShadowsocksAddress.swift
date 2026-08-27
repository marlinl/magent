import Foundation

// MARK: - Shadowsocks Address

extension NetworkAddress {
    /// 编码成 Shadowsocks 地址头 `ATYP | ADDR | PORT`。
    internal func shadowsocksAddressBytes() throws -> Data {
        guard let encodedPort = UInt16(exactly: port) else {
            throw MagentError.invalidAddress("port out of range")
        }

        switch self {
        case .ipv4(let raw, _):
            guard raw.count == 4 else {
                throw MagentError.malformedRequest("IPv4 address must contain 4 bytes")
            }
            var output = Data([0x01])
            output.append(raw)
            output.append(UInt8(encodedPort >> 8))
            output.append(UInt8(encodedPort & 0xFF))
            return output

        case .ipv6(let raw, _):
            guard raw.count == 16 else {
                throw MagentError.malformedRequest("IPv6 address must contain 16 bytes")
            }
            var output = Data([0x04])
            output.append(raw)
            output.append(UInt8(encodedPort >> 8))
            output.append(UInt8(encodedPort & 0xFF))
            return output

        case .domain(let name, _):
            let nameBytes = Data(name.utf8)
            guard !name.isEmpty else {
                throw MagentError.malformedRequest("Domain address is empty")
            }
            guard nameBytes.count <= 255 else {
                throw MagentError.malformedRequest("Domain address is too long")
            }
            var output = Data([0x03, UInt8(nameBytes.count)])
            output.append(nameBytes)
            output.append(UInt8(encodedPort >> 8))
            output.append(UInt8(encodedPort & 0xFF))
            return output
        }
    }

    /// 从 Shadowsocks 地址头解出地址，并返回已消费的字节数。
    internal static func decodeShadowsocksAddress(from data: Data) throws -> (NetworkAddress, Int) {
        guard data.isEmpty == false else {
            throw MagentError.malformedRequest("Shadowsocks address is empty")
        }

        switch data[0] {
        case 0x01:
            guard data.count >= 7 else {
                throw MagentError.malformedRequest("truncated IPv4 address")
            }
            let address = Data(data[1..<5])
            let port = (Int(data[5]) << 8) | Int(data[6])
            return (.ipv4(address, port: port), 7)

        case 0x04:
            guard data.count >= 19 else {
                throw MagentError.malformedRequest("truncated IPv6 address")
            }
            let address = Data(data[1..<17])
            let port = (Int(data[17]) << 8) | Int(data[18])
            return (.ipv6(address, port: port), 19)

        case 0x03:
            guard data.count >= 2 else {
                throw MagentError.malformedRequest("truncated domain address")
            }
            let length = Int(data[1])
            let addressStart = 2
            let addressEnd = addressStart + length
            let portStart = addressEnd
            guard data.count >= portStart + 2 else {
                throw MagentError.malformedRequest("truncated domain address")
            }
            guard let host = String(data: data[addressStart..<addressEnd], encoding: .utf8),
                  host.isEmpty == false
            else {
                throw MagentError.malformedRequest("invalid domain address")
            }
            let port = (Int(data[portStart]) << 8) | Int(data[portStart + 1])
            return (.domain(host, port: port), portStart + 2)

        default:
            let addressType = String(format: "0x%02X", data[0])
            throw MagentError.invalidAddress("unsupported Shadowsocks address type \(addressType)")
        }
    }
}
