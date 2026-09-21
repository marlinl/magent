---
desc: MagentX当前持久化模型与Magent运行配置的转换边界
updated_at: 2026-09-21
baseline: current-working-tree
---

# Magent 模型与 SQL 映射

## 0. 文档目标

Magent package 不读写数据库。本文说明当前 MagentX 持久化模型如何形成 Magent 运行配置，
不维护另一套独立 DDL。数据库定义以 [schema.sql](../../MagentX/docs/database/schema.sql) 为准；
SwiftData 定义以 [Persistence](../../MagentX/MagentX/Model/Persistence/) 中的模型为准。
SQL 契约不等于 SwiftData 自动生成的物理表结构，两者的约束表达需要分别核对。

# 1. Context

```text
MagentX ModelContainer
  -> MagentService.getConfig
       -> 启用的 MagentProxyPolicy
       -> MagentProxyNode -> Magent.ProxyNode
       -> MagentProxyPolicyRule + MagentProxyRule -> Magent.ProxyRule
       -> MagentConfig
  -> 由调用方交给 Magent.start / restart
```

[MagentService.swift](../../MagentX/MagentX/Service/MagentService.swift) 的 `getConfig` 已有转换实现；
该文件当前 `start` 和 `close` 方法体仍为空，因此不能把“已生成配置”写成“App 已完成实际启动/关闭”。
本文只描述当前代码，不为未接通的应用生命周期补充隐含行为。

# 2. Contract

## 2.1 模型与表

| SwiftData 模型 | SQL 表 | 身份与关联 |
| --- | --- | --- |
| `MagentProxyNode` | `magent_proxy_nodes` | 节点 UUID；SwiftData id 唯一，默认生成 UUIDv7 |
| `MagentProxyRule` | `magent_proxy_rules` | 整数 id；SQL 对 `(match_type, match_value)` 建唯一索引 |
| `MagentProxyPolicy` | `magent_proxy_policies` | 整数 id；`nodeID` 必填且唯一；`enable` 默认 true |
| `MagentProxyPolicyRule` | `magent_proxy_policy_rules` | `policyID` 可重复，`ruleID` 全局唯一；一个策略关联多条规则，一条规则最多归属一个策略 |

当前模型没有旧设计中的 `region`、`dnsPolicy`、`suffixDomain` 或可空 `magentNodeID`。
规则与策略 id 是 `Int`，不能按节点 UUID 的编码导入。SwiftData 中这些整数由应用提供，
SQL 的规则/策略表则声明 `INTEGER PRIMARY KEY AUTOINCREMENT`，不能据此声称 SwiftData 自动分配相同序列。

## 2.2 SQL 编码和约束

- 节点 `id` 与策略 `node_id` 为 16 字节 BLOB；UUIDv7 按网络字节顺序保存。
- `created_at` / `updated_at` 是整数 Unix 毫秒；SwiftData 属性是 `Date`，导入导出需明确转换单位。
- `enable` 为 0/1 整数，默认 1，并有 CHECK。
- 节点端口限定 `1...65535`；`timeout` 为秒，默认 30，SQL 要求大于 0。
- SQL 节点 `name` 可空；SwiftData `name` 是非可选 String，默认空字符串，不能据此增加 SQL NOT NULL。
- schema 未对节点 `(address, port)` 声明唯一，也未给 type/cipher/decision 建枚举 CHECK。
  Core 对已解析的 `SocketAddress` 的唯一性校验属于运行配置层，并不等同于数据库文本地址唯一。
- 四个表使用 STRICT；每次连接数据库应启用 `PRAGMA foreign_keys = ON`。

| 外键 | ON UPDATE | ON DELETE |
| --- | --- | --- |
| policy.node_id → node.id | CASCADE | RESTRICT |
| policy_rule.policy_id → policy.id | CASCADE | CASCADE |
| policy_rule.rule_id → rule.id | CASCADE | CASCADE |

SwiftData 当前用标量 id 保存关联，没有声明相同的 `@Relationship` 外键/级联行为。
规则的 `(matchType, matchValue)` 唯一性由应用校验和同步流程维护，模型仅给 `id` 标注 `.unique`；
SQL 的组合唯一索引不能被描述为 SwiftData 的 `#Unique`。

## 2.3 公开模型映射

| 持久化数据 | 运行配置 |
| --- | --- |
| node.id/type/cipher/password/timeout | `ProxyNode` 同名值；type/cipher 从 String 解析为枚举 |
| node.address + port | 在 App 转换中先解析为 `SocketAddress`，再交给 `ProxyNode.address` |
| rule.matchType/matchValue/order | 构造并校验 `ProxyRule` |
| rule.decision = direct | `Decision.direct` |
| rule.decision = proxy | 经 rule → policy → nodeID 得到 `Decision.proxy(nodeID)` |
| UI 监听地址/端口 | `MagentConfig.listener` |

name、source、数据库身份和时间戳不进入 package 规则；规则本身没有持久化 id。
当前 `getConfig` 不传 `dnsListener` 或 `defaultTimeout`，因此使用 nil 与 10_000 毫秒默认值。

# 3. Core Logic

## 3.1 当前配置生成顺序

1. 按策略 id 升序读取 `enable == true` 的策略。
2. 查询这些策略引用的节点；解析节点类型、cipher 和服务器地址，构造 `[ProxyNode]`。
3. 按代理模式决定默认决策与规则集合。
4. 构造完整 `MagentConfig`，交由库的生命周期入口使用。

| App 模式 | 默认决策 | rules |
| --- | --- | --- |
| policy | direct | 启用策略关联的可转换规则 |
| global | 按启用策略 id 顺序找到的第一个可转换节点；没有则 direct | 空 |
| direct | direct | 空 |

节点列表来自启用策略引用的节点，不是无条件读取数据库全部节点。
即使 direct 模式，当前转换仍查询并传入这些可转换节点；Core 初始化仍会验证它们的 Wire 配置。

## 3.2 过滤和报错边界

当前 App 转换存在以下行为，不能写成全部 fail-fast：

- 查询启用策略失败会从 `getConfig` 抛出；节点/关联/规则辅助查询失败会返回空数组。
- 节点 type/cipher 无法识别或服务器地址解析失败时，该节点被 `compactMap` 排除。
- 规则缺少关联、匹配类型未知、`urlRegex`、decision 未知或 `ProxyRule` 构造失败时，该规则被排除。
- 规则使用策略中的 nodeID；不会再核实该节点是否已成功进入转换后的节点列表。
  因此无效节点被过滤后，仍可能留下指向它的 proxy 规则。
- Core 在初始化时校验默认代理节点；规则引用缺失节点直到路由被使用时才报错，绝不在库内降级直连。
- 节点 timeout 的有限正数/毫秒转换与重复已解析 endpoint 等验证由 Core/Wire 初始化完成。

这里记录的是现行转换行为，不表示过滤无效记录是数据库迁移的错误处理规范。

# 4. Corners

## 4.1 迁移与兼容

现有 [001_add_magent_proxy_policy_enable.sql](../../MagentX/docs/database/migrations/001_add_magent_proxy_policy_enable.sql)
只负责增加 enable 列。它不执行旧 UUID 规则/策略到整数 id 的转换，也不将旧多对多关系自动改为单一归属。
旧文档中的建表和迁移步骤不再适用于当前 schema；实际迁移应以目标 schema、已有数据库版本和专门迁移脚本为准。

## 4.2 验证范围

本文对照当前 schema、上述 migration、SwiftData 模型和 `MagentService.getConfig` 静态整理。
本次没有修改数据库定义或业务代码，也没有执行真实数据库迁移、SwiftData 读回或 App 生命周期验证。
