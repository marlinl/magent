import Foundation
import Testing
@testable import MagentX

/// 验证当前用户单实例文件锁的互斥与释放语义。
struct CurrentUserAppInstanceLockTests {
    /// 同一路径不能同时获得两把锁，原持有者释放后应允许再次获取。
    @Test
    func lockExcludesConcurrentHolderAndCanBeReacquired() throws {
        let lockFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurrentUserAppInstanceLockTests-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockFileURL) }

        var firstLock: CurrentUserAppInstanceLock? = try CurrentUserAppInstanceLock(
            lockFileURL: lockFileURL
        )

        #expect(throws: MagentXError.anotherInstanceRunning) {
            try CurrentUserAppInstanceLock(lockFileURL: lockFileURL)
        }

        firstLock = nil
        _ = try CurrentUserAppInstanceLock(lockFileURL: lockFileURL)
    }
}
