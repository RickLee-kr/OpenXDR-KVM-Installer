# Sensor-Installer.sh  
## Script-Specific Immutable Contract

This document defines the **exclusive, script-specific behavioral contract** for `Sensor-Installer.sh`.  
All future changes **must preserve the behaviors defined below** unless this contract itself is explicitly revised.

---

## 1. Script Purpose and Scope (Non-Overlapping)

- `Sensor-Installer.sh` is dedicated to **Sensor VM installation and host-side preparation**.
- It **does not deploy DL or DA**, and must never assume DP cluster topology logic.
- The script shares UI and framework patterns with other installers, but **execution logic remains independent**.

---

## 2. Execution Model (Menu-Driven, Step-Based)

### 2.1 Step-Oriented Architecture (Immutable)

- The script is composed of a **fixed, ordered list of STEP functions**.
- Each STEP:
  - Has a unique STEP ID
  - Is executed independently via `run_step`
  - Must be restartable without requiring earlier steps to re-run

No STEP is allowed to implicitly execute another STEP.

---

### 2.2 Main Menu Behavior (Immutable)

The main menu must always provide the following options:

1. Auto execute all steps (continue from next step based on state)
2. Select and run a specific step
3. Configuration (e.g. DRY_RUN)
4. Full configuration validation
5. Script usage guide
6. View log
7. Exit

**Behavioral rules:**
- `ESC` or `Cancel` returns to the menu (never exits the script).
- Exit always requires explicit confirmation.
- Menu layout dynamically adjusts to terminal size.

---

## 3. Auto Execution Logic

### 3.1 Auto-Continue from State

- Auto execution always starts from the **next incomplete STEP** based on the state file.
- Execution proceeds sequentially.
- If any STEP fails:
  - Auto execution stops immediately.
  - Control returns to the main menu.
  - No rollback is performed.

---

## 4. State and Configuration Persistence

### 4.1 State File Contract

- State tracks:
  - Last completed STEP
  - Last execution time
- State is updated **only after successful STEP completion**.
- Skipped steps (user choice) are treated as completed for state purposes.

### 4.2 Configuration File Contract

- Configuration values (e.g. DRY_RUN, NIC names, paths) are:
  - Loaded at menu entry
  - Saved explicitly via setter functions
- No STEP may silently overwrite configuration values.

---

## 5. User Interaction Rules (Immutable UX Contract)

### 5.1 Confirmation Model

- Every STEP that modifies system state must:
  - Show a **summary or inspection screen**
  - Require explicit user confirmation (`Yes/No`)
- Selecting `No`, `Cancel`, or `ESC`:
  - Cleanly aborts the STEP
  - Returns control to the menu
  - Does **not** mark the STEP as failed

---

### 5.2 Input Handling

- All user inputs are collected via `whiptail`.
- Missing critical values may prompt the user.
- If the user cancels input:
  - The STEP exits gracefully
  - No partial execution occurs

---

## 6. Logging Contract (Strict Format)

### 6.1 Log Message Format

All log entries must follow this structure:


- Logs are append-only.
- DRY_RUN actions must be explicitly labeled `[DRY-RUN]`.
- Log output is the **single source of truth** for troubleshooting.

---

## 7. DRY_RUN Semantics (Strict)

- DRY_RUN:
  - Prints commands
  - Shows summaries
  - Updates UI and state where applicable
- DRY_RUN must never:
  - Modify system state
  - Execute destructive commands
- DRY_RUN behavior must mirror real execution flow as closely as possible.

---

## 8. Validation Model (Full Configuration Validation)

### 8.1 Full Validation Characteristics

- Validation is **read-only**.
- Validation ignores DRY_RUN (always executes real checks).
- Validation:
  - Collects system state
  - Groups results into OK / WARN / ERROR
  - Presents output in paged, scrollable view

### 8.2 Validation Philosophy

- WARN ≠ failure
- ERROR indicates misalignment with installation guide
- Validation never modifies configuration or state

---

## 9. Network and VM Assumptions

- Sensor Installer assumes:
  - Host networking is already configured
  - Required bridges or interfaces exist
- The script may verify existence but **must not redesign topology**.
- NAT / bridge handling is verified, not invented.

---

## 10. Failure Handling Contract

- STEP failure:
  - Is reported via UI and log
  - Does not crash the installer
  - Allows user to re-run the STEP
- The script must never exit unexpectedly due to:
  - Command failure
  - Missing optional components

---

## 11. Anti-Regression Rules (Cursor Guardrails)

The following actions are strictly forbidden without contract revision:

- Merging STEP logic
- Converting menu-driven flow into linear execution
- Auto-skipping confirmations
- Replacing whiptail UI with plain CLI prompts
- Generalizing Sensor logic to match DP/AIO installers

---

## 12. Core Design Principle (Invariant)

> **The Sensor Installer prioritizes predictability and recoverability over automation.**  
> Every action must be visible, confirmable, and repeatable.

---

## 13. Enforcement Note

This contract is intentionally strict.  
Any change request must explicitly state:
- Which section(s) of this contract are affected
- Why the existing behavior is insufficient
- How backward compatibility is preserved

Unrequested refactoring or behavioral changes are prohibited.

