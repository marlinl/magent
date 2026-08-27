import Foundation
import Crypto

// MARK: - HKDF-SHA1 Key Derivation (Shadowsocks AEAD subkey)

/// 按 Shadowsocks AEAD 规范使用 HKDF-SHA1 从 master key 和 salt 派生 subkey。
internal func deriveSubkey(
    key: Data,
    salt: Data,
    info: Data = Data("ss-subkey".utf8),
    outputLength: Int
) -> Data {
    let derivedKey = HKDF<Insecure.SHA1>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: key),
        salt: salt,
        info: info,
        outputByteCount: outputLength
    )
    return derivedKey.withUnsafeBytes { Data($0) }
}

// MARK: - Password to Key (EVP_BytesToKey, legacy stream ciphers)

/// 使用 OpenSSL EVP_BytesToKey 兼容算法把 Shadowsocks password 派生为 master key。
///
/// Shadowsocks AEAD 仍沿用该 password-to-key 过程，hash 函数为 MD5。
internal func passwordToKey(password: String, keyLength: Int) -> Data {
    let passwordData = Data(password.utf8)
    var result = Data()
    var lastDigest = Data()

    while result.count < keyLength {
        var input = Data()
        if !lastDigest.isEmpty {
            input.append(lastDigest)
        }
        input.append(passwordData)

        lastDigest = Data(Insecure.MD5.hash(data: input))
        result.append(lastDigest)
    }

    return Data(result.prefix(keyLength))
}

// MARK: - Random Bytes

/// 生成指定长度的随机字节，用于 Shadowsocks salt。
internal func randomBytes(count: Int) -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    var rng = SystemRandomNumberGenerator()
    for i in stride(from: 0, to: count, by: 8) {
        let val: UInt64 = rng.next()
        let remaining = count - i
        let take = Swift.min(remaining, 8)
        let v = val
        for j in 0..<take {
            bytes[i + j] = UInt8(truncatingIfNeeded: v &>> (j * 8))
        }
    }
    return Data(bytes)
}
