//
//  MagentXApp.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: App entry point and SwiftData model container registration.
//

import AppKit
import FactoryKit
import SwiftUI
import SwiftData

/// macOS 应用代理，协调窗口关闭后是否继续保留后台进程。
final class MagentXAppDelegate: NSObject, NSApplicationDelegate {
    /// 应用菜单栏后台运行偏好。
    static var keepsRunningAfterLastWindowClosed = true

    /// 应用设置中的后台运行偏好。
    static func applyBackgroundPreference(_ isEnabled: Bool) {
        keepsRunningAfterLastWindowClosed = isEnabled
    }

    /// 应用启动后按持久化状态恢复本地代理和系统代理配置。
    func applicationDidFinishLaunching(_ notification: Notification) {
        MagentXLogger.info(
            "Application did finish launching",
            category: .app,
            metadata: ["logFile": MagentXLogger.logFileURL.path]
        )
        Task { @MainActor in
            do {
                try await SystemNetworkProxyService.shared.applyStoredConfiguration()
            } catch {
                MagentXLogger.error(
                    error,
                    category: .systemProxy,
                    message: "Failed to restore stored proxy configuration at launch"
                )
            }
        }
    }

    /// 应用退出前停止进程内本地监听，并清理 MagentX 写入的系统代理配置。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MagentXLogger.info("Application will terminate", category: .app)
        Task { @MainActor in
            await SystemNetworkProxyService.shared.deactivateRuntimeServices()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 根据后台运行偏好决定最后一个窗口关闭后是否退出应用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.keepsRunningAfterLastWindowClosed == false
    }

    /// 允许用户点击 Dock 图标时重新打开窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }
}

@main
/// MagentX 应用入口，创建 SwiftData 容器、主窗口和菜单栏入口。
struct MagentXApp: App {
    static let mainWindowID = "main"

    /// 应用在当前沙箱中持久化本地文件的根目录。
    nonisolated static let localDirectoryURL = URL.applicationSupportDirectory
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MagentX", isDirectory: true)

    @NSApplicationDelegateAdaptor(MagentXAppDelegate.self) private var appDelegate
    @State private var isMenuBarInserted: Bool
    private let modelContainer: ModelContainer

    /// 初始化 SwiftData 容器，并恢复菜单栏入口偏好。
    init() {
        do {
            let container = try Self.makeModelContainer()
            let enableMenuBar = GeneralSettings.load().enableMenuBar
            modelContainer = container
            Container.shared.magentProxyRuleService.register {
                MagentProxyRuleService(modelContainer: container)
            }
            _isMenuBarInserted = State(initialValue: enableMenuBar)
            MagentXAppDelegate.applyBackgroundPreference(enableMenuBar)
        } catch {
            let appError = MagentXError.modelContainerCreationFailed(error.localizedDescription)
            MagentXLogger.fault(
                appError,
                category: .persistence,
                message: "Failed to initialize SwiftData model container"
            )
            fatalError(appError.localizedDescription)
        }
    }

    var body: some Scene {
        Window("MagentX", id: Self.mainWindowID) {
            ContentView(isMenuBarInserted: $isMenuBarInserted)
        }
        .modelContainer(modelContainer)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra(
            "MagentX",
            image: "MenuBarIcon",
            isInserted: $isMenuBarInserted
        ) {
            MenuBarView(isMenuBarInserted: $isMenuBarInserted)
        }
        .modelContainer(modelContainer)
        .menuBarExtraStyle(.menu)
    }

    /// 创建应用 SwiftData 容器；Preview 可请求内存存储以隔离本地用户数据。
    ///
    /// - Parameter isStoredInMemoryOnly: 是否仅在内存中保存模型数据。
    /// - Returns: 注册全部 MagentX 持久化模型的容器。
    /// - Throws: 目录创建或 SwiftData 容器初始化失败时抛出原始错误。
    static func makeModelContainer(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            MagentProxyNode.self,
            MagentProxyRule.self,
            MagentProxyPolicy.self,
            MagentProxyPolicyRule.self
        ])
        if isStoredInMemoryOnly {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        let storeURL = localDirectoryURL.appendingPathComponent("MagentX.store", isDirectory: false)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
