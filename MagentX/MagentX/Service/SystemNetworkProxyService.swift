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

/// 监听当前 macOS 网络服务变化，并按 `CurrentSelection` 维护系统代理配置。
@MainActor
final class SystemNetworkProxyService {
    /// MagentX 进程内唯一的系统代理协调服务。
    static let shared = SystemNetworkProxyService()

    @Injected(\.magentServiceFactory) private var makeMagentService
    private let systemProxyPreferences = SystemNetworkProxyPreferences()
    private var magentProxyService: MagentProxyService?
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var activeConfiguration: SystemNetworkProxyConfiguration?

    /// 创建系统网络代理协调服务。
    init() {}

    /// 读取持久化配置并应用当前后台代理服务状态。
    func applyStoredConfiguration() async throws {
        try await apply(
            currentSelection: CurrentSelection.load(),
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
        activeConfiguration = configuration

        if configuration.state == .start {
            try startMonitoring()
        } else {
            stopMonitoring()
        }

        try await apply(configuration: configuration, generalSettings: generalSettings)
    }

    private func apply(
        configuration: SystemNetworkProxyConfiguration,
        generalSettings: GeneralSettings
    ) async throws {
        switch configuration.state {
        case .stop:
            try systemProxyPreferences.disableMagentProxy()
            try await stopLocalProxyServices()
        case .start:
            try await applyStartedMode(configuration: configuration, generalSettings: generalSettings)
        }
    }

    private func applyStartedMode(
        configuration: SystemNetworkProxyConfiguration,
        generalSettings: GeneralSettings
    ) async throws {
        let proxyService = try await configuredProxyService(generalSettings: generalSettings)
        MagentXLogger.info(
            "Starting proxy services",
            category: .service,
            metadata: [
                "mode": configuration.mode.rawValue,
                "proxyEndpoint": "\(configuration.proxyEndpoint.address):\(configuration.proxyEndpoint.port)",
                "pacEndpoint": "\(configuration.pacEndpoint.address):\(configuration.pacEndpoint.port)"
            ]
        )

        switch configuration.mode {
        case .pac:
            try await proxyService.startProxyServer()
            try await proxyService.startPacServer()
            try systemProxyPreferences.applyPAC(url: configuration.pacURL)
        case .global:
            try await proxyService.startProxyServer()
            try await proxyService.startPacServer()
            try systemProxyPreferences.applySOCKS(endpoint: configuration.proxyEndpoint)
        case .tunnel:
            try systemProxyPreferences.disableMagentProxy()
            throw MagentXError.tunnelModeNotImplemented
        }
    }

    private func configuredProxyService(generalSettings: GeneralSettings) async throws -> MagentProxyService {
        if let magentProxyService {
            try await magentProxyService.reload(generalSettings: generalSettings)
            return magentProxyService
        }

        let magentProxyService = try MagentProxyService(
            generalSettings: generalSettings,
            makeMagentService: makeMagentService
        )
        self.magentProxyService = magentProxyService
        return magentProxyService
    }

    private func stopLocalProxyServices() async throws {
        guard let magentProxyService else { return }
        try await magentProxyService.stopPacServer()
        try await magentProxyService.stopProxyServer()
    }

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

    private static let dynamicStoreDidChange: SCDynamicStoreCallBack = { _, _, info in
        guard let info else { return }
        let service = Unmanaged<SystemNetworkProxyService>
            .fromOpaque(info)
            .takeUnretainedValue()
        Task { @MainActor in
            service.handleNetworkChange()
        }
    }

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

    @MainActor
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

    private static func systemConfigurationError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}
