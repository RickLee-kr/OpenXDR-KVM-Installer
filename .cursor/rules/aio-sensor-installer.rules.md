# AIO-Sensor-Installer.sh  
## Script-Specific Immutable Contract

This document defines the **exclusive, script-specific behavioral contract**
for `AIO-Sensor-Installer.sh`.

This contract is written based on a full review of the current stable script.
All existing logic, execution flow, UI behavior, and defaults are intentional
and must be preserved unless this contract itself is explicitly revised.

---

## 1. Script Purpose and Scope (Immutable)

- `AIO-Sensor-Installer.sh` installs and deploys a **single All-In-One (AIO) Sensor VM**
  on a KVM host.
- The script:
  - Does **not** deploy DL or DA
  - Does **not** participate in DP cluster logic
  - Does **not** use SR-IOV, PCI passthrough, or CPU affinity
- The script shares a common UX and framework style with other installers,
  but its **deployment logic is standalone and self-contained**.

---

## 2. Execution Model (Menu-Driven, Step-Based)

### 2.1 STEP-Oriented Architecture

- The script consists of a **fixed, ordered list of STEP functions**.
- Each STEP:
  - Has a stable STEP ID
  - Has a human-readable STEP name
  - Can be executed independently
  - Can be re-run without requiring earlier STEPs

- STEPs must never:
  - Be reordered dynamically
  - Implicitly invoke other STEPs
  - Be merged or split without contract revision

---

### 2.2 Main Menu Behavior

The main menu provides the following options:

1. Auto execute all steps (resume from next incomplete STEP)
2. Select and execute a specific STEP
3. Configuration (e.g., DRY_RUN)
4. Full configuration validation
5. Usage guide
6. View log
7. Exit

**Menu rules:**
- Cancel / ESC always returns to the previous menu level
- Exiting the installer always requires explicit user confirmation
- No menu action may implicitly trigger STEP execution

---

## 3. Auto Execution Logic

### 3.1 State-Based Auto-Continue

- Auto execution always starts from the **first incomplete STEP**
  based on the persistent state file.
- STEPs execute sequentially.
- If any STEP fails or is canceled:
  - Auto execution stops immediately
  - Control returns to the main menu
  - No rollback is attempted

---

## 4. State and Configuration Contract

### 4.1 State File

- The state file records:
  - LAST_COMPLETED_STEP
  - LAST_RUN_TIME
- State is updated **only after successful STEP completion**.
- FAILED or CANCELED STEPs must not update state.

### 4.2 Configuration File

- Configuration values include (but are not limited to):
  - DRY_RUN
  - Network mode and interface names
  - Paths and image locations
- Configuration changes must:
  - Be explicitly initiated by the user
  - Be confirmed
  - Be persisted using the existing save mechanism

---

## 5. User Interaction Rules (Immutable UX)

### 5.1 Confirmation Model

- Any STEP that modifies system state must:
  - Present a clear summary of intended actions
  - Require explicit user confirmation (Yes / No)
- Selecting No, Cancel, or ESC:
  - Cleanly aborts the current STEP
  - Returns control to the menu
  - Does **not** mark the STEP as FAILED

---

### 5.2 Input Handling

- All user inputs are collected via `whiptail`.
- Missing or invalid values may trigger user prompts.
- Canceling input:
  - Aborts the STEP gracefully
  - Prevents partial execution

---

## 6. Logging Contract

### 6.1 Log Format

All log entries must follow this structure:


- Logs are append-only.
- Log messages are neutral and descriptive.
- UI icons or emojis must **not** appear in logs.
- DRY_RUN actions must be explicitly labeled.

---

## 7. DRY_RUN Semantics (Strict)

- DRY_RUN is a first-class safety mechanism.
- When DRY_RUN=1:
  - Commands are printed instead of executed
  - UI flow remains identical to real execution
  - No system state is modified
- DRY_RUN behavior must be consistent across all STEPs.

---

## 8. Image Handling and --nodownload Logic (AIO-Specific)

### 8.1 STEP 09 – Image Source Selection

STEP 09 is the **only step responsible for determining the AIO Sensor image source**.

Behavior contract:
- If a qcow2 image file of size **1GB or larger** exists in the current directory:
  - The user must be prompted whether to use the local image.
- If the user accepts:
  - qcow2 download is skipped
- If the user declines:
  - qcow2 image is downloaded from ACPS

Regardless of qcow2 choice:
- Other required files must always be downloaded.

---

### 8.2 Deployment STEPs (STEP 10 and Later)

- Deployment STEPs must assume that the image is already prepared.
- `--nodownload=true` is mandatory.
- Re-downloading qcow2 images during deployment is forbidden.
- No additional user prompt is allowed at this stage.

---

## 9. Network and IP Semantics

- Host management IP:
  - Is derived from the management interface
  - May be prompted if auto-detection fails
- NAT IP addresses:
  - Are VM-internal only
  - Must never be used as host or management identifiers

---

## 10. Validation Model

### 10.1 Full Configuration Validation

- Validation is strictly read-only.
- Validation ignores DRY_RUN.
- Validation checks include:
  - Required packages and services
  - Network prerequisites
  - Image availability
  - VM existence and status

### 10.2 Validation Output

- Results are categorized as:
  - OK
  - WARN
  - FAIL
- FAIL results block further deployment.
- Validation must not modify configuration or state.

---

## 11. UI and UX Consistency Requirement

- The visual style, tone, and navigation model must remain consistent with:
  - `DP-Installer.sh`
  - `Sensor-Installer.sh`
- A user familiar with one installer must be able to operate this script
  without additional explanation.

---

## 12. Forbidden Changes (Anti-Regression Rules)

The following changes are strictly forbidden unless this contract is revised:

- Introducing SR-IOV, PCI passthrough, or CPU affinity logic
- Changing STEP order or STEP meaning
- Altering Cancel / ESC semantics
- Automatically skipping confirmations or validations
- Silent logic changes for optimization or refactoring

---

## 13. Enforcement Clause

Any change to `AIO-Sensor-Installer.sh` must:
1. Reference this contract
2. Specify which section is affected
3. Demonstrate backward compatibility
4. Preserve existing user experience and defaults

If code and contract conflict, **this contract prevails**.

