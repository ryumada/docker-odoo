---
title: Auto ICM Recall Rule
trigger: model_decision
category: Safety
description: Queries ICM context at session start.
context: Session Lifecycle Management
tokens: ~6
---

Run `icm recall-context "docker-odoo" --limit 5` outside sandbox (`BypassSandbox: true` since `icm` is installed on host) at session start and integrate recalled context.
