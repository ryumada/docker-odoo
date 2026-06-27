---
title: Session Pruning Rule
trigger: always_on
category: Safety
description: Monitors tool calls/turns and prompts context reset to prevent context window bloat.
context: Session Lifecycle Management
---

# ⏱️ PROTOCOL: SESSION PRUNING & CONTEXT RESET

**Objective**: Prevent context window bloat by keeping chat histories short and highly focused. Long sessions cost exponential input tokens per turn and dilute model accuracy.

## Rule

1. **Track Session Length**: Monitor your current number of tool calls and conversation turns.
2. **Warn & Pause at Threshold**:
   - If the conversation reaches **20 turns** or **25 tool calls**, you **MUST** warn the user.
   - Output: *"⚠️ Session limit reached. To conserve tokens and keep reasoning sharp, let's reset our context."*
3. **Execute Reset Handoff**:
   - Summarize the active work done and any remaining tasks.
   - Run `icm store -t context-docker-odoo -c "<detailed-summary-of-current-state>" -i high`.
   - Ask the user to start a new chat session to continue from the saved ICM context.
