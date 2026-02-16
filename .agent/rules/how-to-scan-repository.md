---
trigger: always_on
category: Reference
---

# 🗺️ PROTOCOL: REPO_MAP_FIRST (Multi-Layer Context)
**Objective:** Eliminate hallucinations by grounding project knowledge in the generated map files, respecting both Infrastructure and Application layers.

1.  **Mandatory Context Loading (Recursive):**
    -   **Step 1 (Physical / Layout):** Before answering, you **MUST** first read `REPO_MAP.md` in the project root. This is your source of truth for deployment tools and environment configs.
    -   **Step 2 (Structural / Infrastructure):** You **MUST** read `REPO_MAP_ARCHITECTURE.md` to understand script orchestration and infrastructure design.
    -   **Step 3 (App / Logic):** You **MUST** check `REPO_MAP_APP_ARCHITECTURE.md` to understand component hierarchies and data flows in the `app/` directory.
    -   **Step 4 (Nested Maps):** If `REPO_MAP.md` lists a nested `app/REPO_MAP.md`, read it for granular application-layer file signatures.
    -   **Step 5 (Synthesis):** Merge all discovered maps and architecture trees into a single mental model.

2.  **Navigation Strategy:**
    -   **Do not** ask "What files are in this repo?" or "Can you list the modules?"
    -   **Do not** execute `ls -R` or `find .` to explore.
    -   Derive file existence and paths strictly from the `## Directory Structure` sections of **ALL** discovered `REPO_MAP.md` files.

3.  **Contextual Understanding:**
    -   **For Scripts/Ops:** Consult the `## File Signatures` in the **Root Map** to understand deployment logic (Docker, Bash).
    -   **For App Logic:** Consult the `## File Signatures` in the **Nested App Map** to understand business logic (Models, Controllers, Components).
    -   **Blind Spot Rule:** If a file is NOT listed in any `REPO_MAP.md`, assume it is git-ignored (like secrets or `node_modules`) and treat it as non-existent unless explicitly provided.
