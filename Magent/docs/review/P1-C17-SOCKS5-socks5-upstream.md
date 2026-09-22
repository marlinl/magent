---
id: SOCKS5-C17
title: "出站只有原生 Shadowsocks，缺少 SOCKS5 上游状态机"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: DESIGN_DECISION_REQUIRED
priority: P1
evidence: SOURCE_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C17：出站只有原生 Shadowsocks，缺少 SOCKS5 上游状态机

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§11、§15.4–15.10、§17；O01–O10/U12–U18。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Model/ProxyNode.swift](../../Sources/Model/ProxyNode.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)
- [Sources/Wire/Wire.swift](../../Sources/Wire/Wire.swift)
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)

## Cause

ProxyNodeType 只有 shadowsocks；Core 构造 Shadowsocks Wire。没有独立上游方法/认证/CONNECT 回复状态，也没有上游 UDP ASSOCIATE 控制连接。

## 影响与复现边界

不能把 sslocal 的 SOCKS5 端口作为现有 SS 节点使用；SS 加密握手成功不等于 spec 的上游 SOCKS5 握手成功。当前架构文档又明确支持原生 SS，与 spec 的“本版本不实现原生 SS”不同。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testMagentTCPConnectionWritesShadowsocksHandshakeAndEstablishesSOCKS5Connect`
- `testSOCKS5UDPShadowsocksDataPlaneEncryptsRoutesAndDecryptsResponse`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

明确选择增加 SOCKS5 出站还是保留现有出站范围。若实现 spec，完整校验上游握手后才回复本地成功，UDP 使用真实上游 ASSOCIATE。

### 修复方案

1. 决定原生 SS 是保留为扩展能力还是另行迁移；不得擅自删除有效 SS 功能。
2. node 类型、认证、UDP 能力、relay allowlist 都是实际产品配置；不要塞进测试专用 flags。
3. Wire 保持纯远端编解码/状态，不拥有 Channel；Connection/Core 现有 owner 负责所有上游 TCP/UDP 资源。
4. 协议状态需要消费长度/余留字节；BND 校验区分 CONNECT 回复信息与 UDP 实际中继端点。
5. 外部 sslocal 固定版本，单独验证 TCP/UDP、DNS/ACL 和无 DIRECT 回退。

依赖：C05、C06、C07、C12、C16、C20、C22。

设计约束/决策：新 Swift 文件必须按 AGENTS 的文件规则单独评估；本提案不是新增源文件的授权。可选 TLS 未实现本身不算基础 spec 缺陷，但不能接受 TLS 配置后静默退回明文。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 远端协议状态草案，放在获得批准的既有 owner 文件中。
enum UpstreamPhase {
  case methodSelection
  case authentication
  case requestReply
  case ready
  case closed
}
// 收到完整合法请求回复后：
if reply.rep == 0 {
  phase = .ready
  // 保留 remainder；先完成下游成功回复，再交付 server-first payload。
} else {
  // 用结构有效的 01...08 失败码结束，不重试/重放或切 DIRECT。
}
// UDP 必须另建控制 TCP，并向经验证的 BND UDP endpoint 发数据。
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

- [ ] 上述旧测试仅证明原生 SS，不计入 SOCKS5 上游验收；新增 O/U 的可观察假 SOCKS5 上游测试。
- [ ] 上游提前数据、非法 method/VER/RSV/ATYP/REP、失败认证与截断全部覆盖。
- [ ] 每个 TCP 隧道和 UDP flow 的控制资源独立；无默认 DIRECT、无旧数据重放。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
