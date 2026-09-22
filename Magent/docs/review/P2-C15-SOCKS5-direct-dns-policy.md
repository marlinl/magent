---
id: SOCKS5-C15
title: "DIRECT 域名解析采用自定义 DNS 而非系统解析合同"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: DESIGN_DECISION_REQUIRED
priority: P2
evidence: SOURCE_AND_LEGACY_TESTS
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C15：DIRECT 域名解析采用自定义 DNS 而非系统解析合同

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§9、§10、§16；D02/D06/D07/U11。
- 证据等级：`SOURCE_AND_LEGACY_TESTS`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [Sources/Magent.swift](../../Sources/Magent.swift)

## Cause

UDP 依赖可选 dnsListener 和 DNSClient，组合 A/AAAA 查询并永久记录选中的地址；nil 时不支持域名。TCP 使用 connect(host:port:) 的名称拨号路径，缺少显式“解析→安全过滤→数值拨号”阶段。

## 影响与复现边界

现有远端 DNS 配置及测试与 spec 的 system-only/absolute-name 语义不同。缺 DNS 的 UDP 域名包会关闭整个关联；同时缺少可观察的 Resolver 调用计数和真实工作槽生命周期。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSOCKS5UDPDirectDomainRejectsMissingDNSAddress`
- `testSOCKS5UDPDirectDomainUsesConfiguredRemoteDNS`
- `testSpecUDPInterleavesDirectAndProxyTargetsWithoutInspectingDNSPayload`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

选择统一 DIRECT 解析合同；若采用 spec，系统解析产出受检数值候选，PROXY 业务域名不触发 Target DNS。

### 修复方案

1. 决定保留可配置远端 DNS 还是迁移 system resolver；不要静默改 dnsListener 的含义。
2. 优先采用符合约束的 NIO/平台现成解析能力；禁止临时创建线程池、Task.detached 或在 EventLoop 执行阻塞 getaddrinfo。
3. 真实解析任务槽直到任务退出才释放；超时只取消消费，不伪造任务完成。
4. UDP 固定一个被允许候选直到 flow 结束；TCP 有界竞速；传给连接器的始终是数值端点。

依赖：C04、C05、C06、C22。

设计约束/决策：当前 MagentConfig.dnsListener 和远端 DNS 测试是有效既有功能；迁移或扩展需要先选定产品合同。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// Core 的生产解析/拨号边界伪代码；Resolver 的注入必须服务真实配置。
return resolveAbsolute(domain, purpose: .targetDirect, deadline: deadline)
  .flatMapThrowing { candidates in
    guard owner.isAlive else { throw MagentError.connectionClosed }
    return try self.filterNumericCandidates(candidates)
  }.flatMap { allowed in
    self.connectNumericCandidates(allowed, deadline: deadline)
  }
// PROXY 分支不调用 resolveAbsolute(target)；节点 bootstrap 单独计数。
// UDP 选一个候选，不向多个候选复制业务包。
```

### 验证命令

从包根目录执行，先用 `swift test --filter <测试方法名>` 运行本篇引用的相关测试。实现涉及连接、并发、缓冲或清理时，完成改动后执行：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test --filter ConnectionTests
swift test
xcrun swift-format lint --strict Tests/Connection/Socks5ConnectionTests.swift
git diff --check
```

对其他修改过的 Swift 文件同样执行 strict lint。记录实际运行时间与版本，并分别报告普通通过、预期失败、意外失败、环境跳过及未执行项；文档修改只做静态检查，不能据此认定修复通过。

### 验收与关闭条件

- [ ] 直接域名真实使用所选系统解析策略；single-label 不经过隐式搜索后缀。
- [ ] 用生产 Resolver 边界分别计数 target/bootstrap；不能仅用抓包没看到 DNS 证明零调用。
- [ ] 迟到结果不拨号，真实工作槽有界；DIRECT 不按解析结果重新分流。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
