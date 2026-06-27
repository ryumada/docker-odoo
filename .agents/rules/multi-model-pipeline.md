---
title: Multi-Model Pipeline Rule
trigger: model_decision
category: Reference
description: Guides switching between Pro (planning) and Flash (execution) models to minimize API costs.
context: Architecture Design
---

# 🧠 PROTOCOL: MULTI-MODEL PIPELINE Handoff

**Objective**: Maximize efficiency by designing with expensive high-reasoning models (@pro) and executing with lightweight, cost-effective models (@flash).

## Handoff Flow

1. **The Plan Phase (@pro)**:
   - Use high-reasoning models (e.g., Gemini Pro, Claude Sonnet) to investigate, research, and create the `implementation_plan.md` and `tasks.md`.
   - The architect MUST stop and wait for approval once the files are written.

2. **The Execution Phase (@flash)**:
   - Once the user replies with "Approved", the user should switch the active model in the workspace to a faster/cheaper execution model (e.g., Gemini Flash).
   - Under this mode, the agent acts strictly as `@flash` (Execution Agent) to complete checklist items line-by-line using diff-based modifications.

3. **Self-Check**: If you detect that the user has switched the model to a Flash variant, immediately adopt the `@flash` persona constraints (localized reasoning, no monolithic output, 5-line headers).
