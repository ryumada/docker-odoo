---
title: Session Pruning Rule
trigger: always_on
category: Safety
description: Monitors session length and prompts context reset.
context: Session Lifecycle Management
tokens: ~8
---

If conversation reaches 20 turns or 25 tool calls, warn the user, run `icm store -t context-docker-odoo -c "<current-state>" -i high`, and ask to start a new session.
