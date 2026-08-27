//
//  MagentXLogger.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Provides app-wide runtime logging through Apple unified logging and user Library log files.
//

import Foundation
import OSLog

/// MagentX 运行期日志分类，对应 Apple Unified Logging 的 category。
enum MagentXLogCategory: String, Codable, Sendable {
    case app
    case service
    case systemProxy
    case network
    case persistence
}

/// MagentX 运行期日志级别，统一映射到 `Logger` 和本地日志文件。
enum MagentXLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault
}

/// MagentX 应用日志入口，统一写入 Apple Unified Logging 和用户域 `Library/Logs`。
enum MagentXLogger {
    fileprivate static let fallbackSubsystem = "io.github.marlinl.magent.macos"
    private static let subsystem = Bundle.main.bundleIdentifier ?? fallbackSubsystem
    private static let fileWriter = MagentXLogFileWriter(subsystem: subsystem)

    /// 当前进程写入的本地日志文件路径，通常位于 app 容器内的 `Library/Logs/<bundle id>/MagentX.log`。
    static var logFileURL: URL {
        fileWriter.logFileURL
    }

    /// 写入调试级日志。
    static func debug(
        _ message: String,
        category: MagentXLogCategory,
        metadata: [String: String] = [:]
    ) {
        write(level: .debug, category: category, message: message, metadata: metadata)
    }

    /// 写入普通信息日志。
    static func info(
        _ message: String,
        category: MagentXLogCategory,
        metadata: [String: String] = [:]
    ) {
        write(level: .info, category: category, message: message, metadata: metadata)
    }

    /// 写入可恢复异常或异常状态日志。
    static func warning(
        _ message: String,
        category: MagentXLogCategory,
        metadata: [String: String] = [:]
    ) {
        write(level: .warning, category: category, message: message, metadata: metadata)
    }

    /// 写入抛出的可恢复错误日志。
    static func error(
        _ error: Error,
        category: MagentXLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        write(level: .error, category: category, message: message, error: error, metadata: metadata)
    }

    /// 写入会导致当前流程终止或应用无法继续运行的严重错误日志。
    static func fault(
        _ error: Error,
        category: MagentXLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        write(level: .fault, category: category, message: message, error: error, metadata: metadata)
    }

    private static func write(
        level: MagentXLogLevel,
        category: MagentXLogCategory,
        message: String,
        error: Error? = nil,
        metadata: [String: String]
    ) {
        let renderedMessage = render(message: message, error: error, metadata: metadata)
        let logger = Logger(subsystem: subsystem, category: category.rawValue)

        switch level {
        case .debug:
            logger.debug("\(renderedMessage, privacy: .public)")
        case .info:
            logger.info("\(renderedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(renderedMessage, privacy: .public)")
        case .error:
            logger.error("\(renderedMessage, privacy: .public)")
        case .fault:
            logger.fault("\(renderedMessage, privacy: .public)")
        }

        fileWriter.append(
            MagentXLogFileEntry(
                timestamp: Date.now,
                level: level,
                category: category,
                message: message,
                errorDescription: error.map { String(reflecting: $0) },
                metadata: metadata
            )
        )
    }

    private static func render(message: String, error: Error?, metadata: [String: String]) -> String {
        var components = [message]
        if let error {
            components.append("error=\(String(reflecting: error))")
        }
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            components.append("\(key)=\(value)")
        }
        return components.joined(separator: " | ")
    }
}

/// 本地日志文件单行记录，使用 JSON Lines 便于 Console 之外的脚本排查。
private struct MagentXLogFileEntry: Encodable {
    let timestamp: Date
    let level: MagentXLogLevel
    let category: MagentXLogCategory
    let message: String
    let errorDescription: String?
    let metadata: [String: String]
}

/// 本地日志文件追加写入器，负责定位用户域 `Library/Logs` 并串行写入。
private final class MagentXLogFileWriter {
    let logFileURL: URL

    private let queue = DispatchQueue(label: "io.github.marlinl.magent.macos.log-file")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(subsystem: String) {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logFileURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(subsystem, isDirectory: true)
            .appendingPathComponent("MagentX.log", isDirectory: false)
    }

    func append(_ entry: MagentXLogFileEntry) {
        queue.async { [encoder, logFileURL] in
            do {
                var data = try encoder.encode(entry)
                data.append(0x0A)

                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: logFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if fileManager.fileExists(atPath: logFileURL.path) == false {
                    _ = fileManager.createFile(atPath: logFileURL.path, contents: data)
                    return
                }

                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                try fileHandle.close()
            } catch {
                Logger(subsystem: MagentXLogger.fallbackSubsystem, category: "app")
                    .error("Failed to write local log file: \(String(reflecting: error), privacy: .public)")
            }
        }
    }
}
