---
trigger: always_on
description: Use at the start of every session to load the AGENTS.md file and follow its instructions.
---

# 📋 PROTOCOL: READ_AGENTS_MD_ON_START
**Objective:** Ensure the AGENTS.md file is read and followed at the start of every session.

## Rule
At the **beginning of every session**, you **MUST**:

1. **Read AGENTS.md**: Use `read_file` to load the `AGENTS.md` file from the project root.
2. **Follow Instructions**: Apply all instructions from AGENTS.md, including:
   - Identify the task layer (Infrastructure or Application)
   - Load targeted context from `.agents/rules/`
   - Follow standard rules from `.agents/rules/`
   - Apply the core checklist (5-Line Signatures, no browser testing, use `./scripts/bootstraping/run.sh` for npm commands, etc.)

## Why This Rule Exists
The AGENTS.md file contains critical instructions for how to operate in this repository. Without reading it at session start, the agent may not follow the required protocols, leading to inconsistent behavior and potential errors.

## Enforcement
- **If starting a new session:** Read AGENTS.md immediately.
- **If AGENTS.md is missing:** Ask the user to create it or provide instructions.
- **If AGENTS.md is outdated:** Follow the current version and notify the user if updates are needed.
