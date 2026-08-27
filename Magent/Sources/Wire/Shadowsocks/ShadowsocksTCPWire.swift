//
//  ShadowsocksTCPWire.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation
import NIOCore

// MARK: - ShadowsocksTCPWire

/// Shadowsocks AEAD TCP 节点协议编解码状态机。
///
/// 本类型不持有 channel，不解析 SOCKS/HTTP，只负责：
/// - `start(handshake:)`: 生成 SS TCP 启动字节 `[salt + AEAD(ATYP + ADDR + PORT)]`
/// - `encodeOutbound`: 把 stream plaintext 编码成 SS AEAD frames
/// - `decodeInbound`: 缓存并解码来自 SS server 的 AEAD stream
internal final class ShadowsocksTCPWire: Wire {

    /// 建立下游 Channel 时实际连接的 Shadowsocks 节点地址。
    private let proxyAddress: SocketAddress

    /// 连接 Shadowsocks 节点的超时时间，单位为毫秒。
    private let timeout: Int64

    /// Shadowsocks AEAD 加密方法。
    private let method: ProxyCipher

    /// 由节点密码派生出的 master key。
    private let masterKey: Data

    /// client -> server 方向的连接 salt，只在 TCP 启动帧发送一次。
    private let clientSalt: Data

    /// client -> server 方向的 AEAD frame 加密器。
    private let encCipher: AeadCipher

    /// 是否已经发送过 Shadowsocks TCP 启动帧。
    private var started = false

    /// 当前 TCP stream 在 `start(handshake:)` 中确定的最终目标地址。
    private var destinationAddress: NetworkAddress?

    /// server -> client 方向的 AEAD frame 解密器，收到 server salt 后创建。
    private var decCipher: AeadCipher?

    /// 尚未解出完整 frame 的 server stream 缓冲区。
    private var decBuffer = Data()

    /// `decBuffer` 中尚未消费数据的起始位置，避免每解出一个 frame 都移动剩余字节。
    private var decBufferIndex = 0

    /// 当前解码状态：先读加密长度，再读加密 payload。
    private var decState: DecState = .waitingLength

    /// 当前 payload frame 的明文长度。
    private var expectedPayloadLength = 0

    /// Shadowsocks TCP AEAD frame 解码阶段。
    private enum DecState {
        /// 等待 `2-byte length + tag` frame。
        case waitingLength

        /// 等待 `payload + tag` frame。
        case waitingPayload
    }

    /// 使用代理节点配置创建 TCP wire，并初始化 client 加密方向。
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

        let salt = randomBytes(count: proxyNode.cipher.saltSize)
        self.clientSalt = salt

        let subkey = deriveSubkey(
            key: masterKey,
            salt: salt,
            outputLength: proxyNode.cipher.keySize
        )
        self.encCipher = try AeadCipher(cipher: proxyNode.cipher, key: subkey)
    }

    /// 生成 TCP 连接启动帧。
    ///
    /// 返回 `[client salt] + AEAD frames(ATYP | ADDR | PORT)`；重复调用返回空 `Data`。
    internal func start(handshake address: NetworkAddress) throws -> Data? {
        guard !started else { return Data() }

        let addressBytes = try address.shadowsocksAddressBytes()
        var output = clientSalt
        output.append(try encryptFrames(addressBytes))
        destinationAddress = address
        started = true
        return output
    }

    /// 返回建立下游 Channel 时使用的 Shadowsocks 节点地址。
    internal func getTargetAddress() -> SocketAddress {
        proxyAddress
    }

    /// 返回连接 Shadowsocks 节点的超时时间，单位为毫秒。
    internal func getTimeout() -> Int64 {
        timeout
    }

    /// 把后续 TCP 明文 payload 编码成 Shadowsocks AEAD frames。
    internal func encodeOutbound(_ data: Data, address _: NetworkAddress?) throws -> Data {
        guard started else {
            throw MagentError.invalidOptions("Shadowsocks TCP wire must be started before encoding data")
        }
        return try encryptFrames(data)
    }

    /// 增量解码 server stream。
    ///
    /// 首次收到数据时先读取 server salt 建立解密器，之后按 frame 状态机解密可用明文。
    internal func decodeInbound(_ bytes: Data) throws -> InboundData {
        guard let destinationAddress else {
            throw MagentError.invalidOptions("Shadowsocks TCP wire must be started before decoding data")
        }
        guard !bytes.isEmpty else {
            return InboundData(data: Data(), address: destinationAddress)
        }
        decBuffer.append(bytes)
        defer { compactDecBuffer() }

        if decCipher == nil {
            guard decReadableBytes >= method.saltSize else {
                return InboundData(data: Data(), address: destinationAddress)
            }

            let serverSalt = readDecBytes(method.saltSize)
            let subkey = deriveSubkey(
                key: masterKey,
                salt: serverSalt,
                outputLength: method.keySize
            )
            decCipher = try AeadCipher(cipher: method, key: subkey)
        }

        return InboundData(data: try decryptAvailableFrames(), address: destinationAddress)
    }

    /// 把一段明文切成 Shadowsocks TCP AEAD frame。
    ///
    /// 每个 chunk 最大 0x3FFF 字节；每个 chunk 先加密 2 字节长度，再加密 payload。
    private func encryptFrames(_ plaintext: Data) throws -> Data {
        guard !plaintext.isEmpty else { return Data() }

        let maxChunkSize = 0x3FFF
        var output = Data()
        var offset = 0

        while offset < plaintext.count {
            let chunkSize = Swift.min(maxChunkSize, plaintext.count - offset)
            let chunk = Data(plaintext[offset..<(offset + chunkSize)])

            var lengthBytes = Data(count: 2)
            lengthBytes[0] = UInt8(chunkSize >> 8)
            lengthBytes[1] = UInt8(chunkSize & 0xFF)

            output.append(try encCipher.encrypt(lengthBytes))
            output.append(try encCipher.encrypt(chunk))
            offset += chunkSize
        }

        return output
    }

    /// 从 `decBuffer` 中尽可能多地解出完整 frame。
    ///
    /// 如果只解到部分 frame，保留剩余 bytes 并返回当前已完成的明文。
    private func decryptAvailableFrames() throws -> Data {
        var output = Data()
        let tagSize = method.tagSize

        while true {
            switch decState {
            case .waitingLength:
                let lengthFrameSize = 2 + tagSize
                guard decReadableBytes >= lengthFrameSize else {
                    return output
                }

                let encryptedLength = readDecBytes(lengthFrameSize)

                guard let decCipher else {
                    throw MagentError.cryptoError(type: "decryptCipherNotInitialized")
                }
                let lengthPlaintext = try decCipher.decrypt(encryptedLength)
                expectedPayloadLength = Int(lengthPlaintext[0]) << 8 | Int(lengthPlaintext[1])
                guard expectedPayloadLength <= 0x3FFF else {
                    throw MagentError.malformedRequest(
                        "payload length \(expectedPayloadLength) exceeds max 16383"
                    )
                }
                decState = .waitingPayload

            case .waitingPayload:
                let payloadFrameSize = expectedPayloadLength + tagSize
                guard decReadableBytes >= payloadFrameSize else {
                    return output
                }

                let encryptedPayload = readDecBytes(payloadFrameSize)

                guard let decCipher else {
                    throw MagentError.cryptoError(type: "decryptCipherNotInitialized")
                }
                let payload = try decCipher.decrypt(encryptedPayload)
                output.append(payload)
                decState = .waitingLength
            }
        }
    }

    /// `decBuffer` 中尚未消费的字节数。
    private var decReadableBytes: Int {
        decBuffer.count - decBufferIndex
    }

    /// 从当前读取位置复制指定数量的密文字节，并向后推进读取位置。
    private func readDecBytes(_ count: Int) -> Data {
        precondition(count >= 0 && count <= decReadableBytes, "Shadowsocks TCP decode buffer underflow")
        let endIndex = decBufferIndex + count
        let bytes = Data(decBuffer[decBufferIndex..<endIndex])
        decBufferIndex = endIndex
        return bytes
    }

    /// 一次 decode 结束后统一移除已消费前缀，避免每个 frame 都触发 Data 搬移。
    private func compactDecBuffer() {
        guard decBufferIndex > 0 else { return }

        if decBufferIndex == decBuffer.count {
            decBuffer.removeAll(keepingCapacity: true)
        } else {
            decBuffer = Data(decBuffer.dropFirst(decBufferIndex))
        }
        decBufferIndex = 0
    }
}
