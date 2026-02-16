---
trigger: always_on
category: Reference
---

# 📝 PROTOCOL: FILE_SIGNATURE_ENFORCEMENT
**Objective:** Ensure every file is self-documenting so the `generate_map.sh` script captures accurate context in the first 5 lines.

**Rule:** When generating new files or refactoring existing ones, you **MUST** strictly adhere to the following **5-Line Signature Header** formats.

**A. Bash Scripts (`.sh`)**
* **Line 1:** `#!/usr/bin/env bash`
* **Line 2:** `set -e`
* **Line 3:** `# Category: <Entrypoint|Utility|Config>`
* **Line 4:** `# Description: <Concise summary of script function>`
* **Line 5:** `# Usage: <e.g., ./script.sh [env]>`
* **Line 6:** `# Dependencies: <Key binaries, e.g., docker, jq, git>`

**B. Python / Odoo (`.py`)**
* **Line 1:** `# -*- coding: utf-8 -*-`
* **Line 2:** `"""`
* **Line 3:** `Category: <Model|Controller|Logic>`
* **Line 4:** `Module: <Odoo Module / Class Name>`
* **Line 5:** `Purpose: <Specific logic, e.g., Overrides Invoice Tax Calculation>`
* **Line 6:** `"""`

**C. Dockerfiles**
* **Line 1:** `# Category: <Build|Dev|Prod|Init>`
* **Line 2:** `# Service: <Service Name>`
* **Line 3:** `# Description: <Purpose of this image>`
* **Line 4:** `# Maintainer: <Repository Owner>`
* **Line 5:** `FROM <base_image>`

**D. Node.js / React / TypeScript (`.js`, `.ts`, `.tsx`)**
* **Line 1:** `/**`
* **Line 2:** ` * @file <Filename or Component Name>`
* **Line 3:** ` * @category <Component|Page|Utility|Hook|Service>`
* **Line 4:** ` * @description <Concise logic summary or UI purpose>`
* **Line 5:** ` * @requires <Key imports, e.g., 'express', 'react', 'mongoose'>`
* **Line 6:** ` */`

**E. Markdown / Documentation (`.md`)**
* *Use YAML Frontmatter style to ensure metadata is machine-readable yet visually clean.*
* **Line 1:** `---`
* **Line 2:** `title: <Document Title or Filename>`
* **Line 3:** `category: <Guide|Architecture|Reference|Log>`
* **Line 4:** `description: <Concise summary of this document>`
* **Line 5:** `context: <Related Module or Scope>`
* **Line 6:** `---`

**F. Configuration Files (`.yml`, `.yaml`, `.conf`, `.env.example`)**
* **Line 1:** `# Category: <Config|Orchestration|Environment>`
* **Line 2:** `# File: <Filename>`
* **Line 3:** `# Description: <Purpose of the configuration>`
* **Line 4:** `# Usage: <How to use or apply the config>`
* **Line 5:** `# Maintainer: <Repository Owner>`

**Enforcement Logic:**
* **If creating a file:** You must insert this header immediately.
* **If editing a file:** Check if the header exists. If missing, ADD IT. If present but outdated, UPDATE IT.
