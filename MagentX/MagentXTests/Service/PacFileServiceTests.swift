//
//  PacFileServiceTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for generated proxy host PAC files.
//

import Foundation
import Magent
import Testing
@testable import MagentX

/// `PacFileService` 生成和覆盖 PAC 文件的单元测试。
struct PacFileServiceTests {
    /// 验证访问规则会被写入完整 PAC 文件，并使用代理监听 host 和端口。
    @Test func writeProxyHostPACPersistsCompleteRuleFile() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let proxyEndpoint = try PacFileService.ProxyEndpoint(address: "127.0.0.1", port: 1086)
        let rules = [
            PacFileService.Rule(matchType: .domainSuffix, matchValue: "google.com", decision: "proxy", order: 100),
            PacFileService.Rule(matchType: .domainKeyword, matchValue: "telegram", decision: "proxy", order: 100),
            PacFileService.Rule(matchType: .ipCIDR, matchValue: "10.0.0.0/8", decision: "direct", order: 100),
            PacFileService.Rule(matchType: .urlRegex, matchValue: #"https?:\/\/.*\.example\.com"#, decision: "proxy", order: 100)
        ]

        let fileURL = try PacFileService.writeProxyHostPAC(
            rules: rules,
            proxyEndpoint: proxyEndpoint,
            directoryURL: directoryURL
        )
        let pac = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(fileURL.lastPathComponent == "proxy.pac")
        #expect(pac.contains("function FindProxyForURL(url, host)"))
        #expect(pac.contains(#"var proxy = "SOCKS5 127.0.0.1:1086; DIRECT";"#))
        #expect(pac.contains(#"{ type: "domainSuffix", value: "google.com", decision: "proxy" }"#))
        #expect(pac.contains(#"{ type: "domainKeyword", value: "telegram", decision: "proxy" }"#))
        #expect(pac.contains(#"{ type: "ipCIDR", value: "10.0.0.0", mask: "255.0.0.0", decision: "direct" }"#))
        #expect(pac.contains(#"{ type: "urlRegex", value: "https?:\\/\\/.*\\.example\\.com", decision: "proxy" }"#))
        #expect(pac.contains(#"return "DIRECT";"#))
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PacFileServiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}
