---
id: SOCKS5-C18
title: "路由模型没有 REJECT、端口和业务传输条件"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: NOT_IMPLEMENTED
priority: P1
evidence: SOURCE_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C18：路由模型没有 REJECT、端口和业务传输条件

状态：**能力未实现**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§8.1–8.2、§20.4；R 系列/REQ-03。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Model/Decision.swift](../../Sources/Model/Decision.swift)
- [Sources/Model/ProxyRule.swift](../../Sources/Model/ProxyRule.swift)
- [Sources/Model/MatchType.swift](../../Sources/Model/MatchType.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)

## Cause

Decision 只有 direct/proxy；ProxyRule 只有单个 matchType/value；routeDecision 不接收 transport，缓存键也没有端口或传输。

## 影响与复现边界

无法表达阻止某目标、仅 UDP:53 走代理或多条件 AND；如只增加字段却不改缓存，会在 TCP/UDP 或不同端口间复用错误决策。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- 尚无对应可执行验收测试；能力实现后补充真实生产路径测试，不能用空测试或 skip 占位冒充覆盖。

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

以实际业务传输和规范化目标执行 AND/OR 组合规则，明确 REJECT 无 DNS/无 socket，缓存语义一致。

### 修复方案

1. 先定义版本化配置迁移，扩展现有 Decision、ProxyRule；保留支持类型在消费它们的现有 API 文件附近。
2. TCP/UDP 调用将 transport 和 port 传给 Core，不能把 UDP 的控制 TCP 当作业务 TCP。
3. 第一阶段可禁用路由缓存以保证正确；重新启用时键包含运行周期隔离、transport、addressType、地址、端口。
4. 检验 UDP 规则不能引用 TCP-only 节点；REJECT 在创建出站前结束。

依赖：C09、C10、C12、C20。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 真实模型扩展草案，不创建 forwarding protocol。
public enum Decision {
  case direct
  case proxy(UUID)
  case reject
}
// 规则命中：地址条件 AND 端口条件 AND 业务 transport 条件。
let decision = routeDecision(target, transport: .udp)
if decision == .reject { return dropWithoutDNSOrSocket() }
// TCP REJECT 在本地 request owning boundary 返回 REP=02。
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

- [ ] 新增同地址不同端口、TCP/UDP 相反决策、AND/OR 条件和缓存交叉污染测试。
- [ ] REJECT 的 DNS/节点连接计数为 0；UDP REJECT 不关闭其他流。
- [ ] 规则数组首命中还是现有 order 模式由 C10 决定，不混用。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | NOT_IMPLEMENTED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | NOT_IMPLEMENTED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
