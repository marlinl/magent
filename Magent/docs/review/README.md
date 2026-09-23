---
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-23T10:19:20+08:00"
status: REVIEW_DOCUMENTED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
fix_commit: null
---

# SOCKS5 spec 审查索引

本目录把 2026-09-22 审查发现拆为 **24 个独立 cause**，每个文件包含时间、状态、基线/修复 commit 和证据；各篇 `## Goal` 小标题下集中记录修复目标、方案、Swift 风格代码草案、验证命令和验收条件。

- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)
- 实现：[Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- 测试：[Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)
- 当前架构：[ARCHITECTURE.md](../ARCHITECTURE.md)
- 适用规则：[AGENTS.md](../../AGENTS.md)

## Commit 与状态语义

审查基线为 `31ea88cb864d4468224234f8ed0620da0a1eb190`（`refactor: refine Magent runtime and cache behavior`）。这只标识被审查源码版本，不表示问题在该提交引入，也不是修复提交。首次审查时的测试是该 HEAD 之上的未提交追加，SHA-256：`8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8`。

`introduced_commit=unknown`：尚未通过 blame/bisect 确认；未修复条目的 `fix_commit=null` 表示尚无修复提交，`verification_commit=null` 表示尚未在修复提交验收。已归档 C09 记录实际的修复及验收 commit；其他条目仍按各自证据更新。

状态流转：

```text
OPEN / NOT_IMPLEMENTED / DESIGN_DECISION_REQUIRED
    → IN_PROGRESS → FIXED → VERIFIED → ARCHIVED
    ↘ ACCEPTED_DEVIATION（必须记录明确选择和 spec 版本；不等价于完整 spec 通过）
```

- `OPEN`：已确认差异，待修复。
- `NOT_IMPLEMENTED`：spec 所需能力尚无实现，不能当作普通 bug 已修复。
- `DESIGN_DECISION_REQUIRED`：与当前公开模型、架构或 AGENTS 明确约定不同；先选择目标合同。
- `FIXED`：代码已修改但验收未完成；不能因为测试命令退出 0 就自动转 `VERIFIED`。
- `VERIFIED`：该 cause 的目标断言普通通过，证据与实际版本齐全。
- `ARCHIVED`：验收完成并移入 `archive/`；原验收结论记录为 `resolution: VERIFIED`。

证据等级：

- `REGRESSION_VERIFIED`：对应 cause 已修复并完成回归；未提交时必须标注工作树指纹。
- `TEST_CONFIRMED`：已有本机测试复现差异。
- `TEST_PARTIAL`：部分情形复现，其他情形仅源码确认或受环境限制；逐篇说明边界。
- `SOURCE_CONFIRMED`：仅确认实现/接口缺口，未宣称完成运行复现。
- `SOURCE_AND_LEGACY_TESTS`：源码与旧测试一致，但旧行为与目标 spec 不同。

## 文件命名

格式为 `{优先级}-{id}-SOCKS5-{name}.md`，例如 `P1-C01-SOCKS5-udp-source-hint.md`。优先级保留各项实际的 P1/P2，编号沿用 C01–C24，业务场景统一为 SOCKS5。Goal 是每篇修复文档的小标题，修复方案和代码直接写在对应文档中。

## 根因清单

| Cause | 根因 | 优先级 | 当前状态 | 证据 |
|---|---|---|---|---|
| [C01](P1-C01-SOCKS5-udp-source-hint.md) | UDP ASSOCIATE 丢弃客户端来源提示 | P1 | 待修复 | `TEST_CONFIRMED` |
| [C02](P1-C02-SOCKS5-udp-client-pinning.md) | UDP 首包缺少 TCP 对端校验且过早固定来源 | P1 | 待修复 | `TEST_PARTIAL` |
| [C03](P1-C03-SOCKS5-udp-error-scope.md) | UDP 单包和单流错误升级为整个关联关闭 | P1 | 待修复 | `TEST_CONFIRMED` |
| [C04](P1-C04-SOCKS5-target-safety.md) | 业务目标缺少强制安全检查及自回环检查 | P1 | 待修复 | `TEST_PARTIAL` |
| [C05](P1-C05-SOCKS5-phase-deadlines.md) | 握手和会话缺少绝对截止时间 | P1 | 待修复 | `TEST_PARTIAL` |
| [C06](P1-C06-SOCKS5-resource-budgets.md) | 会话、UDP 映射和缓冲缺少共享资源预算 | P1 | 能力未实现 | `SOURCE_CONFIRMED` |
| [C07](P2-C07-SOCKS5-tcp-remainder-early-data.md) | TCP 解析将当前消息之后的字节当作错误 | P2 | 待设计决策 | `TEST_CONFIRMED` |
| [C08](P2-C08-SOCKS5-hostname-validation.md) | 域名语法验证仅检查非空 UTF-8 | P2 | 部分修复，仍待完成 | `TEST_CONFIRMED` |
| [C09](archive/P2-C09-SOCKS5-address-normalization.md) | 目标地址类型与转发形式未统一规范化 | P2 | 已归档（已修复并验证） | `REGRESSION_VERIFIED` |
| [C10](P2-C10-SOCKS5-routing-precedence.md) | 路由使用优先级及特异度而不是配置顺序首命中 | P2 | 待设计决策 | `TEST_CONFIRMED` |
| [C11](P2-C11-SOCKS5-rule-node-reference.md) | 仅默认代理节点在初始化时校验 | P2 | 待设计决策 | `TEST_CONFIRMED` |
| [C12](P2-C12-SOCKS5-error-mapping.md) | 底层错误丢失与请求阶段分类不足 | P2 | 待修复 | `TEST_PARTIAL` |
| [C13](P2-C13-SOCKS5-ipv6-udp-relay.md) | UDP 入站中继硬编码 IPv4 控制连接 | P2 | 待修复 | `TEST_CONFIRMED` |
| [C14](P2-C14-SOCKS5-udp-control-payload.md) | UDP 控制态静默忽略额外 TCP 字节 | P2 | 待修复 | `TEST_CONFIRMED` |
| [C15](P2-C15-SOCKS5-direct-dns-policy.md) | DIRECT 域名解析采用自定义 DNS 而非系统解析合同 | P2 | 待设计决策 | `SOURCE_AND_LEGACY_TESTS` |
| [C16](P1-C16-SOCKS5-authentication-access.md) | 仅支持无认证且缺少配套监听访问策略 | P1 | 能力未实现 | `SOURCE_CONFIRMED` |
| [C17](P1-C17-SOCKS5-socks5-upstream.md) | 出站只有原生 Shadowsocks，缺少 SOCKS5 上游状态机 | P1 | 待设计决策 | `SOURCE_CONFIRMED` |
| [C18](P1-C18-SOCKS5-routing-capabilities.md) | 路由模型没有 REJECT、端口和业务传输条件 | P1 | 能力未实现 | `SOURCE_CONFIRMED` |
| [C19](P2-C19-SOCKS5-udp-enable-switch.md) | UDP ASSOCIATE 没有可配置关闭能力 | P2 | 能力未实现 | `SOURCE_CONFIRMED` |
| [C20](P2-C20-SOCKS5-configuration-contract.md) | 配置 API 不具备 spec 的 schema 与完整语义校验 | P2 | 待设计决策 | `SOURCE_CONFIRMED` |
| [C21](P2-C21-SOCKS5-reload-drain-lifecycle.md) | restart 关闭旧 runtime，与保留旧会话及优雅排空的 spec 不同 | P2 | 待设计决策 | `SOURCE_CONFIRMED` |
| [C22](P2-C22-SOCKS5-udp-flow-ownership.md) | UDP 按远端端点记 Wire，缺少独立逻辑流所有权 | P2 | 待设计决策 | `SOURCE_AND_LEGACY_TESTS` |
| [C23](P2-C23-SOCKS5-udp-packet-size.md) | UDP 缺少 spec 的完整报文大小和截断验收 | P2 | 能力未实现 | `SOURCE_CONFIRMED` |
| [C24](P2-C24-SOCKS5-observability.md) | 缺少 spec 所需分阶段、脱敏和有界可观测性 | P2 | 能力未实现 | `SOURCE_CONFIRMED` |

C01–C15 拆解上轮主要问题；C16–C22 展开认证、上游、配置及生命周期能力差异；C23/C24 将此前测试矩阵中的报文完整性与可观测性缺口显式追踪，证据为源码确认，不新增未经复现的漏洞结论。

## 验证基线

以下保留首次审查的历史结果；C09 修复后的新结果见下文“C09 修复验证”。全包测试日志记录结束时间 `2026-09-22T14:58:23+08:00`；该时间是日志时间，不是所有命令共享的执行时间。

| 验证 | 上轮结果 |
|---|---|
| 原有 SOCKS5 测试 | 16 个，0 失败；其中有断言旧行为的测试 |
| 新增 spec 测试 | 33 个：12 正常通过、20 方法含严格预期失败、1 环境跳过 |
| SOCKS5 合计 | 49 个；20 方法共 72 次预期断言失败，不能称完整 spec 通过 |
| `swift test --filter ConnectionTests` | 90 个，0 意外失败，1 跳过 |
| `swift test` | 235 个，0 意外失败，1 跳过 |
| 普通 / strict-concurrency 构建 | 通过 |
| 修改测试文件 swift-format strict lint / diff check | 通过 |

唯一跳过为 `testSpecUDPFirstSenderMustMatchControlPeerIP`：本机绑定 `127.0.0.2` 返回 errno 49。不能把它计为来源 IP 安全验证通过，也不应自动修改用户网卡/回环配置。

未完成：真实 SOCKS5/sslocal 集成、全资源预算验收、30 分钟稳定性运行及缺失生产能力对应的完整矩阵。原始临时日志不作为仓库永久依赖；后续修复需要保存新的可复现命令/结果。

## C09 修复验证与归档

首次验收结束：`2026-09-22T15:51:53+08:00`。C09 当时在未提交工作树完成，历史及当前证据见 [归档 C09](archive/P2-C09-SOCKS5-address-normalization.md)。原两个规范化预期失败方法已普通通过；增加了 TCP/UDP 路由、转发、DIRECT 数值别名和地址模型边界回归。

首次验收中，普通构建、严格并发构建、5 个修改文件的 strict lint 和 diff check 均通过。连接测试 **94 个**、全包测试 **243 个**，均为 **0 意外失败、1 环境跳过**。完整测试仍有其他 cause 的 **18 个方法、46 次严格预期断言失败**，不能称为全 spec 通过。

C09 的修复和测试已提交于 `ec3cad4`。2026-09-23 在 `3433033` 上重新运行地址模型测试 12 个及 C09 SOCKS5 回归 7 个，全部普通通过；本次全包测试因执行环境禁止 HTTP CONNECT 测试本地 `bind` 而中断，不能计为通过。C08 的基本主机名语法校验随规范化实现；完整 IDNA、空串/非法 UTF-8 的错误回复及 UDP 单包丢弃仍待完成。

## 设计冲突与执行边界

严格握手顺序、原生 Shadowsocks、order/特异度、规则节点惰性校验、远端 DNS、共享 UDP socket、restart 关闭旧会话均有当前代码或文档依据。它们和目标 spec 不同，不能通过删除旧测试或改名字掩盖差异。

各篇 Goal 描述该 cause 的修复目标及实施方案；除 C09 已标明的实现片段外，其他 Swift 代码块仍是未编译的设计草案。新建 Swift 文件、改变公开配置或迁移既有语义均须遵守当前任务授权和仓库规则。

## 文档重命名验证（历史）

验证时间：`2026-09-22T15:27:18+08:00`。检查了 25 篇 Markdown、24 个 cause 的文件命名、元数据/状态/索引和 Goal 层级、208 个本地链接及 35 个测试方法名，20 个已有预期失败测试均能映射到 cause；未发现断链或不存在的测试引用。对原 spec 和上一轮测试文件做 SHA-256 前后比较，均未变化；`git diff --check` 通过。

上述历史重命名检查未运行构建或测试，也未编译草案；不能作为代码修复证据。C09 的实际构建和回归结果已单独记录在上文。
