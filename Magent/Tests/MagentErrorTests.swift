import Foundation
@testable import Magent
import XCTest

// MARK: - MagentError Tests

final class MagentErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertEqual(
            MagentError.cryptoError(type: "invalidKeyLength", expected: 32, actual: 16),
            .cryptoError("invalidKeyLength: expected 32, actual 16")
        )
        XCTAssertEqual(
            MagentError.cryptoError(type: "invalidIVLength", expected: 12, actual: 16),
            .cryptoError("invalidIVLength: expected 12, actual 16")
        )
        XCTAssertEqual(
            MagentError.cryptoError(type: "bufferTooSmall"),
            .cryptoError("bufferTooSmall")
        )
    }

    func testErrorEquality() {
        XCTAssertEqual(MagentError.cryptoError("bufferTooSmall"), MagentError.cryptoError("bufferTooSmall"))
        XCTAssertNotEqual(MagentError.cryptoError("bufferTooSmall"), MagentError.cryptoError("invalidPassword"))
        XCTAssertNotEqual(
            MagentError.cryptoError(type: "invalidKeyLength", expected: 16, actual: 8),
            MagentError.cryptoError(type: "invalidKeyLength", expected: 32, actual: 8)
        )
    }
}
