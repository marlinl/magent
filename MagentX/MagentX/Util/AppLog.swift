//
//  AppLog.swift
//  MagentX
//
//  Responsibility: Provides the app-wide Apple unified logging categories.
//

import Foundation
import OSLog

/// MagentX 统一系统日志入口，为应用、代理、网络、规则和持久化流程提供稳定分类。
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.magentx.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let proxy = Logger(subsystem: subsystem, category: "Proxy")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let rules = Logger(subsystem: subsystem, category: "Rules")
    static let database = Logger(subsystem: subsystem, category: "Database")
}
