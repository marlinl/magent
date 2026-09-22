---
id: SOCKS5-C12
title: "底层错误丢失与请求阶段分类不足"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: OPEN
priority: P2
evidence: TEST_PARTIAL
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C12：底层错误丢失与请求阶段分类不足

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§18；P09/O05/O06。
- 证据等级：`TEST_PARTIAL`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/MagentError.swift](../../Sources/MagentError.swift)

## Cause

Core 把原始连接错误转换成 channelCreationFailed(String)，SOCKS5 又把广义 invalidAddress/invalidOptions 映射成固定 REP。映射缺少 direct/proxy、解析/端口/版本等阶段信息。

## 影响与复现边界

零端口 08 而非 01；DIRECT ECONNREFUSED 01 而非 05；缺失代理 03 而非 01；错误请求版本发 REP 而非直接关闭（已复现）。普通建连超时映射 04 的差异仅由源码确认。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecZeroConnectPortUsesGeneralFailure`
- `testSpecDirectConnectionRefusalUsesREP05`
- `testSpecInvalidRequestVersionClosesWithoutReply`
- `testSpecMissingProxyDoesNotFallBackToDirect`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

原始错误沿 helper 原样传播，在最高 owning boundary 根据阶段决定回复/日志/关闭，且只回复一次。

### 修复方案

1. 移除 Core 中仅重命名错误的 catch/flatMapErrorThrowing；保留必要 cleanup 后 rethrow 原错。
2. 在 Socks5Connection 的请求状态中保留真实建立阶段，区分业务目标与节点连接。
3. 解析错误使用明确的协议分类：version、RSV、address expression、zero port；避免读字符串判断。
4. 多候选 DIRECT 错误按 spec 集合归并；reply flush 受 C05 截止时间约束。

依赖：C05；新增语义错误类型须有实际生产用途。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// Socks5Connection 的统一请求失败边界；伪代码中的 stage 为真实状态。
if failure == .requestVersion { return closeWithoutReply() }
let rep: UInt8
switch (stage, error) {
case (.directConnect, let io as IOError) where io.errnoCode == ECONNREFUSED:
  rep = 0x05
case (.directDNS, _): rep = 0x04
case (.proxyConnect, _), (.proxyHandshake, _): rep = 0x01
case (_, RequestFailure.zeroPort): rep = 0x01
case (_, RequestFailure.addressType): rep = 0x08
case (_, RequestFailure.notAllowed): rep = 0x02
case (_, RequestFailure.command): rep = 0x07
default: rep = 0x01
}
// 原始 error 保留给日志/关闭；具体 NIO 多候选错误还需展开归并。
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

- [ ] 精确断言完整 10 字节失败帧以及关闭，不只断言 REP。
- [ ] 节点拒绝不报告为目标拒绝；超时不报告为 TTL 到期。
- [ ] 成功后的流错误不插入第二条 SOCKS 回复；取消和迟到回调不重复回复。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
