---
id: SOCKS5-C07
title: "TCP 解析将当前消息之后的字节当作错误"
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

# SOCKS5-C07：TCP 解析将当前消息之后的字节当作错误

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§6.1、§6.4；P06/P07。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [AGENTS.md](../../AGENTS.md)

## Cause

checkInitalData 要求 requestLength == requestBuffer.readableBytes，且 reply 未完成时拒绝下一阶段字节。没有 consumed/remainder 或独立 earlyDataBuffer。

## 影响与复现边界

合法分片可以通过，但 greeting+request 粘包和 request+payload 会失败。该行为也被仓库 AGENTS 的严格请求/回复约定明确要求，不应当成无争议的局部 bug 自动改掉。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecCoalescedGreetingAndRequestPreservesReplyOrder`
- `testSpecEarlyDataWaitsForSuccessAndPreservesBytes`
- `testMagentTCPConnectionSendsSingleSOCKS5FailureWhenDirectConnectCompletesLate`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

若选择 spec 目标，则支持有界粘包和提前数据，保证方法选择/认证/请求回复先后顺序，成功前不发送业务 payload。

### 修复方案

1. 先记录选择：迁移到 spec，或保留严格模式并把 spec 条款明确版本化。
2. 迁移方案按当前阶段消费精确消息长度，保留 remainder；写回复完成回调推进下一阶段。
3. 握手本身使用独立最大长度；early data 64 KiB 上限并计入全局预算。
4. 出站成功且下游成功回复 flush 后才排空 early data；EOF 仍按顺序半关闭。

依赖：C05、C06。

设计约束/决策：AGENTS.md 原文："bytes received after a complete handshake request but before the local success reply are rejected." 当前文档仅提出迁移方案，不覆盖该约定。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 方案草案：取代整缓冲长度必须相等的约束。
guard let length = try requestLength(requestBuffer) else { return readMore() }
let request = requestBuffer.readSlice(length: length)!
let parsed = try parseRequest(request)
try reserveEarlyDataBytes(requestBuffer.readableBytes)
earlyData.writeBuffer(&requestBuffer)
// openOutbound -> writeSuccess -> flush 成功 -> drainEarlyData -> startRelay
// greeting 的 remainder 留在握手缓冲，方法选择写完后才继续解析。
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

- [ ] 选择 spec 后替换与新目标冲突的旧断言，并说明原因；不能保留两套相互矛盾的验收标准。
- [ ] 所有切分点、64 KiB 边界、EOF、写失败和迟到拨号均无乱序/重复回复。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
