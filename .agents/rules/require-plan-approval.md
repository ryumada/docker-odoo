---
title: require-plan-approval
trigger: always_on
category: Guide
description: Mandatory rules for investigating, structuring, and getting approval for implementation plans and task checklists.
context: Agent Planning Phase
---

# 🛑 PROTOCOL: STRATEGIC PLANNING & APPROVAL

You must **never** execute code changes or edit repository files without explicit permission. When tasked with creating an implementation plan under the `@pro` persona, you must follow this strict investigation and structuring protocol.

## Step 1: Proactive Investigation (No Assumptions)
Before writing the plan, you MUST verify how the existing system works.
1. Identify the core components involved.
2. Read the specific files handling the logic to ensure your plan will work end-to-end.
3. Explicitly state in your thoughts: *"Let me check how the [Component] handles [Action] to make sure the flow will work end-to-end."*

## Step 2: The Implementation Plan (`implementation_plan.md`)
Output an `implementation_plan.md` file that strictly follows this structure:
1. **Problem Summary / Objective**: A concise explanation of the issue or feature.
2. **Root Cause Analysis / Architectural Strategy**: A deep dive into *why* the bug exists or *how* the new architecture integrates.
3. **Proposed Changes**: Broken down by component.
4. **Files to Modify**: A Markdown table listing the `File` and a brief `Change` description.
5. **User Flows**: Outline the step-by-step user experience.
6. **Open Questions & Decisions**: Highlight any edge cases requiring the user's explicit agreement.

## Step 3: Actionable Task Generation (`tasks.md`)
Alongside the plan, you MUST generate a `tasks.md` file. This file acts as the strict execution blueprint for the Flash model. It must follow this exact format:
1. **Header**: Reference the implementation plan.
2. **Component/File Grouping**: Group tasks under `## Component Name` and specify the `File: path/to/file` below the header.
3. **Granular Checkboxes**: Use strictly numbered checkboxes (e.g., `- [ ] **1.1**`, `- [ ] **1.2**`).
4. **Logic Constraints**: Define exactly what to import, what state to add, and what logic to replace.
5. **Rule Reminders**: Always include a checkbox to "Preserve the 5-line file signature at the top of the file."
6. **Verification Section**: End with a `## Verification` block containing exact shell commands (e.g., `./scripts/bootstraping/run.sh npm run typecheck` and `lint`) for the execution agent to run.

## Step 4: Stop and Wait
Once `implementation_plan.md` and `tasks.md` are generated, you must STOP.
* Ask the user: "Please review the plan and the open questions. Reply with 'Approved' so we can begin execution."
* Do not transition to code editing until explicit human approval is granted.
