PRAGMA foreign_keys = ON;

-- UUIDv7 按 RFC 9562 的 16 字节网络顺序保存；该二进制表示可按时间排序。
-- created_at 和 updated_at 保存 Unix 时间戳，单位为毫秒。
CREATE TABLE magent_proxy_nodes (
    id BLOB PRIMARY KEY NOT NULL CHECK (length(id) = 16),
    name TEXT,
    type TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
    cipher TEXT NOT NULL,
    password TEXT NOT NULL,
    timeout REAL NOT NULL DEFAULT 30 CHECK (timeout > 0),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE magent_proxy_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    match_type TEXT NOT NULL,
    match_value TEXT NOT NULL,
    decision TEXT NOT NULL,
    rule_order INTEGER NOT NULL,
    source TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX idx_magent_proxy_rules_match_type_match_value
    ON magent_proxy_rules (match_type, match_value);

CREATE TABLE magent_proxy_policies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    node_id BLOB NOT NULL UNIQUE CHECK (length(node_id) = 16),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (node_id)
        REFERENCES magent_proxy_nodes (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) STRICT;

-- policy_id 可重复，表示一个 policy 关联多条 rule。
-- rule_id 唯一，保证同一条 rule 不能归属多个 policy。
CREATE TABLE magent_proxy_policy_rules (
    policy_id INTEGER NOT NULL,
    rule_id INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (policy_id, rule_id),
    FOREIGN KEY (policy_id)
        REFERENCES magent_proxy_policies (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    FOREIGN KEY (rule_id)
        REFERENCES magent_proxy_rules (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
) STRICT;

CREATE UNIQUE INDEX idx_magent_proxy_policy_rules_rule_id
    ON magent_proxy_policy_rules (rule_id);
