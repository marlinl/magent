---
id: SOCKS5-C05
title: "握手和会话缺少绝对截止时间"
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

# SOCKS5-C05：握手和会话缺少绝对截止时间

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§18.5、§19.1；L01/U22。
- 证据等级：`TEST_PARTIAL`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/MagentTCPConnection.swift](../../Sources/Connection/MagentTCPConnection.swift)
- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Magent.swift](../../Sources/Magent.swift)

## Cause

当前 defaultTimeout 只用于出站连接和 DNS；没有从 accept 开始的绝对握手计时器，也没有 reply flush、TCP idle、half-close drain、UDP association/flow idle 的完整计时归属。

## 影响与复现边界

不完整握手在虚拟时钟超过 10 秒后仍存活，已复现。其他阶段缺口来自源码检查；不能把连接超时当作会话生命周期上限。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecHandshakeDeadlineIsAbsolute`
- `testSpecIncompleteHandshakeEOFAtEveryOffset`
- `testSpecUDPControlEOFReleasesRelayAndStopsForwarding`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

由已有 owner 保存并取消 EventLoop Scheduled，使用单调时间和总截止时间；无效活动不得续命。

### 修复方案

1. MagentTCPConnection 在 accept/channelActive 设一次 handshake deadline；收到单字节不重置，完整入站请求结束时取消。
2. Socks5Connection 保存 reply/drain/idle 定时器；flow 定时器放在 UDP flow owner。
3. 所有阶段取 min(phaseDeadline,totalDeadline)，关闭时取消，迟到回调检查 owner 状态。
4. 用 EmbeddedEventLoop 验证边界，避免依赖真实长时间 sleep。

依赖：C06、C22；固定默认值之后再接入真实配置。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// MagentTCPConnection 内新增真实生命周期字段；不是测试 hook。
handshakeTimeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
  guard let self, !self.hasCompleteInboundRequest, self.state != .closed else { return }
  self.serverChannel.close(promise: nil)
}
// 收到部分字节：不重新调度。
// 完整 request 被接受：
handshakeTimeout?.cancel()
handshakeTimeout = nil
// channelInactive/error cleanup 中取消全部所属定时器并清空引用。
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

- [ ] 10 秒绝对握手截止、回复写入截止和 half-close 排空截止均精确触发。
- [ ] 正常流量按定义刷新 idle；坏 UDP、REJECT 和只有 TCP 活着不刷新 UDP idle。
- [ ] 关闭后迟到定时器不重复回复、关闭或释放资源。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
