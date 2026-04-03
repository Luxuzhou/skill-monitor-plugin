#!/usr/bin/env bash
# skill-monitor usage tracker hook v3
# Logs every Skill tool invocation to ~/.claude/skill-usage.jsonl
# Cross-platform: uses grep -E (not -P) for Windows Git Bash compatibility

set -uo pipefail

LOG_FILE="$HOME/.claude/skill-usage.jsonl"
CHECKSUM_FILE="$HOME/.claude/skill-usage.sha256"

# Read tool input from stdin
input=$(cat)

# Debug: log raw input to diagnose hook issues (remove after debugging)
DEBUG_LOG="$HOME/.claude/skill-monitor/hook-debug.log"
mkdir -p "$HOME/.claude/skill-monitor"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RAW_INPUT: ${input:0:500}" >> "$DEBUG_LOG" 2>/dev/null

# Validate: input must be non-empty and look like JSON
if [ -z "$input" ] || ! echo "$input" | grep -q '^{'; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] REJECTED: empty or not JSON" >> "$DEBUG_LOG" 2>/dev/null
  exit 0
fi

# Extract skill name from hook stdin JSON
# Claude Code PreToolUse sends: {"tool_name":"Skill","tool_input":{"skill":"xxx",...},...}
skill_name=""
if command -v jq &>/dev/null; then
  skill_name=$(echo "$input" | jq -r '.tool_input.skill // .skill // .name // empty' 2>/dev/null || true)
else
  # Fallback: extract "skill":"value" with basic grep (matches both top-level and nested)
  skill_name=$(echo "$input" | grep -oE '"skill"\s*:\s*"[^"]+"' | head -1 | sed 's/.*"skill"\s*:\s*"//;s/"$//')
fi

# Validate skill name: non-empty, safe characters only
if [ -z "$skill_name" ]; then
  exit 0
fi
if ! echo "$skill_name" | grep -qE '^[a-zA-Z0-9_:.-]{1,100}$'; then
  exit 0
fi

# Build log entry
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
project=$(basename "$(pwd)" 2>/dev/null | tr -cd 'a-zA-Z0-9_-' | head -c 64)

# Append to log
if command -v jq &>/dev/null; then
  jq -nc --arg s "$skill_name" --arg t "$ts" --arg p "$project" \
    '{skill:$s, ts:$t, project:$p}' >> "$LOG_FILE"
else
  echo "{\"skill\":\"$skill_name\",\"ts\":\"$ts\",\"project\":\"$project\"}" >> "$LOG_FILE"
fi

# Update checksum
if command -v sha256sum &>/dev/null; then
  sha256sum "$LOG_FILE" > "$CHECKSUM_FILE" 2>/dev/null
elif command -v shasum &>/dev/null; then
  shasum -a 256 "$LOG_FILE" > "$CHECKSUM_FILE" 2>/dev/null
fi

exit 0
