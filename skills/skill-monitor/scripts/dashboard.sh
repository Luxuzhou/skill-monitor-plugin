#!/usr/bin/env bash
# skill-monitor unified dashboard
# Delegates to Python scanner for fast single-pass analysis.
# Falls back to bash implementation if Python unavailable.
# Usage: dashboard.sh [overview|security|cost|hooks|usage|versions|diff|full]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Try Python fast path ────────────────────────────────
PY=""
command -v python &>/dev/null && PY="python"
[ -z "$PY" ] && command -v python3 &>/dev/null && PY="python3"

if [ -n "$PY" ] && [ -f "$SCRIPT_DIR/scanner.py" ]; then
  # Convert Git Bash path to Windows path for Python compatibility
  SCANNER="$SCRIPT_DIR/scanner.py"
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    SCANNER=$(cygpath -w "$SCANNER" 2>/dev/null || echo "$SCANNER")
  fi
  exec $PY "$SCANNER" "${1:-overview}" 2>/dev/null
fi
# ─── Fallback: bash implementation below ─────────────────

# ─── Colors ───────────────────────────────────────────────
R='\033[0m'; B='\033[1m'; DIM='\033[2m'
RED='\033[1;31m'; GRN='\033[1;32m'; YLW='\033[1;33m'
BLU='\033[1;34m'; MAG='\033[1;35m'; CYN='\033[1;36m'; WHT='\033[1;37m'

MODE="${1:-overview}"
SKILLS_DIR="$HOME/.claude/skills"
PLUGINS_DIR="$HOME/.claude/plugins/cache"
USAGE_LOG="$HOME/.claude/skill-usage.jsonl"
GSTACK_LOG="$HOME/.gstack/analytics/skill-usage.jsonl"
SNAPSHOT_DIR="$HOME/.claude/skill-monitor/snapshots"
QUARANTINE_DIR="$HOME/.claude/skill-monitor/quarantine"
PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"

bar() {
  local val="${1:-0}" max="${2:-1}" width="${3:-20}" color="${4:-$R}"
  [ "$max" -eq 0 ] && max=1
  local filled=$(( val * width / max ))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$(( width - filled ))
  local s=""
  local i
  for ((i=0;i<filled;i++)); do s+="█"; done
  for ((i=0;i<empty;i++)); do s+="░"; done
  echo -e "${color}${s}${R}"
}
score_color() { [ "$1" -ge 90 ] && echo -e "${GRN}" && return; [ "$1" -ge 70 ] && echo -e "${YLW}" && return; [ "$1" -ge 50 ] && echo -e "${MAG}" && return; echo -e "${RED}"; }

# ─── Collect skill paths ─────────────────────────────────
all_user=(); all_plugin=()
while IFS= read -r f; do [ -f "$f" ] && all_user+=("$f"); done < <(find "$SKILLS_DIR" -maxdepth 2 -name "SKILL.md" 2>/dev/null)
for pd in "$PLUGINS_DIR"/*/; do
  [ -d "$pd" ] || continue
  for pkg in "$pd"*/; do
    [ -d "$pkg" ] || continue
    latest=$(ls -d "$pkg"*/ 2>/dev/null | sort -V | tail -1); [ -n "$latest" ] || continue
    while IFS= read -r pf; do [ -f "$pf" ] && all_plugin+=("$pf"); done < <(find "$latest" -name "SKILL.md" 2>/dev/null)
  done
done 2>/dev/null
uc=${#all_user[@]}; pc=${#all_plugin[@]}; tc=$((uc+pc))

# ─── Helper: Windows path for Python ─────────────────────
win_path() { echo "$1" | sed -E 's|^/([a-zA-Z])/|\1:/|'; }

# ═══════════════════════════════════════════════════════════
# SECTION: header
# ═══════════════════════════════════════════════════════════
render_header() {
  echo ""
  echo -e "${B}${CYN}  ┌─────────────────────────────────────────────────────┐${R}"
  echo -e "${B}${CYN}  │${R}${B}         Skill Monitor Dashboard                   ${CYN}│${R}"
  echo -e "${B}${CYN}  │${R}${DIM}         $(date '+%Y-%m-%d %H:%M')                            ${CYN}│${R}"
  echo -e "${B}${CYN}  └─────────────────────────────────────────────────────┘${R}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: overview
# ═══════════════════════════════════════════════════════════
render_overview() {
  local disabled=$(find "$SKILLS_DIR" -name "SKILL.md.disabled" 2>/dev/null | wc -l)
  local quarantined=0; [ -d "$QUARANTINE_DIR" ] && quarantined=$(ls -d "$QUARANTINE_DIR"/*/ 2>/dev/null | wc -l)
  local disk_u=$(du -sh "$SKILLS_DIR" 2>/dev/null | cut -f1)
  local disk_p=$(du -sh "$PLUGINS_DIR" 2>/dev/null | cut -f1)
  local plugins=0; [ -f "$PLUGINS_FILE" ] && plugins=$(grep -c '"scope"' "$PLUGINS_FILE" 2>/dev/null || echo 0)

  echo -e "  ${B}${WHT}SKILLS${R}    ${B}${tc}${R} total  ${DIM}(${uc} user · ${pc} plugin · ${plugins} packages)${R}"
  echo -e "  ${DIM}Disk${R}      ${disk_u} user · ${disk_p} plugins"
  [ "$disabled" -gt 0 ] || [ "$quarantined" -gt 0 ] && echo -e "  ${YLW}Disabled${R}  ${disabled}    ${RED}Quarantined${R}  ${quarantined}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: security
# ═══════════════════════════════════════════════════════════
render_security() {
  echo -e "  ${B}${WHT}SECURITY${R}  ${DIM}(pattern scan: ${tc} skills)${R}"

  local critical=0 high=0 medium=0
  local critical_list="" high_list="" medium_list=""

  scan_one() {
    local f="$1" name
    name=$(basename "$(dirname "$f")")

    # CRITICAL (-15): Genuinely malicious patterns only
    # Reverse shell — no legitimate skill needs this
    if grep -qE 'bash\s+-i\s+>&\s+/dev/tcp|nc\s+-e|mkfifo.*nc' "$f" 2>/dev/null; then
      critical=$((critical+1)); critical_list+="  ${RED}CRITICAL${R}  ${name}: reverse shell\n"
    fi
    # Base64-decoded execution — obfuscation indicates malice
    if grep -qE 'base64\s+-d.*\|\s*(ba)?sh' "$f" 2>/dev/null; then
      critical=$((critical+1)); critical_list+="  ${RED}CRITICAL${R}  ${name}: obfuscated execution\n"
    fi

    # HIGH (-5): Unusual risk patterns (not normal tool behavior)
    # Credential env vars combined with network exfiltration
    if grep -qE '\$(API_KEY|TOKEN|SECRET|PASSWORD|ANTHROPIC_API)' "$f" 2>/dev/null; then
      if grep -qE 'curl|wget|fetch' "$f" 2>/dev/null; then
        high=$((high+1)); high_list+="  ${YLW}HIGH    ${R}  ${name}: credential + network\n"
      fi
    fi
    # Sensitive directory access (~/.ssh, ~/.aws, ~/.gnupg)
    if grep -qE '~/\.ssh/|~/\.aws/|~/\.gnupg/' "$f" 2>/dev/null; then
      high=$((high+1)); high_list+="  ${YLW}HIGH    ${R}  ${name}: sensitive path access\n"
    fi
    # Modifies settings.json without confirmation flow
    if grep -qE 'settings\.json' "$f" 2>/dev/null; then
      if ! grep -qE 'AskUserQuestion|confirm|user' "$f" 2>/dev/null; then
        high=$((high+1)); high_list+="  ${YLW}HIGH    ${R}  ${name}: settings.json no confirm\n"
      fi
    fi

    # MEDIUM (-1): Worth noting, common in legitimate tools
    # Oversized skill (>50KB)
    local fsize
    fsize=$(wc -c < "$f")
    if [ "$fsize" -gt 50000 ]; then
      medium=$((medium+1)); medium_list+="  ${DIM}MEDIUM  ${R}  ${name}: oversized ($((fsize/1024))KB)\n"
    fi
    # Self-modification of skill ecosystem (exclude skill-monitor)
    if [ "$name" != "skill-monitor" ]; then
      if grep -qE 'Write.*\.claude/skills|mv.*\.claude/skills' "$f" 2>/dev/null; then
        medium=$((medium+1)); medium_list+="  ${DIM}MEDIUM  ${R}  ${name}: modifies skill dirs\n"
      fi
    fi
  }

  for f in "${all_user[@]}"; do scan_one "$f"; done
  for f in "${all_plugin[@]}"; do scan_one "$f"; done

  local score=100
  [ "$critical" -gt 0 ] && score=$((score - critical * 20))
  [ "$high" -gt 0 ] && score=$((score - high * 5))
  [ "$medium" -gt 0 ] && score=$((score - medium * 1))
  [ "$score" -lt 0 ] && score=0
  local sc; sc=$(score_color $score)

  echo -e "  Score     ${sc}${score}/100${R}  $(bar $score 100 20 "$sc")"

  if [ "$critical" -eq 0 ] && [ "$high" -eq 0 ] && [ "$medium" -eq 0 ]; then
    echo -e "  ${GRN}No issues found${R}"
  else
    echo -e "  Findings  ${RED}${critical} critical${R}  ${YLW}${high} high${R}  ${DIM}${medium} medium${R}"
    [ -n "$critical_list" ] && echo -e "$critical_list"
    [ -n "$high_list" ] && echo -e "$high_list"
    [ "$MODE" = "security" ] && [ -n "$medium_list" ] && echo -e "$medium_list"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: cost
# ═══════════════════════════════════════════════════════════
render_cost() {
  echo -e "  ${B}${WHT}TOKEN COST${R}  ${DIM}(all skill descriptions injected per conversation)${R}"

  local user_chars=0 plugin_chars=0 oversized=0
  local top_costs=""

  # Extract description chars — handles both single-line and multi-line YAML
  extract_desc_chars() {
    local f="$1"
    # Try multi-line first (description: | or description: >)
    local mc
    mc=$(awk '/^description:\s*[\|>]/{found=1;next} found && /^  /{print;next} found{exit}' "$f" 2>/dev/null | wc -c)
    if [ "$mc" -gt 0 ]; then echo "$mc"; return; fi
    # Try single-line (description: "text" or description: text)
    local sc
    sc=$(sed -n 's/^description:\s*"\?\(.*\)"\?\s*$/\1/p' "$f" 2>/dev/null | head -1 | wc -c)
    echo "$sc"
  }

  for f in "${all_user[@]}"; do
    [ -f "$f" ] || continue
    local dc name size
    dc=$(extract_desc_chars "$f")
    user_chars=$((user_chars + dc))
    name=$(basename "$(dirname "$f")")
    size=$(wc -c < "$f")
    [ "$size" -gt 50000 ] && oversized=$((oversized+1))
    [ "$dc" -gt 300 ] && top_costs+="${dc}|${name}|user\n"
  done
  for f in "${all_plugin[@]}"; do
    [ -f "$f" ] || continue
    local dc name size
    dc=$(extract_desc_chars "$f")
    plugin_chars=$((plugin_chars + dc))
    name=$(basename "$(dirname "$f")")
    size=$(wc -c < "$f")
    [ "$size" -gt 50000 ] && oversized=$((oversized+1))
    [ "$dc" -gt 300 ] && top_costs+="${dc}|${name}|plugin\n"
  done

  local total_chars=$((user_chars + plugin_chars))
  local est_tokens=$((total_chars * 10 / 35))
  local user_tokens=$((user_chars * 10 / 35))
  local plugin_tokens=$((plugin_chars * 10 / 35))
  local tok_color="${GRN}"
  [ "$est_tokens" -gt 3000 ] && tok_color="${YLW}"
  [ "$est_tokens" -gt 5000 ] && tok_color="${RED}"

  echo -e "  Total     ${tok_color}~${est_tokens}${R}/conv  $(bar $est_tokens 12000 20 "$tok_color")  ${DIM}Oversized: ${oversized}${R}"
  echo -e "  ${DIM}  User skills:    ~${user_tokens} tok (${uc} skills)${R}"
  echo -e "  ${DIM}  Plugin skills:  ~${plugin_tokens} tok (${pc} skills)${R}"

  if [ "$MODE" = "cost" ] && [ -n "$top_costs" ]; then
    echo ""
    echo -e "  ${DIM}Top description costs (>300 chars):${R}"
    echo -e "$top_costs" | sort -rn -t'|' -k1 | head -10 | while IFS='|' read -r chars name src; do
      [ -z "$chars" ] && continue
      local toks=$((chars * 10 / 35))
      local tag=""; [ "$src" = "plugin" ] && tag="${DIM}[p]${R}"
      printf "  ${CYN}%-24s${R} %s ~%4d tok  $(bar $toks 500 12 "${YLW}")\n" "$name" "$tag" "$toks"
    done
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: usage
# ═══════════════════════════════════════════════════════════
render_usage() {
  echo -e "  ${B}${WHT}USAGE${R}"
  local usage_total=0 usage_unique=0 gstack_total=0
  [ -f "$USAGE_LOG" ] && { usage_total=$(wc -l < "$USAGE_LOG"); usage_unique=$(cut -d'"' -f4 "$USAGE_LOG" | sort -u | wc -l); }
  [ -f "$GSTACK_LOG" ] && gstack_total=$(wc -l < "$GSTACK_LOG")

  if [ "$((usage_total + gstack_total))" -gt 0 ]; then
    echo -e "  Records   ${BLU}$((usage_total + gstack_total))${R}  ${DIM}(hook: ${usage_total} · gstack: ${gstack_total})${R}"
    echo -e "  Unique    ${BLU}${usage_unique}${R}/${uc} user skills"
    local zombie=$((uc - usage_unique)) zp=0
    [ "$uc" -gt 0 ] && zp=$((zombie * 100 / uc))
    local zc="${GRN}"; [ "$zp" -gt 50 ] && zc="${YLW}"; [ "$zp" -gt 75 ] && zc="${RED}"
    echo -e "  Zombie    ${zc}${zombie}${R} never used (${zp}%)"

    local top_skills
    top_skills=$(cat "$GSTACK_LOG" "$USAGE_LOG" 2>/dev/null | grep -o '"skill":"[^"]*"' | cut -d'"' -f4 | sort | uniq -c | sort -rn | head -8)
    if [ -n "$top_skills" ]; then
      echo ""
      echo -e "  ${DIM}Top Used:${R}"
      local top1; top1=$(echo "$top_skills" | head -1 | awk '{print $1}')
      echo "$top_skills" | while read -r count name; do
        [ -z "$count" ] && continue
        local w=$((count * 20 / top1)); [ "$w" -lt 1 ] && w=1
        local bstr=""; for ((i=0;i<w;i++)); do bstr+="█"; done
        printf "  ${CYN}%-24s${R} ${BLU}%s${R} %s\n" "$name" "$bstr" "${count}x"
      done
    fi
  else
    echo -e "  ${DIM}No usage data. Run /skill-monitor setup-tracking to start.${R}"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: versions
# ═══════════════════════════════════════════════════════════
render_versions() {
  echo -e "  ${B}${WHT}PLUGIN VERSIONS${R}"

  local PY=""
  command -v python &>/dev/null && PY="python"
  [ -z "$PY" ] && command -v python3 &>/dev/null && PY="python3"

  if [ -z "$PY" ] || [ ! -f "$PLUGINS_FILE" ]; then
    echo -e "  ${DIM}Python or installed_plugins.json not available.${R}"
    echo ""; return
  fi

  local PF_PY; PF_PY=$(win_path "$PLUGINS_FILE")
  local TMPDATA; TMPDATA=$(mktemp)
  $PY -c "
import json, sys
from datetime import datetime, timezone
sys.stdout.reconfigure(encoding='utf-8')
with open('$PF_PY') as f:
    data = json.load(f)
for key, installs in sorted(data.get('plugins', {}).items()):
    if not installs: continue
    i = installs[0]
    name = key.split('@')[0] if '@' in key else key
    ver = i.get('version', '?')
    sha = i.get('gitCommitSha', '?')[:8]
    lu = i.get('lastUpdated', '')
    days = '?'
    if lu:
        try:
            dt = datetime.fromisoformat(lu.replace('Z', '+00:00'))
            days = str((datetime.now(timezone.utc) - dt).days)
        except: pass
    print(f'{name}|{ver}|{lu[:10]}|{sha}|{days}')
" > "$TMPDATA" 2>/dev/null

  printf "  ${DIM}%-24s %-10s %-12s %s${R}\n" "PLUGIN" "VERSION" "UPDATED" "AGE"
  while IFS='|' read -r name ver date sha days; do
    days=$(echo "$days" | tr -d '\r\n ')
    local age_color="${GRN}"
    if [ "$days" = "?" ]; then age_color="${DIM}"
    elif [ "$days" -gt 30 ]; then age_color="${RED}"
    elif [ "$days" -gt 14 ]; then age_color="${YLW}"
    fi
    printf "  %-24s ${BLU}%-10s${R} %-12s ${age_color}%sd${R}\n" "$name" "$ver" "$date" "$days"
  done < "$TMPDATA"
  rm -f "$TMPDATA"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: hooks
# ═══════════════════════════════════════════════════════════
render_hooks() {
  echo -e "  ${B}${WHT}HOOKS${R}  ${DIM}(settings.json + skill-embedded)${R}"

  local SETTINGS="$HOME/.claude/settings.json"
  local conflicts=0 total_hooks=0
  local matchers=""

  # 1. Collect hooks from settings.json
  if [ -f "$SETTINGS" ]; then
    local sj_matchers
    sj_matchers=$(grep -o '"matcher":\s*"[^"]*"' "$SETTINGS" 2>/dev/null | sed 's/"matcher":\s*"//;s/"//' | tr '[:upper:]' '[:lower:]')
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      matchers+="settings.json|${m}\n"
      total_hooks=$((total_hooks + 1))
    done <<< "$sj_matchers"
  fi

  # 2. Collect hooks from skill frontmatter
  for f in "${all_user[@]}"; do
    [ -f "$f" ] || continue
    local name; name=$(basename "$(dirname "$f")")
    local sk_matchers
    sk_matchers=$(grep -A1 'matcher:' "$f" 2>/dev/null | grep 'matcher:' | sed 's/.*matcher:\s*"*//;s/".*//;s/\s*$//' | tr '[:upper:]' '[:lower:]')
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      matchers+="${name}|${m}\n"
      total_hooks=$((total_hooks + 1))
    done <<< "$sk_matchers"
  done

  # 3. Detect duplicate matchers (same event from different sources)
  local conflict_list=""
  local dup_matchers
  dup_matchers=$(echo -e "$matchers" | cut -d'|' -f2 | sort | uniq -d)
  while IFS= read -r dm; do
    [ -z "$dm" ] && continue
    local sources
    sources=$(echo -e "$matchers" | grep "|${dm}$" | cut -d'|' -f1 | tr '\n' ' ')
    conflict_list+="  ${YLW}CONFLICT${R}  matcher '${dm}' registered by: ${sources}\n"
    conflicts=$((conflicts + 1))
  done <<< "$dup_matchers"

  echo -e "  Hooks     ${BLU}${total_hooks}${R} total  ${DIM}(settings.json + skill frontmatter)${R}"
  if [ "$conflicts" -gt 0 ]; then
    echo -e "  Conflicts ${RED}${conflicts}${R}"
    echo -e "$conflict_list"
  else
    echo -e "  ${GRN}No conflicts${R}"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: diff
# ═══════════════════════════════════════════════════════════
render_diff() {
  echo -e "  ${B}${WHT}CHANGES${R}  ${DIM}(since last snapshot)${R}"

  local snap_count; snap_count=$(ls "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null | wc -l)
  if [ "$snap_count" -lt 2 ]; then
    echo -e "  ${DIM}Need 2+ snapshots. Run /skill-monitor to create one.${R}"
    echo ""; return
  fi

  local files_arr=($(ls -t "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null))
  local latest="${files_arr[0]}" prev="${files_arr[1]}"
  local prev_date; prev_date=$(head -2 "$prev" | tail -1 | sed 's/# Date: //')
  echo -e "  ${DIM}Compared to: ${prev_date}${R}"

  local new_names old_names
  new_names=$(grep -v '^#\|^---' "$latest" 2>/dev/null | cut -d'|' -f1 | sort)
  old_names=$(grep -v '^#\|^---' "$prev" 2>/dev/null | cut -d'|' -f1 | sort)

  local added removed
  added=$(comm -23 <(echo "$new_names") <(echo "$old_names") | grep -c . || true)
  removed=$(comm -13 <(echo "$new_names") <(echo "$old_names") | grep -c . || true)

  local changed=0
  while IFS='|' read -r name source size hash; do
    [ -z "$name" ] && continue
    local old_hash; old_hash=$(grep -v '^#\|^---' "$prev" | grep "^${name}|" | cut -d'|' -f4)
    [ -n "$old_hash" ] && [ "$old_hash" != "$hash" ] && changed=$((changed+1))
  done < <(grep -v '^#\|^---' "$latest" 2>/dev/null)

  if [ "$added" -eq 0 ] && [ "$removed" -eq 0 ] && [ "$changed" -eq 0 ]; then
    echo -e "  ${GRN}No changes${R}"
  else
    echo -e "  ${GRN}+${added} added${R}  ${RED}-${removed} removed${R}  ${YLW}~${changed} changed${R}"

    if [ "$MODE" = "diff" ]; then
      [ "$added" -gt 0 ] && comm -23 <(echo "$new_names") <(echo "$old_names") | while read -r n; do
        echo -e "    ${GRN}+ ${n}${R}"; done
      [ "$removed" -gt 0 ] && comm -13 <(echo "$new_names") <(echo "$old_names") | while read -r n; do
        echo -e "    ${RED}- ${n}${R}"; done
    fi
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: skill table (detailed)
# ═══════════════════════════════════════════════════════════
render_table() {
  echo -e "  ${B}${CYN}─── User Skills ────────────────────────────────────${R}"
  printf "  ${DIM}%-28s %7s  %5s  %s${R}\n" "NAME" "SIZE" "DESC" "FLAGS"
  echo -e "  ${DIM}$(printf '%.0s─' {1..58})${R}"

  for f in "${all_user[@]}"; do
    [ -f "$f" ] || continue
    local name size desc_c size_h flags=""
    name=$(basename "$(dirname "$f")")
    size=$(wc -c < "$f")
    desc_c=$(extract_desc_chars "$f")

    local sc="${R}"; [ "$size" -gt 30000 ] && sc="${YLW}"; [ "$size" -gt 50000 ] && sc="${RED}"
    local dc="${R}"; [ "$desc_c" -gt 500 ] && dc="${YLW}"; [ "$desc_c" -gt 800 ] && dc="${RED}"

    grep -qP 'curl\s.*\|\s*(ba)?sh' "$f" 2>/dev/null && flags+="${RED}RCE${R} "
    grep -qP 'hooks:' "$f" 2>/dev/null && flags+="${BLU}hook${R} "
    grep -qP 'allowed-tools:' "$f" 2>/dev/null && flags+="${DIM}tools${R} "

    [ "$size" -ge 1048576 ] && size_h="$((size/1048576))MB"
    [ "$size" -lt 1048576 ] && [ "$size" -ge 1024 ] && size_h="$((size/1024))KB"
    [ "$size" -lt 1024 ] && size_h="${size}B"

    printf "  %-28s ${sc}%7s${R}  ${dc}%4dc${R}  %b\n" "$name" "$size_h" "$desc_c" "$flags"
  done
  echo ""
}

# ═══════════════════════════════════════════════════════════
# SECTION: footer
# ═══════════════════════════════════════════════════════════
render_footer() {
  echo -e "  ${DIM}Modes: /skill-monitor [security|cost|usage|versions|diff|full]${R}"
  echo -e "  ${DIM}Manage: /skill-monitor [disable|quarantine|restore] <name>${R}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# Auto-snapshot (silent)
# ═══════════════════════════════════════════════════════════
auto_snapshot() {
  bash "$HOME/.claude/skills/skill-monitor/scripts/snapshot.sh" save >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# MAIN DISPATCH
# ═══════════════════════════════════════════════════════════
render_header

case "$MODE" in
  overview|compact)
    render_overview; render_security; render_cost; render_usage; render_diff ;;
  security)
    render_security ;;
  cost)
    render_cost ;;
  usage)
    render_usage ;;
  versions)
    render_versions ;;
  diff)
    render_diff ;;
  hooks)
    render_hooks ;;
  full)
    render_overview; render_security; render_cost; render_hooks; render_usage; render_versions; render_diff; render_table ;;
  *)
    echo -e "  ${RED}Unknown mode: ${MODE}${R}"; echo "" ;;
esac

render_footer
auto_snapshot
