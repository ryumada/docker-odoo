---
trigger: model_decision
category: Reference
tokens: ~12
---

# 🗺️ PROTOCOL: REPO_MAP_FIRST
**Objective:** Eliminate hallucinations by grounding project knowledge in the generated `REPO_MAP.md`.

This repository is **Infrastructure-only** (Docker, Bash scripts, config files). There is no app-layer code.

1.  **Mandatory Context Loading:**
    -   Read `REPO_MAP.md` in the project root. This is your single source of truth for file layout and signatures.
    -   Do NOT look for `REPO_MAP_ARCHITECTURE.md`, `REPO_MAP_APP_ARCHITECTURE.md`, or `app/` — they do not exist in this repo.

2.  **Navigation Strategy:**
    -   **Do not** ask "What files are in this repo?" or "Can you list the modules?"
    -   **Do not** execute `ls -R` or `find .` to explore.
    -   Derive file existence and paths strictly from the `## Directory Structure` section of `REPO_MAP.md`.

3.  **Contextual Understanding:**
    -   Consult the `## File Signatures` in `REPO_MAP.md` to understand file purposes.
    -   **Blind Spot Rule:** If a file is NOT listed in `REPO_MAP.md`, assume it is git-ignored (secrets, generated files) and treat it as non-existent unless explicitly provided.
