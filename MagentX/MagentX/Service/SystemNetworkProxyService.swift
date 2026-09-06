//
//  SystemNetworkProxyService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Applies MagentX background service state to macOS network proxy settings.
//

import FactoryKit
import Foundation
import SystemConfiguration
import Combine

/// 监听当前 macOS 网络服务变化，并按 `CurrentSelection` 维护系统代理配置。
@MainActor
final class SystemNetworkProxyService: ObservableObject {
    /// MagentX 进程内唯一的系统代理协调服务。
    static let shared = SystemNetworkProxyService()

    /// 当前已持久化的后台代理服务选择，供所有界面入口共同显示。
    @Published private(set) var currentSelection: CurrentSelection
    /// 最近一次用户发起的服务切换错误，供界面显示和清除。
    @Published private(set) var serviceError: String?
    /// 是否正在应用服务状态，避免多个界面入口并发修改系统代理。
    @Published private(set) var isApplying = false

    @Injected(\.magentService) private var magentService
    private let systemProxyPreferences: SystemNetworkProxyPreferences
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var activeConfiguration: SystemNetworkProxyConfiguration?
    private let stateApplier: ((CurrentSelection, GeneralSettings) async throws -> Void)?
    private let loadCurrentSelection: () -> CurrentSelection
    private let saveCurrentSelection: (CurrentSelection) -> Void
    private let disableMagentProxyOperation: () throws -> Void
    private let stopPACServerOperation: @MainActor () async throws -> Void
    private let stopMagentOperation: @MainActor () async throws -> Void

    /// 创建系统网络代理协调服务。
    ///
    /// 默认构造直接读写应用选择并应用真实系统代理；可选依赖仅用于隔离服务状态事务测试。
    ///
    /// - Parameters:
    ///   - stateApplier: 测试时替换真实系统代理应用的闭包。
    ///   - loadCurrentSelection: 读取当前选择的持久化依赖。
    ///   - saveCurrentSelection: 保存当前选择的持久化依赖。
    ///   - disableMagentProxyOperation: 关闭系统代理的依赖；默认写入真实系统网络偏好。
    ///   - stopPACServerOperation: 停止 PAC 监听器的依赖；默认调用共享 Magent 服务。
    ///   - stopMagentOperation: 停止 Magent 核心监听器的依赖；默认调用共享 Magent 服务。
    init(
        stateApplier: ((CurrentSelection, GeneralSettings) async throws -> Void)? = nil,
        loadCurrentSelection: @escaping () -> CurrentSelection = { CurrentSelection.load() },
        saveCurrentSelection: @escaping (CurrentSelection) -> Void = { $0.save() },
        disableMagentProxyOperation: (() throws -> Void)? = nil,
        stopPACServerOperation: (@MainActor () async throws -> Void)? = nil,
        stopMagentOperation: (@MainActor () async throws -> Void)? = nil
    ) {
        let resolvedMagentService = Container.shared.magentService()
        let resolvedSystemProxyPreferences = SystemNetworkProxyPreferences()
        self.stateApplier = stateApplier
        self.loadCurrentSelection = loadCurrentSelection
        self.saveCurrentSelection = saveCurrentSelection
        self.systemProxyPreferences = resolvedSystemProxyPreferences
        self.disableMagentProxyOperation = disableMagentProxyOperation ?? {
            try resolvedSystemProxyPreferences.disableMagentProxy()
        }
        self.stopPACServerOperation = stopPACServerOperation ?? {
            try await resolvedMagentService.stopPACServer()
        }
        self.stopMagentOperation = stopMagentOperation ?? {
            try await resolvedMagentService.stop()
        }
        self.currentSelection = loadCurrentSelection()
    }

    /// 当前选择是否表示代理服务已启动。
    var isServiceStarted: Bool {
        currentSelection.state == .start
    }

    /// 从持久化存储重新读取当前服务选择。
    func reloadCurrentSelection() {
        currentSelection = loadCurrentSelection()
    }

    /// 按持久化状态恢复已启动的代理服务，并把结果反馈给共享界面状态。
    func applyStoredConfigurationIfNeeded() async {
        reloadCurrentSelection()
        guard currentSelection.state == .start, isApplying == false else { return }

        isApplying = true
        defer { isApplying = false }

        do {
            try await applyStoredConfiguration()
            serviceError = nil
            reloadCurrentSelection()
        } catch {
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to apply stored proxy service configuration",
                metadata: [
                    "state": currentSelection.state.rawValue,
                    "mode": currentSelection.mode.rawValue
                ]
            )
            serviceError = error.localizedDescription
        }
    }

    /// 启动代理服务，并且只在成功后持久化启动状态。
    func startService() async {
        await applyServiceState(.start)
    }

    /// 停止代理服务，并且只在成功后持久化停止状态。
    func stopService() async {
        await applyServiceState(.stop)
    }

    /// 在启动和停止状态之间切换代理服务。
    func toggleService() async {
        await applyServiceState(isServiceStarted ? .stop : .start)
    }

    /// 清除最近一次服务操作的界面错误提示。
    func clearServiceError() {
        serviceError = nil
    }

    /// 读取持久化配置并应用当前后台代理服务状态。
    func applyStoredConfiguration() async throws {
        try await apply(
            currentSelection: loadCurrentSelection(),
            generalSettings: GeneralSettings.load()
        )
    }

    /// 停止当前进程内的本地监听并清理 MagentX 写入的系统代理配置。
    func deactivateRuntimeServices() async {
        stopMonitoring()
        activeConfiguration = nil
        do {
            try systemProxyPreferences.disableMagentProxy()
        } catch {
            MagentXLogger.error(
                error,
                category: .systemProxy,
                message: "Failed to disable system proxy during runtime deactivation"
            )
        }
        do {
            try await stopLocalProxyServices()
        } catch {
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to stop local proxy services during runtime deactivation"
            )
        }
    }

    /// 开始监听当前网络服务变化；重复调用保持幂等。
    func startMonitoring() throws {
        guard dynamicStore == nil else { return }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "MagentX.SystemNetworkProxyService" as CFString,
            Self.dynamicStoreDidChange,
            &context
        ) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }

        let keys = [
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, nil) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        dynamicStore = store
        runLoopSource = source
        MagentXLogger.info("Started monitoring network service changes", category: .systemProxy)
    }

    /// 停止监听当前网络服务变化。
    func stopMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            MagentXLogger.info("Stopped monitoring network service changes", category: .systemProxy)
        }
        runLoopSource = nil
        dynamicStore = nil
    }

    /// 根据当前选择和系统设置应用后台服务状态。
    func apply(
        currentSelection: CurrentSelection,
        generalSettings: GeneralSettings
    ) async throws {
        let configuration = try SystemNetworkProxyConfiguration(
            currentSelection: currentSelection,
            generalSettings: generalSettings
        )

        guard configuration.state == .start else {
            stopMonitoring()
            activeConfiguration = nil
            try await apply(configuration: configuration)
            return
        }

        activeConfiguration = configuration
        do {
            try startMonitoring()
            try await apply(configuration: configuration)
        } catch {
            activeConfiguration = nil
            stopMonitoring()
            await stopLocalProxyServicesAfterFailedStart()
            throw error
        }
    }

    /// 串行应用用户请求的服务状态，并在成功后更新持久化和可观察选择。
    ///
    /// - Parameter state: 用户请求的后台服务状态。
    private func applyServiceState(_ state: BackgroundServiceState) async {
        guard isApplying == false else { return }

        isApplying = true
        defer { isApplying = false }

        var nextSelection = loadCurrentSelection()
        nextSelection.state = state

        do {
            let generalSettings = GeneralSettings.load()
            if let stateApplier {
                try await stateApplier(nextSelection, generalSettings)
            } else {
                try await apply(currentSelection: nextSelection, generalSettings: generalSettings)
            }
            saveCurrentSelection(nextSelection)
            currentSelection = nextSelection
            serviceError = nil
        } catch {
            currentSelection = loadCurrentSelection()
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to apply proxy service state",
                metadata: [
                    "requestedState": state.rawValue,
                    "currentState": currentSelection.state.rawValue,
                    "mode": currentSelection.mode.rawValue
                ]
            )
            serviceError = error.localizedDescription
        }
    }

    /// 应用已校验的运行配置，并统一协调本地服务和系统代理设置。
    ///
    /// - Parameter configuration: 当前后台服务、代理模式和监听端点快照。
    private func apply(configuration: SystemNetworkProxyConfiguration) async throws {
        switch configuration.state {
        case .stop:
            try disableMagentProxyOperation()
            try await stopLocalProxyServices()
        case .start:
            try await applyStartedMode(configuration: configuration)
        }
    }

    /// 启动 Magent 与 PAC 监听器，并按当前模式写入对应系统代理配置。
    ///
    /// - Parameter configuration: 已校验的启动模式和监听配置。
    private func applyStartedMode(configuration: SystemNetworkProxyConfiguration) async throws {
        MagentXLogger.info(
            "Starting proxy services",
            category: .service,
            metadata: [
                "mode": configuration.mode.rawValue,
                "proxyEndpoint": "\(configuration.proxyEndpoint.address):\(configuration.proxyEndpoint.port)",
                "pacEndpoint": "\(configuration.pacEndpoint.address):\(configuration.pacEndpoint.port)"
            ]
        )

        if case .tunnel = configuration.mode {
            try disableMagentProxyOperation()
            throw MagentXError.tunnelModeNotImplemented
        }

        try await magentService.start(
            address: configuration.proxyEndpoint.address,
            port: configuration.proxyEndpoint.port
        )
        try await magentService.startPACServer()

        switch configuration.mode {
        case .pac:
            try systemProxyPreferences.applyPAC(url: configuration.pacURL)
        case .global:
            try systemProxyPreferences.applySOCKS(endpoint: configuration.proxyEndpoint)
        case .tunnel:
            break
        }
    }

    /// 停止 PAC HTTP 和 Magent 核心监听器；二者均支持重复停止。
    private func stopLocalProxyServices() async throws {
        var firstError: Error?

        do {
            try await stopPACServerOperation()
        } catch {
            firstError = error
        }

        do {
            try await stopMagentOperation()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    /// 在启动失败后尽力停止本地监听器，同时保留触发启动失败的原始错误。
    private func stopLocalProxyServicesAfterFailedStart() async {
        do {
            try await stopLocalProxyServices()
        } catch {
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to stop local proxy services after startup failure"
            )
        }
    }

    /// 网络主服务变化后，按最近成功应用的启动配置重新写入系统代理项。
    private func handleNetworkChange() {
        guard let activeConfiguration, activeConfiguration.state == .start else { return }

        do {
            switch activeConfiguration.mode {
            case .pac:
                try systemProxyPreferences.applyPAC(url: activeConfiguration.pacURL)
            case .global:
                try systemProxyPreferences.applySOCKS(endpoint: activeConfiguration.proxyEndpoint)
            case .tunnel:
                break
            }
        } catch {
            MagentXLogger.error(
                error,
                category: .systemProxy,
                message: "Failed to reapply system proxy after network service change",
                metadata: ["mode": activeConfiguration.mode.rawValue]
            )
        }
    }

    /// 将 SystemConfiguration 的网络变化回调转交给主 actor 上的共享协调服务。
    private static let dynamicStoreDidChange: SCDynamicStoreCallBack = { _, _, info in
        guard let info else { return }
        let service = Unmanaged<SystemNetworkProxyService>
            .fromOpaque(info)
            .takeUnretainedValue()
        Task { @MainActor in
            service.handleNetworkChange()
        }
    }

    /// 读取最近一次 SystemConfiguration 调用的可展示错误文本。
    ///
    /// - Returns: SystemConfiguration 提供的错误描述。
    private static func systemConfigurationError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}

/// 系统代理应用所需的不可变配置快照。
private struct SystemNetworkProxyConfiguration {
    let state: BackgroundServiceState
    let mode: SystemProxyMode
    let proxyEndpoint: SystemNetworkProxyEndpoint
    let pacEndpoint: SystemNetworkProxyEndpoint

    var pacURL: URL {
        URL(string: "http://\(pacEndpoint.urlHost):\(pacEndpoint.port)/proxy.pac")!
    }

    /// 根据持久化选择和常规设置创建可跨异步边界使用的系统代理配置快照。
    ///
    /// - Parameters:
    ///   - currentSelection: 当前服务开关与代理模式选择。
    ///   - generalSettings: 本次启动使用的监听设置。
    init(
        currentSelection: CurrentSelection,
        generalSettings: GeneralSettings
    ) throws {
        self.state = currentSelection.state
        self.mode = currentSelection.mode
        self.proxyEndpoint = try SystemNetworkProxyEndpoint(
            address: generalSettings.proxyListenAddress,
            port: generalSettings.proxyListenPort
        )
        self.pacEndpoint = try SystemNetworkProxyEndpoint(
            address: generalSettings.pacListenAddress,
            port: generalSettings.pacListenPort
        )
    }
}

/// 已校验的系统代理端点。
private struct SystemNetworkProxyEndpoint {
    let address: String
    let port: Int

    var urlHost: String {
        address.contains(":") ? "[\(address)]" : address
    }

    /// 规范化并校验系统代理端点。
    ///
    /// - Parameters:
    ///   - address: 待校验的监听地址。
    ///   - port: 待校验的监听端口。
    init(address: String, port: Int) throws {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAddress.isEmpty == false else {
            throw MagentXError.invalidListenAddress(address)
        }
        guard (1...65535).contains(port) else {
            throw MagentXError.invalidListenPort(port)
        }

        self.address = normalizedAddress
        self.port = port
    }
}

/// macOS `SystemConfiguration` 代理偏好写入器。
private final class SystemNetworkProxyPreferences {
    private let preferenceName = "MagentX" as CFString

    /// 写入自动代理配置 URL。
    func applyPAC(url: URL) throws {
        try updateCurrentNetworkServices { proxyConfiguration in
            proxyConfiguration[kSCPropNetProxiesProxyAutoConfigEnable as String] = NSNumber(value: 1)
            proxyConfiguration[kSCPropNetProxiesProxyAutoConfigURLString as String] = url.absoluteString
            proxyConfiguration[kSCPropNetProxiesSOCKSEnable as String] = NSNumber(value: 0)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesSOCKSProxy as String)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesSOCKSPort as String)
        }
    }

    /// 写入全局 SOCKS 代理配置。
    func applySOCKS(endpoint: SystemNetworkProxyEndpoint) throws {
        try updateCurrentNetworkServices { proxyConfiguration in
            proxyConfiguration[kSCPropNetProxiesProxyAutoConfigEnable as String] = NSNumber(value: 0)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesProxyAutoConfigURLString as String)
            proxyConfiguration[kSCPropNetProxiesSOCKSEnable as String] = NSNumber(value: 1)
            proxyConfiguration[kSCPropNetProxiesSOCKSProxy as String] = endpoint.address
            proxyConfiguration[kSCPropNetProxiesSOCKSPort as String] = NSNumber(value: endpoint.port)
        }
    }

    /// 关闭 MagentX 管理的 PAC 和 SOCKS 系统代理项。
    func disableMagentProxy() throws {
        try updateCurrentNetworkServices { proxyConfiguration in
            proxyConfiguration[kSCPropNetProxiesProxyAutoConfigEnable as String] = NSNumber(value: 0)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesProxyAutoConfigURLString as String)
            proxyConfiguration[kSCPropNetProxiesSOCKSEnable as String] = NSNumber(value: 0)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesSOCKSProxy as String)
            proxyConfiguration.removeValue(forKey: kSCPropNetProxiesSOCKSPort as String)
        }
    }

    /// 锁定当前网络偏好，将给定变更应用到所有活跃网络服务并提交。
    ///
    /// - Parameter mutate: 对每个服务代理字典执行的原子修改。
    private func updateCurrentNetworkServices(
        mutate: (inout [String: Any]) -> Void
    ) throws {
        guard let preferences = SCPreferencesCreate(nil, preferenceName, nil) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }
        guard SCPreferencesLock(preferences, true) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }
        defer {
            SCPreferencesUnlock(preferences)
        }

        try updateProxyProtocols(in: preferences, mutate: mutate)

        guard SCPreferencesCommitChanges(preferences) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }
    }

    /// 遍历应更新的网络服务并写回其代理协议配置。
    ///
    /// - Parameters:
    ///   - preferences: 已锁定的系统网络偏好。
    ///   - mutate: 对每个服务代理字典执行的修改。
    private func updateProxyProtocols(
        in preferences: SCPreferences,
        mutate: (inout [String: Any]) -> Void
    ) throws {
        guard let currentSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
            throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
        }

        let activeServiceIDs = Self.activeServiceIDs()
        var didUpdateService = false

        for service in services where Self.shouldUpdate(service: service, activeServiceIDs: activeServiceIDs) {
            guard let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
                continue
            }

            var proxyConfiguration = (
                SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]
            ) ?? [:]
            mutate(&proxyConfiguration)

            guard SCNetworkProtocolSetConfiguration(proxyProtocol, proxyConfiguration as CFDictionary) else {
                throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
            }
            didUpdateService = true
        }

        guard didUpdateService else {
            throw MagentXError.systemNetworkProxyConfigurationFailed("No active network service found")
        }
    }

    /// 判断网络服务是否启用且属于当前活动连接。
    ///
    /// - Parameters:
    ///   - service: 待检查的系统网络服务。
    ///   - activeServiceIDs: IPv4 与 IPv6 当前主服务标识集合。
    /// - Returns: 是否应写入 MagentX 管理的代理配置。
    private static func shouldUpdate(
        service: SCNetworkService,
        activeServiceIDs: Set<String>
    ) -> Bool {
        guard SCNetworkServiceGetEnabled(service),
              let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
            return false
        }
        return activeServiceIDs.isEmpty || activeServiceIDs.contains(serviceID)
    }

    /// 读取 IPv4 与 IPv6 当前主网络服务标识。
    ///
    /// - Returns: 为空时表示无法识别主服务，调用方会退回更新所有启用服务。
    private static func activeServiceIDs() -> Set<String> {
        guard let store = SCDynamicStoreCreate(
            nil,
            "MagentX.SystemNetworkProxyPreferences" as CFString,
            nil,
            nil
        ) else {
            return []
        }

        let keys = [
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)
        ]
        return Set(keys.compactMap { key in
            guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
            return value["PrimaryService"] as? String
        })
    }

    /// 读取最近一次 SystemConfiguration 调用的可展示错误文本。
    ///
    /// - Returns: SystemConfiguration 提供的错误描述。
    private static func systemConfigurationError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}
