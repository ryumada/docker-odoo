---
title: Auto ICM Recall Rule
trigger: always_on
category: Safety
description: Automatically queries ICM context at the start of every session.
context: Session Lifecycle Management
---

# 📋 PROTOCOL: AUTO ICM RECALL ON START

**Objective**: Ensure the agent always retrieves context from ICM memory at the start of a session, preventing context loss.

## Rule

At the **beginning of every session**, before running other commands or modifications, you MUST:

1. Retrieve relevant context by running the ICM recall command on the active project/task:
   - Run: `rtk proxy icm recall-context "docker-odoo" --limit 5`
2. Integrate the recalled context into your current plan.
