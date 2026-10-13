---
title: Repo Map Verification Rule
trigger: model_decision
category: Safety
description: Ensures REPO_MAP.md exists before modifying or exploring repository files.
context: Repository Operations
tokens: ~6
---

When executing repository operations, code modifications, or scans: if you don't find any `REPO_MAP.md` file in the root repository, do not proceed and ask the user to run `scripts/generate_map.sh` first.

```bash
./scripts/generate_map.sh
```
