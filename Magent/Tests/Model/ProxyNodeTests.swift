import Foundation
@testable import Magent
import XCTest

// MARK: - ProxyCipher Tests

final class ProxyNodeTests: XCTestCase {

    func testKeySizes() {
        XCTAssertEqual(ProxyCipher.aes128Gcm.keySize, 16)
        XCTAssertEqual(ProxyCipher.aes256Gcm.keySize, 32)
        XCTAssertEqual(ProxyCipher.chacha20IetfPoly1305.keySize, 32)
        XCTAssertEqual(ProxyCipher.xchacha20IetfPoly1305.keySize, 32)
    }

    func testSaltSizes() {
        for cipher in ProxyCipher.allCases {
            XCTAssertEqual(cipher.saltSize, cipher.keySize, "\(cipher.rawValue) salt size should equal key size")
        }
    }

    func testNonceSizes() {
        XCTAssertEqual(ProxyCipher.aes128Gcm.nonceSize, 12)
        XCTAssertEqual(ProxyCipher.aes256Gcm.nonceSize, 12)
        XCTAssertEqual(ProxyCipher.chacha20IetfPoly1305.nonceSize, 12)
        XCTAssertEqual(ProxyCipher.xchacha20IetfPoly1305.nonceSize, 24)
    }

    func testTagSizes() {
        for cipher in ProxyCipher.allCases {
            XCTAssertEqual(cipher.tagSize, 16, "\(cipher.rawValue) should have 16-byte tag")
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(ProxyCipher.allCases.count, 4)
    }

    func testRawValueRoundTrip() {
        for cipher in ProxyCipher.allCases {
            XCTAssertEqual(ProxyCipher(rawValue: cipher.rawValue), cipher)
        }
    }
}
