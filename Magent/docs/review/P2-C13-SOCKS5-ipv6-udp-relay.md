---
id: SOCKS5-C13
title: "UDP 入站中继硬编码 IPv4 控制连接"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: OPEN
priority: P2
evidence: TEST_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C13：UDP 入站中继硬编码 IPv4 控制连接

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§13.5；U01/U06。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)

## Cause

installUDPAssociate 用 guard case .ipv4 限定控制连接，固定发布 IPv4 relay。现有 IPv6 socket 只用于出站，不是面向 IPv6 客户端的入站中继。

## 影响与复现边界

::1 控制连接上的 ASSOCIATE 被返回 08；IPv4 客户端能够访问 IPv6 目标不能证明 IPv6 入站支持。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecIPv6ControlSupportsUDPAssociate`
- `testSpecUDPIPv6EmptyPayloadUsesTwentyTwoByteHeader`
- `testSOCKS5UDPAssociateRejectsIPv6ControlBecauseRelayIsIPv4`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

按控制连接具体本地地址族创建并发布对应入站 relay，同时独立处理出站地址族。

### 修复方案

1. 从 proxyChannel.localAddress 选择具体 IPv4/IPv6 地址，避免发布 wildcard。
2. 在既有 UDP handler 区分 clientRelayChannel 与 outbound 通道职责，不再假设 client 一定走 wireV4Channel。
3. IPv6 relay 使用正确 v6-only 策略；绑定成功且 handler 可用才回复。
4. 根据实际 localAddress 生成 10/22 字节成功回复，客户端测试按 ATYP 解码。

依赖：C01、C02、C22。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// installUDPAssociate 的拟议绑定选择。
let local = try concreteLocalAddress(of: proxyChannel)
let relayBind = try SocketAddress(ipAddress: local.ipAddress, port: 0)
return createRelay(on: proxyChannel.eventLoop, boundTo: relayBind)
  .flatMapThrowing { relay in
    self.clientRelayChannel = relay // 先让 owner 持有，后续失败也能清理
    return try networkAddress(of: relay.localAddress)
  }.flatMap { advertised in
    self.writeAssociateSuccess(advertised)
  }.map {
    self.clientRelayChannel?.read()
  }
// 每个回调检查 owner 存活；迟到成功/回复失败时 owner 关闭已创建 relay。
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

- [ ] 127.0.0.1/::1 两种控制入口分别发布可达的对应族 relay 并完成回包。
- [ ] 迁移旧的 IPv6 拒绝断言；不把环境缺 IPv6 当实现通过。
- [ ] 两种控制族都覆盖目标 IPv4/IPv6，以及控制关闭后的端口释放。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
