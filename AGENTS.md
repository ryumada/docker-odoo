---
title: AGENTS.md
category: Reference
description: Instructions AI agents to read and follow all .agents repository content
context: Root Repository
---

# Agent Instructions

## Required Protocol
1. **Identify Task Layer**: Determine if the task is **Infrastructure** (Docker, Bash) or **Application** (React, Next.js).
2. **Follow Standard Rules**: All active instructions reside in the `.agents/rules/` directory.

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
To optimize token usage and execution speed, use these tags to set the agent's behavior for the session:

* **@flash:** Act as a precise execution agent capable of localized deep reasoning. Before invoking any file editing tools, write out a brief step-by-step logical breakdown of your planned changes in standard text. **Do not use custom XML tags (like `<thinking>`) as they break the tool parser.** To protect context limits, restrict your reasoning strictly to the files currently in your context for the active phase. Enforce "Phased Execution" (do not write monolithic code), explicitly ask me to provide specific files from the REPO_MAP before you begin coding, and strictly enforce the project's 5-line File Signatures.

* **@pro:** Act as a deep-reasoning Senior Architect. Prioritize First Principles Thinking. You have full freedom to analyze the architecture maps and suggest high-level changes, but **you must NOT read individual source code files** unless explicitly requested. Output your system designs strictly to `implementation_plan.md`. **You are strictly forbidden from executing the implementation plan, modifying source code, or writing scripts unless I explicitly command you to "Execute with Pro."**

## References
- Lint command: `npm run lint`
- Type‑check command: `npm run typecheck`

*Centralizing rules in AGENTS.md reduces token usage by avoiding repeated inclusion of the same protocol text across multiple agents and tasks.*
