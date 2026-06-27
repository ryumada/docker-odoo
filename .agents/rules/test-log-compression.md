---
title: Test Log Compression Rule
trigger: model_decision
category: Reference
description: Filters test outputs and Docker logs to prevent chat buffer exhaustion.
context: Test Run Execution
---

# 📝 PROTOCOL: TEST LOG COMPRESSION (docker-odoo)

**Objective**: Prevent voluminous test logs or container build traces from filling the context window during execution.

## Rules

1. **Docker Builds**:
   - Always run docker builds with `--quiet` or pipe output to strip verbose step logs when checking for simple compilation success.
   - Example: `docker compose build --quiet` or pipe details through grep for errors only.

2. **Odoo Module Tests**:
   - When running Odoo unit tests, use filters to target specific modules (`--test-tags`) rather than running broad sweeps.
   - If tests fail, parse/report ONLY the traceback block (usually starting with `ERROR` or `Traceback (most recent call last):`) and the final failure count. Do NOT paste or read thousands of lines of Odoo initialization logs.
