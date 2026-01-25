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

## 8. Language Policy (English-only Output Contract)

### 8.1 Mandatory Language
- All user-facing text and engineering text must be written in **English**.
- This includes, but is not limited to:
  - whiptail UI titles and messages
  - menu labels
  - log messages (LOG_FILE output)
  - validation output (OK/WARN/FAIL lines and summaries)
  - inline error messages shown to the user
  - comments added to the code
  - documentation text added/updated under this repository
  - proposed commit messages, PR titles, and patch summaries

### 8.2 Non-Regression Constraint
- Existing English UI and log messages are part of the stability contract and must not be changed unless explicitly requested.
- Existing non-English strings must not be translated as a “cleanup” action.
  - Translation is allowed **only** when the user explicitly requests it.
  - Otherwise, the rule is: **do not change existing text; only ensure all newly introduced text is English.**

### 8.3 New Text Rule (Strict)
- Any newly introduced strings (UI/log/validation/error text) must be English only.
- Any newly introduced comments must be English only.
- Any newly introduced identifiers (function/variable names) must be English only.
- Do not mix languages in a single message or log line.

### 8.4 Commit Message Standard (English)
Whenever a commit message is proposed, it must be in English and follow this format:
- Subject line: `<type>(<scope>): <short summary>` (max 72 chars)
- Body (optional): bullet points describing behavior-preserving changes

Allowed `type` values:
- fix, feat, refactor, docs, chore, test

Example:
- `fix(sensor): return to main menu on auto-execute cancel`

## X. UI Layout and Sizing Policy (Allowed UX Adjustment)

### X.1 Fixed-Size UI Limitation Rule
- Hard-coded UI size limits (e.g., fixed height or width values)
  are allowed only when strictly required by terminal or tool limitations.
- When a UI element unnecessarily restricts usability due to fixed sizing,
  it is permitted to replace fixed dimensions with terminal-size-based
  dynamic sizing.

### X.2 Allowed Scope of Change
The following changes are explicitly allowed and do NOT require
contract revision, as long as behavior and messaging remain identical:
- Replacing fixed width/height values with values derived from terminal size
- Allowing UI components (e.g., textbox, message box) to expand within
  available terminal dimensions
- Improving readability without altering:
  - UI text content
  - Message tone
  - Log output
  - Control flow or user decisions

### X.3 Non-Regression Requirement
- UI layout changes must not:
  - Change existing UI text
  - Change menu options or ordering
  - Introduce new prompts
  - Alter Cancel / ESC semantics
- The only permitted effect is improved visibility or readability.

### X.4 Documentation Rule
- Such UI sizing changes must be documented in commit messages or patch notes
  as **layout or usability improvements**, not behavior changes.

