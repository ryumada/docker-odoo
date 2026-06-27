---
title: LLM Token Optimization Guide
category: Guide
description: Documents the strategy and setup used to drastically reduce LLM token usage in this repository's Antigravity AI agent configuration.
context: Root Repository
---

# LLM Token Optimization Guide

This document explains the four-layer strategy used to reduce token consumption when working with AI agents (Google Antigravity) in this repository.

## Overview

Token usage is reduced at four distinct levels:

| Layer | Tool | Savings |
|---|---|---|
| CLI output compression | RTK (Rust Token Killer) | 60–90% per command |
| Agent context compression | Rule trigger optimization | ~84% baseline reduction |
| Code output minimalism | Ponytail + Cavecrew | Prevents token-heavy responses |
| Persistent context sync | ICM (Interactive Context Memory) | Stops redundant explanation cycles |

---

## Layer 1: CLI Output Compression — RTK

**Rule file**: [`.agents/rules/antigravity-rtk-rules.md`](.agents/rules/antigravity-rtk-rules.md)
**Trigger**: `always_on`

Every shell command is prefixed with `rtk` instead of running it raw. RTK acts as a filtering proxy that compresses command output before it reaches the LLM context window.

```bash
# Without RTK (verbose, expensive)
git status

# With RTK (compressed, cheap)
rtk git status
```

RTK meta commands:

```bash
rtk gain              # Show cumulative token savings
rtk gain --history    # Per-command savings history
rtk discover          # Find commands that missed RTK
rtk proxy <cmd>       # Bypass RTK for debugging
```

**Installation**: See [github.com/rtk-ai/rtk](https://github.com/rtk-ai/rtk)

---

## Layer 2: Agent Context Compression — Rule Trigger Optimization

The largest baseline saving. Antigravity injects `always_on` rules into every session regardless of task. By switching most rules to `model_decision`, those rules are only loaded when the agent determines the task requires them (e.g., the file-signature rule is only loaded when the agent is creating or editing files).

### Before vs. After

| State | `always_on` rules | Lines injected per session |
|---|---|---|
| Before | 8 files | ~370 lines |
| After | 3 files | ~20 lines |
| **Reduction** | | **~94%** (further reduced by referenced ponytail instructions) |

### Current Rule Triggers

| Rule File | Trigger | Reason |
|---|---|---|
| `antigravity-rtk-rules.md` | `always_on` | RTK habit must be unconditional |
| `ponytail.md` | `always_on` | Core behavioral discipline — slim header referencing full file |
| `do-not-answer-if-repo-map-file-not-found.md` | `always_on` | Critical safety gate, only 10 lines |
| `session-pruning.md` | `always_on` | Monitors session length to trigger context reset warnings |
| `auto-icm-recall.md` | `always_on` | Automatically queries ICM context at the start of every session |
| `cavecrew-builder.md` | `model_decision` | Only needed during file editing tasks |
| `cavecrew-investigator.md` | `model_decision` | Only needed during code investigation (Search-First) |
| `cavecrew-reviewer.md` | `model_decision` | Only needed during code reviews |
| `file-signature-enforcement.md` | `model_decision` | Only needed when creating/editing files |
| `how-to-scan-repository.md` | `model_decision` | Only needed for multi-file repo tasks |
| `require-plan-approval.md` | `model_decision` | Only needed during `@pro` planning sessions |
| `phased-execution.md` | `model_decision` | Only needed for 4+ file cross-layer tasks |
| `test-log-compression.md` | `model_decision` | Compresses verbose Docker logs and Odoo test traces |
| `multi-model-pipeline.md` | `model_decision` | Guides switching between Pro planning and Flash execution |

### Rule References (Loaded on demand only)

*   [`ponytail-ref.md`](.agents/rules/references/ponytail-ref.md): Fully expanded guidelines for minimalist code implementation.

### Deleted Redundant Rules

| File | Reason Deleted |
|---|---|
| `read-agents-md-on-start.md` | AGENTS.md is already auto-injected by the rule system; this caused a double-load on every session |

---

## Layer 3: Output Minimalism — Ponytail & Cavecrew

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

All three use **caveman-ultra** output style: drop articles/filler, lead with the answer, code/paths always backticked.

---

## Layer 4: Persistent Context Sync — ICM

ICM (Interactive Context Memory) persists important contextual updates across distinct sessions, ensuring agents do not forget project architecture, preferences, or critical error details.

### When to Store Context (`icm store`)

You MUST call `icm store` when:
1. **Error resolved** → `icm store -t errors-resolved -c "description" -i high -k "keyword1,keyword2"`
2. **Architecture/design decision** → `icm store -t decisions-{project} -c "description" -i high`
3. **User preference discovered** → `icm store -t preferences -c "description" -i critical`
4. **Significant task completed** → `icm store -t context-{project} -c "summary of work done" -i high`

### Querying and Recalling Context

Agents start sessions by loading context dynamically:
```bash
icm recall "query"                        # search memories
icm recall "query" -t "topic-name"        # filter by topic
icm recall-context "query" --limit 5      # inject into agent context
```

---

## Agent Personas

Defined in [`AGENTS.md`](AGENTS.md), these session tags further control token usage:

- **`@flash`** — Execution agent. Localized reasoning, phased execution, no monolithic code.
- **`@pro`** — Senior Architect. Reads only architecture maps (not source files). Outputs to `implementation_plan.md`. Never executes until explicitly commanded.

---

## Summary: How the Four Layers Stack

```
Session Start
│
├── Layer 2 & 4: Only 3 slim always-on rules loaded. Dynamic ICM context injection.
│
├── User types a command
│   └── Layer 1: RTK compresses shell output (60-90% savings per command)
│
├── Agent needs to edit/review code
│   ├── Layer 2: model_decision rules load (only what's needed)
│   └── Layer 3: Ponytail + Cavecrew keep output minimal
│
└── Net result: drastically fewer input + output tokens per task
```
