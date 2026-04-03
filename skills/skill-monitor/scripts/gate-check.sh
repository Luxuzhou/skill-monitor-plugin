#!/usr/bin/env bash
# skill-monitor install gate check v2
# Scans newly installed/modified skills for dangerous patterns
# Enhanced: checks over-permissive tools, data exfil, skill modification

set -euo pipefail

SKILLS_DIR="$HOME/.claude/skills"
PLUGINS_DIR="$HOME/.claude/plugins/cache"
ALERT_FILE="$HOME/.claude/skill-monitor/last-gate-alert.txt"

mkdir -p "$HOME/.claude/skill-monitor"

# Find SKILL.md files modified in the last 2 minutes (likely just installed)
new_skills=$(find "$SKILLS_DIR" "$PLUGINS_DIR" -name "SKILL.md" -mmin -2 2>/dev/null || true)

if [ -z "$new_skills" ]; then
  exit 0
fi

alerts=""
count=0

while IFS= read -r skill_file; do
  [ -z "$skill_file" ] && continue
  skill_name=$(basename "$(dirname "$skill_file")")

  # ── CRITICAL: Remote Code Execution ──
  if grep -qP 'curl\s.*\|\s*(ba)?sh|wget\s.*\|\s*(ba)?sh|eval\s+\$\(curl' "$skill_file" 2>/dev/null; then
    alerts="${alerts}[CRITICAL] ${skill_name}: curl|bash remote code execution\n"
    count=$((count + 1))
  fi

  # ── CRITICAL: Reverse shell ──
  if grep -qP 'bash\s+-i\s+>&\s+/dev/tcp|nc\s+-e|mkfifo.*nc\s' "$skill_file" 2>/dev/null; then
    alerts="${alerts}[CRITICAL] ${skill_name}: reverse shell pattern\n"
    count=$((count + 1))
  fi

  # ── CRITICAL: Obfuscated payloads ──
  if grep -qP 'base64\s+-d\s*\|\s*(ba)?sh|\\x[0-9a-fA-F]{2}.*\\x[0-9a-fA-F]{2}' "$skill_file" 2>/dev/null; then
    alerts="${alerts}[CRITICAL] ${skill_name}: obfuscated payload\n"
    count=$((count + 1))
  fi

  # ── HIGH: Credential env var + network send ──
  if grep -qP '\$(API_KEY|TOKEN|SECRET|PASSWORD|AWS_|ANTHROPIC_API_KEY|OPENAI_API_KEY)' "$skill_file" 2>/dev/null; then
    if grep -qP 'curl|wget|nc\s' "$skill_file" 2>/dev/null; then
      alerts="${alerts}[HIGH] ${skill_name}: credential variable + network access\n"
      count=$((count + 1))
    fi
  fi

  # ── HIGH: Sensitive file access ──
  if grep -qP '~/\.ssh/|~/\.aws/|~/\.gnupg/|~/\.env\b' "$skill_file" 2>/dev/null; then
    alerts="${alerts}[HIGH] ${skill_name}: sensitive directory access\n"
    count=$((count + 1))
  fi

  # ── HIGH: Unrestricted Bash in allowed-tools ──
  if grep -qP 'allowed-tools:' "$skill_file" 2>/dev/null; then
    if grep -A20 'allowed-tools:' "$skill_file" | grep -qP '^\s*-\s*Bash\s*$' 2>/dev/null; then
      alerts="${alerts}[HIGH] ${skill_name}: unrestricted Bash permission (no path/pattern)\n"
      count=$((count + 1))
    fi
  fi

  # ── HIGH: Skill self-modification ──
  if grep -qP 'Write.*~/.claude/skills|Write.*~/.claude/plugins|mv\s+.*~/.claude/plugins' "$skill_file" 2>/dev/null; then
    # Exclude skill-monitor itself (it needs to manage skills)
    if [ "$skill_name" != "skill-monitor" ]; then
      alerts="${alerts}[HIGH] ${skill_name}: writes to skill/plugin directories\n"
      count=$((count + 1))
    fi
  fi

  # ── HIGH: Settings modification ──
  if grep -qP 'Write.*settings\.json|Edit.*settings\.json' "$skill_file" 2>/dev/null; then
    if ! grep -qP 'AskUserQuestion|confirm' "$skill_file" 2>/dev/null; then
      alerts="${alerts}[HIGH] ${skill_name}: modifies settings.json without confirmation flow\n"
      count=$((count + 1))
    fi
  fi

  # ── MEDIUM: Destructive commands ──
  if grep -qP 'rm\s+-rf\s+[~/]|git\s+push\s+--force|DROP\s+TABLE|chmod\s+777' "$skill_file" 2>/dev/null; then
    alerts="${alerts}[MEDIUM] ${skill_name}: destructive command pattern\n"
    count=$((count + 1))
  fi

  # ── MEDIUM: Silent external telemetry ──
  if grep -qP 'curl\s+.*-X\s*POST|fetch\(|https?://[^/]*\.(io|com|net)' "$skill_file" 2>/dev/null; then
    if ! grep -qiP 'github\.com|anthropic\.com|localhost|127\.0\.0\.1' "$skill_file" 2>/dev/null; then
      alerts="${alerts}[MEDIUM] ${skill_name}: possible external telemetry\n"
      count=$((count + 1))
    fi
  fi

done <<< "$new_skills"

if [ "$count" -gt 0 ]; then
  header="╔══ SKILL MONITOR GATE CHECK v2 ══╗\n║ ${count} security issue(s) in new/modified skill(s)\n╚═════════════════════════════════╝"
  echo -e "${header}\n${alerts}"
  echo -e "${header}\n${alerts}" > "$ALERT_FILE"
  # Warn but don't block
  exit 0
fi

exit 0
