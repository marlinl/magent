//
//  SystemNetworkChangeListsner.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/15.
//

import Foundation
import OSLog
import SystemConfiguration

/// 维护 macOS 网络配置变化监听资源的完整生命周期。
///
/// 当前类型只负责注册、持有和释放系统监听资源；网络变化后的业务处理将在后续接入。
@MainActor
final class SystemNetworkChangeListsner {
  private var dynamicStore: SCDynamicStore?
  private var runLoopSource: CFRunLoopSource?

  isolated deinit {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      CFRunLoopSourceInvalidate(runLoopSource)
    }
  }

  /// 启动网络配置变化监听；已经启动时保持幂等。
  ///
  /// 副作用：在主运行循环中注册 IPv4、IPv6 和系统代理配置变化通知。
  func start() throws {
    guard dynamicStore == nil else { return }

    var context = SCDynamicStoreContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    guard
      let dynamicStore = SCDynamicStoreCreate(
        nil,
        "MagentX.SystemNetworkChangeListsner" as CFString,
        Self.dynamicStoreDidChange,
        &context
      )
    else {
      throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
    }

    let notificationKeys =
      [
        SCDynamicStoreKeyCreateNetworkGlobalEntity(
          nil,
          kSCDynamicStoreDomainState,
          kSCEntNetIPv4
        ),
        SCDynamicStoreKeyCreateNetworkGlobalEntity(
          nil,
          kSCDynamicStoreDomainState,
          kSCEntNetIPv6
        ),
        SCDynamicStoreKeyCreateProxies(nil),
      ] as CFArray
    guard SCDynamicStoreSetNotificationKeys(dynamicStore, notificationKeys, nil) else {
      throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
    }
    guard let runLoopSource = SCDynamicStoreCreateRunLoopSource(nil, dynamicStore, 0) else {
      throw MagentXError.systemNetworkProxyConfigurationFailed(Self.systemConfigurationError())
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    self.dynamicStore = dynamicStore
    self.runLoopSource = runLoopSource
    AppLog.network.info("Started monitoring system network changes")
  }

  /// 停止网络配置变化监听；尚未启动时保持幂等。
  ///
  /// 副作用：从主运行循环移除并释放当前监听资源。
  func stop() {
    guard dynamicStore != nil || runLoopSource != nil else { return }

    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      CFRunLoopSourceInvalidate(runLoopSource)
    }
    runLoopSource = nil
    dynamicStore = nil
    AppLog.network.info("Stopped monitoring system network changes")
  }

  /// 接收系统回调，但暂不接入任何业务处理。
  private func networkDidChange() {
    AppLog.network.debug("Detected a system network change")
  }

  /// 将 SystemConfiguration 回调转交给主 actor 上的监听器实例。
  private static let dynamicStoreDidChange: SCDynamicStoreCallBack = { _, _, info in
    guard let info else { return }
    let listener = Unmanaged<SystemNetworkChangeListsner>
      .fromOpaque(info)
      .takeUnretainedValue()
    Task { @MainActor in
      listener.networkDidChange()
    }
  }

  /// 读取最近一次 SystemConfiguration 调用的可展示错误文本。
  ///
  /// - Returns: SystemConfiguration 提供的错误描述。
  private static func systemConfigurationError() -> String {
    String(cString: SCErrorString(SCError()))
  }
}
