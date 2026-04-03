#!/usr/bin/env python3
"""skill-monitor scanner — fast single-pass analysis of all skills.

Replaces per-file shell loops with one Python process.
Reads all SKILL.md files, extracts metadata, runs security checks,
and outputs JSON for dashboard.sh to format.

Usage: python scanner.py [--json | --dashboard MODE]
"""
import json, os, re, sys, glob, hashlib, io
from pathlib import Path
from datetime import datetime, timezone

# Fix Windows GBK encoding — force UTF-8 output
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

HOME = Path.home()
SKILLS_DIR = HOME / ".claude" / "skills"
PLUGINS_DIR = HOME / ".claude" / "plugins" / "cache"
SETTINGS_FILE = HOME / ".claude" / "settings.json"
PLUGINS_FILE = HOME / ".claude" / "plugins" / "installed_plugins.json"
USAGE_LOG = HOME / ".claude" / "skill-usage.jsonl"
GSTACK_LOG = HOME / ".gstack" / "analytics" / "skill-usage.jsonl"
SNAPSHOT_DIR = HOME / ".claude" / "skill-monitor" / "snapshots"

# ─── Colors ─────────────────────────────────────────────
R = "\033[0m"; B = "\033[1m"; DIM = "\033[2m"
RED = "\033[1;31m"; GRN = "\033[1;32m"; YLW = "\033[1;33m"
BLU = "\033[1;34m"; CYN = "\033[1;36m"; WHT = "\033[1;37m"

def bar(val, mx=1, width=20, color=R):
    if mx == 0: mx = 1
    filled = min(val * width // mx, width)
    return f"{color}{'█'*filled}{'░'*(width-filled)}{R}"

def score_color(s):
    if s >= 90: return GRN
    if s >= 70: return YLW
    if s >= 50: return "\033[1;35m"
    return RED

# ─── Skill Discovery ───────────────────────────────────
def find_user_skills():
    results = []
    if SKILLS_DIR.exists():
        for p in SKILLS_DIR.iterdir():
            f = p / "SKILL.md"
            if f.is_file():
                results.append(("user", p.name, f))
    return results

def find_plugin_skills():
    results = []
    if not PLUGINS_DIR.exists():
        return results
    for org_dir in PLUGINS_DIR.iterdir():
        if not org_dir.is_dir():
            continue
        for pkg_dir in org_dir.iterdir():
            if not pkg_dir.is_dir():
                continue
            # Find latest version
            versions = sorted([v for v in pkg_dir.iterdir() if v.is_dir()], key=lambda x: x.name)
            if not versions:
                continue
            latest = versions[-1]
            # Claude Code loads plugin skills from skills/ subdir (official structure)
            # Also loads root-level SKILL.md dirs as fallback (some plugins use this)
            skills_dir = latest / "skills"
            if skills_dir.exists():
                for f in skills_dir.rglob("SKILL.md"):
                    results.append(("plugin", f.parent.name, f))
            else:
                # Fallback: scan root-level dirs (e.g., codebase-audit-suite)
                for f in latest.rglob("SKILL.md"):
                    results.append(("plugin", f.parent.name, f))
    return results

# ─── Description Extraction ────────────────────────────
def extract_description(content):
    """Handle both single-line and multi-line YAML descriptions."""
    # Multi-line: description: | or description: >
    m = re.search(r'^description:\s*[\|>]\s*\n((?:[ \t]+.+\n?)+)', content, re.MULTILINE)
    if m:
        return m.group(1).strip()
    # Single-line: description: "text" or description: text
    m = re.search(r'^description:\s*"?(.+?)"?\s*$', content, re.MULTILINE)
    if m:
        return m.group(1).strip()
    return ""

# ─── Security Scan ─────────────────────────────────────
CRITICAL_PATTERNS = [
    (r'bash\s+-i\s+>&\s+/dev/tcp|nc\s+-e|mkfifo.*nc', "reverse shell"),
    (r'base64\s+-d.*\|\s*(ba)?sh', "obfuscated execution"),
]
HIGH_PATTERNS = [
    (r'\$(API_KEY|TOKEN|SECRET|PASSWORD|ANTHROPIC_API)', r'curl|wget|fetch', "credential + network"),
    (r'~/\.ssh/|~/\.aws/|~/\.gnupg/', None, "sensitive path access"),
]
def scan_security(name, content):
    findings = []
    for pat, label in CRITICAL_PATTERNS:
        if re.search(pat, content):
            findings.append(("CRITICAL", label))
    for pat1, pat2, label in HIGH_PATTERNS:
        if pat2:
            if re.search(pat1, content) and re.search(pat2, content):
                findings.append(("HIGH", label))
        else:
            if re.search(pat1, content):
                findings.append(("HIGH", label))
    # settings.json without confirmation
    if re.search(r'settings\.json', content) and not re.search(r'AskUserQuestion|confirm|user', content, re.IGNORECASE):
        findings.append(("HIGH", "settings.json no confirm"))
    # Oversized
    if len(content) > 50000:
        findings.append(("MEDIUM", f"oversized ({len(content)//1024}KB)"))
    # Self-modification
    if name != "skill-monitor":
        if re.search(r'Write.*\.claude/skills|mv.*\.claude/skills', content):
            findings.append(("MEDIUM", "modifies skill dirs"))
    return findings

# ─── Hook Detection ────────────────────────────────────
def find_hooks(skills_data):
    hooks = []
    # From settings.json
    if SETTINGS_FILE.exists():
        try:
            sj = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
            for phase_key in ("PreToolUse", "PostToolUse", "Notification"):
                for entry in sj.get("hooks", {}).get(phase_key, []):
                    m = entry.get("matcher", "")
                    if m:
                        hooks.append(("settings.json", m.lower(), phase_key))
        except: pass
    # From skill frontmatter
    for s in skills_data:
        if s["source"] != "user":
            continue
        # Simple YAML parse for matcher fields
        for m in re.findall(r'matcher:\s*"?([^"\n]+)"?', s["raw_content"]):
            hooks.append((s["name"], m.strip().lower(), "skill"))
    # Find conflicts
    from collections import Counter
    matcher_sources = {}
    for src, matcher, phase in hooks:
        matcher_sources.setdefault(matcher, []).append(src)
    conflicts = {m: srcs for m, srcs in matcher_sources.items() if len(srcs) > 1}
    return hooks, conflicts

# ─── Usage Data ────────────────────────────────────────
def load_usage():
    records = []
    for log_file, source in [(USAGE_LOG, "hook"), (GSTACK_LOG, "gstack")]:
        if log_file.exists():
            try:
                for line in log_file.read_text(encoding="utf-8").strip().split("\n"):
                    if line.strip():
                        r = json.loads(line)
                        r["_source"] = source
                        records.append(r)
            except: pass
    return records

# ─── Plugin Versions ───────────────────────────────────
def load_plugin_versions():
    versions = []
    if not PLUGINS_FILE.exists():
        return versions
    try:
        data = json.loads(PLUGINS_FILE.read_text(encoding="utf-8"))
        for key, installs in sorted(data.get("plugins", {}).items()):
            if not installs:
                continue
            i = installs[0]
            name = key.split("@")[0] if "@" in key else key
            ver = i.get("version", "?")
            sha = i.get("gitCommitSha", "?")[:8]
            lu = i.get("lastUpdated", "")
            days = "?"
            if lu:
                try:
                    dt = datetime.fromisoformat(lu.replace("Z", "+00:00"))
                    days = (datetime.now(timezone.utc) - dt).days
                except: pass
            versions.append({"name": name, "version": ver, "date": lu[:10], "sha": sha, "days": days})
    except: pass
    return versions

# ─── Snapshot Diff ─────────────────────────────────────
def load_diff():
    if not SNAPSHOT_DIR.exists():
        return None
    snaps = sorted(SNAPSHOT_DIR.glob("snapshot_*.txt"), reverse=True)
    if len(snaps) < 2:
        return None
    latest_lines = snaps[0].read_text(encoding="utf-8", errors="replace").strip().split("\n")
    prev_lines = snaps[1].read_text(encoding="utf-8", errors="replace").strip().split("\n")
    def parse_names(lines):
        return {l.split("|")[0] for l in lines if l and not l.startswith("#") and not l.startswith("---") and "|" in l}
    def parse_hashes(lines):
        r = {}
        for l in lines:
            if l and not l.startswith("#") and not l.startswith("---") and "|" in l:
                parts = l.split("|")
                if len(parts) >= 4:
                    r[parts[0]] = parts[3]
        return r
    new_n, old_n = parse_names(latest_lines), parse_names(prev_lines)
    new_h, old_h = parse_hashes(latest_lines), parse_hashes(prev_lines)
    added = new_n - old_n
    removed = old_n - new_n
    changed = sum(1 for n in new_n & old_n if new_h.get(n) != old_h.get(n))
    # Get prev date
    prev_date = ""
    for l in prev_lines:
        if l.startswith("# Date:"):
            prev_date = l.replace("# Date:", "").strip()
            break
    return {"added": len(added), "removed": len(removed), "changed": changed, "prev_date": prev_date}

# ─── Main Scan ─────────────────────────────────────────
def scan_all():
    skills_data = []
    for source, name, path in find_user_skills() + find_plugin_skills():
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except:
            continue
        desc = extract_description(content)
        sec = scan_security(name, content)
        skills_data.append({
            "name": name,
            "source": source,
            "path": str(path),
            "size": len(content),
            "desc_chars": len(desc),
            "description": desc[:200],
            "security": sec,
            "raw_content": content,
            "hash": hashlib.md5(content.encode()).hexdigest()[:8],
        })
    return skills_data

# ─── Dashboard Rendering ──────────────────────────────
def render_header():
    print(f"\n{B}{CYN}  ┌─────────────────────────────────────────────────────┐{R}")
    print(f"{B}{CYN}  │{R}{B}         Skill Monitor Dashboard                   {CYN}│{R}")
    print(f"{B}{CYN}  │{R}{DIM}         {datetime.now().strftime('%Y-%m-%d %H:%M')}                            {CYN}│{R}")
    print(f"{B}{CYN}  └─────────────────────────────────────────────────────┘{R}\n")

def render_overview(sd):
    uc = sum(1 for s in sd if s["source"] == "user")
    pc = sum(1 for s in sd if s["source"] == "plugin")
    tc = uc + pc
    disk_u = sum(s["size"] for s in sd if s["source"] == "user")
    disk_p = sum(s["size"] for s in sd if s["source"] == "plugin")
    plugins = 0
    if PLUGINS_FILE.exists():
        try:
            plugins = len(json.loads(PLUGINS_FILE.read_text(encoding="utf-8")).get("plugins", {}))
        except: pass
    print(f"  {B}{WHT}SKILLS{R}    {B}{tc}{R} total  {DIM}({uc} user /{pc} plugin /{plugins} packages){R}")
    def fmt_size(b):
        if b >= 1048576: return f"{b/1048576:.1f}M"
        if b >= 1024: return f"{b/1024:.0f}K"
        return f"{b}B"
    print(f"  {DIM}Disk{R}      {fmt_size(disk_u)} user /{fmt_size(disk_p)} plugins\n")

def render_security(sd):
    tc = len(sd)
    print(f"  {B}{WHT}SECURITY{R}  {DIM}(pattern scan: {tc} skills){R}")
    c = h = m = 0
    c_list = []; h_list = []; m_list = []
    for s in sd:
        for sev, label in s["security"]:
            if sev == "CRITICAL": c += 1; c_list.append(f"  {RED}CRITICAL{R}  {s['name']}: {label}")
            elif sev == "HIGH": h += 1; h_list.append(f"  {YLW}HIGH    {R}  {s['name']}: {label}")
            else: m += 1; m_list.append(f"  {DIM}MEDIUM  {R}  {s['name']}: {label}")
    score = max(0, 100 - c*20 - h*5 - m*1)
    sc = score_color(score)
    print(f"  Score     {sc}{score}/100{R}  {bar(score, 100, 20, sc)}")
    if c == 0 and h == 0 and m == 0:
        print(f"  {GRN}No issues found{R}")
    else:
        print(f"  Findings  {RED}{c} critical{R}  {YLW}{h} high{R}  {DIM}{m} medium{R}")
        for l in c_list: print(l)
        for l in h_list: print(l)
    print()

def render_cost(sd, detailed=False):
    print(f"  {B}{WHT}TOKEN COST{R}  {DIM}(all skill descriptions injected per conversation){R}")
    user_chars = sum(s["desc_chars"] for s in sd if s["source"] == "user")
    plugin_chars = sum(s["desc_chars"] for s in sd if s["source"] == "plugin")
    total = user_chars + plugin_chars
    est = total * 10 // 35
    u_tok = user_chars * 10 // 35
    p_tok = plugin_chars * 10 // 35
    uc = sum(1 for s in sd if s["source"] == "user")
    pc = sum(1 for s in sd if s["source"] == "plugin")
    oversized = sum(1 for s in sd if s["size"] > 50000)
    tc = GRN if est <= 3000 else (YLW if est <= 5000 else RED)
    print(f"  Total     {tc}~{est}{R}/conv  {bar(est, 12000, 20, tc)}  {DIM}Oversized: {oversized}{R}")
    print(f"  {DIM}  User skills:    ~{u_tok} tok ({uc} skills){R}")
    print(f"  {DIM}  Plugin skills:  ~{p_tok} tok ({pc} skills){R}")
    if detailed:
        top = sorted([s for s in sd if s["desc_chars"] > 300], key=lambda x: -x["desc_chars"])[:10]
        if top:
            print(f"\n  {DIM}Top description costs (>300 chars):{R}")
            for s in top:
                tok = s["desc_chars"] * 10 // 35
                tag = f" {DIM}[p]{R}" if s["source"] == "plugin" else "   "
                print(f"  {CYN}{s['name']:<24}{R}{tag} ~{tok:4d} tok  {bar(tok, 500, 12, YLW)}")
    print()

def render_hooks_section(sd):
    hooks, conflicts = find_hooks(sd)
    print(f"  {B}{WHT}HOOKS{R}  {DIM}(settings.json + skill-embedded){R}")
    print(f"  Hooks     {BLU}{len(hooks)}{R} total  {DIM}(settings.json + skill frontmatter){R}")
    if conflicts:
        print(f"  Conflicts {RED}{len(conflicts)}{R}")
        for matcher, srcs in conflicts.items():
            print(f"  {YLW}CONFLICT{R}  matcher '{matcher}' registered by: {' '.join(srcs)}")
    else:
        print(f"  {GRN}No conflicts{R}")
    print()

def render_usage_section(sd):
    print(f"  {B}{WHT}USAGE{R}")
    records = load_usage()
    uc = sum(1 for s in sd if s["source"] == "user")
    if records:
        hook_c = sum(1 for r in records if r.get("_source") == "hook")
        gstack_c = sum(1 for r in records if r.get("_source") == "gstack")
        skills_used = {r.get("skill", "") for r in records}
        unique = len(skills_used - {""})
        zombie = uc - unique
        zp = zombie * 100 // max(uc, 1)
        zc = GRN if zp <= 50 else (YLW if zp <= 75 else RED)
        print(f"  Records   {BLU}{len(records)}{R}  {DIM}(hook: {hook_c} /gstack: {gstack_c}){R}")
        print(f"  Unique    {BLU}{unique}{R}/{uc} user skills")
        print(f"  Zombie    {zc}{zombie}{R} never used ({zp}%)")
        # Top used
        from collections import Counter
        counts = Counter(r.get("skill", "") for r in records if r.get("skill"))
        top = counts.most_common(8)
        if top:
            print(f"\n  {DIM}Top Used:{R}")
            top1 = top[0][1]
            for name, count in top:
                w = max(1, count * 20 // top1)
                print(f"  {CYN}{name:<24}{R} {BLU}{'█'*w}{R} {count}x")
    else:
        print(f"  {DIM}No usage data. Run /skill-monitor setup-tracking to start.{R}")
    print()

def render_versions():
    print(f"  {B}{WHT}PLUGIN VERSIONS{R}")
    versions = load_plugin_versions()
    if not versions:
        print(f"  {DIM}No version data available.{R}\n")
        return
    print(f"  {DIM}{'PLUGIN':<24} {'VERSION':<10} {'UPDATED':<12} AGE{R}")
    for v in versions:
        d = v["days"]
        ac = GRN if isinstance(d, int) and d <= 14 else (YLW if isinstance(d, int) and d <= 30 else RED)
        ds = f"{d}d" if isinstance(d, int) else "?d"
        print(f"  {v['name']:<24} {BLU}{v['version']:<10}{R} {v['date']:<12} {ac}{ds}{R}")
    print()

def render_diff():
    print(f"  {B}{WHT}CHANGES{R}  {DIM}(since last snapshot){R}")
    diff = load_diff()
    if not diff:
        print(f"  {DIM}Need 2+ snapshots.{R}\n")
        return
    print(f"  {DIM}Compared to: {diff['prev_date']}{R}")
    if diff["added"] == 0 and diff["removed"] == 0 and diff["changed"] == 0:
        print(f"  {GRN}No changes{R}")
    else:
        print(f"  {GRN}+{diff['added']} added{R}  {RED}-{diff['removed']} removed{R}  {YLW}~{diff['changed']} changed{R}")
    print()

def render_table(sd):
    user_skills = sorted([s for s in sd if s["source"] == "user"], key=lambda x: x["name"])
    print(f"  {B}{CYN}─── User Skills ────────────────────────────────────{R}")
    print(f"  {DIM}{'NAME':<28} {'SIZE':>7}  {'DESC':>5}  FLAGS{R}")
    print(f"  {DIM}{'─'*58}{R}")
    for s in user_skills:
        sz = s["size"]
        if sz >= 1048576: sz_h = f"{sz//1048576}MB"
        elif sz >= 1024: sz_h = f"{sz//1024}KB"
        else: sz_h = f"{sz}B"
        sc = RED if sz > 50000 else (YLW if sz > 30000 else R)
        dc = RED if s["desc_chars"] > 800 else (YLW if s["desc_chars"] > 500 else R)
        flags = ""
        if re.search(r'curl\s.*\|\s*(ba)?sh', s.get("raw_content", "")):
            flags += f"{RED}RCE{R} "
        if "hooks:" in s.get("raw_content", ""):
            flags += f"{BLU}hook{R} "
        print(f"  {s['name']:<28} {sc}{sz_h:>7}{R}  {dc}{s['desc_chars']:>4}c{R}  {flags}")
    print()

def render_budget(sd, detailed=False):
    """Analyze skill description budget health.

    Official behavior (code.claude.com/docs/en/skills):
    - All skill NAMES are always visible to Claude
    - Descriptions are truncated to 250 chars each when budget is tight
    - Budget = 1% of context window, floor 8K chars (adjustable via SLASH_COMMAND_TOOL_CHAR_BUDGET)
    - Truncation strips trigger keywords, reducing match accuracy
    - Too many skills also degrades matching quality (community: 8-10 starts conflicting)
    """
    # Budget: 1% of context. Opus 4.6 = 1M tokens ≈ 3.5M chars, 1% ≈ 35K chars
    # Conservative estimate accounting for system prompt overhead
    BUDGET = int(os.environ.get("SLASH_COMMAND_TOOL_CHAR_BUDGET", 0)) or 35000
    TRUNCATE_TO = 250  # official: "each entry is capped at 250 characters regardless of budget"
    NAME_OVERHEAD = 30  # approximate overhead per skill entry (name + formatting)
    # Community-tested quality thresholds
    QUALITY_GOOD = 30    # <=30 skills: Claude handles well
    QUALITY_WARN = 60    # 30-60: some description truncation
    QUALITY_BAD = 100    # 60-100: heavy truncation, trigger keywords lost
    # QUALITY_CRITICAL = 100+ : severe matching degradation

    print(f"  {B}{WHT}BUDGET{R}  {DIM}(skill description budget: ~{BUDGET//1000}K chars, {len(sd)} skills){R}")

    # Calculate actual cost
    total_full = sum(s["desc_chars"] + NAME_OVERHEAD for s in sd)
    total_truncated = sum(min(s["desc_chars"], TRUNCATE_TO) + NAME_OVERHEAD for s in sd)
    over_250 = sum(1 for s in sd if s["desc_chars"] > TRUNCATE_TO)
    tc = len(sd)

    # Budget utilization
    pct = total_truncated * 100 // max(BUDGET, 1)
    bc = GRN if pct <= 80 else (YLW if pct <= 100 else RED)
    print(f"  Used      {bc}{total_truncated:,}{R}/{BUDGET:,} chars  {bar(min(pct, 200), 200, 20, bc)}  ({pct}%)")

    if over_250 > 0:
        lost = total_full - total_truncated
        print(f"  {YLW}Truncated  {over_250} skills have desc >250c (losing ~{lost:,} chars of trigger keywords){R}")

    # Quality assessment (the more important metric)
    print()
    qc = GRN if tc <= QUALITY_GOOD else (YLW if tc <= QUALITY_WARN else (RED if tc <= QUALITY_BAD else RED))
    print(f"  {B}Quality{R}  {qc}{tc} skills{R}  ", end="")
    if tc <= QUALITY_GOOD:
        print(f"{GRN}Excellent{R} - Claude handles this well")
    elif tc <= QUALITY_WARN:
        print(f"{YLW}Moderate{R} - some descriptions truncated, minor matching degradation")
    elif tc <= QUALITY_BAD:
        print(f"{RED}Poor{R} - heavy truncation, Claude may pick wrong skills")
    else:
        print(f"{RED}Critical{R} - too many skills competing for attention")

    if tc > QUALITY_GOOD:
        print(f"  {DIM}Community consensus: <=30 skills for best accuracy, 3-6 for critical workflows{R}")
        if detailed:
            # Show which descriptions lose the most from truncation
            losers = sorted(
                [{"name": s["name"], "source": s["source"], "full": s["desc_chars"],
                  "lost": s["desc_chars"] - TRUNCATE_TO}
                 for s in sd if s["desc_chars"] > TRUNCATE_TO],
                key=lambda x: -x["lost"]
            )[:10]
            if losers:
                print(f"\n  {DIM}Most truncated descriptions (trigger keywords at risk):{R}")
                for e in losers:
                    tag = f"{DIM}[p]{R}" if e["source"] == "plugin" else "   "
                    print(f"  {YLW}  ~ {e['name']:<24}{R}{tag} {e['full']}c -> 250c ({e['lost']}c lost)")

            # Actionable recommendation
            print(f"\n  {DIM}Recommendations:{R}")
            if tc > QUALITY_BAD:
                print(f"  {DIM}  1. Reduce skill count (uninstall unused plugins){R}")
                print(f"  {DIM}  2. Run /skill-monitor compress to shorten user skill descriptions{R}")
            print(f"  {DIM}  3. Front-load trigger keywords in first 50 chars of each description{R}")
            print(f"  {DIM}  4. Set SLASH_COMMAND_TOOL_CHAR_BUDGET in env to increase budget{R}")
    print()

def render_footer():
    print(f"  {DIM}Modes: /skill-monitor [security|cost|hooks|budget|usage|versions|diff|full]{R}")
    print(f"  {DIM}Manage: /skill-monitor [disable|quarantine|restore] <name>{R}\n")

# ─── Main ──────────────────────────────────────────────
def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "overview"

    # Scan once, use everywhere
    sd = scan_all()
    # Strip raw_content for modes that don't need it (save memory)
    sd_light = [{k: v for k, v in s.items() if k != "raw_content"} for s in sd]

    render_header()

    if mode == "overview":
        render_overview(sd_light); render_security(sd_light); render_cost(sd_light)
        render_budget(sd_light); render_usage_section(sd_light); render_diff()
    elif mode == "security":
        render_security(sd_light)
    elif mode == "cost":
        render_cost(sd_light, detailed=True)
    elif mode == "hooks":
        render_hooks_section(sd)
    elif mode == "budget":
        render_budget(sd_light, detailed=True)
    elif mode == "usage":
        render_usage_section(sd_light)
    elif mode == "versions":
        render_versions()
    elif mode == "diff":
        render_diff()
    elif mode == "full":
        render_overview(sd_light); render_security(sd_light); render_cost(sd_light, detailed=True)
        render_budget(sd_light, detailed=True); render_hooks_section(sd)
        render_usage_section(sd_light); render_versions(); render_diff(); render_table(sd)
    else:
        print(f"  {RED}Unknown mode: {mode}{R}\n")

    render_footer()

    # Auto-snapshot (pure Python, no bash dependency)
    try:
        snap_dir = HOME / ".claude" / "skill-monitor" / "snapshots"
        snap_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        snap_file = snap_dir / f"snapshot_{ts}.txt"
        lines = [
            "# Skill Monitor Snapshot",
            f"# Date: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
            "# Format: name|source|size|hash",
            "---",
        ]
        for s in sd:
            lines.append(f"{s['name']}|{s['source']}|{s['size']}|{s.get('hash','')}")
        snap_file.write_text("\n".join(lines), encoding="utf-8")
        # Keep only last 30
        snaps = sorted(snap_dir.glob("snapshot_*.txt"), reverse=True)
        for old in snaps[30:]:
            old.unlink(missing_ok=True)
    except: pass

if __name__ == "__main__":
    main()
