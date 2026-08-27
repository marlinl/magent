# MagentX App Model SQL Design

本文档只描述 MagentX macOS App 自己使用的设置和 UI 状态模型，不属于 Magent 跨平台共享业务模型。

共享模型 `MagentNode`、`AccessControlRule`、`ProxyPolicy` 的 SQL 设计见 `../Magent_Model_SQL_Design.md`。

当前 MagentX 专属模型包括：

| Swift Model | SQL Table | 说明 |
|---|---|---|
| `CurrentSelection` | `magentx_current_selections` | 当前策略分组和当前节点选择 |
| `GeneralSettings` | `magentx_general_settings` | MagentX 启动、菜单栏、代理监听、PAC、iCloud、规则订阅 URL 设置 |

## 1. 通用约定

- SQL 方言按 SQLite 设计。
- UUID 统一存为 36 位字符串。
- `Date` 统一存为 `REAL` 类型的 Unix epoch seconds。
- Boolean 统一存为 `INTEGER NOT NULL DEFAULT 0/1`，并用 `CHECK (value IN (0, 1))` 约束。
- MagentX 专属表统一使用 `magentx_` 前缀，避免和 Magent 共享模型混淆。

## 2. magentx_current_selections

`CurrentSelection.key` 是单记录设置身份。当前默认值是 `default`，但保留未来多配置档扩展空间。

```sql
CREATE TABLE IF NOT EXISTS magentx_current_selections (
    key TEXT PRIMARY KEY
        CHECK (length(trim(key)) > 0),

    group_id TEXT NULL
        CHECK (group_id IS NULL OR length(group_id) = 36),

    magent_node_id TEXT NULL
        CHECK (magent_node_id IS NULL OR length(magent_node_id) = 36),

    updated_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_magentx_current_selections_node
    ON magentx_current_selections (magent_node_id);
```

Swift 字段映射：

| Swift | Swift 类型 | SQL |
|---|---|---|
| `key` | `String` | `key` |
| `groupID` | `UUID?` | `group_id` |
| `magentNodeID` | `UUID?` | `magent_node_id` |
| `updatedAt` | `Date` | `updated_at` |

如果 MagentX 当前只允许一条默认记录，初始化时写入：

```sql
INSERT OR IGNORE INTO magentx_current_selections (
    key,
    group_id,
    magent_node_id,
    updated_at
) VALUES (
    'default',
    NULL,
    NULL,
    unixepoch()
);
```

## 3. magentx_general_settings

`GeneralSettings.key` 是全局设置记录身份。当前 Swift model 默认值是 `default`。

```sql
CREATE TABLE IF NOT EXISTS magentx_general_settings (
    key TEXT PRIMARY KEY
        CHECK (length(trim(key)) > 0),

    launch_at_login INTEGER NOT NULL DEFAULT 0
        CHECK (launch_at_login IN (0, 1)),

    enable_menu_bar INTEGER NOT NULL DEFAULT 1
        CHECK (enable_menu_bar IN (0, 1)),

    icloud_sync_enabled INTEGER NOT NULL DEFAULT 0
        CHECK (icloud_sync_enabled IN (0, 1)),

    rules_url TEXT NOT NULL DEFAULT ''
        CHECK (rules_url = '' OR instr(rules_url, '://') > 1),

    proxy_listen_address TEXT NOT NULL DEFAULT '127.0.0.1'
        CHECK (length(trim(proxy_listen_address)) > 0),

    proxy_listen_port INTEGER NOT NULL DEFAULT 1086
        CHECK (proxy_listen_port BETWEEN 1 AND 65535),

    pac_listen_address TEXT NOT NULL DEFAULT '127.0.0.1'
        CHECK (length(trim(pac_listen_address)) > 0),

    pac_listen_port INTEGER NOT NULL DEFAULT 10080
        CHECK (pac_listen_port BETWEEN 1 AND 65535),

    updated_at REAL NOT NULL
);
```

Swift 字段映射：

| Swift | Swift 类型 | SQL |
|---|---|---|
| `key` | `String` | `key` |
| `launchAtLogin` | `Bool` | `launch_at_login` |
| `enableMenuBar` | `Bool` | `enable_menu_bar` |
| `iCloudSyncEnabled` | `Bool` | `icloud_sync_enabled` |
| `rulesURL` | `String` | `rules_url` |
| `proxyListenAddress` | `String` | `proxy_listen_address` |
| `proxyListenPort` | `Int` | `proxy_listen_port` |
| `pacListenAddress` | `String` | `pac_listen_address` |
| `pacListenPort` | `Int` | `pac_listen_port` |
| `updatedAt` | `Date` | `updated_at` |

默认设置记录：

```sql
INSERT OR IGNORE INTO magentx_general_settings (
    key,
    launch_at_login,
    enable_menu_bar,
    icloud_sync_enabled,
    rules_url,
    proxy_listen_address,
    proxy_listen_port,
    pac_listen_address,
    pac_listen_port,
    updated_at
) VALUES (
    'default',
    0,
    1,
    0,
    '',
    '127.0.0.1',
    1086,
    '127.0.0.1',
    10080,
    unixepoch()
);
```

## 4. SwiftData 同步建议

| Model | 字段 | 建议 |
|---|---|---|
| `CurrentSelection` | `key` | 已有 `@Attribute(.unique)` |
| `GeneralSettings` | `key` | 建议增加 `@Attribute(.unique)` |
| `GeneralSettings` | `proxyListenPort` | UI 层限制只能输入数字，模型/服务层继续校验端口范围 |

`CurrentSelection.magentNodeID` 当前只是 MagentX 恢复选择使用的弱引用。若未来希望数据库层强制引用共享节点表，可以在显式 SQLite schema 中添加外键到 `magent_nodes(id)`，但 SwiftData 当前模型不表达这个关系。
