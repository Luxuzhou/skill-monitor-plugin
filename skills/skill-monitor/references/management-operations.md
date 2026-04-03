# Management Operations

## Disable

**Syntax:** `/skill-monitor disable <skill-name>`

Disables a skill WITHOUT deleting it. Reversible.

### Implementation
```bash
mv ~/.claude/skills/<name>/SKILL.md ~/.claude/skills/<name>/SKILL.md.disabled
```

### Rules
1. ALWAYS confirm with AskUserQuestion:
   "确认禁用技能 '<name>'？（文件不会删除，可随时通过 /skill-monitor restore <name> 恢复）"
2. After disabling, save snapshot
3. Log action: `{"action":"disable","skill":"<name>","ts":"<ISO8601>"}` → audit-log.jsonl
4. Report: "已禁用 <name>。下次对话起生效。"
5. NEVER disable skill-monitor itself

---

## Quarantine

**Syntax:** `/skill-monitor quarantine <skill-name>`

Moves skill to isolated quarantine directory. Stronger than disable.
Use for skills with CRITICAL security findings.

### Implementation
```bash
mkdir -p ~/.claude/skill-monitor/quarantine
mv ~/.claude/skills/<name> ~/.claude/skill-monitor/quarantine/<name>
```

### Rules
1. ALWAYS confirm with AskUserQuestion:
   "确认隔离技能 '<name>'？（将移到 quarantine 目录，可通过 /skill-monitor restore <name> 恢复）"
2. If skill has CRITICAL findings, proactively recommend quarantine
3. Log: `{"action":"quarantine","skill":"<name>","ts":"<ISO8601>","reason":"<reason>"}`
   → `~/.claude/skill-monitor/audit-log.jsonl`
4. Auto-snapshot after quarantine
5. NEVER quarantine skill-monitor itself

---

## Restore

**Syntax:** `/skill-monitor restore <skill-name>`

Restores a disabled or quarantined skill.

### Implementation
```bash
# Check disabled first
if [ -f ~/.claude/skills/<name>/SKILL.md.disabled ]; then
  mv ~/.claude/skills/<name>/SKILL.md.disabled ~/.claude/skills/<name>/SKILL.md
# Check quarantine
elif [ -d ~/.claude/skill-monitor/quarantine/<name> ]; then
  mv ~/.claude/skill-monitor/quarantine/<name> ~/.claude/skills/<name>
fi
```

### Rules
1. Confirm with AskUserQuestion
2. After restore, run a quick security scan on the restored skill
3. Log the restore action to audit-log.jsonl
4. Save a snapshot

---

## Audit Log

All management actions are logged to `~/.claude/skill-monitor/audit-log.jsonl`.
Each entry is a JSON line with fields: `action`, `skill`, `ts`, `reason` (optional).

This provides a complete audit trail for compliance and debugging.
