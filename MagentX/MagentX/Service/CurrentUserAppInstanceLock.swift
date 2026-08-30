import Darwin
import Foundation

/// 持有当前用户范围内的 MagentX 单实例文件锁，确保同一时刻只有一个应用进程继续启动。
final class CurrentUserAppInstanceLock {
    private let fileDescriptor: CInt

    /// 尝试获取指定文件上的非阻塞排他锁；已有实例持锁时抛出 `MagentXError.anotherInstanceRunning`。
    init(lockFileURL: URL? = nil) throws {
        let resolvedLockFileURL = lockFileURL ?? Self.defaultLockFileURL
        let descriptor = resolvedLockFileURL.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
        }

        guard descriptor >= 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK {
                throw MagentXError.anotherInstanceRunning
            }
            throw MagentXError.singleInstanceLockFailed(String(cString: strerror(lockError)))
        }

        fileDescriptor = descriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    private static var defaultLockFileURL: URL {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.marlinl.magent.macos"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bundleIdentifier).single-instance.lock")
    }
}
