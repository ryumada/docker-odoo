---
title: RTK Rules
trigger: always_on
category: Reference
description: Always prefix shell commands with rtk to compress LLM context output.
context: Environment & Shell Commands
tokens: ~8
---

# RTK - Rust Token Killer

**Rule**: Always prefix shell commands with `rtk` (e.g., `rtk git status`, `rtk docker ps`) to compress LLM context output (saves 60-90% tokens).

## Meta
- `rtk gain` / `rtk gain --history` (analytics)
- `rtk discover` (find missed opportunities)
- `rtk proxy <cmd>` (bypass filtering)
