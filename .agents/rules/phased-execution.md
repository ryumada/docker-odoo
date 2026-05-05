---
trigger: model_decision
description: Use when the task involves 4+ files or crosses infrastructure and application layers. Guides phased execution to optimize token usage.
title: Phased Execution Strategy
category: Reference
context: All Layers
---

# Phased Execution Strategy

For **complex, multi-file tasks**, follow this phased approach:

1. **Plan Phase**: Outline all phases with scope and affected files. Do NOT read files yet.
2. **Execute Per Phase**: Load only the context (files, maps) needed for the current phase.
3. **Checkpoint**: After each phase, summarize what was done and ask to proceed.

## When to Phase

| Complexity | Action |
|---|---|
| Single file change | Execute directly, no phasing needed |
| 2-3 related files | Execute directly, but summarize at the end |
| 4+ files or cross-layer (infra + app) | **Must phase** |

## Rules

- Never read all REPO_MAP files at once. Read only the layer relevant to the current phase.
- Keep per-phase output focused. Avoid repeating unchanged code.
- Carry forward a **1-2 line summary** of prior phases, not raw content.
