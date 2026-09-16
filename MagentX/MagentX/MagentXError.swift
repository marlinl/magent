//
//  MagentXError.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Defines app-wide errors for the MagentX target.
//

import Foundation

/// MagentX 应用层统一错误定义，约束 Controller、Service 和 Model 抛出的异常。
enum MagentXError: LocalizedError, Equatable {
  case invalidAclBase64Data
  case invalidAclDecodedText
  case invalidParameter(String)
  case duplicateMagentProxyRule
  case missingMagentProxyRule(Int)
  case missingMagentProxyNode(UUID)
  case missingGeneralSettings
  case listenPortUnavailable(String, Int)
  case modelContainerCreationFailed(String)
  case proxyNotRunning
  case systemNetworkProxyConfigurationFailed(String)
  case tunnelModeNotImplemented

  var errorDescription: String? {
    switch self {
    case .invalidAclBase64Data:
      return String(localized: "Downloaded rules data is not valid Base64")
    case .invalidAclDecodedText:
      return String(localized: "Decoded rules data is not valid UTF-8 text")
    case .invalidParameter(let message):
      return message
    case .duplicateMagentProxyRule:
      return String(localized: "Proxy rule already exists")
    case .missingMagentProxyRule(let id):
      return String(format: String(localized: "Proxy rule does not exist: %d"), id)
    case .missingMagentProxyNode(let id):
      return String(format: String(localized: "Proxy node does not exist: %@"), id.uuidString)
    case .missingGeneralSettings:
      return String(localized: "GeneralSettings is required before refreshing rules")
    case .listenPortUnavailable(let address, let port):
      return String(
        format: String(localized: "Listen port is already in use: %@:%d"), address, port)
    case .modelContainerCreationFailed(let reason):
      return String(
        format: String(localized: "Failed to create SwiftData model container: %@"), reason)
    case .proxyNotRunning:
      return String(localized: "No proxy service is running")
    case .systemNetworkProxyConfigurationFailed(let reason):
      return String(
        format: String(localized: "Failed to configure system network proxy: %@"), reason)
    case .tunnelModeNotImplemented:
      return String(localized: "Tunnel mode is not implemented yet")
    }
  }
}
