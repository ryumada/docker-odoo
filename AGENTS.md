---
title: AGENTS.md
category: Reference
description: Instructions AI agents to read and follow all .agents repository content
context: Root Repository
---

# Agent Instructions

## Required Protocol
1. **Follow Standard Rules**: All active instructions reside in the `.agents/rules/` directory.

## Core Checklist
- 5-Line Signatures mandatory for all files.
- No browser testing (use logs and build status).

## Example
```yaml
Task(
  description="Load rule",
  prompt="/load .agents/rules/how-to-scan-repository.md",
  subagent_type="explore"
)
```

## Agent Personas (Routing)
Use these tags to set the agent's behavior. Full definitions: [`.agents/rules/references/agent-personas-ref.md`](.agents/rules/references/agent-personas-ref.md).

* **@flash:** Execution agent — phased, localized reasoning, enforces 5-line signatures.
* **@pro:** Senior Architect — reads maps only, outputs to `implementation_plan.md`, never executes without explicit command.

*Centralizing rules in AGENTS.md reduces token usage by avoiding repeated inclusion of the same protocol text across multiple agents and tasks.*
