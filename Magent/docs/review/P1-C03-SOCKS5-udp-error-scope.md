---
id: SOCKS5-C03
title: "UDP 单包和单流错误升级为整个关联关闭"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: OPEN
priority: P1
evidence: TEST_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C03：UDP 单包和单流错误升级为整个关联关闭

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§14.5、§15.12、§18.2；U07/U08/U16/U18。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Connection/MagentTCPConnection.swift](../../Sources/Connection/MagentTCPConnection.swift)

## Cause

UDP channelRead 的同步 catch 和异步失败回调都调用 `proxyChannel.pipeline.fireErrorCaught`。MagentTCPConnection 统一关闭 accepted TCP，继而释放所有 UDP 资源，错误作用域丢失。

## 影响与复现边界

一个非零 FRAG、短包、陌生来源包或坏路由即可中断同关联中的正常目标；控制 TCP 已成功后，普通 UDP 失败不应变成父连接故障。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecUDPMalformedDatagramsDoNotCloseAssociation`
- `testSpecUDPStrangerPortIsDroppedWithoutClosingPinnedAssociation`
- `testSpecUDPRouteFailureDoesNotDestroyOtherFlows`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

UDP owning boundary 统一选择 packet drop、flow failure 或 association close；保留原始错误，不在 helper 中包装。

### 修复方案

1. 在 UDP handler 保存处理阶段/当前流，原始错误传播到 handler 一处分类。
2. 协议包错误/非法来源只计数、丢包并恢复读取。
3. DNS、拨号、代理通道错误只结束该 flow；不得降级 DIRECT 或重放旧包。
4. 仅父控制连接结束、入站中继不可恢复失效等关联级事件关闭整个关联。

依赖：C22；可先实现 packet drop，再接入 flow 级隔离。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 位于 Socks5UDPConnection 的统一错误边界；scope 根据阶段和原始 error 计算。
switch failureScope(error, phase: phase) {
case .datagram:
  recordDrop(error)
  context.read()
case .flow:
  closeCurrentFlow(error: error)
  context.read()
case .association:
  connection.proxyChannel.pipeline.fireErrorCaught(error)
}
// parse/resolve/encode 等 helper 不 catch-wrap-route；cleanup catch 后原样 rethrow。
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

- [ ] 每种坏包之后，同一合法客户端仍能完成往返。
- [ ] 单个代理流失败时已有 DIRECT 流继续；TCP 上不追加第二条 REP。
- [ ] 关联真正关闭仍释放所有子资源，不保留孤儿 flow。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
