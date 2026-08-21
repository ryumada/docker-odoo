---
title: LLM Token Optimization Guide
category: Guide
description: Documents the strategy and setup used to drastically reduce LLM token usage in this repository's Antigravity AI agent configuration.
context: Root Repository
---

# LLM Token Optimization Guide

This document explains the multi-layer strategy used to reduce token consumption when working with AI agents (Google Antigravity) in this repository.

## Overview

Token usage is reduced across multiple layers:

| Layer | Tool / Mechanism | Savings |
|---|---|---|
| Agent context compression | Rule trigger optimization | ~84% baseline reduction |
| Workspace search scoping | Scoped `.aiexclude` & `.ignore` | Prevents ingesting megabytes of upstream Odoo source |
| Code output minimalism | Ponytail + Cavecrew | Prevents token-heavy responses |
| Deployment token compression | Health probes + Odoo log filters | 95%+ reduction on deployment verification & upgrade logs |
| Persistent context sync | ICM (Interactive Context Memory) | Stops redundant explanation cycles |

---

## Layer 1: Agent Context Compression — Rule Trigger Optimization

The largest baseline saving. Antigravity injects `always_on` rules into every session regardless of task. By switching most rules to `model_decision`, those rules are only loaded when the agent determines the task requires them (e.g., the file-signature rule is only loaded when the agent is creating or editing files).

### Current Rule Triggers

| Rule File | Trigger | Est. Tokens | Purpose |
|---|---|---|---|
| `ponytail.md` | `always_on` | ~12 | Behavioral discipline + response budget |
| `do-not-answer-if-repo-map-file-not-found.md` | `always_on` | ~4 | Safety gate |
| `session-pruning.md` | `always_on` | ~8 | Context window limit |
| `auto-icm-recall.md` | `always_on` | ~6 | Cross-session memory |
| `cavecrew.md` | `model_decision` | ~65 | Merged builder/investigator/reviewer + phased execution |
| `file-signature-enforcement.md` | `model_decision` | ~40 | 5-line header enforcement |
| `how-to-scan-repository.md` | `model_decision` | ~12 | REPO_MAP navigation |
| `ponytail-ref.md` | `on_demand` | ~25 | Full ponytail guidelines |
| `agent-personas-ref.md` | `on_demand` | ~40 | @flash / @pro definitions |

---

## Layer 3: Workspace Search Scoping — `.aiexclude` & `.ignore`

**Files**: [`.aiexclude`](.aiexclude), [`.ignore`](.ignore)

Prevents AI agents and workspace indexing tools from ingesting hundreds of megabytes of upstream Odoo source (`odoo-base/`), database dumps (`*.sql`, `*.dump`, `*.tar*`), or `.mypy_cache`. Only operational configurations (`conf/`), scripts (`scripts/`, `utilities/`), deployments (`deployments/`), and custom modules (`git/`) are scanned.

---

## Layer 4: Output Minimalism — Ponytail & Cavecrew

These rules constrain *how much* the agent writes, reducing output tokens.

### Ponytail (Lazy Senior Dev Mode)

**Rule file**: [`.agents/rules/ponytail.md`](.agents/rules/ponytail.md)
**Trigger**: `always_on`

Enforces YAGNI-first thinking: Only write what is absolutely necessary, reuse standard utilities, write one-liners when functional, and avoid unrequested abstractions.

### Cavecrew Personas

Three specialized personas, each only loaded when relevant:

| Persona | File | Role |
|---|---|---|
| Builder | `cavecrew-builder.md` | Edits only — smallest diff, no narration, receipt output |
| Investigator | `cavecrew-investigator.md` | Locates symbols — no edits, no proposals, compact format |
| Reviewer | `cavecrew-reviewer.md` | Findings only — emoji severity tiers, no "looks good" |

---

## Layer 5: Deployment Token Compression & Zero-Token Health Probes

**Skill file**: [`.agents/skills/docker-odoo-management/SKILL.md`](.agents/skills/docker-odoo-management/SKILL.md)
**Utilities**: [`scripts/lib/filter_odoo_log.sh`](scripts/lib/filter_odoo_log.sh), [`scripts/lib/check_odoo_health.sh`](scripts/lib/check_odoo_health.sh)

1. **Zero-Token Deployment Probes**: Never run `docker compose logs` to check if a service deployed. Run:
   ```bash
   ./scripts/lib/check_odoo_health.sh
   ```
2. **Log Compression**: Filter routine `INFO` lines during container troubleshooting or module updates:
   ```bash
   docker compose logs --tail=100 odoo | ./scripts/lib/filter_odoo_log.sh -e
   ```
3. **Quiet Builds & Upgrades**: Use `-q` with Docker builds and `--log-level=warn --stop-after-init` with headless Odoo upgrades.

---

## Layer 6: Persistent Context Sync — ICM

ICM (Interactive Context Memory) persists important contextual updates across distinct sessions.

### When to Store Context (`icm store`)

You MUST call `icm store` when:
1. **Error resolved** → `icm store -t errors-resolved -c "description" -i high -k "keyword1,keyword2"`
2. **Architecture/design decision** → `icm store -t decisions-{project} -c "description" -i high`
3. **User preference discovered** → `icm store -t preferences -c "description" -i critical`
4. **Significant task completed** → `icm store -t context-{project} -c "summary of work done" -i high`

---

## Agent Personas

Defined in [`AGENTS.md`](AGENTS.md):

- **`@flash`** — Execution agent. Localized reasoning, phased execution, no monolithic code.
- **`@pro`** — Senior Architect. Reads only architecture maps. Outputs to `implementation_plan.md`. Never executes without explicit approval.
