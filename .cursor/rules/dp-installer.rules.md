# DP-Installer.sh – Script-Specific Contract
# (Data Processor Host & DL/DA Deployment Installer)

This contract defines the immutable behavior, execution model, and user interaction
rules specific to DP-Installer.sh.

This script is considered production-stable.
All current logic, defaults, UI text, and operational flow are intentional.

---

## 1. Script Role and Scope (Immutable)

- DP-Installer.sh is the **host-level installer and orchestrator** for:
  - KVM host preparation
  - Network and NIC renaming (ifupdown-based)
  - Kernel and SR-IOV configuration
  - LVM storage provisioning
  - DL-master and DA-master VM deployment
  - DP Appliance CLI installation
- This script is **stateful**, **re-runnable**, and **menu-driven**.
- It must remain usable as a standalone installer without dependencies on
  Sensor installers.

---

## 2. STEP Model Contract (Immutable)

### 2.1 STEP Definition
- STEPs are defined by two parallel arrays:
  - STEP_IDS (internal identity, used for state tracking)
  - STEP_NAMES (display-only, shown to users)
- The order and meaning of STEP_IDS must never change.
- STEP indices are part of the persistent state contract.

### 2.2 STEP Execution Rules
- Each STEP is executed via `run_step <index>`.
- STEP completion state is recorded only when:
  - The STEP finishes successfully
  - `mark_step_done` is explicitly called
- A STEP that is skipped due to unmet prerequisites is **not a failure**.

### 2.3 Auto-Continue Semantics
- Auto execution always resumes from the **first incomplete STEP**.
- Auto execution must stop immediately if:
  - A STEP returns non-zero
  - A STEP is explicitly canceled by the user
- Canceling auto-continue is never treated as an error.

---

## 3. State and Config Contract (Strict)

### 3.1 State File
- STATE_FILE tracks:
  - LAST_COMPLETED_STEP
  - LAST_RUN_TIME
- These values must only be updated on successful STEP completion.
- FAILED or CANCELED STEPs must not update state.

### 3.2 Config File
- CONFIG_FILE is the authoritative source for:
  - DRY_RUN
  - DP_VERSION
  - ACPS credentials and URL
  - NIC selections (MGT_NIC, CLTR0_NIC)
  - Storage device lists
- All configuration edits must:
  - Be explicit
  - Be user-confirmed
  - Persist via save_config

---

## 4. DRY_RUN Contract (Non-Negotiable)

- DRY_RUN=1 means **no destructive or system-changing commands** are executed.
- In DRY_RUN mode:
  - Commands must be printed
  - UI confirmation must still be shown
  - STEP is still marked as DONE (simulation success)
- DRY_RUN logic must never be removed or bypassed.

---

## 5. Network & IP Semantics (Critical)

### 5.1 local-ip (--local-ip)
- --local-ip always represents the **host management (mgt) interface IP**.
- The value is determined by:
  1) Reading IPv4 address from MGT_NIC
  2) Prompting the user if auto-detection fails
- --local-ip must never be:
  - A NAT VM IP
  - A DL/DA internal IP
  - Auto-rewritten to 192.168.122.x

### 5.2 VM IP (--ip)
- --ip / --netmask / --gw configure **VM internal networking only**.
- Default model:
  - virbr0 NAT (192.168.122.0/24)
  - DL IP: 192.168.122.2
  - DA IP: 192.168.122.3
- This separation must be preserved at all times.

---

## 6. Deployment Script Resolution Contract

- virt_deploy_uvp_centos.sh resolution order is intentional:
  1) Path saved from STEP 09
  2) ${INSTALL_DIR}/images
  3) ${INSTALL_DIR}
  4) Current working directory
- This search order must not be altered.
- Absence of the script results in:
  - User-visible message
  - STEP being skipped, not failed

---

## 7. DP Image and --nodownload Logic (Step-Specific Contract)

### 7.1 STEP 09 – Image Source Selection and Download

STEP 09 is the **only step responsible for determining the source of the DP qcow2 image**.

Behavior contract:
- If a qcow2 image file larger than 1GB is found in the current directory:
  - The user must be prompted whether to use the existing qcow2 image.
- If the user chooses to use the existing qcow2 image:
  - qcow2 download from ACPS is skipped
  - Other required files (deployment scripts, metadata, etc.) are still downloaded
- If the user declines:
  - qcow2 and all related files are downloaded from ACPS

STEP 09 is the single decision point for qcow2 image sourcing.

---

### 7.2 STEP 10 and STEP 11 – Deployment Using Prepared Image

STEP 10 (DL deployment) and STEP 11 (DA deployment) **must never determine or change the DP image source**.

Behavior contract:
- qcow2 image is assumed to already exist as a result of STEP 09
- `--nodownload=true` is mandatory
- `--nodownload=false` must never be used in STEP 10 or STEP 11
- Any attempt to re-download the qcow2 image during deployment is forbidden

STEP 10 and STEP 11 are **image consumption stages**, not image acquisition stages.

---

### 7.3 Cross-Step Integrity Rule

- STEP 09 defines the DP qcow2 image source
- STEP 10 and STEP 11 must strictly consume that result without modification
- Cursor must never merge or generalize image download logic across these steps


---

## 8. User Confirmation Model

- Every destructive or provisioning STEP must include:
  - A full parameter summary
  - A yes/no confirmation dialog
- Canceling at confirmation:
  - Aborts the STEP
  - Returns to menu
  - Does not alter state

---

## 9. UI and Message Contract (DP-Specific)

- All STEP dialogs use:
  - Explicit STEP number and name
  - Neutral, operational tone
- Messages explain:
  - What will happen
  - Why a STEP is skipped
  - What the user should do next
- No conversational, emotional, or speculative language is allowed.

---

## 10. Logging Contract

- All significant actions are logged with:
  - Timestamp
  - STEP identifier
- Log messages are factual and descriptive.
- Logging order reflects actual execution order.
- Log content must never contradict UI messages.

---

## 11. Reboot Semantics

- Certain STEPs explicitly require reboot.
- Auto reboot behavior is controlled by:
  - ENABLE_AUTO_REBOOT
  - AUTO_REBOOT_AFTER_STEP_ID
- Reboot is intentional and part of the design.
- Post-reboot continuation via state is mandatory.

---

## 12. Validation Model

- Full Configuration Validation:
  - Is non-destructive
  - Aggregates system, VM, and configuration checks
- Validation output uses:
  - OK / WARN / FAIL severity levels
- FAIL blocks further deployment.

---

## 13. Modification Rules (Enforcement)

Any change to DP-Installer.sh must include:
- Explicit identification of affected STEP(s)
- Explanation of why existing behavior is preserved
- Confirmation that:
  - State format is unchanged
  - UI and log messages are unchanged unless explicitly requested
  - Default behavior remains identical

Unrequested refactoring or behavioral change is strictly forbidden.

