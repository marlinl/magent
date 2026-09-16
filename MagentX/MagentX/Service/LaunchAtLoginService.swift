//
//  LaunchAtLoginService.swift
//  MagentX
//
//  Responsibility: Registers the main app as a macOS login item.
//

import ServiceManagement

/// 管理 MagentX 主应用的 macOS 登录启动注册状态。
@MainActor
final class LaunchAtLoginService {
  private let statusProvider: () -> SMAppService.Status
  private let registerOperation: () throws -> Void
  private let unregisterOperation: () throws -> Void

  /// 当前主应用是否已获准在用户登录后启动。
  var isEnabled: Bool {
    statusProvider() == .enabled
  }

  /// 创建登录启动服务；可替换系统操作以隔离单元测试。
  ///
  /// - Parameters:
  ///   - statusProvider: 返回主应用当前 Service Management 状态。
  ///   - registerOperation: 注册主应用登录启动项的操作。
  ///   - unregisterOperation: 取消主应用登录启动项的操作。
  init(
    statusProvider: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
    registerOperation: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
    unregisterOperation: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
  ) {
    self.statusProvider = statusProvider
    self.registerOperation = registerOperation
    self.unregisterOperation = unregisterOperation
  }

  /// 按目标状态注册或取消主应用登录启动项；状态已满足时保持幂等。
  ///
  /// - Parameter isEnabled: 是否应在用户登录后启动 MagentX。
  /// - Throws: Service Management 返回的原始注册或取消注册错误。
  func setEnabled(_ isEnabled: Bool) throws {
    let status = statusProvider()
    if isEnabled {
      guard status != .enabled else { return }
      try registerOperation()
      return
    }

    guard status != .notRegistered, status != .notFound else { return }
    try unregisterOperation()
  }
}
