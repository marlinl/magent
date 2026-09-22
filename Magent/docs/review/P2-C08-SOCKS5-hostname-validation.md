---
id: SOCKS5-C08
title: "域名语法验证仅检查非空 UTF-8"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:54:44+08:00"
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

# SOCKS5-C08：域名语法验证仅检查非空 UTF-8

状态：**部分修复，仍待完成**。C09 已实现基础主机名校验；完整 IDNA、编码错误回复码和 UDP 单包错误作用域仍未验收，保持 OPEN。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:54:44+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§7.3–7.4、§25.2；P11/R03。
- 证据等级：`TEST_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Model/NetworkAddress.swift](../../Sources/Model/NetworkAddress.swift)

## Cause

原审查基线中，parseAddress 对 Domain 只执行 String(data:encoding:.utf8) 与非空判断，没有 ASCII/标签/总长度/危险字符/伪数值地址校验；路由未匹配时仍可使用默认出口。

## 影响与复现边界

原审查中 NUL、原始 Unicode、空白、非法标签、多个根点和非标准数值文本会进入代理链。C09 修复后上述基本语法用例已普通通过；空串/非法 UTF-8 仍返回 01，完整 A-label 校验未实现，UDP 非法单包仍可能关闭整个关联（C03）。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecRejectsInvalidDomainExpressionsBeforeOpeningProxy`（C09 后已普通通过）
- `testSpecInvalidDomainEncodingUsesAddressFailure`（从原测试拆出，保留 2 次严格预期失败）
- `testSpecConnectAddressVectorsAtEverySplit`

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

完整读取线协议 L 字节后再执行纯语法校验；不截断输入，不在校验时访问网络。

### 修复方案

1. 校验放到 NetworkAddress 现有文件中的生产地址规范化逻辑，由 TCP/UDP 共用。
2. 区分线协议长度最多 255 与去单个根点后主机名最多 253；每标签 1..63。
3. 拒绝 NUL、控制/空白和 spec 列出的分隔符；禁止首尾连字符、空标签。
4. A-label 的验证采用明确实现/版本；不自行编写不完整 Punycode 算法，也不能用 LDH 校验冒充全部 IDNA 校验。

依赖：C09、C12。

设计约束/决策：无；按对应 spec 条款实现，保持既有层次和资源归属。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 纯 Swift 风格伪代码，省略有效 A-label 验证依赖。
guard bytes.allSatisfy({ $0 < 128 }) else { throw AddressFailure.expression }
let name = String(decoding: bytes, as: UTF8.self)
let absolute = name.hasSuffix(".")
let matchName = absolute ? String(name.dropLast()) : name
guard !matchName.isEmpty, matchName.utf8.count <= 253 else { throw AddressFailure.expression }
for label in matchName.split(separator: ".", omittingEmptySubsequences: false) {
  try validateHostnameLabel(label) // 字节长度、字符、边界和有效 A-label
}
try rejectAmbiguousNumericHost(matchName)
// 标准 IPv4 文本由 C09 转换；非标准数字表示拒绝。
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

- [ ] 保持 1/253/254（末尾根点）/255 字节解析边界测试。
- [ ] 非法目标在 DNS、路由和拨号前被拒绝；TCP REP=08，UDP 仅丢包。
- [ ] 合法单标签/A-label 通过；不能把所有 254 字节名称一概拒绝。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |
| 2026-09-22T15:54:44+08:00 | OPEN | null（未提交工作树） | C09 补齐基础 ASCII/标签/数字表达校验；完整 IDNA、编码错误回复与 UDP 丢包验收尚未完成 |

[返回根因索引](README.md)
