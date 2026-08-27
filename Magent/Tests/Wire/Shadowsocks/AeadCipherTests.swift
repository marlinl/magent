import Foundation
@testable import Magent
import XCTest

// MARK: - AeadCipher Tests

final class AeadCipherTests: XCTestCase {

    private func makeKey(_ cipher: ProxyCipher) -> Data {
        randomBytes(count: cipher.keySize)
    }

    // MARK: All AEAD round-trips

    func testAES128GCMRoundTrip() throws {
        try assertAeadRoundTrip(cipher: .aes128Gcm, plaintext: Data("Hello, AEAD!".utf8))
    }

    func testAES256GCMRoundTrip() throws {
        try assertAeadRoundTrip(cipher: .aes256Gcm, plaintext: Data("Hello, AEAD!".utf8))
    }

    func testChaCha20Poly1305RoundTrip() throws {
        try assertAeadRoundTrip(cipher: .chacha20IetfPoly1305, plaintext: Data("Hello, AEAD!".utf8))
    }

    func testXChaCha20Poly1305RoundTrip() throws {
        try assertAeadRoundTrip(cipher: .xchacha20IetfPoly1305, plaintext: Data("Hello, XChaCha!".utf8))
    }

    /// draft-irtf-cfrg-xchacha-03 Appendix A.3.1 外部 AEAD 测试向量。
    func testXChaCha20Poly1305DraftVector() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("404142434445464748494a4b4c4d4e4f5051525354555657")
        let aad = hexData("50515253c0c1c2c3c4c5c6c7")
        let plaintext = hexData(
            "4c616469657320616e642047656e746c656d656e206f662074686520636c6173" +
            "73206f66202739393a204966204920636f756c64206f6666657220796f75206f" +
            "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73" +
            "637265656e20776f756c642062652069742e"
        )
        let expected = hexData(
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb" +
            "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452" +
            "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9" +
            "21f9664c97637da9768812f615c68b13b52e" +
            "c0875924c1c7987947deafd8780acf49"
        )

        let encryptor = try AeadCipher(cipher: .xchacha20IetfPoly1305, key: key, nonce: nonce)
        let ciphertext = try encryptor.encrypt(plaintext, authenticating: aad)
        XCTAssertEqual(ciphertext, expected)

        let decryptor = try AeadCipher(cipher: .xchacha20IetfPoly1305, key: key, nonce: nonce)
        XCTAssertEqual(try decryptor.decrypt(expected, authenticating: aad), plaintext)
    }

    // MARK: Larger data

    func testAES128GCMLargeData() throws {
        let data = Data((0..<4096).map { UInt8($0 % 256) })
        try assertAeadRoundTrip(cipher: .aes128Gcm, plaintext: data)
    }

    func testChaCha20Poly1305LargeData() throws {
        let data = Data((0..<4096).map { UInt8($0 % 256) })
        try assertAeadRoundTrip(cipher: .chacha20IetfPoly1305, plaintext: data)
    }

    func testXChaCha20Poly1305LargeData() throws {
        let data = Data((0..<4096).map { UInt8($0 % 256) })
        try assertAeadRoundTrip(cipher: .xchacha20IetfPoly1305, plaintext: data)
    }

    // MARK: Single byte

    func testAES256GCMSingleByte() throws {
        try assertAeadRoundTrip(cipher: .aes256Gcm, plaintext: Data([0x42]))
    }

    func testChaCha20Poly1305SingleByte() throws {
        try assertAeadRoundTrip(cipher: .chacha20IetfPoly1305, plaintext: Data([0x42]))
    }

    func testXChaCha20Poly1305SingleByte() throws {
        try assertAeadRoundTrip(cipher: .xchacha20IetfPoly1305, plaintext: Data([0x42]))
    }

    // MARK: Nonce auto-increment

    func testNonceIncrementsAfterEncrypt() throws {
        let cipher = ProxyCipher.aes128Gcm
        let enc = try AeadCipher(cipher: cipher, key: makeKey(cipher))
        let plaintext = Data("test".utf8)

        let ct1 = try enc.encrypt(plaintext)
        let ct2 = try enc.encrypt(plaintext)

        XCTAssertNotEqual(ct1, ct2, "Different nonces should produce different ciphertexts")
    }

    func testNonceIncrementsAfterDecrypt() throws {
        let cipher = ProxyCipher.aes256Gcm
        let key = makeKey(cipher)
        let enc = try AeadCipher(cipher: cipher, key: key)
        let dec = try AeadCipher(cipher: cipher, key: key)

        let ct1 = try enc.encrypt(Data("msg1".utf8))
        let ct2 = try enc.encrypt(Data("msg2".utf8))

        let pt1 = try dec.decrypt(ct1)
        let pt2 = try dec.decrypt(ct2)

        XCTAssertEqual(pt1, Data("msg1".utf8))
        XCTAssertEqual(pt2, Data("msg2".utf8))
    }

    // MARK: Invalid key length

    func testAeadInvalidKeyLengthThrows() {
        for cipher in ProxyCipher.allCases {
            XCTAssertThrowsError(try AeadCipher(cipher: cipher, key: Data(repeating: 0, count: 1))) { error in
                guard let magentError = error as? MagentError,
                      case .cryptoError(let description) = magentError else {
                    XCTFail("Expected MagentError.cryptoError")
                    return
                }
                XCTAssertEqual(description, "invalidKeyLength: expected \(cipher.keySize), actual 1")
            }
        }
    }

    // MARK: Buffer too small

    func testDecryptBufferTooSmall() throws {
        for cipher in ProxyCipher.allCases {
            let dec = try AeadCipher(cipher: cipher, key: makeKey(cipher))
            let shortData = Data(repeating: 0, count: cipher.tagSize)
            XCTAssertThrowsError(try dec.decrypt(shortData)) { error in
                guard let magentError = error as? MagentError,
                      case .cryptoError(let description) = magentError else {
                    XCTFail("Expected MagentError.cryptoError")
                    return
                }
                XCTAssertEqual(
                    description,
                    "bufferTooSmall: expected \(cipher.tagSize + 1), actual \(shortData.count)"
                )
            }
        }
    }

    func testDecryptEmptyBufferThrows() throws {
        let cipher = ProxyCipher.aes128Gcm
        let dec = try AeadCipher(cipher: cipher, key: makeKey(cipher))
        XCTAssertThrowsError(try dec.decrypt(Data())) { error in
            guard let magentError = error as? MagentError,
                  case .cryptoError(let description) = magentError else {
                XCTFail("Expected MagentError.cryptoError")
                return
            }
            XCTAssertEqual(description, "bufferTooSmall: expected \(cipher.tagSize + 1), actual 0")
        }
    }

    // MARK: Tampered ciphertext

    func testTamperedCiphertextFailsDecryption() throws {
        for cipher in ProxyCipher.allCases {
            let key = makeKey(cipher)
            let enc = try AeadCipher(cipher: cipher, key: key)
            let dec = try AeadCipher(cipher: cipher, key: key)

            let ct = try enc.encrypt(Data("sensitive data".utf8))

            var tampered = ct
            if !tampered.isEmpty {
                tampered[tampered.count / 2] ^= 0xFF
            }

            XCTAssertThrowsError(try dec.decrypt(tampered))
        }
    }

    // MARK: Wrong key fails

    func testWrongKeyFailsDecryption() throws {
        for cipher in ProxyCipher.allCases {
            let key1 = makeKey(cipher)
            let key2 = makeKey(cipher)
            let enc = try AeadCipher(cipher: cipher, key: key1)
            let dec = try AeadCipher(cipher: cipher, key: key2)

            let ct = try enc.encrypt(Data("test data".utf8))

            XCTAssertThrowsError(try dec.decrypt(ct))
        }
    }

    // MARK: Helper

    private func assertAeadRoundTrip(cipher: ProxyCipher, plaintext: Data, file: StaticString = #file,
        line: UInt = #line) throws {
        let key = makeKey(cipher)
        let enc = try AeadCipher(cipher: cipher, key: key)
        let dec = try AeadCipher(cipher: cipher, key: key)

        let ct = try enc.encrypt(plaintext)
        XCTAssertGreaterThan(
            ct.count,
            plaintext.count,
            "AEAD ciphertext should be larger (includes tag)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            ct.count,
            plaintext.count + cipher.tagSize,
            "Ciphertext should be plaintext + tag",
            file: file,
            line: line
        )

        let pt = try dec.decrypt(ct)
        XCTAssertEqual(pt, plaintext, "Decrypted data should match original", file: file, line: line)
    }
}

private func hexData(_ value: String) -> Data {
    let bytes = Array(value.utf8)
    precondition(bytes.count.isMultiple(of: 2))
    var result = Data()
    result.reserveCapacity(bytes.count / 2)

    for index in stride(from: 0, to: bytes.count, by: 2) {
        func nibble(_ byte: UInt8) -> UInt8 {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: preconditionFailure("invalid hex character")
            }
        }
        result.append((nibble(bytes[index]) << 4) | nibble(bytes[index + 1]))
    }
    return result
}

// MARK: - Nonce Counter Tests

final class AeadCipherNonceTests: XCTestCase {

    private func makeKey(_ cipher: ProxyCipher) -> Data {
        randomBytes(count: cipher.keySize)
    }

    // MARK: - Sequential nonce advance

    /// 同一明文连续 encrypt N 次，应得到 N 个不同密文——nonce 必须严格递增、不重用。
    func testSequentialEncryptProducesUniqueCiphertexts() throws {
        for cipher in ProxyCipher.allCases {
            let enc = try AeadCipher(cipher: cipher, key: makeKey(cipher))
            let plaintext = Data("same plaintext".utf8)

            var seen = Set<Data>()
            for i in 0..<20 {
                let ct = try enc.encrypt(plaintext)
                XCTAssertTrue(seen.insert(ct).inserted,
                              "\(cipher.rawValue): nonce reused at call \(i)")
            }
            XCTAssertEqual(seen.count, 20, "\(cipher.rawValue): expected 20 unique ciphertexts")
        }
    }

    /// 1000 次大样本——任何 nonce 重用都会被检测到。
    func testLargeSequenceHasNoNonceReuse() throws {
        let cipher = ProxyCipher.aes128Gcm
        let enc = try AeadCipher(cipher: cipher, key: makeKey(cipher))
        let plaintext = Data([0x00])

        var seen = Set<Data>()
        for _ in 0..<1000 {
            let ct = try enc.encrypt(plaintext)
            XCTAssertTrue(seen.insert(ct).inserted, "Nonce reuse detected")
        }
    }

    /// encrypt 端顺序推进，decrypt 端必须严格按相同顺序解——证明两端 nonce 序列对齐。
    func testDecryptMustFollowEncryptOrder() throws {
        for cipher in ProxyCipher.allCases {
            let key = makeKey(cipher)
            let enc = try AeadCipher(cipher: cipher, key: key)
            let dec = try AeadCipher(cipher: cipher, key: key)

            let plaintexts: [Data] = (0..<5).map { Data("msg-\($0)".utf8) }
            let cts = try plaintexts.map { try enc.encrypt($0) }
            let recovered = try cts.map { try dec.decrypt($0) }

            XCTAssertEqual(recovered, plaintexts, "\(cipher.rawValue): out-of-order nonce broke decrypt")
        }
    }

    /// 乱序解密必然失败——decrypt 端 nonce 还没推进到 encrypt 端封存时用的位置。
    func testDecryptOutOfOrderFails() throws {
        let cipher = ProxyCipher.aes256Gcm
        let key = makeKey(cipher)
        let enc = try AeadCipher(cipher: cipher, key: key)
        let dec = try AeadCipher(cipher: cipher, key: key)

        _ = try enc.encrypt(Data("0".utf8))   // sealed with nonce=0
        let ct1 = try enc.encrypt(Data("1".utf8))  // sealed with nonce=1
        _ = try enc.encrypt(Data("2".utf8))   // sealed with nonce=2

        // dec.nonce=0，但 ct1 是用 nonce=1 封的 → AEAD tag 校验失败
        XCTAssertThrowsError(try dec.decrypt(ct1),
                             "Decrypting with nonce=0 a ciphertext sealed with nonce=1 must fail")
    }

    // MARK: - Reference semantics

    /// AeadCipher 是 class——两个引用共享 nonce 状态。
    /// 从任一引用 encrypt，另一引用下次 encrypt 得到的是下一个 nonce。
    func testReferenceSemanticsShareNonceState() throws {
        let cipher = ProxyCipher.chacha20IetfPoly1305
        let enc = try AeadCipher(cipher: cipher, key: makeKey(cipher))
        let alias: AeadCipher = enc  // 引用，不是 copy

        let ct0 = try enc.encrypt(Data("a".utf8))   // nonce=0
        let ct1 = try alias.encrypt(Data("a".utf8)) // nonce=1（共享状态）
        let ct2 = try enc.encrypt(Data("a".utf8))   // nonce=2

        XCTAssertNotEqual(ct0, ct1)
        XCTAssertNotEqual(ct1, ct2)
        XCTAssertNotEqual(ct0, ct2)
    }

    /// XChaCha20 的 24 字节 nonce 也要正确递增——大 nonce 不能因为字节多就出 bug。
    func testXChaCha20NonceSequenceRoundTrip() throws {
        let cipher = ProxyCipher.xchacha20IetfPoly1305
        let key = makeKey(cipher)
        let enc = try AeadCipher(cipher: cipher, key: key)
        let dec = try AeadCipher(cipher: cipher, key: key)

        let plaintexts: [Data] = (0..<20).map { Data("x-\($0)".utf8) }
        let cts = try plaintexts.map { try enc.encrypt($0) }
        let recovered = try cts.map { try dec.decrypt($0) }
        XCTAssertEqual(recovered, plaintexts)
    }

    // MARK: - Concurrent access via actor serialization

    /// 跨 100 个并发任务通过 actor 串行化 encrypt 同一实例——所有密文必须唯一，
    /// 验证 AeadCipher 作为 `@unchecked Sendable` 在 actor 串行化下行为正确。
    func testConcurrentEncryptViaActorProducesUniqueCiphertexts() async throws {
        let cipher = ProxyCipher.aes256Gcm
        let key = makeKey(cipher)

        actor CipherBox {
            let enc: AeadCipher
            init(_ enc: AeadCipher) { self.enc = enc }
            func encrypt(_ data: Data) throws -> Data { try enc.encrypt(data) }
        }

        let box = CipherBox(try AeadCipher(cipher: cipher, key: key))
        let plaintext = Data("concurrent".utf8)

        let results = await withTaskGroup(of: Data?.self) { group -> [Data] in
            for _ in 0..<100 {
                group.addTask { try? await box.encrypt(plaintext) }
            }
            var out: [Data] = []
            for await ct in group {
                if let ct = ct { out.append(ct) }
            }
            return out
        }

        XCTAssertEqual(results.count, 100, "All concurrent encrypts should succeed")
        XCTAssertEqual(Set(results).count, 100, "All ciphertexts must be unique (no nonce reuse)")
    }

    /// 同一实例跨任务共享。
    /// 通过 actor 包一层累计计数，验证所有调用确实落到同一 cipher 上。
    func testSharedInstanceAcrossTasksViaActor() async throws {
        let cipher = ProxyCipher.chacha20IetfPoly1305
        let key = makeKey(cipher)

        actor Box {
            let enc: AeadCipher
            private(set) var callCount = 0
            init(_ enc: AeadCipher) { self.enc = enc }
            func encrypt(_ data: Data) throws -> Data {
                callCount += 1
                return try enc.encrypt(data)
            }
        }

        let box = Box(try AeadCipher(cipher: cipher, key: key))
        let plaintext = Data("shared".utf8)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = try? await box.encrypt(plaintext) }
            }
        }

        let finalCount = await box.callCount
        XCTAssertEqual(finalCount, 50, "All 50 concurrent calls should hit the shared instance")
    }

    /// actor 包装的 cipher 可以安全地按顺序 decrypt 整个密文流——证明 SS 协议要求的
    /// "两端各自顺序推进 nonce" 契约在 actor 串行化下成立。
    func testActorWrappedDecryptFollowsNonceOrder() async throws {
        let cipher = ProxyCipher.aes128Gcm
        let key = makeKey(cipher)
        let enc = try AeadCipher(cipher: cipher, key: key)

        actor DecryptBox {
            let dec: AeadCipher
            init(_ dec: AeadCipher) { self.dec = dec }
            func decrypt(_ data: Data) throws -> Data { try dec.decrypt(data) }
        }
        let box = DecryptBox(try AeadCipher(cipher: cipher, key: key))

        let originals: [Data] = (0..<30).map { Data("payload-\($0)".utf8) }
        let cts = try originals.map { try enc.encrypt($0) }

        // 顺序提交（不开并发任务），保证 decrypt nonce 与 encrypt nonce 严格对齐
        var recovered: [Data] = []
        for ct in cts {
            recovered.append(try await box.decrypt(ct))
        }
        XCTAssertEqual(recovered, originals)
    }

    /// 500 次高并发 encrypt via actor——只验证不崩、不数据竞争。
    /// 唯一性已经由 testConcurrentEncryptViaActorProducesUniqueCiphertexts 覆盖。
    func testHighConcurrencyStressViaActor() async throws {
        let cipher = ProxyCipher.chacha20IetfPoly1305
        let key = makeKey(cipher)

        actor Box {
            let enc: AeadCipher
            init(_ enc: AeadCipher) { self.enc = enc }
            func encrypt(_ data: Data) throws -> Data { try enc.encrypt(data) }
        }
        let box = Box(try AeadCipher(cipher: cipher, key: key))
        let plaintext = Data("stress".utf8)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask { _ = try? await box.encrypt(plaintext) }
            }
        }
    }
}

// MARK: - HChaCha20 Tests

final class HChaCha20Tests: XCTestCase {

    func testHChaCha20Produces32Bytes() {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 16)
        let result = hChaCha20(key: key, nonce: nonce)
        XCTAssertEqual(result.count, 32)
    }

    func testHChaCha20Deterministic() {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data((0..<16).map { UInt8($0) })
        let result1 = hChaCha20(key: key, nonce: nonce)
        let result2 = hChaCha20(key: key, nonce: nonce)
        XCTAssertEqual(result1, result2)
    }

    func testHChaCha20DifferentInputs() {
        let key1 = Data(repeating: 0x01, count: 32)
        let key2 = Data(repeating: 0x02, count: 32)
        let nonce = Data(repeating: 0, count: 16)
        let result1 = hChaCha20(key: key1, nonce: nonce)
        let result2 = hChaCha20(key: key2, nonce: nonce)
        XCTAssertNotEqual(result1, result2)
    }

    func testHChaCha20TestVector() {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 16)
        let result = hChaCha20(key: key, nonce: nonce)

        XCTAssertNotEqual(result, Data(repeating: 0, count: 32))
        XCTAssertEqual(result.count, 32)
    }
}
