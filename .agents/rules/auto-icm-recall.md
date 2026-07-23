---
title: Auto ICM Recall Rule
trigger: always_on
category: Safety
description: Queries ICM context at session start.
context: Session Lifecycle Management
tokens: ~6
---

Run `rtk proxy icm recall-context "docker-odoo" --limit 5 || icm recall-context "docker-odoo" --limit 5` at session start and integrate recalled context.
