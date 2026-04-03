#!/usr/bin/env bash
# skill-monitor plugin version checker
# Reads installed_plugins.json and reports version status
# Usage: version-check.sh [--check-remote]

set -euo pipefail

PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"
MARKETPLACES_FILE="$HOME/.claude/plugins/known_marketplaces.json"

# Convert Git Bash paths (/c/Users/...) to Windows paths (C:/Users/...) for Python
win_path() {
  echo "$1" | sed -E 's|^/([a-zA-Z])/|\1:/|'
}
PLUGINS_FILE_PY=$(win_path "$PLUGINS_FILE")
MARKETPLACES_FILE_PY=$(win_path "$MARKETPLACES_FILE")

# Colors
R='\033[0m'
B='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[1;36m'

CHECK_REMOTE="${1:-}"

if [ ! -f "$PLUGINS_FILE" ]; then
  echo "No installed_plugins.json found."
  exit 0
fi

PYTHON=""
if command -v python &>/dev/null; then
  PYTHON="python"
elif command -v python3 &>/dev/null; then
  PYTHON="python3"
fi

if [ -z "$PYTHON" ]; then
  echo -e "  ${YLW}Python not available. Install Python for version checking.${R}"
  exit 0
fi

echo ""
echo -e "${B}${CYN}  Plugin Version Report${R}"
echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M')${R}"
echo ""
printf "  ${DIM}%-30s %-12s %-12s %-10s %s${R}\n" "PLUGIN" "VERSION" "INSTALLED" "SHA" "STATUS"
echo -e "  ${DIM}$(printf '%.0s─' {1..80})${R}"

# Local version report
TMPDATA=$(mktemp)
$PYTHON -c "
import json, sys
from datetime import datetime, timezone

with open('$PLUGINS_FILE_PY') as f:
    data = json.load(f)

plugins = data.get('plugins', {})
for key, installs in sorted(plugins.items()):
    if not installs:
        continue
    install = installs[0]
    name = key.split('@')[0] if '@' in key else key
    version = install.get('version', '?')
    sha = install.get('gitCommitSha', '?')[:8]
    last_updated = install.get('lastUpdated', '')

    days = '?'
    if last_updated:
        try:
            dt = datetime.fromisoformat(last_updated.replace('Z', '+00:00'))
            delta = datetime.now(timezone.utc) - dt
            days = str(delta.days)
        except:
            pass

    print(f'{name}|{version}|{last_updated[:10]}|{sha}|{days}')
" > "$TMPDATA"

while IFS='|' read -r name version install_date sha days; do
  # Strip Windows CR and whitespace
  days=$(echo "$days" | tr -d '\r\n ')
  status=""
  if [ "$days" = "?" ]; then
    status="${DIM}unknown${R}"
  elif [ "$days" -le 3 ]; then
    status="${GRN}current (${days}d)${R}"
  elif [ "$days" -le 14 ]; then
    status="${GRN}${days}d ago${R}"
  elif [ "$days" -le 30 ]; then
    status="${YLW}${days}d ago${R}"
  else
    status="${RED}${days}d ago${R}"
  fi

  printf "  %-30s ${BLU}%-12s${R} %-12s ${DIM}%-10s${R} %b\n" "$name" "$version" "$install_date" "$sha" "$status"
done < "$TMPDATA"
rm -f "$TMPDATA"

# Remote check
if [ "$CHECK_REMOTE" = "--check-remote" ]; then
  echo ""
  echo -e "  ${B}${CYN}Remote Update Check${R}"
  echo -e "  ${DIM}Checking GitHub for newer commits...${R}"
  echo ""

  updates=0
  current=0
  errors=0

  $PYTHON -c "
import json, subprocess, sys

with open('$PLUGINS_FILE_PY') as f:
    plugins_data = json.load(f)

markets_data = {}
try:
    with open('$MARKETPLACES_FILE_PY') as f:
        markets_data = json.load(f)
except:
    pass

for key, installs in sorted(plugins_data.get('plugins', {}).items()):
    if not installs:
        continue
    install = installs[0]
    name = key.split('@')[0] if '@' in key else key
    marketplace = key.split('@')[1] if '@' in key else ''
    installed_sha = install.get('gitCommitSha', '')

    if not marketplace or marketplace not in markets_data:
        print(f'{name}|skip|no marketplace info')
        continue

    repo = markets_data[marketplace].get('source', {}).get('repo', '')
    if not repo:
        print(f'{name}|skip|no repo info')
        continue

    try:
        result = subprocess.run(
            ['git', 'ls-remote', f'https://github.com/{repo}.git', 'HEAD'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0 and result.stdout.strip():
            remote_sha = result.stdout.split()[0]
            if installed_sha and remote_sha:
                if remote_sha == installed_sha or remote_sha.startswith(installed_sha) or installed_sha.startswith(remote_sha[:len(installed_sha)]):
                    print(f'{name}|current|up to date')
                else:
                    print(f'{name}|update|{installed_sha[:8]} -> {remote_sha[:8]}')
            else:
                print(f'{name}|unknown|cannot compare SHAs')
        else:
            print(f'{name}|error|git ls-remote failed')
    except subprocess.TimeoutExpired:
        print(f'{name}|timeout|network slow')
    except Exception as e:
        print(f'{name}|error|{str(e)[:50]}')
" | while IFS='|' read -r name status detail; do
    if [ "$status" = "update" ]; then
      printf "  ${RED}  UPDATE${R}  %-30s ${DIM}%s${R}\n" "$name" "$detail"
    elif [ "$status" = "current" ]; then
      printf "  ${GRN}      OK${R}  %-30s\n" "$name"
    elif [ "$status" = "skip" ]; then
      printf "  ${DIM}    SKIP${R}  %-30s ${DIM}%s${R}\n" "$name" "$detail"
    else
      printf "  ${YLW}   ERROR${R}  %-30s ${DIM}%s${R}\n" "$name" "$detail"
    fi
  done

  echo ""
  echo -e "  ${DIM}To update a plugin: claude /install <plugin-name>@<marketplace>${R}"
fi

echo ""
