# Bugfix Standard Playbook
## (Applies to All Installer Scripts)

This playbook defines the **mandatory procedure** for fixing bugs
in any installer script within this repository.

---

## 1. Mandatory Preconditions

Before making any code change:

- Apply all rules under `.cursor/rules/`
- Identify the exact script and STEP number affected
- Confirm that the issue is a **bug**, not a behavior change request

If the requested change alters existing behavior,
**stop and request contract revision first**.

---

## 2. Scope Control (Hard Rule)

- Modify **only** the STEP(s) directly related to the bug
- Do NOT:
  - Reformat code
  - Rename variables
  - Extract helpers
  - Touch unrelated STEPs
- Changes must be minimal and surgical

---

## 3. UI / Log Protection

- UI text must remain unchanged
- Log message format must remain unchanged
- New log lines may be added only if:
  - They are strictly necessary
  - They follow existing log format
  - They do not alter log order semantics

---

## 4. State and Config Safety

- Do not change:
  - State file structure
  - Config keys
  - Default values
- If a new config key is unavoidable:
  - Default must preserve existing behavior
  - Must be explicitly documented

---

## 5. Validation and Testing Checklist

After implementing the fix, verify:

- DRY_RUN=1 path behaves correctly
- Normal execution path behaves identically except for the fix
- Cancel / ESC behavior is unchanged
- Re-running the STEP is safe

---

## 6. Output Requirements

- Provide a **minimal diff**
- Clearly explain:
  - What was wrong
  - Why this fix is safe
  - Why no other behavior is affected

