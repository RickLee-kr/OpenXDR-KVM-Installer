# Global Rules
# (Stability-first, Non-regression Contract)

These rules apply to all installer scripts in this repository.
The purpose is to treat the current stable behavior as the Single Source of Truth,
and to strictly prevent unintended changes to logic, UI, logging, or state handling
during future bug fixes or feature enhancements.

---

## 0. Prime Directive

- This codebase is a production-stable installer framework.
- Unless the user explicitly requests it, the following actions are strictly forbidden:
  - Refactoring logic or changing function structure
  - Reordering function or STEP execution
  - Simplifying or altering conditional branches
  - Changing default values
  - Modifying UI text (whiptail), menu labels, or log messages
  - Changing config/state file keys, structure, or paths
- "Cleanup", "generalization", or "readability improvement" is NOT a valid reason to change behavior.

---

## 1. Minimal Patch Discipline

- All changes must be **minimal and surgical**.
- Existing code must not be removed or rewritten.
- New behavior may only be introduced via:
  - A new configuration flag (default must preserve existing behavior)
  - A DP_VERSION gate
  - Explicit user confirmation (yes/no)
- Running the script with existing configurations must produce **identical behavior**.

---

## 2. UI and Logging Immutability

- The whiptail UI is a contract with the user.
- The following must remain unchanged:
  - Titles, message text, and menu option labels
  - Icon usage and formatting
  - Message tone (operator-focused, neutral, declarative)
- Cancel / ESC input represents **user cancellation**, not failure.
- Cancellation semantics must not be changed or treated as errors.

---

## 3. Safety and Re-runnability

- Every STEP must be idempotent and safe to re-run.
- Destructive operations must always include:
  - Clear warnings
  - Explicit user confirmation
  - DRY_RUN protection
- DRY_RUN is a first-class safety mechanism:
  - DRY_RUN=1 must never perform real system changes
  - DRY_RUN branches must never be removed

---

## 4. State and Config Contract

- State and config files are long-term compatibility contracts.
- The following actions are forbidden:
  - Changing file paths
  - Renaming or removing keys
  - Restructuring file formats
- When adding new keys:
  - Append only (never reorder or remove existing keys)
  - Use safe default values
  - Maintain full backward compatibility

---

## 5. Execution Model Preservation

- The script assumes `set -euo pipefail` and this assumption must remain valid.
- UI cancellation must never terminate the entire script.
- The meaning of return states (DONE / FAILED / CANCELED) must not change.

---

## 6. Mandatory Change Documentation

When modifying code, Cursor must explicitly provide:
- The exact functions or STEPs modified
- A clear before/after comparison
- An explanation of why existing stable behavior is not affected
- A list of any new or changed config/state/log entries

---

## 7. Enforced UX and Logging Consistency

- All installer scripts in this repository must share an identical UX and control model.
- Script-specific UX differentiation is strictly forbidden for:
  - STEP start/end messages
  - Log message formats
  - Full Validation screens
  - Menu navigation structure
  - Cancel / ESC behavior
- Any UX change must be applied uniformly across all scripts.

