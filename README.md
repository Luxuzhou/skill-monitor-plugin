<p align="center">
  <img src="https://img.shields.io/badge/v0.1.0-6366f1?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Claude_Code-black?style=flat-square&logo=anthropic" alt="Claude Code">
  <img src="https://img.shields.io/badge/Codex-black?style=flat-square&logo=openai" alt="Codex">
  <img src="https://img.shields.io/badge/Gemini_CLI-black?style=flat-square&logo=google" alt="Gemini">
  <img src="https://img.shields.io/badge/OpenCode-black?style=flat-square" alt="OpenCode">
  <img src="https://img.shields.io/badge/Python_3.8+-yellow?style=flat-square" alt="Python">
  <img src="https://img.shields.io/badge/MIT-brightgreen?style=flat-square" alt="License">
</p>

<h1 align="center">Skill Monitor</h1>
<p align="center"><strong>AI Coding Agent 技能生态健康管理</strong></p>
<p align="center">你的 Agent 装了 200 个 Skill，但只有 30 个在工作。<br>安全扫描 / Token 成本审计 / 描述预算诊断 / Hook 冲突 / 使用追踪 — 225ms 全面洞察。</p>
<p align="center"><a href="https://luxuzhou.github.io/skill-monitor-plugin/">Landing Page</a> · <a href="#installation">安装</a> · <a href="#features">功能</a> · <a href="CHANGELOG.md">更新日志</a></p>

---

## The Problem

You install 5 plugins, get 200+ skills, and have **zero visibility** into what's happening:

- **74% of your token budget** goes to plugin description injection you can't see
- **50+ skill descriptions** get silently truncated, losing trigger keywords
- **Hook conflicts** between plugins cause duplicate processing on every tool call
- **Security patterns** like credential+network combos go undetected
- You don't know which skills you actually use vs. which are dead weight

## The Solution

```
/skill-monitor
```

```
  ┌─────────────────────────────────────────────────────┐
  │         Skill Monitor Dashboard                     │
  └─────────────────────────────────────────────────────┘

  SKILLS    120 total  (27 user / 93 plugin / 8 packages)

  SECURITY  (pattern scan: 120 skills)
  Score     86/100  █████████████████░░░
  Findings  0 critical  2 high  4 medium

  TOKEN COST  (all skill descriptions injected per conversation)
  Total     ~12507/conv  ████████████████████
    User skills:    ~3300 tok (27 skills)
    Plugin skills:  ~9207 tok (93 skills)

  BUDGET  (skill description budget: ~35K chars, 120 skills)
  Used      28,534/35,000 chars  ████████████████░░░░  (81%)
  Truncated  50 skills have desc >250c (losing ~9,531 chars of trigger keywords)

  Quality   120 skills  Critical - too many skills competing for attention

  HOOKS  (settings.json + skill-embedded)
  Hooks     8 total
  Conflicts 4
```

## Features

| Command | What it does |
|---------|-------------|
| `/skill-monitor` | Overview dashboard with all key metrics |
| `/skill-monitor security` | Pattern-based security scan (CRITICAL/HIGH/MEDIUM) |
| `/skill-monitor cost` | Token cost breakdown: user vs plugin, top 10 most expensive |
| `/skill-monitor budget` | Description budget vs 250-char truncation analysis |
| `/skill-monitor hooks` | Hook conflict detection across settings.json + skills |
| `/skill-monitor usage` | Skill invocation tracking (requires setup-tracking) |
| `/skill-monitor versions` | Plugin version staleness check |
| `/skill-monitor diff` | What changed since last snapshot |
| `/skill-monitor full` | Everything above in one report |

### LLM-Powered Analysis

| Command | What it does |
|---------|-------------|
| `/skill-monitor overlap` | Find user skills that duplicate plugin capabilities |
| `/skill-monitor profile` | Flag skills irrelevant to your tech stack |
| `/skill-monitor compress` | Shorten descriptions to preserve trigger keywords |
| `/skill-monitor project-config` | Generate project-specific skill whitelist |
| `/skill-monitor clusters` | Semantic grouping to find redundant skills |
| `/skill-monitor deep-audit` | Full LLM security audit with isolated subagents |

### Management

| Command | What it does |
|---------|-------------|
| `/skill-monitor disable <name>` | Disable a skill (reversible) |
| `/skill-monitor quarantine <name>` | Move skill to quarantine (recoverable) |
| `/skill-monitor restore <name>` | Restore disabled/quarantined skill |
| `/skill-monitor setup-tracking` | Install usage tracking hooks |

## Key Findings This Tool Surfaces

### 1. Your real token cost is 3x what you think

Most monitoring tools only count user skill descriptions. Plugin descriptions are invisible but injected every conversation. Skill Monitor counts **both** and shows the breakdown.

### 2. Descriptions get silently truncated at 250 chars

Claude Code caps each skill description at 250 characters when budget is tight. Trigger keywords after char 250 are lost. Skill Monitor shows which skills are affected and how many characters of trigger keywords are at risk.

### 3. Hook conflicts slow down every tool call

When multiple skills register hooks for the same matcher (e.g., both `guard` and `settings.json` hook into `Bash`), every tool call triggers multiple scripts. Skill Monitor detects these overlaps.

### 4. 220 skills is way too many

Community consensus: Claude handles 30 skills well, starts conflicting at 8-10 mixed skills. If you have 200+, Claude needs to choose from a crowded candidate pool, reducing matching accuracy.

## Installation

### Claude Code Plugin (推荐)

```bash
claude plugin add luxuzhou/skill-monitor-plugin
```

### Git Clone (适用所有平台)

```bash
git clone https://github.com/Luxuzhou/skill-monitor-plugin.git

# Claude Code / Codex / OpenCode
cp -r skill-monitor-plugin/skills/skill-monitor ~/.claude/skills/

# Gemini CLI
cp -r skill-monitor-plugin/skills/skill-monitor ~/.gemini/skills/

# Cursor
cp -r skill-monitor-plugin/skills/skill-monitor .cursor/skills/
```

> Skill Monitor 遵循 [Agent Skills](https://agentskills.io) 开放标准，兼容所有支持 SKILL.md 的 AI Coding Agent。

### Setup Usage Tracking (Optional)

After installation, enable skill invocation tracking:

```
/skill-monitor setup-tracking
```

This adds a `PreToolUse[Skill]` hook to `settings.json` that logs every explicit skill invocation.

## Performance

| Environment | Scan Time (220 skills) |
|-------------|:---------------------:|
| Python (any OS) | **~225ms** |
| Bash fallback (Linux/Mac) | ~5s |
| Bash fallback (Windows Git Bash) | ~150s |

The Python scanner runs a single-pass analysis: read all SKILL.md files once, extract descriptions, run security checks, analyze hooks, and render the dashboard. No subprocess spawning per file.

## Requirements

- **Claude Code** 2.0+
- **Python** 3.8+ (recommended, for fast scanner)
- Works without Python (falls back to bash, much slower on Windows)

## How It Works

Skill Monitor follows Claude Code's [progressive disclosure](https://code.claude.com/docs/en/skills) architecture:

1. **Description** (always loaded): Short summary for Claude to decide when to trigger
2. **SKILL.md** (loaded when triggered): Full instructions for dashboard commands
3. **scanner.py** (executed, not loaded): Fast Python scanner that reads all skills and outputs the dashboard

Script-based commands (`overview`, `security`, `cost`, `budget`, `hooks`, `usage`, `versions`, `diff`, `full`) run the Python scanner directly. LLM-powered commands (`overlap`, `profile`, `compress`, `project-config`, `clusters`, `deep-audit`) use Claude's reasoning to analyze skill descriptions semantically.

## Based On

- [Claude Code Skills Documentation](https://code.claude.com/docs/en/skills)
- [Skill Budget Research](https://gist.github.com/alexey-pelykh/faa3c304f731d6a962efc5fa2a43abe1)
- [Skill Invocation Tracking Feature Request](https://github.com/anthropics/claude-code/issues/35319)
- Community best practices from r/ClaudeCode and Claude Code Discord

## License

MIT - see [LICENSE](LICENSE)

## Author

[Lex Lu (luxuzhou)](https://github.com/luxuzhou) - R&D Lead, AI tooling enthusiast
