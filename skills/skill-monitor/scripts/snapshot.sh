#!/usr/bin/env bash
# skill-monitor snapshot tool
# Saves current skill inventory state for diff comparison
# Usage: snapshot.sh [save|diff|list]

set -euo pipefail

SNAPSHOT_DIR="$HOME/.claude/skill-monitor/snapshots"
mkdir -p "$SNAPSHOT_DIR"

action="${1:-save}"

take_snapshot() {
  local out_file="$1"
  {
    echo "# Skill Monitor Snapshot"
    echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Format: name|source|size|sha256_first8"
    echo "---"

    # User-level skills
    for f in ~/.claude/skills/*/SKILL.md; do
      [ -f "$f" ] || continue
      name=$(basename "$(dirname "$f")")
      size=$(wc -c < "$f")
      hash=$(sha256sum "$f" 2>/dev/null | cut -c1-8 || shasum -a 256 "$f" 2>/dev/null | cut -c1-8 || echo "nohash")
      echo "${name}|user|${size}|${hash}"
    done

    # Plugin-provided skills (latest version only)
    for plugin_dir in ~/.claude/plugins/cache/*/; do
      plugin_name=$(basename "$plugin_dir")
      for pkg_dir in "$plugin_dir"*/; do
        latest=$(ls -d "$pkg_dir"*/ 2>/dev/null | sort -V | tail -1)
        [ -n "$latest" ] || continue
        find "$latest" -name "SKILL.md" 2>/dev/null | while read -r pf; do
          pname=$(basename "$(dirname "$pf")")
          psize=$(wc -c < "$pf")
          phash=$(sha256sum "$pf" 2>/dev/null | cut -c1-8 || shasum -a 256 "$pf" 2>/dev/null | cut -c1-8 || echo "nohash")
          echo "${pname}|plugin:${plugin_name}|${psize}|${phash}"
        done
      done
    done
  } > "$out_file"
}

case "$action" in
  save)
    ts=$(date +%Y%m%d_%H%M%S)
    outfile="${SNAPSHOT_DIR}/snapshot_${ts}.txt"
    take_snapshot "$outfile"
    echo "Snapshot saved: $outfile"
    # Keep only last 30 snapshots
    ls -t "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null || true
    ;;

  diff)
    # Compare latest two snapshots
    files=($(ls -t "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null))
    if [ ${#files[@]} -lt 2 ]; then
      echo "Need at least 2 snapshots for diff. Current count: ${#files[@]}"
      exit 0
    fi
    latest="${files[0]}"
    previous="${files[1]}"

    echo "Comparing:"
    echo "  NEW: $(head -2 "$latest" | tail -1)"
    echo "  OLD: $(head -2 "$previous" | tail -1)"
    echo "---"

    # Extract skill lines (skip header)
    new_skills=$(grep -v '^#\|^---' "$latest" | sort)
    old_skills=$(grep -v '^#\|^---' "$previous" | sort)

    # Added skills (in new but not in old, by name)
    new_names=$(echo "$new_skills" | cut -d'|' -f1)
    old_names=$(echo "$old_skills" | cut -d'|' -f1)

    added=$(comm -23 <(echo "$new_names") <(echo "$old_names"))
    removed=$(comm -13 <(echo "$new_names") <(echo "$old_names"))

    # Changed skills (same name but different hash)
    changed=""
    while IFS='|' read -r name source size hash; do
      old_hash=$(echo "$old_skills" | grep "^${name}|" | cut -d'|' -f4)
      if [ -n "$old_hash" ] && [ "$old_hash" != "$hash" ]; then
        changed="${changed}${name} (hash: ${old_hash} -> ${hash})\n"
      fi
    done <<< "$new_skills"

    if [ -n "$added" ]; then
      echo "ADDED:"
      echo "$added" | sed 's/^/  + /'
    fi
    if [ -n "$removed" ]; then
      echo "REMOVED:"
      echo "$removed" | sed 's/^/  - /'
    fi
    if [ -n "$changed" ]; then
      echo "CHANGED:"
      echo -e "$changed" | sed 's/^/  ~ /'
    fi
    if [ -z "$added" ] && [ -z "$removed" ] && [ -z "$changed" ]; then
      echo "No changes detected."
    fi
    ;;

  list)
    echo "Saved snapshots:"
    ls -lt "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null | head -10
    ;;

  *)
    echo "Usage: snapshot.sh [save|diff|list]"
    ;;
esac
