---
id: SOCKS5-C04
title: "业务目标缺少强制安全检查及自回环检查"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: OPEN
priority: P1
evidence: TEST_PARTIAL
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C04：业务目标缺少强制安全检查及自回环检查

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§7.2、§21.2–21.5；S01–S04。
- 证据等级：`TEST_PARTIAL`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [Sources/Magent.swift](../../Sources/Magent.swift)

## Cause

解析结果直接进入 routeTCPWire/routeUDPWire。Core 没有在路由之前或 DIRECT 解析结果之后应用安全策略，也没有用实际 listener/relay endpoints 阻止自回环。

## 影响与复现边界

回环、未指定、组播、link-local 等 spec 禁止目标会被转发给假代理节点（已复现）。自回环与 DNS 结果绕过尚未做运行复现，只确认缺少对应防护入口。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecForbiddenNumericTargetsAreRejectedBeforeProxyDial`
- `testSpecMappedIPv6CannotBypassIPv4Rule`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

在 Core 的真实路由/拨号边界校验目标；DIRECT DNS 后逐候选检查并仅向数值地址拨号。

### 修复方案

1. 把安全策略作为 MagentConfig 的真实产品字段，默认值与 spec 一致；显式区分业务目标和配置的代理基础设施。
2. 在现有 NetworkAddress 中统一 mapped IPv6；Core 路由前做数值/域名基础检查。
3. DIRECT Resolver 返回数值候选后逐项过滤；全部拒绝映射为 REP=02。
4. 由 Magent/runtime 维护实际 listener 和活动 relay 端点，拒绝连接自身；不能仅比较 127.0.0.1 字符串。

依赖：C09、C12、C15；安全配置职责需与 C20 明确。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// MagentCore 中拟议执行顺序；PROXY domain 不做 Target DNS。
let normalized = try target.normalized()
try validateBusinessTarget(normalized, policy: security)
let decision = routeDecision(normalized, transport: transport)
if decision == .direct, normalized.isDomain {
  return resolveAbsolute(normalized).flatMapThrowing { candidates in
    let allowed = candidates.filter { self.isAllowedNumericTarget($0) }
    guard !allowed.isEmpty else { throw RequestFailure.notAllowed }
    return allowed  // 下一步只接受这些数值候选，禁止重新按域名拨号。
  }
}
// 代理 bootstrap 使用独立政策；允许显式 loopback 节点但仍禁止自身端点。
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

- [ ] 补充 DIRECT 和 UDP 同类安全用例；默认禁用回环后将本机测试显式配置成允许受控业务回环。
- [ ] DNS 候选全部受检；禁止结果不会触发二次解析。
- [ ] 自身端点及 mapped IPv6/节点域名回环被拒绝；外部 loopback 节点仍可使用。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
