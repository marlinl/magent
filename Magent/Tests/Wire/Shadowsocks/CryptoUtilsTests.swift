import Foundation
@testable import Magent
import XCTest

// MARK: - CryptoUtils Tests

final class CryptoUtilsTests: XCTestCase {

    func testPasswordToKeyProducesCorrectLength() {
        for keyLen in [16, 24, 32] {
            let key = passwordToKey(password: "test-password", keyLength: keyLen)
            XCTAssertEqual(key.count, keyLen)
        }
    }

    func testPasswordToKeyDeterministic() {
        let key1 = passwordToKey(password: "hello", keyLength: 32)
        let key2 = passwordToKey(password: "hello", keyLength: 32)
        XCTAssertEqual(key1, key2)
    }

    func testPasswordToKeyDifferentPasswords() {
        let key1 = passwordToKey(password: "password1", keyLength: 32)
        let key2 = passwordToKey(password: "password2", keyLength: 32)
        XCTAssertNotEqual(key1, key2)
    }

    func testPasswordToKeySingleBlock() {
        let key = passwordToKey(password: "test", keyLength: 16)
        XCTAssertEqual(key.count, 16)
    }

    func testDeriveSubkeyProducesCorrectLength() {
        let key = Data(repeating: 0xAB, count: 32)
        let salt = Data(repeating: 0xCD, count: 12)
        let subkey = deriveSubkey(key: key, salt: salt, outputLength: 32)
        XCTAssertEqual(subkey.count, 32)
    }

    func testDeriveSubkeyDeterministic() {
        let key = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 16)
        let subkey1 = deriveSubkey(key: key, salt: salt, outputLength: 32)
        let subkey2 = deriveSubkey(key: key, salt: salt, outputLength: 32)
        XCTAssertEqual(subkey1, subkey2)
    }

    func testDeriveSubkeyDifferentSalts() {
        let key = Data(repeating: 0x01, count: 32)
        let salt1 = Data(repeating: 0x02, count: 16)
        let salt2 = Data(repeating: 0x03, count: 16)
        let subkey1 = deriveSubkey(key: key, salt: salt1, outputLength: 32)
        let subkey2 = deriveSubkey(key: key, salt: salt2, outputLength: 32)
        XCTAssertNotEqual(subkey1, subkey2)
    }

    func testRandomBytesCorrectLength() {
        for count in [0, 1, 12, 16, 32, 64, 256] {
            let bytes = randomBytes(count: count)
            XCTAssertEqual(bytes.count, count)
        }
    }

    func testRandomBytesAreRandom() {
        let bytes1 = randomBytes(count: 32)
        let bytes2 = randomBytes(count: 32)
        XCTAssertNotEqual(bytes1, bytes2, "Two random byte sequences should differ")
    }

    func testRandomBytesEmpty() {
        let bytes = randomBytes(count: 0)
        XCTAssertEqual(bytes.count, 0)
    }
}
