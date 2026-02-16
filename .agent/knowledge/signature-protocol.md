---
title: Semantic Indexing Protocol
category: Reference
description: Protocol for maintaining project visibility and low-token context density.
context: Project Root
---

# Semantic Indexing Protocol

This document defines the rules for maintaining project visibility and ensuring the AI can navigate the codebase with minimal token usage.

## 1. File Signatures
Every file in the repository **must** include a 5-line signature header.
- **Bash Scripts**: `#!`, `set -e`, `Category`, `Description`, `Usage`, `Dependencies`.
- **Node/TS/JS**: `@file`, `@category`, `@description`, `@requires`.
- **Markdown**: YAML frontmatter (`title`, `category`, `description`, `context`).

## 2. Directory Mapping (`REPO_MAP.md`)
- Generated via `scripts/generate_map.sh`.
- Captures the first 10 lines of every file.
- Supports "Russian Doll" nesting: directories with their own `REPO_MAP.md` are linked in the root map.

## 3. Dependency Graphing (`REPO_MAP_ARCHITECTURE.md`)
- Generated via `scripts/generate_app_tree.sh`.
- Uses `generate_tree.py` to map project orchestration and application logic.
- Represents internal dependencies and identifies orphaned components.

## 4. Compliance Auditing
- Verified via `scripts/check_compliance.sh`.
- Target: **100% compliance** across all git-tracked files.

---
*Last Updated: 2026-02-14*
