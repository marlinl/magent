PRAGMA foreign_keys = ON;

ALTER TABLE magent_proxy_policies
ADD COLUMN enable INTEGER NOT NULL DEFAULT 1 CHECK (enable IN (0, 1));
