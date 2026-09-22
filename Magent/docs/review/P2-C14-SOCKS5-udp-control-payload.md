---
id: SOCKS5-C14
title: "UDP 控制态静默忽略额外 TCP 字节"
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

# SOCKS5-C14：UDP 控制态静默忽略额外 TCP 字节

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§6.5、§26 U22。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)

## Cause

upstream 的 `.idle` 分支只有 context.read()，任意非空 TCP 数据都被丢弃后继续读取，没有定义为控制连接协议误用。

## 影响与复现边界

关联建立后的额外 TCP 业务数据无法被发现并按 spec 终止，控制态和隧道态职责不明确。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecUDPControlDataIsProtocolMisuse`
- `testSpecUDPControlEOFReleasesRelayAndStopsForwarding`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

成功建立 UDP 关联后，任何非空控制 TCP 输入都经统一 owning boundary 关闭关联，不再发送 REP。

### 修复方案

1. 保留函数顶部对空 ByteBuffer 的处理；仅非空 idle 输入触发协议误用。
2. 通过 MagentTCPConnection 的既有错误/关闭链结束 accepted Channel。
3. TCP closeFuture 触发 UDP 资源清理；确保不递归关闭且不追加成功/失败帧。

依赖：无。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// Socks5Connection.upstream：空输入已在 switch 之前处理。
case .idle:
  proxyChannel.pipeline.fireErrorCaught(
    MagentError.malformedRequest("SOCKS5 UDP control connection received payload")
  )
// 不调用 respondProxyChannelOnce；ASSOCIATE 已经回复过。
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

- [ ] 发送 1 字节或完整伪 CONNECT 都终止关联；收到的控制回复仍只有原来一次。
- [ ] 中继端口被释放；后续 UDP 不再转发。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
