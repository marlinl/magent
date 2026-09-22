---
id: SOCKS5-C09
title: "目标地址类型与转发形式未统一规范化"
created_at: "2026-09-22T15:14:35+08:00"
updated_at: "2026-09-22T15:54:44+08:00"
timezone: Asia/Shanghai
status: VERIFIED
priority: P2
evidence: REGRESSION_VERIFIED
reviewed_commit: 31ea88cb864d4468224234f8ed0620da0a1eb190
introduced_commit: unknown
fix_commit: null
verification_commit: null
test_revision: uncommitted_worktree
review_baseline_tests_sha256: 8af1205566e47bc616e9c2fb8a2ac2ca6e6be9339c5ae538585cfbc227cb8ee8
tests_sha256: a27b82bb523fdbef1f3902649c0d2d0a64fef801b6a2f04de0c94075bd3e52b4
verified_at: "2026-09-22T15:51:53+08:00"
verification_revision: uncommitted_worktree
verification_worktree_sha256: a94933073c6df76fe5ac9ed97bb836a3a5caf6fd27212445b27034e5d85d8289
---

# SOCKS5-C09：目标地址类型与转发形式未统一规范化

状态：**已修复并验证（未提交工作树）**。C09 的规范化回归普通通过；修复与验收 commit 仍为 `null`，本轮未创建 Git 提交。

## 基线与证据

- 创建时间：`2026-09-22T15:14:35+08:00`；更新时间：`2026-09-22T15:54:44+08:00`，时区 `Asia/Shanghai`。
- 审查基线 commit：`31ea88cb864d4468224234f8ed0620da0a1eb190`；它不是已确认的缺陷引入提交。
- 引入 commit：`unknown`，未做逐项 git blame/bisect；修复/验收 commit：`null`，尚未产生。
- 规格：[SOCKS5_PROXY_SPEC.md](../SOCKS5_PROXY_SPEC.md)，§7.2–7.5；R03/R05。
- 证据等级：`REGRESSION_VERIFIED`，含义见 [索引](README.md)。
- 原审查测试指纹保留在 `review_baseline_tests_sha256`；当前测试指纹在 `tests_sha256`，验收工作树指纹与具体文件记录在下文。

涉及文件与 owner：

- [Sources/Model/NetworkAddress.swift](../../Sources/Model/NetworkAddress.swift)
- [Sources/Connection/Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift)
- [Sources/Core/MagentCore.swift](../../Sources/Core/MagentCore.swift)

## Cause

审查基线中，域名原样进入 Wire；Core 匹配时另行 lowercase/trim。ATYP=03 的标准 IPv4 文本保持 Domain，mapped IPv6 保持 IPv6，导致匹配、转发和来源比较使用不同语义。

## 影响与复现边界

IPv4-mapped IPv6 不命中 IPv4 CIDR；域名大小写、根点和数值表示可能造成出口或策略差异。相关转发字节和路由差异已由原审查测试复现；本次修复后对应断言普通通过。

相关测试位于 [Socks5ConnectionTests.swift](../../Tests/Connection/Socks5ConnectionTests.swift)：

- `testSpecNormalizesDomainForwardingAndNumericAddresses`
- `testSpecMappedIPv6CannotBypassIPv4Rule`
- `testSpecDomainSuffixBoundaryAndNumericTargetsDoNotGuessDomains`
- `testSpecUDPNormalizesBeforeRoutingAndForwarding`
- `testSpecUDPNumericAliasesUseDirectWithoutDNS`
- `testSpecTCPNumericAliasesUseDirect`
- `testSpecRejectsInvalidDomainExpressionsBeforeOpeningProxy`

[NetworkAddressTests.swift](../../Tests/Model/NetworkAddressTests.swift) 另有 4 个新增测试，覆盖幂等性、源端点等价、原生 IPv6 保留、数字歧义和主机名长度边界。

C09 的两个原预期失败方法已移除 `XCTExpectFailure`，保持字节与路由断言。其他 cause 的严格预期失败仍保留；历史审查结果见 [索引](README.md#验证基线)。

## Goal

建立一个纯规范化入口，匹配和转发都消费同一结果；保留显式根点，只在匹配时移除。

### 修复方案

已实现：

1. 在现有 NetworkAddress 中增加内部 `normalized()`，纯语法处理，无 DNS、无新公共 API、无新 Swift 文件。
2. mapped IPv6 和严格 dotted-quad Domain 转为 IPv4；原生 IPv6 保持原值。整数、十六进制、前导零、省略字段、带根点的纯数值表达和域名字段中的 IPv6 文本被拒绝。
3. ASCII 域名小写化，转发保留显式根点；`hostForMatching` 只移除一个根点。共用的基本校验拒绝空标签、非法字符和过长名称，避免用 trim 接受错误输入。
4. SOCKS5 CONNECT 和 UDP 数据报在路由前规范化，Core 对独立调用者同样执行规范化；匹配和路由缓存共用 `hostForMatching`。ASSOCIATE 来源提示保留原类型，留给 C01 的独立策略。
5. UDP 已固定来源的比较先转为统一数值身份，回复保留原 SocketAddress；数值 TCP DIRECT 使用 `connect(to:)`，不会进入 hostname resolver。

依赖边界：C08 的基本 ASCII/标签校验作为规范化前提已实现；完整 IDNA、空串/非法 UTF-8 的回复码仍由 C08/C12 跟踪。C01/C02 的控制对端授权、C04 的目标安全策略与 C13 的 IPv6 入站 relay 未在本次实现。

### 实现代码

实现位于 [NetworkAddress.swift](../../Sources/Model/NetworkAddress.swift)、[Socks5Connection.swift](../../Sources/Connection/Socks5Connection.swift) 和 [MagentCore.swift](../../Sources/Core/MagentCore.swift)。以下是已经编译并测试的实现片段：

```swift
// NetworkAddress.normalized() 的 IPv6 分支。
if bytes.prefix(12) == Data(repeating: 0, count: 10) + Data([0xFF, 0xFF]) {
  return .ipv4(Data(bytes.suffix(4)), port: port)
}

// SOCKS5 UDP 业务目标在路由、解析或 Wire 编码之前规范化。
return (target: try address.normalized(), data: Data(data.dropFirst(consumed)))

// Core 的所有路由入口先统一表示，再构造缓存 key。
let address = try address.normalized()
let key = Self.routeCacheKey(address)
```

### 验证命令

本次从包根目录执行下列命令。缓存放入可写的临时目录；TCP/UDP 本机监听测试在获得执行权限后运行。

```bash
export CLANG_MODULE_CACHE_PATH=/tmp/magent-c09-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/magent-c09-module-cache
swift build --disable-sandbox
swift build --disable-sandbox -Xswiftc -strict-concurrency=complete
swift test --disable-sandbox --filter ConnectionTests
swift test --disable-sandbox
xcrun swift-format lint --strict Sources/Model/NetworkAddress.swift Sources/Core/MagentCore.swift Sources/Connection/Socks5Connection.swift Tests/Model/NetworkAddressTests.swift Tests/Connection/Socks5ConnectionTests.swift
git diff --check
```

全包验收结束时间：`2026-09-22T15:51:53+08:00`。

| 验证 | 结果 |
|---|---|
| 定向测试：NetworkAddressTests 与 C09 相关 SOCKS5 方法，以及独立的编码错误回归 | 20 个，0 意外失败；其中 C08/C12 编码错误方法保留 2 次预期断言失败 |
| 普通构建 / strict-concurrency 构建 | 均通过，无代码编译警告 |
| ConnectionTests | 94 个，0 意外失败，1 环境跳过 |
| 全包测试 | 243 个，0 意外失败，1 环境跳过 |
| 修改的 5 个 Swift 文件 strict lint / git diff check | 通过 |

构建日志有 SwiftPM 用户级缓存只读提示，构建均成功，未出现源码编译警告。

全包仍有其他 cause 的 **18 个测试方法、46 次严格预期断言失败**，不代表全部 spec 通过。唯一环境跳过仍是 `testSpecUDPFirstSenderMustMatchControlPeerIP`：绑定 `127.0.0.2` 返回 errno 49，属于 C02。未运行真实外部 SOCKS5/sslocal 集成，也未验证完整 IDNA。

工作树证据：基线仍为 `31ea88cb864d4468224234f8ed0620da0a1eb190`，未提交。下面是本次实际编译测试的文件 SHA-256；`verification_worktree_sha256` 是该路径到摘要映射按 key 排序、无空白 JSON 的 SHA-256。

```json
{
  "Sources/Connection/Socks5Connection.swift": "2f86f1a5b92cf8be62d11a08f44c1f65ffe5ef017ac7647ff7fdd235e0561073",
  "Sources/Core/MagentCore.swift": "1a677a84ea988fe2be1e60ed863430efdf2c07f2f733b2cea95d2753ceaefef3",
  "Sources/Model/NetworkAddress.swift": "277687044fae5abf67f3124cf66a6b69959399b4caafae8da44b3bf87362d88a",
  "Tests/Connection/Socks5ConnectionTests.swift": "a27b82bb523fdbef1f3902649c0d2d0a64fef801b6a2f04de0c94075bd3e52b4",
  "Tests/Model/NetworkAddressTests.swift": "b643034aa9872ebe5efbe4fac40839026214f1b4d0581340e9dc711a45037754"
}
```

### 验收与关闭条件

- [x] 同一逻辑 IPv4 统一表示；TCP/UDP CIDR 与已固定 UDP 来源比较已接入。缺失的安全策略和控制对端授权仍由 C01/C02/C04 负责，未宣称已实现。
- [x] API.Example.COM. 转发为 api.example.com.，匹配为 api.example.com。
- [x] 数值目标不做 PTR/猜域名，不触发 Target DNS。
- [x] 本 cause 的 spec 断言普通通过后，才删除相应严格预期失败标记；不能放宽断言、禁用测试或把失败改成 skip。
- [x] 执行本篇 Goal 下与改动匹配的验证命令，并记录执行时间、结果、剩余跳过项。
- [x] 已记录验收时间和工作树指纹。`fix_commit` 与 `verification_commit` 保持 null；将来有真实提交后再按实际版本回填。

## 状态历史

| 时间 | 状态 | commit | 说明 |
|---|---|---|---|
| 2026-09-22T15:14:35+08:00 | OPEN | 31ea88cb864d4468224234f8ed0620da0a1eb190（审查基线） | 记录根因和提案；未修改业务实现 |
| 2026-09-22T15:27:18+08:00 | OPEN | — | 按优先级、编号和业务场景重命名；方案、代码与验收归入本篇 Goal，状态未变 |
| 2026-09-22T15:54:44+08:00 | VERIFIED | null（未提交工作树） | 统一规范化与数值拨号；C09 回归普通通过，完整构建和 243 个包测试完成 |

[返回根因索引](README.md)
