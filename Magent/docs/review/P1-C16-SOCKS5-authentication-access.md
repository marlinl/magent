---
id: SOCKS5-C16
title: "仅支持无认证且缺少配套监听访问策略"
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

# SOCKS5-C16：仅支持无认证且缺少配套监听访问策略

状态：**能力未实现**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§5.2–5.3、§20.3、§21.1；P02/P03/C04。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Magent.swift](../../Sources/Magent.swift)

## Cause

方法选择固定寻找 00，状态机没有 RFC 1929 子协商；MagentConfig 没有认证策略、凭据验证边界和 client CIDR 等访问控制。当前 listener 配置可为非回环数值地址。

## 影响与复现边界

无法启用 spec 要求的用户名密码模式；非回环部署也无法表达 spec 的 authenticated LAN 合同。未对实际 LAN/公网部署进行测试，不能宣称已发生公网暴露。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- 尚无对应可执行验收测试；能力实现后补充真实生产路径测试，不能用空测试或 skip 占位冒充覆盖。

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

认证策略决定唯一可接受方法；用户密码模式绝不降级无认证，未获准来源在昂贵工作之前被拒绝。

### 修复方案

1. 真实认证配置和 SecretProvider 的边界先定在 MagentConfig/应用凭据层；库不能直接依赖 UI/Keychain。
2. 在 Socks5Connection 现有文件中扩展认证状态和纯字节解析；凭据长度按 UTF-8 字节计，禁止 trim/归一化。
3. 验证工作有界、可取消；失败统一发送 01 01 然后关闭，不解析后续业务请求。
4. 非回环监听先进行配置语义校验：LAN 显式启用、非空来源 CIDR、认证、明文风险策略。

依赖：C05、C06、C20、C24。

设计约束/决策：这是新增公开配置和协议能力；应用拥有凭据存储，库消费生产认证边界。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 方法选择拟议逻辑；本地与上游认证策略分别保存。
let selected: UInt8 = authentication.requiresPassword ? 0x02 : 0x00
guard offeredMethods.contains(selected) else {
  return writeNoAcceptableMethodsThenClose()
}
return writeMethodSelection(selected).map {
  self.state = selected == 0x02 ? .authentication : .request
}
// 认证请求 VER=01，ULEN/PLEN 为 1...255；验证失败只给 01 01。
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

- [ ] 新增 P02/P03 全部切分点、255 字节用户名/密码、错误版本、空长度、NUL 和失败后粘包用例。
- [ ] 同给 00/02 时严格遵循配置；本地/上游凭据互不混用。
- [ ] 不记录凭据或完整认证帧；LAN 负向配置测试不实际向公网监听。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | NOT_IMPLEMENTED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | NOT_IMPLEMENTED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
