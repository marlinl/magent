---
id: SOCKS5-C10
title: "路由使用优先级及特异度而不是配置顺序首命中"
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

# SOCKS5-C10：路由使用优先级及特异度而不是配置顺序首命中

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§8.3；R06。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [Sources/Model/ProxyRule.swift](../../Sources/Model/ProxyRule.swift)

## Cause

MagentRouter 使用较小 order、较高 specificity 和较早 sequence 比较；同类型同值规则后者覆盖前者。这是当前显式设计及现有 Core 测试的语义。

## 影响与复现边界

相同输入规则数组在 spec 算法与当前算法下可能选不同出口；直接删掉排序/去重会改变现有配置行为。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecRoutingUsesFirstConfiguredMatch`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

选择并固定一种可解释的优先级；若采用 spec，则按传入配置数组首条匹配，不以特异度或重复覆盖改变结果。

### 修复方案

1. 明确 order 是否只由应用层用于生成最终数组，或决定保留现有优先级并修改目标规格。
2. spec 方案以数组顺序为权威；可以保留索引加速，但候选最终比较只能用数组位置。
3. 重复匹配项保留首条可命中的语义；不能 silently last-write-wins。
4. 迁移 Core 的旧特异度/重复覆盖测试，保留正常 CIDR 和域名边界回归。

依赖：C09、C18。

设计约束/决策：现有 `ProxyRule.order` 和 Core 测试明确支持不同语义；这是配置行为迁移，不能仅为使 spec 测试变绿自动改变。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// MagentRouter.match 的 spec 基准算法（先正确，后在等价性测试下优化）。
for rule in rulesInConfigurationOrder {
  if matches(rule, target: normalizedTarget, transport: transport) {
    return rule.decision
  }
}
return nil // 由 Core 应用默认动作
// 不按 specificity 重新选优，也不删除较早的重复规则。
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

- [ ] 后缀/精确规则重叠、CIDR 重叠、重复规则、order 与数组逆序均服从选定合同。
- [ ] 新旧配置迁移影响有明确示例；未决定时保留 DESIGN_DECISION_REQUIRED。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
