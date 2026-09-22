---
id: SOCKS5-C20
title: "配置 API 不具备 spec 的 schema 与完整语义校验"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:27:18+08:00"
timezone: Asia/Shanghai
status: DESIGN_DECISION_REQUIRED
priority: P2
evidence: SOURCE_CONFIRMED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
---

# SOCKS5-C20：配置 API 不具备 spec 的 schema 与完整语义校验

状态：**待设计决策**。本文件是审查与修复提案；当前没有业务代码修复提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:27:18+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§20；C01–C04/C08。
- 证据等级：`SOURCE_CONFIRMED`，含义见 [索引](README.md)。
- 测试来自上轮追加的未提交工作树，指纹见元数据；不能把它们归到基线 commit。

涉及文件与 owner：

- [Sources/Magent.swift](../../Sources/Magent.swift)
- [Sources/Model/ProxyRule.swift](../../Sources/Model/ProxyRule.swift)
- [Sources/Model/ProxyNode.swift](../../Sources/Model/ProxyNode.swift)
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)

## Cause

当前库消费类型化 MagentConfig，validate 只检查部分地址/超时/DNS。spec 的 JSON schema、重复键/未知字段校验、完整配置导出、凭据引用等没有对应入口；应用拥有 persistence/import 的现有边界也需保留。

## 影响与复现边界

不能将类型化构造成功等同于 C01–C08 验收通过；仅用普通 JSONDecoder 会漏掉未知键或重复键要求。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- 尚无对应可执行验收测试；能力实现后补充真实生产路径测试，不能用空测试或 skip 占位冒充覆盖。

严格 `XCTExpectFailure` 表示已知 spec 差异，不代表实现符合规格；若引用旧测试，它只证明当前旧行为。完整基线结果见 [索引](README.md#验证基线)。

## Goal

确定 schema 属于库还是应用适配层；类型化语义校验始终在真实配置边界完成，错误字段可定位且不泄漏秘密。

### 修复方案

1. 固定职责：应用负责导入/存储/SecretProvider，库负责完整 MagentConfig 的语义和引用校验；若库新增导入 API，需明确产品需求。
2. JSON 严格校验应在任何会折叠重复键的 dictionary 解码之前完成。
3. 加载全部配置与凭据后一次性校验；默认填充后导出生效配置，密码只留引用。
4. 拒绝无效动作/outbound、类型/范围/容量关系、未支持 TLS/监听选项；不静默忽略。

依赖：C06、C11、C16、C18、C19。

设计约束/决策：AGENTS/架构将 persistence 交给应用；不把整套 JSON 配置系统未经决定塞进协议 handler。

### 方案代码草案

以下为 **Swift 风格设计草案，未编译、未写入 Sources**。除明确指出的现有符号外，示例类型、字段和方法是拟议接口；实现时必须回到现有 owner，不把示例自动变成新文件、包装层或测试专用 API。

```swift
// 仅是配置流程草案，实际归属按本篇设计决策确定。
let document = try parseJSONRejectingDuplicateKeys(bytes)
try rejectUnknownFields(document, schemaVersion: 1)
let config = try decodeTypedConfiguration(document)
try validateAllReferencesAndCapabilities(config)
try validateBudgetRelationships(config)
let credentials = try loadReferencedSecrets(config)
// 全部成功后才创建 Core/应用配置；export 永远不展开 credentials。
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

- [ ] 新增重复 JSON 键、未知字段、布尔冒充整数、范围、重复 ID、缺引用、UDP 能力和敏感信息导出测试。
- [ ] API 边界先确定再写测试，不为方便引入 StoredConfig 包装或测试专用构造器。
- [ ] C11 的 eager 引用校验决策作为单独迁移项记录。
- [ ] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [ ] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [ ] 有真实修复提交后填写 `fix_commit`；在该提交上验收后填写 `verification_commit`、更新状态和时间。未获授权提交时记录工作树指纹，commit 字段继续为 null。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | DESIGN_DECISION_REQUIRED | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | DESIGN_DECISION_REQUIRED | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |

[返回根因索引](README.md)
