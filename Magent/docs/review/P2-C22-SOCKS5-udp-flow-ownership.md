---
id: SOCKS5-C22
title: "UDP 按远端端点记 Wire，缺少独立逻辑流所有权"
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

# SOCKS5-C22：UDP 按远端端点记 Wire，缺少独立逻辑流所有权

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§4.4、§15.1–15.12；R10/U11/U13/U16。
- 证据等级：`SOURCE_AND_LEGACY_TESTS`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [AGENTS.md](../../AGENTS.md)

## Cause

关联通过共享 v4/v6 socket 和 wireMap[SocketAddress] 记录回包；Core 按 node UUID 复用 UDP Wire。没有以 normalizedTarget+decision+outbound 为键、带状态和关闭资源的 flow。

## 影响与复现边界

已实现同关联多目标直接/SS 出口往返，但不具备 spec 的每目标 connected socket、上游独立控制通道、流内错误/队列/冷却隔离。不能仅凭共享 socket 宣称当前已发生串包；该错误尚未复现。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecUDPInterleavesDirectAndProxyTargetsWithoutInspectingDNSPayload`
- `testSpecUDPTwoAssociationsHaveIndependentPortsAndLifetime`
- `testSpecUDPRouteFailureDoesNotDestroyOtherFlows`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

关联拥有有限的每目标 flow；每个 flow 固定出口和远端并负责资源释放，父关联关闭统一清理。

### 修复方案

1. 判断采用 spec 每流隔离还是保留共享 socket 并明确不同验收合同。
2. 若迁移，在 Socks5Connection 现有文件内嵌套定义 flow 状态，避免独立 context actor/wrapper。
3. DIRECT flow 使用 connected UDP endpoint；SOCKS5 PROXY flow 拥有专属上游 control/data channels。
4. 只允许绑定远端的有效回包；Domain 代理回包的归属依赖专属可信通道，不查询 DNS 猜对应关系。
5. 关联每个新目标先做额度申请；flow 结束清理 maps/queue/timers，父关闭遍历并回收。

依赖：C03、C05、C06、C09、C17。

设计约束/决策：AGENTS 当前明确使用 actual outbound endpoint 与 Wire 映射；专属流是 spec 架构迁移方案，需先确定目标再替换。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 现有 Socks5UDPConnection 内的拟议真实状态。
enum FlowState { case opening, ready, failed, closed }
struct FlowKey: Hashable {
  let target: NetworkAddress
  let action: RouteAction // direct / proxy；REJECT 不创建 flow
  let outboundID: UUID? // 仅 proxy 必须非空，不能用 nil 表示选择失败
  let transport: Transport
}
// runtime 隔离由所属 Core/association 实例保证。
// flow owns: connected socket/control channel, bounded pending packets,
// deadline, selected endpoint, cooldown, lastActivity.
// 收到新包：route -> key -> lookup/create -> enqueue/send，不重放旧包。
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

- [ ] 补充同代理多个域名、同数值端点的不同逻辑目标、陌生回包、上游控制关闭和迟到回调测试。
- [ ] 已发送包从不多候选复制或自动重放，冷却结束只由新包触发新通道。
- [ ] 旧多目标正确性回归仍通过；不能把“同代理节点”当作“同业务流”。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
