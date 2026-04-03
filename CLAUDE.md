# Skill Monitor Plugin

Skill health management for Claude Code. Scans all installed skills (user + plugin) for security risks, token cost, description budget, hook conflicts, and usage tracking.

## Quick Start

```
/skill-monitor          # Overview dashboard
/skill-monitor full     # Complete report
/skill-monitor budget   # Description budget analysis
/skill-monitor security # Security scan
/skill-monitor cost     # Token cost breakdown
/skill-monitor hooks    # Hook conflict detection
```

## Requirements

- Python 3.8+ (for fast scanner, falls back to bash if unavailable)
- Claude Code 2.0+
