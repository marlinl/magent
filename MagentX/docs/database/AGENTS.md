# SQLite Rules

`schema.sql` defines the canonical database schema.

Before editing any file in this directory:

1. Read `schema.sql`.
2. Read all relevant migrations.
3. Never assume a Swift property implies a database column.
4. Never add/drop/rename a column without a migration.
5. Never remove UNIQUE, INDEX, FOREIGN KEY, CHECK, DEFAULT,
   or NOT NULL constraints unless explicitly requested.

When adding a new schema change:

- update the current schema definition
- add a new numbered migration
- add or update schema verification tests

SQLite foreign key enforcement must always be enabled:

PRAGMA foreign_keys = ON;