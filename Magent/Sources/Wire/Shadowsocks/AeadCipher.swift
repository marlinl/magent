import Foundation
import Crypto

// MARK: - AeadCipher

/// AEAD 加密器，对应 Shadowsocks 流式会话的**单一方向**。
///
/// 一个实例只负责一个方向（encrypt 或 decrypt），内部维护单调递增的 nonce 计数器。
/// 每次 encrypt/decrypt 调用都会让 nonce 自增 1（小端计数器），符合 SS AEAD 协议要求。
///
/// **线程安全契约**：本类型包含可变 nonce，不符合 `Sendable`。
/// 调用方必须串行化对同一实例的 encrypt/decrypt 调用；并发调用会导致 nonce
/// 推进顺序未定义、AEAD 解密失败或密文碰撞。
/// TCP Wire 由所属 Connection 的 EventLoop 串行调用。
///
/// 加密方法由 `ProxyCipher` 决定，密钥长度必须与 `cipher.keySize` 严格匹配。
/// 支持的算法：AES-128-GCM / AES-256-GCM / ChaCha20-IETF-Poly1305 / XChaCha20-IETF-Poly1305。
///
/// 返回格式：`ciphertext || tag`（不含 nonce 前缀，nonce 由调用方按 SS 协议单独传输）。
internal final class AeadCipher {

    /// 具体 AEAD 算法。
    private let cipher: ProxyCipher

    /// 当前方向使用的 subkey。
    private let key: Data

    /// 当前方向的 nonce 计数器。
    private var nonce: [UInt8]

    /// 用 subkey 构造一个方向的 cipher，nonce 从全零开始。
    internal init(cipher: ProxyCipher, key: Data, nonce: Data? = nil) throws {
        guard key.count == cipher.keySize else {
            throw MagentError.cryptoError(type: "invalidKeyLength", expected: cipher.keySize, actual: key.count)
        }
        if let nonce, nonce.count != cipher.nonceSize {
            throw MagentError.cryptoError(type: "invalidIVLength", expected: cipher.nonceSize, actual: nonce.count)
        }
        self.cipher = cipher
        self.key = key
        self.nonce = nonce.map { [UInt8]($0) } ?? [UInt8](repeating: 0, count: cipher.nonceSize)
    }

    /// 加密，返回 `ciphertext || tag`。调用后 nonce 自增 1。
    internal func encrypt(_ plaintext: Data, authenticating aad: Data = Data()) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let nonceData = Data(nonce)
        defer { incrementNonce() }

        do {
            switch cipher {
            case .aes128Gcm, .aes256Gcm:
                let n = try AES.GCM.Nonce(data: nonceData)
                let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: n, authenticating: aad)
                return Data(sealed.combined!.dropFirst(12))
            case .chacha20IetfPoly1305:
                let n = try ChaChaPoly.Nonce(data: nonceData)
                let sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: n, authenticating: aad)
                return Data(sealed.combined.dropFirst(12))
            case .xchacha20IetfPoly1305:
                return try sealXChaCha20(plaintext: plaintext, nonce: nonceData, authenticating: aad)
            }
        } catch {
            throw MagentError.cryptoError(type: "encryptionFailed", underlying: error)
        }
    }

    /// 解密 `ciphertext || tag`。调用后 nonce 自增 1。
    internal func decrypt(_ ciphertext: Data, authenticating aad: Data = Data()) throws -> Data {
        guard ciphertext.count > cipher.tagSize else {
            throw MagentError.cryptoError(
                type: "bufferTooSmall",
                expected: cipher.tagSize + 1,
                actual: ciphertext.count
            )
        }
        let symKey = SymmetricKey(data: key)
        let nonceData = Data(nonce)
        defer { incrementNonce() }

        do {
            switch cipher {
            case .aes128Gcm, .aes256Gcm:
                let box = try AES.GCM.SealedBox(combined: nonceData + ciphertext)
                return try AES.GCM.open(box, using: symKey, authenticating: aad)
            case .chacha20IetfPoly1305:
                let box = try ChaChaPoly.SealedBox(combined: nonceData + ciphertext)
                return try ChaChaPoly.open(box, using: symKey, authenticating: aad)
            case .xchacha20IetfPoly1305:
                return try openXChaCha20(ciphertext: ciphertext, nonce: nonceData, authenticating: aad)
            }
        } catch {
            throw MagentError.cryptoError(type: "decryptionFailed", underlying: error)
        }
    }

    // MARK: - Nonce Management

    /// Nonce 自增 1（小端计数器）。
    /// 溢出回绕到全零，符合 SS 协议规定（实际不会用到那么多）。
    private func incrementNonce() {
        var carry: UInt16 = 1
        for i in 0..<nonce.count {
            carry += UInt16(nonce[i])
            nonce[i] = UInt8(carry & 0xFF)
            carry >>= 8
        }
    }

    // MARK: - XChaCha20-Poly1305

    /// XChaCha20 = HChaCha20(key, nonce[0..16]) → subkey，再走 ChaCha20-Poly1305，
    /// subNonce = 0x00000000 || nonce[16..24]。
    private func sealXChaCha20(plaintext: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        let subkey = hChaCha20(key: key, nonce: nonce.prefix(16))
        let subNonce = Data(repeating: 0, count: 4) + nonce.suffix(8)
        let n = try ChaChaPoly.Nonce(data: subNonce)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: subkey),
            nonce: n,
            authenticating: aad
        )
        return Data(sealed.combined.dropFirst(12))
    }

    /// XChaCha20-Poly1305 解密，输入格式为 `ciphertext || tag`。
    private func openXChaCha20(ciphertext: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        let subkey = hChaCha20(key: key, nonce: nonce.prefix(16))
        let subNonce = Data(repeating: 0, count: 4) + nonce.suffix(8)
        let box = try ChaChaPoly.SealedBox(combined: subNonce + ciphertext)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: subkey), authenticating: aad)
    }
}

// MARK: - HChaCha20

/// HChaCha20 key derivation（draft-irtf-cfrg-xchacha）。
///
/// 用 32 字节 key + 16 字节 nonce 推导出 32 字节 subkey，
/// 仅用于 XChaCha20-Poly1305 的 subkey 派生阶段。
func hChaCha20(key: Data, nonce: Data) -> Data {
    precondition(key.count == 32, "HChaCha20 key must be 32 bytes")
    precondition(nonce.count == 16, "HChaCha20 nonce must be 16 bytes")

    let keyWords = littleEndianWords(key)
    let nonceWords = littleEndianWords(nonce)

    var state: [UInt32] = [
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        keyWords[0], keyWords[1], keyWords[2], keyWords[3],
        keyWords[4], keyWords[5], keyWords[6], keyWords[7],
        nonceWords[0], nonceWords[1], nonceWords[2], nonceWords[3],
    ]

    for _ in 0..<10 {
        quarterRound(&state, 0, 4, 8, 12)
        quarterRound(&state, 1, 5, 9, 13)
        quarterRound(&state, 2, 6, 10, 14)
        quarterRound(&state, 3, 7, 11, 15)
        quarterRound(&state, 0, 5, 10, 15)
        quarterRound(&state, 1, 6, 11, 12)
        quarterRound(&state, 2, 7, 8, 13)
        quarterRound(&state, 3, 4, 9, 14)
    }

    var output = Data()
    for i in [0, 1, 2, 3, 12, 13, 14, 15] {
        var word = state[i].littleEndian
        output.append(Data(bytes: &word, count: 4))
    }
    return output
}

/// 不依赖底层内存对齐，按四个小端字节解出 UInt32。
private func littleEndianWords(_ data: Data) -> [UInt32] {
    precondition(data.count.isMultiple(of: 4), "Little-endian word input must be 4-byte aligned in length")
    var words: [UInt32] = []
    words.reserveCapacity(data.count / 4)

    for index in stride(from: 0, to: data.count, by: 4) {
        let byte0 = UInt32(data[index])
        let byte1 = UInt32(data[index + 1]) << 8
        let byte2 = UInt32(data[index + 2]) << 16
        let byte3 = UInt32(data[index + 3]) << 24
        words.append(byte0 | byte1 | byte2 | byte3)
    }
    return words
}

/// ChaCha20 单轮 quarter round，按列/对角线原地更新 state 的四个字。
@inline(__always)
private func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
    state[a] = state[a] &+ state[b]
    state[d] = rotateLeft(state[d] ^ state[a], by: 16)

    state[c] = state[c] &+ state[d]
    state[b] = rotateLeft(state[b] ^ state[c], by: 12)

    state[a] = state[a] &+ state[b]
    state[d] = rotateLeft(state[d] ^ state[a], by: 8)

    state[c] = state[c] &+ state[d]
    state[b] = rotateLeft(state[b] ^ state[c], by: 7)
}

/// 32 位循环左移。
@inline(__always)
private func rotateLeft(_ x: UInt32, by n: UInt32) -> UInt32 {
    (x << n) | (x >> (32 - n))
}
