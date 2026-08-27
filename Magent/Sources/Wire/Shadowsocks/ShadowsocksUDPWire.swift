import Foundation
import NIOCore

// MARK: - ShadowsocksUDPWire

/// Shadowsocks AEAD UDP 节点协议编解码状态机。
///
/// UDP 无 stream handshake，每个 packet 都是独立的 `[salt + AEAD(ATYP + ADDR + PORT + payload)]`。
internal final class ShadowsocksUDPWire: Wire {

    /// 发送 Shadowsocks UDP packet 时使用的代理节点地址。
    private let proxyAddress: SocketAddress

    /// 当前代理节点配置的超时时间，单位为毫秒。
    private let timeout: Int64

    /// Shadowsocks AEAD 加密方法。
    private let method: ProxyCipher

    /// 由节点密码派生出的 master key。
    private let masterKey: Data

    /// 使用代理节点配置创建 UDP wire。
    internal init(proxyNode: ProxyNode) throws {
        let timeoutMilliseconds = (proxyNode.timeout * 1_000).rounded(.up)
        guard timeoutMilliseconds >= 1, timeoutMilliseconds < Double(Int64.max) else {
            throw MagentError.invalidPolicy("proxy node timeout must fit positive Int64 milliseconds")
        }
        self.proxyAddress = proxyNode.address
        self.timeout = Int64(timeoutMilliseconds)
        self.method = proxyNode.cipher
        self.masterKey = passwordToKey(
            password: proxyNode.password,
            keyLength: proxyNode.cipher.keySize
        )
    }

    /// UDP wire 没有连接级启动帧。
    internal func start(handshake _: NetworkAddress) throws -> Data? {
        nil
    }

    /// 返回发送 Shadowsocks UDP packet 时使用的代理节点地址。
    internal func getTargetAddress() -> SocketAddress {
        proxyAddress
    }

    /// 返回当前代理节点配置的动态超时时间，单位为毫秒。
    internal func getTimeout() -> Int64 {
        timeout
    }

    /// 把单个 UDP payload 编码成 Shadowsocks UDP packet。
    internal func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data {
        guard let address else {
            throw MagentError.invalidAddress("UDP outbound target is missing")
        }
        return try encodeDatagram(data, target: address)
    }

    /// 解码单个 Shadowsocks UDP packet。
    internal func decodeInbound(_ bytes: Data) throws -> InboundData {
        try decodeDatagram(bytes)
    }

    /// 构造 `ATYP | ADDR | PORT | payload` 明文并加密为 UDP packet。
    private func encodeDatagram(_ payload: Data, target: NetworkAddress) throws -> Data {
        var plaintext = try target.shadowsocksAddressBytes()
        plaintext.append(payload)
        return try encryptPacket(plaintext)
    }

    /// 解密 UDP packet，并把 Shadowsocks 地址头还原为入站 source。
    private func decodeDatagram(_ bytes: Data) throws -> InboundData {
        guard !bytes.isEmpty else {
            throw MagentError.malformedRequest("Shadowsocks UDP packet is empty")
        }

        let plaintext = try decryptPacket(bytes)
        let (address, consumed) = try NetworkAddress.decodeShadowsocksAddress(from: plaintext)
        return InboundData(data: Data(plaintext.dropFirst(consumed)), address: address)
    }

    /// 使用独立随机 salt 加密一个 UDP packet。
    private func encryptPacket(_ plaintext: Data) throws -> Data {
        let salt = randomBytes(count: method.saltSize)
        let subkey = deriveSubkey(
            key: masterKey,
            salt: salt,
            outputLength: method.keySize
        )
        let cipher = try AeadCipher(cipher: method, key: subkey)
        var output = salt
        output.append(try cipher.encrypt(plaintext))
        return output
    }

    /// 使用 packet 前缀 salt 派生 subkey 并解密。
    private func decryptPacket(_ packet: Data) throws -> Data {
        guard packet.count >= method.saltSize + method.tagSize + 1 else {
            throw MagentError.malformedRequest("UDP packet too short (\(packet.count))")
        }

        let salt = Data(packet.prefix(method.saltSize))
        let ciphertext = Data(packet.dropFirst(method.saltSize))
        let subkey = deriveSubkey(
            key: masterKey,
            salt: salt,
            outputLength: method.keySize
        )
        let cipher = try AeadCipher(cipher: method, key: subkey)
        return try cipher.decrypt(ciphertext)
    }
}
