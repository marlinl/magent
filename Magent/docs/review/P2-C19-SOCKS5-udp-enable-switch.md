---
id: SOCKS5-C19
title: "UDP ASSOCIATE 没有可配置关闭能力"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: NOT_IMPLEMENTED
priority: P2
evidence: SOURCE_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C19：UDP ASSOCIATE 没有可配置关闭能力

状态：**能力未实现**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§2.1、§18.1、§20.3；P10。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Magent.swift](../../Sources/Magent.swift)
- [Sources/Connection/MagentTCPConnection.swift](../../Sources/Connection/MagentTCPConnection.swift)
- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)

## Cause

MagentConfig 没有 UDP enabled 字段；任何合法 `.udpAssociate` 都进入资源建立过程。

## 影响与复现边界

调用方无法按 spec 发布 TCP-only 配置，也无法在禁用 UDP 时稳定返回命令不支持并保证零 UDP 资源。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- 尚无对应可执行验收测试；能力实现后补充真实生产路径测试，不能用空测试或 skip 占位冒充覆盖。

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

提供真实 UDP enabled 配置，关闭时在创建关联资源前返回 REP=07。

### 修复方案

1. 把开关纳入 MagentConfig 的产品配置并沿现有 init 调用链传入。
2. CONNECT 行为保持不受该开关影响；UDP 请求只能在 disabled 分支回复一次。
3. 禁用值不通过测试专用默认参数隐藏，测试完整构造生产配置。

依赖：C12、C20。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// Socks5Connection.installWireChannel 中的拟议前置检查。
case .udpAssociate:
  guard udpEnabled else { throw RequestFailure.command }
  try installUDPAssociate(sourceHint: address)
// RequestFailure.command 由 owning boundary 映射为 REP=07；没有 UDP socket。
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

- [ ] enabled=false 时 IPv4/IPv6/Domain 提示都走确定的命令不支持路径，且没有 UDP 绑定。
- [ ] enabled=true 的正常关联/回收回归保持通过。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | NOT_IMPLEMENTED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | NOT_IMPLEMENTED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
