---
desc: Magent共享节点、访问规则、策略组和规则关联的SQLite逻辑模型
updated_at: 2026-07-24
commit: af5ba87
---

# Magent Model SQL Design

## 0. 文档目标

本文定义 Magent 体系跨客户端共享业务模型的推荐 SQLite schema，并对齐当前 MagentX SwiftData
模型：

| SwiftData Model | SQL Table | 说明 |
| --- | --- | --- |
| `MagentNode` | `magent_nodes` | 节点配置和展示元数据 |
| `AccessControlRule` | `magent_acls` | 可复用访问规则 |
| `ProxyPolicy` | `magent_policy_groups` | 策略组和可选代理节点 |
| `ProxyPolicyRule` | `magent_policy_rules` | 策略组与规则的多对多关联 |

Magent package 自身不操作数据库。App 从持久化模型生成 `ProxyNode`、`ProxyRule` 和
`MagentConfig`，再调用 `Magent.start/restart`。

MagentX 专属 UI/设置模型如 `CurrentSelection`、`GeneralSettings` 不属于本文，见
`docs/MagentX/MagentX_App_Model_SQL_Design.md`。

## 1. 通用约定

- 方言：SQLite。
- UUID：36 位字符串。
- `Date`：`REAL` Unix epoch seconds。
- Boolean：`INTEGER`，并使用 `CHECK (value IN (0, 1))`。
- 列名：snake_case。
- 每次连接数据库后开启外键：

```sql
PRAGMA foreign_keys = ON;
```

SQL schema 是跨客户端逻辑契约，不要求 SwiftData 的内部真实表名与列名完全相同。

## 2. magent_nodes

```sql
CREATE TABLE IF NOT EXISTS magent_nodes (
    id TEXT PRIMARY KEY
        CHECK (length(id) = 36),

    name TEXT NOT NULL
        CHECK (length(trim(name)) > 0),

    region TEXT NOT NULL DEFAULT '',

    type TEXT NOT NULL DEFAULT 'shadowsocks'
        CHECK (type IN ('shadowsocks')),

    address TEXT NOT NULL
        CHECK (length(trim(address)) > 0),

    port INTEGER NOT NULL
        CHECK (port BETWEEN 1 AND 65535),

    cipher TEXT NOT NULL
        CHECK (cipher IN (
            'aes-128-gcm',
            'aes-256-gcm',
            'chacha20-ietf-poly1305',
            'xchacha20-ietf-poly1305'
        )),

    password TEXT NOT NULL
        CHECK (length(password) > 0),

    timeout_seconds REAL NOT NULL DEFAULT 30
        CHECK (timeout_seconds > 0),

    dns_policy TEXT NOT NULL DEFAULT 'remote'
        CHECK (dns_policy IN ('remote', 'local')),

    CONSTRAINT uq_magent_nodes_endpoint
        UNIQUE (address, port)
);
```

字段映射：

| `MagentNode` | SQL |
| --- | --- |
| `id` | `id` |
| `name` | `name` |
| `region` | `region` |
| `type` | `type` |
| `address` | `address` |
| `port` | `port` |
| `cipher` | `cipher` |
| `password` | `password` |
| `timeout` | `timeout_seconds` |
| `dnsPolicy` | `dns_policy` |

endpoint 唯一约束与当前 `MagentCore` 一致：同一 Core 中不同 UUID 不允许使用相同
`NetworkAddress`。导入旧数据时必须先合并或让用户选择重复的 `address + port`。

`name`、`region` 是 App 展示字段，不进入 `Magent.ProxyNode`。`dns_policy` 当前也是 App 保留
字段；commit `af5ba87` 的 package `ProxyNode` 尚没有该参数。

## 3. magent_acls

```sql
CREATE TABLE IF NOT EXISTS magent_acls (
    id TEXT PRIMARY KEY
        CHECK (length(id) = 36),

    match_type TEXT NOT NULL
        CHECK (match_type IN (
            'exactDomain',
            'domainSuffix',
            'domainKeyword',
            'ipCIDR',
            'urlRegex'
        )),

    match_value TEXT NOT NULL
        CHECK (length(trim(match_value)) > 0),

    decision TEXT NOT NULL
        CHECK (decision IN ('direct', 'proxy')),

    rule_order INTEGER NOT NULL DEFAULT 0,

    source TEXT NOT NULL DEFAULT '',

    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,

    CONSTRAINT uq_magent_acls_identity
        UNIQUE (match_type, match_value)
);
```

字段映射：

| `AccessControlRule` | SQL |
| --- | --- |
| `id` | `id` |
| `matchType` | `match_type` |
| `matchValue` | `match_value` |
| `decision` | `decision` |
| `order` | `rule_order` |
| `source` | `source` |
| `createdAt` | `created_at` |
| `updatedAt` | `updated_at` |

MagentX 当前使用 `SHA256(matchType.rawValue + ":" + matchValue)` 的前 16 字节生成稳定 UUID。SQL
仍保留组合唯一约束，避免不同客户端 id 生成实现发生变化时写入重复规则。

运行时转换注意：

- `direct` -> `Decision.direct`。
- `proxy` -> `Decision.proxy(policyGroup.magentNodeID)`。
- `ProxyRule` 构造时会再次规范化和校验 match value。
- `urlRegex` 可以持久化和用于 PAC/UI，但当前 `MagentRouter` 会拒绝包含 `urlRegex` 的运行配置；
  App 在生成 `MagentConfig.rules` 时必须过滤或明确报错。

## 4. magent_policy_groups

`ProxyPolicy` 当前是策略组实体，不是“规则 + 节点”的单行关联。

```sql
CREATE TABLE IF NOT EXISTS magent_policy_groups (
    id TEXT PRIMARY KEY
        CHECK (length(id) = 36),

    name TEXT NOT NULL
        CHECK (length(trim(name)) > 0),

    suffix_domain TEXT NOT NULL DEFAULT '',

    magent_node_id TEXT NULL
        CHECK (magent_node_id IS NULL OR length(magent_node_id) = 36),

    CONSTRAINT fk_magent_policy_groups_node
        FOREIGN KEY (magent_node_id)
        REFERENCES magent_nodes (id)
        ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_magent_policy_groups_node
    ON magent_policy_groups (magent_node_id);
```

字段映射：

| `ProxyPolicy` | SQL |
| --- | --- |
| `id` | `id` |
| `name` | `name` |
| `suffixDomain` | `suffix_domain` |
| `magentNodeID` | `magent_node_id` |
| `magentNode` relationship | `magent_node_id` foreign key |

`magent_node_id` 允许空，表示策略组尚未选择代理节点。此时组内 `decision = proxy` 的规则不能转换为
有效 `ProxyRule`，App 必须在 start/restart 前报错或排除。

## 5. magent_policy_rules

```sql
CREATE TABLE IF NOT EXISTS magent_policy_rules (
    policy_id TEXT NOT NULL
        CHECK (length(policy_id) = 36),

    rule_id TEXT NOT NULL
        CHECK (length(rule_id) = 36),

    PRIMARY KEY (policy_id, rule_id),

    CONSTRAINT fk_magent_policy_rules_policy
        FOREIGN KEY (policy_id)
        REFERENCES magent_policy_groups (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_magent_policy_rules_rule
        FOREIGN KEY (rule_id)
        REFERENCES magent_acls (id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_magent_policy_rules_rule
    ON magent_policy_rules (rule_id);
```

字段映射：

| `ProxyPolicyRule` | SQL |
| --- | --- |
| `id`（当前保存 `ProxyPolicy.id`） | `policy_id` |
| `ruleID` | `rule_id` |
| `proxyPolicy` relationship | `policy_id` foreign key |
| `accessControlRule` relationship | `rule_id` foreign key |

当前 SwiftData 模型使用 `#Unique([\.id, \.ruleID])`，与 SQL 组合主键语义一致。虽然属性名 `id`
容易被误解为 join row 的独立身份，文档按当前代码保留，不擅自重命名。

## 6. 从持久化模型生成 MagentConfig

推荐转换顺序：

```text
读取并校验 MagentNode
  -> 生成 [Magent.ProxyNode]
  -> 读取启用的 ProxyPolicy
  -> 读取每组 ProxyPolicyRule / AccessControlRule
  -> direct 规则生成 Decision.direct
  -> proxy 规则使用该组 magentNodeID 生成 Decision.proxy
  -> 构造 [Magent.ProxyRule]
  -> 构造 MagentConfig
  -> start 或 restart
```

必须保证：

- 节点 endpoint 唯一。
- proxy rule 引用的节点存在。
- timeout 为正且可转换为毫秒。
- 不把当前 Core 不支持的 `urlRegex` 放入运行规则。
- 同一逻辑规则的覆盖顺序明确。

## 7. 当前 package/App 类型漂移

commit `af5ba87` 下，MagentX 模型仍引用旧 package API：

| MagentX 当前引用 | package 当前实际类型 | 更新方向 |
| --- | --- | --- |
| `Magent.ProxyDNSPolicy` | 不存在 | 暂作为 App 字段，转换 `ProxyNode` 时不传 |
| `Magent.AccessControlPolicy` | 不存在 | 改为构造 `Magent.ProxyRule` |
| `ProxyNode(..., dnsPolicy:)` | 当前 initializer 无该参数 | 删除该参数或先扩展 package 公共契约 |

因此本文的 SQL schema可以保留跨客户端/未来字段，但 App 到 package 的转换代码必须先完成上述
对齐，不能把旧 API 写进新的接入文档。

## 8. SwiftData 对齐

| Model | 当前约束 | SQL 对齐要求 |
| --- | --- | --- |
| `MagentNode` | `id` 未标记 unique | Controller upsert 保证 UUID 唯一；迁移后可收紧 |
| `MagentNode` | 与 `ProxyPolicy` cascade relationship | SQL node 删除使用 `SET NULL` 更适合保留策略组；需明确产品选择 |
| `AccessControlRule` | `id @Attribute(.unique)` | 保留，并继续按稳定 identity upsert |
| `ProxyPolicy` | `id @Attribute(.unique)` | 保留 |
| `ProxyPolicyRule` | composite `#Unique` | 与 SQL composite primary key 一致 |

SwiftData 和 SQL 对删除规则的表达能力不同。真正导出/同步到 SQLite 时，以本文显式外键行为为准；
如果 App 希望删除节点时连带删除策略组，应同时修改本文和模型，而不是让两端静默不一致。

## 9. 迁移

旧设计只有 `magent_policies` 关联表。迁移到当前四模型结构时：

1. 为节点补齐 `region`，可先使用 address 回填。
2. 清理重复 `address + port`，再创建 endpoint 唯一约束。
3. 按旧 `group_id` 创建 `magent_policy_groups`，补齐稳定 UUID 和非空 name。
4. 把旧 `access_control_rule_id` 关系迁移到 `magent_policy_rules`。
5. 把旧 `magent_node_id` 迁移到对应 policy group。
6. 校验所有外键和组合唯一约束。
7. 备份并验证后再删除旧 `magent_policies`。

不要在同一次迁移中静默删除无法转换的 proxy rule 或重复节点；应生成可审查的冲突清单。
