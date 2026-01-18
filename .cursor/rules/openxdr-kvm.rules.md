# OpenXDR KVM Installer – Project Rules
# (Unified UX, Logging, Navigation, and Validation Standard)

This document defines the mandatory UX, logging, and operational standards
that ensure all installer scripts behave as a single, coherent product.

Applies to:
- DP-Installer.sh
- AIO-Sensor-Installer.sh
- Sensor-Installer.sh

---

## A. Common Framework Contract

### A-1. Base Paths (Immutable)
- BASE_DIR=/root/xdr-installer
- STATE_DIR=${BASE_DIR}/state
- CONFIG_FILE=${STATE_DIR}/xdr_install.conf
- STATE_FILE=${STATE_DIR}/xdr_install.state
- LOG_FILE=${STATE_DIR}/xdr_install.log
- These paths and filenames must not be changed.

### A-2. Common Safety Defaults
- `set -euo pipefail` must be preserved
- DRY_RUN default behavior must be preserved
- If whiptail is missing, exit with a clear error message

---

## B. STEP Execution UI Standard

### B-1. STEP START Screen
- Title: "<Installer Name> - Step <NN>: <STEP_NAME>"
- Body format:
  [ℹ️] STEP <NN> Start: <STEP_NAME>
  - Summary of actions (max 3 lines)
  - Impact scope (network / VM / disk / services)
  - Warnings or reboot notes (if applicable)

### B-2. STEP Result Screens
- DONE:
  [✅] STEP <NN> Completed: <STEP_NAME>
  - Result summary
  - Next action guidance
- FAILED:
  [❌] STEP <NN> Failed: <STEP_NAME>
  - Short cause summary
  - Log file reference
- CANCELED:
  [⏭️] STEP <NN> Canceled: <STEP_NAME>
  - Minimal-change notice
  - Return-to-menu notice

---

## C. Icon and Message Tone Standard

### C-1. Icon Set (Mandatory)
- Information: [ℹ️]
- Success: [✅]
- Failure: [❌]
- Warning: [⚠️]
- Canceled / Skipped: [⏭️]
- Confirmation / Question: [❓]

### C-2. Message Tone
- Operator-focused, neutral, and declarative
- No emotional or conversational language
- Use short, clear sentences:
  - "will be performed"
  - "is required"
  - "is recommended"

---

## D. Menu Navigation and Cancel / ESC Behavior

- Cancel / ESC always means **user cancellation**
- During STEP execution:
  - Cancel → STEP ends as CANCELED → return to main menu
- During STEP selection:
  - Cancel → return to main menu
- From main menu:
  - Cancel → show exit confirmation (yes/no)

STEP result states are strictly limited to:
- DONE
- FAILED
- CANCELED

State update rules:
- LAST_COMPLETED_STEP is updated only on DONE
- FAILED and CANCELED must not update LAST_COMPLETED_STEP

---

## E. Logging Format Standard

### E-1. STEP Banners
- START:
  [YYYY-mm-dd HH:MM:SS] ===== STEP START: <ID> - <NAME> =====
- DONE:
  [YYYY-mm-dd HH:MM:SS] ===== STEP DONE:  <ID> - <NAME> =====
- FAILED:
  [YYYY-mm-dd HH:MM:SS] ===== STEP FAILED: <ID> - <NAME> =====
- CANCELED:
  [YYYY-mm-dd HH:MM:SS] ===== STEP CANCELED: <ID> - <NAME> =====

### E-2. Command Execution Logging
- Before execution:
  [RUN] <command>
- On success:
  [RUN][OK] <command>
- On failure:
  [RUN][FAIL] <command> (rc=<n>)

---

## F. Full Configuration Validation Standard

### F-1. Screen Layout
- Title: "Full Configuration Validation"
- Result levels:
  - [OK]    Requirement satisfied
  - [WARN]  Warning / recommendation
  - [FAIL]  Blocking issue

### F-2. Summary Rules
- If one or more FAIL entries exist, deployment must not proceed
- Display total counts of OK / WARN / FAIL

### F-3. Common Validation Categories
- Files and paths: STATE_DIR, CONFIG_FILE, LOG_FILE
- Environment: libvirt availability and access
- Network: NAT / Bridge preconditions
- User input: format and value validation

Script-specific validation is allowed,
but output style and severity levels must remain identical.

## (Additional) Language Standard
- All UI, menu, validation, and log messages must be in English only.

