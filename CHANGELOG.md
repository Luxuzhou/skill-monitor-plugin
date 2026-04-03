# Changelog

## 0.1.0 (2026-04-03)

### Features
- **Security scan**: Pattern-based detection (CRITICAL/HIGH/MEDIUM) across all skills
- **Token cost analysis**: Accurate cost for both user and plugin skills with breakdown
- **Description budget**: Budget utilization and quality assessment per official Claude Code spec
- **Hook conflict detection**: Finds duplicate matchers across settings.json and skill frontmatter
- **Usage tracking**: PreToolUse hook for Skill tool invocation logging
- **Plugin versions**: Staleness check for all installed plugins
- **Snapshot diff**: Track skill additions, removals, and changes over time
- **Skill management**: disable, quarantine, restore operations with audit logging
- **LLM-powered analysis**: overlap, profile, compress, project-config, clusters, deep-audit

### Performance
- Python scanner: ~225ms for full scan of 220+ skills (670x faster than bash on Windows)
- Bash fallback for environments without Python

### Bug Fixes
- Fixed description extraction for single-line YAML format (was missing 205/208 plugin descriptions)
- Fixed hook matcher case sensitivity (`"skill"` -> `"Skill"`)
- Fixed Windows GBK encoding issue in Python output
