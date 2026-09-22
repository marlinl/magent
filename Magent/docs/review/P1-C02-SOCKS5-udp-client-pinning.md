---
id: SOCKS5-C02
title: "UDP 首包缺少 TCP 对端校验且过早固定来源"
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

# SOCKS5-C02：UDP 首包缺少 TCP 对端校验且过早固定来源

状态：**待修复**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§13.4、§14.4、§21.6；U05/S08。
- 证据等级：`TEST_PARTIAL`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)

## Cause

`Socks5UDPConnection.channelRead` 在 parseUDPRelay 和目标检查之前直接赋值 `sourceAddress`；没有将 UDP 来源 IP 与 TCP 控制对端比较。关联 IPv4 socket 还绑定在 wildcard 地址。

## 影响与复现边界

能到达关联端口的另一来源可能抢先固定关联或用畸形首包干扰合法客户端。错误端口抢占已复现；跨 IP 测试因本机未配置 127.0.0.2 跳过，不能宣称已运行验证跨 IP 攻击。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecUDPFirstSenderMustMatchControlPeerIP`
- `testSpecUDPExplicitSourcePortMustBeHonored`
- `testSpecUDPStrangerPortIsDroppedWithoutClosingPinnedAssociation`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

先核对来源、检查完整数据报和目标，再固定首个合法源端口；来源不符只丢包。

### 修复方案

1. 采用 C01 保存的 expectedClientIP/Port；比较前统一 mapped IPv6 表示。
2. 使用来源端点判断 client / known backend / stranger，不能把任意陌生端点当业务输入。
3. 先完整解析 UDP 头和基础目标安全检查，再将端口从 nil 变成固定值。
4. 尽量把入站中继绑定为 TCP 连接的具体本地地址；后续不允许端口重绑定。

依赖：C01、C03、C04、C09。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 在现有 UDP handler 的 owning boundary 内；该分支处理客户端入站。
guard packet.source.normalizedIP == expectedClientIP else {
  recordDrop(.sourceMismatch)
  resumeRead()
  return
}
guard expectedClientPort.map({ $0 == packet.source.port }) ?? true else {
  recordDrop(.sourceMismatch)
  resumeRead()
  return
}
let request = try parseAndValidateDatagram(packet)
try checkBasicTargetSafety(request.target)
if expectedClientPort == nil { expectedClientPort = packet.source.port }
// 此处才允许创建/查找目标流。
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

- [ ] 受控环境提供第二个回环 IP 后，跨 IP 包不转发、不固定端口、不关闭合法关联。
- [ ] 畸形首包不固定端口；合法来源后续可正常往返。
- [ ] 错误端口和伪造后台来源不污染 flow/source 映射。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
