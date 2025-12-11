# Memory Backup & Recovery Guide

**Created:** December 7, 2025  
**Purpose:** Prevent memory loss during migrations and system changes

## 🚨 What Happened (Dec 5, 2025)

During major schema migrations (Temporal Memory Chains, emergence patterns), the database was reset and **all November 2025 operational memories were lost**. This document ensures it never happens again.

## 🛡️ Automatic Protection

### 1. Automatic Backup Before Migrations

**Every `mix ecto.migrate` now automatically creates a backup.**

```bash
# Automatic backup happens before migration
mix ecto.migrate

# Skip backup only if you're certain (NOT RECOMMENDED)
mix ecto.migrate --skip-backup
```

Backups are stored in `priv/backups/` with timestamps:
```
priv/backups/
  ├── pre-migration_20251207_143022.db
  ├── pre-migration_20251207_143022.db.meta.json
  ├── backup_20251206_090000.db
  └── backup_20251206_090000.db.meta.json
```

### 2. Manual Backup Commands

```bash
# Create manual backup
mix mimo.backup

# Create backup with custom name
mix mimo.backup --name "before-major-change"

# List all backups
mix mimo.backup --list

# Restore from backup
mix mimo.backup --restore backup_20251207_143022.db
```

### 3. Backup Retention Policy

**Default retention:**
- Keep all backups for 30 days
- Keep monthly backups for 1 year
- Never auto-delete backups created before major version changes

**Manual cleanup:**
```bash
# Remove backups older than 30 days
find priv/backups -name "*.db" -mtime +30 -delete
```

## 📋 Memory Export/Import

### Export Memories to JSON

```elixir
# In IEx
Mimo.Brain.Memory.export_to_json("backup_memories.json")
```

### Import Memories from JSON

```elixir
# In IEx
Mimo.Brain.Memory.import_from_json("backup_memories.json")
```

## 🔍 Recovery Procedures

### Scenario 1: Just ran migration, lost data

```bash
# 1. List backups
mix mimo.backup --list

# 2. Find the pre-migration backup
# Example: pre-migration_20251207_143022.db

# 3. Restore
mix mimo.backup --restore pre-migration_20251207_143022.db
```

### Scenario 2: Discovered loss days later

```bash
# 1. Check if old database file exists
ls -lah priv/*.db*

# 2. If mimo_mcp.db.old exists, it might have the data
mix mimo.backup --restore ../mimo_mcp.db.old
```

### Scenario 3: No backup available

```bash
# Try to recover from WAL files
sqlite3 priv/mimo_mcp.db "PRAGMA wal_checkpoint(FULL);"

# Check git history for database snapshots
git log --all --full-history -- "priv/*.db"
```

## ⚠️ Critical Migrations Checklist

Before running ANY migration that changes engram schema:

- [ ] Create manual backup: `mix mimo.backup --name "before-[feature-name]"`
- [ ] Export to JSON: `Mimo.Brain.Memory.export_to_json("memories_backup.json")`
- [ ] Verify backup exists: `mix mimo.backup --list`
- [ ] Test migration on dev database first
- [ ] Document what the migration does in CHANGELOG.md
- [ ] Run migration: `mix ecto.migrate`
- [ ] Verify data integrity after migration
- [ ] Keep backup for 30 days minimum

## 🔧 Configuration

### Enable Backup Notifications

Add to `config/config.exs`:

```elixir
config :mimo_mcp, :backup,
  auto_backup_enabled: true,
  backup_dir: "priv/backups",
  retention_days: 30,
  notify_on_backup: true
```

### Backup to External Storage

```bash
# Sync backups to S3
aws s3 sync priv/backups/ s3://mimo-backups/$(hostname)/

# Or to another server
rsync -avz priv/backups/ backup-server:/mimo-backups/
```

## 📊 Backup Monitoring

### Check Backup Health

```bash
# List backups with metadata
mix mimo.backup --list

# Verify backup integrity
sqlite3 priv/backups/backup_20251207_143022.db "PRAGMA integrity_check;"
```

### Automated Backup Testing

```bash
# Test restore to temp database
mix test test/mimo/brain/backup_restore_test.exs
```

## 🎯 Prevention Rules

1. **NEVER run `mix ecto.reset` on production database**
2. **NEVER run `mix ecto.drop` without explicit backup**
3. **ALWAYS backup before schema changes**
4. **ALWAYS test migrations on dev database first**
5. **ALWAYS verify data after migration**
6. **ALWAYS keep backups for 30+ days**

## 📝 Incident Response

If you discover memory loss:

1. **STOP** - Don't make more changes
2. **Check backups** - `mix mimo.backup --list`
3. **Restore latest backup** - `mix mimo.backup --restore [file]`
4. **Verify restoration** - Check memory count and content
5. **Document incident** - Add to this file
6. **Update protection** - Improve safeguards

## 🔗 Related

- [SPEC-034: Temporal Memory Chains](../docs/specs/SPEC-034-temporal-memory-chains.md)
- [SPEC-070: Implementation Robustness](../docs/specs/SPEC-070-implementation-robustness-framework.md)
- [Cleanup Configuration](../config/dev.exs) - Memory retention settings

---

**Remember:** Memories are irreplaceable. When in doubt, backup first.
