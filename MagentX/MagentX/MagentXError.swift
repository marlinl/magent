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
    case anotherInstanceRunning
    case singleInstanceLockFailed(String)
    case invalidAclBase64Data
    case invalidAclDecodedText
    case duplicateAccessControlRule
    case missingAccessControlRule(UUID)
    case missingMagentProxyNode(UUID)
    case proxyNodeInUse(UUID)
    case missingGeneralSettings
    case missingRulesURL
    case invalidRulesURL(String)
    case invalidURL
    case invalidListenAddress(String)
    case invalidListenPort(Int)
    case listenPortUnavailable(String, Int)
    case invalidProxyThreadNumber(Int)
    case modelContainerCreationFailed(String)
    case proxyNotRunning
    case systemNetworkProxyConfigurationFailed(String)
    case tunnelModeNotImplemented
    case emptyName
    case emptyAddress
    case invalidPort
    case emptyPassword
    case invalidTimeout

    var errorDescription: String? {
        switch self {
        case .anotherInstanceRunning:
            return String(localized: "MagentX is already running")
        case .singleInstanceLockFailed(let reason):
            return String(localized: "Failed to acquire the single-instance lock: \(reason)")
        case .invalidAclBase64Data:
            return String(localized: "Downloaded rules data is not valid Base64")
        case .invalidAclDecodedText:
            return String(localized: "Decoded rules data is not valid UTF-8 text")
        case .duplicateAccessControlRule:
            return String(localized: "Access control rule already exists")
        case .missingAccessControlRule(let id):
            return String(format: String(localized: "Access control rule does not exist: %@"), id.uuidString)
        case .missingMagentProxyNode(let id):
            return String(format: String(localized: "Proxy node does not exist: %@"), id.uuidString)
        case .proxyNodeInUse(let id):
            return String(format: String(localized: "Proxy node is referenced by a policy: %@"), id.uuidString)
        case .missingGeneralSettings:
            return String(localized: "GeneralSettings is required before refreshing rules")
        case .missingRulesURL:
            return String(localized: "Rules URL is required")
        case .invalidRulesURL(let value):
            return String(format: String(localized: "Invalid rules URL: %@"), value)
        case .invalidURL:
            return String(localized: "Invalid URL")
        case .invalidListenAddress:
            return String(localized: "Listen address is required")
        case .invalidListenPort(let port):
            return String(format: String(localized: "Listen port is invalid: %d"), port)
        case .listenPortUnavailable(let address, let port):
            return String(format: String(localized: "Listen port is already in use: %@:%d"), address, port)
        case .invalidProxyThreadNumber(let number):
            return String(format: String(localized: "Proxy thread number is invalid: %d"), number)
        case .modelContainerCreationFailed(let reason):
            return String(format: String(localized: "Failed to create SwiftData model container: %@"), reason)
        case .proxyNotRunning:
            return String(localized: "No proxy service is running")
        case .systemNetworkProxyConfigurationFailed(let reason):
            return String(format: String(localized: "Failed to configure system network proxy: %@"), reason)
        case .tunnelModeNotImplemented:
            return String(localized: "Tunnel mode is not implemented yet")
        case .emptyName:
            return String(localized: "Name is required")
        case .emptyAddress:
            return String(localized: "Address is required")
        case .invalidPort:
            return String(localized: "Port must be an integer from 1 to 65535")
        case .emptyPassword:
            return String(localized: "Password is required")
        case .invalidTimeout:
            return String(localized: "Timeout must be greater than 0")
        }
    }
}
