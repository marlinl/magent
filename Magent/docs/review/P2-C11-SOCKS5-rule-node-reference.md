---
id: SOCKS5-C11
title: "仅默认代理节点在初始化时校验"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: DESIGN_DECISION_REQUIRED
priority: P2
evidence: TEST_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C11：仅默认代理节点在初始化时校验

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§20.4、§20.7；C02。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)

## Cause

初始化 putAllProxyNodes 后仅检查 defaultDecision；rules 中的代理节点直到 routeTCPWire/routeUDPWire 被命中才检查。此前重构保留了这种惰性校验语义。

## 影响与复现边界

配置可以初始化成功，某个 TCP/UDP 目标首次命中时才失败，无法满足 spec 的“无效引用拒绝整个配置”。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecConfigurationRejectsMissingRuleNode`
- `testSpecMissingProxyDoesNotFallBackToDirect`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

若采用 spec，在完成节点表装载之后验证全部规则引用；失败时旧 runtime 不受影响。

### 修复方案

1. 确认由惰性校验迁移为配置时失败。
2. 直接在现有 MagentCore.init 的节点装载之后遍历默认决策及每条规则决策。
3. 维持完整节点表先装载后校验，不增加兼容别名、测试初始化器或事务框架。
4. 增加规则节点缺失的构造失败测试，并调整依赖坏配置构造的运行期回归用例。

依赖：C18、C20。

设计约束/决策：现有惰性规则引用校验是先前明确保留的合同；这里只记录 spec 迁移提案，尚未获得修改业务代码的授权。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// MagentCore.init 中，putAllProxyNodes(proxyNodes) 成功之后。
for decision in [defaultDecision] + rules.map(\.decision) {
  if case .proxy(let id) = decision, nodes[id] == nil {
    throw MagentError.proxyNodeNotFound(id)
  }
}
// 这会改变构造合同；不能在只修默认节点校验的工作中顺带引入。
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

- [ ] 默认/精确/后缀/CIDR 引用缺失均在构造阶段失败。
- [ ] 合法完整节点表通过；restart 新配置验证失败不会关闭旧 runtime。
- [ ] 运行期断链不回退 DIRECT 使用合法配置+真实节点失效来测试。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
