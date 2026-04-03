# Capability Clustering Guide

## Purpose

With 100+ skills installed, many overlap in functionality. Clustering identifies
redundancies so users can trim their skill set, reducing token cost and
trigger conflicts.

## Algorithm

Do NOT use hardcoded cluster lists. Discover clusters dynamically.

### Step 1: Collect
Read all skill descriptions from the metadata/description field.

### Step 2: Group
Group skills by functional overlap:
- Same keywords in description (e.g., "git", "commit", "review")
- Similar trigger phrases
- Same domain (git operations, testing, security, design, documentation, etc.)
- Overlapping allowed-tools footprint

### Step 3: Compare
For each cluster with 2+ skills, build a comparison matrix:

| Dimension | How to measure |
|-----------|---------------|
| Size | SKILL.md file size in bytes |
| Usage count | From usage logs (0 if untracked) |
| Security score | From Phase 2 or quick scan |
| Unique capability | What does this skill do that others in the cluster don't? |
| Source | User skill vs plugin (plugins auto-update, user skills don't) |

### Step 4: Recommend
For each cluster:
- **Keep**: best combination of usage + security + unique capability
- **Review**: overlapping but with some unique value worth evaluating
- **Remove candidate**: unused, redundant, or risky

### Step 5: Confirm
Present each cluster to the user with options:
- Keep all — no changes
- Keep recommended — disable/remove the rest
- Custom selection — user picks
- Skip — decide later

### Output
Cleanup summary with:
- Number of skills that could be removed/disabled
- Estimated token savings per conversation
- Estimated monthly token savings
