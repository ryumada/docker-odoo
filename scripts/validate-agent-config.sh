#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Validates AI agent configuration — checks triggers, token metadata, and stale references.
# Usage: ./scripts/validate-agent-config.sh
# Dependencies: git, grep, awk

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_REPO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)

# Colors
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"
COLOR_SUCCESS="\033[0;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[0;31m"

log()  { echo -e "${COLOR_INFO}[$(date +"%Y-%m-%d %H:%M:%S")]${COLOR_RESET} $1"; }
ok()   { echo -e "${COLOR_SUCCESS}[PASS]${COLOR_RESET} $1"; }
warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1"; }
fail() { echo -e "${COLOR_ERROR}[FAIL]${COLOR_RESET} $1"; failures=$((failures+1)); }

RULES_DIR="$PATH_TO_REPO/.agents/rules"
SKILLS_DIR="$PATH_TO_REPO/.agents/skills"
failures=0

log "=== always_on Rule Count ==="
always_on_count=$(grep -rl "trigger: always_on" "$RULES_DIR" 2>/dev/null | wc -l)
ok "always_on rules: $always_on_count (target: 5)"

log "=== model_decision Rule Count ==="
model_decision_count=$(grep -rl "trigger: model_decision" "$RULES_DIR" 2>/dev/null | wc -l)
ok "model_decision rules: $model_decision_count"

log "=== Token Metadata Check ==="
while IFS= read -r -d '' f; do
    basename "$f"
    if grep -q '^tokens:' "$f" 2>/dev/null; then
        tok=$(grep '^tokens:' "$f" | head -1 | awk '{print $2}')
        ok "  $f → $tok"
    else
        warn "  $f — missing tokens: metadata"
    fi
done < <(find "$RULES_DIR" -name '*.md' -type f -print0)
while IFS= read -r -d '' f; do
    basename "$f"
    if grep -q '^tokens:' "$f" 2>/dev/null; then
        tok=$(grep '^tokens:' "$f" | head -1 | awk '{print $2}')
        ok "  $f → $tok"
    else
        warn "  $f — missing tokens: metadata"
    fi
done < <(find "$SKILLS_DIR" -name 'SKILL.md' -type f -print0 2>/dev/null)
while IFS= read -r -d '' f; do
    basename "$f"
    if grep -q '^tokens:' "$f" 2>/dev/null; then
        tok=$(grep '^tokens:' "$f" | head -1 | awk '{print $2}')
        ok "  $f → $tok"
    else
        warn "  $f — missing tokens: metadata"
    fi
done < <(find "$RULES_DIR/references" -name '*.md' -type f -print0 2>/dev/null)

log "=== Stale Reference Check (AGENTS.md) ==="
FILES_REFERENCED=$(grep -oP '\.[a-zA-Z0-9_/.-]+\.md' "$RULES_DIR/../AGENTS.md" 2>/dev/null || true)
while IFS= read -r ref; do
    ref="${ref#./}"
    if [ -n "$ref" ] && [ ! -f "$PATH_TO_REPO/$ref" ]; then
        fail "AGENTS.md references '$ref' but file does not exist"
    fi
done <<< "$FILES_REFERENCED"

log "=== Trigger Metadata Check ==="
while IFS= read -r -d '' f; do
    if ! head -20 "$f" | grep -q '^trigger:' ; then
        warn "  $f — missing trigger: metadata"
    fi
done < <(find "$RULES_DIR" -name '*.md' -type f -print0)

log "=== always_on File Size Budget ==="
while IFS= read -r -d '' f; do
    size=$(wc -c < "$f")
    if [ "$size" -gt 500 ]; then
        warn "  $f — ${size}B (budget: 500B for always_on)"
    else
        ok "  $f — ${size}B"
    fi
done < <(grep -rl "trigger: always_on" "$RULES_DIR" --include='*.md' -print0 2>/dev/null)

log "=== Deleted Files Still Referenced ==="
DELETED_FILES="multi-model-pipeline.md cavecrew-builder.md cavecrew-investigator.md cavecrew-reviewer.md phased-execution.md require-plan-approval.md test-log-compression.md CLINE.md"
for df in $DELETED_FILES; do
    if grep -r "$df" "$RULES_DIR" "$SKILLS_DIR" "$PATH_TO_REPO/AGENTS.md" 2>/dev/null | grep -v '^.*:.*#' > /dev/null 2>&1; then
        fail "'$df' is deleted but still referenced in active files"
    fi
done

log "=== .clinerules / .kilocode Consistency ==="
if [ -f "$PATH_TO_REPO/.clinerules" ]; then
    if grep -q "canonical rule" "$PATH_TO_REPO/.clinerules"; then
        ok ".clinerules is a thin reference"
    else
        warn ".clinerules may contain duplicate content"
    fi
fi
if [ -f "$PATH_TO_REPO/.kilocode/rules/rtk-rules.md" ]; then
    if grep -q "canonical rule" "$PATH_TO_REPO/.kilocode/rules/rtk-rules.md"; then
        ok ".kilocode/rules/rtk-rules.md is a thin reference"
    else
        warn ".kilocode/rules/rtk-rules.md may contain duplicate content"
    fi
fi

log ""
if [ "$failures" -gt 0 ]; then
    echo -e "${COLOR_ERROR}${failures} check(s) FAILED.${COLOR_RESET}"
    exit 1
else
    echo -e "${COLOR_SUCCESS}All checks passed.${COLOR_RESET}"
fi
