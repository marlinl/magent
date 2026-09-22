---
id: SOCKS5-C06
title: "会话、UDP 映射和缓冲缺少共享资源预算"
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

# SOCKS5-C06：会话、UDP 映射和缓冲缺少共享资源预算

状态：**能力未实现**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，INV-10、§19.2–19.4；L04/L07/U19。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Magent.swift](../../Sources/Magent.swift)
- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)

## Cause

MagentConfig 明确不限制接入连接数；UDP wireMap/resolvedAddressMap 没有容量或过期规则。没有跨连接 socket、buffer、DNS 排队的统一配额。maxMessagesPerRead=1 和单个请求长度检查不等价于全局预算。

## 影响与复现边界

长时间持有控制连接并访问不同目标可能持续积累资源。这里确认的是缺少预算机制，尚未执行耗尽系统资源的压力验证。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- 尚无对应可执行验收测试；能力实现后补充真实生产路径测试，不能用空测试或 skip 占位冒充覆盖。

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

所有真实资源在分配前获取额度，在 owner 结束时恰好释放一次；不会用无界等待隐藏过载。

### 修复方案

1. 在 Magent 现有文件中定义服务拥有的预算状态；跨 EventLoop 的共享计数必须同步，不能使用普通无锁 Int。
2. 关联内 flow 计数由该 EventLoop 串行管理；全局额度原子申请或在既有 lifecycle owner 中串行申请。
3. 给 socket、handshake、UDP pending packet/bytes 和真实 DNS 工作槽分别计量。
4. 读取前申请 buffer 额度，失败按阶段拒绝/丢新包；不能先收无限 Data 再检查。

依赖：C05、C22；默认配额改变现有无限接入语义，纳入版本化配置决策。

设计约束/决策：本项是 spec 新能力，不以既有“可接受超过 256 个连接”测试证明符合或不符合 512 上限；保留该旧测试在合法配额内运行。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 伪代码：预算是服务资源约束，不是另一层业务 router。
guard budget.tryAcquireSocket() else { throw ResourceFailure.socketLimit }
return createChannel().map { channel in
  channel.closeFuture.whenComplete { _ in budget.releaseSocket() }
  return channel
}.flatMapError { error in
  budget.releaseSocket()
  return eventLoop.makeFailedFuture(error) // 保留原始错误
}
// 成功路径交给 closeFuture；失败路径自己归还，两个路径不得同时归还。
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

- [ ] 用小配额真实配置确定性测试上限、上限+1、失败回滚和取消竞争。
- [ ] 每流 drop-newest 同时检查包数和字节数；所有额度最终归零。
- [ ] 读取实际 FD 限制并保留系统余量；压力数据与应用缓冲/RSS 分别报告。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | NOT_IMPLEMENTED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | NOT_IMPLEMENTED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
