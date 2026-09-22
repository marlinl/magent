---
id: SOCKS5-C23
title: "UDP 缺少 spec 的完整报文大小和截断验收"
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

# SOCKS5-C23：UDP 缺少 spec 的完整报文大小和截断验收

状态：**能力未实现**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§14.5–14.6；U08/U21。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)

## Cause

Core 的固定 65535 接收缓冲并不等于 spec 的 65507 完整报文上限。parseUDPRelay/udpRelayResponse 没有完整输入/封装后输出的产品长度检查，也没有显式验证所用 NIO 接口的截断合同。

## 影响与复现边界

无法证明超长包按 spec 整包丢弃并计数。尚未复现底层截断后被错误转发；不得把“没有显式检查”写成“必然截断”的运行结论。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecUDPMalformedDatagramsDoNotCloseAssociation`
- `testSpecUDPIPv6EmptyPayloadUsesTwentyTwoByteHeader`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

解码前检查完整输入上限，编码前安全检查 header+payload 长度，确认适配器不会把截断数据当完整报文。

### 修复方案

1. 在 UDP owning boundary 检查客户端输入和各类回包的实际完整报文长度。
2. 采用减法或 reportingOverflow 处理加法，超限整包丢弃，不截断/拆包/降级 TCP。
3. 核对当前 NIO Datagram API/内核接收元数据能否满足截断契约；必要的适配变更必须保持同 EventLoop 和资源归属。
4. 测试受 macOS UDP 最大值影响时，用真实生产 codec/适配入口的确定性测试补足，环境限制独立报告。

依赖：C03、C06、C24。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
let maximumPacketBytes = 65_507
let headerBytes = encodedSourceAddress.count + 3
guard headerBytes <= maximumPacketBytes,
      payload.count <= maximumPacketBytes - headerBytes else {
  recordDrop(.encapsulationTooLarge)
  context.read()
  return
}
// 只有完整且未截断的 datagram 才编码；FRAG != 0 始终丢弃。
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

- [ ] 新增输入上限-1/上限/上限+1、IPv4/Domain/IPv6 回包封装超限和截断元数据用例。
- [ ] 坏包不关闭其他流；合法 0 字节载荷仍可往返。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | NOT_IMPLEMENTED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | NOT_IMPLEMENTED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
