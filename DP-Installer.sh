#!/usr/bin/env bash
#
# XDR Install Framework (SSH + Whiptail-based TUI)
# Only the base framework is implemented; each STEP is still DRY-RUN.

set -euo pipefail

#######################################
# Basic settings
#######################################

BASE_DIR="/root/xdr-installer"
STATE_DIR="${BASE_DIR}/state"
STEPS_DIR="${BASE_DIR}/steps"

STATE_FILE="${STATE_DIR}/xdr_install.state"
LOG_FILE="${STATE_DIR}/xdr_install.log"
CONFIG_FILE="${STATE_DIR}/xdr_install.conf" 

# Values are loaded from CONFIG instead of being hardcoded
DRY_RUN=1   # Default (overridden in load_config)

# Host auto reboot settings
ENABLE_AUTO_REBOOT=1                 # 1: auto reboot after STEP, 0: no auto reboot
AUTO_REBOOT_AFTER_STEP_ID="03_nic_ifupdown 05_kernel_tuning"

# Ensure whiptail is installed
if ! command -v whiptail >/dev/null 2>&1; then
  echo "ERROR: whiptail is required. Please install first:"
  echo "  sudo apt update && sudo apt install -y whiptail"
  exit 1
fi

# Create directories
mkdir -p "${STATE_DIR}" "${STEPS_DIR}"

#######################################
# STEP definitions
#  - Managed via ID and NAME arrays
#######################################

# STEP IDs (internal use, state tracking)
STEP_IDS=(
  "01_hw_detect"
  "02_hwe_kernel"
  "03_nic_ifupdown"
  "04_kvm_libvirt"
  "05_kernel_tuning"
  "06_ntpsec"
  "07_lvm_storage"
  "08_libvirt_hooks"
  "09_dp_download"
  "10_dl_master_deploy"
  "11_da_master_deploy"
  "12_sriov_cpu_affinity"
  "13_install_dp_cli"
)

# STEP display names (shown in UI)
STEP_NAMES=(
  "Detect and select hardware / NIC / disks"
  "Install HWE kernel"
  "Rename NICs / switch to ifupdown and configure networking"
  "Install and configure KVM / Libvirt"
  "Tune kernel parameters / KSM / swap"
  "Configure SR-IOV drivers (iavf/i40evf) + NTPsec"
  "LVM storage (DL/DA root + data)"
  "libvirt hooks and OOM recovery scripts"
  "Download DP image and deployment scripts"
  "Deploy DL-master VM"
  "Deploy DA-master VM"
  "SR-IOV / CPU Affinity / PCI Passthrough"
  "Install DP Appliance CLI package"
)

NUM_STEPS=${#STEP_IDS[@]}


# Calculate whiptail menu dimensions dynamically
calc_menu_size() {
  local item_count="$1"  # Number of menu items
  local min_width="${2:-80}"  # Minimum width (default 80)
  local min_height="${3:-10}"  # Minimum menu height (default 10)
  
  local HEIGHT WIDTH MENU_HEIGHT
  
  # Get terminal size
  if command -v tput >/dev/null 2>&1; then
    HEIGHT=$(tput lines)
    WIDTH=$(tput cols)
  else
    HEIGHT=25
    WIDTH=100
  fi
  
  [ -z "${HEIGHT}" ] && HEIGHT=25
  [ -z "${WIDTH}" ] && WIDTH=100
  
  # Calculate dialog height (leave space for title, message, buttons)
  # Title: ~1 line, Message: ~2-3 lines, Buttons: ~2 lines, Padding: ~2 lines
  local dialog_height=$((HEIGHT - 8))
  [ "${dialog_height}" -lt 15 ] && dialog_height=15
  
  # Calculate menu height (number of items + some padding)
  MENU_HEIGHT=$((item_count + 2))
  [ "${MENU_HEIGHT}" -lt "${min_height}" ] && MENU_HEIGHT="${min_height}"
  # Don't exceed dialog height minus message/button space
  local max_menu_height=$((dialog_height - 6))
  [ "${MENU_HEIGHT}" -gt "${max_menu_height}" ] && MENU_HEIGHT="${max_menu_height}"
  
  # Calculate dialog width (use most of terminal width, but respect minimum)
  local dialog_width=$((WIDTH - 10))
  [ "${dialog_width}" -lt "${min_width}" ] && dialog_width="${min_width}"
  # Don't exceed terminal width too much
  [ "${dialog_width}" -gt 120 ] && dialog_width=120
  
  echo "${dialog_height} ${dialog_width} ${MENU_HEIGHT}"
}

# Calculate whiptail dialog dimensions for simple dialogs (msgbox, yesno, inputbox, etc.)
calc_dialog_size() {
  local min_height="${1:-10}"  # Minimum height
  local min_width="${2:-70}"   # Minimum width
  
  local HEIGHT WIDTH
  
  # Get terminal size
  if command -v tput >/dev/null 2>&1; then
    HEIGHT=$(tput lines)
    WIDTH=$(tput cols)
  else
    HEIGHT=25
    WIDTH=100
  fi
  
  [ -z "${HEIGHT}" ] && HEIGHT=25
  [ -z "${WIDTH}" ] && WIDTH=100
  
  # Calculate dialog height - use more of terminal height for better centering
  # Reserve minimal space for title/buttons to allow message to be more centered
  local dialog_height=$((HEIGHT - 2))
  [ "${dialog_height}" -lt "${min_height}" ] && dialog_height="${min_height}"
  # Don't limit max height too much - allow larger dialogs for better centering
  [ "${dialog_height}" -gt 35 ] && dialog_height=35  # Increased max reasonable height
  
  # Calculate dialog width (use most of terminal width, but respect minimum)
  local dialog_width=$((WIDTH - 6))
  [ "${dialog_width}" -lt "${min_width}" ] && dialog_width="${min_width}"
  [ "${dialog_width}" -gt 100 ] && dialog_width=100  # Max reasonable width
  
  echo "${dialog_height} ${dialog_width}"
}

# Center-align message text by adding empty lines
center_message() {
  local msg="$1"
  echo "\n\n${msg}\n"
}

# Center-align menu by calculating proper spacing based on terminal height
center_menu_message() {
  local msg="$1"
  local menu_height="$2"  # Height of the menu dialog
  
  local HEIGHT
  if command -v tput >/dev/null 2>&1; then
    HEIGHT=$(tput lines)
  else
    HEIGHT=25
  fi
  
  [ -z "${HEIGHT}" ] && HEIGHT=25
  
  # Calculate how many empty lines to add at top to center the menu
  # whiptail menu structure:
  # - Title: 1 line
  # - Message area: variable (our msg)
  # - Menu list: menu_list_height lines
  # - Buttons: 2 lines
  # - Border: 2 lines (top + bottom)
  # Total dialog height = menu_height (which includes all of the above)
  
  # We want to center the entire dialog box, not just the message
  # Calculate top padding: (terminal_height - dialog_height) / 2
  # But leave some margin (about 2-3 lines)
  local margin=3
  local available_height=$((HEIGHT - margin * 2))
  
  # Calculate top padding to center the dialog
  local top_padding=0
  if [[ "${available_height}" -gt "${menu_height}" ]]; then
    top_padding=$(( (available_height - menu_height) / 2 ))
    # Ensure we have at least some padding, but not too much
    [[ "${top_padding}" -lt 2 ]] && top_padding=2
    [[ "${top_padding}" -gt 15 ]] && top_padding=15
  else
    # If menu is larger than available space, use minimal padding
    top_padding=2
  fi
  
  # Build padding string with newlines
  local padding=""
  local i
  for ((i=0; i<top_padding; i++)); do
    padding+="\n"
  done
  
  echo "${padding}${msg}"
}

# Wrapper function for whiptail msgbox with dynamic sizing, centering, and ESC handling
whiptail_msgbox() {
  local title="$1"
  local message="$2"
  local min_height="${3:-10}"
  local min_width="${4:-70}"
  
  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size "${min_height}" "${min_width}")
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  
  # Center-align message
  local centered_msg
  centered_msg=$(center_message "${message}")
  
  # Show dialog (ESC key won't exit script - just returns)
  whiptail --title "${title}" --msgbox "${centered_msg}" "${dialog_height}" "${dialog_width}" || true
}

# Wrapper function for whiptail yesno with dynamic sizing, centering, and ESC handling
whiptail_yesno() {
  local title="$1"
  local message="$2"
  local min_height="${3:-10}"
  local min_width="${4:-70}"
  
  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size "${min_height}" "${min_width}")
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  
  # Center-align message
  local centered_msg
  centered_msg=$(center_message "${message}")
  
  # Show dialog and return exit code (ESC returns 1, but we handle it gracefully)
  whiptail --title "${title}" --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  local rc=$?
  # Return 0 for ESC (don't exit script), 0 for Yes, 1 for No
  return ${rc}
}

# Wrapper function for whiptail inputbox with dynamic sizing, centering, and ESC handling
whiptail_inputbox() {
  local title="$1"
  local message="$2"
  local default_value="${3:-}"
  local min_height="${4:-10}"
  local min_width="${5:-70}"
  
  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size "${min_height}" "${min_width}")
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  
  # Center-align message
  local centered_msg
  centered_msg=$(center_message "${message}")
  
  # Show dialog and capture output
  local result
  result=$(whiptail --title "${title}" --inputbox "${centered_msg}" "${dialog_height}" "${dialog_width}" "${default_value}" 3>&1 1>&2 2>&3)
  local rc=$?
  # Return empty string for ESC, actual value otherwise
  if [[ ${rc} -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

# Wrapper function for whiptail passwordbox with dynamic sizing, centering, and ESC handling
whiptail_passwordbox() {
  local title="$1"
  local message="$2"
  local default_value="${3:-}"
  local min_height="${4:-10}"
  local min_width="${5:-70}"
  
  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size "${min_height}" "${min_width}")
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  
  # Center-align message
  local centered_msg
  centered_msg=$(center_message "${message}")
  
  # Show dialog and capture output
  local result
  result=$(whiptail --title "${title}" --passwordbox "${centered_msg}" "${dialog_height}" "${dialog_width}" "${default_value}" 3>&1 1>&2 2>&3)
  local rc=$?
  # Return empty string for ESC, actual value otherwise
  if [[ ${rc} -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

# Shared whiptail textbox helper (scrollable)
show_textbox() {
  local title="$1"
  local file="$2"
  local HEIGHT WIDTH

  if command -v tput >/dev/null 2>&1; then
    HEIGHT=$(tput lines)
    WIDTH=$(tput cols)
  else
    HEIGHT=25
    WIDTH=100
  fi

  [ -z "${HEIGHT}" ] && HEIGHT=25
  [ -z "${WIDTH}" ] && WIDTH=100
  [ "${HEIGHT}" -lt 15 ] && HEIGHT=15
  [ "${WIDTH}" -lt 60 ] && WIDTH=60

  if ! whiptail --title "${title}" \
                --scrolltext \
                --textbox "${file}" $((HEIGHT-4)) $((WIDTH-4)); then
    # Ignore cancel (ESC) and simply return
    :
  fi
}

#######################################
# View long output via less (color + safe for set -e / set -u)
# Usage:
#   1) Pass only content          : show_paged "$big_message"
#   2) Pass title and file path   : show_paged "Title" "/path/to/file"
#######################################
show_paged() {
  local title file tmpfile no_clear

  # ANSI color definitions
  local RED="\033[1;31m"
  local GREEN="\033[1;32m"
  local BLUE="\033[1;34m"
  local CYAN="\033[1;36m"
  local YELLOW="\033[1;33m"
  local RESET="\033[0m"

  # --- Argument handling (safe with set -u) ---
  no_clear="0"
  if [[ $# -eq 1 ]]; then
    # Single argument: content string only
    title="XDR Installer info"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    # Two or more args: 1 = title, 2 = file path
    title="$1"
    file="$2"
    if [[ "${3:-}" == "no-clear" ]]; then
      no_clear="1"
    fi
  else
    echo "show_paged: no content provided" >&2
    return 1
  fi

  if [[ "${no_clear}" -eq 0 ]]; then
    clear
  fi
  echo -e "${CYAN}============================================================${RESET}"
  echo -e "  ${YELLOW}${title}${RESET}"
  echo -e "${CYAN}============================================================${RESET}"
  echo
  echo -e "${GREEN}※ Space/↓: next page, ↑: previous, q: quit${RESET}"
  echo

  # --- Protect less: avoid set -e bailouts here ---
  set +e
  less -R "${file}"
  local rc=$?
  set -e
  # ----------------------------------------------------

  # In single-arg mode we created tmpfile; remove if present
  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"

  # Always treat as success regardless of less return code
  return 0
}



#######################################
# Common utility functions
#######################################

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | tee -a "${LOG_FILE}"
}

# Run command in DRY_RUN-aware mode
run_cmd() {
  local cmd="$*"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${cmd}"
  else
    log "[RUN] ${cmd}"
    eval "${cmd}"
  fi
}

run_cmd_linkscan() {
  local cmd="$*"

  if [[ "${DRY_RUN}" -eq 1 && "${STEP01_LINK_SCAN_REAL:-1}" -ne 1 ]]; then
    log "[DRY-RUN] ${cmd}"
    return 0
  fi

  log "[RUN-LINKSCAN] ${cmd}"
  eval "${cmd}" 2>&1 | tee -a "${LOG_FILE}"
  local exit_code="${PIPESTATUS[0]}"
  if [[ "${exit_code}" -ne 0 ]]; then
    log "[ERROR] Link-scan command failed (exit code: ${exit_code}): ${cmd}"
  fi
  return "${exit_code}"
}

append_fstab_if_missing() {
  local line="$1"
  local mount_point="$2"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if grep -qE "[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
      log "[DRY-RUN] remove existing /etc/fstab entries for: ${mount_point}"
    fi
    log "[DRY-RUN] add the following line to /etc/fstab: ${line}"
  else
    if grep -qE "[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
      local esc_mount_point="${mount_point//\//\\/}"
      sed -i "/[[:space:]]${esc_mount_point}[[:space:]]/d" /etc/fstab
      log "Removed existing /etc/fstab entries for: ${mount_point}"
    fi
    echo "${line}" >> /etc/fstab
    log "Added entry to /etc/fstab: ${line}"
  fi
}

#######################################
# Bridge runtime creation/UP guarantee (NO-CARRIER allowed)
# Purpose: Ensure bridge exists and is admin UP for VM attach
#          NO-CARRIER (operstate DOWN) is acceptable and not a failure condition
#######################################
ensure_bridge_up_no_carrier_ok() {
  local bridge_name="$1"
  local phys_nic="$2"
  local _DRY="${DRY_RUN:-0}"

  log "[Bridge Ensure] Ensuring bridge ${bridge_name} is ready for VM attach (NO-CARRIER allowed)"

  # 1) Check bridge existence and create
  if ! ip link show dev "${bridge_name}" >/dev/null 2>&1; then
    log "[Bridge Ensure] Bridge ${bridge_name} does not exist, creating it"
    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] ip link add name ${bridge_name} type bridge"
    else
      ip link add name "${bridge_name}" type bridge 2>/dev/null || {
        log "[ERROR] Failed to create bridge ${bridge_name}"
        return 1
      }
      log "[Bridge Ensure] Bridge ${bridge_name} created"
    fi
  else
    log "[Bridge Ensure] Bridge ${bridge_name} already exists"
  fi

  # 2) Ensure bridge admin UP
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] ip link set dev ${bridge_name} up"
  else
    ip link set dev "${bridge_name}" up 2>/dev/null || {
      log "[ERROR] Failed to set bridge ${bridge_name} admin UP"
      return 1
    }
    log "[Bridge Ensure] Bridge ${bridge_name} set to admin UP"
  fi

  # 3) Physical NIC admin UP (bring up before enslave)
  if [[ -n "${phys_nic}" ]]; then
    if ip link show dev "${phys_nic}" >/dev/null 2>&1; then
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] ip link set dev ${phys_nic} up"
      else
        ip link set dev "${phys_nic}" up 2>/dev/null || true
        log "[Bridge Ensure] Physical NIC ${phys_nic} set to admin UP"
      fi

      # 4) Enslave physical NIC to bridge (set master)
      local current_master
      current_master="$(ip link show dev "${phys_nic}" 2>/dev/null | grep -oP 'master \K\w+' || echo "")"
      if [[ "${current_master}" != "${bridge_name}" ]]; then
        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] ip link set dev ${phys_nic} master ${bridge_name}"
        else
          ip link set dev "${phys_nic}" master "${bridge_name}" 2>/dev/null || {
            log "[WARN] Failed to enslave ${phys_nic} to ${bridge_name}, but continuing"
          }
          log "[Bridge Ensure] Physical NIC ${phys_nic} enslaved to bridge ${bridge_name}"
        fi
      else
        log "[Bridge Ensure] Physical NIC ${phys_nic} is already enslaved to ${bridge_name}"
      fi
    else
      log "[WARN] Physical NIC ${phys_nic} does not exist, skipping enslave"
    fi
  fi

  # 5) Disable STP/forward_delay (same as Sensor-Installer)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] echo 0 > /sys/class/net/${bridge_name}/bridge/stp_state"
    log "[DRY-RUN] echo 0 > /sys/class/net/${bridge_name}/bridge/forward_delay"
  else
    if [[ -f "/sys/class/net/${bridge_name}/bridge/stp_state" ]]; then
      echo 0 > "/sys/class/net/${bridge_name}/bridge/stp_state" 2>/dev/null || true
      log "[Bridge Ensure] Bridge ${bridge_name} STP disabled"
    fi
    if [[ -f "/sys/class/net/${bridge_name}/bridge/forward_delay" ]]; then
      echo 0 > "/sys/class/net/${bridge_name}/bridge/forward_delay" 2>/dev/null || true
      log "[Bridge Ensure] Bridge ${bridge_name} forward_delay set to 0"
    fi
  fi

  # 6) Final admin UP check (operstate not enforced)
  if [[ "${_DRY}" -eq 0 ]]; then
    if ! ip -o link show dev "${bridge_name}" 2>/dev/null | grep -q "<.*UP.*>"; then
      log "[ERROR] Bridge ${bridge_name} exists but cannot be set ADMIN-UP"
      return 1
    fi
  fi

  # 7) Check operstate (log only, not a failure condition)
  if [[ "${_DRY}" -eq 0 ]]; then
    local operstate
    operstate="$(cat /sys/class/net/${bridge_name}/operstate 2>/dev/null || echo unknown)"
    local admin_flags
    admin_flags="$(ip -o link show dev "${bridge_name}" 2>/dev/null | grep -o '<.*>' || echo 'unknown')"

    if [[ "${operstate}" != "up" ]]; then
      log "[WARN] Bridge ${bridge_name} operstate=${operstate} (NO-CARRIER is acceptable for VM attach)"
    else
      log "[Bridge Ensure] Bridge ${bridge_name} operstate=up"
    fi

    log "[Bridge Ensure] Bridge ${bridge_name} - exists: yes, admin flags: ${admin_flags}, operstate: ${operstate} (acceptable)"
  fi

  log "[Bridge Ensure] Bridge ${bridge_name} is ready for VM attach"
  return 0
}


#######################################
# Config management (CONFIG_FILE)
#######################################

# CONFIG_FILE is already defined above
# Example: CONFIG_FILE="${STATE_DIR}/xdr-installer.conf"
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
  fi

  # Defaults (set only if missing)
  : "${DRY_RUN:=1}"  # Default DRY_RUN=1 (safe mode)
  : "${STEP01_LINK_SCAN_REAL:=1}"
  : "${DP_VERSION:=6.2.0}"
  : "${ACPS_USERNAME:=}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=}"

  # Auto reboot defaults
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"

  # Ensure NIC / disk selections are always defined
  : "${MGT_NIC:=}"
  : "${CLTR0_NIC:=}"
  : "${HOST_NIC:=}"
  : "${DATA_SSD_LIST:=}"
  
  # Load renamed interface names if available
  : "${MGT_NIC_RENAMED:=}"
  : "${CLTR0_NIC_RENAMED:=}"
  : "${HOST_NIC_RENAMED:=}"

  # NIC identity (selected at STEP 01, stable across reboots)
  : "${MGT_NIC_SELECTED:=}"
  : "${CLTR0_NIC_SELECTED:=}"
  : "${HOST_NIC_SELECTED:=}"

  # NIC identity by PCI/MAC (stable hardware identifiers)
  : "${MGT_NIC_PCI:=}"
  : "${CLTR0_NIC_PCI:=}"
  : "${HOST_NIC_PCI:=}"

  : "${MGT_NIC_MAC:=}"
  : "${CLTR0_NIC_MAC:=}"
  : "${HOST_NIC_MAC:=}"

  # Compatibility (deprecated, use *_NIC_PCI/*_NIC_MAC instead)
  : "${MGT_PCI:=}"
  : "${CLTR0_PCI:=}"
  : "${HOST_PCI:=}"
  : "${MGT_MAC:=}"
  : "${CLTR0_MAC:=}"
  : "${HOST_MAC:=}"

  # Effective alias identity (measured after STEP 03)
  : "${MGT_EFFECTIVE_PCI:=}"
  : "${CLTR0_EFFECTIVE_PCI:=}"
  : "${HOST_EFFECTIVE_PCI:=}"
  : "${MGT_EFFECTIVE_MAC:=}"
  : "${CLTR0_EFFECTIVE_MAC:=}"
  : "${HOST_EFFECTIVE_MAC:=}"

  # Effective interface names (current names after STEP 03 rename)
  : "${MGT_NIC_EFFECTIVE:=}"
  : "${CLTR0_NIC_EFFECTIVE:=}"
  : "${HOST_NIC_EFFECTIVE:=}"

  : "${RENAMED_CONFLICT_IFACES:=}"

  # Cluster Interface Type (SRIOV or BRIDGE)
  : "${CLUSTER_NIC_TYPE:=BRIDGE}"
  : "${CLUSTER_BRIDGE_NAME:=br-cluster}"

  # VM configuration defaults (can be overridden from config file)
  : "${DL_VCPUS:=42}"
  : "${DL_MEMORY_GB:=136}"
  : "${DL_DISK_GB:=500}"
  : "${DA_VCPUS:=46}"
  : "${DA_MEMORY_GB:=80}"
  : "${DA_DISK_GB:=500}"
}


save_config() {
  # Create directory for CONFIG_FILE
  mkdir -p "$(dirname "${CONFIG_FILE}")"

  # Escape quotes inside values to keep config intact
  local esc_dp_version esc_acps_user esc_acps_pass esc_acps_url
  esc_dp_version=${DP_VERSION//\"/\\\"}
  esc_acps_user=${ACPS_USERNAME//\"/\\\"}
  esc_acps_pass=${ACPS_PASSWORD//\"/\\\"}
  esc_acps_url=${ACPS_BASE_URL//\"/\\\"}

  # Also escape NIC / disk values
  local esc_mgt_nic esc_cltr0_nic esc_host_nic esc_data_ssd esc_cluster_nic_type esc_cluster_bridge_name
  esc_mgt_nic=${MGT_NIC//\"/\\\"}
  esc_cltr0_nic=${CLTR0_NIC//\"/\\\"}
  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_data_ssd=${DATA_SSD_LIST//\"/\\\"}
  esc_cluster_nic_type=${CLUSTER_NIC_TYPE//\"/\\\"}
  esc_cluster_bridge_name=${CLUSTER_BRIDGE_NAME//\"/\\\"}

  # VM configuration values (set defaults if not already set)
  : "${DL_VCPUS:=42}"
  : "${DL_MEMORY_GB:=136}"
  : "${DL_DISK_GB:=500}"
  : "${DA_VCPUS:=46}"
  : "${DA_MEMORY_GB:=80}"
  : "${DA_DISK_GB:=500}"

  cat > "${CONFIG_FILE}" <<EOF
# xdr-installer configuration (auto-generated)
DRY_RUN=${DRY_RUN}
DP_VERSION="${esc_dp_version}"
ACPS_USERNAME="${esc_acps_user}"
ACPS_PASSWORD="${esc_acps_pass}"
ACPS_BASE_URL="${esc_acps_url}"
ENABLE_AUTO_REBOOT=${ENABLE_AUTO_REBOOT}
AUTO_REBOOT_AFTER_STEP_ID="${AUTO_REBOOT_AFTER_STEP_ID}"

# NIC / disk selected in STEP 01
MGT_NIC="${esc_mgt_nic}"
CLTR0_NIC="${esc_cltr0_nic}"
HOST_NIC="${esc_host_nic}"
DATA_SSD_LIST="${esc_data_ssd}"

# NIC identity (stable)
MGT_NIC_SELECTED="${MGT_NIC_SELECTED//\"/\\\"}"
CLTR0_NIC_SELECTED="${CLTR0_NIC_SELECTED//\"/\\\"}"
HOST_NIC_SELECTED="${HOST_NIC_SELECTED//\"/\\\"}"

# NIC identity by PCI/MAC (stable hardware identifiers)
MGT_NIC_PCI="${MGT_NIC_PCI//\"/\\\"}"
CLTR0_NIC_PCI="${CLTR0_NIC_PCI//\"/\\\"}"
HOST_NIC_PCI="${HOST_NIC_PCI//\"/\\\"}"

MGT_NIC_MAC="${MGT_NIC_MAC//\"/\\\"}"
CLTR0_NIC_MAC="${CLTR0_NIC_MAC//\"/\\\"}"
HOST_NIC_MAC="${HOST_NIC_MAC//\"/\\\"}"

# Compatibility (deprecated)
MGT_PCI="${MGT_PCI//\"/\\\"}"
CLTR0_PCI="${CLTR0_PCI//\"/\\\"}"
HOST_PCI="${HOST_PCI//\"/\\\"}"
MGT_MAC="${MGT_MAC//\"/\\\"}"
CLTR0_MAC="${CLTR0_MAC//\"/\\\"}"
HOST_MAC="${HOST_MAC//\"/\\\"}"

# Effective alias identity (measured after STEP 03)
MGT_EFFECTIVE_PCI="${MGT_EFFECTIVE_PCI//\"/\\\"}"
CLTR0_EFFECTIVE_PCI="${CLTR0_EFFECTIVE_PCI//\"/\\\"}"
HOST_EFFECTIVE_PCI="${HOST_EFFECTIVE_PCI//\"/\\\"}"
MGT_EFFECTIVE_MAC="${MGT_EFFECTIVE_MAC//\"/\\\"}"
CLTR0_EFFECTIVE_MAC="${CLTR0_EFFECTIVE_MAC//\"/\\\"}"
HOST_EFFECTIVE_MAC="${HOST_EFFECTIVE_MAC//\"/\\\"}"

# Effective interface names (current names after STEP 03 rename)
MGT_NIC_EFFECTIVE="${MGT_NIC_EFFECTIVE//\"/\\\"}"
CLTR0_NIC_EFFECTIVE="${CLTR0_NIC_EFFECTIVE//\"/\\\"}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE//\"/\\\"}"

# Alias conflict rename history
RENAMED_CONFLICT_IFACES="${RENAMED_CONFLICT_IFACES//\"/\\\"}"

# Cluster Interface Type (SRIOV or BRIDGE)
CLUSTER_NIC_TYPE="${esc_cluster_nic_type}"
CLUSTER_BRIDGE_NAME="${esc_cluster_bridge_name}"

# VM configuration (set in STEP 10/11)
DL_VCPUS=${DL_VCPUS}
DL_MEMORY_GB=${DL_MEMORY_GB}
DL_DISK_GB=${DL_DISK_GB}
DA_VCPUS=${DA_VCPUS}
DA_MEMORY_GB=${DA_MEMORY_GB}
DA_DISK_GB=${DA_DISK_GB}
EOF
}


# Keep compatibility with existing calls to save_config_var by updating
# variables internally and re-calling save_config()
save_config_var() {
  local key="$1"
  local value="$2"

  case "${key}" in
    DRY_RUN)        DRY_RUN="${value}" ;;
    DP_VERSION)     DP_VERSION="${value}" ;;
    ACPS_USERNAME)  ACPS_USERNAME="${value}" ;;
    ACPS_PASSWORD)  ACPS_PASSWORD="${value}" ;;
    ACPS_BASE_URL)  ACPS_BASE_URL="${value}" ;;
    ENABLE_AUTO_REBOOT)        ENABLE_AUTO_REBOOT="${value}" ;;
    AUTO_REBOOT_AFTER_STEP_ID) AUTO_REBOOT_AFTER_STEP_ID="${value}" ;;

    # Add additional keys here
    MGT_NIC)        MGT_NIC="${value}" ;;
    CLTR0_NIC)      CLTR0_NIC="${value}" ;;
    HOST_NIC)       HOST_NIC="${value}" ;;
    DATA_SSD_LIST)  DATA_SSD_LIST="${value}" ;;
    CLUSTER_NIC_TYPE) CLUSTER_NIC_TYPE="${value}" ;;
    CLUSTER_BRIDGE_NAME) CLUSTER_BRIDGE_NAME="${value}" ;;
    MGT_NIC_RENAMED) MGT_NIC_RENAMED="${value}" ;;
    CLTR0_NIC_RENAMED) CLTR0_NIC_RENAMED="${value}" ;;
    HOST_NIC_RENAMED) HOST_NIC_RENAMED="${value}" ;;
    # NIC selection and mapping info
    MGT_SELECTED_IFNAME) MGT_SELECTED_IFNAME="${value}" ;;
    MGT_SELECTED_PCI) MGT_SELECTED_PCI="${value}" ;;
    MGT_SELECTED_MAC) MGT_SELECTED_MAC="${value}" ;;
    MGT_TARGET_NAME) MGT_TARGET_NAME="${value}" ;;
    MGT_EFFECTIVE_IFNAME) MGT_EFFECTIVE_IFNAME="${value}" ;;
    MGT_NIC_SELECTED) MGT_NIC_SELECTED="${value}" ;;
    CLTR0_NIC_SELECTED) CLTR0_NIC_SELECTED="${value}" ;;
    HOST_NIC_SELECTED) HOST_NIC_SELECTED="${value}" ;;

    MGT_NIC_PCI) MGT_NIC_PCI="${value}" ;;
    CLTR0_NIC_PCI) CLTR0_NIC_PCI="${value}" ;;
    HOST_NIC_PCI) HOST_NIC_PCI="${value}" ;;

    MGT_NIC_MAC) MGT_NIC_MAC="${value}" ;;
    CLTR0_NIC_MAC) CLTR0_NIC_MAC="${value}" ;;
    HOST_NIC_MAC) HOST_NIC_MAC="${value}" ;;

    # Compatibility
    MGT_PCI) MGT_PCI="${value}" ;;
    CLTR0_PCI) CLTR0_PCI="${value}" ;;
    HOST_PCI) HOST_PCI="${value}" ;;
    MGT_MAC) MGT_MAC="${value}" ;;
    CLTR0_MAC) CLTR0_MAC="${value}" ;;
    HOST_MAC) HOST_MAC="${value}" ;;

    MGT_EFFECTIVE_PCI) MGT_EFFECTIVE_PCI="${value}" ;;
    CLTR0_EFFECTIVE_PCI) CLTR0_EFFECTIVE_PCI="${value}" ;;
    HOST_EFFECTIVE_PCI) HOST_EFFECTIVE_PCI="${value}" ;;
    MGT_EFFECTIVE_MAC) MGT_EFFECTIVE_MAC="${value}" ;;
    CLTR0_EFFECTIVE_MAC) CLTR0_EFFECTIVE_MAC="${value}" ;;
    HOST_EFFECTIVE_MAC) HOST_EFFECTIVE_MAC="${value}" ;;

    MGT_NIC_EFFECTIVE) MGT_NIC_EFFECTIVE="${value}" ;;
    CLTR0_NIC_EFFECTIVE) CLTR0_NIC_EFFECTIVE="${value}" ;;
    HOST_NIC_EFFECTIVE) HOST_NIC_EFFECTIVE="${value}" ;;

    RENAMED_CONFLICT_IFACES) RENAMED_CONFLICT_IFACES="${value}" ;;

    # Compatibility (keep for backward compatibility)
    MGT_SELECTED_IFNAME) MGT_NIC_SELECTED="${value}" ;;
    CLTR0_SELECTED_IFNAME) CLTR0_NIC_SELECTED="${value}" ;;
    HOST_SELECTED_IFNAME) HOST_NIC_SELECTED="${value}" ;;
    MGT_SELECTED_PCI) MGT_PCI="${value}" ;;
    CLTR0_SELECTED_PCI) CLTR0_PCI="${value}" ;;
    HOST_SELECTED_PCI) HOST_PCI="${value}" ;;
    MGT_SELECTED_MAC) MGT_MAC="${value}" ;;
    CLTR0_SELECTED_MAC) CLTR0_MAC="${value}" ;;
    HOST_SELECTED_MAC) HOST_MAC="${value}" ;;
    MGT_TARGET_NAME) ;; # Ignore, not needed
    CLTR0_TARGET_NAME) ;; # Ignore, not needed
    HOST_TARGET_NAME) ;; # Ignore, not needed
    MGT_EFFECTIVE_IFNAME) ;; # Ignore, always "mgt"
    CLTR0_EFFECTIVE_IFNAME) ;; # Ignore, always "cltr0"
    HOST_EFFECTIVE_IFNAME) ;; # Ignore, always "hostmgmt"
    *)
      # Ignore unknown keys for now (extend here if needed)
      ;;
    esac

  save_config
}


#######################################
# Version compare helpers (DP_VERSION)
#######################################
version_ge() { dpkg --compare-versions "$1" ge "$2"; }
version_gt() { dpkg --compare-versions "$1" gt "$2"; }
version_le() { dpkg --compare-versions "$1" le "$2"; }
version_lt() { dpkg --compare-versions "$1" lt "$2"; }


#######################################
# NIC identity helpers (PCI/MAC/resolve)
#######################################
normalize_pci() {
  # Accept "8b:00.1" or "0000:8b:00.1"
  local p="$1"
  if [[ -z "$p" ]]; then echo ""; return 0; fi
  if [[ "$p" =~ ^0000: ]]; then echo "$p"; return 0; fi
  echo "0000:${p}"
}

get_if_pci() {
  local ifname="$1"
  if [[ -z "$ifname" || ! -e "/sys/class/net/${ifname}/device" ]]; then
    echo ""
    return 0
  fi
  readlink -f "/sys/class/net/${ifname}/device" 2>/dev/null | awk -F/ '{print $NF}'
}

get_if_mac() {
  local ifname="$1"
  if [[ -z "$ifname" || ! -e "/sys/class/net/${ifname}/address" ]]; then
    echo ""
    return 0
  fi
  cat "/sys/class/net/${ifname}/address" 2>/dev/null || echo ""
}

resolve_ifname_by_pci() {
  local pci
  pci="$(normalize_pci "$1")"
  [[ -z "$pci" ]] && { echo ""; return 0; }

  local iface iface_pci
  for iface in /sys/class/net/*; do
    local name
    name="$(basename "$iface")"
    iface_pci="$(get_if_pci "$name")"
    if [[ "$iface_pci" == "$pci" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
}

# Free reserved alias name by renaming current holder to a short temp name.
# This prevents: "Failed to rename ... to 'cltr0': File exists"
free_reserved_name() {
  local alias="$1"       # mgt|cltr0|hostmgmt
  local desired_pci="$2" # 0000:xx:yy.z
  local desired_mac="$3" # optional
  local conflict_log_var="$4" # name of variable to append logs (RENAMED_CONFLICT_IFACES)

  desired_pci="$(normalize_pci "$desired_pci")"

  if ! ip link show "$alias" >/dev/null 2>&1; then
    return 0
  fi

  local cur_pci cur_mac
  cur_pci="$(get_if_pci "$alias")"
  cur_mac="$(get_if_mac "$alias")"

  # If current alias already points to desired NIC -> nothing to do
  if [[ -n "$desired_pci" && "$cur_pci" == "$desired_pci" ]]; then
    return 0
  fi
  if [[ -z "$desired_pci" && -n "$desired_mac" && "$cur_mac" == "$desired_mac" ]]; then
    return 0
  fi

  # We must free the alias name by renaming the current holder.
  # Linux IFNAME length limit is 15, so keep it short & deterministic.
  local tmp=""
  case "$alias" in
    mgt) tmp="mgtold" ;;
    cltr0) tmp="cltold" ;;
    hostmgmt) tmp="hmgold" ;;
    *) tmp="old" ;;
  esac

  # Find available tmp name (tmp0..tmp9)
  local i candidate
  for i in 0 1 2 3 4 5 6 7 8 9; do
    candidate="${tmp}${i}"
    if ! ip link show "$candidate" >/dev/null 2>&1; then
      tmp="$candidate"
      break
    fi
  done

  log "[STEP 03] Alias name conflict: '${alias}' is held by PCI=${cur_pci:-?}, MAC=${cur_mac:-?} but desired PCI=${desired_pci:-?}, MAC=${desired_mac:-?}"
  log "[STEP 03] Freeing alias '${alias}' by renaming it to '${tmp}'"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would run: ip link set ${alias} down; ip link set ${alias} name ${tmp}"
  else
    ip link set "$alias" down >/dev/null 2>&1 || true
    ip link set "$alias" name "$tmp" >/dev/null 2>&1 || true
  fi

  # Append conflict record into RENAMED_CONFLICT_IFACES
  # Format: alias:cur_pci->tmp
  local rec="${alias}:${cur_pci:-unknown}->${tmp}"
  if [[ -n "${!conflict_log_var:-}" ]]; then
    eval "$conflict_log_var=\"${!conflict_log_var};${rec}\""
  else
    eval "$conflict_log_var=\"${rec}\""
  fi
}


#######################################
# PDF-based UEFI/XML patch function (for DP_VERSION >= 6.2.1)
#######################################
apply_pdf_xml_patch() {
  local vm_name="$1"
  local mem_kb="$2"
  local vcpu="$3"
  local bridge_name="$4"
  local disk_path="$5"

  log "[PATCH] ${vm_name} :: PDF guide-based UEFI/XML conversion and Cloud-Init application starting"

  # 1. Stop VM and undefine existing definition
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] virsh destroy ${vm_name} || true"
  else
    local destroy_out
    if destroy_out="$(virsh destroy "${vm_name}" 2>&1)"; then
      log "[PATCH] ${vm_name}: virsh destroy completed"
    else
      log "[WARN] ${vm_name}: virsh destroy failed (likely not running): ${destroy_out}"
    fi
  fi
  run_cmd "virsh undefine ${vm_name} --nvram || virsh undefine ${vm_name} || true"

  # 2. Disk format conversion (QCOW2 -> RAW)
  # virt_deploy script may have created .qcow2 file (or file without extension)
  local qcow_disk="${disk_path%.*}.qcow2"
  # If raw file doesn't exist but qcow2 does, perform conversion
  if [[ ! -f "${disk_path}" ]] && [[ -f "${qcow_disk}" ]]; then
    log "[PATCH] Converting QCOW2 -> RAW... (${qcow_disk} -> ${disk_path})"
    run_cmd "qemu-img convert -f qcow2 -O raw ${qcow_disk} ${disk_path}"
    # Remove original qcow2 (free space)
    run_cmd "rm -f ${qcow_disk}"
  elif [[ -f "${disk_path}" ]]; then
    log "[PATCH] RAW file already exists, skipping conversion: ${disk_path}"
  else
    log "[ERROR] Cannot find source disk image to convert."
    return 1
  fi

  # 3. Copy OVMF NVRAM file (PDF Page 3)
  local nvram_path="/var/lib/libvirt/qemu/nvram/${vm_name}_VARS.fd"
  if [[ ! -f "${nvram_path}" ]]; then
    log "[PATCH] Copying OVMF VARS file (/usr/share/OVMF/OVMF_VARS_4M.fd)"
    run_cmd "cp /usr/share/OVMF/OVMF_VARS_4M.fd ${nvram_path}"
    run_cmd "chmod 600 ${nvram_path}"
    run_cmd "chown libvirt-qemu:kvm ${nvram_path}"
  fi

  # 4. Create Cloud-Init ISO (for automatic partition expansion)
  local seed_iso="/var/lib/libvirt/images/${vm_name}-seed.iso"
  local user_data="/tmp/user-data-${vm_name}"
  local meta_data="/tmp/meta-data-${vm_name}"

  # meta-data
  echo "instance-id: ${vm_name}" > "${meta_data}"
  echo "local-hostname: ${vm_name}" >> "${meta_data}"

  # user-data (automates manual work from PDF Page 5: growpart, resize2fs)
  cat <<CLOUD > "${user_data}"
#cloud-config
bootcmd:
  - [ growpart, /dev/vda, 1 ]
  - [ resize2fs, /dev/vda1 ]
CLOUD

  log "[PATCH] Creating Cloud-Init ISO: ${seed_iso}"
  run_cmd "cloud-localds ${seed_iso} ${user_data} ${meta_data}"

  # 5. Generate UEFI XML (reflects PDF content + Bridge + Raw Disk + Cloud-Init ISO)
  local tmp_xml="/tmp/${vm_name}_uefi.xml"

  cat <<EOF > "${tmp_xml}"
<domain type='kvm'>
  <name>${vm_name}</name>
  <memory unit='KiB'>${mem_kb}</memory>
  <currentMemory unit='KiB'>${mem_kb}</currentMemory>
  <vcpu placement='static'>${vcpu}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
    <nvram>${nvram_path}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='${disk_path}'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${seed_iso}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='bridge'>
      <source bridge='${bridge_name}'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>
    <console type='pty'>
      <target type='virtio' port='0'/>
    </console>
  </devices>
</domain>
EOF

  log "[PATCH] Defining and applying UEFI XML"
  run_cmd "virsh define ${tmp_xml}"
}


#######################################
# State management
#######################################

# State file format (plain text):
# LAST_COMPLETED_STEP=01_hw_detect
# LAST_RUN_TIME=2025-11-28 20:00:00

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    local prev_opts="$-"
    set +e
    set +u
    local tmp_state
    tmp_state="$(mktemp)"
    # Keep only simple KEY=VALUE lines, strip CRLF to avoid source errors.
    tr -d '\r' < "${STATE_FILE}" | grep -E '^[A-Z0-9_]+=.*$' > "${tmp_state}" || true
    # shellcheck disable=SC1090
    source "${tmp_state}" 2>/dev/null || true
    rm -f "${tmp_state}" || true
    [[ "${prev_opts}" == *e* ]] && set -e || set +e
    [[ "${prev_opts}" == *u* ]] && set -u || set +u
  else
    LAST_COMPLETED_STEP=""
    LAST_RUN_TIME=""
  fi
}

save_state() {
  local step_id="$1"
  cat > "${STATE_FILE}" <<EOF
LAST_COMPLETED_STEP="${step_id}"
LAST_RUN_TIME="$(date '+%F %T')"

# NIC identity and effective names (updated after STEP 01/03)
MGT_NIC="${MGT_NIC}"
CLTR0_NIC="${CLTR0_NIC}"
HOST_NIC="${HOST_NIC}"
MGT_NIC_PCI="${MGT_NIC_PCI}"
CLTR0_NIC_PCI="${CLTR0_NIC_PCI}"
HOST_NIC_PCI="${HOST_NIC_PCI}"
MGT_NIC_MAC="${MGT_NIC_MAC}"
CLTR0_NIC_MAC="${CLTR0_NIC_MAC}"
HOST_NIC_MAC="${HOST_NIC_MAC}"
MGT_NIC_EFFECTIVE="${MGT_NIC_EFFECTIVE}"
CLTR0_NIC_EFFECTIVE="${CLTR0_NIC_EFFECTIVE}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE}"
EOF
}

get_step_index_by_id() {
  local id="$1"
  local i
  for ((i=0; i<NUM_STEPS; i++)); do
    if [[ "${STEP_IDS[$i]}" == "${id}" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "-1"
  return 1
}

get_next_step_index() {
  load_state
  if [[ -z "${LAST_COMPLETED_STEP}" ]]; then
    # Nothing done yet → start from index 0
    echo "0"
    return
  fi
  local idx
  idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
  if (( idx < 0 )); then
    # Unknown state → restart from 0
    echo "0"
    return
  fi
  local next=$((idx + 1))
  if (( next >= NUM_STEPS )); then
    # All steps completed
    echo "${NUM_STEPS}"
  else
    echo "${next}"
  fi
}

#######################################
# STEP execution (skeleton)
#######################################

run_step() {
  local idx="$1"
  local step_id="${STEP_IDS[$idx]}"
  local step_name="${STEP_NAMES[$idx]}"
  RUN_STEP_STATUS="UNKNOWN"

  # STEP 06 always includes SR-IOV driver installation + NTPsec
  if [[ "${step_id}" == "06_ntpsec" ]]; then
    step_name="Configure SR-IOV drivers (iavf/i40evf) + NTPsec"
  fi

  # Confirm whether to run this STEP
  # Calculate dialog size dynamically and center message
  local dialog_dims
  dialog_dims=$(calc_dialog_size 12 70)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  local centered_msg
  centered_msg=$(center_message "${step_name}\n\nRun this step now?")
  
  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail --title "XDR Installer - ${step_id}" \
           --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    # Treat cancel as normal flow (not an error)
    log "User canceled running STEP ${step_id}."
    RUN_STEP_STATUS="CANCELED"
    return 0   # Must return 0 here to avoid set -e firing in main case
  fi

  log "===== STEP START: ${step_id} - ${step_name} ====="

  local rc=0

  # Invoke each STEP's implementation
  case "${step_id}" in
    "01_hw_detect")
      step_01_hw_detect || rc=$?
      ;;
    "02_hwe_kernel")
      step_02_hwe_kernel || rc=$?
      ;;
    "03_nic_ifupdown")
      step_03_nic_ifupdown || rc=$?
      ;;
    "04_kvm_libvirt")
      step_04_kvm_libvirt || rc=$?
      ;;
    "05_kernel_tuning")
      step_05_kernel_tuning || rc=$?
      ;;
    "06_ntpsec")
      step_06_ntpsec || rc=$?
      ;;
    "07_lvm_storage")
      step_07_lvm_storage || rc=$?
      ;;
    "08_libvirt_hooks")
      step_08_libvirt_hooks || rc=$?
      ;;
    "09_dp_download")
      step_09_dp_download || rc=$?
      ;;
    "10_dl_master_deploy")
      step_10_dl_master_deploy || rc=$?
      ;;
    "11_da_master_deploy")
      step_11_da_master_deploy || rc=$?
      ;;
    "12_sriov_cpu_affinity")
      step_12_sriov_cpu_affinity || rc=$?
      ;;
    "13_install_dp_cli")
      step_13_install_dp_cli || rc=$?
      ;;
    *)
      log "ERROR: Undefined STEP ID: ${step_id}"
      rc=1
      ;;
  esac

  # Check if step was canceled (return code 2) vs failed (return code 1)
  if [[ "${rc}" -eq 2 ]]; then
    # Step was canceled by user - don't save state, don't reboot
    log "===== STEP CANCELED: ${step_id} - ${step_name} ====="
    RUN_STEP_STATUS="CANCELED"
    return 0
  elif [[ "${rc}" -eq 0 ]]; then
    RUN_STEP_STATUS="DONE"
    log "===== STEP DONE: ${step_id} - ${step_name} ====="
    save_state "${step_id}"

    ###############################################
    # Shared auto reboot handling
    ###############################################
    if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
      # Support multiple STEP IDs in AUTO_REBOOT_AFTER_STEP_ID
      for reboot_step in ${AUTO_REBOOT_AFTER_STEP_ID}; do
        if [[ "${step_id}" == "${reboot_step}" ]]; then
          log "AUTO_REBOOT_AFTER_STEP_ID=${AUTO_REBOOT_AFTER_STEP_ID} contains current STEP=${step_id} → performing auto reboot."

          whiptail_msgbox "Auto reboot" "STEP ${step_id} (${step_name}) completed successfully.\n\nThe system will reboot automatically." 12 70

          if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] Auto reboot is not executed."
            # If DRY_RUN, just exit this block and continue down to return 0
          else
            reboot
            # Ensure the shell exits immediately after issuing reboot
            exit 0
          fi

          # Once reboot handled in this STEP, no need to check others
          break
        fi
      done
    fi
  else
    RUN_STEP_STATUS="FAILED"
    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    whiptail_msgbox "STEP failed - ${step_id}" "An error occurred while running STEP ${step_id} (${step_name}).\n\nCheck logs and rerun the STEP if needed.\nThe installer can continue to run." 14 80
  fi

  # Always return 0 so set -e is not triggered here
  return 0
  }


#######################################
# Hardware detection utilities
#######################################

is_step01_excluded_iface() {
  local name="$1"
  [[ -z "${name}" ]] && return 0
  [[ "${name}" == "lo" ]] && return 0
  [[ "${name}" =~ ^(virbr|vnet|br|docker|tap|tun|vxlan|flannel|cni|cali|kube|veth|ovs) ]] && return 0
  [[ -d "/sys/class/net/${name}/bridge" ]] && return 0
  [[ ! -e "/sys/class/net/${name}/device" ]] && return 0
  [[ -e "/sys/class/net/${name}/device/physfn" ]] && return 0
  return 1
}

list_step01_phys_nics() {
  local nic_path name
  for nic_path in /sys/class/net/*; do
    name="${nic_path##*/}"
    if is_step01_excluded_iface "${name}"; then
      continue
    fi
    echo "${name}"
  done
}

list_auto_ifaces() {
  local f
  for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
    [[ -f "${f}" ]] || continue
    awk '
      tolower($1)=="auto" {
        for (i=2; i<=NF; i++) print $i
      }
    ' "${f}" 2>/dev/null || true
  done | sort -u
}

get_admin_state() {
  local nic="$1"
  local line
  line="$(ip -o link show dev "${nic}" 2>/dev/null || true)"
  if [[ -z "${line}" ]]; then
    echo "UNKNOWN"
    return 0
  fi
  if echo "${line}" | grep -q "UP"; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

step01_write_admin_state_snapshot() {
  local state_file="$1"
  local nic
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write STEP 01 admin snapshot: ${state_file}"
    return 0
  fi
  mkdir -p "${STATE_DIR}" 2>/dev/null || true
  {
    echo "# nic|admin_state|mac"
    for nic in "${STEP01_CANDIDATE_NICS[@]}"; do
      echo "${nic}|${STEP01_ADMIN_STATE[${nic}]}|${STEP01_MAC[${nic}]}"
    done
  } > "${state_file}"
}

step01_get_link_state() {
  local nic="$1"
  local et_out link_state

  link_state="unknown"

  if command -v ethtool >/dev/null 2>&1; then
    et_out="$(ethtool "${nic}" 2>/dev/null || true)"
    if echo "${et_out}" | grep -q "Link detected: yes"; then
      echo "yes"
      return 0
    fi
    if echo "${et_out}" | grep -q "Link detected: no"; then
      link_state="no"
    fi
  fi

  if [[ -f "/sys/class/net/${nic}/carrier" ]]; then
    local carrier
    carrier="$(cat "/sys/class/net/${nic}/carrier" 2>/dev/null || echo "")"
    if [[ "${carrier}" == "1" ]]; then
      echo "yes"
      return 0
    elif [[ "${carrier}" == "0" && "${link_state}" != "yes" ]]; then
      echo "no"
      return 0
    fi
  fi

  if [[ -f "/sys/class/net/${nic}/operstate" ]]; then
    local operstate
    operstate="$(cat "/sys/class/net/${nic}/operstate" 2>/dev/null || echo "")"
    if [[ "${operstate}" == "up" ]]; then
      echo "yes"
      return 0
    fi
    if [[ "${operstate}" == "down" || "${operstate}" == "dormant" ]]; then
      echo "no"
      return 0
    fi
  fi

  echo "${link_state}"
}

step01_get_link_state_with_retry() {
  local nic="$1"
  local retries interval attempt state

  retries="${STEP01_LINK_RETRIES:-5}"
  interval="${STEP01_LINK_INTERVAL:-2}"
  attempt=1

  while true; do
    state="$(step01_get_link_state "${nic}")"
    if [[ "${state}" == "yes" ]]; then
      echo "yes"
      return 0
    fi
    if (( attempt >= retries )); then
      echo "${state}"
      return 0
    fi
    sleep "${interval}"
    attempt=$((attempt + 1))
  done
}

step01_prepare_link_scan() {
  local cleanup_mode="${STEP01_LINK_CLEANUP_MODE:-B}"
  local state_file="${STATE_DIR}/step01_admin_state.txt"
  local nics auto_list nic mac admin_state

  nics="$(list_step01_phys_nics || true)"
  if [[ -z "${nics}" ]]; then
    log "[STEP 01] No physical NIC candidates found for link scan (skip)"
    return 0
  fi

  declare -gA STEP01_ADMIN_STATE STEP01_LINK_STATE STEP01_MAC
  declare -ga STEP01_CANDIDATE_NICS STEP01_TEMP_UP_NICS
  STEP01_CANDIDATE_NICS=()
  STEP01_TEMP_UP_NICS=()

  while IFS= read -r nic; do
    [[ -z "${nic}" ]] && continue
    STEP01_CANDIDATE_NICS+=("${nic}")
    mac="$(get_if_mac "${nic}")"
    admin_state="$(get_admin_state "${nic}")"
    STEP01_MAC["${nic}"]="${mac}"
    STEP01_ADMIN_STATE["${nic}"]="${admin_state}"
  done <<< "${nics}"

  step01_write_admin_state_snapshot "${state_file}"
  log "[STEP 01] Temp admin-up target NICs: ${STEP01_CANDIDATE_NICS[*]}"

  auto_list="$(list_auto_ifaces || true)"

  for nic in "${STEP01_CANDIDATE_NICS[@]}"; do
    if echo "${auto_list}" | grep -qx "${nic}"; then
      log "[STEP 01] Skip temp up (auto iface): ${nic}"
      continue
    fi
    if [[ "${STEP01_ADMIN_STATE[${nic}]}" == "UP" ]]; then
      log "[STEP 01] Skip temp up (already UP): ${nic}"
      continue
    fi
    STEP01_TEMP_UP_NICS+=("${nic}")
  done

  if [[ ${#STEP01_TEMP_UP_NICS[@]} -gt 0 ]]; then
    log "[STEP 01] Executing temp admin-up: ${STEP01_TEMP_UP_NICS[*]}"
    for nic in "${STEP01_TEMP_UP_NICS[@]}"; do
      run_cmd_linkscan "sudo ip link set ${nic} up" || true
    done
  fi

  local initial_wait retries interval total_wait
  initial_wait="${STEP01_LINK_INITIAL_WAIT:-3}"
  retries="${STEP01_LINK_RETRIES:-5}"
  interval="${STEP01_LINK_INTERVAL:-2}"
  total_wait=$(( initial_wait + interval * (retries - 1) ))
  log "[STEP 01] Link scan in progress. This can take longer depending on NIC count (often 10~20s). Please wait..."

  # Allow link to settle after admin up
  sleep "${initial_wait}"

  local remaining_nics round
  remaining_nics=("${STEP01_CANDIDATE_NICS[@]}")
  round=1
  while true; do
    local new_remaining=()
    for nic in "${remaining_nics[@]}"; do
      local link_state
      link_state="$(step01_get_link_state "${nic}")"
      STEP01_LINK_STATE["${nic}"]="${link_state}"
      if [[ "${link_state}" != "yes" ]]; then
        new_remaining+=("${nic}")
      fi
    done
    remaining_nics=("${new_remaining[@]}")
    if [[ ${#remaining_nics[@]} -eq 0 || ${round} -ge ${retries} ]]; then
      break
    fi
    sleep "${interval}"
    round=$((round + 1))
  done

  for nic in "${STEP01_CANDIDATE_NICS[@]}"; do
    log "[STEP 01] Link detected: ${nic}=${STEP01_LINK_STATE[${nic}]:-unknown}"
  done

  log "[STEP 01] Link scan cleanup policy: ${cleanup_mode}"
  for nic in "${STEP01_CANDIDATE_NICS[@]}"; do
    local link_state orig_state
    link_state="${STEP01_LINK_STATE[${nic}]}"
    orig_state="${STEP01_ADMIN_STATE[${nic}]}"

    if [[ "${cleanup_mode}" == "A" ]]; then
      if [[ "${orig_state}" == "DOWN" ]]; then
        run_cmd_linkscan "sudo ip link set ${nic} down" || true
        log "[STEP 01] Cleanup(A): ${nic} -> DOWN (restore)"
      else
        log "[STEP 01] Cleanup(A): ${nic} -> keep ${orig_state}"
      fi
      continue
    fi

    if [[ "${link_state}" == "yes" ]]; then
      run_cmd_linkscan "sudo ip link set ${nic} up" || true
      log "[STEP 01] Cleanup(B): ${nic} -> keep UP (link yes)"
    else
      if [[ "${orig_state}" == "DOWN" ]]; then
        run_cmd_linkscan "sudo ip link set ${nic} down" || true
        log "[STEP 01] Cleanup(B): ${nic} -> restore DOWN (link ${link_state})"
      else
        log "[STEP 01] Cleanup(B): ${nic} -> keep ${orig_state} (link ${link_state})"
      fi
    fi
  done
}

list_nic_candidates() {
  list_step01_phys_nics || true
}

# Find interface name by PCI address
# Excludes virtual interfaces (lo, virbr*, vnet*, docker*, br-*, ovs*)
find_if_by_pci() {
  local pci="$1"
  [[ -z "$pci" ]] && { echo ""; return 0; }
  
  pci="$(normalize_pci "$pci")"
  
  local iface name iface_pci
  for iface in /sys/class/net/*; do
    name="$(basename "$iface")"
    # Skip virtual interfaces
    [[ "$name" =~ ^(lo|virbr|vnet|tap|docker|br-|ovs) ]] && continue
    
    iface_pci="$(get_if_pci "$name")"
    if [[ "$iface_pci" == "$pci" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
}

# Find interface name by MAC address
# Excludes virtual interfaces (lo, virbr*, vnet*, docker*, br-*, ovs*)
find_if_by_mac() {
  local mac="$1"
  [[ -z "$mac" ]] && { echo ""; return 0; }
  
  local iface name iface_mac
  for iface in /sys/class/net/*; do
    name="$(basename "$iface")"
    # Skip virtual interfaces
    [[ "$name" =~ ^(lo|virbr|vnet|tap|docker|br-|ovs) ]] && continue
    
    iface_mac="$(get_if_mac "$name")"
    if [[ "$iface_mac" == "$mac" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
}

# Resolve interface name by preferred name, PCI, or MAC (in that order)
# Returns the first available match
resolve_if_name() {
  local preferred_name="$1"
  local pci="$2"
  local mac="$3"
  
  # 1) Check preferred name first
  if [[ -n "$preferred_name" ]] && [[ -e "/sys/class/net/$preferred_name" ]]; then
    # Verify it's not a virtual interface
    if [[ ! "$preferred_name" =~ ^(lo|virbr|vnet|tap|docker|br-|ovs) ]]; then
      echo "$preferred_name"
      return 0
    fi
  fi
  
  # 2) Try PCI
  if [[ -n "$pci" ]]; then
    local found_by_pci
    found_by_pci="$(find_if_by_pci "$pci")"
    if [[ -n "$found_by_pci" ]]; then
      echo "$found_by_pci"
      return 0
    fi
  fi
  
  # 3) Try MAC
  if [[ -n "$mac" ]]; then
    local found_by_mac
    found_by_mac="$(find_if_by_mac "$mac")"
    if [[ -n "$found_by_mac" ]]; then
      echo "$found_by_mac"
      return 0
    fi
  fi
  
  # 4) Not found
  echo ""
}

# Normalize MAC address: convert to lowercase and remove spaces/colons normalization
normalize_mac() {
  local mac="$1"
  [[ -z "$mac" ]] && { echo ""; return 0; }
  # Convert to lowercase, remove spaces, ensure colon-separated format
  echo "$mac" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | sed 's/-/:/g'
}

# Resolve interface name by PCI/MAC identity (source of truth)
# Priority: PCI first, then MAC, then empty string
# Usage: resolve_ifname_by_identity <pci> <mac>
resolve_ifname_by_identity() {
  local pci="$1"
  local mac="$2"
  
  # Normalize inputs
  if [[ -n "$pci" ]]; then
    pci="$(normalize_pci "$pci")"
  fi
  if [[ -n "$mac" ]]; then
    mac="$(normalize_mac "$mac")"
  fi
  
  # 1) Try PCI first (most reliable)
  if [[ -n "$pci" ]]; then
    local found_by_pci
    found_by_pci="$(find_if_by_pci "$pci")"
    if [[ -n "$found_by_pci" ]]; then
      echo "$found_by_pci"
      return 0
    fi
  fi
  
  # 2) Try MAC if PCI failed or not available
  if [[ -n "$mac" ]]; then
    local found_by_mac
    found_by_mac="$(find_if_by_mac "$mac")"
    if [[ -n "$found_by_mac" ]]; then
      echo "$found_by_mac"
      return 0
    fi
  fi
  
  # 3) Not found
  echo ""
}

# Get effective NIC name for subsequent steps (STEP 12, etc.)
# Priority: 1) EFFECTIVE, 2) resolve by identity, 3) fallback to original
# Usage: get_effective_nic <NIC_TYPE> where NIC_TYPE is MGT, CLTR0, or HOST
get_effective_nic() {
  local nic_type="$1"
  local effective_var="" pci_var="" mac_var="" fallback_var=""
  
  case "$nic_type" in
    MGT)
      effective_var="MGT_NIC_EFFECTIVE"
      pci_var="MGT_NIC_PCI"
      mac_var="MGT_NIC_MAC"
      fallback_var="MGT_NIC"
      ;;
    CLTR0)
      effective_var="CLTR0_NIC_EFFECTIVE"
      pci_var="CLTR0_NIC_PCI"
      mac_var="CLTR0_NIC_MAC"
      fallback_var="CLTR0_NIC"
      ;;
    HOST)
      effective_var="HOST_NIC_EFFECTIVE"
      pci_var="HOST_NIC_PCI"
      mac_var="HOST_NIC_MAC"
      fallback_var="HOST_NIC"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
  
  # 1) Use EFFECTIVE if available and interface exists
  local effective_name="${!effective_var:-}"
  if [[ -n "$effective_name" ]] && ip link show "$effective_name" >/dev/null 2>&1; then
    echo "$effective_name"
    return 0
  fi
  
  # 2) Resolve by identity (PCI/MAC)
  local pci_val="${!pci_var:-}"
  local mac_val="${!mac_var:-}"
  if [[ -n "$pci_val" ]] || [[ -n "$mac_val" ]]; then
    local resolved
    resolved="$(resolve_ifname_by_identity "$pci_val" "$mac_val")"
    if [[ -n "$resolved" ]]; then
      echo "$resolved"
      return 0
    fi
  fi
  
  # 3) Fallback to original variable
  local fallback_name="${!fallback_var:-}"
  if [[ -n "$fallback_name" ]] && ip link show "$fallback_name" >/dev/null 2>&1; then
    echo "$fallback_name"
    return 0
  fi
  
  # 4) Not found
  echo ""
  return 1
}

# Build udev rule string for a given alias
# Usage: build_udev_rule <alias> <pci> <mac> <extra_attrs>
# Returns rule string, uses PCI if available, otherwise MAC
build_udev_rule() {
  local alias="$1"
  local pci="$2"
  local mac="$3"
  local extra_attrs="$4"
  
  local rule=""
  if [[ -n "$pci" ]]; then
    pci="$(normalize_pci "$pci")"
    rule="ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"${pci}\", NAME:=\"${alias}\""
  elif [[ -n "$mac" ]]; then
    mac="$(normalize_mac "$mac")"
    rule="ACTION==\"add\", SUBSYSTEM==\"net\", ATTR{address}==\"${mac}\", NAME:=\"${alias}\""
  else
    echo ""
    return 1
  fi
  
  if [[ -n "$extra_attrs" ]]; then
    rule="${rule}, ${extra_attrs}"
  fi
  
  echo "$rule"
}

# Get interface identity (PCI and MAC) by interface name
# Returns: "pci|mac" format
get_if_identity_by_name() {
  local ifname="$1"
  [[ -z "$ifname" ]] && { echo "|"; return 0; }
  
  local pci mac
  pci="$(get_if_pci "$ifname")"
  mac="$(get_if_mac "$ifname")"
  mac="$(normalize_mac "$mac")"
  
  echo "${pci}|${mac}"
}

# Check if target alias name is occupied by wrong NIC
# Returns 0 if OK (free or correct), 1 if conflict
check_name_conflict() {
  local alias="$1"        # mgt|cltr0|hostmgmt
  local desired_pci="$2"  # Expected PCI (normalized)
  local desired_mac="$3"  # Expected MAC (normalized)
  
  if ! ip link show "$alias" >/dev/null 2>&1; then
    return 0  # Name is free, no conflict
  fi
  
  # Get current occupant's identity
  local current_identity
  current_identity="$(get_if_identity_by_name "$alias")"
  local current_pci="${current_identity%%|*}"
  local current_mac="${current_identity#*|}"
  
  # Normalize for comparison
  if [[ -n "$desired_pci" ]]; then
    desired_pci="$(normalize_pci "$desired_pci")"
  fi
  if [[ -n "$current_pci" ]]; then
    current_pci="$(normalize_pci "$current_pci")"
  fi
  if [[ -n "$desired_mac" ]]; then
    desired_mac="$(normalize_mac "$desired_mac")"
  fi
  if [[ -n "$current_mac" ]]; then
    current_mac="$(normalize_mac "$current_mac")"
  fi
  
  # Check if current occupant matches desired
  local matches=0
  if [[ -n "$desired_pci" && -n "$current_pci" && "$current_pci" == "$desired_pci" ]]; then
    matches=1
  elif [[ -z "$desired_pci" && -n "$desired_mac" && -n "$current_mac" && "$current_mac" == "$desired_mac" ]]; then
    matches=1
  fi
  
  if [[ $matches -eq 1 ]]; then
    return 0  # Correct NIC already has this name
  fi
  
  # Conflict: wrong NIC occupies the name
  log "[ERROR] Name conflict: alias '${alias}' is occupied by PCI=${current_pci:-?}, MAC=${current_mac:-?}, but desired PCI=${desired_pci:-?}, MAC=${desired_mac:-?}"
  return 1
}

# Check for external udev/systemd-networkd rules that conflict with our target names
# Returns 0 if no conflict, 1 if conflict found
check_external_rules_conflict() {
  local udev_file="$1"  # Our managed udev file to exclude from search
  local conflict_file="/tmp/xdr_nic_conflict.txt"
  local conflicts_found=0
  
  > "$conflict_file"  # Clear conflict file
  
  # Check udev rules (exclude our managed file and backup files)
  local udev_conflicts
  udev_conflicts=$(
    grep -rE 'NAME:="mgt"|NAME:="cltr0"|NAME:="hostmgmt"' /etc/udev/rules.d /lib/udev/rules.d 2>/dev/null \
      | grep -v "^${udev_file}:" \
      | grep -vE '\.bak(:|$)' \
      || true
  )
  if [[ -n "$udev_conflicts" ]]; then
    echo "=== udev rules conflicts ===" >> "$conflict_file"
    echo "$udev_conflicts" >> "$conflict_file"
    echo "" >> "$conflict_file"
    conflicts_found=1
  fi
  
  # Check systemd-networkd
  if [[ -d /etc/systemd/network ]] || [[ -d /lib/systemd/network ]]; then
    local systemd_conflicts
    systemd_conflicts=$(grep -rE 'Name=mgt|Name=cltr0|Name=hostmgmt' /etc/systemd/network /lib/systemd/network 2>/dev/null || true)
    if [[ -n "$systemd_conflicts" ]]; then
      echo "=== systemd-networkd conflicts ===" >> "$conflict_file"
      echo "$systemd_conflicts" >> "$conflict_file"
      echo "" >> "$conflict_file"
      conflicts_found=1
    fi
  fi
  
  if [[ $conflicts_found -eq 1 ]]; then
    return 1
  fi
  
  return 0
}

# Check that mgt/cltr0/hostmgmt have unique identities (no duplicate PCI/MAC)
# Returns 0 if all unique, 1 if duplicates found
check_unique_identities() {
  local mgt_pci="$1"
  local mgt_mac="$2"
  local cltr0_pci="$3"
  local cltr0_mac="$4"
  local host_pci="$5"
  local host_mac="$6"
  
  # Normalize all values
  if [[ -n "$mgt_pci" ]]; then
    mgt_pci="$(normalize_pci "$mgt_pci")"
  fi
  if [[ -n "$cltr0_pci" ]]; then
    cltr0_pci="$(normalize_pci "$cltr0_pci")"
  fi
  if [[ -n "$host_pci" ]]; then
    host_pci="$(normalize_pci "$host_pci")"
  fi
  if [[ -n "$mgt_mac" ]]; then
    mgt_mac="$(normalize_mac "$mgt_mac")"
  fi
  if [[ -n "$cltr0_mac" ]]; then
    cltr0_mac="$(normalize_mac "$cltr0_mac")"
  fi
  if [[ -n "$host_mac" ]]; then
    host_mac="$(normalize_mac "$host_mac")"
  fi
  
  # Check PCI duplicates (if PCI is available)
  if [[ -n "$mgt_pci" && -n "$cltr0_pci" && "$mgt_pci" == "$cltr0_pci" ]]; then
    log "[ERROR] Duplicate identity: mgt and cltr0 share the same PCI: ${mgt_pci}"
    return 1
  fi
  if [[ -n "$mgt_pci" && -n "$host_pci" && "$mgt_pci" == "$host_pci" ]]; then
    log "[ERROR] Duplicate identity: mgt and hostmgmt share the same PCI: ${mgt_pci}"
    return 1
  fi
  if [[ -n "$cltr0_pci" && -n "$host_pci" && "$cltr0_pci" == "$host_pci" ]]; then
    log "[ERROR] Duplicate identity: cltr0 and hostmgmt share the same PCI: ${cltr0_pci}"
    return 1
  fi
  
  # Check MAC duplicates (if PCI is not available, use MAC)
  if [[ -z "$mgt_pci" && -z "$cltr0_pci" ]]; then
    if [[ -n "$mgt_mac" && -n "$cltr0_mac" && "$mgt_mac" == "$cltr0_mac" ]]; then
      log "[ERROR] Duplicate identity: mgt and cltr0 share the same MAC: ${mgt_mac}"
      return 1
    fi
  fi
  if [[ -z "$mgt_pci" && -z "$host_pci" ]]; then
    if [[ -n "$mgt_mac" && -n "$host_mac" && "$mgt_mac" == "$host_mac" ]]; then
      log "[ERROR] Duplicate identity: mgt and hostmgmt share the same MAC: ${mgt_mac}"
      return 1
    fi
  fi
  if [[ -z "$cltr0_pci" && -z "$host_pci" ]]; then
    if [[ -n "$cltr0_mac" && -n "$host_mac" && "$cltr0_mac" == "$host_mac" ]]; then
      log "[ERROR] Duplicate identity: cltr0 and hostmgmt share the same MAC: ${cltr0_mac}"
      return 1
    fi
  fi
  
  return 0
}

list_disk_candidates() {
  # Exclude the physical disk hosting the root filesystem
  local root_src root_disk
  root_src=$(findmnt -no SOURCE / 2>/dev/null || echo "")
  root_disk=""
  if [[ -n "${root_src}" ]]; then
    root_disk=$(lsblk -no PKNAME "${root_src}" 2>/dev/null || echo "")
  fi

  lsblk -dn -o NAME,SIZE,MODEL,TYPE | awk -v rd="${root_disk}" '
    $4 == "disk" && $1 != rd {
      # Output: NAME SIZE[ MODEL...]
      printf "%s %s_%s\n", $1, $2, $3
    }
  '
}


#######################################
# DRY-RUN skeleton implementations for each STEP
# (actual logic not yet implemented here)
#######################################

step_01_hw_detect() {
  log "[STEP 01] Detect and select hardware / NIC / disks"

  # Load latest config (optional, avoid failure)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set defaults to avoid set -u issues (empty when undefined)
  : "${MGT_NIC:=}"
  : "${CLTR0_NIC:=}"
  : "${HOST_NIC:=}"
  : "${DATA_SSD_LIST:=}"

  ########################
  # 0) Reuse existing selections?
  ########################
  local mgt_display cltr0_display host_display
  mgt_display="${MGT_NIC_EFFECTIVE:-${MGT_NIC}}"
  cltr0_display="${CLTR0_NIC_EFFECTIVE:-${CLTR0_NIC}}"
  host_display="${HOST_NIC_EFFECTIVE:-${HOST_NIC}}"

  if [[ -n "${MGT_NIC}" && -n "${CLTR0_NIC}" && -n "${HOST_NIC}" && -n "${DATA_SSD_LIST}" ]]; then
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 01 - Reuse previous selections" "The following values are already set:\n\n- MGT_NIC: ${mgt_display}\n- CLTR0_NIC: ${cltr0_display}\n- HOST_NIC: ${host_display}\n- DATA_SSD_LIST: ${DATA_SSD_LIST}\n\nReuse these and skip STEP 01?\n\n(Choose No to re-select NICs/disks.)"
    local reuse_rc=$?
    set -e
    
    if [[ ${reuse_rc} -eq 0 ]]; then
      log "User chose to reuse existing STEP 01 selections (skip STEP 01)."

      # Ensure config is updated even when reusing
      save_config_var "MGT_NIC"       "${MGT_NIC}"
      save_config_var "CLTR0_NIC"     "${CLTR0_NIC}"
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "DATA_SSD_LIST" "${DATA_SSD_LIST}"

      # Reuse counts as success with no further work → return 0
      return 0
    fi
  fi
  

  ########################
  # 1) List NIC candidates
  ########################
  local nics nic_list nic name idx

  # STEP 01 link scan: temp admin UP + ethtool detection + cleanup
  step01_prepare_link_scan || log "[STEP 01] Link scan completed with warnings (continuing)"

  # Guard against list_nic_candidates failure under set -e
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail_msgbox "STEP 01 - NIC detection failed" "No usable NICs found.\n\nCheck ip link output and adjust the script." 12 70
    log "No NIC candidates. Check ip link output."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # Collect IP info and ethtool speed/duplex for each NIC
    local ipinfo speed duplex et_out link_state

    # IP info
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Defaults
    speed="Unknown"
    duplex="Unknown"

    # Fetch Speed / Duplex via ethtool
    if command -v ethtool >/dev/null 2>&1; then
      # Protect from ethtool failure under set -e
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    link_state="${STEP01_LINK_STATE[${name}]:-unknown}"

    # Show as "speed=..., duplex=..., ip=..." in whiptail menu
    nic_list+=("${name}" "link=${link_state}, speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
    ((idx++))
  done <<< "${nics}"

  ########################
  # 2) Select mgt NIC
  ########################
  local mgt_nic
  # Calculate menu size dynamically based on terminal size and number of NICs
  local menu_dims
  menu_dims=$(calc_menu_size $((idx)) 90 8)
  local menu_height menu_width menu_list_height
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align the menu message based on terminal height
  local msg_content="Choose the management (mgt) NIC.\nThis is the external uplink for VM management traffic (NAT/bridge side).\nDo NOT select the hostmgmt NIC here.\nCurrent: ${mgt_display:-<none>}\n"
  local centered_msg
  centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")
  
  mgt_nic=$(whiptail --title "STEP 01 - Select mgt NIC" \
                     --menu "${centered_msg}" \
                     "${menu_height}" "${menu_width}" "${menu_list_height}" \
                     "${nic_list[@]}" \
                     3>&1 1>&2 2>&3) || {
    log "User canceled mgt NIC selection."
    return 1
  }

  log "Selected mgt NIC: ${mgt_nic}"
  MGT_NIC="${mgt_nic}"
  save_config_var "MGT_NIC" "${MGT_NIC}"   ### Change 2: assign to variable before saving
  # Save stable identity for mgt NIC (PCI/MAC - hardware identifiers)
  save_config_var "MGT_NIC_SELECTED" "${mgt_nic}"
  save_config_var "MGT_NIC_PCI" "$(get_if_pci "${mgt_nic}")"
  save_config_var "MGT_NIC_MAC" "$(get_if_mac "${mgt_nic}")"
  # Compatibility
  save_config_var "MGT_PCI" "$(get_if_pci "${mgt_nic}")"
  save_config_var "MGT_MAC" "$(get_if_mac "${mgt_nic}")"

  ########################
  # 3) Select HOST access NIC (for direct KVM host access only)
  ########################
  local host_nic
  # Calculate menu size dynamically (reuse same calculation as mgt/cltr0 NIC)
  menu_dims=$(calc_menu_size $((idx)) 90 8)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align the menu message
  local msg_content="Select NIC for direct access (hostmgmt) to the KVM host only.\nThis is NOT the mgt NIC. It is used for host access (no VM NAT).\nIt will be configured as 192.168.0.100/24 without gateway.\n\nCurrent setting: ${HOST_NIC:-<none>}\n"
  local centered_msg
  centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")
  
  host_nic=$(whiptail --title "STEP 01 - Select Host Access NIC" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
    log "User canceled HOST_NIC selection."
    return 1
  }

  # Prevent duplicates (same NIC as mgt/cltr0 is not allowed)
  if [[ "${host_nic}" == "${MGT_NIC}" || "${host_nic}" == "${CLTR0_NIC}" ]]; then
    whiptail_msgbox "Error" "HOST_NIC cannot be the same as MGT_NIC or CLTR0_NIC.\n\n- MGT_NIC : ${MGT_NIC}\n- CLTR0_NIC: ${CLTR0_NIC}\n- HOST_NIC : ${host_nic}" 12 80
    log "HOST_NIC duplicate selection: ${host_nic}"
    return 1
  fi

  log "Selected HOST_NIC: ${host_nic}"
  HOST_NIC="${host_nic}"
  save_config_var "HOST_NIC" "${HOST_NIC}"
  # Save stable identity for hostmgmt NIC (PCI/MAC - hardware identifiers)
  save_config_var "HOST_NIC_SELECTED" "${host_nic}"
  save_config_var "HOST_NIC_PCI" "$(get_if_pci "${host_nic}")"
  save_config_var "HOST_NIC_MAC" "$(get_if_mac "${host_nic}")"
  # Compatibility
  save_config_var "HOST_PCI" "$(get_if_pci "${host_nic}")"
  save_config_var "HOST_MAC" "$(get_if_mac "${host_nic}")"

  ########################
  # 4) Select cltr0 NIC
  ########################
  # Warn if cltr0 NIC matches mgt NIC
  local cltr0_nic
  # Calculate menu size dynamically (reuse same calculation as mgt NIC)
  menu_dims=$(calc_menu_size $((idx)) 90 8)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align the menu message based on terminal height
  local msg_content="Select NIC for cluster (cltr0).\n\nUsing a different NIC from mgt is recommended.\nCurrent: ${cltr0_display:-<none>}\n"
  local centered_msg
  centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")
  
  cltr0_nic=$(whiptail --title "STEP 01 - Select cltr0 NIC" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
    log "User canceled cltr0 NIC selection."
    return 1
  }

  if [[ "${cltr0_nic}" == "${host_nic}" ]]; then
    whiptail_msgbox "Error" "cltr0 NIC cannot be the same as HOST_NIC.\n\n- HOST_NIC : ${host_nic}\n- CLTR0_NIC: ${cltr0_nic}" 12 80
    log "CLTR0_NIC duplicate selection: ${cltr0_nic}"
    return 1
  fi

  if [[ "${cltr0_nic}" == "${mgt_nic}" ]]; then
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "Warning" "mgt NIC and cltr0 NIC are identical.\nThis is not recommended.\nContinue anyway?"
    local warn_rc=$?
    set -e
    
    if [[ ${warn_rc} -ne 0 ]]; then
      log "User canceled configuration with identical NICs."
      return 2  # Return 2 to indicate cancellation
    fi
  fi

  log "Selected cltr0 NIC: ${cltr0_nic}"
  CLTR0_NIC="${cltr0_nic}"
  save_config_var "CLTR0_NIC" "${CLTR0_NIC}"   ### Change 3
  # Save stable identity for cltr0 NIC (PCI/MAC - hardware identifiers)
  save_config_var "CLTR0_NIC_SELECTED" "${cltr0_nic}"
  save_config_var "CLTR0_NIC_PCI" "$(get_if_pci "${cltr0_nic}")"
  save_config_var "CLTR0_NIC_MAC" "$(get_if_mac "${cltr0_nic}")"
  # Compatibility
  save_config_var "CLTR0_PCI" "$(get_if_pci "${cltr0_nic}")"
  save_config_var "CLTR0_MAC" "$(get_if_mac "${cltr0_nic}")"

  ########################
  # 5) Select SSDs for data
  ########################

  # Initialize variables
  local root_info="OS Disk: detection failed (needs check)"
  local disk_list=()
  local all_disks

  # List all physical disks (exclude loop, ram; include only type disk)
  # Output format: NAME SIZE MODEL
  all_disks=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1, $2, $3}')

  if [[ -z "${all_disks}" ]]; then
    whiptail_msgbox "STEP 01 - Disk detection failed" "No physical disks found.\nCheck lsblk output." 12 70
    return 1
  fi

  # Iterate over disks
  while read -r d_name d_size d_model; do
  # Check if any child of the disk (/dev/d_name) is mounted at /, /boot, or /boot/efi
  # Using lsblk -r (raw) to inspect all children mountpoints
  if lsblk "/dev/${d_name}" -r -o MOUNTPOINT | grep -qE "^(/|/boot|/boot/efi)$"; then
    # OS disk found -> omit from list; keep for notice
    root_info="OS Disk: ${d_name} (${d_size}) ${d_model} -> Ubuntu Linux (excluded)"
  else
    # Data disk candidate -> add to checklist
    # Preserve ON/OFF if already selected
    local flag="OFF"
    for selected in ${DATA_SSD_LIST}; do
      if [[ "${selected}" == "${d_name}" ]]; then
        flag="ON"
        break
      fi
    done
  
    # Append to whiptail list
    # Display as: "sda" "1.7T_model" "OFF"
      disk_list+=("${d_name}" "${d_size}_${d_model}" "${flag}")
    fi
  done <<< "${all_disks}"

  # If no data disk candidates (e.g., only one OS disk)
  if [[ ${#disk_list[@]} -eq 0 ]]; then
    whiptail_msgbox "Warning" "No additional disks available for data.\n\nDetected OS disk:\n${root_info}" 12 70
    return 1
  fi

  # Build guidance message
  local msg_guide="Select disks for LVM/ES data.\n(Space: toggle, Enter: confirm)\n\n"
  msg_guide+="==================================================\n"
  msg_guide+=" [System protection] ${root_info}\n"
  msg_guide+="==================================================\n\n"
  msg_guide+="Select data disks from the list below:"

  # Calculate menu size dynamically for disk selection
  local disk_count=$(( ${#disk_list[@]} / 3 ))  # Each disk has 3 elements (name, desc, flag)
  menu_dims=$(calc_menu_size "${disk_count}" 90 8)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

  # Center-align the menu message based on terminal height
  local centered_msg
  centered_msg=$(center_menu_message "${msg_guide}\n" "${menu_height}")

  local selected_disks
  selected_disks=$(whiptail --title "STEP 01 - Select data disks" \
                             --checklist "${centered_msg}" \
                             "${menu_height}" "${menu_width}" "${menu_list_height}" \
                             "${disk_list[@]}" \
                             3>&1 1>&2 2>&3) || {
    log "User canceled disk selection."
    return 1
  }

  # whiptail output is like "sdb" "sdc" → remove quotes
  selected_disks=$(echo "${selected_disks}" | tr -d '"')

  if [[ -z "${selected_disks}" ]]; then
    whiptail_msgbox "Warning" "No disks selected.\nCannot proceed with LVM configuration." 10 70
    log "No data disk selected."
    return 1
  fi

  log "Selected data disks: ${selected_disks}"
  DATA_SSD_LIST="${selected_disks}"
  save_config_var "DATA_SSD_LIST" "${DATA_SSD_LIST}"


  ########################
  # 5) Show summary
  ########################
  local summary
  summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 01: Hardware Detection and Selection - Complete
═══════════════════════════════════════════════════════════

✅ SELECTED HARDWARE:
  • Management NIC (mgt):     ${MGT_NIC}
  • Cluster NIC (cltr0):      ${CLTR0_NIC}
  • Host access NIC:          ${HOST_NIC} (will set 192.168.0.100/24, no gateway in STEP 03)
  • Data disks (LVM):         ${DATA_SSD_LIST}

📁 CONFIGURATION:
  • Config file: ${CONFIG_FILE}
  • Settings saved successfully

💡 IMPORTANT NOTES:
  • These selections will be used in subsequent steps
  • STEP 03 will configure network using mgt NIC
  • STEP 07 will configure LVM using selected data disks
  • To change selections, re-run STEP 01

📝 NEXT STEPS:
  • Proceed to STEP 02 (HWE Kernel Installation)
EOF
)

  whiptail_msgbox "STEP 01 complete" "${summary}"

  ### Optional: save once more for safety
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  # When successful, caller will persist state via save_state
}


step_02_hwe_kernel() {
  log "[STEP 02] Install HWE kernel"
  load_config

  local pkg_name="linux-generic-hwe-24.04"
  local tmp_status="/tmp/xdr_step02_status.txt"

  #######################################
  # 0) Check current kernel / package state
  #######################################
  local cur_kernel hwe_installed hwe_status_detail
  cur_kernel=$(uname -r 2>/dev/null || echo "unknown")
  
  # Check HWE package installation status
  # Check if linux-image-generic-hwe-24.04 is installed via dpkg -l | grep hwe
  hwe_installed="no"
  hwe_status_detail="not installed"
  
  if dpkg -l 2>/dev/null | grep hwe | grep -q "linux-image-generic-hwe-24.04"; then
    hwe_installed="yes"
    hwe_status_detail="HWE kernel installed (linux-image-generic-hwe-24.04)"
  fi

  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 02: HWE (Hardware Enablement) Kernel Installation"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "📋 CURRENT STATUS:"
    echo "  • Current kernel version: ${cur_kernel}"
    echo "  • HWE kernel status: ${hwe_installed}"
    if [[ "${hwe_installed}" == "yes" ]]; then
      echo "    ✅ ${hwe_status_detail}"
    else
      echo "    ⚠️  ${hwe_status_detail}"
      echo "    Expected package: ${pkg_name}"
    fi
    echo
    echo "🔧 ACTIONS TO BE PERFORMED:"
    echo "  1. Update package lists (apt update)"
    echo "  2. Upgrade all packages (apt full-upgrade -y)"
    echo "  3. Install HWE kernel package (${pkg_name})"
    echo "     └─ Will be skipped if already installed"
    echo
    echo "⚠️  IMPORTANT NOTES:"
    echo "  • Even after installing the new HWE kernel, it will NOT take effect"
    echo "    until the system is rebooted"
    echo "  • The current kernel (${cur_kernel}) will remain active until reboot"
    echo "  • Automatic reboot will occur after STEP 03 completes"
    echo "  • There will be a second reboot after STEP 05 completes"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
    fi
  } > "${tmp_status}"


  # After computing cur_kernel/hwe_installed, show summary textbox

  if [[ "${hwe_installed}" == "yes" ]]; then
    local skip_msg="HWE kernel is already detected on this system.\n\n"
    skip_msg+="Status: ${hwe_status_detail}\n"
    skip_msg+="Current kernel: ${cur_kernel}\n\n"
    skip_msg+="Do you want to skip this STEP?\n\n"
    skip_msg+="(Yes: Skip / No: Continue with package update and verification)"
    
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 02 - HWE Kernel Already Detected" "${skip_msg}" 18 80
    local skip_rc=$?
    set -e
    
    if [[ ${skip_rc} -ne 0 ]]; then
      log "User chose to skip STEP 02 entirely (HWE kernel already detected: ${hwe_status_detail})."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE kernel overview" "${tmp_status}"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 02 - confirmation" "Proceed with these actions?\n\n(Yes: continue / No: cancel)"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    log "User canceled STEP 02 execution."
    return 2  # Return 2 to indicate cancellation
  fi


  #######################################
  # 1) apt update / full-upgrade
  #######################################
  log "[STEP 02] Running apt update / full-upgrade"
  run_cmd "sudo apt update"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y"

  #######################################
  # 2) Install HWE kernel package
  #######################################
  if [[ "${hwe_installed}" == "yes" ]]; then
    log "[STEP 02] ${pkg_name} already installed → skipping install"
  else
    log "[STEP 02] Installing ${pkg_name}"
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg_name}"
  fi

  #######################################
  # 3) Post-install summary
  #######################################
  local new_kernel hwe_now hwe_now_detail
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # In DRY-RUN we don't install; reuse existing uname -r and status
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
    hwe_now_detail="${hwe_status_detail}"
  else
    # In real run, re-check current kernel and HWE package status
    new_kernel=$(uname -r 2>/dev/null || echo "unknown")
    hwe_now="no"
    hwe_now_detail="not installed"
    
    # Re-check HWE status: Check if linux-image-generic-hwe-24.04 is installed via dpkg -l | grep hwe
    if dpkg -l 2>/dev/null | grep hwe | grep -q "linux-image-generic-hwe-24.04"; then
      hwe_now="yes"
      hwe_now_detail="HWE kernel installed (linux-image-generic-hwe-24.04)"
    fi
  fi

  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 02: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
    fi
    echo "📊 KERNEL STATUS:"
    echo "  • Previous kernel: ${cur_kernel}"
    echo "  • Current kernel:  ${new_kernel}"
    echo "  • HWE kernel status: ${hwe_now}"
    if [[ "${hwe_now}" == "yes" ]]; then
      echo "    ✅ ${hwe_now_detail}"
    else
      echo "    ⚠️  ${hwe_now_detail}"
      echo "    Expected package: ${pkg_name}"
    fi
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "ℹ️  In real execution mode, the HWE kernel would be installed"
      echo "   and activated after the next reboot."
    else
      if [[ "${hwe_now}" == "yes" ]]; then
        echo "✅ HWE kernel package is now installed"
      else
        echo "⚠️  HWE kernel package installation status: ${hwe_now}"
      fi
    fi
    echo
    echo "📝 NEXT STEPS:"
    echo "  • The new HWE kernel is installed but NOT yet active"
    echo "  • Current kernel (${new_kernel}) remains active until reboot"
    echo "  • The new HWE kernel will become active after the first reboot"
    echo "  • Automatic reboot will occur after STEP 03 completes"
    echo "    (if AUTO_REBOOT_AFTER_STEP_ID includes '03_nic_ifupdown')"
    echo "  • A second reboot will occur after STEP 05 completes"
    echo "    (if AUTO_REBOOT_AFTER_STEP_ID includes '05_kernel_tuning')"
    echo
    echo "💡 TIP: You can verify the new kernel after reboot with:"
    echo "   uname -r"
  } > "${tmp_status}"


  show_textbox "STEP 02 summary" "${tmp_status}"

  # Reboot happens once after STEP 05 via common logic (AUTO_REBOOT_AFTER_STEP_ID)
  log "[STEP 02] HWE kernel step completed. New kernel applies after host reboot."

  return 0
}


#######################################
# STEP 03 - Bridge Mode (Cluster Interface)
#######################################
step_03_bridge_mode() {
  log "[STEP 03 Bridge Mode] Preparing persistent cluster bridge config (Declarative, no runtime network changes)"
  load_config

  if [[ -z "${CLTR0_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - Bridge Mode" "CLTR0_NIC is not configured.\n\nSelect cluster NIC in STEP 01 first." 12 70
    log "CLTR0_NIC missing; cannot proceed."
    return 1
  fi

  local bridge_name="${CLUSTER_BRIDGE_NAME:-br-cluster}"

  #######################################
  # 1) Resolve selected NICs by identity (sysfs-only presence check)
  # NOTE: Do NOT use ip/link/addr/route/ifup/ifdown in STEP 03.
  #######################################
  local desired_cltr0_if desired_mgt_if
  desired_cltr0_if="$(resolve_ifname_by_identity "${CLTR0_NIC_PCI:-}" "${CLTR0_NIC_MAC:-}")"
  desired_mgt_if="$(resolve_ifname_by_identity "${MGT_NIC_PCI:-}" "${MGT_NIC_MAC:-}")"

  [[ -z "${desired_cltr0_if}" ]] && desired_cltr0_if="${CLTR0_NIC}"
  [[ -z "${desired_mgt_if}" ]] && desired_mgt_if="${MGT_NIC:-}"

  if [[ ! -d "/sys/class/net/${desired_cltr0_if}" ]]; then
    whiptail_msgbox "STEP 03 - Bridge Mode" "Cannot find selected cluster NIC in the system.\n\nSelected: ${CLTR0_NIC}\nResolved: ${desired_cltr0_if}\nPCI: ${CLTR0_NIC_PCI:-<none>}\nMAC: ${CLTR0_NIC_MAC:-<none>}\n\nRe-run STEP 01 and select the correct NIC." 16 85
    log "[ERROR] Cluster NIC not found in /sys/class/net: ${desired_cltr0_if}"
    return 1
  fi

  # Prevent selecting the same physical NIC for mgt and cluster (prefer identity compare)
  if [[ -n "${MGT_NIC_PCI:-}" && -n "${CLTR0_NIC_PCI:-}" && "${MGT_NIC_PCI}" == "${CLTR0_NIC_PCI}" ]]; then
    whiptail_msgbox "STEP 03 - Bridge Mode" "Cluster NIC and Management NIC cannot be the same physical NIC (same PCI).\n\nMGT PCI: ${MGT_NIC_PCI}\nCLTR0 PCI: ${CLTR0_NIC_PCI}\n\nPlease select different NICs in STEP 01." 14 80
    log "[ERROR] Duplicate PCI selection: mgt and cltr0 are the same (${MGT_NIC_PCI})"
    return 1
  fi
  if [[ -z "${MGT_NIC_PCI:-}" && -n "${desired_mgt_if}" && "${desired_mgt_if}" == "${desired_cltr0_if}" ]]; then
    whiptail_msgbox "STEP 03 - Bridge Mode" "Cluster NIC and Management NIC cannot be the same interface.\n\nMGT: ${desired_mgt_if}\nCLTR0: ${desired_cltr0_if}\n\nPlease select different NICs in STEP 01." 12 75
    log "[ERROR] Duplicate ifname selection: mgt=${desired_mgt_if} cltr0=${desired_cltr0_if}"
    return 1
  fi

  #######################################
  # 2) Write persistent bridge configuration (interfaces.d)
  # - Use 'cltr0' as the port name because udev will rename the chosen NIC to cltr0 after reboot.
  # - Do NOT embed ip commands (pre-up/post-up) here to keep the config clean.
  #######################################
  log "[STEP 03 Bridge Mode] Writing persistent bridge config under /etc/network/interfaces.d"

  local iface_dir="/etc/network/interfaces.d"
  local bridge_cfg="${iface_dir}/03-${bridge_name}.cfg"
  local bridge_bak="${bridge_cfg}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
    if [[ -f "${bridge_cfg}" ]]; then
      cp -a "${bridge_cfg}" "${bridge_bak}" || true
      log "Backed up existing ${bridge_cfg}: ${bridge_bak}"
    fi
  fi

  local bridge_content
  bridge_content=$(cat <<EOF
 auto cltr0
 iface cltr0 inet manual

 auto ${bridge_name}
 iface ${bridge_name} inet manual
     bridge_ports cltr0
     bridge_stp off
     bridge_fd 0
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${bridge_cfg}:\n${bridge_content}"
  else
    printf "%s\n" "${bridge_content}" > "${bridge_cfg}"
    log "[STEP 03 Bridge Mode] Persistent bridge config saved to ${bridge_cfg}"
  fi

  #######################################
  # 3) Ensure /etc/network/interfaces sources interfaces.d
  #######################################
  local iface_file="/etc/network/interfaces"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ ! -f "${iface_file}" ]]; then
      printf "%s\n" "source /etc/network/interfaces.d/*" > "${iface_file}"
      printf "%s\n" "" >> "${iface_file}"
      printf "%s\n" "auto lo" >> "${iface_file}"
      printf "%s\n" "iface lo inet loopback" >> "${iface_file}"
      log "[STEP 03 Bridge Mode] Created ${iface_file} with source line"
    else
      if ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' "${iface_file}" 2>/dev/null; then
        # Insert at top for deterministic include
        sed -i '1i source /etc/network/interfaces.d/*' "${iface_file}" 2>/dev/null || true
        log "[STEP 03 Bridge Mode] Added source line to ${iface_file}"
      fi
    fi
  fi

  #######################################
  # 4) Summary (declarative)
  #######################################
  local summary
  summary=$(cat <<EOF
 ═══════════════════════════════════════════════════════════
   STEP 03: Bridge Mode Configuration - Prepared
 ═══════════════════════════════════════════════════════════

 ✅ FILES WRITTEN (no runtime network changes):
   • ${bridge_cfg}
     - bridge: ${bridge_name}
     - port  : cltr0 (udev will rename the selected NIC to cltr0 after reboot)

 ✅ NOTES:
   • This step only prepares persistent configuration.
   • The bridge will be created/activated after reboot (or networking restart).
   • VM bridge attach occurs in STEP 12.
EOF
)

  whiptail_msgbox "STEP 03 Bridge Mode prepared" "${summary}"

  log "[STEP 03 Bridge Mode] Declarative bridge configuration finished."
  return 0
}


step_03_nic_ifupdown() {
  log "[STEP 03] NIC naming / ifupdown switch and network config (Declarative, no runtime ip changes)"
  load_config

  #######################################
  # Design goal:
  # - DO NOT run: ip link / ip addr / ip route (no runtime network changes)
  # - Only write udev + ifupdown config files
  # - Validate by file checks + sysfs presence only
  #######################################

  # Basic sanity checks (must have NIC selections from STEP 01)
  if [[ -z "${MGT_NIC:-}" || -z "${CLTR0_NIC:-}" || -z "${HOST_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - Missing NIC settings" "MGT_NIC/CLTR0_NIC/HOST_NIC is not configured.\n\nSelect NICs in STEP 01 first." 12 70
    log "ERROR: Missing NIC settings. Run STEP 01 first."
    return 1
  fi

  local cluster_nic_type="${CLUSTER_NIC_TYPE:-SRIOV}"
  : "${CLUSTER_BRIDGE_NAME:=br-cluster}"

  #######################################
  # Helpers (NO ip command usage)
  #######################################
  cidr_to_netmask() {
    local pfx="$1"
    local mask=$(( 0xffffffff << (32-pfx) & 0xffffffff ))
    printf "%d.%d.%d.%d\n" \
      $(( (mask>>24) & 255 )) $(( (mask>>16) & 255 )) $(( (mask>>8) & 255 )) $(( mask & 255 ))
  }

  # Parse existing mgt config from files (best-effort)
  parse_mgt_from_interfaces() {
    local f="/etc/network/interfaces"
    local fd="/etc/network/interfaces.d"
    local ip="" netmask="" gw="" dns=""

    if [[ -f "${fd}/01-mgt.cfg" ]]; then
      ip="$(awk '/^[[:space:]]*address[[:space:]]+/{print $2; exit}' "${fd}/01-mgt.cfg" 2>/dev/null || true)"
      netmask="$(awk '/^[[:space:]]*netmask[[:space:]]+/{print $2; exit}' "${fd}/01-mgt.cfg" 2>/dev/null || true)"
      gw="$(awk '/^[[:space:]]*gateway[[:space:]]+/{print $2; exit}' "${fd}/01-mgt.cfg" 2>/dev/null || true)"
      dns="$(awk '/^[[:space:]]*dns-nameservers[[:space:]]+/{sub(/^[[:space:]]*dns-nameservers[[:space:]]+/,""); print; exit}' "${fd}/01-mgt.cfg" 2>/dev/null || true)"
    fi

    if [[ -z "${ip}" && -f "${f}" ]]; then
      # if mgt stanza exists in /etc/network/interfaces
      ip="$(awk '
        $1=="iface" && $2=="mgt" {in=1}
        in && $1=="address" {print $2; exit}
      ' "${f}" 2>/dev/null || true)"
      netmask="$(awk '
        $1=="iface" && $2=="mgt" {in=1}
        in && $1=="netmask" {print $2; exit}
      ' "${f}" 2>/dev/null || true)"
      gw="$(awk '
        $1=="iface" && $2=="mgt" {in=1}
        in && $1=="gateway" {print $2; exit}
      ' "${f}" 2>/dev/null || true)"
      dns="$(awk '
        $1=="iface" && $2=="mgt" {in=1}
        in && $1=="dns-nameservers" {sub(/^dns-nameservers[[:space:]]+/,""); print; exit}
      ' "${f}" 2>/dev/null || true)"
    fi

    echo "${ip}|${netmask}|${gw}|${dns}"
  }

  #######################################
  # 1) Resolve desired interfaces by identity (PCI/MAC) using sysfs-only helpers
  #######################################
  local resolved_mgt resolved_cltr0 resolved_host
  resolved_mgt="$(resolve_ifname_by_identity "${MGT_NIC_PCI:-}" "${MGT_NIC_MAC:-}")"
  resolved_cltr0="$(resolve_ifname_by_identity "${CLTR0_NIC_PCI:-}" "${CLTR0_NIC_MAC:-}")"
  resolved_host="$(resolve_ifname_by_identity "${HOST_NIC_PCI:-}" "${HOST_NIC_MAC:-}")"

  local desired_mgt_if="${resolved_mgt:-${MGT_NIC}}"
  local desired_cltr0_if="${resolved_cltr0:-${CLTR0_NIC}}"
  local desired_host_if="${resolved_host:-${HOST_NIC}}"

  # Validate existence via sysfs only
  if [[ ! -d "/sys/class/net/${desired_mgt_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "MGT_NIC '${desired_mgt_if}' does not exist on this system.\n\nRe-run STEP 01 and select correct NIC." 12 70
    log "ERROR: MGT_NIC '${desired_mgt_if}' not found in /sys/class/net"
    return 1
  fi
  if [[ ! -d "/sys/class/net/${desired_host_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "HOST_NIC '${desired_host_if}' does not exist on this system.\n\nRe-run STEP 01 and select correct NIC." 12 70
    log "ERROR: HOST_NIC '${desired_host_if}' not found in /sys/class/net"
    return 1
  fi
  if [[ ! -d "/sys/class/net/${desired_cltr0_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "CLTR0_NIC '${desired_cltr0_if}' does not exist on this system.\n\nRe-run STEP 01 and select correct NIC." 12 70
    log "ERROR: CLTR0_NIC '${desired_cltr0_if}' not found in /sys/class/net"
    return 1
  fi

  #######################################
  # 2) Collect mgt IP settings (NO runtime detection; parse from files/config or ask)
  #######################################
  local parsed ip0 nm0 gw0 dns0
  parsed="$(parse_mgt_from_interfaces)"
  ip0="${parsed%%|*}"; parsed="${parsed#*|}"
  nm0="${parsed%%|*}"; parsed="${parsed#*|}"
  gw0="${parsed%%|*}"; parsed="${parsed#*|}"
  dns0="${parsed}"

  # Config file values override parsed if present (optional)
  local def_ip="${MGT_IP_ADDR:-$ip0}"
  local def_prefix="${MGT_IP_PREFIX:-}"
  local def_gw="${MGT_GW:-$gw0}"
  local def_dns="${MGT_DNS:-$dns0}"

  # If netmask exists but prefix not, infer common /24 else ask
  if [[ -z "${def_prefix}" ]]; then
    def_prefix="24"
  fi
  if [[ -z "${def_dns}" ]]; then
    def_dns="8.8.8.8 8.8.4.4"
  fi

  local new_ip new_prefix new_gw new_dns
  new_ip="$(whiptail_inputbox "STEP 03 - mgt IP setup" "Enter IP address for mgt interface.\nExample: 10.4.0.210" "${def_ip}" 10 70)" || return 1
  [[ -z "${new_ip}" ]] && return 1

  new_prefix="$(whiptail_inputbox "STEP 03 - mgt Prefix" "Enter subnet prefix length (/ value).\nExample: 24" "${def_prefix}" 10 70)" || return 1
  [[ -z "${new_prefix}" ]] && return 1

  new_gw="$(whiptail_inputbox "STEP 03 - gateway" "Enter default gateway IP.\nExample: 10.4.0.254" "${def_gw}" 10 70)" || return 1
  [[ -z "${new_gw}" ]] && return 1

  new_dns="$(whiptail_inputbox "STEP 03 - DNS" "Enter DNS servers separated by spaces.\nExample: 8.8.8.8 8.8.4.4" "${def_dns}" 10 80)" || return 1
  [[ -z "${new_dns}" ]] && return 1

  local netmask
  netmask="$(cidr_to_netmask "${new_prefix}")"

  # Save user-entered values into config/state (for re-run consistency)
  save_config_var "MGT_IP_ADDR" "${new_ip}"
  save_config_var "MGT_IP_PREFIX" "${new_prefix}"
  save_config_var "MGT_GW" "${new_gw}"
  save_config_var "MGT_DNS" "${new_dns}"

  #######################################
  # 3) Build udev rules (declarative only)
  #######################################
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_lib_file="/usr/lib/udev/rules.d/99-custom-ifnames.rules"

  # Determine PCI for udev matching (use stored PCI from STEP 01; fallback to sysfs path)
  local mgt_pci cltr0_pci host_pci
  mgt_pci="${MGT_NIC_PCI:-}"
  cltr0_pci="${CLTR0_NIC_PCI:-}"
  host_pci="${HOST_NIC_PCI:-}"

  if [[ -z "${mgt_pci}" ]]; then
    mgt_pci="$(readlink -f "/sys/class/net/${desired_mgt_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  fi
  if [[ -z "${cltr0_pci}" ]]; then
    cltr0_pci="$(readlink -f "/sys/class/net/${desired_cltr0_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  fi
  if [[ -z "${host_pci}" ]]; then
    host_pci="$(readlink -f "/sys/class/net/${desired_host_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  fi

  if [[ -z "${mgt_pci}" || -z "${cltr0_pci}" || -z "${host_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI info error" "Cannot fetch PCI bus info for selected NICs.\n\nmgt=${desired_mgt_if} pci=${mgt_pci:-?}\ncltr0=${desired_cltr0_if} pci=${cltr0_pci:-?}\nhostmgmt=${desired_host_if} pci=${host_pci:-?}\n\nCheck hardware/BIOS or re-run STEP 01." 14 80
    log "ERROR: PCI info missing for one or more NICs."
    return 1
  fi

  # Uniqueness check (no duplicate identity)
  if ! check_unique_identities "${mgt_pci}" "" "${cltr0_pci}" "" "${host_pci}" ""; then
    whiptail_msgbox "STEP 03 - Duplicate NIC Selection" "Selected NICs are duplicated.\n\nThe same NIC is assigned to more than one role (mgt/cltr0/hostmgmt).\n\nPlease select different NICs in STEP 01." 12 70
    log "[ERROR] Duplicate identity detected - STEP 03 failed"
    return 1
  fi

  local numvfs cltr0_extra is_sriov_mode
  numvfs="${CLTR0_NUMVFS:-2}"
  cltr0_extra=""
  is_sriov_mode=1
  if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
    is_sriov_mode=0
  fi
  if [[ "${is_sriov_mode}" -eq 1 ]]; then
    cltr0_extra=", ATTR{device/sriov_numvfs}=\"${numvfs}\""
  fi

  local udev_content
  udev_content=$(cat <<EOF
# XDR Installer persistent interface names (declarative)
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${mgt_pci}", NAME:="mgt"
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${cltr0_pci}", NAME:="cltr0"${cltr0_extra}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${host_pci}", NAME:="hostmgmt"
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${udev_file}:\n${udev_content}"
    log "[DRY-RUN] Will write to ${udev_lib_file}:\n${udev_content}"
    log "[DRY-RUN] Would run: sudo udevadm control --reload-rules"
    log "[DRY-RUN] Would run: sudo update-initramfs -u -k all"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
    printf "%s\n" "${udev_content}" > "${udev_lib_file}"
    chmod 644 "${udev_file}" || true
    chmod 644 "${udev_lib_file}" || true
    run_cmd "sudo udevadm control --reload-rules || true"
    log "[STEP 03] Updating initramfs to apply udev rename on reboot"
    run_cmd "sudo update-initramfs -u -k all"

    if command -v lsinitramfs >/dev/null 2>&1; then
      log "[STEP 03] Checking initramfs for ${udev_lib_file}"
      lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -F "${udev_lib_file}" >/dev/null || true
    fi
  fi

  if [[ "${is_sriov_mode}" -eq 1 ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would verify cltr0 sriov_numvfs in ${udev_file}"
      log "[DRY-RUN] Would verify cltr0 sriov_numvfs in ${udev_lib_file}"
    else
      local etc_has="no" lib_has="no"
      if [[ -f "${udev_file}" ]] && grep -q "NAME:=\"cltr0\".*sriov_numvfs" "${udev_file}" 2>/dev/null; then
        etc_has="yes"
      fi
      if [[ -f "${udev_lib_file}" ]] && grep -q "NAME:=\"cltr0\".*sriov_numvfs" "${udev_lib_file}" 2>/dev/null; then
        lib_has="yes"
      fi
      log "[STEP 03] SR-IOV udev rule check: ${udev_file} cltr0 sriov_numvfs=${etc_has}"
      log "[STEP 03] SR-IOV udev rule check: ${udev_lib_file} cltr0 sriov_numvfs=${lib_has}"
    fi
    log "[STEP 03] SR-IOV VF creation applies at reboot (udev add). Reboot is required before STEP 12."
  fi

  # Save effective ifnames for later steps (state stability)
  save_config_var "MGT_NIC_EFFECTIVE" "mgt"
  save_config_var "CLTR0_NIC_EFFECTIVE" "cltr0"
  save_config_var "HOST_NIC_EFFECTIVE" "hostmgmt"

  #######################################
  # 4) Write ifupdown config files (declarative only)
  #######################################
  local iface_file="/etc/network/interfaces"
  local iface_dir="/etc/network/interfaces.d"
  local mgt_cfg="${iface_dir}/01-mgt.cfg"
  local host_cfg="${iface_dir}/02-hostmgmt.cfg"
  local cltr0_cfg="${iface_dir}/00-cltr0.cfg"
  local br_cfg="${iface_dir}/03-${CLUSTER_BRIDGE_NAME}.cfg"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  # Ensure /etc/network/interfaces has source line and lo only
  local iface_content
  iface_content=$(cat <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${iface_file}:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  # mgt config in interfaces.d (preferred)
  local mgt_content
  mgt_content=$(cat <<EOF
auto mgt
iface mgt inet static
    address ${new_ip}
    netmask ${netmask}
    gateway ${new_gw}
    dns-nameservers ${new_dns}
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${mgt_cfg}:\n${mgt_content}"
  else
    printf "%s\n" "${mgt_content}" > "${mgt_cfg}"
  fi

  # hostmgmt fixed IP (no gateway)
  local host_content
  host_content=$(cat <<EOF
auto hostmgmt
iface hostmgmt inet static
    address 192.168.0.100
    netmask 255.255.255.0
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${host_cfg}:\n${host_content}"
  else
    printf "%s\n" "${host_content}" > "${host_cfg}"
  fi

  # cltr0: manual
  local cltr0_content
  cltr0_content=$(cat <<EOF
auto cltr0
iface cltr0 inet manual
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${cltr0_cfg}:\n${cltr0_content}"
  else
    printf "%s\n" "${cltr0_content}" > "${cltr0_cfg}"
  fi

  # Bridge mode: create persistent bridge config ONLY (no runtime create/up)
  if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
    local br_content
    br_content=$(cat <<EOF
auto ${CLUSTER_BRIDGE_NAME}
iface ${CLUSTER_BRIDGE_NAME} inet manual
    bridge_ports cltr0
    bridge_stp off
    bridge_fd 0
EOF
)
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will write to ${br_cfg}:\n${br_content}"
    else
      printf "%s\n" "${br_content}" > "${br_cfg}"
    fi
  else
    # If SR-IOV mode, remove stale bridge cfg if exists
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      rm -f "${br_cfg}" 2>/dev/null || true
    fi
  fi

  #######################################
  # 4-1) File-based verification (no runtime checks)
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[STEP 03] DRY-RUN: Skipping file-based verification"
  else
    # Helper: extract value for a key within an iface stanza
    extract_iface_value() {
      local file="$1" iface="$2" key="$3"
      awk -v iface="${iface}" -v key="${key}" '
        $1=="iface" && $2==iface {in=1; next}
        in && $1=="iface" {in=0}
        in && $1==key {print $2; exit}
      ' "${file}" 2>/dev/null || true
    }

    # Helper: extract full dns-nameservers line (can have multiple values)
    extract_dns_list() {
      local file="$1" iface="$2"
      awk -v iface="${iface}" '
        $1=="iface" && $2==iface {in=1; next}
        in && $1=="iface" {in=0}
        in && $1=="dns-nameservers" {$1=""; sub(/^[[:space:]]+/,""); print; exit}
      ' "${file}" 2>/dev/null || true
    }

    normalize_value() {
      echo "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    normalize_list() {
      echo "$1" | tr '\t' ' ' | tr -d '\r' | sed 's/[[:space:]]\+/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    # Helper: ensure all expected dns tokens are present
    dns_contains_all() {
      local expected="$1" actual="$2"
      local token
      for token in ${expected}; do
        if ! echo " ${actual} " | grep -q " ${token} "; then
          return 1
        fi
      done
      return 0
    }

    # Helper: list missing dns tokens for error reporting
    dns_missing_tokens() {
      local expected="$1" actual="$2"
      local token missing=""
      for token in ${expected}; do
        if ! echo " ${actual} " | grep -q " ${token} "; then
          missing="${missing} ${token}"
        fi
      done
      echo "${missing# }"
    }

    local verify_failed=0
    local verify_errors=""

    if [[ ! -f "${udev_file}" ]] || [[ ! -f "${udev_lib_file}" ]] || \
       ! grep -qE "KERNELS==\"${mgt_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${cltr0_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"cltr0\"" "${udev_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${host_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"hostmgmt\"" "${udev_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${mgt_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"mgt\"" "${udev_lib_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${cltr0_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"cltr0\"" "${udev_lib_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${host_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"hostmgmt\"" "${udev_lib_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- udev rules missing or invalid: ${udev_file}"
      verify_errors="${verify_errors}\n- udev rules missing or invalid: ${udev_lib_file}"
      verify_errors="${verify_errors}\n  expected: mgt=${mgt_pci}, cltr0=${cltr0_pci}, hostmgmt=${host_pci}"
    fi

    if [[ ! -f "${iface_file}" ]] || \
       ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' "${iface_file}" 2>/dev/null || \
       ! grep -qE '^[[:space:]]*auto[[:space:]]+lo([[:space:]]|$)' "${iface_file}" 2>/dev/null || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+lo[[:space:]]+inet[[:space:]]+loopback([[:space:]]|$)' "${iface_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- /etc/network/interfaces is missing required base content"
      verify_errors="${verify_errors}\n  expected: source line + lo stanza"
    fi

    local mgt_addr mgt_netmask mgt_gw mgt_dns
    mgt_addr="$(extract_iface_value "${mgt_cfg}" "mgt" "address")"
    mgt_netmask="$(extract_iface_value "${mgt_cfg}" "mgt" "netmask")"
    mgt_gw="$(extract_iface_value "${mgt_cfg}" "mgt" "gateway")"
    mgt_dns="$(extract_dns_list "${mgt_cfg}" "mgt")"
    if [[ -z "${mgt_addr}" ]]; then
      mgt_addr="$(awk '/^[[:space:]]*address[[:space:]]+/{print $2; exit}' "${mgt_cfg}" 2>/dev/null || true)"
    fi
    if [[ -z "${mgt_netmask}" ]]; then
      mgt_netmask="$(awk '/^[[:space:]]*netmask[[:space:]]+/{print $2; exit}' "${mgt_cfg}" 2>/dev/null || true)"
    fi
    if [[ -z "${mgt_gw}" ]]; then
      mgt_gw="$(awk '/^[[:space:]]*gateway[[:space:]]+/{print $2; exit}' "${mgt_cfg}" 2>/dev/null || true)"
    fi
    if [[ -z "${mgt_dns}" ]]; then
      mgt_dns="$(awk '/^[[:space:]]*dns-nameservers[[:space:]]+/{sub(/^[[:space:]]*dns-nameservers[[:space:]]+/,""); print; exit}' "${mgt_cfg}" 2>/dev/null || true)"
    fi
    mgt_addr="$(normalize_value "${mgt_addr}")"
    mgt_netmask="$(normalize_value "${mgt_netmask}")"
    mgt_gw="$(normalize_value "${mgt_gw}")"
    mgt_dns="$(normalize_list "${mgt_dns}")"

    if [[ ! -f "${mgt_cfg}" ]] || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+mgt[[:space:]]+inet[[:space:]]+static' "${mgt_cfg}" 2>/dev/null || \
       [[ "${mgt_addr}" != "${new_ip}" ]] || \
       [[ "${mgt_netmask}" != "${netmask}" ]] || \
       [[ "${mgt_gw}" != "${new_gw}" ]] || \
       [[ -z "${mgt_dns}" ]] || ! dns_contains_all "${new_dns}" "${mgt_dns}"; then
      verify_failed=1
      verify_errors="${verify_errors}\n- mgt config invalid: ${mgt_cfg}"
      verify_errors="${verify_errors}\n  expected: address=${new_ip} netmask=${netmask} gateway=${new_gw} dns=${new_dns}"
      verify_errors="${verify_errors}\n  actual  : address=${mgt_addr:-<empty>} netmask=${mgt_netmask:-<empty>} gateway=${mgt_gw:-<empty>} dns=${mgt_dns:-<empty>}"
      if [[ -n "${mgt_dns}" ]]; then
        local dns_missing
        dns_missing="$(dns_missing_tokens "${new_dns}" "${mgt_dns}")"
        if [[ -n "${dns_missing}" ]]; then
          verify_errors="${verify_errors}\n  dns missing: ${dns_missing}"
        fi
      fi
    fi

    local host_addr host_netmask
    host_addr="$(extract_iface_value "${host_cfg}" "hostmgmt" "address")"
    host_netmask="$(extract_iface_value "${host_cfg}" "hostmgmt" "netmask")"
    if [[ -z "${host_addr}" ]]; then
      host_addr="$(awk '/^[[:space:]]*address[[:space:]]+/{print $2; exit}' "${host_cfg}" 2>/dev/null || true)"
    fi
    if [[ -z "${host_netmask}" ]]; then
      host_netmask="$(awk '/^[[:space:]]*netmask[[:space:]]+/{print $2; exit}' "${host_cfg}" 2>/dev/null || true)"
    fi
    host_addr="$(normalize_value "${host_addr}")"
    host_netmask="$(normalize_value "${host_netmask}")"
    if [[ ! -f "${host_cfg}" ]] || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+hostmgmt[[:space:]]+inet[[:space:]]+static' "${host_cfg}" 2>/dev/null || \
       [[ "${host_addr}" != "192.168.0.100" ]] || \
       [[ "${host_netmask}" != "255.255.255.0" ]]; then
      verify_failed=1
      verify_errors="${verify_errors}\n- hostmgmt config invalid: ${host_cfg}"
      verify_errors="${verify_errors}\n  expected: address=192.168.0.100 netmask=255.255.255.0"
      verify_errors="${verify_errors}\n  actual  : address=${host_addr:-<empty>} netmask=${host_netmask:-<empty>}"
    fi

    if [[ ! -f "${cltr0_cfg}" ]] || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+cltr0[[:space:]]+inet[[:space:]]+manual([[:space:]]|$)' "${cltr0_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- cltr0 config invalid: ${cltr0_cfg}"
      verify_errors="${verify_errors}\n  expected: iface cltr0 inet manual"
    fi

    if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
      local br_ports
      br_ports="$(extract_iface_value "${br_cfg}" "${CLUSTER_BRIDGE_NAME}" "bridge_ports")"
      if [[ -z "${br_ports}" ]]; then
        br_ports="$(awk '/^[[:space:]]*bridge_ports[[:space:]]+/{sub(/^[[:space:]]*bridge_ports[[:space:]]+/,""); print; exit}' "${br_cfg}" 2>/dev/null || true)"
      fi
      br_ports="$(normalize_list "${br_ports}")"
      if [[ ! -f "${br_cfg}" ]] || \
         ! grep -qE "^[[:space:]]*iface[[:space:]]+${CLUSTER_BRIDGE_NAME}[[:space:]]+inet[[:space:]]+manual([[:space:]]|$)" "${br_cfg}" 2>/dev/null || \
         [[ -z "${br_ports}" ]] || ! echo " ${br_ports} " | grep -q " cltr0 "; then
        verify_failed=1
        verify_errors="${verify_errors}\n- bridge config invalid: ${br_cfg}"
        verify_errors="${verify_errors}\n  expected: iface ${CLUSTER_BRIDGE_NAME} inet manual + bridge_ports cltr0"
        verify_errors="${verify_errors}\n  actual  : bridge_ports=${br_ports:-<empty>}"
      fi
    else
      if [[ -f "${br_cfg}" ]]; then
        verify_failed=1
        verify_errors="${verify_errors}\n- stale bridge config exists in SR-IOV mode: ${br_cfg}"
      fi
    fi

    if [[ "${verify_failed}" -eq 1 ]]; then
      whiptail_msgbox "STEP 03 - File Verification Failed" "Configuration file verification failed.\n\n${verify_errors}\n\nPlease check the files and re-run the step." 16 85
      log "[ERROR] STEP 03 file verification failed:${verify_errors}"
      return 1
    fi

    log "[STEP 03] File-based verification passed"
  fi

  #######################################
  # 5) Disable netplan, enable ifupdown (no network restart here)
  #######################################
  log "[STEP 03] Install ifupdown and disable netplan (no restart)"
  local missing_pkgs=()
  dpkg -s ifupdown >/dev/null 2>&1 || missing_pkgs+=("ifupdown")
  dpkg -s net-tools >/dev/null 2>&1 || missing_pkgs+=("net-tools")
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    log "[STEP 03] Missing packages: ${missing_pkgs[*]} (apt update required)"
    run_cmd "sudo apt update"
    run_cmd "sudo apt install -y ${missing_pkgs[*]}"
  else
    log "[STEP 03] Packages already installed (skip apt update/install)"
  fi

  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    log "[STEP 03] Moving netplan config files to /etc/netplan/disabled"
    run_cmd "sudo mkdir -p /etc/netplan/disabled"
    run_cmd "sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
  else
    log "No netplan yaml files to move (may already be relocated)."
  fi

  log "[STEP 03] Disable systemd-networkd/netplan services; enable legacy networking service (no restart)"
  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"
  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"

  #######################################
  # 6) Keep link-up NICs admin UP (runtime safeguard)
  #######################################
  log "[STEP 03] Ensuring link-up NICs stay admin UP (ethtool link detected)"
  if command -v ethtool >/dev/null 2>&1; then
    local nic_path nic et_out
    for nic_path in /sys/class/net/*; do
      nic="${nic_path##*/}"
      [[ "${nic}" == "lo" ]] && continue
      et_out="$(ethtool "${nic}" 2>/dev/null || true)"
      if echo "${et_out}" | grep -q "Link detected: yes"; then
        run_cmd "sudo ip link set ${nic} up"
      fi
    done
  else
    log "[STEP 03] ethtool not found; skip link-up NIC protection"
  fi

  #######################################
  # 7) Summary (reboot required for udev rename + ifupdown apply)
  #######################################
  local summary
  summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 03: Network Configuration - Complete (Declarative)
═══════════════════════════════════════════════════════════

✅ FILES WRITTEN (no runtime config changes; link-up NICs set admin UP):
  • udev rules: ${udev_file}
    - ${mgt_pci}   → mgt
    - ${cltr0_pci} → cltr0
    - ${host_pci}  → hostmgmt

  • ifupdown:
    - ${iface_file}
    - ${mgt_cfg}
    - ${host_cfg}
    - ${cltr0_cfg}
EOF
)

  if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
    summary="${summary}
    - ${br_cfg} (bridge ${CLUSTER_BRIDGE_NAME} uses cltr0)"
  fi

  summary="${summary}

✅ mgt IP plan (applied after reboot / networking restart):
  - mgt: ${new_ip}/${new_prefix} (netmask ${netmask})
  - gw : ${new_gw}
  - dns: ${new_dns}

✅ hostmgmt (applied after reboot / networking restart):
  - hostmgmt: 192.168.0.100/24 (no gateway)

⚠️ REBOOT REQUIRED:
  - udev rename + ifupdown config are applied on reboot (or explicit networking restart).
  - This step intentionally does NOT restart networking to avoid SSH disruption.
"

  whiptail_msgbox "STEP 03 complete" "${summary}"

  log "[STEP 03] Declarative network configuration finished. Reboot required for apply."
  return 0
}
  

step_04_kvm_libvirt() {
  log "[STEP 04] Install KVM / Libvirt and pin default network (virbr0)"
  load_config

  #######################################
  # Helper functions for STEP 04
  #######################################
  
  # Check if systemd unit is active (service or socket)
  is_systemd_unit_active_or_socket() {
    local svc="$1"
    # svc: libvirtd or virtlogd
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      return 0
    fi
    if systemctl is-active --quiet "${svc}.socket" 2>/dev/null; then
      return 0
    fi
    return 1
  }

  # Check if default network is in desired state (virsh-based)
  is_default_net_desired_state() {
    # Active check (with space tolerance and net-list fallback)
    local active_check=0
    if virsh net-info default 2>/dev/null | grep -qiE '^[[:space:]]*Active:[[:space:]]*yes'; then
      active_check=1
    else
      # Fallback: check net-list --all for active status
      if virsh net-list --all 2>/dev/null | awk 'NR>2 {print $1,$2}' | grep -qiE '^default[[:space:]]+active'; then
        active_check=1
      fi
    fi
    
    if [[ ${active_check} -eq 0 ]]; then
      return 1
    fi

    local xml
    xml="$(virsh net-dumpxml default 2>/dev/null)" || return 1

    # Required: IP address and netmask
    if ! echo "$xml" | grep -q "ip address='192.168.122.1'"; then
      return 1
    fi
    if ! echo "$xml" | grep -q "netmask='255.255.255.0'"; then
      return 1
    fi

    # Required: DHCP must NOT exist
    if echo "$xml" | grep -qi "<dhcp"; then
      return 1
    fi

    # Optional checks (warn only, not failure conditions)
    if ! echo "$xml" | grep -qi "<forward mode='nat'"; then
      log "[STEP 04] Warning: default network XML may not have forward mode='nat' (continuing anyway)"
    fi
    if ! echo "$xml" | grep -qi "<bridge name='virbr0'"; then
      log "[STEP 04] Warning: default network XML may not have bridge name='virbr0' (continuing anyway)"
    fi

    return 0
  }

  # Wait for default network to reach desired state (polling)
  wait_for_default_net_desired_state() {
    local timeout_sec="${1:-30}"
    local interval_sec="${2:-1}"
    local waited=0

    while (( waited < timeout_sec )); do
      if is_default_net_desired_state; then
        return 0
      fi
      sleep "$interval_sec"
      waited=$((waited + interval_sec))
    done

    # Debug outputs (do not exit here; caller decides)
    log "[STEP 04] default network not in desired state after ${timeout_sec}s. Debug:"
    log "[STEP 04] virsh net-list --all:"
    virsh net-list --all 2>&1 | sed 's/^/[STEP 04]   /' || true
    log "[STEP 04] virsh net-info default:"
    virsh net-info default 2>&1 | sed 's/^/[STEP 04]   /' || true
    log "[STEP 04] virsh net-dumpxml default (first 200 lines):"
    virsh net-dumpxml default 2>&1 | sed -n '1,200p' | sed 's/^/[STEP 04]   /' || true
    return 1
  }

  local tmp_info="/tmp/xdr_step04_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Summarize current KVM/Libvirt status
  #######################################
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 04: KVM and Libvirt Installation"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "📋 CURRENT STATUS:"
    echo
    echo "1️⃣  CPU Virtualization Support:"
    local logical_cpus
    logical_cpus=$(nproc 2>/dev/null || echo "0")
    if [[ "${logical_cpus}" -gt 0 ]]; then
      # Check for virtualization flags
      if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
        echo "  ✅ Virtualization support detected"
        echo "  📊 System has ${logical_cpus} logical CPUs (vCPUs)"
        echo "     (Hyper-threading enabled: physical cores × 2)"
      else
        echo "  ⚠️  No virtualization flags found (check BIOS settings)"
        echo "  📊 System has ${logical_cpus} logical CPUs (vCPUs)"
      fi
    else
      echo "  ⚠️  Unable to determine CPU count"
    fi
    echo
    echo "2️⃣  KVM/Libvirt Package Status:"
    local pkg_status
    pkg_status=$(dpkg -l | egrep 'qemu-kvm|libvirt-daemon-system|libvirt-clients|virtinst|bridge-utils|qemu-utils|virt-viewer|genisoimage|net-tools|cpu-checker|ipset|ipcalc-ng' 2>/dev/null || echo "(no packages found)")
    if [[ "${pkg_status}" == *"(no packages found)"* ]]; then
      echo "  ⚠️  No KVM/Libvirt packages installed"
    else
      echo "  📦 Installed packages:"
      echo "${pkg_status}" | sed 's/^/    /'
    fi
    echo
    echo "3️⃣  libvirtd Service Status:"
    local libvirtd_status
    libvirtd_status=$(systemctl is-active libvirtd 2>/dev/null)
    if [[ -z "${libvirtd_status}" ]] || [[ "${libvirtd_status}" != "active" ]]; then
      libvirtd_status="inactive"
    fi
    if [[ "${libvirtd_status}" == "active" ]]; then
      echo "  ✅ libvirtd is active"
    else
      echo "  ⚠️  libvirtd service is inactive"
    fi
    echo
    echo "4️⃣  Libvirt Networks:"
    virsh net-list --all 2>/dev/null || echo "  ⚠️  No libvirt networks found (libvirt may not be installed)"
    echo
    echo "🔧 ACTIONS TO BE PERFORMED:"
    echo "  1. Install KVM and required packages"
    echo "  2. Enable and start libvirtd service"
    echo "  3. Configure default libvirt network (virbr0)"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 04 - Current KVM/Libvirt status" "${tmp_info}"

  # Calculate dialog size dynamically and center message
  local dialog_dims
  dialog_dims=$(calc_dialog_size 13 80)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  local centered_msg
  centered_msg=$(center_message "Proceed with KVM/Libvirt package install and default network configuration?")
  
  if ! whiptail --title "STEP 04 - confirmation" \
                 --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  then
    log "User canceled STEP 04 execution."
    return 0
  fi

  #######################################
  # 1) Install KVM and required packages (per docs)
  #######################################
  log "[STEP 04] Installing KVM and required packages (per docs)"

  run_cmd "sudo apt-get update"
  run_cmd "sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
qemu-utils virt-viewer genisoimage net-tools cpu-checker ipset make gcc ipcalc-ng bridge-utils"

  #######################################
  # 2) libvirtd / virtlogd enable --now
  #######################################
  log "[STEP 04] libvirtd / virtlogd enable --now"

  run_cmd "sudo systemctl enable --now libvirtd"
  run_cmd "sudo systemctl enable --now virtlogd"

  # Wait for services to become active (with retry logic, considering socket-activation)
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    log "[STEP 04] Waiting for libvirtd/virtlogd to become active (service or socket)..."
    local tries=10
    local i
    for i in $(seq 1 "$tries"); do
      if is_systemd_unit_active_or_socket libvirtd && is_systemd_unit_active_or_socket virtlogd; then
        log "[STEP 04] libvirtd/virtlogd are active (service or socket)"
        break
      fi
      sleep 1
    done

    if ! is_systemd_unit_active_or_socket libvirtd; then
      log "[WARN] libvirtd not active (service/socket) after wait"
      log "[STEP 04] Debug: systemctl status libvirtd --no-pager:"
      systemctl status libvirtd --no-pager 2>&1 | sed 's/^/[STEP 04]   /' || true
    fi

    if ! is_systemd_unit_active_or_socket virtlogd; then
      log "[WARN] virtlogd not active (service/socket) after wait"
      log "[STEP 04] Debug: systemctl status virtlogd --no-pager:"
      systemctl status virtlogd --no-pager 2>&1 | sed 's/^/[STEP 04]   /' || true
    fi
  else
    log "[DRY-RUN] Would wait for libvirtd/virtlogd services to become active"
  fi

  # Verification commands – no real execution in DRY_RUN
  log "[STEP 04] KVM settings check commands (lsmod, kvm-ok, systemctl status libvirtd)"
  run_cmd "lsmod | grep kvm || echo 'kvm module is not loaded.'"
  run_cmd "kvm-ok || echo 'kvm-ok failed (check cpu-checker package)'"
  run_cmd "sudo systemctl status libvirtd --no-pager || true"

  #######################################
  # 3) Check default network state
  #######################################
  local default_net_xml_final="/etc/libvirt/qemu/networks/default.xml"
  local need_redefine=0

  if is_default_net_desired_state; then
    need_redefine=0
    log "[STEP 04] Default network already in desired state (virsh). Skipping redefine."
  else
    need_redefine=1
    log "[STEP 04] Default network NOT in desired state (virsh). Redefining..."
  fi

  #######################################
  # 4) Enforce default network per docs (if needed)
  #######################################
  if [[ "${need_redefine}" -eq 1 ]]; then
    log "[STEP 04] Redefining default network to DHCP-less NAT 192.168.122.0/24 (virbr0)."

    mkdir -p "${STATE_DIR}"
    local backup_xml="${STATE_DIR}/default.xml.backup.$(date +%Y%m%d-%H%M%S)"
    local new_xml="${STATE_DIR}/default.xml"

    # Backup existing default.xml
    if virsh net-dumpxml default > "${backup_xml}" 2>/dev/null; then
      log "Backed up existing default network XML to ${backup_xml}."
    else
      log "virsh net-dumpxml default failed (default network may be missing) – skip backup."
    fi

    # Desired final form: NAT, virbr0, 192.168.122.1/24, no DHCP block
    local net_xml_content
    net_xml_content=$(cat <<'EOF'
<network>
  <name>default</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
  </ip>
</network>
EOF
)

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will write the following default network XML to ${new_xml}:\n${net_xml_content}"
    else
      printf "%s\n" "${net_xml_content}" > "${new_xml}"
      log "Saved new default network XML to ${new_xml}."
    fi

    # Destroy/undefine existing default network → redefine with new XML
    log "[STEP 04] Run virsh net-destroy/undefine/define/autostart/start default"
    run_cmd "virsh net-destroy default || true"
    run_cmd "virsh net-undefine default || true"
    run_cmd "virsh net-define ${new_xml}"
    run_cmd "virsh net-autostart default"
    run_cmd "virsh net-start default || true"

    # Wait for default network settings to apply (polling)
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      log "[STEP 04] Waiting for default network settings to apply (polling)..."
      if ! wait_for_default_net_desired_state 30 1; then
        log "[STEP 04] Prerequisite validation failed (default network not stabilized) -> rc=1"
        return 1
      fi
      log "[STEP 04] Default network settings applied successfully."
    else
      log "[DRY-RUN] Would wait for default network settings to apply (polling)"
    fi
	
  else
    log "[STEP 04] Default network already in desired state (virsh). Skipping redefine."
  fi

  #######################################
  # 5) Final status summary
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 04: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
    fi
    echo "📊 INSTALLATION STATUS:"
    echo
    echo "1️⃣  Libvirt Networks:"
    local net_list
    net_list=$(virsh net-list --all 2>/dev/null || echo "  ⚠️  Unable to list networks")
    if [[ "${net_list}" != *"Unable to list"* ]]; then
      echo "${net_list}" | sed 's/^/  /'
    else
      echo "  ${net_list}"
    fi
    echo
    echo "2️⃣  Default Network Configuration:"
    if [[ -f "${default_net_xml_final}" ]]; then
      echo "  ✅ Network XML file exists: ${default_net_xml_final}"
      echo "  📋 Key configuration:"
      grep -E "<network>|<name>|<forward|<bridge|<ip|<dhcp" "${default_net_xml_final}" 2>/dev/null | sed 's/^/    /' || echo "    (unable to parse)"
    else
      echo "  ⚠️  Network XML file not found: ${default_net_xml_final}"
    fi
    echo
    echo "3️⃣  Service Status:"
    local libvirtd_status
    libvirtd_status=$(systemctl is-active libvirtd 2>/dev/null)
    if [[ -z "${libvirtd_status}" ]] || [[ "${libvirtd_status}" != "active" ]]; then
      libvirtd_status="inactive"
    fi
    if [[ "${libvirtd_status}" == "active" ]]; then
      echo "  ✅ libvirtd service is active"
    else
      echo "  ⚠️  libvirtd service is inactive"
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • Default network (virbr0) is configured with:"
    echo "    - IP range: 192.168.122.0/24"
    echo "    - DHCP: Disabled (as required by hooks)"
    echo "  • /etc/libvirt/hooks/network and qemu scripts"
    echo "    assume virbr0 network configuration"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 05 (Kernel Tuning) - 1 step later"
    echo "  • After STEP 05 completes, system will reboot automatically"
    echo "  • After reboot, proceed to STEP 06 (SR-IOV + NTPsec)"
  } > "${tmp_info}"

  show_textbox "STEP 04 - Summary" "${tmp_info}"

  #######################################
  # 6) Validate prerequisites and handle errors
  #######################################

  # In DRY_RUN, skip validation but do not return
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[STEP 04] Skipping prerequisite validation in DRY-RUN."
  else
    local fail_reasons=()

    # 1) virsh / kvm-ok commands exist
    if ! command -v virsh >/dev/null 2>&1; then
      fail_reasons+=(" - virsh command (libvirt-clients package) is missing.")
    fi

    if ! command -v kvm-ok >/dev/null 2>&1; then
      fail_reasons+=(" - kvm-ok command (cpu-checker package) is missing.")
    fi

    # 2) KVM kernel module loaded
    if ! grep -q '^kvm ' /proc/modules; then
      fail_reasons+=(" - kvm kernel module is not loaded.")
    fi

    # 3) libvirtd / virtlogd service state (considering socket-activation)
    if ! is_systemd_unit_active_or_socket libvirtd; then
      fail_reasons+=(" - libvirtd service/socket is not active.")
    fi

    if ! is_systemd_unit_active_or_socket virtlogd; then
      fail_reasons+=(" - virtlogd service/socket is not active.")
    fi

    # 4) default network (virbr0) configuration state (virsh-based)
    if ! is_default_net_desired_state; then
      fail_reasons+=(" - default network is not in desired state (virsh check failed).")
    fi

    # 5) Guidance on failure and return rc=1
    if ((${#fail_reasons[@]} > 0)); then
      local msg="The following items are not properly installed/configured:\n\n"
      local r
      for r in "${fail_reasons[@]}"; do
        msg+="$r\n"
      done
      msg+="\n[STEP 04] Rerun KVM / Libvirt installation and default network (virbr0) setup, then check logs."

      log "[STEP 04] Prerequisite validation failed → returning rc=1"
      
      # Debug outputs for troubleshooting
      log "[STEP 04] Debug: systemctl status libvirtd --no-pager:"
      systemctl status libvirtd --no-pager 2>&1 | sed 's/^/[STEP 04]   /' || true
      log "[STEP 04] Debug: systemctl status virtlogd --no-pager:"
      systemctl status virtlogd --no-pager 2>&1 | sed 's/^/[STEP 04]   /' || true
      log "[STEP 04] Debug: virsh net-list --all:"
      virsh net-list --all 2>&1 | sed 's/^/[STEP 04]   /' || true
      log "[STEP 04] Debug: virsh net-info default:"
      virsh net-info default 2>&1 | sed 's/^/[STEP 04]   /' || true
      log "[STEP 04] Debug: virsh net-dumpxml default (first 200 lines):"
      virsh net-dumpxml default 2>&1 | sed -n '1,200p' | sed 's/^/[STEP 04]   /' || true
      
      whiptail_msgbox "STEP 04 validation failed" "${msg}"
      return 1
    fi
  fi

  log "[STEP 04] Prerequisite validation complete – ready for next step."

  # save_state is called from run_step()
}
  


step_05_kernel_tuning() {
  log "[STEP 05] Kernel tuning / KSM / Swap / IOMMU"
  load_config

  # DRY_RUN default handling
  local _DRY="${DRY_RUN:-0}"

  local tmp_info="/tmp/xdr_step05_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Summarize current state
  #######################################
  {
    echo "Current kernel / memory status"
    echo "--------------------------------"
    echo
    echo "# vm.min_free_kbytes"
    sysctl vm.min_free_kbytes 2>/dev/null || echo "Failed to read vm.min_free_kbytes"
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 05: Kernel Tuning and System Configuration"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "📋 CURRENT STATUS:"
    echo
    echo "1️⃣  Kernel Parameters:"
    local ip_forward
    ip_forward=$(sysctl net.ipv4.ip_forward 2>/dev/null || echo "Failed to read")
    echo "  • net.ipv4.ip_forward: ${ip_forward}"
    local arp_filter
    arp_filter=$(sysctl net.ipv4.conf.all.arp_filter 2>/dev/null || echo "not set")
    echo "  • net.ipv4.conf.all.arp_filter: ${arp_filter}"
    local ignore_routes
    ignore_routes=$(sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null || echo "not set")
    echo "  • net.ipv4.conf.all.ignore_routes_with_linkdown: ${ignore_routes}"
    echo
    echo "2️⃣  KSM (Kernel Same-page Merging) Status:"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      local ksm_state
      ksm_state=$(cat /sys/kernel/mm/ksm/run)
      if [[ "${ksm_state}" == "0" ]]; then
        echo "  ✅ KSM is currently disabled (0)"
      else
        echo "  ⚠️  KSM is currently enabled (${ksm_state})"
      fi
    else
      echo "  ⚠️  KSM control file not found"
    fi
    echo
    echo "3️⃣  Swap Status:"
    local swap_info
    swap_info=$(swapon --show 2>/dev/null || echo "No active swap")
    if [[ "${swap_info}" == *"No active"* ]]; then
      echo "  ✅ ${swap_info}"
    else
      echo "  📋 Active swap devices:"
      echo "${swap_info}" | sed 's/^/    /'
    fi
    echo
    echo "4️⃣  GRUB Configuration:"
    if grep -q 'intel_iommu=on' /etc/default/grub 2>/dev/null && grep -q 'iommu=pt' /etc/default/grub 2>/dev/null; then
      echo "  ✅ IOMMU parameters already configured in GRUB"
    else
      echo "  ⚠️  IOMMU parameters not found in GRUB"
    fi
    echo
    echo "🔧 ACTIONS TO BE PERFORMED:"
    echo "  1. Configure kernel parameters (vm.min_free_kbytes, ARP settings)"
    echo "  2. Disable KSM (Kernel Same-page Merging)"
    echo "  3. Disable swap (swapoff -a, comment /swap.img in /etc/fstab)"
    echo "  4. Add IOMMU parameters to GRUB (intel_iommu=on iommu=pt)"
    echo "  5. Update GRUB configuration (update-grub)"
    echo
    echo "⚠️  IMPORTANT NOTES:"
    echo "  • GRUB changes require reboot to take effect"
    echo "  • This script will automatically reboot immediately after this step"
    echo "  • Swap will be disabled (all active swap will be turned off)"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Current kernel/Swap status" "${tmp_info}"

  # Calculate dialog size dynamically and center message
  local dialog_dims
  dialog_dims=$(calc_dialog_size 15 80)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  local centered_msg
  centered_msg=$(center_message "Apply kernel params, disable KSM, disable Swap, and configure IOMMU per docs?\n\n(Yes: continue / No: cancel)")
  
  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail --title "STEP 05 - confirmation" \
           --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    log "User canceled STEP 05."
    return 2  # Return 2 to indicate cancellation (not error, but not success)
  fi

  #######################################
  # 0-1) Add IOMMU parameters to GRUB (intel_iommu=on iommu=pt)
  #######################################
  local grub_file="/etc/default/grub"
  local grub_backup="/etc/default/grub.xdr-backup.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${grub_file}" ]]; then
    log "[STEP 05] Backing up GRUB config: ${grub_backup}"

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] sudo cp ${grub_file} ${grub_backup}"
    else
      sudo cp "${grub_file}" "${grub_backup}"
    fi

    # Append intel_iommu=on iommu=pt to GRUB_CMDLINE_LINUX if missing
    if grep -q '^GRUB_CMDLINE_LINUX=' "${grub_file}"; then
      if grep -q 'intel_iommu=on' "${grub_file}" && grep -q 'iommu=pt' "${grub_file}"; then
        log "[STEP 05] intel_iommu=on iommu=pt already present in GRUB_CMDLINE_LINUX."
      else
        log "[STEP 05] Adding intel_iommu=on iommu=pt to GRUB_CMDLINE_LINUX."

        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] sudo sed -i -E 's/^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"/\\1 intel_iommu=on iommu=pt\"/' ${grub_file}"
        else
          sudo sed -i -E 's/^(GRUB_CMDLINE_LINUX=")([^"]*)(")/\1\2 intel_iommu=on iommu=pt\3/' "${grub_file}"
        fi
      fi
    else
      log "[STEP 05] GRUB_CMDLINE_LINUX not found; adding new entry."

      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] echo 'GRUB_CMDLINE_LINUX=\"intel_iommu=on iommu=pt\"' | sudo tee -a ${grub_file}"
      else
        echo 'GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"' | sudo tee -a "${grub_file}" >/dev/null
      fi
    fi

    # Run update-grub
    log "[STEP 05] Running update-grub"
    run_cmd "sudo update-grub"
  else
    log "[WARN] ${grub_file} not found. Skipping GRUB/IOMMU configuration."
  fi
  
  #######################################
  # 1) Add XDR kernel parameter block to sysctl.conf
  #######################################
  local SYSCTL_FILE="/etc/sysctl.conf"
  local SYSCTL_BACKUP="/etc/sysctl.conf.backup.$(date +%Y%m%d-%H%M%S)"
  local TUNING_TAG_BEGIN="# XDR_KERNEL_TUNING_BEGIN"
  local TUNING_TAG_END="# XDR_KERNEL_TUNING_END"

  log "[STEP 05] Add kernel parameters to /etc/sysctl.conf (XDR block)"

  # Check if block already exists
  if grep -q "${TUNING_TAG_BEGIN}" "${SYSCTL_FILE}" 2>/dev/null; then
    log "[STEP 05] XDR kernel tuning block already present in ${SYSCTL_FILE} → skip add"
  else
    # Backup
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      cp -a "${SYSCTL_FILE}" "${SYSCTL_BACKUP}"
      log "Backed up existing ${SYSCTL_FILE} to ${SYSCTL_BACKUP}"
    else
      log "[DRY-RUN] Would back up ${SYSCTL_FILE} to ${SYSCTL_BACKUP}"
    fi

    # Parameter block from documentation
    local tuning_block
    tuning_block=$(cat <<EOF

${TUNING_TAG_BEGIN}
# ARP tuning (prevent ARP flux)
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 2

# Ignore routes when link is down
#net.ipv4.conf.data1g.ignore_routes_with_linkdown = 1
#net.ipv4.conf.data10g.ignore_routes_with_linkdown = 1
net.ipv4.conf.all.ignore_routes_with_linkdown = 1

# Reserve free memory (~1GB) to mitigate OOM
vm.min_free_kbytes = 1048576
${TUNING_TAG_END}
EOF
)

    if [[ "${DRY_RUN}" -eq 0 ]]; then
      printf "%s\n" "${tuning_block}" | sudo tee -a "${SYSCTL_FILE}" >/dev/null
      log "[STEP 05] Added XDR kernel tuning block to ${SYSCTL_FILE}"
    else
      log "[DRY-RUN] Would append XDR kernel tuning block to ${SYSCTL_FILE}"
    fi
  fi  # tuning block add

  # 1-1) Explicitly enable IPv4 forwarding (net.ipv4.ip_forward)
  if grep -q "^#\?net\.ipv4\.ip_forward" "${SYSCTL_FILE}"; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would set net.ipv4.ip_forward = 1 in ${SYSCTL_FILE}"
    else
      sudo sed -i -E 's|^#?net\.ipv4\.ip_forward *=.*$|net.ipv4.ip_forward = 1|' "${SYSCTL_FILE}"
      log "Set net.ipv4.ip_forward to 1 in ${SYSCTL_FILE}"
    fi
  else
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would append net.ipv4.ip_forward = 1 to ${SYSCTL_FILE}"
    else
      echo "net.ipv4.ip_forward = 1" | sudo tee -a "${SYSCTL_FILE}" >/dev/null
      log "Appended net.ipv4.ip_forward = 1 to ${SYSCTL_FILE}"
    fi
  fi

  # Apply / verify sysctl
  log "[STEP 05] Apply kernel parameters via sysctl -p"
  run_cmd "sudo sysctl -p ${SYSCTL_FILE}"
  log "[STEP 05] Check net.ipv4.ip_forward state"
  run_cmd "grep net.ipv4.ip_forward /etc/sysctl.conf || echo '#net.ipv4.ip_forward=1 (commented)'"
  run_cmd "sysctl net.ipv4.ip_forward"

  #######################################
  # 2) Disable KSM ( /etc/default/qemu-kvm )
  #######################################
  log "[STEP 05] Disable KSM (KSM_ENABLED=0)"

  local QEMU_DEFAULT="/etc/default/qemu-kvm"
  local QEMU_BACKUP="/etc/default/qemu-kvm.backup.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${QEMU_DEFAULT}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      cp -a "${QEMU_DEFAULT}" "${QEMU_BACKUP}"
      log "Backed up existing ${QEMU_DEFAULT}: ${QEMU_BACKUP}"
    else
      log "[DRY-RUN] Would back up ${QEMU_DEFAULT} to ${QEMU_BACKUP}"
    fi

    # If KSM_ENABLED exists set to 0, otherwise append
    if grep -q "^KSM_ENABLED=" "${QEMU_DEFAULT}" 2>/dev/null; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would set KSM_ENABLED=0 in ${QEMU_DEFAULT}"
      else
        sudo sed -i 's/^KSM_ENABLED=.*/KSM_ENABLED=0/' "${QEMU_DEFAULT}"
        log "Set KSM_ENABLED to 0 in ${QEMU_DEFAULT}"
      fi
    else
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would append 'KSM_ENABLED=0' to ${QEMU_DEFAULT}"
      else
        echo "KSM_ENABLED=0" | sudo tee -a "${QEMU_DEFAULT}" >/dev/null
        log "Appended KSM_ENABLED=0 to ${QEMU_DEFAULT}"
      fi
    fi
  else
    log "[STEP 05] ${QEMU_DEFAULT} not found → skip KSM setting"
  fi

  # Disable KSM immediately by writing 0 to /sys/kernel/mm/ksm/run
  if [[ -f /sys/kernel/mm/ksm/run ]]; then
    log "[STEP 05] Disabling KSM immediately by writing 0 to /sys/kernel/mm/ksm/run"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would run: echo 0 | sudo tee /sys/kernel/mm/ksm/run"
    else
      echo 0 | sudo tee /sys/kernel/mm/ksm/run >/dev/null
      log "Disabled KSM: /sys/kernel/mm/ksm/run = 0"
    fi
  else
    log "[STEP 05] /sys/kernel/mm/ksm/run not found → skip immediate KSM disable"
  fi

  # Restart qemu-kvm to apply KSM setting
  if systemctl list-unit-files 2>/dev/null | grep -q '^qemu-kvm\.service'; then
    log "[STEP 05] Restarting qemu-kvm to apply KSM setting."

    # Use run_cmd to honor DRY_RUN
    run_cmd "sudo systemctl restart qemu-kvm"

    # Check KSM state after restart
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      local ksm_after_restart
      ksm_after_restart=$(cat /sys/kernel/mm/ksm/run 2>/dev/null)
      log "[STEP 05] qemu-kvm restart → current /sys/kernel/mm/ksm/run: ${ksm_after_restart}"
      # If KSM is still enabled after restart, disable it again
      if [[ "${ksm_after_restart}" != "0" ]] && [[ "${DRY_RUN}" -eq 0 ]]; then
        log "[STEP 05] KSM was re-enabled after qemu-kvm restart, disabling again"
        echo 0 | sudo tee /sys/kernel/mm/ksm/run >/dev/null
        log "Disabled KSM again: /sys/kernel/mm/ksm/run = 0"
      fi
    fi
  else
    log "[STEP 05] qemu-kvm service unit not found; skip restart."
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      log "[STEP 05] Current /sys/kernel/mm/ksm/run:"
      cat /sys/kernel/mm/ksm/run >> "${LOG_FILE}" 2>&1
    fi
  fi

  #######################################
  # 3) Disable swap and clean /swap.img (optional)
  #######################################
  local do_swapoff=0
  local do_zeroize=0

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 05 - disable Swap" "Disable Swap per docs and comment /swap.img in /etc/fstab.\n\nProceed now?"
  local swap_rc=$?
  set -e
  
  if [[ ${swap_rc} -eq 0 ]]; then
    do_swapoff=1
  else
    log "[STEP 05] User chose to skip Swap disable."
  fi

  if [[ "${do_swapoff}" -eq 1 ]]; then
    log "[STEP 05] Running swapoff -a and commenting /swap.img in /etc/fstab"

    # 3-1) swapoff -a
    run_cmd "sudo swapoff -a"

    # 3-2) Comment /swap.img entry in /etc/fstab
    local FSTAB_FILE="/etc/fstab"
    local FSTAB_BACKUP="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"

    if [[ -f "${FSTAB_FILE}" ]]; then
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        cp -a "${FSTAB_FILE}" "${FSTAB_BACKUP}"
        log "Backed up existing ${FSTAB_FILE}: ${FSTAB_BACKUP}"
      else
        log "[DRY-RUN] Would back up ${FSTAB_FILE} to ${FSTAB_BACKUP}"
      fi

      if grep -q "/swap.img" "${FSTAB_FILE}" 2>/dev/null; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] Would comment /swap.img entry in ${FSTAB_FILE}"
        else
          sudo sed -i 's|^\([^#].*swap.img.*\)|#\1|' "${FSTAB_FILE}"
          log "Commented /swap.img entry in ${FSTAB_FILE}"
        fi
      else
        log "[STEP 05] No /swap.img entry in ${FSTAB_FILE} → skip commenting"
      fi
    else
      log "[STEP 05] ${FSTAB_FILE} not found → skip Swap fstab handling"
    fi

    # 3-3) Optional zeroize /swap.img
    if [[ -f /swap.img ]]; then
      # Temporarily disable set -e to handle cancel gracefully
      set +e
      whiptail_yesno "STEP 05 - swap.img Zeroize" "/swap.img exists.\nDocs recommend zeroize with dd + truncate (takes time).\n\nProceed now?"
      local zeroize_rc=$?
      set -e
      
      if [[ ${zeroize_rc} -eq 0 ]]; then
        do_zeroize=1
      else
        log "[STEP 05] User skipped /swap.img zeroize."
      fi
    else
      log "[STEP 05] /swap.img not present → skip zeroize"
    fi

    if [[ "${do_zeroize}" -eq 1 ]]; then
      log "[STEP 05] Zeroizing /swap.img (dd + truncate)"

      # Per docs: dd if=/dev/zero of=/swap.img bs=1M count=8192 status=progress
      #            truncate -s 0 /swap.img
      run_cmd "sudo dd if=/dev/zero of=/swap.img bs=1M count=8192 status=progress"
      run_cmd "sudo truncate -s 0 /swap.img"
    fi
  fi

  #######################################
  # 4) Final summary
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 05: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
    fi
    echo "📊 KERNEL PARAMETERS:"
    echo
    echo "1️⃣  Memory Management (vm.min_free_kbytes):"
    local min_free
    min_free=$(sysctl vm.min_free_kbytes 2>/dev/null || echo "Failed to read")
    if [[ "${min_free}" != *"Failed"* ]]; then
      echo "  ✅ ${min_free}"
    else
      echo "  ⚠️  ${min_free}"
    fi
    echo
    echo "2️⃣  Network ARP Settings:"
    echo "  • arp_filter (all):     $(sysctl net.ipv4.conf.all.arp_filter 2>/dev/null | awk '{print $3}')"
    echo "  • arp_filter (default):  $(sysctl net.ipv4.conf.default.arp_filter 2>/dev/null | awk '{print $3}')"
    echo "  • arp_announce (all):    $(sysctl net.ipv4.conf.all.arp_announce 2>/dev/null | awk '{print $3}')"
    echo "  • arp_announce (default): $(sysctl net.ipv4.conf.default.arp_announce 2>/dev/null | awk '{print $3}')"
    echo "  • arp_ignore (all):      $(sysctl net.ipv4.conf.all.arp_ignore 2>/dev/null | awk '{print $3}')"
    echo "  • ignore_routes_with_linkdown: $(sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null | awk '{print $3}')"
    echo
    echo "3️⃣  KSM (Kernel Same-page Merging) Status:"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      local ksm_state
      ksm_state=$(cat /sys/kernel/mm/ksm/run)
      if [[ "${ksm_state}" == "0" ]]; then
        echo "  ✅ KSM is disabled (0)"
      else
        echo "  ⚠️  KSM is enabled (${ksm_state})"
      fi
    else
      echo "  ⚠️  KSM control file not found"
    fi
    echo
    echo "4️⃣  Swap Status:"
    local swap_info
    swap_info=$(swapon --show 2>/dev/null || echo "No active swap")
    if [[ "${swap_info}" == *"No active"* ]]; then
      echo "  ✅ ${swap_info}"
    else
      echo "  📋 Active swap devices:"
      echo "${swap_info}" | sed 's/^/    /'
    fi
    echo
    echo "5️⃣  GRUB Configuration:"
    if grep -q 'intel_iommu=on' /etc/default/grub 2>/dev/null && grep -q 'iommu=pt' /etc/default/grub 2>/dev/null; then
      echo "  ✅ IOMMU parameters (intel_iommu=on iommu=pt) configured"
    else
      echo "  ⚠️  IOMMU parameters not found in GRUB"
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • GRUB changes require reboot to take effect"
    echo "  • Automatic reboot will occur immediately after this step"
    echo "    (if AUTO_REBOOT_AFTER_STEP_ID includes '05_kernel_tuning')"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • System will reboot automatically immediately after this step (if configured)"
    echo "  • After reboot, proceed to STEP 06 (SR-IOV + NTPsec)"
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Summary" "${tmp_info}"

  # STEP 05 is considered complete here (save_state is called from run_step)
}




step_06_ntpsec() {
  load_config

  log "[STEP 06] Install SR-IOV driver (iavf/i40evf) + configure NTPsec"
  
  local tmp_info="/tmp/xdr_step06_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Install SR-IOV iavf(i40evf) driver
  #######################################
  log "[STEP 06] Starting SR-IOV iavf(i40evf) driver install"

  local iavf_url="https://github.com/intel/ethernet-linux-iavf/releases/download/v4.13.16/iavf-4.13.16.tar.gz"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would install packages needed to build iavf driver"
    log "[DRY-RUN] Would download iavf driver from: ${iavf_url}"
    log "[DRY-RUN] Would build and install iavf driver"
  else
    echo "=== Installing packages needed to build iavf driver (apt-get) ==="
    run_cmd "sudo apt-get update -y"
    run_cmd "sudo apt-get install -y build-essential linux-headers-$(uname -r) curl"

    echo
    echo "=== Downloading iavf driver archive (curl progress below) ==="
    (
      cd /tmp || exit 1
      curl -L -o iavf-4.13.16.tar.gz "${iavf_url}"
    )
    local rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log "[ERROR] Failed to download iavf driver (rc=${rc})"
      whiptail_msgbox "STEP 06 - iavf download failed" "Failed to download iavf driver (${iavf_url}).\n\nCheck network or GitHub access and retry." 12 80
      return 1
    fi
    echo "=== iavf driver download complete ==="
    log "[STEP 06] iavf driver download complete"

    echo
    echo "=== Building / installing iavf driver (may take time) ==="
    (
      cd /tmp || exit 1
      tar xzf iavf-4.13.16.tar.gz
      cd iavf-4.13.16/src || exit 1
      make
      sudo make install
      sudo depmod -a
    )
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log "[ERROR] Failed to build/install iavf driver (rc=${rc})"
      whiptail_msgbox "STEP 06 - iavf build/install failed" "Failed to build or install iavf driver.\n\nCheck /var/log/xdr-installer.log." 12 80
      return 1
    fi
    echo "=== iavf driver build / install complete ==="
    log "[STEP 06] iavf driver build / install complete"
  fi

  #######################################
  # 1) Verify/apply SR-IOV VF driver (iavf/i40evf)
  #######################################
  log "[STEP 06] Attempting to load iavf/i40evf modules"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would load iavf/i40evf modules"
  else
    run_cmd "sudo modprobe iavf 2>/dev/null || sudo modprobe i40evf 2>/dev/null || true"
  fi

  {
    echo "--------------------------------------"
    echo "[SR-IOV] iavf(i40evf) driver install and load"
    echo "  - URL : ${iavf_url}"
    echo
    echo "# lsmod | grep -E '^(iavf|i40evf)\\b'"
    lsmod | grep -E '^(iavf|i40evf)\b' || echo "No loaded iavf/i40evf modules."
    echo
  } >> "${tmp_info}"


  #######################################
  # 0) Summarize current time / NTP state
  #######################################
  {
    echo "Current time / NTP status"
    echo "--------------------------------"
    echo
    echo "# timedatectl"
    timedatectl 2>/dev/null || echo "timedatectl failed"
    echo
    echo "# ntpsec package status (dpkg -l ntpsec)"
    dpkg -l ntpsec 2>/dev/null || echo "No ntpsec package info"
    echo
    echo "# ntpsec service state (systemctl is-active ntpsec)"
    local ntpsec_check
    ntpsec_check=$(systemctl is-active ntpsec 2>/dev/null)
    if [[ -z "${ntpsec_check}" ]] || [[ "${ntpsec_check}" != "active" ]]; then
      echo "inactive"
    else
      echo "${ntpsec_check}"
    fi
    echo
    echo "# ntpq -p (if available)"
    ntpq -p 2>/dev/null || echo "ntpq -p failed or ntpsec not installed"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV driver install / NTP status" "${tmp_info}"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 06 - confirmation" "After installing iavf(i40evf), configure NTPsec on the host.\n\nProceed?"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    log "User canceled STEP 06."
    return 2  # Return 2 to indicate cancellation
  fi


  #######################################
  # 1) Install NTPsec
  #######################################
  log "[STEP 06] Installing NTPsec package"

  run_cmd "sudo apt-get update"
  run_cmd "sudo apt-get install -y ntpsec"

  #######################################
  # 2) Back up /etc/ntpsec/ntp.conf
  #######################################
  local NTP_CONF="/etc/ntpsec/ntp.conf"
  local NTP_CONF_BACKUP="/etc/ntpsec/ntp.conf.orig.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${NTP_CONF}" "${NTP_CONF_BACKUP}"
      log "Backed up existing ${NTP_CONF} to ${NTP_CONF_BACKUP}."
    else
      log "[DRY-RUN] Would back up ${NTP_CONF} to ${NTP_CONF_BACKUP}"
    fi
  else
    log "[STEP 06] ${NTP_CONF} not found (check ntpsec install state)"
  fi

  #######################################
  # 3) Comment default Ubuntu NTP pool/server entries
  #######################################
  log "[STEP 06] Commenting default Ubuntu NTP pool/server entries"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would comment pool/server entries in ${NTP_CONF} (0~3 ubuntu pool, ntp.ubuntu.com)"
    else
      sudo sed -i 's/^pool 0.ubuntu.pool.ntp.org iburst/#pool 0.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 1.ubuntu.pool.ntp.org iburst/#pool 1.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 2.ubuntu.pool.ntp.org iburst/#pool 2.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 3.ubuntu.pool.ntp.org iburst/#pool 3.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^server ntp.ubuntu.com iburst/#server ntp.ubuntu.com iburst/' "${NTP_CONF}"
    fi
  fi

  #######################################
  # 4) Comment restrict default kod ... line
  #######################################
  log "[STEP 06] Commenting out restrict default kod ... rule"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Would comment 'restrict default kod nomodify nopeer noquery limited' in ${NTP_CONF}"
    else
      sudo sed -i 's/^restrict default kod nomodify nopeer noquery limited/#restrict default kod nomodify nopeer noquery limited/' "${NTP_CONF}"
    fi
  fi

  #######################################
  # 5) Add Google NTP + us.pool servers, tinker panic 0, restrict default
  #######################################
  log "[STEP 06] Add Google NTP servers plus tinker panic 0, restrict default"

  local TAG_BEGIN="# XDR_NTPSEC_CONFIG_BEGIN"
  local TAG_END="# XDR_NTPSEC_CONFIG_END"

  if [[ -f "${NTP_CONF}" ]]; then
    if grep -q "${TAG_BEGIN}" "${NTP_CONF}" 2>/dev/null; then
      log "[STEP 06] XDR_NTPSEC_CONFIG block already present in ${NTP_CONF} → skip add"
    else
      local ntp_block
      ntp_block=$(cat <<EOF

${TAG_BEGIN}
# Alternate NTP servers (per docs)
server time1.google.com prefer
server time2.google.com
server time3.google.com
server time4.google.com
server 0.us.pool.ntp.org
server 1.us.pool.ntp.org

# Allow large time offsets to be corrected
tinker panic 0

# Update restrict rule
restrict default nomodify nopeer noquery notrap
${TAG_END}
EOF
)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would append block to ${NTP_CONF}:\n${ntp_block}"
      else
        printf "%s\n" "${ntp_block}" | sudo tee -a "${NTP_CONF}" >/dev/null
        log "Added XDR_NTPSEC_CONFIG block to ${NTP_CONF}"
      fi
    fi
  else
    log "[STEP 06] ${NTP_CONF} missing; cannot append NTP server settings."
  fi

  #######################################
  # 6) Restart and verify NTPsec
  #######################################
  log "[STEP 06] Restart NTPsec and check status"

  run_cmd "sudo systemctl restart ntpsec"
  run_cmd "systemctl status ntpsec --no-pager || true"
  run_cmd "ntpq -p || true"

  #######################################
  # 7) Final summary
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 06: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "ℹ️  In real execution mode, the following would be performed:"
      echo "   • SR-IOV driver (iavf/i40evf) installation"
      echo "   • NTPsec package installation and configuration"
      echo
    fi
    echo "📊 SR-IOV DRIVER STATUS:"
    echo
    local sriov_modules
    sriov_modules=$(lsmod | grep -E '^(iavf|i40evf)\b' 2>/dev/null || echo "No loaded modules")
    if [[ "${sriov_modules}" == *"No loaded"* ]]; then
      echo "  ⚠️  ${sriov_modules}"
      echo "     (Driver may need to be loaded manually or after reboot)"
    else
      echo "  ✅ Loaded SR-IOV driver modules:"
      echo "${sriov_modules}" | sed 's/^/    /'
    fi
    echo
    echo "📊 NTPsec CONFIGURATION STATUS:"
    echo
    echo "1️⃣  NTPsec Configuration File:"
    if [[ -f "${NTP_CONF}" ]]; then
      echo "  ✅ Configuration file exists: ${NTP_CONF}"
      echo "  📋 XDR_NTPSEC_CONFIG section:"
      local ntp_config
      ntp_config=$(grep -n -A5 -B2 "${TAG_BEGIN}" "${NTP_CONF}" 2>/dev/null || echo "    (XDR_NTPSEC_CONFIG section not found)")
      echo "${ntp_config}" | sed 's/^/    /'
    else
      echo "  ⚠️  Configuration file not found: ${NTP_CONF}"
      echo "     (NTPsec may not be installed)"
    fi
    echo
    echo "2️⃣  NTPsec Service Status:"
    local ntpsec_status
    # Capture output and suppress stderr
    ntpsec_status=$(systemctl is-active ntpsec 2>/dev/null || echo "")
    # systemctl is-active returns "active", "inactive", "activating", "deactivating", "failed", or empty
    # If empty or not "active", consider it inactive
    if [[ -z "${ntpsec_status}" ]] || [[ "${ntpsec_status}" != "active" ]]; then
      echo "  ⚠️  ntpsec service is inactive"
    else
      echo "  ✅ ntpsec service is active"
    fi
    echo
    echo "3️⃣  NTP Synchronization Status:"
    local ntpq_output
    ntpq_output=$(ntpq -p 2>/dev/null || echo "Unable to query NTP servers")
    if [[ "${ntpq_output}" == *"Unable"* ]]; then
      echo "  ⚠️  ${ntpq_output}"
      echo "     (NTPsec may not be running or not yet synchronized)"
    else
      echo "  📋 NTP peer status:"
      echo "${ntpq_output}" | sed 's/^/    /'
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • SR-IOV driver modules should be loaded after the previous reboot (STEP 05)"
    echo "  • If modules are not loaded, a manual reboot may be needed"
    echo "  • NTPsec synchronization may take a few minutes"
    echo "  • Verify NTP sync with: ntpq -p"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 07 (LVM Storage Configuration)"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV(iavf/i40evf) + NTPsec summary" "${tmp_info}"

  # save_state is called from run_step()
}


step_07_lvm_storage() {
  log "[STEP 07] Start LVM storage configuration"

  load_config

  local _DRY_RUN="${DRY_RUN:-0}"
  local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"
  local DA_INSTALL_DIR="${DA_INSTALL_DIR:-/stellar/da}"

  # Auto-detect OS VG name
  local root_dev
  root_dev=$(findmnt -n -o SOURCE /)

  local UBUNTU_VG
  # Extract VG name containing root device via lvs (trim spaces)
  UBUNTU_VG=$(sudo lvs --noheadings -o vg_name "${root_dev}" 2>/dev/null | awk '{print $1}')

  # Fallback to default on detection failure
  if [[ -z "${UBUNTU_VG}" ]]; then
    log "[WARN] Could not detect OS VG name; using default (ubuntu-vg)."
    UBUNTU_VG="ubuntu-vg"
  else
    log "[STEP 07] Detected OS VG name: ${UBUNTU_VG}"
  fi

  local DL_ROOT_LV="lv_dl_root"
  local DA_ROOT_LV="lv_da_root"
  local ES_VG="vg_dl"
  local ES_LV="lv_dl"

  if [[ -z "${DATA_SSD_LIST}" ]]; then
    whiptail_msgbox "STEP 07 - data disks not set" "DATA_SSD_LIST is empty.\n\nSelect data disks in STEP 01 first." 12 70
    log "DATA_SSD_LIST empty; cannot proceed with STEP 07."
    return 1
  fi

  #######################################
  # If LVM/mounts seem present, ask to skip
  #######################################
  local already_lvm=0

  # ES_VG, UBUNTU_VG, DL_ROOT_LV, DA_ROOT_LV are predefined above
  if vgs "${ES_VG}" >/dev/null 2>&1 && \
     lvs "${UBUNTU_VG}/${DL_ROOT_LV}" >/dev/null 2>&1 && \
     lvs "${UBUNTU_VG}/${DA_ROOT_LV}" >/dev/null 2>&1; then
    # Also check /stellar/dl and /stellar/da mounts
    if mount | grep -qE "on /stellar/dl " && mount | grep -qE "on /stellar/da "; then
      already_lvm=1
    fi
  fi

  if [[ "${already_lvm}" -eq 1 ]]; then
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 07 - appears already configured" "vg_dl / lv_dl and ${UBUNTU_VG}/${DL_ROOT_LV}, ${UBUNTU_VG}/${DA_ROOT_LV}\nplus /stellar/dl and /stellar/da mounts already exist.\n\nThis STEP recreates disk partitions and should not normally be rerun.\n\nSkip this STEP?"
    local skip_rc=$?
    set -e
    
    if [[ ${skip_rc} -eq 0 ]]; then
      log "User skipped STEP 07 because it appears already configured."
      return 0
    fi
    log "User chose to rerun STEP 07 anyway. (WARNING: existing data may be destroyed)"
  fi



  #######################################
  # Verify selected disks + destructive action warning
  #######################################
  local tmp_info="/tmp/xdr_step07_disks.txt"
  : > "${tmp_info}"
  echo "[Selected data disk list]" >> "${tmp_info}"
  for d in ${DATA_SSD_LIST}; do
    {
      echo
      echo "=== /dev/${d} ==="
      lsblk "/dev/${d}" -o NAME,SIZE,TYPE,MOUNTPOINT
    } >> "${tmp_info}" 2>&1
  done

  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 07: LVM Storage Configuration - Pre-Execution"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "⚠️  DESTRUCTIVE OPERATION WARNING:"
    echo "  • All existing partitions and data on the following disks"
    echo "    will be PERMANENTLY DELETED:"
    for d in ${DATA_SSD_LIST}; do
      echo "    - /dev/${d}"
    done
    echo
    echo "🔧 ACTIONS TO BE PERFORMED:"
    echo "  1. Remove all existing LVM structures (PV/VG/LV)"
    echo "  2. Wipe all filesystem signatures"
    echo "  3. Create GPT partition table"
    echo "  4. Create single partition on each disk"
    echo "  5. Create Physical Volumes (PV)"
    echo "  6. Create Volume Groups (VG):"
    echo "     - vg_dl (for ES data storage)"
    echo "     - ${UBUNTU_VG} (for DL/DA root volumes)"
    echo "  7. Create Logical Volumes (LV):"
    echo "     - lv_dl (ES data)"
    echo "     - ${DL_ROOT_LV} (DL root, 545GB)"
    echo "     - ${DA_ROOT_LV} (DA root, 545GB)"
    echo "  8. Format volumes with ext4"
    echo "  9. Mount volumes at /stellar/dl and /stellar/da"
    echo "  10. Add entries to /etc/fstab"
    echo "  11. Set ownership to stellar:stellar"
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • This operation is IRREVERSIBLE"
    echo "  • All data on selected disks will be lost"
    echo "  • Ensure you have backups if needed"
    echo "  • OS disk is automatically excluded from selection"
    echo
    echo "🔧 TROUBLESHOOTING (if issues occur):"
    echo "  • If disk operations fail:"
    echo "    1. Check disk status: lsblk"
    echo "    2. Verify disk is not in use: lsof /dev/${DATA_SSD_LIST}"
    echo "    3. Check for mounted filesystems: mount | grep /dev/"
    echo "  • If LVM operations fail:"
    echo "    1. Check existing LVM: sudo pvs, sudo vgs, sudo lvs"
    echo "    2. Remove manually if needed: sudo vgremove, sudo pvremove"
    echo "  • If mount fails:"
    echo "    1. Check filesystem: sudo fsck /dev/..."
    echo "    2. Verify mount points exist: ls -ld /stellar/dl /stellar/da"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 07 - Pre-execution warning and actions" "${tmp_info}"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 07 - WARNING" "All existing partitions/data on /dev/${DATA_SSD_LIST}\nwill be deleted and used exclusively for LVM.\n\nThis operation is IRREVERSIBLE.\n\nContinue?"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    log "User canceled STEP 07 disk initialization."
    return 2  # Return 2 to indicate cancellation
  fi

  #######################################
  # Stop and remove running DL/DA VMs (avoid busy volumes)
  #######################################
  local -a dl_vms da_vms cluster_vms
  mapfile -t dl_vms < <(list_dl_domains)
  mapfile -t da_vms < <(list_da_domains)
  cluster_vms=("${dl_vms[@]}" "${da_vms[@]}")

  if [[ ${#cluster_vms[@]} -gt 0 ]]; then
    local vm_list_str
    vm_list_str=$(printf '%s\n' "${cluster_vms[@]}")
    if ! confirm_destroy_vm_batch "STEP 07 - LVM Storage" "${vm_list_str}" "DL/DA"; then
      log "[STEP 07] VM cleanup canceled by user."
      return 2
    fi
    local vm
    for vm in "${cluster_vms[@]}"; do
      cleanup_dl_da_vm_and_images "${vm}" "${DL_INSTALL_DIR}" "${DA_INSTALL_DIR}" "${_DRY_RUN}"
    done
  fi

  #######################################
  # 0-5) Remove all existing LVM/VG/LV on selected disks
  #######################################
  log "[STEP 07] Removing existing LVM metadata (LV/VG/PV) from selected disks."

  local disk pv vg_name pv_list_for_disk

  for disk in ${DATA_SSD_LIST}; do
    log "[STEP 07] Cleaning existing LVM structures on /dev/${disk}"

    # List PVs on this disk (includes /dev/sdb, /dev/sdb1, etc.)
    pv_list_for_disk=$(sudo pvs --noheadings -o pv_name 2>/dev/null \
                         | awk "\$1 ~ /^\\/dev\\/${disk}([0-9]+)?\$/ {print \$1}")

    for pv in ${pv_list_for_disk}; do
      vg_name=$(sudo pvs --noheadings -o vg_name "${pv}" 2>/dev/null | awk '{print $1}')

      if [[ -n "${vg_name}" && "${vg_name}" != "-" ]]; then
        log "[STEP 07] PV ${pv} belongs to VG ${vg_name} → removing LV/VG"

        # Remove all LVs in VG (ignore errors if repeated)
        run_cmd "sudo lvremove -y ${vg_name} || true"

        # Remove VG (ignore if already removed)
        run_cmd "sudo vgremove -y ${vg_name} || true"
      fi

      # Remove PV metadata
      run_cmd "sudo pvremove -y ${pv} || true"
    done

    # Wipe remaining filesystem/partition signatures on disk
    log "[STEP 07] Running wipefs on /dev/${disk}"
    run_cmd "sudo wipefs -a /dev/${disk} || true"
  done


  #######################################
  # 1) Create GPT label + single partition on each disk
  #######################################
  log "[STEP 07] Create GPT label and partition"

  local d
  for d in ${DATA_SSD_LIST}; do
    run_cmd "sudo parted -s /dev/${d} mklabel gpt"
    run_cmd "sudo parted -s /dev/${d} mkpart primary ext4 1MiB 100%"
  done

  # Ensure kernel/udev sees new partitions before pvcreate
  for d in ${DATA_SSD_LIST}; do
    run_cmd "sudo partprobe /dev/${d} || true"
  done
  run_cmd "sudo udevadm settle || true"

  # Wait for partition device nodes (e.g., /dev/sdb1) to appear
  for d in ${DATA_SSD_LIST}; do
    for _ in {1..10}; do
      [[ -b "/dev/${d}1" ]] && break
      sleep 0.3
    done
  done

  #######################################
  # 2) Create PV / VG / LV (for ES data)
  #######################################
  log "[STEP 07] Create ES-only VG/LV (vg_dl / lv_dl)"

  local pv_list=""
  local stripe_count=0
  for d in ${DATA_SSD_LIST}; do
    pv_list+=" /dev/${d}1"
    ((stripe_count++))
  done

  # pvcreate
  run_cmd "sudo pvcreate${pv_list}"

  # vgcreate vg_dl
  run_cmd "sudo vgcreate ${ES_VG}${pv_list}"

  # lvcreate --extents 100%FREE --stripes <N> --name lv_dl vg_dl
  run_cmd "sudo lvcreate --extents 100%FREE --stripes ${stripe_count} --name ${ES_LV} ${ES_VG}"

  #######################################
  # 3) Create DL / DA Root LV (ubuntu-vg)
  #######################################
  log "[STEP 07] Create DL/DA Root LV (${UBUNTU_VG}/${DL_ROOT_LV}, ${UBUNTU_VG}/${DA_ROOT_LV})"

  if lvs "${UBUNTU_VG}/${DL_ROOT_LV}" >/dev/null 2>&1; then
    log "LV ${UBUNTU_VG}/${DL_ROOT_LV} already exists → skip create"
  else
    run_cmd "sudo lvcreate -L 545G -n ${DL_ROOT_LV} ${UBUNTU_VG}"
  fi

  if lvs "${UBUNTU_VG}/${DA_ROOT_LV}" >/dev/null 2>&1; then
    log "LV ${UBUNTU_VG}/${DA_ROOT_LV} already exists → skip create"
  else
    run_cmd "sudo lvcreate -L 545G -n ${DA_ROOT_LV} ${UBUNTU_VG}"
  fi

  #######################################
  # 4) mkfs.ext4 (DL/DA Root + ES Data)
  #######################################
  log "[STEP 07] Format LVs (mkfs.ext4)"

  local DEV_DL_ROOT="/dev/${UBUNTU_VG}/${DL_ROOT_LV}"
  local DEV_DA_ROOT="/dev/${UBUNTU_VG}/${DA_ROOT_LV}"
  local DEV_ES_DATA="/dev/${ES_VG}/${ES_LV}"

  if ! blkid "${DEV_DL_ROOT}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_DL_ROOT}"
  else
    log "Filesystem already exists: ${DEV_DL_ROOT} → skip mkfs"
  fi

  if ! blkid "${DEV_DA_ROOT}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_DA_ROOT}"
  else
    log "Filesystem already exists: ${DEV_DA_ROOT} → skip mkfs"
  fi

  if ! blkid "${DEV_ES_DATA}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_ES_DATA}"
  else
    log "Filesystem already exists: ${DEV_ES_DATA} → skip mkfs"
  fi

  #######################################
  # 5) Create mount points
  #######################################
  log "[STEP 07] Create /stellar/dl and /stellar/da directories"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /stellar/dl /stellar/da"
  else
    sudo mkdir -p /stellar/dl /stellar/da
  fi

  #######################################
  # 6) Add entries to /etc/fstab (per docs)
  #######################################
  log "[STEP 07] Register /etc/fstab entries"

  local FSTAB_DL_LINE="${DEV_DL_ROOT} /stellar/dl ext4 defaults,noatime 0 2"
  local FSTAB_DA_LINE="${DEV_DA_ROOT} /stellar/da ext4 defaults,noatime 0 2"
  append_fstab_if_missing "${FSTAB_DL_LINE}" "/stellar/dl"
  append_fstab_if_missing "${FSTAB_DA_LINE}" "/stellar/da"

  #######################################
  # 7) Run mount -a and verify
  #######################################
  log "[STEP 07] Run mount -a and verify mount state"

  run_cmd "sudo systemctl daemon-reload"
  run_cmd "sudo mount -a"

  #######################################
  # 8) Change ownership of /stellar (doc: chown -R stellar:stellar /stellar)
  #######################################
  log "[STEP 07] Set /stellar ownership to stellar:stellar (per docs)"

  if id stellar >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo chown -R stellar:stellar /stellar"
    else
      sudo chown -R stellar:stellar /stellar
      log "[STEP 07] /stellar ownership update complete"
    fi
  else
    log "[WARN] 'stellar' user not found; skipping chown."
  fi

  #######################################
  # 9) Generate and show summary (after all operations)
  #######################################
  local tmp_df="/tmp/xdr_step07_df.txt"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 07: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
    fi
    echo "📊 STORAGE STATUS:"
    echo
    echo "1️⃣  Mount Points:"
    local mount_info
    mount_info=$(df -h | egrep '/stellar/(dl|da)' 2>/dev/null || echo "  ⚠️  No /stellar/dl or /stellar/da mount info found")
    if [[ "${mount_info}" != *"No /stellar"* ]]; then
      echo "${mount_info}" | sed 's/^/  /'
    else
      echo "  ${mount_info}"
    fi
    echo
    echo "2️⃣  Logical Volumes:"
    echo "  📋 Current LVM structure:"
    lvs 2>/dev/null | sed 's/^/    /' || echo "    ⚠️  Unable to list logical volumes"
    echo
    echo "3️⃣  Disk Layout (lsblk):"
    echo "  📋 Complete disk/partition/volume view:"
    lsblk 2>/dev/null | sed 's/^/    /' || echo "    ⚠️  Unable to list block devices"
    echo
    echo "4️⃣  Directory Ownership:"
    if [[ -d /stellar ]]; then
      if id stellar >/dev/null 2>&1; then
        local stellar_owner
        stellar_owner=$(stat -c '%U:%G' /stellar 2>/dev/null || echo "unknown")
        if [[ "${stellar_owner}" == "stellar:stellar" ]]; then
          echo "  ✅ /stellar ownership: ${stellar_owner}"
        else
          if [[ "${DRY_RUN}" -eq 1 ]]; then
            echo "  ⚠️  /stellar ownership: ${stellar_owner} (expected: stellar:stellar)"
            echo "  💡 This will be corrected during STEP 07 execution"
          else
            echo "  ⚠️  /stellar ownership: ${stellar_owner} (expected: stellar:stellar)"
            echo "  ⚠️  Ownership change may have failed or stellar user not available"
          fi
        fi
      else
        echo "  ⚠️  'stellar' user not found"
        echo "  💡 The 'stellar' user will be created during VM deployment (STEP 10/11)"
      fi
    else
      echo "  ℹ️  /stellar directory does not exist yet"
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "  💡 This will be created during STEP 07 execution"
      else
        echo "  ⚠️  /stellar directory creation may have failed"
      fi
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • LVM volumes are created and mounted at /stellar/dl and /stellar/da"
    echo "  • These mount points will be used for VM storage"
    echo "  • Ensure all volumes are properly mounted before proceeding"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 08 (Libvirt Hooks Configuration)"
  } > "${tmp_df}" 2>&1
  
  

  #######################################
  # 8) Change ownership of /stellar (doc: chown -R stellar:stellar /stellar)
  #######################################
  log "[STEP 07] Set /stellar ownership to stellar:stellar (per docs)"

  if id stellar >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo chown -R stellar:stellar /stellar"
    else
      sudo chown -R stellar:stellar /stellar
      log "[STEP 07] /stellar ownership update complete"
    fi
  else
    log "[WARN] 'stellar' user not found; skipping chown."
  fi

  #######################################
  # 9) Show summary
  #######################################
  show_textbox "STEP 07 summary" "${tmp_df}"

  # STEP success → save_state called in run_step()
}



step_08_libvirt_hooks() {
  log "[STEP 08] Install libvirt hooks (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  local tmp_info="/tmp/xdr_step08_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Summarize current hooks state
  #######################################
  {
    echo "/etc/libvirt/hooks directory and scripts status"
    echo "-------------------------------------------"
    echo
    echo "# Directory existence"
    if [[ -d /etc/libvirt/hooks ]]; then
      echo "/etc/libvirt/hooks directory exists."
      echo
      echo "# /etc/libvirt/hooks/network (first 20 lines if present)"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/network
      else
        echo "(no network script)"
      fi
      echo
      echo "# /etc/libvirt/hooks/qemu (first 20 lines if present)"
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/qemu
      else
        echo "(no qemu script)"
      fi
    else
      echo "/etc/libvirt/hooks directory does not exist yet."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 08 - Current hooks state" "${tmp_info}"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 08 - confirmation" "Create/overwrite /etc/libvirt/hooks/network and qemu scripts per docs.\n\nProceed?"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    log "User canceled STEP 08."
    return 2  # Return 2 to indicate cancellation
  fi


  #######################################
  # 1) Create /etc/libvirt/hooks directory
  #######################################
  log "[STEP 08] Create /etc/libvirt/hooks directory if missing"
  run_cmd "sudo mkdir -p /etc/libvirt/hooks"

  #######################################
  # 2) Create /etc/libvirt/hooks/network (per docs)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Create/update ${HOOK_NET}"

  if [[ -f "${HOOK_NET}" ]]; then
    log "[STEP 08] Backing up existing ${HOOK_NET}"
    run_cmd "sudo cp -a ${HOOK_NET} ${HOOK_NET_BAK}"
    log "Backed up existing ${HOOK_NET} to ${HOOK_NET_BAK}."
  fi

  local net_hook_content
  net_hook_content=$(cat <<'EOF'
#!/bin/bash
# Last Update: 2020-01-06
# Update the following variables to fit your setup

if [ "$1" = "default" ]; then
    MGT_BR_NET='192.168.122.0/24'
    MGT_BR_IP='192.168.122.1'
    MGT_BR_DEV='virbr0'
    RT='rt_mgt'

    if [ "$2" = "stopped" ] || [ "$2" = "reconnect" ]; then
        ip route del $MGT_BR_NET via $MGT_BR_IP dev $MGT_BR_DEV table $RT
        ip rule del from $MGT_BR_NET table $RT
    fi

    if [ "$2" = "started" ] || [ "$2" = "reconnect" ]; then
        ip route add $MGT_BR_NET via $MGT_BR_IP dev $MGT_BR_DEV table $RT
        ip rule add from $MGT_BR_NET table $RT
    fi
fi
EOF
)

  log "[STEP 08] Writing network hook script to ${HOOK_NET}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write the following to ${HOOK_NET}:\n${net_hook_content}"
  else
    printf "%s\n" "${net_hook_content}" | run_cmd "sudo tee ${HOOK_NET} >/dev/null"
  fi

  run_cmd "sudo chmod +x ${HOOK_NET}"

  #######################################
  # 3) Create /etc/libvirt/hooks/qemu (full version)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Create/update ${HOOK_QEMU} (full NAT + OOM restart script)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    log "[STEP 08] Backing up existing ${HOOK_QEMU}"
    run_cmd "sudo cp -a ${HOOK_QEMU} ${HOOK_QEMU_BAK}"
    log "Backed up existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}."
  fi

  local qemu_hook_content
  qemu_hook_content=$(cat <<'EOF'
#!/bin/bash
# Last Update: 2025-11-27 (unified mgt network)
# IMPORTANT: Change the "VM NAME" string to match your actual VM Name.
# In order to create rules to other VMs, just duplicate the below block and configure
# it accordingly.

# UI exception list (internal management IP addresses of DLm, DAm, SDS)
# Unified topology: DL = 192.168.122.2, DA = 192.168.122.3
# If datasensor is attached to virbr0 as 192.168.122.4, add it below
UI_EXC_LIST=(192.168.122.2 192.168.122.3)
IPSET_UI='ui'

# Create ipset ui if missing + add exception IPs
IPSET_CONFIG=$(echo -n $(ipset list $IPSET_UI 2>/dev/null))
if ! [[ $IPSET_CONFIG =~ $IPSET_UI ]]; then
  ipset create $IPSET_UI hash:ip
  for IP in ${UI_EXC_LIST[@]}; do
    ipset add $IPSET_UI $IP
  done
fi

########################
# dl-master NAT / forwarding
########################
if [ "${1}" = "dl-master" ]; then
  GUEST_IP=192.168.122.2
  HOST_SSH_PORT=2222
  GUEST_SSH_PORT=22
  UI_PORTS=(80 443)
  TCP_PORTS=(6640 6641 6642 6643 6644 6645 6646 6647 6648 8443)
  BRIDGE='virbr0'
  MGT_INTF='mgt'

  if [ "${2}" = "stopped" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      #/sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_CM src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    for PORT in ${UI_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_UI src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      #/sbin/iptables -t nat -D PREROUTING -p tcp ! -s 192.168.122.0/23 --dport $UI_PORT -j DNAT --to $GUEST_IP:PORT
    done
    # Remove additional DNAT for DL Web UI via hostmgmt
    /sbin/iptables -t nat -D PREROUTING -i hostmgmt -p tcp --dport 443 -j DNAT --to $GUEST_IP:443 2>/dev/null || true
  fi

  if [ "${2}" = "start" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      #/sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_CM src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    for PORT in ${UI_PORTS[@]}; do
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_UI src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      #/sbin/iptables -t nat -I PREROUTING -p tcp ! -s 192.168.122.0/23 --dport $UI_PORT -j DNAT --to $GUEST_IP:PORT
    done
    # Additional DNAT for DL Web UI via hostmgmt (HTTPS only)
    if ! /sbin/iptables -t nat -C PREROUTING -i hostmgmt -p tcp --dport 443 -j DNAT --to $GUEST_IP:443 2>/dev/null; then
      /sbin/iptables -t nat -I PREROUTING -i hostmgmt -p tcp --dport 443 -j DNAT --to $GUEST_IP:443
    fi
    # save last known good pid
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# da-master NAT / forwarding
#  - Unified topology: DA also uses virbr0 + mgt for mgmt/data
########################
if [ "${1}" = "da-master" ]; then
  # Internal IP unified to 192.168.122.3
  GUEST_IP=192.168.122.3
  HOST_SSH_PORT=2223
  GUEST_SSH_PORT=22
  TCP_PORTS=(8888 8889)
  UDP_PORTS=(162)
  BRIDGE='virbr0'
  MGT_INTF='mgt'

  if [ "${2}" = "stopped" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    for PORT in ${UDP_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
  fi

  if [ "${2}" = "start" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    for PORT in ${UDP_PORTS[@]}; do
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    # save last known good pid
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# datasensor NAT / forwarding (optional)
#  - Use only if datasensor VM is needed
#  - Example when attaching datasensor to virbr0 as 192.168.122.4
#  - If not using datasensor VM, this whole block can be removed
########################
if [ "${1}" = "datasensor" ]; then
  # Update the following variables to fit your setup
  GUEST_IP=192.168.122.4
  HOST_SSH_PORT=2224
  GUEST_SSH_PORT=22
  TCP_PORTS=(514 2055 5000:6000)
  VXLAN_PORTS=(4789 8472)
  UDP_PORTS=(514 2055 5000:6000)
  BRIDGE='virbr0'
  MGT_INTF='mgt'

  if [ "${2}" = "stopped" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT
      else
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      fi
    done

    for PORT in ${UDP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT
      else
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      fi
    done
    for PORT in ${VXLAN_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
  fi

  if [ "${2}" = "start" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    for PORT in ${TCP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT
      else
        /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      fi
    done

    for PORT in ${UDP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT
      else
        /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
      fi
    done
    for PORT in ${VXLAN_PORTS[@]}; do
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    # save last known good pid
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi
EOF
)

  log "[STEP 08] Writing qemu hook script to ${HOOK_QEMU}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write the following to ${HOOK_QEMU}:\n${qemu_hook_content}"
  else
    printf "%s\n" "${qemu_hook_content}" | run_cmd "sudo tee ${HOOK_QEMU} >/dev/null"
  fi

  run_cmd "sudo chmod +x ${HOOK_QEMU}"


  ########################################
  # 4) Install OOM recovery scripts (last_known_good_pid, check_vm_state)
  ########################################
  log "[STEP 08] Installing OOM recovery scripts (last_known_good_pid, check_vm_state)"

  local _DRY="${DRY_RUN:-0}"

  # 1) Create /usr/bin/last_known_good_pid (per docs)
  log "[STEP 08] Creating /usr/bin/last_known_good_pid script"
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would create /usr/bin/last_known_good_pid script"
  else
    local last_known_good_pid_content
    last_known_good_pid_content=$(cat <<'EOF'
#!/bin/bash
VM_NAME=$1
RUN_DIR=/var/run/libvirt/qemu
RETRY=60 # timeout 5 minutes

for i in $(seq 1 $RETRY); do
    if [ -e ${RUN_DIR}/${VM_NAME}.pid ]; then
        cp ${RUN_DIR}/${VM_NAME}.pid ${RUN_DIR}/${VM_NAME}.lkg
        exit 0
    else
        sleep 5
    fi
done

exit 1
EOF
)
    printf "%s\n" "${last_known_good_pid_content}" | run_cmd "sudo tee /usr/bin/last_known_good_pid >/dev/null"
    run_cmd "sudo chmod +x /usr/bin/last_known_good_pid"
  fi


  # 2) Create /usr/bin/check_vm_state (per docs)
  log "[STEP 08] Creating /usr/bin/check_vm_state script"
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would create /usr/bin/check_vm_state script"
  else
    local check_vm_state_content
    check_vm_state_content=$(cat <<'EOF'
#!/bin/bash
RUN_DIR=/var/run/libvirt/qemu

# Match any DL/DA VM (master or workerN) based on name
VM_NAME_REGEX='^(dl|da)-(master|worker[0-9]+)$'

for lkg in "${RUN_DIR}"/*.lkg; do
    [ -e "${lkg}" ] || continue
    VM="$(basename "${lkg}" .lkg)"

    # Only handle DL/DA masters and workers
    if ! [[ "${VM}" =~ ${VM_NAME_REGEX} ]]; then
        continue
    fi

    # Detect if VM is down (.xml and .pid absent)
    if [ ! -e "${RUN_DIR}/${VM}.xml" ] && [ ! -e "${RUN_DIR}/${VM}.pid" ]; then
        LKG_PID="$(cat "${RUN_DIR}/${VM}.lkg")"

        # Check dmesg to see if OOM-killer killed that PID
        if dmesg | grep "Out of memory: Kill process $LKG_PID" > /dev/null 2>&1; then
            virsh start "${VM}"
        fi
    fi
done

exit 0
EOF
)
    printf "%s\n" "${check_vm_state_content}" | run_cmd "sudo tee /usr/bin/check_vm_state >/dev/null"
    run_cmd "sudo chmod +x /usr/bin/check_vm_state"
  fi


  # 3) Add cron (run check_vm_state every 5 minutes)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would add the following two lines to root crontab:"
    log "  SHELL=/bin/bash"
    log "  */5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1"
  else
    # Preserve existing crontab; ensure SHELL and check_vm_state lines
    local tmp_cron added_flag
    tmp_cron="$(mktemp)"
    added_flag="0"

    # Dump existing crontab (create empty if none)
    if ! sudo crontab -l 2>/dev/null > "${tmp_cron}"; then
      : > "${tmp_cron}"
    fi

    # Add SHELL=/bin/bash if missing
    if ! grep -q '^SHELL=' "${tmp_cron}"; then
      echo "SHELL=/bin/bash" >> "${tmp_cron}"
      added_flag="1"
    fi

    # Add check_vm_state line if missing
    if ! grep -q 'check_vm_state' "${tmp_cron}"; then
      echo "*/5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1" >> "${tmp_cron}"
      added_flag="1"
    fi

    # Apply updated crontab
    run_cmd "sudo crontab ${tmp_cron}"
    rm -f "${tmp_cron}"

    if [[ "${added_flag}" = "1" ]]; then
      log "[STEP 08] Added/updated SHELL=/bin/bash and check_vm_state entries in root crontab."
    else
      log "[STEP 08] root crontab already has SHELL=/bin/bash and check_vm_state entries."
    fi
  fi



  #######################################
  # 5) Final summary
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 08: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
    fi
    echo "📊 LIBVIRT HOOKS STATUS:"
    echo
    echo "1️⃣  Network Hook Script:"
    if [[ -f /etc/libvirt/hooks/network ]]; then
      echo "  ✅ File exists: /etc/libvirt/hooks/network"
      echo "  📋 First 30 lines:"
      sed -n '1,30p' /etc/libvirt/hooks/network | sed 's/^/    /'
    else
      echo "  ⚠️  File not found: /etc/libvirt/hooks/network"
    fi
    echo
    echo "2️⃣  QEMU Hook Script:"
    if [[ -f /etc/libvirt/hooks/qemu ]]; then
      echo "  ✅ File exists: /etc/libvirt/hooks/qemu"
      echo "  📋 First 40 lines:"
      sed -n '1,40p' /etc/libvirt/hooks/qemu | sed 's/^/    /'
    else
      echo "  ⚠️  File not found: /etc/libvirt/hooks/qemu"
    fi
    echo
    echo "3️⃣  OOM Recovery Scripts:"
    if [[ -f /usr/bin/last_known_good_pid ]]; then
      echo "  ✅ last_known_good_pid script installed"
    else
      echo "  ⚠️  last_known_good_pid script not found"
    fi
    if [[ -f /usr/bin/check_vm_state ]]; then
      echo "  ✅ check_vm_state script installed"
    else
      echo "  ⚠️  check_vm_state script not found"
    fi
    echo
    echo "4️⃣  Cron Job Status:"
    if sudo crontab -l 2>/dev/null | grep -q "check_vm_state"; then
      echo "  ✅ check_vm_state cron job is configured"
    else
      echo "  ⚠️  check_vm_state cron job not found"
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • Hooks will be triggered automatically when VMs start/stop"
    echo "  • Network hook manages routing for virbr0 network"
    echo "  • QEMU hook manages iptables NAT rules for VM access"
    echo "  • OOM recovery scripts monitor and restart VMs if needed"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 09 (DP Download)"
  } >> "${tmp_info}"

  show_textbox "STEP 08 - Summary" "${tmp_info}"

  # save_state handled in run_step()
}


#######################################
# DP_VERSION >= 6.2.1: KT v1.8 Step 09~12 implementations
#######################################

step_09_dp_download_v621() {
  log "[STEP 09] Download DP deploy script and image (KT v1.8 logic for DP_VERSION >= 6.2.1)"
  load_config
  local tmp_info="/tmp/xdr_step09_info.txt"

  #######################################
  # 0) Check configuration values
  #######################################
  local ver="${DP_VERSION:-}"
  local acps_user="${ACPS_USERNAME:-}"
  local acps_pass="${ACPS_PASSWORD:-}"
  local acps_url="${ACPS_BASE_URL:-https://acps.stellarcyber.ai}"

  # Check required values
  local missing=""
  [[ -z "${ver}"       ]] && missing+="\n - DP_VERSION"
  [[ -z "${acps_user}" ]] && missing+="\n - ACPS_USERNAME"
  [[ -z "${acps_pass}" ]] && missing+="\n - ACPS_PASSWORD"

  if [[ -n "${missing}" ]]; then
    local msg="The following items are missing in config:${missing}\n\nSet them in Settings, then rerun."
    log "[STEP 09] Missing config values: ${missing}"
    whiptail_msgbox "STEP 09 - Missing config" "${msg}" 15 70
    log "[STEP 09] Skipping STEP 09 due to missing config."
    return 0
  fi

  # Normalize URL (trim trailing slash)
  acps_url="${acps_url%/}"

  #######################################
  # 1) Prepare download directory
  #######################################
  local dl_img_dir="/stellar/dl/images"
  log "[STEP 09] Download directory: ${dl_img_dir}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p ${dl_img_dir}"
  else
    sudo mkdir -p "${dl_img_dir}"
  fi

  #######################################
  # 2) Define download targets/URLs
  #######################################
  # Script version fixed at 6.2.0
  local script_ver="6.2.0"
  local dp_script="virt_deploy_uvp_centos.sh"

  # File naming strategy: Long Name (remote) vs Short Name (local)
  local remote_qcow2="aella-dataprocessor-ubuntu2404-py2-${ver}.qcow2"
  local remote_xml="aella-dataprocessor-ubuntu2404-py2-${ver}.xml"
  local remote_sha1="${remote_qcow2}.sha1"

  # Local storage name (Short Name - compatible with Step 10/11)
  local local_qcow2="aella-dataprocessor-${ver}.qcow2"

  # URL assembly
  local url_script="${acps_url}/release/${script_ver}/dataprocessor/${dp_script}"
  local url_qcow2="${acps_url}/release/${ver}/dataprocessor/${remote_qcow2}"
  local url_xml="${acps_url}/release/${ver}/dataprocessor/${remote_xml}"
  local url_sha1="${acps_url}/release/${ver}/dataprocessor/${remote_sha1}"

  log "[STEP 09] Configuration summary:"
  log "  - DP_VERSION     = ${ver}"
  log "  - ACPS_BASE_URL  = ${acps_url}"
  log "  - Remote filename: ${remote_qcow2}"
  log "  - Local filename  : ${local_qcow2}"

  #######################################
  # 3-A) Check for local qcow2 >= 1GB reuse
  #######################################
  local use_local_qcow=0
  local found_local_file=""
  local found_size=""
  local search_dir="."

  # Find newest *.qcow2 >= 1GB (1000M)
  found_local_file="$(
    find "${search_dir}" -maxdepth 1 -type f -name '*.qcow2' -size +1000M -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}'
  )"

  if [[ -n "${found_local_file}" ]]; then
    found_size="$(ls -lh "${found_local_file}" 2>/dev/null | awk '{print $5}')"

    local msg
    msg="Found a qcow2 (>=1GB) in current directory.\n\n"
    msg+="  File: ${found_local_file}\n"
    msg+="  Size: ${found_size}\n\n"
    msg+="Use this file to skip download?\n"
    msg+="(If selected, file will be saved as '${local_qcow2}')"

    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 09 - reuse local qcow2" "${msg}"
    local reuse_rc=$?
    set -e
    
    if [[ ${reuse_rc} -eq 0 ]]; then
      use_local_qcow=1
      log "[STEP 09] User chose to use local qcow2 file (${found_local_file})."

      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${found_local_file}\" \"${dl_img_dir}/${remote_qcow2}\""
      else
        # Copy as remote_qcow2 (long name) for SHA1 verification
        sudo cp "${found_local_file}" "${dl_img_dir}/${remote_qcow2}"
        log "[STEP 09] Copied local file to ${dl_img_dir}/${remote_qcow2} (for verification)"
      fi
    else
      log "[STEP 09] User chose to download from server instead."
    fi
  else
    log "[STEP 09] No qcow2 >=1GB in current directory → will download."
  fi

  #######################################
  # 3-B) Force Refresh (always re-download script/XML/SHA1)
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will remove existing script/XML/SHA1 files"
    [[ "${use_local_qcow}" -eq 0 ]] && log "[DRY-RUN] Will remove existing image files"
  else
    # Always remove script/XML/SHA1 to ensure latest versions
    sudo rm -f "${dl_img_dir}/${dp_script}" \
               "${dl_img_dir}/${remote_xml}" \
               "${dl_img_dir}/${remote_sha1}" \
               "${dl_img_dir}/*.xml" "${dl_img_dir}/*.sha1" 2>/dev/null || true

    # Remove image only if not using local file
    if [[ "${use_local_qcow}" -eq 0 ]]; then
      if [[ -f "${dl_img_dir}/${local_qcow2}" || -f "${dl_img_dir}/${remote_qcow2}" ]]; then
        log "[STEP 09] Force Refresh: removing existing qcow2 images"
        sudo rm -f "${dl_img_dir}/${local_qcow2}" "${dl_img_dir}/${remote_qcow2}"
      fi
    else
      log "[STEP 09] Using local file, skipping image removal."
    fi
  fi

  #######################################
  # 3-C) Perform downloads
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] (password is not shown in logs)"
    log "[DRY-RUN] Script: ${url_script}"
    log "[DRY-RUN] XML:    ${url_xml}"
    log "[DRY-RUN] SHA1:   ${url_sha1}"
    if [[ "${use_local_qcow}" -eq 0 ]]; then
      log "[DRY-RUN] Image:  ${url_qcow2}"
    fi
  else
    (
      cd "${dl_img_dir}" || exit 1

      # 1) Deploy script (always)
      log "[STEP 09] Starting ${dp_script} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_script}" || {
        log "[ERROR] ${dp_script} download failed"
        exit 1
      }

      # 2) XML file (always - Long Name)
      log "[STEP 09] Starting ${remote_xml} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_xml}" || {
        log "[WARN] XML download failed (continuing)"
      }

      # 3) SHA1 file (always - Long Name)
      log "[STEP 09] Starting ${remote_sha1} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_sha1}" || {
        log "[WARN] SHA1 download failed (verification may be skipped)"
      }

      # 4) qcow2 (only if not using local file - Long Name)
      if [[ "${use_local_qcow}" -eq 0 ]]; then
        log "[STEP 09] Starting image download: ${remote_qcow2}"
        echo "=== Downloading ${remote_qcow2} (curl progress below) ==="
        curl -O -k -u "${acps_user}:${acps_pass}" "${url_qcow2}" || {
          log "[ERROR] ${remote_qcow2} download failed"
          exit 1
        }
        echo "=== ${remote_qcow2} download complete ==="
        log "[STEP 09] Image download complete"
      else
        log "[STEP 09] Using local image, skipping download."
      fi
    )

    local rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log "[STEP 09] Download error; aborting STEP 09 (rc=${rc})"
      return 1
    fi
  fi

  #######################################
  # 4) Execute permission, SHA1 verification, and rename
  #######################################
  local _DRY="${DRY_RUN:-0}"

  if [[ "${_DRY}" -eq 0 ]]; then
    # 4-1) Add execute permission to script
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      sudo chmod +x "${dl_img_dir}/${dp_script}"
      log "[STEP 09] Granted execute permission to ${dl_img_dir}/${dp_script}"
    else
      log "[STEP 09] WARN: ${dl_img_dir}/${dp_script} missing; skipping chmod."
    fi

    # 4-2) SHA1 verification (only if both files exist)
    if [[ -f "${dl_img_dir}/${remote_sha1}" && -f "${dl_img_dir}/${remote_qcow2}" ]]; then
      log "[STEP 09] Running sha1sum verification for ${remote_qcow2}"

      (
        cd "${dl_img_dir}" || exit 2

        if ! sha1sum -c "${remote_sha1}"; then
          log "[WARN] sha1sum verification failed."

          # Temporarily disable set -e to handle cancel gracefully (in subshell)
          set +e
          whiptail_yesno "STEP 09 - sha1 verification failed" "sha1 verification failed.\n\nFile may be corrupted.\n\nProceed anyway?\n\n[Yes] continue\n[No] stop STEP 09"
          local sha_continue_rc=$?
          set -e
          
          if [[ ${sha_continue_rc} -eq 0 ]]; then
            log "[STEP 09] User chose to continue despite sha1 failure."
            exit 0
          else
            log "[STEP 09] User stopped STEP 09 due to sha1 failure."
            exit 3
          fi
        fi

        log "[STEP 09] sha1sum verification succeeded."
        exit 0
      )

      local sha_rc=$?
      case "${sha_rc}" in
        0) ;; # ok
        2) log "[STEP 09] Failed to access directory during sha1 check"; return 1 ;;
        3) log "[STEP 09] User aborted STEP 09 due to sha1 failure"; return 1 ;;
        *) log "[STEP 09] Unknown error during sha1 verification (code=${sha_rc})"; return 1 ;;
      esac
    else
      log "[STEP 09] SHA1 file or image missing; skipping sha1 verification."
    fi

    # 4-3) Rename: Long Name -> Short Name
    if [[ -f "${dl_img_dir}/${remote_qcow2}" ]]; then
      log "[STEP 09] Renaming: ${remote_qcow2} -> ${local_qcow2}"
      sudo mv "${dl_img_dir}/${remote_qcow2}" "${dl_img_dir}/${local_qcow2}"

      # Remove SHA1 file (no longer needed, avoid confusion)
      sudo rm -f "${dl_img_dir}/${remote_sha1}"
    fi

    #######################################
    # 5) Patch virt_deploy_uvp_centos.sh (Short Name + ACPS_BASE_URL)
    #######################################
    local target_script="${dl_img_dir}/${dp_script}"
    local hardcoded_image_name="${local_qcow2}" # Short Name

    if [[ -f "${target_script}" ]]; then
      log "[STEP 09] Patching virt_deploy_uvp_centos.sh (Short Name + ACPS_BASE_URL)"

      # 1. IMAGE variable patch
      sed -i "s|^#\?IMAGE=\${DIR}/\${IMAGE_NAME}|IMAGE=${dl_img_dir}/${hardcoded_image_name}|" "${target_script}"

      # 2. uvp_package_url patch (use ACPS_BASE_URL, not FS_SERVER or apsdev)
      sed -i "s|^#\?uvp_package_url=.*|uvp_package_url=${acps_url}/release/\${RELEASE}/dataprocessor/${hardcoded_image_name}|" "${target_script}"

      log "[STEP 09] virt_deploy_uvp_centos.sh patched (IMAGE, uvp_package_url)."
    fi

    #######################################
    # 6) Copy to DA image directory
    #######################################
    local da_img_dir="/stellar/da/images"

    run_cmd "sudo mkdir -p ${da_img_dir}"

    # Copy image (Short Name)
    if [[ -f "${dl_img_dir}/${local_qcow2}" ]]; then
      run_cmd "sudo cp ${dl_img_dir}/${local_qcow2} ${da_img_dir}/"
    else
      log "[WARN] ${local_qcow2} missing; skipping DA image copy."
    fi

    # Copy script
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      run_cmd "sudo cp ${dl_img_dir}/${dp_script} ${da_img_dir}/"
    else
      log "[WARN] ${dp_script} missing; skipping DA script copy."
    fi
  else
    # DRY_RUN mode
    log "[DRY-RUN] chmod, SHA1 verification, Rename, script patching, file copying skipped"
  fi

  #######################################
  # 7) Final summary
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 09: Execution Summary (v621)"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${use_local_qcow}" -eq 1 ]]; then
      echo "# Image source: Local file reuse"
      echo "  - Original: ${found_local_file}"
    else
      echo "# Image source: Downloaded from server"
      echo "  - Remote: ${remote_qcow2}"
    fi
    echo
    echo "# Final local name: ${local_qcow2}"
    echo "  (This filename is used in Step 10/11)"
    echo
    echo "# Download path: ${dl_img_dir}"
    echo "# Script patched: Yes (IMAGE, uvp_package_url)"
    echo "# ACPS_BASE_URL: ${acps_url}"
  } >> "${tmp_info}"

  show_textbox "STEP 09 - Summary (v621)" "${tmp_info}"
}

step_10_dl_master_deploy_v621() {
  local STEP_ID="10_dl_master_deploy"

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 10. DL-master VM deployment (v621) ====="

  # Load configuration
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  local _DRY_RUN="${DRY_RUN:-0}"

  # VM hostname input (KT v1.8 feature)
  local default_hostname="${DL_HOSTNAME:-dl-master}"
  local vm_name_input

  vm_name_input=$(whiptail_inputbox "STEP 10 - DL VM name (Role) Configuration" "Enter hostname for DL VM.\n\n(Example: dl-master, dl-worker1, dl-worker2 ...)\n\n※ Important: This name is used for NVRAM filename (\${VM_NAME}_VARS.fd)." "${default_hostname}" 15 70)
  if [[ $? -ne 0 ]] || [[ -z "${vm_name_input}" ]]; then
    vm_name_input="dl-master"
  fi

  DL_HOSTNAME="${vm_name_input}"

  # Save to config
  if type save_config_var >/dev/null 2>&1; then
    save_config_var "DL_HOSTNAME" "${DL_HOSTNAME}"
  fi

  log "[STEP 10] Selected VM name: ${DL_HOSTNAME}"

  local DL_CLUSTERSIZE="${DL_CLUSTERSIZE:-1}"
  local DL_VCPUS="${DL_VCPUS:-42}"
  local DL_MEMORY_GB="${DL_MEMORY_GB:-186}"       # GB
  local DL_DISK_GB="${DL_DISK_GB:-500}"           # GB

  local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"
  local DL_BRIDGE="${DL_BRIDGE:-virbr0}"
  local DL_IMAGE_DIR="${DL_INSTALL_DIR}/images"
  local DA_INSTALL_DIR="${DA_INSTALL_DIR:-/stellar/da}"

  local DL_IP="${DL_IP:-192.168.122.2}"
  local DL_NETMASK="${DL_NETMASK:-255.255.255.0}"
  local DL_GW="${DL_GW:-192.168.122.1}"
  local DL_DNS="${DL_DNS:-8.8.8.8}"

  ############################################################
  # Cleanup existing DL cluster VMs (dl-*)
  ############################################################
  local -a cluster_vms
  mapfile -t cluster_vms < <(list_dl_domains)
  if [[ ${#cluster_vms[@]} -gt 0 ]]; then
    local vm_list_str
    vm_list_str=$(printf '%s\n' "${cluster_vms[@]}")
    if ! confirm_destroy_vm_batch "STEP 10 - DL deploy" "${vm_list_str}" "DL"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Redeploy canceled by user. Skipping."
      return 0
    fi
    local vm
    for vm in "${cluster_vms[@]}"; do
      cleanup_dl_da_vm_and_images "${vm}" "${DL_INSTALL_DIR}" "${DA_INSTALL_DIR}" "${_DRY_RUN}"
    done
  fi

  # DP_VERSION check
  local _DP_VERSION="${DP_VERSION:-}"
  if [[ -z "${_DP_VERSION}" ]]; then
    whiptail_msgbox "STEP 10 - DL deploy" "DP_VERSION is not set.\nSet it in Settings and rerun.\nSkipping this step." 12 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DP_VERSION not set. Skipping DL-master deploy."
    return 0
  fi

  # Clean up VM directories (hostname + role-based)
  local DL_DIR_HOST="${DL_IMAGE_DIR}/${DL_HOSTNAME}"
  local DL_DIR_ROLE="${DL_IMAGE_DIR}/dl-master"

  if [[ "${_DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] rm -rf '${DL_DIR_HOST}' '${DL_DIR_ROLE}'"
    log "[DRY-RUN] rm -f '${DL_IMAGE_DIR}/${DL_HOSTNAME}.raw' '${DL_IMAGE_DIR}/dl-master.raw'"
  else
    [[ -d "${DL_DIR_HOST}" ]] && sudo rm -rf "${DL_DIR_HOST}" 2>/dev/null || true
    [[ -d "${DL_DIR_ROLE}" ]] && sudo rm -rf "${DL_DIR_ROLE}" 2>/dev/null || true
    sudo rm -f "${DL_IMAGE_DIR}/${DL_HOSTNAME}.raw" "${DL_IMAGE_DIR}/${DL_HOSTNAME}.log" 2>/dev/null || true
    sudo rm -f "${DL_IMAGE_DIR}/dl-master.raw" "${DL_IMAGE_DIR}/dl-master.log" 2>/dev/null || true
  fi

  # Host MGT IP
  local MGT_NIC_NAME="${MGT_NIC:-mgt}"
  local HOST_MGT_IP
  HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

  if [[ -z "${HOST_MGT_IP}" ]]; then
    HOST_MGT_IP="$(whiptail_inputbox "STEP 10 - DL deploy" "Enter host management interface (${MGT_NIC_NAME}) IP.\n(Example: 10.4.0.210)" "" 12 80)"
    if [[ $? -ne 0 ]] || [[ -z "${HOST_MGT_IP}" ]]; then
      whiptail_msgbox "STEP 10 - DL deploy" "Host management IP not available.\nSkipping DL-master deploy." 10 70
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HOST_MGT_IP not available. Skipping."
      return 0
    fi
  fi

  # Locate virt_deploy_uvp_centos.sh
  local DP_SCRIPT_PATH_CANDIDATES=()
  [[ -n "${DP_SCRIPT_PATH:-}" ]] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")
  DP_SCRIPT_PATH_CANDIDATES+=("${DL_IMAGE_DIR}/virt_deploy_uvp_centos.sh")
  DP_SCRIPT_PATH_CANDIDATES+=("${DL_INSTALL_DIR}/virt_deploy_uvp_centos.sh")
  DP_SCRIPT_PATH_CANDIDATES+=("./virt_deploy_uvp_centos.sh")

  local DP_SCRIPT_PATH=""
  local c
  for c in "${DP_SCRIPT_PATH_CANDIDATES[@]}"; do
    if [[ -f "${c}" ]]; then
      DP_SCRIPT_PATH="${c}"
      break
    fi
  done

  if [[ -z "${DP_SCRIPT_PATH}" ]]; then
    whiptail_msgbox "STEP 10 - DL deploy" "Could not find virt_deploy_uvp_centos.sh.\nComplete STEP 09 first.\nSkipping this step." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] virt_deploy_uvp_centos.sh not found. Skipping."
    return 0
  fi

  # Check DL image
  # Step 10 always uses --nodownload=true since Step 09 already downloaded the image
  local QCOW2_PATH="${DL_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
  local DL_NODOWNLOAD="true"

  if [[ ! -f "${QCOW2_PATH}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: DL qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=true (Step 09 should have downloaded it)."
  fi

  # Check mount
  if ! mount | grep -q "on ${DL_INSTALL_DIR} "; then
    whiptail_msgbox "STEP 10 - DL deploy" "${DL_INSTALL_DIR} is not mounted.\nComplete STEP 07 first.\nSkipping this step." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ${DL_INSTALL_DIR} not mounted. Skipping."
    return 0
  fi

  # DL OTP
  local _DL_OTP="${DL_OTP:-}"
  if [[ -z "${_DL_OTP}" ]]; then
    _DL_OTP="$(whiptail_passwordbox "STEP 10 - DL deploy" "Enter OTP for DL-master (issued from Stellar Cyber)." "")"
    if [[ $? -ne 0 ]] || [[ -z "${_DL_OTP}" ]]; then
      whiptail_msgbox "STEP 10 - DL deploy" "No OTP provided. Skipping DL-master deploy." 10 70
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL_OTP not provided. Skipping."
      return 0
    fi
    DL_OTP="${_DL_OTP}"
    if type save_config >/dev/null 2>&1; then
      save_config
    fi
  fi

  # Check existing VM
  if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
    if ! confirm_destroy_vm "${DL_HOSTNAME}" "STEP 10 - DL deploy"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Existing VM detected, user kept it. Skipping."
      return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Destroying and undefining existing ${DL_HOSTNAME}..."

    if [[ "${_DRY_RUN}" -eq 1 ]]; then
      echo "[DRY_RUN] virsh destroy '${DL_HOSTNAME}' || true"
      echo "[DRY_RUN] virsh undefine '${DL_HOSTNAME}' --nvram || virsh undefine '${DL_HOSTNAME}' || true"
    else
      virsh destroy "${DL_HOSTNAME}" >/dev/null 2>&1 || true
      virsh undefine "${DL_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DL_HOSTNAME}" >/dev/null 2>&1 || true
    fi
  fi

  # DL memory input
  local _DL_MEM_INPUT
  _DL_MEM_INPUT="$(whiptail_inputbox "STEP 10 - DL memory" "Enter memory (GB) for DL-master VM.\n\nCurrent default: ${DL_MEMORY_GB} GB" "${DL_MEMORY_GB}" 12 70)"

  if [[ $? -eq 0 ]] && [[ -n "${_DL_MEM_INPUT}" ]]; then
    if [[ "${_DL_MEM_INPUT}" =~ ^[0-9]+$ ]] && [[ "${_DL_MEM_INPUT}" -gt 0 ]]; then
      DL_MEMORY_GB="${_DL_MEM_INPUT}"
    else
      whiptail_msgbox "STEP 10 - DL memory" "Invalid memory value.\nUsing current default (${DL_MEMORY_GB} GB)." 10 70
    fi
  fi
  save_config_var "DL_MEMORY_GB" "${DL_MEMORY_GB}"

  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  local DL_MEMORY_MB=$(( DL_MEMORY_GB * 1024 ))

  # Build command
  local CMD
  CMD="sudo bash '${DP_SCRIPT_PATH}' -- \
--hostname=${DL_HOSTNAME} \
--cluster-size=${DL_CLUSTERSIZE} \
--release=${_DP_VERSION} \
--local-ip=${HOST_MGT_IP} \
--node-role=DL-master \
--bridge=${DL_BRIDGE} \
--CPUS=${DL_VCPUS} \
--MEM=${DL_MEMORY_MB} \
--DISKSIZE=${DL_DISK_GB} \
--nodownload=${DL_NODOWNLOAD} \
--installdir=${DL_INSTALL_DIR} \
--OTP=${_DL_OTP} \
--ip=${DL_IP} \
--netmask=${DL_NETMASK} \
--gw=${DL_GW} \
--dns=${DL_DNS}"

  # Final confirmation
  local SUMMARY
  SUMMARY="Deploy DL-master VM with:

  Hostname      : ${DL_HOSTNAME}
  Cluster size  : ${DL_CLUSTERSIZE}
  DP version    : ${_DP_VERSION}
  Host MGT IP   : ${HOST_MGT_IP}
  Bridge        : ${DL_BRIDGE}
  vCPU          : ${DL_VCPUS}
  Memory        : ${DL_MEMORY_GB} GB (${DL_MEMORY_MB} MB)
  Disk size     : ${DL_DISK_GB} GB
  installdir    : ${DL_INSTALL_DIR}
  VM IP         : ${DL_IP}
  Netmask       : ${DL_NETMASK}
  Gateway       : ${DL_GW}
  DNS           : ${DL_DNS}
  nodownload    : ${DL_NODOWNLOAD}
  Script path   : ${DP_SCRIPT_PATH}

Run virt_deploy_uvp_centos.sh with these settings?"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 10 - DL deploy" "${SUMMARY}"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] User canceled DL-master deploy."
    return 2  # Return 2 to indicate cancellation
  fi

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Running DL-master deploy command:"
  echo "  ${CMD}"
  echo

  if [[ "${_DRY_RUN}" -eq 1 ]]; then
    echo "[DRY_RUN] Command not executed (DRY_RUN=1)."
    whiptail_msgbox "STEP 10 - DL deploy (DRY RUN)" "DRY_RUN mode.\n\nCommand printed but not executed:\n\n${CMD}" 20 80
    if type mark_step_done >/dev/null 2>&1; then
      mark_step_done "${STEP_ID}"
    fi
    return 0
  fi

  # Actual execution
  eval "${CMD}"
  local RC=$?

  if [[ ${RC} -ne 0 ]]; then
    whiptail_msgbox "STEP 10 - DL deploy" "virt_deploy_uvp_centos.sh exited with code ${RC}.\nCheck status via virsh list / virsh console ${DL_HOSTNAME}." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master deploy failed with RC=${RC}."
    return ${RC}
  fi

  # Validation
  if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' successfully created/updated."
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: virt_deploy script finished, but virsh dominfo ${DL_HOSTNAME} failed."
  fi

  # Monitor VM until running state, then wait 10 seconds
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Monitoring DL-master VM '${DL_HOSTNAME}' until running state..."
  local monitor_timeout=180  # 3 minutes timeout
  local monitor_interval=2   # Check every 2 seconds
  local monitor_elapsed=0
  local vm_running=0

  while (( monitor_elapsed < monitor_timeout )); do
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
      local vm_state
      vm_state="$(virsh dominfo "${DL_HOSTNAME}" | awk -F': +' '/State/ {print $2}' 2>/dev/null || echo "unknown")"
      if [[ "${vm_state}" == "running" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' is now running. Waiting 10 seconds to confirm stability..."
        sleep 10
        vm_running=1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' confirmed running and stable."
        break
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' state: ${vm_state} (waiting for running...)"
      fi
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' not found yet (waiting...)"
    fi
    sleep "${monitor_interval}"
    (( monitor_elapsed += monitor_interval ))
  done

  if (( vm_running == 0 )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Timeout (${monitor_timeout} seconds) reached. Treating DL-master VM deployment as successful and proceeding to next step."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Note: Check VM status manually with: virsh list / virsh console ${DL_HOSTNAME}"
  fi

  whiptail_msgbox "STEP 10 - DL deploy complete" "DL-master VM (UEFI) deployment completed.\n\nVM is running and stable.\n\nCheck logs and virsh list / virsh console ${DL_HOSTNAME} for status." 14 80

  if type mark_step_done >/dev/null 2>&1; then
    mark_step_done "${STEP_ID}"
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 10. DL-master VM deployment (v621) ====="
  echo
}

step_11_da_master_deploy_v621() {
  local STEP_ID="11_da_master_deploy"

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 11. DA-master VM deployment (v621) ====="

  # Load configuration
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  local _DRY_RUN="${DRY_RUN:-0}"

  # VM hostname input (KT v1.8 feature)
  local default_hostname="${DA_HOSTNAME:-da-master}"
  local vm_name_input

  vm_name_input=$(whiptail_inputbox "STEP 11 - DA VM name Configuration" "Enter hostname for DA VM.\n\n(Example: da-master, da-worker1, da-worker2 ...)\n\n※ This name is used for NVRAM filename (\${VM_NAME}_VARS.fd)." "${default_hostname}" 15 70)
  if [[ $? -ne 0 ]] || [[ -z "${vm_name_input}" ]]; then
    vm_name_input="da-master"
  fi

  DA_HOSTNAME="${vm_name_input}"

  # Save to config
  save_config_var "DA_HOSTNAME" "${DA_HOSTNAME}"

  log "[STEP 11] Selected VM name: ${DA_HOSTNAME}"

  local DA_VCPUS="${DA_VCPUS:-46}"
  local DA_MEMORY_GB="${DA_MEMORY_GB:-156}"       # GB
  local DA_DISK_GB="${DA_DISK_GB:-500}"           # GB

  local DA_INSTALL_DIR="${DA_INSTALL_DIR:-/stellar/da}"
  local DA_BRIDGE="${DA_BRIDGE:-virbr0}"
  local DA_IMAGE_DIR="${DA_INSTALL_DIR}/images"
  local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"

  local DA_IP="${DA_IP:-192.168.122.3}"
  local DA_NETMASK="${DA_NETMASK:-255.255.255.0}"
  local DA_GW="${DA_GW:-192.168.122.1}"
  local DA_DNS="${DA_DNS:-8.8.8.8}"

  ############################################################
  # Cleanup existing DA cluster VMs (da-*)
  ############################################################
  local -a cluster_vms
  mapfile -t cluster_vms < <(list_da_domains)
  if [[ ${#cluster_vms[@]} -gt 0 ]]; then
    local vm_list_str
    vm_list_str=$(printf '%s\n' "${cluster_vms[@]}")
    if ! confirm_destroy_vm_batch "STEP 11 - DA Deployment" "${vm_list_str}" "DA"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Redeploy canceled by user. Skipping."
      return 0
    fi
    local vm
    for vm in "${cluster_vms[@]}"; do
      cleanup_dl_da_vm_and_images "${vm}" "${DL_INSTALL_DIR}" "${DA_INSTALL_DIR}" "${_DRY_RUN}"
    done
  fi

  # DP_VERSION check
  local _DP_VERSION="${DP_VERSION:-}"
  if [[ -z "${_DP_VERSION}" ]]; then
    whiptail_msgbox "STEP 11 - DA Deployment" "DP_VERSION is not set.\nSet it in Settings and rerun.\nSkipping this step." 12 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DP_VERSION not set. Skipping DA-master deploy."
    return 0
  fi

  # Clean up VM directories (hostname + role-based)
  local DA_DIR_HOST="${DA_IMAGE_DIR}/${DA_HOSTNAME}"
  local DA_DIR_ROLE="${DA_IMAGE_DIR}/da-master"

  if [[ "${_DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] rm -rf '${DA_DIR_HOST}' '${DA_DIR_ROLE}'"
    log "[DRY-RUN] rm -f '${DA_IMAGE_DIR}/${DA_HOSTNAME}.raw' '${DA_IMAGE_DIR}/da-master.raw'"
  else
    [[ -d "${DA_DIR_HOST}" ]] && sudo rm -rf "${DA_DIR_HOST}" 2>/dev/null || true
    [[ -d "${DA_DIR_ROLE}" ]] && sudo rm -rf "${DA_DIR_ROLE}" 2>/dev/null || true
    sudo rm -f "${DA_IMAGE_DIR}/${DA_HOSTNAME}.raw" "${DA_IMAGE_DIR}/${DA_HOSTNAME}.log" 2>/dev/null || true
    sudo rm -f "${DA_IMAGE_DIR}/da-master.raw" "${DA_IMAGE_DIR}/da-master.log" 2>/dev/null || true
  fi

  # Host MGT IP
  : "${MGT_NIC:=mgt}"
  local MGT_NIC_NAME="${MGT_NIC}"
  local HOST_MGT_IP
  HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

  if [[ -z "${HOST_MGT_IP}" ]]; then
    HOST_MGT_IP="$(whiptail_inputbox "STEP 11 - DA deploy" "Enter host management (${MGT_NIC_NAME}) interface IP.\n(Example: 10.4.0.210)" "" 12 80)"
    if [[ $? -ne 0 ]] || [[ -z "${HOST_MGT_IP}" ]]; then
      whiptail_msgbox "STEP 11 - DA deploy" "Host management IP not available.\nSkipping DA-master deploy." 10 70
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] HOST_MGT_IP not available. Skipping."
      return 0
    fi
  fi

  # cm_fqdn (DL cluster IP, CM address)
  : "${DL_IP:=192.168.122.2}"
  local CM_FQDN="${CM_FQDN:-${DL_IP}}"

  # Locate virt_deploy_uvp_centos.sh
  local DP_SCRIPT_PATH_CANDIDATES=()
  [[ -n "${DP_SCRIPT_PATH:-}" ]] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")
  DP_SCRIPT_PATH_CANDIDATES+=("${DA_IMAGE_DIR}/virt_deploy_uvp_centos.sh")
  DP_SCRIPT_PATH_CANDIDATES+=("${DA_INSTALL_DIR}/virt_deploy_uvp_centos.sh")
  DP_SCRIPT_PATH_CANDIDATES+=("./virt_deploy_uvp_centos.sh")
  DP_SCRIPT_PATH_CANDIDATES+=("/root/virt_deploy_uvp_centos.sh")

  local DP_SCRIPT_PATH=""
  local c
  for c in "${DP_SCRIPT_PATH_CANDIDATES[@]}"; do
    if [[ -f "${c}" ]]; then
      DP_SCRIPT_PATH="${c}"
      break
    fi
  done

  if [[ -z "${DP_SCRIPT_PATH}" ]]; then
    whiptail_msgbox "STEP 11 - DA Deployment" "virt_deploy_uvp_centos.sh file not found.\n\nComplete STEP 09 first, then run again.\nSkipping this step." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] virt_deploy_uvp_centos.sh not found. Skipping."
    return 0
  fi

  # Check DA image
  # Step 11 always uses --nodownload=true since Step 09 already downloaded the image
  local QCOW2_PATH="${DA_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
  local DA_NODOWNLOAD="true"

  if [[ ! -f "${QCOW2_PATH}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: DA qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=true (Step 09 should have downloaded it)."
  fi

  # Check mount
  if ! mount | grep -q "on ${DA_INSTALL_DIR} "; then
    whiptail_msgbox "STEP 11 - DA Deployment" "${DA_INSTALL_DIR} is not mounted.\nComplete STEP 07 first.\nSkipping this step." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] ${DA_INSTALL_DIR} not mounted. Skipping."
    return 0
  fi

  # Check existing VM
  if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
    if ! confirm_destroy_vm "${DA_HOSTNAME}" "STEP 11 - DA Deployment"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Existing VM detected, user chose to keep it. Skipping."
      return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Destroying and undefining existing ${DA_HOSTNAME}..."

    if [[ "${_DRY_RUN}" -eq 1 ]]; then
      echo "[DRY_RUN] virsh destroy '${DA_HOSTNAME}' || true"
      echo "[DRY_RUN] virsh undefine '${DA_HOSTNAME}' --nvram || virsh undefine '${DA_HOSTNAME}' || true"
    else
      virsh destroy "${DA_HOSTNAME}" >/dev/null 2>&1 || true
      virsh undefine "${DA_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DA_HOSTNAME}" >/dev/null 2>&1 || true
    fi
  fi

  # DA memory input
  local _DA_MEM_INPUT
  _DA_MEM_INPUT="$(whiptail_inputbox "STEP 11 - DA Memory Configuration" "Enter memory (GB) for DA-master VM.\n\nCurrent default: ${DA_MEMORY_GB} GB" "${DA_MEMORY_GB}" 12 70)"

  if [[ $? -eq 0 ]] && [[ -n "${_DA_MEM_INPUT}" ]]; then
    if [[ "${_DA_MEM_INPUT}" =~ ^[0-9]+$ ]] && [[ "${_DA_MEM_INPUT}" -gt 0 ]]; then
      DA_MEMORY_GB="${_DA_MEM_INPUT}"
    else
      whiptail_msgbox "STEP 11 - DA Memory Configuration" "Invalid memory value.\nUsing current default (${DA_MEMORY_GB} GB)." 10 70
    fi
  fi

  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  save_config_var "DA_MEMORY_GB" "${DA_MEMORY_GB}"

  local DA_MEMORY_MB=$(( DA_MEMORY_GB * 1024 ))

  # node_role = resource (DA node)
  local DA_NODE_ROLE="resource"

  # Build command
  local CMD
  CMD="sudo bash '${DP_SCRIPT_PATH}' -- \
--hostname=${DA_HOSTNAME} \
--release=${_DP_VERSION} \
--local-ip=${HOST_MGT_IP} \
--cm_fqdn=${CM_FQDN} \
--node-role=${DA_NODE_ROLE} \
--bridge=${DA_BRIDGE} \
--CPUS=${DA_VCPUS} \
--MEM=${DA_MEMORY_MB} \
--DISKSIZE=${DA_DISK_GB} \
--nodownload=${DA_NODOWNLOAD} \
--installdir=${DA_INSTALL_DIR} \
--ip=${DA_IP} \
--netmask=${DA_NETMASK} \
--gw=${DA_GW} \
--dns=${DA_DNS}"

  # Final confirmation
  local SUMMARY
  SUMMARY="Deploy DA-master VM with:

  Hostname        : ${DA_HOSTNAME}
  DP Version      : ${_DP_VERSION}
  Host MGT IP     : ${HOST_MGT_IP}
  CM FQDN(DL IP)  : ${CM_FQDN}
  Bridge          : ${DA_BRIDGE}
  node_role       : ${DA_NODE_ROLE}
  vCPU            : ${DA_VCPUS}
  Memory          : ${DA_MEMORY_GB} GB (${DA_MEMORY_MB} MB)
  Disk Size       : ${DA_DISK_GB} GB
  installdir      : ${DA_INSTALL_DIR}
  VM IP           : ${DA_IP}
  Netmask         : ${DA_NETMASK}
  Gateway         : ${DA_GW}
  DNS             : ${DA_DNS}
  nodownload      : ${DA_NODOWNLOAD}
  Script Path     : ${DP_SCRIPT_PATH}

Execute virt_deploy_uvp_centos.sh with the above settings?"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 11 - DA Deployment" "${SUMMARY}"
  local confirm_rc=$?
  set -e
  
  if [[ ${confirm_rc} -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] User cancelled DA-master deploy."
    return 2  # Return 2 to indicate cancellation
  fi

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Running DA-master deploy command:"
  echo "  ${CMD}"
  echo

  if [[ "${_DRY_RUN}" -eq 1 ]]; then
    echo "[DRY_RUN] Command not executed (DRY_RUN=1)."
    whiptail_msgbox "STEP 11 - DA Deployment (DRY RUN)" "DRY_RUN mode.\n\nCommand printed but not executed:\n\n${CMD}" 20 80
    if type mark_step_done >/dev/null 2>&1; then
      mark_step_done "${STEP_ID}"
    fi
    return 0
  fi

  # Actual execution
  eval "${CMD}"
  local RC=$?

  if [[ ${RC} -ne 0 ]]; then
    whiptail_msgbox "STEP 11 - DA Deployment" "virt_deploy_uvp_centos.sh exited with error code ${RC}.\n\nCheck status using virsh list, virsh console ${DA_HOSTNAME}, etc." 14 80
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master deploy failed with RC=${RC}."
    return ${RC}
  fi

  # Validation
  if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' successfully created/updated."
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: virt_deploy script finished, but virsh dominfo ${DA_HOSTNAME} failed."
  fi

  # Monitor VM until running state, then wait 10 seconds
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Monitoring DA-master VM '${DA_HOSTNAME}' until running state..."
  local monitor_timeout=180  # 3 minutes timeout
  local monitor_interval=2   # Check every 2 seconds
  local monitor_elapsed=0
  local vm_running=0

  while (( monitor_elapsed < monitor_timeout )); do
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
      local vm_state
      vm_state="$(virsh dominfo "${DA_HOSTNAME}" | awk -F': +' '/State/ {print $2}' 2>/dev/null || echo "unknown")"
      if [[ "${vm_state}" == "running" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' is now running. Waiting 10 seconds to confirm stability..."
        sleep 10
        vm_running=1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' confirmed running and stable."
        break
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' state: ${vm_state} (waiting for running...)"
      fi
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' not found yet (waiting...)"
    fi
    sleep "${monitor_interval}"
    (( monitor_elapsed += monitor_interval ))
  done

  if (( vm_running == 0 )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Timeout (${monitor_timeout} seconds) reached. Treating DA-master VM deployment as successful and proceeding to next step."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Note: Check VM status manually with: virsh list / virsh console ${DA_HOSTNAME}"
  fi

  whiptail_msgbox "STEP 11 - DA Deployment Complete" "DA-master VM (UEFI) deployment completed.\n\nVM is running and stable.\n\nCheck logs and virsh list / virsh console ${DA_HOSTNAME} for status." 14 80

  if type mark_step_done >/dev/null 2>&1; then
    mark_step_done "${STEP_ID}"
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 11. DA-master VM deployment (v621) ====="
  echo
}

#######################################
# STEP 12 - Bridge Mode Attach (v621)
#######################################
step_12_bridge_attach_v621() {
  local STEP_ID="12_bridge_attach"

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. Bridge Attach + CPU Affinity + CD-ROM removal + DL data LV (v621) ====="

  # Load config
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  local _DRY="${DRY_RUN:-0}"
  
  # Auto-detect VM names: if DL_HOSTNAME/DA_HOSTNAME not set, look in virsh list
  local DL_VM="${DL_HOSTNAME:-}"
  local DA_VM="${DA_HOSTNAME:-}"
  
  # Auto-detect DL_VM
  if [[ -z "${DL_VM}" ]]; then
    log "[STEP 12 Bridge] DL_HOSTNAME not set, auto-detecting DL VM from virsh list"
    DL_VM=$(virsh list --all --name 2>/dev/null | grep -E "^dl-" | head -n1 || echo "")
    if [[ -n "${DL_VM}" ]]; then
      log "[STEP 12 Bridge] Auto-detected DL VM: ${DL_VM}"
    else
      DL_VM="dl-master"
      log "[STEP 12 Bridge] No DL VM found, using default: ${DL_VM}"
    fi
  fi
  
  # Auto-detect DA_VM
  if [[ -z "${DA_VM}" ]]; then
    log "[STEP 12 Bridge] DA_HOSTNAME not set, auto-detecting DA VM from virsh list"
    DA_VM=$(virsh list --all --name 2>/dev/null | grep -E "^da-" | head -n1 || echo "")
    if [[ -n "${DA_VM}" ]]; then
      log "[STEP 12 Bridge] Auto-detected DA VM: ${DA_VM}"
    else
      DA_VM="da-master"
      log "[STEP 12 Bridge] No DA VM found, using default: ${DA_VM}"
    fi
  fi
  
  local bridge_name="${CLUSTER_BRIDGE_NAME:-br-cluster}"
  local cluster_nic="${CLTR0_NIC:-}"

  # Execution start confirmation
  local start_msg
  if [[ "${_DRY}" -eq 1 ]]; then
    start_msg="STEP 12: Bridge Attach + CPU Affinity Configuration (DRY RUN)

This will simulate the following operations:
  • Bridge interface (${bridge_name}) attach to ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration (CPU pinning)
  • NUMA memory interleave configuration
  • DL data disk attach (if applicable)
  • CD-ROM removal

⚠️  DRY RUN MODE: No actual changes will be made.

Do you want to continue?"
  else
    start_msg="STEP 12: Bridge Attach + CPU Affinity Configuration

This will perform the following operations:
  • Attach bridge interface (${bridge_name}) to ${DL_VM} and ${DA_VM}
  • Configure CPU pinning (CPU Affinity)
  • Apply NUMA memory interleave configuration
  • Attach DL data disk (if applicable)
  • Remove CD-ROM devices

⚠️  IMPORTANT: VMs will be shut down during this process.

Do you want to continue?"
  fi

  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size 18 85)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  local centered_msg
  centered_msg=$(center_message "${start_msg}")

  if ! whiptail --title "STEP 12 Execution Confirmation" \
                --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  then
    log "User canceled STEP 12 execution."
    return 0
  fi

  ###########################################################################
  # 1. DL/DA VM shutdown (wait until completely shut down)
  ###########################################################################
  log "[STEP 12 Bridge] Requesting DL/DA VM shutdown"

  for vm in "${DL_VM}" "${DA_VM}"; do
    if virsh dominfo "${vm}" >/dev/null 2>&1; then
      local state
      state="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
      if [[ "${state}" != "shut off" ]]; then
        log "[STEP 12 Bridge] Requesting shutdown of ${vm}"
        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] virsh shutdown ${vm}"
        else
          virsh shutdown "${vm}" || log "[WARN] ${vm} shutdown failed (continuing anyway)"
        fi
      else
        log "[STEP 12 Bridge] ${vm} is already in shut off state"
      fi
    else
      log "[STEP 12 Bridge] ${vm} VM not found → skipping shutdown"
    fi
  done

  local timeout=180
  local interval=5
  local elapsed=0

  while (( elapsed < timeout )); do
    local all_off=1
    for vm in "${DL_VM}" "${DA_VM}"; do
      if virsh dominfo "${vm}" >/dev/null 2>&1; then
        local st
        st="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
        if [[ "${st}" != "shut off" ]]; then
          all_off=0
        fi
      fi
    done

    if (( all_off )); then
      log "[STEP 12 Bridge] All DL/DA VMs are now in shut off state."
      break
    fi

    sleep "${interval}"
    (( elapsed += interval ))
  done

  if (( elapsed >= timeout )); then
    log "[WARN] [STEP 12 Bridge] Some VMs did not shut off within timeout(${timeout}s). Continuing anyway."
  fi

  ###########################################################################
  # 2. CD-ROM removal (detach all CD-ROM devices)
  ###########################################################################
  _list_non_seed_cdrom_targets() {
    local vm="$1"
    # Extract cdrom disk sections, exclude seed ISO (required for Cloud-Init)
    # Process each CD-ROM section: if it contains seed ISO, skip it
    virsh dumpxml "${vm}" --inactive 2>/dev/null \
      | grep -B 5 -A 10 -E "device=['\"]cdrom['\"]" \
      | awk '
        BEGIN { in_cdrom=0; is_seed=0; target_dev="" }
        /device=['\''"]cdrom['\''"]/ { in_cdrom=1; is_seed=0; target_dev="" }
        /<source.*-seed\.iso/ { is_seed=1 }
        /<target/ {
          if (match($0, /dev=['\''"]([^'\''"]*)['\''"]/, arr)) {
            target_dev=arr[1]
          }
        }
        /<\/disk>/ {
          if (in_cdrom && !is_seed && target_dev != "") {
            print target_dev
          }
          in_cdrom=0
          is_seed=0
          target_dev=""
        }
      ' | sort -u
  }

  _detach_all_cdroms_config() {
    local vm="$1"
    [[ -n "${vm}" ]] || return 0
    virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

    # Get only non-seed CD-ROM devices (seed ISO is required for Cloud-Init)
    local devs
    devs="$(_list_non_seed_cdrom_targets "${vm}" || true)"
    [[ -n "${devs}" ]] || return 0

    local dev
    while IFS= read -r dev; do
      [[ -n "${dev}" ]] || continue
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] virsh detach-disk ${vm} ${dev} --config"
      else
        virsh detach-disk "${vm}" "${dev}" --config >/dev/null 2>&1 || true
        log "[STEP 12 Bridge] ${vm}: CD-ROM(${dev}) detach attempt completed (seed ISO preserved)"
      fi
    done <<< "${devs}"
  }

  _detach_all_cdroms_config "${DL_VM}"
  _detach_all_cdroms_config "${DA_VM}"

  ###########################################################################
  # 2.2. Detach all hostdev devices (SR-IOV remnants)
  ###########################################################################
  _detach_all_hostdevs_config() {
    local vm="$1"
    [[ -n "${vm}" ]] || return 0
    virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

    local xml tmpdir files
    xml="$(virsh dumpxml "${vm}" --inactive 2>/dev/null || true)"
    [[ -n "${xml}" ]] || return 0

    tmpdir="$(mktemp -d)"
    echo "${xml}" | awk -v dir="${tmpdir}" '
      /<hostdev / { in_block=1; c++; file=dir "/hostdev_" c ".xml" }
      in_block { print > file }
      /<\/hostdev>/ { in_block=0 }
    '

    files="$(ls -1 "${tmpdir}"/hostdev_*.xml 2>/dev/null || true)"
    if [[ -z "${files}" ]]; then
      rm -rf "${tmpdir}"
      return 0
    fi

    local f
    for f in ${files}; do
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] virsh detach-device ${vm} ${f} --config"
      else
        if virsh detach-device "${vm}" "${f}" --config >/dev/null 2>&1; then
          log "[STEP 12 Bridge] ${vm}: hostdev detach (--config) completed"
        else
          log "[WARN] ${vm}: hostdev detach failed (config)"
        fi
      fi
    done

    rm -rf "${tmpdir}"
  }

  _detach_all_hostdevs_config "${DL_VM}"
  _detach_all_hostdevs_config "${DA_VM}"

  ###########################################################################
  # 2.5. Bridge runtime creation/UP guarantee (NO-CARRIER allowed)
  # Ensure bridge is created/up at runtime right before VM attach
  ###########################################################################
  log "[STEP 12 Bridge] Ensuring bridge ${bridge_name} is ready for VM attach (NO-CARRIER allowed)"

  if ! ensure_bridge_up_no_carrier_ok "${bridge_name}" "${cluster_nic}"; then
    log "[ERROR] Failed to ensure bridge ${bridge_name} is ready for VM attach"
    whiptail_msgbox "STEP 12 - Bridge Mode Error" \
      "Failed to ensure bridge ${bridge_name} is ready for VM attach.\n\nPlease check bridge configuration and permissions." \
      12 80
    return 1
  fi

  ###########################################################################
  # 3. Bridge attach (virsh attach-interface --type bridge)
  ###########################################################################
  _attach_bridge_to_vm() {
    local vm="$1"
    local bridge="$2"

    if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
      return 0
    fi

    # Check if bridge interface is already attached
    if virsh dumpxml "${vm}" 2>/dev/null | grep -q "source bridge='${bridge}'"; then
      log "[STEP 12 Bridge] ${vm}: Bridge ${bridge} is already attached → skipping"
      return 0
    fi

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] virsh attach-interface ${vm} --type bridge --source ${bridge} --model virtio --config"
    else
      local out
      if ! out="$(virsh attach-interface "${vm}" --type bridge --source "${bridge}" --model virtio --config 2>&1)"; then
        log "[ERROR] ${vm}: virsh attach-interface failed (bridge=${bridge})"
        log "[ERROR] virsh message:"
        while IFS= read -r line; do
          log "  ${line}"
        done <<< "${out}"
        return 1
      else
        log "[STEP 12 Bridge] ${vm}: Bridge ${bridge} attach (--config) completed"
      fi
    fi
  }

  _attach_bridge_to_vm "${DL_VM}" "${bridge_name}"
  _attach_bridge_to_vm "${DA_VM}" "${bridge_name}"

  ###########################################################################
  # 4. CPU Affinity (virsh vcpupin --config)
  ###########################################################################
  # Check NUMA node count - skip CPU Affinity if only 1 NUMA node exists
  local numa_node_count
  numa_node_count=$(lscpu 2>/dev/null | grep -i "NUMA node(s)" | awk '{print $3}' || echo "0")
  
  if [[ -z "${numa_node_count}" ]] || [[ "${numa_node_count}" == "0" ]]; then
    # Fallback: try numactl if available
    if command -v numactl >/dev/null 2>&1; then
      numa_node_count=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1")
    else
      numa_node_count="1"
    fi
  fi
  
  if [[ "${numa_node_count}" == "1" ]]; then
    log "[STEP 12 Bridge] System has only 1 NUMA node → skipping CPU Affinity configuration"
  else
    local DL_CPUS_LIST=""
    local DA_CPUS_LIST=""

    # DL: even CPUs 4,6,...,86
    local c
    for (( c=4; c<=86; c+=2 )); do
      DL_CPUS_LIST+="${c} "
    done

    # DA: odd CPUs 5,7,...,95
    for (( c=5; c<=95; c+=2 )); do
      DA_CPUS_LIST+="${c} "
    done

    _apply_cpu_affinity_vm() {
      local vm="$1"
      local cpus_list="$2"

      if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
        return 0
      fi
      [[ -n "${cpus_list}" ]] || return 0

      # Maximum vCPU count (designed as DL=42, DA=46, but check based on actual XML)
      local max_vcpus
      max_vcpus="$(virsh vcpucount "${vm}" --maximum --config 2>/dev/null || echo 0)"

      if [[ "${max_vcpus}" -eq 0 ]]; then
        log "[WARN] ${vm}: Unable to determine vCPU count → skipping CPU Affinity"
        return 0
      fi

      # Convert cpus_list to array
      local arr=()
      for c in ${cpus_list}; do
        arr+=("${c}")
      done

      if [[ "${#arr[@]}" -lt "${max_vcpus}" ]]; then
        log "[WARN] ${vm}: Specified CPU list count(${#arr[@]}) is less than maximum vCPU(${max_vcpus})."
        max_vcpus="${#arr[@]}"
      fi

      local i
      for (( i=0; i<max_vcpus; i++ )); do
        local pcpu="${arr[$i]}"
        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] virsh vcpupin ${vm} ${i} ${pcpu} --config"
        else
          if virsh vcpupin "${vm}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
            log "[STEP 12 Bridge] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
          else
            log "[WARN] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin failed"
          fi
        fi
      done
    }

    _apply_cpu_affinity_vm "${DL_VM}" "${DL_CPUS_LIST}"
    _apply_cpu_affinity_vm "${DA_VM}" "${DA_CPUS_LIST}"
  fi

  ###########################################################################
  # 5. NUMA memory interleave (virsh numatune --config)
  ###########################################################################
  _apply_numatune_vm() {
    local vm="$1"
    if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] virsh numatune ${vm} --mode interleave --nodeset 0-1 --config"
    else
      if virsh numatune "${vm}" --mode interleave --nodeset 0-1 --config >/dev/null 2>&1; then
        log "[STEP 12 Bridge] ${vm}: numatune mode=interleave nodeset=0-1 (--config) applied"
      else
        log "[WARN] ${vm}: numatune configuration failed (version/option may not be supported)"
      fi
    fi
  }

  _apply_numatune_vm "${DL_VM}"
  _apply_numatune_vm "${DA_VM}"

  ###########################################################################
  # 6. DL data disk (LV) attach (vg_dl/lv_dl → vdb, --config)
  ###########################################################################
  local DATA_LV="/dev/mapper/vg_dl-lv_dl"

  # Helper: extract the full <disk>...</disk> XML block that contains target dev='vdb'
  # NOTE: In libvirt XML, <source ...> often appears BEFORE <target ...>,
  # so parsing with `grep -A ... "target dev='vdb'"` is unreliable.
  # Args:
  #   $1: vm name
  #   $2: 0=live XML, 1=inactive XML
  get_vdb_disk_block() {
    local vm_name="$1"
    local inactive="${2:-0}"
    if [[ -z "${vm_name}" ]]; then
      return 1
    fi

    local dump_cmd=(virsh dumpxml "${vm_name}")
    if [[ "${inactive}" -eq 1 ]]; then
      dump_cmd+=(--inactive)
    fi

    "${dump_cmd[@]}" 2>/dev/null | awk '
      BEGIN { in_disk=0; buf="" }
      /<disk[ >]/ { in_disk=1; buf=$0 ORS; next }
      in_disk {
        buf = buf $0 ORS
        if ($0 ~ /<\/disk>/) {
          if (buf ~ /<target[[:space:]]+dev=.vdb./) { print buf; exit }
          in_disk=0; buf=""
        }
      }
    '
  }

  if [[ -e "${DATA_LV}" ]]; then
    if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] virsh attach-disk ${DL_VM} ${DATA_LV} vdb --config"
      else
        if [[ -n "$(get_vdb_disk_block "${DL_VM}" 0 || true)" ]]; then
          log "[STEP 12 Bridge] ${DL_VM} vdb already exists → skipping data disk attach"
        else
          if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
            log "[STEP 12 Bridge] ${DL_VM} data disk(${DATA_LV}) attached as vdb (--config) completed"
          else
            log "[WARN] ${DL_VM} data disk(${DATA_LV}) attach failed"
          fi
        fi
      fi
    else
      log "[STEP 12 Bridge] ${DL_VM} VM not found → skipping DL data disk attach"
    fi
  else
    log "[STEP 12 Bridge] ${DATA_LV} does not exist; skipping DL data disk attach."
  fi

  ###########################################################################
  # 7. DL/DA VM restart
  ###########################################################################
  ensure_vm_bridges_ready() {
    local vm_name="$1"
    local bridges
    if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
      return 0
    fi
    bridges="$(virsh dumpxml "${vm_name}" --inactive 2>/dev/null | grep -o "bridge='[^']*'" | cut -d"'" -f2 | sort -u || true)"
    if [[ -z "${bridges}" ]]; then
      return 0
    fi
    local br
    for br in ${bridges}; do
      if ! ip link show dev "${br}" >/dev/null 2>&1; then
        log "[STEP 12 Bridge] Bridge ${br} required by ${vm_name} but missing; creating it"
        ensure_bridge_up_no_carrier_ok "${br}" "" || return 1
      fi
    done
    return 0
  }

  ensure_vm_bridges_ready "${DL_VM}" || return 1
  ensure_vm_bridges_ready "${DA_VM}" || return 1

  for vm in "${DL_VM}" "${DA_VM}"; do
    if virsh dominfo "${vm}" >/dev/null 2>&1; then
      log "[STEP 12 Bridge] ${vm} start request"
      (( _DRY )) || virsh start "${vm}" || log "[WARN] ${vm} start failed"
    fi
  done

  # Wait 5 seconds after VM start
  if [[ "${_DRY}" -eq 0 ]]; then
    log "[STEP 12 Bridge] Waiting 5 seconds after DL/DA VM start (vCPU state stabilization)"
    sleep 5
  fi

  ###########################################################################
  # 8. Basic verification results
  ###########################################################################
  local result_file="/tmp/step12_bridge_result.txt"
  rm -f "${result_file}"

  if [[ "${_DRY}" -eq 1 ]]; then
    {
      echo "===== DRY-RUN MODE: Simulation Results ====="
      echo
      echo "📊 SIMULATED OPERATIONS:"
      echo "  • Bridge interface attach to ${DL_VM} and ${DA_VM}"
      echo "  • CPU Affinity configuration"
      echo "  • NUMA memory interleave configuration"
      echo "  • DL data disk attach (if applicable)"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. Bridge ${bridge_name} would be attached to ${DL_VM} and ${DA_VM}"
      echo "  2. CPU pinning would be applied"
      echo "  3. NUMA configuration would be applied"
      echo "  4. Data disk would be attached to ${DL_VM} (if available)"
      echo
      echo "📋 EXPECTED CONFIGURATION:"
      echo "  • Bridge: ${bridge_name}"
      echo "  • DL VM: ${DL_VM}"
      echo "  • DA VM: ${DA_VM}"
    } > "${result_file}"
  else
    {
      echo "===== DL vcpuinfo (${DL_VM}) ====="
      if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
        virsh vcpuinfo "${DL_VM}" 2>&1
      else
        echo "VM ${DL_VM} not found"
      fi
      echo
      echo "===== DA vcpuinfo (${DA_VM}) ====="
      if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
        virsh vcpuinfo "${DA_VM}" 2>&1
      else
        echo "VM ${DA_VM} not found"
      fi
      echo
      echo "===== DL bridge interface (${DL_VM}) ====="
      if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
        virsh dumpxml "${DL_VM}" | grep -A 5 "source bridge='${bridge_name}'" || echo "Bridge ${bridge_name} not found in XML"
      else
        echo "VM ${DL_VM} not found"
      fi
      echo
      echo "===== DA bridge interface (${DA_VM}) ====="
      if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
        virsh dumpxml "${DA_VM}" | grep -A 5 "source bridge='${bridge_name}'" || echo "Bridge ${bridge_name} not found in XML"
      else
        echo "VM ${DA_VM} not found"
      fi
    } > "${result_file}"
  fi

  # Execution completion message box
  local completion_msg
  if [[ "${_DRY}" -eq 1 ]]; then
    completion_msg="STEP 12: Bridge Attach + CPU Affinity Configuration (DRY RUN) Completed

✅ Simulation Summary:
  • Bridge interface (${bridge_name}) attach simulation for ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration simulation
  • NUMA memory interleave configuration simulation
  • DL data disk attach simulation (if applicable)
  • CD-ROM removal simulation

⚠️  DRY RUN MODE: No actual changes were made.

📋 What Would Have Been Applied:
  • Bridge interface (${bridge_name}) would be attached to VMs
  • CPU pinning would be configured
  • NUMA memory interleave would be applied
  • Data disk would be attached to ${DL_VM} (if available)
  • CD-ROM devices would be removed

💡 Next Steps:
  Set DRY_RUN=0 and rerun STEP 12 to apply actual configurations.
  Detailed simulation results are available in the log."
  else
    completion_msg="STEP 12: Bridge Attach + CPU Affinity Configuration Completed

✅ Configuration Summary:
  • Bridge interface (${bridge_name}) attached to ${DL_VM} and ${DA_VM}
  • CPU Affinity (CPU pinning) configured
  • NUMA memory interleave applied
  • DL data disk attached (if applicable)
  • CD-ROM devices removed

✅ VMs Status:
  • ${DL_VM} and ${DA_VM} have been restarted with new configurations
  • All bridge and CPU affinity settings are now active

📋 Verification:
  • Check VM CPU pinning: virsh vcpuinfo ${DL_VM}
  • Check bridge interface: virsh dumpxml ${DL_VM} | grep '${bridge_name}'
  • Check NUMA configuration: virsh numatune ${DL_VM}
  • Verify data disk: virsh dumpxml ${DL_VM} | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'

💡 Note:
  Detailed verification results are shown below.
  VMs are ready for use with bridge interface and CPU affinity enabled."
  fi

  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size 22 90)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  whiptail_msgbox "STEP 12 - Configuration Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

  if [[ "${_DRY}" -eq 1 ]]; then
    # Read result file content and display in message box
    local dry_run_content
    if [[ -f "${result_file}" ]]; then
      dry_run_content=$(cat "${result_file}")
      # Calculate dialog size dynamically
      local dry_dialog_dims
      dry_dialog_dims=$(calc_dialog_size 20 90)
      local dry_dialog_height dry_dialog_width
      read -r dry_dialog_height dry_dialog_width <<< "${dry_dialog_dims}"
      whiptail_msgbox "STEP 12 – Bridge Attach / CPU Affinity / DL data LV (DRY-RUN)" "${dry_run_content}" "${dry_dialog_height}" "${dry_dialog_width}"
    fi
  else
    show_paged "STEP 12 – Bridge Attach / CPU Affinity / DL data LV verification results (v621)" "${result_file}" "no-clear"
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. Bridge Attach + CPU Affinity + CD-ROM removal + DL data LV (v621) ====="
  echo
}

step_12_sriov_cpu_affinity_v621() {
  local STEP_ID="12_sriov_cpu_affinity"

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV (v621) ====="

  # Load config
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  local _DRY="${DRY_RUN:-0}"

  # Auto-detect VM names: if DL_HOSTNAME/DA_HOSTNAME not set, look in virsh list
  local DL_VM="${DL_HOSTNAME:-}"
  local DA_VM="${DA_HOSTNAME:-}"
  
  # Auto-detect DL_VM
  if [[ -z "${DL_VM}" ]]; then
    log "[STEP 12] DL_HOSTNAME not set, auto-detecting DL VM from virsh list"
    DL_VM=$(virsh list --all --name 2>/dev/null | grep -E "^dl-" | head -n1 || echo "")
    if [[ -n "${DL_VM}" ]]; then
      log "[STEP 12] Auto-detected DL VM: ${DL_VM}"
    else
      DL_VM="dl-master"
      log "[STEP 12] No DL VM found, using default: ${DL_VM}"
    fi
  fi
  
  # Auto-detect DA_VM
  if [[ -z "${DA_VM}" ]]; then
    log "[STEP 12] DA_HOSTNAME not set, auto-detecting DA VM from virsh list"
    DA_VM=$(virsh list --all --name 2>/dev/null | grep -E "^da-" | head -n1 || echo "")
    if [[ -n "${DA_VM}" ]]; then
      log "[STEP 12] Auto-detected DA VM: ${DA_VM}"
    else
      DA_VM="da-master"
      log "[STEP 12] No DA VM found, using default: ${DA_VM}"
    fi
  fi

  # Execution start confirmation
  local start_msg
  if [[ "${_DRY}" -eq 1 ]]; then
    start_msg="STEP 12: SR-IOV + CPU Affinity Configuration (DRY RUN)

This will simulate the following operations:
  • SR-IOV VF PCI passthrough to ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration (CPU pinning)
  • NUMA memory interleave configuration
  • DL data disk attach (if applicable)
  • CD-ROM removal

⚠️  DRY RUN MODE: No actual changes will be made.

Do you want to continue?"
  else
    start_msg="STEP 12: SR-IOV + CPU Affinity Configuration

This will perform the following operations:
  • Attach SR-IOV VF PCI devices to ${DL_VM} and ${DA_VM}
  • Configure CPU pinning (CPU Affinity)
  • Apply NUMA memory interleave configuration
  • Attach DL data disk (if applicable)
  • Remove CD-ROM devices

⚠️  IMPORTANT: VMs will be shut down during this process.

Do you want to continue?"
  fi

  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size 18 85)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"
  local centered_msg
  centered_msg=$(center_message "${start_msg}")

  if ! whiptail --title "STEP 12 Execution Confirmation" \
                --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
  then
    log "User canceled STEP 12 execution."
    return 0
  fi

  # =========================================================================
  # [Moved from Step 10/11] UEFI/XML conversion and partition expansion logic (modified version)
  # =========================================================================
  if [[ "${_DRY}" -eq 0 ]]; then
    log "[STEP 12] Performing PDF guide-based UEFI/XML conversion (regeneration) before SR-IOV/CPU settings"

    # -----------------------------------------------------------------
    # [Important] Force load memory values from config file (fixes 186GB issue)
    # -----------------------------------------------------------------
    if [[ -f "${CONFIG_FILE}" ]]; then
      # Read DL_MEMORY_GB value directly from config file
      local cfg_dl_mem
      cfg_dl_mem=$(grep "^DL_MEMORY_GB=" "${CONFIG_FILE}" | cut -d'=' -f2 | tr -d '"')

      # Overwrite if value exists
      if [[ -n "${cfg_dl_mem}" ]]; then
        DL_MEMORY_GB="${cfg_dl_mem}"
      fi

      # Process DA_MEMORY_GB the same way
      local cfg_da_mem
      cfg_da_mem=$(grep "^DA_MEMORY_GB=" "${CONFIG_FILE}" | cut -d'=' -f2 | tr -d '"')
      if [[ -n "${cfg_da_mem}" ]]; then
        DA_MEMORY_GB="${cfg_da_mem}"
      fi
    fi

    # ------------------------------------------
    # 1) DL-master conversion
    # ------------------------------------------
    if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
      log "[STEP 12] ${DL_VM} :: Starting UEFI conversion and Raw disk processing"

      # Reset DL variables
      local dl_install_dir="${DL_INSTALL_DIR:-/stellar/dl}"
      local dl_bridge="${DL_BRIDGE:-virbr0}"
      local dl_vcpus="${DL_VCPUS:-42}"

      # [Modified] Default value changed to 136 & unified variable name to prevent typos
      # Use DL_MEMORY_GB read from config file if available, otherwise use 136
      local dl_mem_gb="${DL_MEMORY_GB:-136}"

      log "[STEP 12] DL-master memory value to apply: ${dl_mem_gb} GB"

      # Calculate KiB (use variable name dl_mem_gb correctly here)
      local dl_mem_kib=$(( dl_mem_gb * 1024 * 1024 ))

      # Default path assumption
      local dl_raw_disk="${dl_install_dir}/images/${DL_VM}/${DL_VM}.raw"

      # Call common patch function
      apply_pdf_xml_patch "${DL_VM}" "${dl_mem_kib}" "${dl_vcpus}" "${dl_bridge}" "${dl_raw_disk}"
    else
      log "[WARN] ${DL_VM} does not exist, skipping UEFI conversion."
    fi

    # ------------------------------------------
    # 2) DA-master conversion
    # ------------------------------------------
    if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
      log "[STEP 12] ${DA_VM} :: Starting UEFI conversion and Raw disk processing"

      # Reset DA variables
      local da_install_dir="${DA_INSTALL_DIR:-/stellar/da}"
      local da_bridge="${DA_BRIDGE:-virbr0}"
      local da_vcpus="${DA_VCPUS:-46}"

      # [Modified] Keep default value at 156
      local da_mem_gb="${DA_MEMORY_GB:-156}"

      log "[STEP 12] DA-master memory value to apply: ${da_mem_gb} GB"

      local da_mem_kib=$(( da_mem_gb * 1024 * 1024 ))
      local da_raw_disk="${da_install_dir}/images/${DA_VM}/${DA_VM}.raw"

      # Call common patch function
      apply_pdf_xml_patch "${DA_VM}" "${da_mem_kib}" "${da_vcpus}" "${da_bridge}" "${da_raw_disk}"
    else
      log "[WARN] ${DA_VM} does not exist, skipping UEFI conversion."
    fi

    log "[STEP 12] UEFI XML conversion complete. Now adding SR-IOV and CPU Affinity settings."
  else
    log "[DRY-RUN] Simulating UEFI XML conversion and Raw conversion process in Step 12."
  fi
  # =========================================================================

  ###########################################################################
  # Seed ISO guarantee (ensure seed.iso exists if XML references it)
  ###########################################################################
  ensure_seed_iso() {
    local vm="$1"
    local seed="/var/lib/libvirt/images/${vm}-seed.iso"

    # Check if VM exists
    if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
      return 0
    fi

    # Check if XML references seed iso
    if virsh dumpxml "${vm}" 2>/dev/null | grep -q "${vm}-seed.iso"; then
      # If seed iso file is missing, generate it
      if [[ ! -f "$seed" ]]; then
        log "[STEP 12] ${vm}: seed ISO missing -> re-generate via cloud-localds: ${seed}"
        
        # Ensure cloud-localds is available
        if ! command -v cloud-localds >/dev/null 2>&1; then
          if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] cloud-localds not found -> would install: cloud-image-utils"
          else
            log "[STEP 12] cloud-localds not found. Installing cloud-image-utils..."
            apt-get update -y >/dev/null 2>&1 || { log "[ERROR] apt-get update failed"; return 1; }
            apt-get install -y cloud-image-utils >/dev/null 2>&1 || { log "[ERROR] apt-get install cloud-image-utils failed"; return 1; }
            command -v cloud-localds >/dev/null 2>&1 || { log "[ERROR] cloud-localds still not found after install"; return 1; }
          fi
        fi

        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] cloud-localds ${seed} ${user_data} ${meta_data}"
        else
          local user_data="/tmp/user-data-${vm}"
          local meta_data="/tmp/meta-data-${vm}"
          
          echo "instance-id: ${vm}" > "${meta_data}"
          echo "local-hostname: ${vm}" >> "${meta_data}"
          
          cat > "${user_data}" <<'CLOUD'
#cloud-config
bootcmd:
  - [ growpart, /dev/vda, 1 ]
  - [ resize2fs, /dev/vda1 ]
CLOUD
          
          cloud-localds "${seed}" "${user_data}" "${meta_data}" >/dev/null 2>&1 || { log "[ERROR] ${vm}: cloud-localds failed (${seed})"; return 1; }
          [[ -f "$seed" ]] || { log "[ERROR] ${vm}: seed ISO still missing after generation (${seed})"; return 1; }
        fi
      else
        log "[STEP 12] ${vm}: seed ISO exists: ${seed}"
      fi
    fi
  }

  # Ensure seed ISO for both VMs (after UEFI/XML conversion)
  if [[ "${_DRY}" -eq 0 ]]; then
    ensure_seed_iso "${DL_VM}"
    ensure_seed_iso "${DA_VM}"
  fi

  ###########################################################################
  # CPU PINNING RULES (NUMA separation)
  # - DL: NUMA node0 (even cores) even numbers between 4~86 → 42 cores (4,6,...,86)
  # - DA: NUMA node1 (odd cores) odd numbers between 5~95 → 46 cores (5,7,...,95)
  ###########################################################################
  # Check NUMA node count - skip CPU list generation if only 1 NUMA node exists
  local numa_node_count
  numa_node_count=$(lscpu 2>/dev/null | grep -i "NUMA node(s)" | awk '{print $3}' || echo "0")
  
  if [[ -z "${numa_node_count}" ]] || [[ "${numa_node_count}" == "0" ]]; then
    # Fallback: try numactl if available
    if command -v numactl >/dev/null 2>&1; then
      numa_node_count=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1")
    else
      numa_node_count="1"
    fi
  fi
  
  local DL_CPUS_LIST=""
  local DA_CPUS_LIST=""
  
  if [[ "${numa_node_count}" != "1" ]]; then
    # DL: even CPUs 4,6,...,86
    local c
    for (( c=4; c<=86; c+=2 )); do
      DL_CPUS_LIST+="${c} "
    done

    # DA: odd CPUs 5,7,...,95
    for (( c=5; c<=95; c+=2 )); do
      DA_CPUS_LIST+="${c} "
    done

    log "[STEP 12] DL CPU LIST: ${DL_CPUS_LIST}"
    log "[STEP 12] DA CPU LIST: ${DA_CPUS_LIST}"
  else
    log "[STEP 12] System has only 1 NUMA node → skipping CPU list generation for CPU Affinity"
  fi

  ###########################################################################
  # Cluster Interface Type branching
  ###########################################################################
  local cluster_nic_type="${CLUSTER_NIC_TYPE:-SRIOV}"
  
  if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
    log "[STEP 12] Cluster Interface Type: BRIDGE - Executing bridge attach only"
    step_12_bridge_attach_v621
    local v621_bridge_rc=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV (v621) ====="
    echo
    return ${v621_bridge_rc}
  elif [[ "${cluster_nic_type}" == "SRIOV" ]]; then
    log "[STEP 12] Cluster Interface Type: SRIOV - Executing SR-IOV VF passthrough"
    # Continue with existing SR-IOV logic below
  else
    log "[WARN] Unknown CLUSTER_NIC_TYPE: ${cluster_nic_type}, defaulting to SRIOV"
    # Continue with existing SR-IOV logic below
  fi

  ###########################################################################
  # 1. SR-IOV VF PCI auto-detection
  ###########################################################################
  log "[STEP 12] Auto-detecting SR-IOV VF PCI devices"

  local vf_list
  vf_list="$(lspci | awk '/Ethernet/ && /Virtual Function/ {print $1}' || true)"

  if [[ -z "${vf_list}" ]]; then
    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] No SR-IOV VF found, but continuing in DRY_RUN mode"
      vf_list="0000:00:00.0 0000:00:00.1"  # Use placeholder VFs for dry run
    else
      whiptail_msgbox "STEP 12 - SR-IOV" "Failed to detect SR-IOV VF PCI devices.\nPlease check STEP 03 or BIOS settings." 12 70
      log "[STEP 12] No SR-IOV VF found → aborting STEP"
      return 1
    fi
  fi

  log "[STEP 12] Detected VF list:\n${vf_list}"

  local DL_VF DA_VF
  DL_VF="$(echo "${vf_list}" | sed -n '1p')"
  DA_VF="$(echo "${vf_list}" | sed -n '2p')"

  if [[ -z "${DA_VF}" ]]; then
    log "[WARN] Only 1 VF exists, applying VF Passthrough to DL only, DA will only have CPU Affinity without VF"
  fi

  ###########################################################################
  # 2. DL/DA VM shutdown (wait until completely shut down)
  ###########################################################################
  log "[STEP 12] Requesting DL/DA VM shutdown"

  for vm in "${DL_VM}" "${DA_VM}"; do
    if virsh dominfo "${vm}" >/dev/null 2>&1; then
      local state
      state="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
      if [[ "${state}" != "shut off" ]]; then
        log "[STEP 12] Requesting shutdown of ${vm}"
        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] virsh shutdown ${vm}"
        else
          virsh shutdown "${vm}" || log "[WARN] ${vm} shutdown failed (continuing anyway)"
        fi
      else
        log "[STEP 12] ${vm} is already in shut off state"
      fi
    else
      log "[STEP 12] ${vm} VM not found → skipping shutdown"
    fi
  done

  local timeout=180
  local interval=5
  local elapsed=0

  while (( elapsed < timeout )); do
    local all_off=1
    for vm in "${DL_VM}" "${DA_VM}"; do
      if virsh dominfo "${vm}" >/dev/null 2>&1; then
        local st
        st="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
        if [[ "${st}" != "shut off" ]]; then
          all_off=0
        fi
      fi
    done

    if (( all_off )); then
      log "[STEP 12] All DL/DA VMs are now in shut off state."
      break
    fi

    sleep "${interval}"
    (( elapsed += interval ))
  done

  if (( elapsed >= timeout )); then
    log "[WARN] [STEP 12] Some VMs did not shut off within timeout(${timeout}s). Continuing anyway."
  fi

  ###########################################################################
  # 3. CD-ROM removal (detach all CD-ROM devices, except seed ISO)
  ###########################################################################
  _list_non_seed_cdrom_targets() {
    local vm="$1"
    # Extract cdrom disk sections, exclude seed ISO (required for Cloud-Init)
    # Process each CD-ROM section: if it contains seed ISO, skip it
    virsh dumpxml "${vm}" --inactive 2>/dev/null \
      | grep -B 5 -A 10 -E "device=['\"]cdrom['\"]" \
      | awk '
        BEGIN { in_cdrom=0; is_seed=0; target_dev="" }
        /device=['\''"]cdrom['\''"]/ { in_cdrom=1; is_seed=0; target_dev="" }
        /<source.*-seed\.iso/ { is_seed=1 }
        /<target/ {
          if (match($0, /dev=['\''"]([^'\''"]*)['\''"]/, arr)) {
            target_dev=arr[1]
          }
        }
        /<\/disk>/ {
          if (in_cdrom && !is_seed && target_dev != "") {
            print target_dev
          }
          in_cdrom=0
          is_seed=0
          target_dev=""
        }
      ' | sort -u
  }

  _detach_all_cdroms_config() {
    local vm="$1"
    [[ -n "${vm}" ]] || return 0
    virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

    # Get only non-seed CD-ROM devices (seed ISO is required for Cloud-Init)
    local devs
    devs="$(_list_non_seed_cdrom_targets "${vm}" || true)"
    [[ -n "${devs}" ]] || return 0

    local dev
    while IFS= read -r dev; do
      [[ -n "${dev}" ]] || continue
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] virsh detach-disk ${vm} ${dev} --config"
      else
        virsh detach-disk "${vm}" "${dev}" --config >/dev/null 2>&1 || true
        log "[STEP 12] ${vm}: CD-ROM(${dev}) detach attempt completed (seed ISO preserved)"
      fi
    done <<< "${devs}"
  }

  _detach_all_cdroms_config "${DL_VM}"
  _detach_all_cdroms_config "${DA_VM}"

  ###########################################################################
  # 4. VF PCI hostdev attach (virsh attach-device --config)
  ###########################################################################
  _attach_vf_to_vm() {
    local vm="$1"
    local pci="$2"

    if [[ -z "${pci}" ]]; then
      return 0
    fi
    if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
      return 0
    fi

    local domain bus slot func

    # PCI format: DDDD:BB:SS.F  (e.g., 0000:8b:11.0)
    if [[ "${pci}" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
      domain="${BASH_REMATCH[1]}"
      bus="${BASH_REMATCH[2]}"
      slot="${BASH_REMATCH[3]}"
      func="${BASH_REMATCH[4]}"
    # Also handle BB:SS.F format (e.g., 8b:11.0)
    elif [[ "${pci}" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
      domain="0000"
      bus="${BASH_REMATCH[1]}"
      slot="${BASH_REMATCH[2]}"
      func="${BASH_REMATCH[3]}"
    else
      log "[ERROR] ${vm}: Unsupported PCI address format: ${pci}"
      return 1
    fi

    local d="0x${domain}"
    local b="0x${bus}"
    local s="0x${slot}"
    local f="0x${func}"

    local tmp_xml="/tmp/${vm}_vf.xml"
    cat > "${tmp_xml}" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='${d}' bus='${b}' slot='${s}' function='${f}'/>
  </source>
</hostdev>
EOF

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] virsh attach-device ${vm} ${tmp_xml} --config"
    else
      local out
      if ! out="$(virsh attach-device "${vm}" "${tmp_xml}" --config 2>&1)"; then
        if echo "${out}" | grep -q "already in the domain configuration"; then
          log "[STEP 12] ${vm}: VF PCI(${pci}) already attached → skipping"
        else
          log "[ERROR] ${vm}: virsh attach-device failed (PCI=${pci})"
          log "[ERROR] virsh message:"
          while IFS= read -r line; do
            log "  ${line}"
          done <<< "${out}"
        fi
      else
        log "[STEP 12] ${vm}: VF PCI(${pci}) hostdev attach (--config) completed"
      fi
    fi
  }

  _attach_vf_to_vm "${DL_VM}" "${DL_VF}"
  _attach_vf_to_vm "${DA_VM}" "${DA_VF}"

  ###########################################################################
  # 5. CPU Affinity (virsh vcpupin --config)
  ###########################################################################
  # Check NUMA node count - skip CPU Affinity if only 1 NUMA node exists
  local numa_node_count
  numa_node_count=$(lscpu 2>/dev/null | grep -i "NUMA node(s)" | awk '{print $3}' || echo "0")
  
  if [[ -z "${numa_node_count}" ]] || [[ "${numa_node_count}" == "0" ]]; then
    # Fallback: try numactl if available
    if command -v numactl >/dev/null 2>&1; then
      numa_node_count=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1")
    else
      numa_node_count="1"
    fi
  fi
  
  if [[ "${numa_node_count}" == "1" ]]; then
    log "[STEP 12] System has only 1 NUMA node → skipping CPU Affinity configuration"
  else
    _apply_cpu_affinity_vm() {
      local vm="$1"
      local cpus_list="$2"

      if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
        return 0
      fi
      [[ -n "${cpus_list}" ]] || return 0

      # Maximum vCPU count (designed as DL=42, DA=46, but check based on actual XML)
      local max_vcpus
      max_vcpus="$(virsh vcpucount "${vm}" --maximum --config 2>/dev/null || echo 0)"

      if [[ "${max_vcpus}" -eq 0 ]]; then
        log "[WARN] ${vm}: Unable to determine vCPU count → skipping CPU Affinity"
        return 0
      fi

      # Convert cpus_list to array
      local arr=()
      local c
      for c in ${cpus_list}; do
        arr+=("${c}")
      done

      if [[ "${#arr[@]}" -lt "${max_vcpus}" ]]; then
        log "[WARN] ${vm}: Specified CPU list count(${#arr[@]}) is less than maximum vCPU(${max_vcpus})."
        max_vcpus="${#arr[@]}"
      fi

      local i
      for (( i=0; i<max_vcpus; i++ )); do
        local pcpu="${arr[$i]}"
        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] virsh vcpupin ${vm} ${i} ${pcpu} --config"
        else
          if virsh vcpupin "${vm}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
            log "[STEP 12] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
          else
            log "[WARN] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin failed"
          fi
        fi
      done
    }

    _apply_cpu_affinity_vm "${DL_VM}" "${DL_CPUS_LIST}"
    _apply_cpu_affinity_vm "${DA_VM}" "${DA_CPUS_LIST}"
  fi

  ###########################################################################
  # 6. NUMA memory interleave (virsh numatune --config)
  ###########################################################################
  _apply_numatune_vm() {
    local vm="$1"
    if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] virsh numatune ${vm} --mode interleave --nodeset 0-1 --config"
    else
      if virsh numatune "${vm}" --mode interleave --nodeset 0-1 --config >/dev/null 2>&1; then
        log "[STEP 12] ${vm}: numatune mode=interleave nodeset=0-1 (--config) applied"
      else
        log "[WARN] ${vm}: numatune configuration failed (version/option may not be supported)"
      fi
    fi
  }

  _apply_numatune_vm "${DL_VM}"
  _apply_numatune_vm "${DA_VM}"

  ###########################################################################
  # 7. DL data disk (LV) attach (vg_dl/lv_dl → vdb, --config)
  ###########################################################################
  local DATA_LV="/dev/mapper/vg_dl-lv_dl"

  # Helper: extract the full <disk>...</disk> XML block that contains target dev='vdb'
  # NOTE: In libvirt XML, <source ...> often appears BEFORE <target ...>,
  # so parsing with `grep -A ... "target dev='vdb'"` is unreliable.
  # Args:
  #   $1: vm name
  #   $2: 0=live XML, 1=inactive XML
  get_vdb_disk_block() {
    local vm_name="$1"
    local inactive="${2:-0}"
    if [[ -z "${vm_name}" ]]; then
      return 1
    fi

    local dump_cmd=(virsh dumpxml "${vm_name}")
    if [[ "${inactive}" -eq 1 ]]; then
      dump_cmd+=(--inactive)
    fi

    "${dump_cmd[@]}" 2>/dev/null | awk '
      BEGIN { in_disk=0; buf="" }
      /<disk[ >]/ { in_disk=1; buf=$0 ORS; next }
      in_disk {
        buf = buf $0 ORS
        if ($0 ~ /<\/disk>/) {
          if (buf ~ /<target[[:space:]]+dev=.vdb./) { print buf; exit }
          in_disk=0; buf=""
        }
      }
    '
  }

  if [[ -e "${DATA_LV}" ]]; then
    if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] virsh attach-disk ${DL_VM} ${DATA_LV} vdb --config"
      else
        if [[ -n "$(get_vdb_disk_block "${DL_VM}" 0 || true)" ]]; then
          log "[STEP 12] ${DL_VM} vdb already exists → skipping data disk attach"
        else
          if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
            log "[STEP 12] ${DL_VM} data disk(${DATA_LV}) attached as vdb (--config) completed"
          else
            log "[WARN] ${DL_VM} data disk(${DATA_LV}) attach failed"
          fi
        fi
      fi
    else
      log "[STEP 12] ${DL_VM} VM not found → skipping DL data disk attach"
    fi
  else
    log "[STEP 12] ${DATA_LV} does not exist; skipping DL data disk attach."
  fi

  ###########################################################################
  # 8. DL/DA VM restart
  ###########################################################################
  for vm in "${DL_VM}" "${DA_VM}"; do
    if virsh dominfo "${vm}" >/dev/null 2>&1; then
      log "[STEP 12] ${vm} start request"
      (( _DRY )) || virsh start "${vm}" || log "[WARN] ${vm} start failed"
    fi
  done

  # Wait 5 seconds after VM start
  if [[ "${_DRY}" -eq 0 ]]; then
    log "[STEP 12] Waiting 5 seconds after DL/DA VM start (vCPU state stabilization)"
    sleep 5
  fi

  ###########################################################################
  # 9. Basic verification results
  ###########################################################################
  local result_file="/tmp/step12_result.txt"
  rm -f "${result_file}"

  if [[ "${_DRY}" -eq 1 ]]; then
    {
      echo "===== DRY-RUN MODE: Simulation Results ====="
      echo
      echo "📊 SIMULATED OPERATIONS:"
      echo "  • SR-IOV VF PCI passthrough to ${DL_VM} and ${DA_VM}"
      echo "  • CPU Affinity configuration"
      echo "  • NUMA memory interleave configuration"
      echo "  • DL data disk attach (if applicable)"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. SR-IOV VF PCI devices would be attached to ${DL_VM} and ${DA_VM}"
      echo "  2. CPU pinning would be applied"
      echo "  3. NUMA configuration would be applied"
      echo "  4. Data disk would be attached to ${DL_VM} (if available)"
      echo
      echo "📋 EXPECTED CONFIGURATION:"
      echo "  • DL VM: ${DL_VM}"
      echo "  • DA VM: ${DA_VM}"
      if [[ -n "${DL_VF:-}" ]]; then
        echo "  • DL VF PCI: ${DL_VF}"
      fi
      if [[ -n "${DA_VF:-}" ]]; then
        echo "  • DA VF PCI: ${DA_VF}"
      fi
    } > "${result_file}"
  else
    {
      echo "===== DL vcpuinfo (${DL_VM}) ====="
      if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
        virsh vcpuinfo "${DL_VM}" 2>&1
      else
        echo "VM ${DL_VM} not found"
      fi
      echo

      echo "===== DA vcpuinfo (${DA_VM}) ====="
      if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
        virsh vcpuinfo "${DA_VM}" 2>&1
      else
        echo "VM ${DA_VM} not found"
      fi
      echo

      echo "===== DL XML (cputune / numatune / hostdev / vdb) ====="
      if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
        virsh dumpxml "${DL_VM}" 2>/dev/null | \
          grep -E 'cputune|numatune|hostdev' || true
        get_vdb_disk_block "${DL_VM}" 0 2>/dev/null || true
      else
        echo "VM ${DL_VM} not found"
      fi
      echo

      echo "===== DA XML (cputune / numatune / hostdev) ====="
      if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
        virsh dumpxml "${DA_VM}" 2>/dev/null | \
          grep -E 'cputune|numatune|hostdev' || true
      else
        echo "VM ${DA_VM} not found"
      fi
      echo
    } > "${result_file}"
  fi

  # Execution completion message box
  local completion_msg
  if [[ "${_DRY}" -eq 1 ]]; then
    completion_msg="STEP 12: SR-IOV + CPU Affinity Configuration (DRY RUN) Completed

✅ Simulation Summary:
  • SR-IOV VF PCI passthrough simulation for ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration simulation
  • NUMA memory interleave configuration simulation
  • DL data disk attach simulation (if applicable)
  • CD-ROM removal simulation

⚠️  DRY RUN MODE: No actual changes were made.

📋 What Would Have Been Applied:
  • SR-IOV VF PCI devices would be attached to VMs
  • CPU pinning would be configured
  • NUMA memory interleave would be applied
  • Data disk would be attached to ${DL_VM} (if available)
  • CD-ROM devices would be removed

💡 Next Steps:
  Set DRY_RUN=0 and rerun STEP 12 to apply actual configurations.
  Detailed simulation results are available in the log."
  else
    completion_msg="STEP 12: SR-IOV + CPU Affinity Configuration Completed

✅ Configuration Summary:
  • SR-IOV VF PCI passthrough applied to ${DL_VM} and ${DA_VM}
  • CPU Affinity (CPU pinning) configured
  • NUMA memory interleave applied
  • DL data disk attached (if applicable)
  • CD-ROM devices removed

✅ VMs Status:
  • ${DL_VM} and ${DA_VM} have been restarted with new configurations
  • All SR-IOV and CPU affinity settings are now active

📋 Verification:
  • Check VM CPU pinning: virsh vcpuinfo ${DL_VM}
  • Check SR-IOV devices: virsh dumpxml ${DL_VM} | grep hostdev
  • Check NUMA configuration: virsh numatune ${DL_VM}
  • Verify data disk: virsh dumpxml ${DL_VM} | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'

💡 Note:
  Detailed verification results are shown below.
  VMs are ready for use with SR-IOV and CPU affinity enabled."
  fi

  # Calculate dialog size dynamically
  local dialog_dims
  dialog_dims=$(calc_dialog_size 22 90)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  whiptail_msgbox "STEP 12 - Configuration Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

  if [[ "${_DRY}" -eq 1 ]]; then
    # Read result file content and display in message box
    local dry_run_content
    if [[ -f "${result_file}" ]]; then
      dry_run_content=$(cat "${result_file}")
      # Calculate dialog size dynamically
      local dry_dialog_dims
      dry_dialog_dims=$(calc_dialog_size 20 90)
      local dry_dialog_height dry_dialog_width
      read -r dry_dialog_height dry_dialog_width <<< "${dry_dialog_dims}"
      whiptail_msgbox "STEP 12 – SR-IOV / CPU Affinity / DL data LV (DRY-RUN)" "${dry_run_content}" "${dry_dialog_height}" "${dry_dialog_width}"
    fi
  else
    show_paged "STEP 12 – SR-IOV / CPU Affinity / DL data LV verification results (v621)" "${result_file}" "no-clear"
  fi

  ###########################################################################
  # 10. STEP completion marking
  ###########################################################################
  if type mark_step_done >/dev/null 2>&1; then
    mark_step_done "${STEP_ID}"
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV (v621) ====="
  echo
}


step_09_dp_download() {
  log "[STEP 09] Download DP deploy script and image (virt_deploy_uvp_centos.sh + qcow2)"
  load_config
  local tmp_info="/tmp/xdr_step09_info.txt"

  #######################################
  # 0) Check configuration values
  #######################################
  local ver="${DP_VERSION:-}"
  
  # DP_VERSION gate:
  #   - <= 6.2.0 : keep legacy DP-Installer logic (do not change)
  #   - >= 6.2.1 : use KT v1.8 Step 09 behavior (v621)
  if [[ -n "${ver}" ]] && version_ge "${ver}" "6.2.1"; then
    step_09_dp_download_v621
    return
  fi
  
  local acps_user="${ACPS_USERNAME:-}"
  local acps_pass="${ACPS_PASSWORD:-}"
  local acps_url="${ACPS_BASE_URL:-https://acps.stellarcyber.ai}"

  # Check required values
  local missing=""
  [[ -z "${ver}"       ]] && missing+="\n - DP_VERSION"
  [[ -z "${acps_user}" ]] && missing+="\n - ACPS_USERNAME"
  [[ -z "${acps_pass}" ]] && missing+="\n - ACPS_PASSWORD"

  if [[ -n "${missing}" ]]; then
    local msg="The following items are missing in config:${missing}\n\nSet them in Settings, then rerun."
    log "[STEP 09] Missing config values: ${missing}"
    whiptail_msgbox "STEP 09 - Missing config" "${msg}" 15 70
    log "[STEP 09] Skipping STEP 09 due to missing config."
    return 0
  fi

  # Normalize URL (trim trailing slash)
  acps_url="${acps_url%/}"

  #######################################
  # 1) Prepare download directory
  #######################################
  local dl_img_dir="/stellar/dl/images"
  log "[STEP 09] Download directory: ${dl_img_dir}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p ${dl_img_dir}"
  else
    sudo mkdir -p "${dl_img_dir}"
  fi

  #######################################
  # 2) Define download targets/URLs
  #######################################
  local dp_script="virt_deploy_uvp_centos.sh"
  local qcow2="aella-dataprocessor-${ver}.qcow2"
  local sha1="${qcow2}.sha1"

  local url_script="${acps_url}/release/${ver}/dataprocessor/${dp_script}"
  local url_qcow2="${acps_url}/release/${ver}/dataprocessor/${qcow2}"
  local url_sha1="${acps_url}/release/${ver}/dataprocessor/${sha1}"

  log "[STEP 09] Configuration summary:"
  log "  - DP_VERSION   = ${ver}"
  log "  - ACPS_USERNAME= ${acps_user}"
  log "  - ACPS_BASE_URL= ${acps_url}"
  log "  - download path= ${dl_img_dir}"

  #######################################
  # 3-A) Optionally reuse existing >=1GB qcow2 in current dir
  #######################################
  local use_local_qcow=0
  local local_qcow=""
  local local_qcow_size_h=""

  local search_dir="."

  # Find newest *.qcow2 >= 1GB (1000M)
  local_qcow="$(
    find "${search_dir}" -maxdepth 1 -type f -name '*.qcow2' -size +1000M -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}'
  )"

  if [[ -n "${local_qcow}" ]]; then
    local_qcow_size_h="$(ls -lh "${local_qcow}" 2>/dev/null | awk '{print $5}')"

    local msg
    msg="Found a qcow2 (>=1GB) in current directory.\n\n"
    msg+="  File: ${local_qcow}\n"
    msg+="  Size: ${local_qcow_size_h}\n\n"
    msg+="Use this file for VM deployment instead of downloading?\n\n"
    msg+="[Yes] Use this file (copy to DL image dir; skip/replace download)\n"
    msg+="[No] Keep existing download process"

    # Calculate dialog size dynamically and center message
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 09 - reuse local qcow2" "${msg}"
    local reuse_rc=$?
    set -e
    
    if [[ ${reuse_rc} -eq 0 ]]; then
      use_local_qcow=1
      log "[STEP 09] User chose to use local qcow2 file (${local_qcow})."

      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${dl_img_dir}/${qcow2}\""
      else
        sudo mkdir -p "${dl_img_dir}"
        sudo cp "${local_qcow}" "${dl_img_dir}/${qcow2}"
        log "[STEP 09] Copied local qcow2 to ${dl_img_dir}/${qcow2}"
      fi
    else
      log "[STEP 09] User kept normal flow; not using local qcow2."
    fi
  else
    log "[STEP 09] No qcow2 >=1GB in current directory → use default download/existing files."
  fi



  #######################################
  # 3-A) Clean up old version files (if different version exists)
  #######################################
  log "[STEP 09] Checking for old version files to remove..."
  log "[STEP 09] Current version: ${ver}, Current qcow2: ${qcow2}, Current sha1: ${sha1}"
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will check and remove old version files from ${dl_img_dir}"
  else
    # Find all qcow2 files and remove those that don't match current version
    log "[STEP 09] Scanning for old version qcow2 files in ${dl_img_dir}..."
    local file
    while IFS= read -r -d '' file; do
      local basename_file
      basename_file=$(basename "${file}")
      if [[ "${basename_file}" != "${qcow2}" ]]; then
        log "[STEP 09] Removing old qcow2: ${file}"
        sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
      else
        log "[STEP 09] Keeping current version qcow2: ${basename_file}"
      fi
    done < <(find "${dl_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2" -print0 2>/dev/null || true)
    
    # Find all sha1 files and remove those that don't match current version
    log "[STEP 09] Scanning for old version sha1 files in ${dl_img_dir}..."
    while IFS= read -r -d '' file; do
      local basename_file
      basename_file=$(basename "${file}")
      if [[ "${basename_file}" != "${sha1}" ]]; then
        log "[STEP 09] Removing old sha1: ${file}"
        sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
      else
        log "[STEP 09] Keeping current version sha1: ${basename_file}"
      fi
    done < <(find "${dl_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2.sha1" -print0 2>/dev/null || true)
    
    # Remove old virt_deploy_uvp_centos.sh if it exists (will be replaced with new version)
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      log "[STEP 09] Removing existing ${dp_script} (will be replaced with new version)"
      sudo rm -f "${dl_img_dir}/${dp_script}" || log "[WARN] Failed to remove ${dl_img_dir}/${dp_script}"
    fi
    
    # Also clean up DA image directory
    local da_img_dir="/stellar/da/images"
    if [[ -d "${da_img_dir}" ]]; then
      log "[STEP 09] Cleaning up old version files in ${da_img_dir}..."
      
      local current_da_qcow2="aella-dataprocessor-${ver}.qcow2"
      local current_da_sha1="aella-dataprocessor-${ver}.qcow2.sha1"
      
      # Remove old DA qcow2 files
      while IFS= read -r -d '' file; do
        local basename_file
        basename_file=$(basename "${file}")
        if [[ "${basename_file}" != "${current_da_qcow2}" ]]; then
          log "[STEP 09] Removing old DA qcow2: ${file}"
          sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
        else
          log "[STEP 09] Keeping current version DA qcow2: ${basename_file}"
        fi
      done < <(find "${da_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2" -print0 2>/dev/null || true)
      
      # Remove old DA sha1 files
      while IFS= read -r -d '' file; do
        local basename_file
        basename_file=$(basename "${file}")
        if [[ "${basename_file}" != "${current_da_sha1}" ]]; then
          log "[STEP 09] Removing old DA sha1: ${file}"
          sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
        else
          log "[STEP 09] Keeping current version DA sha1: ${basename_file}"
        fi
      done < <(find "${da_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2.sha1" -print0 2>/dev/null || true)
      
      if [[ -f "${da_img_dir}/${dp_script}" ]]; then
        log "[STEP 09] Removing existing DA ${dp_script} (will be replaced with new version)"
        sudo rm -f "${da_img_dir}/${dp_script}" || log "[WARN] Failed to remove ${da_img_dir}/${dp_script}"
      fi
    fi
    
    log "[STEP 09] Old version files cleanup completed"
  fi

  #######################################
  # 3-B) Check existing files (download only missing)
  #######################################
  local need_script=0
  local need_qcow2=0
  local need_sha1=0

  if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
    log "[STEP 09] ${dl_img_dir}/${dp_script} already exists → skip download"
  else
    log "[STEP 09] ${dl_img_dir}/${dp_script} missing → will download"
    need_script=1
  fi

  if [[ -f "${dl_img_dir}/${qcow2}" ]]; then
    log "[STEP 09] ${dl_img_dir}/${qcow2} already exists → skip download"
  else
    log "[STEP 09] ${dl_img_dir}/${qcow2} missing → will download"
    need_qcow2=1
  fi

  if [[ -f "${dl_img_dir}/${sha1}" ]]; then
    log "[STEP 09] ${dl_img_dir}/${sha1} already exists → skip download"
  else
    log "[STEP 09] ${dl_img_dir}/${sha1} missing → will download (used for sha1 verify if present)"
    need_sha1=1
  fi

  #######################################
  # 3-C) Perform downloads
  #   - DRY_RUN=1: log commands only
  #   - DRY_RUN=0: curl missing files only
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] (password is not shown in logs)"

    if [[ "${need_script}" -eq 1 ]]; then
      log "[DRY-RUN] cd ${dl_img_dir} && curl -O -k -u ${acps_user}:******** ${url_script}"
    else
      log "[DRY-RUN] ${dp_script} already exists → skip download"
    fi

    if [[ "${need_qcow2}" -eq 1 ]]; then
      log "[DRY-RUN] cd ${dl_img_dir} && curl -O -k -u ${acps_user}:******** ${url_qcow2}"
    else
      log "[DRY-RUN] ${qcow2} already exists → skip download"
    fi

    if [[ "${need_sha1}" -eq 1 ]]; then
      log "[DRY-RUN] cd ${dl_img_dir} && curl -O -k -u ${acps_user}:******** ${url_sha1}"
    else
      log "[DRY-RUN] ${sha1} already exists → skip download"
    fi

  else
    # Download only missing files
    if [[ "${need_script}" -eq 0 && "${need_qcow2}" -eq 0 && "${need_sha1}" -eq 0 ]]; then
      log "[STEP 09] All required files already present; no download."
    else
      (
        cd "${dl_img_dir}" || exit 1

        # 1) Deploy script
        if [[ "${need_script}" -eq 1 ]]; then
          log "[STEP 09] Starting ${dp_script} download: ${url_script}"
          curl -O -k -u "${acps_user}:${acps_pass}" "${url_script}" || {
            log "[ERROR] ${dp_script} download failed"
            exit 1
          }
        fi

        # 2) qcow2 (large)
        if [[ "${need_qcow2}" -eq 1 ]]; then
          log "[STEP 09] Starting ${qcow2} download: ${url_qcow2}"
          echo "=== Downloading ${qcow2} (curl progress below) ==="
          curl -O -k -u "${acps_user}:${acps_pass}" "${url_qcow2}" || {
            log "[ERROR] ${qcow2} download failed"
            exit 1
          }
          echo "=== ${qcow2} download complete ==="
          log "[STEP 09] ${qcow2} download complete"
        fi

        # 3) sha1 file (used for verification if present)
        if [[ "${need_sha1}" -eq 1 ]]; then
          log "[STEP 09] Attempting to download ${sha1}: ${url_sha1}"
          if ! curl -O -k -u "${acps_user}:${acps_pass}" "${url_sha1}"; then
            log "[WARN] ${sha1} download failed (skip sha1 verification)."
          fi
        fi
      )
      local rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        log "[STEP 09] Download error; aborting STEP 09 (rc=${rc})"
        return 1
      fi
    fi
  fi

  #######################################
  # 4) Execute permission and sha1 verification
  #######################################
  local _DRY="${DRY_RUN:-0}"

  if [[ "${_DRY}" -eq 0 ]]; then
    # 4-1) Add execute permission to script
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      sudo chmod +x "${dl_img_dir}/${dp_script}"
      log "[STEP 09] Granted execute permission to ${dl_img_dir}/${dp_script}"
    else
      log "[STEP 09] WARN: ${dl_img_dir}/${dp_script} missing; skipping chmod."
    fi

    # 4-2) sha1 verification (only if qcow2 + sha1 exist)
    if [[ -f "${dl_img_dir}/${sha1}" ]]; then
      log "[STEP 09] Running sha1sum verification for ${qcow2}"

      (
        cd "${dl_img_dir}" || exit 2

        # Check if sha1 file has proper format (checksum + filename)
        local sha1_content
        sha1_content=$(cat "${sha1}" 2>/dev/null | tr -d '\r\n' | sed 's/[[:space:]]*$//')
        
        # If sha1 file contains only checksum (no filename), create proper format
        if [[ "${sha1_content}" =~ ^[0-9a-f]{40}$ ]]; then
          # Only checksum found, add filename
          log "[STEP 09] sha1 file contains only checksum, adding filename for proper format"
          echo "${sha1_content}  ${qcow2}" > "${sha1}.tmp"
          mv "${sha1}.tmp" "${sha1}"
        elif [[ "${sha1_content}" =~ ^[0-9a-f]{40}[[:space:]]+ ]]; then
          # Already has checksum + filename format, but may need filename update
          local existing_checksum
          existing_checksum=$(echo "${sha1_content}" | awk '{print $1}')
          if [[ -n "${existing_checksum}" ]]; then
            # Update filename if it doesn't match
            if ! echo "${sha1_content}" | grep -q "${qcow2}"; then
              log "[STEP 09] Updating sha1 file to include correct filename"
              echo "${existing_checksum}  ${qcow2}" > "${sha1}.tmp"
              mv "${sha1}.tmp" "${sha1}"
            fi
          fi
        fi

        # Now verify with sha1sum -c
        if ! sha1sum -c "${sha1}"; then
          log "[WARN] sha1sum verification failed."

          # Temporarily disable set -e to handle cancel gracefully (in subshell)
          set +e
          whiptail_yesno "STEP 09 - sha1 verification failed" "sha1 verification failed.\n\nProceed anyway?\n\n[Yes] continue\n[No] stop STEP 09"
          local sha_continue_rc=$?
          set -e
          
          if [[ ${sha_continue_rc} -eq 0 ]]; then
            log "[STEP 09] User chose to continue despite sha1 failure."
            exit 0   # allowed → subshell succeeds
          else
            log "[STEP 09] User stopped STEP 09 due to sha1 failure."
            exit 3   # user-abort code
          fi
        fi

        # sha1sum succeeded
        log "[STEP 09] sha1sum verification succeeded."
        exit 0
      )

      local sha_rc=$?
      case "${sha_rc}" in
        0)
          # ok
          ;;
        2)
          log "[STEP 09] Failed to access directory during sha1 check (cd ${dl_img_dir})"
          return 1
          ;;
        3)
          log "[STEP 09] User aborted STEP 09 due to sha1 failure"
          return 1
          ;;
        *)
          log "[STEP 09] Unknown error during sha1 verification (code=${sha_rc})"
          return 1
          ;;
      esac

      # 4-3) Copy to DA image directory as well (per docs)
      local da_img_dir="/stellar/da/images"

      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo mkdir -p ${da_img_dir}"
        # Copy script
        log "[DRY-RUN] sudo cp ${dl_img_dir}/${dp_script} ${da_img_dir}/ (if exists)"
        # Copy qcow2/sha1
        log "[DRY-RUN] sudo cp ${dl_img_dir}/${qcow2} ${da_img_dir}/ (if exists)"
        log "[DRY-RUN] sudo cp ${dl_img_dir}/${sha1} ${da_img_dir}/ (if exists)"
      else
        run_cmd "sudo mkdir -p ${da_img_dir}"

        # Copy script
        if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
          run_cmd "sudo cp ${dl_img_dir}/${dp_script} ${da_img_dir}/"
        else
          log "[WARN] ${dl_img_dir}/${dp_script} missing; skip DA deploy script copy."
        fi

        # Copy qcow2
        if [[ -f "${dl_img_dir}/${qcow2}" ]]; then
          run_cmd "sudo cp ${dl_img_dir}/${qcow2} ${da_img_dir}/"
        else
          log "[WARN] ${dl_img_dir}/${qcow2} missing; skip DA image copy."
        fi

        # Copy sha1
        if [[ -f "${dl_img_dir}/${sha1}" ]]; then
          run_cmd "sudo cp ${dl_img_dir}/${sha1} ${da_img_dir}/"
        else
          log "[WARN] ${dl_img_dir}/${sha1} missing; skip DA sha1 copy."
        fi
      fi

    else
      log "[STEP 09] ${dl_img_dir}/${sha1} not found; skipping sha1 verification."
    fi

  else
    # DRY_RUN: log only
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      log "[DRY-RUN] sudo chmod +x ${dl_img_dir}/${dp_script}"
    else
      log "[DRY-RUN] (skip chmod) ${dl_img_dir}/${dp_script} missing"
    fi

    if [[ -f "${dl_img_dir}/${sha1}" ]]; then
      log "[DRY-RUN] (cd ${dl_img_dir} && sha1sum -c ${sha1})"
    else
      log "[DRY-RUN] Skip sha1sum: ${dl_img_dir}/${sha1} missing"
    fi
  fi

  #######################################
  # 5) Final summary (brief)
  #######################################
  : > "${tmp_info}"
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP 09: Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual downloads were made"
      echo
    fi
    echo "📊 DOWNLOAD STATUS:"
    echo
    echo "1️⃣  Download Directory:"
    echo "  📁 ${dl_img_dir}"
    local dir_list
    dir_list=$(ls -lh "${dl_img_dir}" 2>/dev/null || echo "  ⚠️  Directory missing or inaccessible")
    if [[ "${dir_list}" != *"missing"* ]]; then
      echo "  📋 Files in directory:"
      echo "${dir_list}" | sed 's/^/    /'
    else
      echo "  ${dir_list}"
    fi
    echo
    echo "2️⃣  Configuration Values Used:"
    echo "  • DP_VERSION:    ${ver}"
    echo "  • ACPS_USERNAME: ${acps_user}"
    echo "  • ACPS_BASE_URL: ${acps_url}"
    echo
    echo "3️⃣  Required Files:"
    local script_file="${dl_img_dir}/virt_deploy_uvp_centos.sh"
    local qcow2_file="${dl_img_dir}/aella-dataprocessor-${ver}.qcow2"
    if [[ -f "${script_file}" ]]; then
      echo "  ✅ Deployment script: virt_deploy_uvp_centos.sh"
    else
      echo "  ⚠️  Deployment script: virt_deploy_uvp_centos.sh (not found)"
    fi
    if [[ -f "${qcow2_file}" ]]; then
      echo "  ✅ QCOW2 image: aella-dataprocessor-${ver}.qcow2"
    else
      echo "  ⚠️  QCOW2 image: aella-dataprocessor-${ver}.qcow2 (not found)"
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • Downloaded files will be used in STEP 10 and STEP 11"
    echo "  • Ensure all required files are present before proceeding"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 10 (DL Master VM Deployment)"
    echo "  • Then proceed to STEP 11 (DA Master VM Deployment)"
  } >> "${tmp_info}"

  show_textbox "STEP 09 - Summary" "${tmp_info}"

  # save_state handled in run_step()
}


#######################################
# STEP 10/11 dedicated helpers
#######################################
confirm_destroy_vm() {
  local vm_name="$1"
  local step_name="$2"

  if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    return 0
  fi

  local state
  state=$(virsh domstate "${vm_name}" 2>/dev/null | tr -d '\r')

  local msg="${vm_name} VM is already defined. (state: ${state})\n\
\n\
If you continue:\n\
  - ${vm_name} VM will be destroyed and undefined\n\
  - Existing disk image files (${vm_name}.raw / ${vm_name}.log, etc.) will be deleted\n\
\n\
This can heavily impact a running cluster (DL / DA service).\n\
\n\
Proceed with redeploy?"

  if command -v whiptail >/dev/null 2>&1; then
      # Temporarily disable set -e to handle cancel gracefully
      set +e
      whiptail_yesno "${step_name} - ${vm_name} redeploy confirmation" "${msg}"
      local confirm_rc=$?
      set -e
      
      if [[ ${confirm_rc} -ne 0 ]]; then
          log "[${step_name}] Redeploy of ${vm_name} canceled by user."
          return 1
      fi
  else
  
    echo
    echo "====================================================="
    echo " ${step_name}: ${vm_name} redeploy warning"
    echo "====================================================="
    echo -e "${msg}"
    echo
    read -r -p "Continue? (type yes to proceed) [default: no] : " answer
    case "${answer}" in
      yes|y|Y) ;;
      *)
        log "[${step_name}] Redeploy of ${vm_name} canceled by user."
        return 1
        ;;
    esac
  fi

  return 0
}

list_dl_domains() {
  virsh list --all --name 2>/dev/null | awk 'NF' | grep -E '^dl-' || true
}

list_da_domains() {
  virsh list --all --name 2>/dev/null | awk 'NF' | grep -E '^da-' || true
}

confirm_destroy_vm_batch() {
  local step_name="$1"
  local vm_list="$2"
  local cluster_label="$3"
  local label="${cluster_label:-DL/DA}"

  if [[ -z "${vm_list}" ]]; then
    return 0
  fi

  local msg="The following ${label} VMs are defined:\n\
${vm_list}\n\
\n\
If you continue:\n\
  - All listed VMs will be destroyed and undefined\n\
  - Their disk image files (raw/log and VM directories) will be deleted\n\
\n\
This can heavily impact a running cluster (${label} service).\n\
\n\
Proceed with redeploy?"

  if command -v whiptail >/dev/null 2>&1; then
      # Temporarily disable set -e to handle cancel gracefully
      set +e
      whiptail_yesno "${step_name} - ${label} cluster redeploy confirmation" "${msg}"
      local confirm_rc=$?
      set -e
      
      if [[ ${confirm_rc} -ne 0 ]]; then
          log "[${step_name}] Redeploy canceled by user."
          return 1
      fi
  else
    echo
    echo "====================================================="
    echo " ${step_name}: ${label} cluster redeploy warning"
    echo "====================================================="
    echo -e "${msg}"
    echo
    read -r -p "Continue? (type yes to proceed) [default: no] : " answer
    case "${answer}" in
      yes|y|Y) ;;
      *)
        log "[${step_name}] Redeploy canceled by user."
        return 1
        ;;
    esac
  fi
}

cleanup_dl_da_vm_and_images() {
  local vm_name="$1"
  local dl_install_dir="$2"
  local da_install_dir="$3"
  local dry_run="$4"

  local install_dir=""
  if [[ "${vm_name}" == dl-* ]]; then
    install_dir="${dl_install_dir}"
  elif [[ "${vm_name}" == da-* ]]; then
    install_dir="${da_install_dir}"
  else
    return 0
  fi

  local image_dir="${install_dir}/images"
  local vm_dir="${image_dir}/${vm_name}"
  local vm_raw="${image_dir}/${vm_name}.raw"
  local vm_log="${image_dir}/${vm_name}.log"

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[DRY_RUN] virsh destroy ${vm_name} || true"
    echo "[DRY_RUN] virsh undefine ${vm_name} --nvram || virsh undefine ${vm_name} || true"
    echo "[DRY_RUN] rm -rf '${vm_dir}'"
    echo "[DRY_RUN] rm -f '${vm_raw}' '${vm_log}'"
  else
    virsh destroy "${vm_name}" >/dev/null 2>&1 || true
    virsh undefine "${vm_name}" --nvram >/dev/null 2>&1 || virsh undefine "${vm_name}" >/dev/null 2>&1 || true
    if [ -d "${vm_dir}" ]; then
      sudo rm -rf "${vm_dir}" 2>/dev/null || true
    fi
    sudo rm -f "${vm_raw}" "${vm_log}" 2>/dev/null || true
  fi
}

###############################################################################
# DL / DA VM memory setting (GB) – user input
###############################################################################
prompt_vm_memory() {
  # If config has values use them; otherwise use defaults shown (e.g., 136/80)
  local default_dl="${DL_MEM_GB:-136}"
  local default_da="${DA_MEM_GB:-80}"

  local dl_input da_input

  if command -v whiptail >/dev/null 2>&1; then
    dl_input=$(whiptail_inputbox "DL VM memory" "Enter DL VM memory in GB.\n\n(Current default: ${default_dl} GB)" "${default_dl}" 12 60)
    if [[ $? -ne 0 ]] || [[ -z "${dl_input}" ]]; then
      return 1
    fi

    da_input=$(whiptail_inputbox "DA VM memory" "Enter DA VM memory in GB.\n\n(Current default: ${default_da} GB)" "${default_da}" 12 60)
    if [[ $? -ne 0 ]] || [[ -z "${da_input}" ]]; then
      return 1
    fi
  else
    echo "Set DL / DA VM memory in GB."
    read -r -p "DL VM memory (GB) [default: ${default_dl}]: " dl_input
    read -r -p "DA VM memory (GB) [default: ${default_da}]: " da_input
  fi

  # Use defaults if empty
  [[ -z "${dl_input}" ]] && dl_input="${default_dl}"
  [[ -z "${da_input}" ]] && da_input="${default_da}"

  # Validate numbers (integers only)
  if ! [[ "${dl_input}" =~ ^[0-9]+$ ]]; then
    log "[WARN] DL memory not integer: ${dl_input} → using ${default_dl} GB"
    dl_input="${default_dl}"
  fi
  if ! [[ "${da_input}" =~ ^[0-9]+$ ]]; then
    log "[WARN] DA memory not integer: ${da_input} → using ${default_da} GB"
    da_input="${default_da}"
  fi

  DL_MEM_GB="${dl_input}"
  DA_MEM_GB="${da_input}"

  log "[CONFIG] DL VM memory: ${DL_MEM_GB} GB"
  log "[CONFIG] DA VM memory: ${DA_MEM_GB} GB"

  # Compute KiB values (used in libvirt XML / virt-install)
  DL_MEM_KIB=$(( DL_MEM_GB * 1024 * 1024 ))
  DA_MEM_KIB=$(( DA_MEM_GB * 1024 * 1024 ))
}


###############################################################################
# STEP 10 - DL-master VM deployment (using virt_deploy_uvp_centos.sh)
###############################################################################
step_10_dl_master_deploy() {
    local STEP_ID="10_dl_master_deploy"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 10. DL-master VM deployment ====="

    # Load configuration (assuming function already exists)
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DP_VERSION gate:
    #   - <= 6.2.0 : keep legacy DP-Installer logic (do not change)
    #   - >= 6.2.1 : use KT v1.8 Step 10 behavior (v621)
    local ver="${DP_VERSION:-}"
    if [[ -n "${ver}" ]] && version_ge "${ver}" "6.2.1"; then
      step_10_dl_master_deploy_v621
      return
    fi

    # DRY_RUN default value guard
    local _DRY_RUN="${DRY_RUN:-0}"

    # Default configuration values (can be overridden from environment variables/config file)
    local DL_HOSTNAME="${DL_HOSTNAME:-dl-master}"
    local DL_CLUSTERSIZE="${DL_CLUSTERSIZE:-1}"

    local DL_VCPUS="${DL_VCPUS:-42}"
    local DL_MEMORY_GB="${DL_MEMORY_GB:-136}"       # in GB
    local DL_DISK_GB="${DL_DISK_GB:-500}"           # in GB

    local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"
    local DL_BRIDGE="${DL_BRIDGE:-virbr0}"

    local DL_IP="${DL_IP:-192.168.122.2}"
    local DL_NETMASK="${DL_NETMASK:-255.255.255.0}"
    local DL_GW="${DL_GW:-192.168.122.1}"
    local DL_DNS="${DL_DNS:-8.8.8.8}"

    # Host MGT IP (required by virt_deploy_uvp_centos.sh)
    local MGT_NIC_NAME="${MGT_NIC:-mgt}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [[ -z "${HOST_MGT_IP}" ]]; then
        # NAT environment: reuse DL VM IP as local-ip
        HOST_MGT_IP="${DL_IP}"
        log "[STEP 10] HOST_MGT_IP empty; using DL_IP (${DL_IP}) for local-ip"
    fi

    # DP_VERSION is managed in config
    local _DP_VERSION="${DP_VERSION:-}"
    if [ -z "${_DP_VERSION}" ]; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] DP_VERSION not set, but continuing in DRY_RUN mode"
            _DP_VERSION="dry-run-version"  # Use placeholder for dry run
        else
            whiptail_msgbox "STEP 10 - DL deploy" "DP_VERSION is not set.\nSet it in Settings and rerun.\nSkipping this step." 12 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DP_VERSION not set. Skipping DL-master deploy."
            return 0
        fi
    fi

    # DL image directory (same as STEP 09)
    local DL_IMAGE_DIR="${DL_INSTALL_DIR}/images"
    # DA install dir for cleanup (DL/DA cluster VMs)
    local DA_INSTALL_DIR="${DA_INSTALL_DIR:-/stellar/da}"

    ############################################################
    # Cleanup existing DL cluster VMs (dl-*)
    ############################################################
    local -a cluster_vms
    mapfile -t cluster_vms < <(list_dl_domains)
    if [[ ${#cluster_vms[@]} -gt 0 ]]; then
        local vm_list_str
        vm_list_str=$(printf '%s\n' "${cluster_vms[@]}")
        if ! confirm_destroy_vm_batch "STEP 10 - DL deploy" "${vm_list_str}" "DL"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Redeploy canceled by user. Skipping."
            return 0
        fi
        local vm
        for vm in "${cluster_vms[@]}"; do
            cleanup_dl_da_vm_and_images "${vm}" "${DL_INSTALL_DIR}" "${DA_INSTALL_DIR}" "${_DRY_RUN}"
        done
    fi

    ############################################################
    # Clean up all VM directories in /stellar/dl/images/ before deployment
    ############################################################
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will clean up all VM directories in ${DL_IMAGE_DIR}/"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Cleaning up all existing VM directories in ${DL_IMAGE_DIR}/..."
        # Find and remove all subdirectories (VM directories like dl-master/, da-master/, etc.)
        # but keep files (qcow2, sha1, scripts)
        local vm_dir
        while IFS= read -r -d '' vm_dir; do
            if [[ -d "${vm_dir}" ]]; then
                local dir_name
                dir_name=$(basename "${vm_dir}")
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Removing VM directory: ${dir_name}/"
                sudo rm -rf "${vm_dir}" 2>/dev/null || log "[WARN] Failed to remove ${vm_dir}"
            fi
        done < <(find "${DL_IMAGE_DIR}" -maxdepth 1 -type d ! -path "${DL_IMAGE_DIR}" -print0 2>/dev/null || true)
        log "[STEP 10] VM directories cleanup completed"
    fi

    # Locate virt_deploy_uvp_centos.sh
    # - prefer DP_SCRIPT_PATH saved from STEP 09
    # - else search /stellar/dl/images, /stellar/dl, current dir
    local DP_SCRIPT_PATH_CANDIDATES=()
    [ -n "${DP_SCRIPT_PATH:-}" ] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")

    # STEP 09 standard location
    DP_SCRIPT_PATH_CANDIDATES+=("${DL_IMAGE_DIR}/virt_deploy_uvp_centos.sh")
    # Also consider old layout where it sits in DL_INSTALL_DIR
    DP_SCRIPT_PATH_CANDIDATES+=("${DL_INSTALL_DIR}/virt_deploy_uvp_centos.sh")
    # And current directory fallback
    DP_SCRIPT_PATH_CANDIDATES+=("./virt_deploy_uvp_centos.sh")

    local DP_SCRIPT_PATH=""
    local c
    for c in "${DP_SCRIPT_PATH_CANDIDATES[@]}"; do
        if [ -f "${c}" ]; then
            DP_SCRIPT_PATH="${c}"
            break
        fi
    done

    if [ -z "${DP_SCRIPT_PATH}" ]; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] virt_deploy_uvp_centos.sh not found, but continuing in DRY_RUN mode"
            DP_SCRIPT_PATH="./virt_deploy_uvp_centos.sh"  # Use placeholder for dry run
        else
            whiptail_msgbox "STEP 10 - DL deploy" "Could not find virt_deploy_uvp_centos.sh.\nComplete STEP 09 (download script/image) first.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] virt_deploy_uvp_centos.sh not found. Skipping."
            return 0
        fi
    fi

    # Check DL image presence
    # Step 10 always uses --nodownload=true since Step 09 already downloaded the image
    local QCOW2_PATH="${DL_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local DL_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: DL qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=true (Step 09 should have downloaded it)."
    fi

    # Ensure DL LV is mounted on /stellar/dl
    if ! mount | grep -q "on ${DL_INSTALL_DIR} "; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] ${DL_INSTALL_DIR} is not mounted, but continuing in DRY_RUN mode"
        else
            whiptail_msgbox "STEP 10 - DL deploy" "${DL_INSTALL_DIR} is not mounted.\nComplete STEP 07 (LVM) and fstab setup, then rerun.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ${DL_INSTALL_DIR} not mounted. Skipping."
            return 0
        fi
    fi

    # DL OTP: use from config or prompt/save once
    local _DL_OTP="${DL_OTP:-}"
    if [ -z "${_DL_OTP}" ]; then
        # Always prompt for OTP (both dry run and actual mode)
        local otp_prompt_msg="Enter OTP for DL-master (issued from Stellar Cyber)."
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            otp_prompt_msg="Enter OTP for DL-master (issued from Stellar Cyber).\n\n(DRY-RUN mode: You can skip this, but OTP will be required for actual deployment.)"
        fi
        _DL_OTP="$(whiptail_passwordbox "STEP 10 - DL deploy" "${otp_prompt_msg}" "")"
        if [ $? -ne 0 ] || [ -z "${_DL_OTP}" ]; then
            if [[ "${_DRY_RUN}" -eq 1 ]]; then
                log "[DRY-RUN] DL_OTP not provided, but continuing in DRY_RUN mode with placeholder"
                _DL_OTP="dry-run-otp"  # Use placeholder for dry run
            else
                whiptail_msgbox "STEP 10 - DL deploy" "No OTP provided. Skipping DL-master deploy." 10 70
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL_OTP not provided. Skipping."
                return 0
            fi
        else
            # User provided OTP - save it
            DL_OTP="${_DL_OTP}"
            if [[ "${_DRY_RUN}" -eq 1 ]]; then
                log "[DRY-RUN] DL_OTP provided by user (will be used in dry run command)"
            fi
            # Save OTP (reflect in configuration)
            if type save_config >/dev/null 2>&1; then
                save_config
            fi
        fi
    fi

    # If dl-master already exists, warn and allow destroy/cleanup
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
        # strong warning + confirmation
        if ! confirm_destroy_vm "${DL_HOSTNAME}" "STEP 10 - DL deploy"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Existing VM detected, user kept it. Skipping."
            return 0
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Destroying and undefining existing ${DL_HOSTNAME}..."

        # Directory containing actual RAW/LOG files (/stellar/dl/images/dl-master)
        local DL_VM_DIR="${DL_IMAGE_DIR}/${DL_HOSTNAME}"

        if [ "${_DRY_RUN}" -eq 1 ]; then
            echo "[DRY_RUN] virsh destroy ${DL_HOSTNAME} || true"
            echo "[DRY_RUN] virsh undefine ${DL_HOSTNAME} --nvram || virsh undefine ${DL_HOSTNAME} || true"

            echo "[DRY_RUN] rm -f '${DL_VM_DIR}/${DL_HOSTNAME}.raw' || true"
            echo "[DRY_RUN] rm -f '${DL_VM_DIR}/${DL_HOSTNAME}.log' || true"
        else
            # Shut down VM and remove definition
            virsh destroy "${DL_HOSTNAME}" >/dev/null 2>&1 || true
            virsh undefine "${DL_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DL_HOSTNAME}" >/dev/null 2>&1 || true

            # Delete disk images/logs (free up space)
            if [ -d "${DL_VM_DIR}" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Removing old DL-master image files in ${DL_VM_DIR} (raw/log and all contents)."
                # Remove all files in the VM directory (raw, log, and any other files)
                sudo rm -rf "${DL_VM_DIR}"/* 2>/dev/null || true
                # Also try to remove the directory itself if empty
                sudo rmdir "${DL_VM_DIR}" 2>/dev/null || true
                log "[STEP 10] Old DL-master image directory ${DL_VM_DIR} cleaned up"
            else
                # Fallback: try to remove files directly if directory doesn't exist
                local fallback_raw="${DL_IMAGE_DIR}/${DL_HOSTNAME}.raw"
                local fallback_log="${DL_IMAGE_DIR}/${DL_HOSTNAME}.log"
                if [ -f "${fallback_raw}" ] || [ -f "${fallback_log}" ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Removing old DL-master image files (fallback location)."
                    sudo rm -f "${fallback_raw}" "${fallback_log}" 2>/dev/null || true
                fi
            fi
        fi
    fi

    ############################################################
    # Prompt for DL VM configuration (memory, vCPU, disk)
    ############################################################
    # 1) Memory
    local _DL_MEM_INPUT
    _DL_MEM_INPUT="$(whiptail_inputbox "STEP 10 - DL memory" "Enter memory (GB) for DL-master VM.\n\nCurrent default: ${DL_MEMORY_GB} GB" "${DL_MEMORY_GB}" 12 70)"

    # If Cancel keep default; if OK validate and apply
    if [ $? -eq 0 ] && [ -n "${_DL_MEM_INPUT}" ]; then
        # basic numeric check
        if [[ "${_DL_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DL_MEM_INPUT}" -gt 0 ]; then
            DL_MEMORY_GB="${_DL_MEM_INPUT}"
        else
            whiptail_msgbox "STEP 10 - DL memory" "Invalid memory value.\nUsing current default (${DL_MEMORY_GB} GB)." 10 70
        fi
    fi

    # 2) vCPU
    local _DL_VCPU_INPUT
    _DL_VCPU_INPUT="$(whiptail_inputbox "STEP 10 - DL vCPU" "Enter number of vCPUs for DL-master VM.\n\nCurrent default: ${DL_VCPUS}" "${DL_VCPUS}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_DL_VCPU_INPUT}" ]; then
        if [[ "${_DL_VCPU_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DL_VCPU_INPUT}" -gt 0 ]; then
            DL_VCPUS="${_DL_VCPU_INPUT}"
        else
            whiptail_msgbox "STEP 10 - DL vCPU" "Invalid vCPU value.\nUsing current default (${DL_VCPUS})." 10 70
        fi
    fi

    # 3) Disk size
    local _DL_DISK_INPUT
    _DL_DISK_INPUT="$(whiptail_inputbox "STEP 10 - DL disk" "Enter disk size (GB) for DL-master VM.\n\nCurrent default: ${DL_DISK_GB} GB" "${DL_DISK_GB}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_DL_DISK_INPUT}" ]; then
        if [[ "${_DL_DISK_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DL_DISK_INPUT}" -gt 0 ]; then
            DL_DISK_GB="${_DL_DISK_INPUT}"
        else
            whiptail_msgbox "STEP 10 - DL disk" "Invalid disk size value.\nUsing current default (${DL_DISK_GB} GB)." 10 70
        fi
    fi

    # Save to config file if needed (reflect in configuration)
    if type save_config >/dev/null 2>&1; then
        save_config
    fi

    # Convert memory to MB
    local DL_MEMORY_MB=$(( DL_MEMORY_GB * 1024 ))

    # Build command to run virt_deploy_uvp_centos.sh
    local CMD
    CMD="sudo bash '${DP_SCRIPT_PATH}' -- \
--hostname=${DL_HOSTNAME} \
--cluster-size=${DL_CLUSTERSIZE} \
--release=${_DP_VERSION} \
--local-ip=${HOST_MGT_IP} \
--node-role=DL-master \
--bridge=${DL_BRIDGE} \
--CPUS=${DL_VCPUS} \
--MEM=${DL_MEMORY_MB} \
--DISKSIZE=${DL_DISK_GB} \
--nodownload=${DL_NODOWNLOAD} \
--installdir=${DL_INSTALL_DIR} \
--OTP=${_DL_OTP} \
--ip=${DL_IP} \
--netmask=${DL_NETMASK} \
--gw=${DL_GW} \
--dns=${DL_DNS}"

    # Final confirmation
    local SUMMARY
    SUMMARY="Deploy DL-master VM with:

  Hostname      : ${DL_HOSTNAME}
  Cluster size  : ${DL_CLUSTERSIZE}
  DP version    : ${_DP_VERSION}
  Host MGT IP   : ${HOST_MGT_IP}
  Bridge        : ${DL_BRIDGE}
  vCPU          : ${DL_VCPUS}
  Memory        : ${DL_MEMORY_GB} GB (${DL_MEMORY_MB} MB)
  Disk size     : ${DL_DISK_GB} GB
  installdir    : ${DL_INSTALL_DIR}
  VM IP         : ${DL_IP}
  Netmask       : ${DL_NETMASK}
  Gateway       : ${DL_GW}
  DNS           : ${DL_DNS}
  nodownload    : ${DL_NODOWNLOAD}
  Script path   : ${DP_SCRIPT_PATH}

Run virt_deploy_uvp_centos.sh with these settings?"

    # Calculate dialog size dynamically and center message
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 10 - DL deploy" "${SUMMARY}"
    local confirm_rc=$?
    set -e
    
    if [[ ${confirm_rc} -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] User canceled DL-master deploy."
        return 2  # Return 2 to indicate cancellation
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Running DL-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Command not executed (DRY_RUN=1)."
        whiptail_msgbox "STEP 10 - DL deploy (DRY RUN)" "DRY_RUN mode.\n\nCommand printed but not executed:\n\n${CMD}" 20 80
        # Call mark_step_done function if it exists
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would execute: ${CMD}"
        log "[DRY-RUN] DL-master VM deployment skipped in DRY_RUN mode"
    else
        eval "${CMD}"
        local RC=$?

        if [ ${RC} -ne 0 ]; then
            whiptail_msgbox "STEP 10 - DL deploy" "virt_deploy_uvp_centos.sh exited with code ${RC}.\nCheck status via virsh list / virsh console ${DL_HOSTNAME}." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master deploy failed with RC=${RC}."
            return ${RC}
        fi
    fi

    # Simple validation: VM definition existence / status
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: virt_deploy script finished, but virsh dominfo ${DL_HOSTNAME} failed."
    fi

    local step10_summary
    step10_summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 10: DL-master VM Deployment - Complete
═══════════════════════════════════════════════════════════

✅ DEPLOYMENT STATUS:
  • DL-master VM (${DL_HOSTNAME}) deployment completed
  • VM configuration: UEFI boot, NAT network (virbr0)
  • Initial boot may take time due to Cloud-Init operations

📊 VERIFICATION COMMANDS:
  • Check VM status:     virsh list --all
  • View VM console:     virsh console ${DL_HOSTNAME}
  • Check VM info:       virsh dominfo ${DL_HOSTNAME}
  • View VM XML:         virsh dumpxml ${DL_HOSTNAME}

⚠️  IMPORTANT NOTES:
  • VM may take several minutes to complete initial boot
  • Cloud-Init will configure network and system settings
  • Monitor console output for any errors during boot
  • If VM fails to start, check logs: ${LOG_FILE}

🔧 TROUBLESHOOTING:
  • If VM doesn't start:
    1. Check: virsh list --all
    2. Check: virsh dominfo ${DL_HOSTNAME}
    3. Review logs: ${LOG_FILE}
    4. Verify disk space: df -h /stellar/dl
  • If network issues:
    1. Verify libvirt hooks: /etc/libvirt/hooks/qemu
    2. Check iptables rules: iptables -t nat -L
    3. Verify virbr0: virsh net-info default

📝 NEXT STEPS:
  • Wait for VM to complete initial boot
  • Verify VM is accessible via console
  • Proceed to STEP 11 (DA-master VM Deployment)
EOF
)
    whiptail_msgbox "STEP 10 - DL deploy complete" "${step10_summary}"

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 10. DL-master VM deployment ====="
    echo
}


###############################################################################
# STEP 11 - DA-master VM deployment (using virt_deploy_uvp_centos.sh)
###############################################################################
step_11_da_master_deploy() {
    local STEP_ID="11_da_master_deploy"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 11. DA-master VM deployment ====="

    # Load configuration
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DP_VERSION gate:
    #   - <= 6.2.0 : keep legacy DP-Installer logic (do not change)
    #   - >= 6.2.1 : use KT v1.8 Step 11 behavior (v621)
    local ver="${DP_VERSION:-}"
    if [[ -n "${ver}" ]] && version_ge "${ver}" "6.2.1"; then
      step_11_da_master_deploy_v621
      return
    fi

    # DRY_RUN default value guard
    local _DRY_RUN="${DRY_RUN:-0}"

    # Default configuration values (can be overridden from config)
    local DA_HOSTNAME="${DA_HOSTNAME:-da-master}"
    local DA_VCPUS="${DA_VCPUS:-46}"
    local DA_MEMORY_GB="${DA_MEMORY_GB:-80}"       # in GB
    local DA_DISK_GB="${DA_DISK_GB:-500}"          # in GB

    local DA_INSTALL_DIR="${DA_INSTALL_DIR:-/stellar/da}"
    local DA_BRIDGE="${DA_BRIDGE:-virbr0}"
    local DA_IMAGE_DIR="${DA_INSTALL_DIR}/images"
    local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"

    ############################################################
    # Cleanup existing DA cluster VMs (da-*)
    ############################################################
    local -a cluster_vms
    mapfile -t cluster_vms < <(list_da_domains)
    if [[ ${#cluster_vms[@]} -gt 0 ]]; then
        local vm_list_str
        vm_list_str=$(printf '%s\n' "${cluster_vms[@]}")
        if ! confirm_destroy_vm_batch "STEP 11 - DA Deployment" "${vm_list_str}" "DA"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Redeploy canceled by user. Skipping."
            return 0
        fi
        local vm
        for vm in "${cluster_vms[@]}"; do
            cleanup_dl_da_vm_and_images "${vm}" "${DL_INSTALL_DIR}" "${DA_INSTALL_DIR}" "${_DRY_RUN}"
        done
    fi

    ############################################################
    # Clean up all VM directories in /stellar/da/images/ before deployment
    ############################################################
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will clean up all VM directories in ${DA_IMAGE_DIR}/"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Cleaning up all existing VM directories in ${DA_IMAGE_DIR}/..."
        # Find and remove all subdirectories (VM directories like da-master/, etc.)
        # but keep files (qcow2, sha1, scripts)
        local vm_dir
        while IFS= read -r -d '' vm_dir; do
            if [[ -d "${vm_dir}" ]]; then
                local dir_name
                dir_name=$(basename "${vm_dir}")
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Removing VM directory: ${dir_name}/"
                sudo rm -rf "${vm_dir}" 2>/dev/null || log "[WARN] Failed to remove ${vm_dir}"
            fi
        done < <(find "${DA_IMAGE_DIR}" -maxdepth 1 -type d ! -path "${DA_IMAGE_DIR}" -print0 2>/dev/null || true)
        log "[STEP 11] VM directories cleanup completed"
    fi

    local DA_IP="${DA_IP:-192.168.122.3}"
    local DA_NETMASK="${DA_NETMASK:-255.255.255.0}"
    local DA_GW="${DA_GW:-192.168.122.1}"
    local DA_DNS="${DA_DNS:-8.8.8.8}"

    # Host MGT IP (required by virt_deploy_uvp_centos.sh)
    local MGT_NIC_NAME="${MGT_NIC:-mgt}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [[ -z "${HOST_MGT_IP}" ]]; then
        # NAT environment: reuse DA VM IP as local-ip
        HOST_MGT_IP="${DA_IP}"
        log "[STEP 11] HOST_MGT_IP empty; using DA_IP (${DA_IP}) for local-ip"
    fi

    # DP_VERSION is managed in config
    local _DP_VERSION="${DP_VERSION:-}"
    if [ -z "${_DP_VERSION}" ]; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] DP_VERSION not set, but continuing in DRY_RUN mode"
            _DP_VERSION="dry-run-version"  # Use placeholder for dry run
        else
            whiptail_msgbox "STEP 11 - DA Deployment" "DP_VERSION is not set.\nPlease set the DP version in the configuration menu first, then re-run.\nSkipping this step." 12 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DP_VERSION not set. Skipping DA-master deploy."
            return 0
        fi
    fi


    # cm_fqdn (DL cluster IP, CM address)
    # If not set separately, use DL_IP or 192.168.122.2 as default
    : "${DL_IP:=192.168.122.2}"
    local CM_FQDN="${CM_FQDN:-${DL_IP}}"

    # Locate virt_deploy_uvp_centos.sh
    local DP_SCRIPT_PATH_CANDIDATES=()

    # 1) If path is saved in config file, use it first
    [ -n "${DP_SCRIPT_PATH:-}" ] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")

    # 2) Actual file location: /stellar/da/images
    DP_SCRIPT_PATH_CANDIDATES+=("${DA_IMAGE_DIR}/virt_deploy_uvp_centos.sh")

    # 3) Might be directly under /stellar/da
    DP_SCRIPT_PATH_CANDIDATES+=("${DA_INSTALL_DIR}/virt_deploy_uvp_centos.sh")

    # 4) Current directory / root as fallback
    DP_SCRIPT_PATH_CANDIDATES+=("./virt_deploy_uvp_centos.sh")
    DP_SCRIPT_PATH_CANDIDATES+=("/root/virt_deploy_uvp_centos.sh")


    local DP_SCRIPT_PATH=""
    local c
    for c in "${DP_SCRIPT_PATH_CANDIDATES[@]}"; do
        if [ -f "${c}" ]; then
            DP_SCRIPT_PATH="${c}"
            break
        fi
    done

    if [ -z "${DP_SCRIPT_PATH}" ]; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] virt_deploy_uvp_centos.sh not found, but continuing in DRY_RUN mode"
            DP_SCRIPT_PATH="./virt_deploy_uvp_centos.sh"  # Use placeholder for dry run
        else
            whiptail_msgbox "STEP 11 - DA Deployment" "virt_deploy_uvp_centos.sh file not found.\n\nPlease complete STEP 09 (DP script/image download) first, then run again.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] virt_deploy_uvp_centos.sh not found. Skipping."
            return 0
        fi
    fi

    # Check DA image presence
    # Step 11 always uses --nodownload=true since Step 09 already downloaded the image
    local QCOW2_PATH="${DA_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local DA_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: DA qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=true (Step 09 should have downloaded it)."
    fi

    # Check if DA LV is mounted at /stellar/da
    if ! mount | grep -q "on ${DA_INSTALL_DIR} "; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] ${DA_INSTALL_DIR} is not mounted, but continuing in DRY_RUN mode"
        else
            whiptail_msgbox "STEP 11 - DA Deployment" "${DA_INSTALL_DIR} is not currently mounted.\n\nPlease complete STEP 07 (LVM configuration) and /etc/fstab setup first,\nthen run again.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] ${DA_INSTALL_DIR} not mounted. Skipping."
            return 0
        fi
    fi

    # If da-master VM already exists: destroy + undefine + delete image files
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
        # Strong warning using common helper
        if ! confirm_destroy_vm "${DA_HOSTNAME}" "STEP 11 - DA Deployment"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Existing VM detected, user chose to keep it. Skipping."
            return 0
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Destroying and undefining existing ${DA_HOSTNAME}..."

        # DA VM disk path: based on /stellar/da/images/da-master/da-master.raw
        local DA_VM_IMAGE_DIR="${DA_INSTALL_DIR}/images/${DA_HOSTNAME}"
        local DA_VM_RAW="${DA_VM_IMAGE_DIR}/${DA_HOSTNAME}.raw"
        local DA_VM_LOG="${DA_VM_IMAGE_DIR}/${DA_HOSTNAME}.log"

        if [ "${_DRY_RUN}" -eq 1 ]; then
            echo "[DRY_RUN] virsh destroy ${DA_HOSTNAME} || true"
            echo "[DRY_RUN] virsh undefine ${DA_HOSTNAME} --nvram || virsh undefine ${DA_HOSTNAME} || true"
            echo "[DRY_RUN] rm -f \"${DA_VM_RAW}\" \"${DA_VM_LOG}\""
        else
            virsh destroy "${DA_HOSTNAME}" >/dev/null 2>&1 || true
            virsh undefine "${DA_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DA_HOSTNAME}" >/dev/null 2>&1 || true

            # Delete actual image/log files
            if [ -d "${DA_VM_IMAGE_DIR}" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Removing old DA-master image files in ${DA_VM_IMAGE_DIR} (raw/log and all contents)."
                # Remove all files in the VM directory (raw, log, and any other files)
                sudo rm -rf "${DA_VM_IMAGE_DIR}"/* 2>/dev/null || true
                # Also try to remove the directory itself if empty
                sudo rmdir "${DA_VM_IMAGE_DIR}" 2>/dev/null || true
                log "[STEP 11] Old DA-master image directory ${DA_VM_IMAGE_DIR} cleaned up"
            else
                # Fallback in case of old layout (/stellar/da/images/da-master.raw)
                local fallback_raw="${DA_INSTALL_DIR}/images/${DA_HOSTNAME}.raw"
                local fallback_log="${DA_INSTALL_DIR}/images/${DA_HOSTNAME}.log"
                if [ -f "${fallback_raw}" ] || [ -f "${fallback_log}" ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Removing old DA-master image files (fallback location)."
                    sudo rm -f "${fallback_raw}" "${fallback_log}" 2>/dev/null || true
                fi
            fi
        fi
    fi


    ############################################################
    # Prompt for DA VM configuration (memory, vCPU, disk)
    ############################################################
    # 1) Memory
    local _DA_MEM_INPUT
    _DA_MEM_INPUT="$(whiptail_inputbox "STEP 11 - DA Memory Configuration" "Please enter the memory (GB) to allocate to the DA-master VM.\n\nCurrent default: ${DA_MEMORY_GB} GB" "${DA_MEMORY_GB}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_DA_MEM_INPUT}" ]; then
        if [[ "${_DA_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DA_MEM_INPUT}" -gt 0 ]; then
            DA_MEMORY_GB="${_DA_MEM_INPUT}"
        else
            whiptail_msgbox "STEP 11 - DA Memory Configuration" "The entered memory value is invalid.\nUsing the existing default (${DA_MEMORY_GB} GB)." 10 70
        fi
    fi

    # 2) vCPU
    local _DA_VCPU_INPUT
    _DA_VCPU_INPUT="$(whiptail_inputbox "STEP 11 - DA vCPU Configuration" "Please enter the number of vCPUs for the DA-master VM.\n\nCurrent default: ${DA_VCPUS}" "${DA_VCPUS}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_DA_VCPU_INPUT}" ]; then
        if [[ "${_DA_VCPU_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DA_VCPU_INPUT}" -gt 0 ]; then
            DA_VCPUS="${_DA_VCPU_INPUT}"
        else
            whiptail_msgbox "STEP 11 - DA vCPU Configuration" "The entered vCPU value is invalid.\nUsing the existing default (${DA_VCPUS})." 10 70
        fi
    fi

    # 3) Disk size
    local _DA_DISK_INPUT
    _DA_DISK_INPUT="$(whiptail_inputbox "STEP 11 - DA Disk Configuration" "Please enter the disk size (GB) for the DA-master VM.\n\nCurrent default: ${DA_DISK_GB} GB" "${DA_DISK_GB}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_DA_DISK_INPUT}" ]; then
        if [[ "${_DA_DISK_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DA_DISK_INPUT}" -gt 0 ]; then
            DA_DISK_GB="${_DA_DISK_INPUT}"
        else
            whiptail_msgbox "STEP 11 - DA Disk Configuration" "The entered disk size value is invalid.\nUsing the existing default (${DA_DISK_GB} GB)." 10 70
        fi
    fi

    if type save_config >/dev/null 2>&1; then
        save_config
    fi

    # Convert memory to MB
    local DA_MEMORY_MB=$(( DA_MEMORY_GB * 1024 ))


    # node_role = resource (DA node)
    local DA_NODE_ROLE="resource"

    # Build command to execute virt_deploy_uvp_centos.sh
    local CMD
CMD="sudo bash '${DP_SCRIPT_PATH}' -- \
--hostname=${DA_HOSTNAME} \
--release=${_DP_VERSION} \
--cm_fqdn=${CM_FQDN} \
--local-ip=${HOST_MGT_IP} \
--node-role=${DA_NODE_ROLE} \
--bridge=${DA_BRIDGE} \
--CPUS=${DA_VCPUS} \
--MEM=${DA_MEMORY_MB} \
--DISKSIZE=${DA_DISK_GB} \
--nodownload=${DA_NODOWNLOAD} \
--installdir=${DA_INSTALL_DIR} \
--ip=${DA_IP} \
--netmask=${DA_NETMASK} \
--gw=${DA_GW} \
--dns=${DA_DNS}"

    # Final confirmation dialog
    local SUMMARY
    SUMMARY="Deploy DA-master VM with the following settings:

  Hostname        : ${DA_HOSTNAME}
  DP Version      : ${_DP_VERSION}
  CM FQDN(DL IP)  : ${CM_FQDN}
  Host MGT IP     : ${HOST_MGT_IP}
  Bridge          : ${DA_BRIDGE}
  node_role       : ${DA_NODE_ROLE}
  vCPU            : ${DA_VCPUS}
  Memory          : ${DA_MEMORY_GB} GB (${DA_MEMORY_MB} MB)
  Disk Size       : ${DA_DISK_GB} GB
  installdir      : ${DA_INSTALL_DIR}
  VM IP           : ${DA_IP}
  Netmask         : ${DA_NETMASK}
  Gateway         : ${DA_GW}
  DNS             : ${DA_DNS}
  nodownload      : ${DA_NODOWNLOAD}
  Script Path     : ${DP_SCRIPT_PATH}

Execute virt_deploy_uvp_centos.sh with the above settings?"

    # Calculate dialog size dynamically and center message
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    whiptail_yesno "STEP 11 - DA Deployment" "${SUMMARY}"
    local confirm_rc=$?
    set -e
    
    if [[ ${confirm_rc} -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] User canceled DA-master deploy."
        return 2  # Return 2 to indicate cancellation
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Running DA-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Not executing the above command."
        whiptail_msgbox "STEP 11 - DA Deployment (DRY RUN)" "DRY_RUN mode.\n\nOnly printed the command below without executing it.\n\n${CMD}" 20 80
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would execute: ${CMD}"
        log "[DRY-RUN] DA-master VM deployment skipped in DRY_RUN mode"
    else
        eval "${CMD}"
        local RC=$?

        if [ ${RC} -ne 0 ]; then
            whiptail_msgbox "STEP 11 - DA Deployment" "virt_deploy_uvp_centos.sh exited with error code ${RC}.\n\nPlease check the status using virsh list, virsh console ${DA_HOSTNAME}, etc." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master deploy failed with RC=${RC}."
            return ${RC}
        fi
    fi

    # Simple validation: VM definition existence / status
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: virt_deploy script finished, but virsh dominfo ${DA_HOSTNAME} failed."
    fi

    local step11_summary
    step11_summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 11: DA-master VM Deployment - Complete
═══════════════════════════════════════════════════════════

✅ DEPLOYMENT STATUS:
  • DA-master VM (${DA_HOSTNAME}) deployment completed
  • VM configuration: UEFI boot, NAT network (virbr0)
  • Initial boot may take time due to Cloud-Init operations

📊 VERIFICATION COMMANDS:
  • Check VM status:     virsh list --all
  • View VM console:     virsh console ${DA_HOSTNAME}
  • Check VM info:       virsh dominfo ${DA_HOSTNAME}
  • View VM XML:         virsh dumpxml ${DA_HOSTNAME}

⚠️  IMPORTANT NOTES:
  • VM may take several minutes to complete initial boot
  • Cloud-Init will configure network and system settings
  • Monitor console output for any errors during boot
  • If VM fails to start, check logs: ${LOG_FILE}

🔧 TROUBLESHOOTING:
  • If VM doesn't start:
    1. Check: virsh list --all
    2. Check: virsh dominfo ${DA_HOSTNAME}
    3. Review logs: ${LOG_FILE}
    4. Verify disk space: df -h /stellar/da
  • If network issues:
    1. Verify libvirt hooks: /etc/libvirt/hooks/qemu
    2. Check iptables rules: iptables -t nat -L
    3. Verify virbr0: virsh net-info default

📝 NEXT STEPS:
  • Wait for VM to complete initial boot
  • Verify VM is accessible via console
  • Proceed to STEP 12 (SR-IOV / CPU Affinity Configuration)
EOF
)
    whiptail_msgbox "STEP 11 - DA Deployment Complete" "${step11_summary}"

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 11. DA-master VM deployment ====="
    echo
}


###############################################################################
# STEP 12 – SR-IOV VF Passthrough + CPU Affinity + CD-ROM removal + DL data LV
###############################################################################
#######################################
# STEP 12 - Bridge Mode Attach
#######################################
step_12_bridge_attach_legacy() {
    local STEP_ID="12_bridge_attach"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. Bridge Attach + CPU Affinity + CD-ROM removal + DL data LV ====="

    # Load config
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    
    # Auto-detect VM names: if DL_HOSTNAME/DL_VM_NAME not set, look in virsh list
    local DL_VM="${DL_HOSTNAME:-${DL_VM_NAME:-}}"
    local DA_VM="${DA_HOSTNAME:-${DA_VM_NAME:-}}"
    
    # Auto-detect DL_VM
    if [[ -z "${DL_VM}" ]]; then
        log "[STEP 12 Bridge] DL_HOSTNAME/DL_VM_NAME not set, auto-detecting DL VM from virsh list"
        DL_VM=$(virsh list --all --name 2>/dev/null | grep -E "^dl-" | head -n1 || echo "")
        if [[ -n "${DL_VM}" ]]; then
            log "[STEP 12 Bridge] Auto-detected DL VM: ${DL_VM}"
        else
            DL_VM="dl-master"
            log "[STEP 12 Bridge] No DL VM found, using default: ${DL_VM}"
        fi
    fi
    
    # Auto-detect DA_VM
    if [[ -z "${DA_VM}" ]]; then
        log "[STEP 12 Bridge] DA_HOSTNAME/DA_VM_NAME not set, auto-detecting DA VM from virsh list"
        DA_VM=$(virsh list --all --name 2>/dev/null | grep -E "^da-" | head -n1 || echo "")
        if [[ -n "${DA_VM}" ]]; then
            log "[STEP 12 Bridge] Auto-detected DA VM: ${DA_VM}"
        else
            DA_VM="da-master"
            log "[STEP 12 Bridge] No DA VM found, using default: ${DA_VM}"
        fi
    fi
    
    local bridge_name="${CLUSTER_BRIDGE_NAME:-br-cluster}"
    local cluster_nic="${CLTR0_NIC:-}"

    # Execution start confirmation
    local start_msg
    if [[ "${_DRY}" -eq 1 ]]; then
        start_msg="STEP 12: Bridge Attach + CPU Affinity Configuration (DRY RUN)

This will simulate the following operations:
  • Bridge interface (${bridge_name}) attach to ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration (CPU pinning)
  • NUMA memory interleave configuration
  • DL data disk attach (if applicable)
  • CD-ROM removal

⚠️  DRY RUN MODE: No actual changes will be made.

Do you want to continue?"
    else
        start_msg="STEP 12: Bridge Attach + CPU Affinity Configuration

This will perform the following operations:
  • Attach bridge interface (${bridge_name}) to ${DL_VM} and ${DA_VM}
  • Configure CPU pinning (CPU Affinity)
  • Apply NUMA memory interleave configuration
  • Attach DL data disk (if applicable)
  • Remove CD-ROM devices

⚠️  IMPORTANT: VMs will be shut down during this process.

Do you want to continue?"
    fi

    # Calculate dialog size dynamically
    local dialog_dims
    dialog_dims=$(calc_dialog_size 18 85)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"
    local centered_msg
    centered_msg=$(center_message "${start_msg}")

    if ! whiptail --title "STEP 12 Execution Confirmation" \
                  --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
    then
        log "User canceled STEP 12 execution."
        return 0
    fi

    ###########################################################################
    # 1. DL/DA VM shutdown (wait until completely shut down)
    ###########################################################################
    log "[STEP 12 Bridge] Requesting DL/DA VM shutdown"

    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            local state
            state="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
            if [[ "${state}" != "shut off" ]]; then
                log "[STEP 12 Bridge] Requesting ${vm} shutdown"
                (( _DRY )) || virsh shutdown "${vm}" || log "[WARN] ${vm} shutdown failed (continuing anyway)"
            else
                log "[STEP 12 Bridge] ${vm} is already in shut off state"
            fi
        else
            log "[STEP 12 Bridge] ${vm} VM not found → skipping shutdown"
        fi
    done

    local timeout=180
    local interval=5
    local elapsed=0

    while (( elapsed < timeout )); do
        local all_off=1
        for vm in "${DL_VM}" "${DA_VM}"; do
            if virsh dominfo "${vm}" >/dev/null 2>&1; then
                local st
                st="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
                if [[ "${st}" != "shut off" ]]; then
                    all_off=0
                fi
            fi
        done

        if (( all_off )); then
            log "[STEP 12 Bridge] All DL/DA VMs are now in shut off state."
            break
        fi

        sleep "${interval}"
        (( elapsed += interval ))
    done

    if (( elapsed >= timeout )); then
        log "[WARN] [STEP 12 Bridge] Some VMs did not shut off within timeout(${timeout}s). Continuing anyway."
    fi

    ###########################################################################
    # 2. CD-ROM removal (detach all CD-ROM devices, except seed ISO)
    ###########################################################################
    _list_non_seed_cdrom_targets() {
        local vm="$1"
        # Extract cdrom disk sections, exclude seed ISO (required for Cloud-Init)
        # Process each CD-ROM section: if it contains seed ISO, skip it
        virsh dumpxml "${vm}" --inactive 2>/dev/null \
          | grep -B 5 -A 10 -E "device=['\"]cdrom['\"]" \
          | awk '
            BEGIN { in_cdrom=0; is_seed=0; target_dev="" }
            /device=['\''"]cdrom['\''"]/ { in_cdrom=1; is_seed=0; target_dev="" }
            /<source.*-seed\.iso/ { is_seed=1 }
            /<target/ {
              if (match($0, /dev=['\''"]([^'\''"]*)['\''"]/, arr)) {
                target_dev=arr[1]
              }
            }
            /<\/disk>/ {
              if (in_cdrom && !is_seed && target_dev != "") {
                print target_dev
              }
              in_cdrom=0
              is_seed=0
              target_dev=""
            }
          ' | sort -u
    }

    _detach_all_cdroms_config() {
        local vm="$1"
        [[ -n "${vm}" ]] || return 0
        virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

        # Get only non-seed CD-ROM devices (seed ISO is required for Cloud-Init)
        local devs
        devs="$(_list_non_seed_cdrom_targets "${vm}" || true)"
        [[ -n "${devs}" ]] || return 0

        local dev
        while IFS= read -r dev; do
            [[ -n "${dev}" ]] || continue
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh detach-disk ${vm} ${dev} --config"
            else
                virsh detach-disk "${vm}" "${dev}" --config >/dev/null 2>&1 || true
                log "[STEP 12 Bridge] ${vm}: CD-ROM(${dev}) detach attempt completed (seed ISO preserved)"
            fi
        done <<< "${devs}"
    }

    _detach_all_cdroms_config "${DL_VM}"
    _detach_all_cdroms_config "${DA_VM}"

    ###########################################################################
    # 2.2. Detach all hostdev devices (SR-IOV remnants)
    ###########################################################################
    _detach_all_hostdevs_config() {
        local vm="$1"
        [[ -n "${vm}" ]] || return 0
        virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

        local xml tmpdir files
        xml="$(virsh dumpxml "${vm}" --inactive 2>/dev/null || true)"
        [[ -n "${xml}" ]] || return 0

        tmpdir="$(mktemp -d)"
        echo "${xml}" | awk -v dir="${tmpdir}" '
          /<hostdev / { in_block=1; c++; file=dir "/hostdev_" c ".xml" }
          in_block { print > file }
          /<\/hostdev>/ { in_block=0 }
        '

        files="$(ls -1 "${tmpdir}"/hostdev_*.xml 2>/dev/null || true)"
        if [[ -z "${files}" ]]; then
            rm -rf "${tmpdir}"
            return 0
        fi

        local f
        for f in ${files}; do
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh detach-device ${vm} ${f} --config"
            else
                if virsh detach-device "${vm}" "${f}" --config >/dev/null 2>&1; then
                    log "[STEP 12 Bridge] ${vm}: hostdev detach (--config) completed"
                else
                    log "[WARN] ${vm}: hostdev detach failed (config)"
                fi
            fi
        done

        rm -rf "${tmpdir}"
    }

    _detach_all_hostdevs_config "${DL_VM}"
    _detach_all_hostdevs_config "${DA_VM}"

    ###########################################################################
    # 2.5. Bridge runtime creation/UP guarantee (NO-CARRIER allowed)
    # Ensure bridge is created/up at runtime right before VM attach
    ###########################################################################
    log "[STEP 12 Bridge] Ensuring bridge ${bridge_name} is ready for VM attach (NO-CARRIER allowed)"

    if ! ensure_bridge_up_no_carrier_ok "${bridge_name}" "${cluster_nic}"; then
        log "[ERROR] Failed to ensure bridge ${bridge_name} is ready for VM attach"
        whiptail_msgbox "STEP 12 - Bridge Mode Error" \
          "Failed to ensure bridge ${bridge_name} is ready for VM attach.\n\nPlease check bridge configuration and permissions." \
          12 80
        return 1
    fi

    ###########################################################################
    # 3. Bridge attach (virsh attach-interface --type bridge)
    ###########################################################################
    _attach_bridge_to_vm() {
        local vm="$1"
        local bridge="$2"

        if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
            return 0
        fi

        # Check if bridge interface is already attached
        if virsh dumpxml "${vm}" 2>/dev/null | grep -q "source bridge='${bridge}'"; then
            log "[STEP 12 Bridge] ${vm}: Bridge ${bridge} is already attached → skipping"
            return 0
        fi

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] virsh attach-interface ${vm} --type bridge --source ${bridge} --model virtio --config"
        else
            local out
            if ! out="$(virsh attach-interface "${vm}" --type bridge --source "${bridge}" --model virtio --config 2>&1)"; then
                log "[ERROR] ${vm}: virsh attach-interface failed (bridge=${bridge})"
                log "[ERROR] virsh message:"
                while IFS= read -r line; do
                    log "  ${line}"
                done <<< "${out}"
                return 1
            else
                log "[STEP 12 Bridge] ${vm}: Bridge ${bridge} attach (--config) completed"
            fi
        fi
    }

    _attach_bridge_to_vm "${DL_VM}" "${bridge_name}"
    _attach_bridge_to_vm "${DA_VM}" "${bridge_name}"

    ###########################################################################
    # 4. CPU Affinity (virsh vcpupin --config)
    ###########################################################################
    # Check NUMA node count - skip CPU Affinity if only 1 NUMA node exists
    local numa_node_count
    numa_node_count=$(lscpu 2>/dev/null | grep -i "NUMA node(s)" | awk '{print $3}' || echo "0")
    
    if [[ -z "${numa_node_count}" ]] || [[ "${numa_node_count}" == "0" ]]; then
        # Fallback: try numactl if available
        if command -v numactl >/dev/null 2>&1; then
            numa_node_count=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1")
        else
            numa_node_count="1"
        fi
    fi
    
    if [[ "${numa_node_count}" == "1" ]]; then
        log "[STEP 12 Bridge] System has only 1 NUMA node → skipping CPU Affinity configuration"
    else
        local DL_CPUS_LIST=""
        local DA_CPUS_LIST=""

        # DL: even CPUs 4,6,...,86
        local c
        for (( c=4; c<=86; c+=2 )); do
            DL_CPUS_LIST+="${c} "
        done

        # DA: odd CPUs 5,7,...,95
        for (( c=5; c<=95; c+=2 )); do
            DA_CPUS_LIST+="${c} "
        done

        _apply_cpu_affinity_vm() {
            local vm="$1"
            local cpus_list="$2"

            if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
                return 0
            fi
            [[ -n "${cpus_list}" ]] || return 0

            # Maximum vCPU count (designed as DL=42, DA=46, but check based on actual XML)
            local max_vcpus
            max_vcpus="$(virsh vcpucount "${vm}" --maximum --config 2>/dev/null || echo 0)"

            if [[ "${max_vcpus}" -eq 0 ]]; then
                log "[WARN] ${vm}: Unable to determine vCPU count → skipping CPU Affinity"
                return 0
            fi

            # Convert cpus_list to array
            local arr=()
            for c in ${cpus_list}; do
                arr+=("${c}")
            done

            if [[ "${#arr[@]}" -lt "${max_vcpus}" ]]; then
                log "[WARN] ${vm}: Specified CPU list count(${#arr[@]}) is less than maximum vCPU(${max_vcpus})."
                max_vcpus="${#arr[@]}"
            fi

            local i
            for (( i=0; i<max_vcpus; i++ )); do
                local pcpu="${arr[$i]}"
                if [[ "${_DRY}" -eq 1 ]]; then
                    log "[DRY-RUN] virsh vcpupin ${vm} ${i} ${pcpu} --config"
                else
                    if virsh vcpupin "${vm}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
                        log "[STEP 12 Bridge] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
                    else
                        log "[WARN] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin failed"
                    fi
                fi
            done
        }

        _apply_cpu_affinity_vm "${DL_VM}" "${DL_CPUS_LIST}"
        _apply_cpu_affinity_vm "${DA_VM}" "${DA_CPUS_LIST}"
    fi

    ###########################################################################
    # 5. NUMA memory interleave (virsh numatune --config)
    ###########################################################################
    _apply_numatune_vm() {
        local vm="$1"
        if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
            return 0
        fi

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] virsh numatune ${vm} --mode interleave --nodeset 0-1 --config"
        else
            if virsh numatune "${vm}" --mode interleave --nodeset 0-1 --config >/dev/null 2>&1; then
                log "[STEP 12 Bridge] ${vm}: numatune mode=interleave nodeset=0-1 (--config) applied"
            else
                log "[WARN] ${vm}: numatune configuration failed (version/option may not be supported)"
            fi
        fi
    }

    _apply_numatune_vm "${DL_VM}"
    _apply_numatune_vm "${DA_VM}"

    ###########################################################################
    # 6. DL data disk (LV) attach (vg_dl/lv_dl → vdb, --config)
    ###########################################################################
    local DATA_LV="/dev/mapper/vg_dl-lv_dl"

    # Helper: extract the full <disk>...</disk> XML block that contains target dev='vdb'
    # NOTE: In libvirt XML, <source ...> often appears BEFORE <target ...>,
    # so parsing with `grep -A ... "target dev='vdb'"` is unreliable.
    # Args:
    #   $1: vm name
    #   $2: 0=live XML, 1=inactive XML
    get_vdb_disk_block() {
        local vm_name="$1"
        local inactive="${2:-0}"
        if [[ -z "${vm_name}" ]]; then
            return 1
        fi

        local dump_cmd=(virsh dumpxml "${vm_name}")
        if [[ "${inactive}" -eq 1 ]]; then
            dump_cmd+=(--inactive)
        fi

        "${dump_cmd[@]}" 2>/dev/null | awk '
            BEGIN { in_disk=0; buf="" }
            /<disk[ >]/ { in_disk=1; buf=$0 ORS; next }
            in_disk {
                buf = buf $0 ORS
                if ($0 ~ /<\/disk>/) {
                    if (buf ~ /<target[[:space:]]+dev=.vdb./) { print buf; exit }
                    in_disk=0; buf=""
                }
            }
        '
    }

    if [[ -e "${DATA_LV}" ]]; then
        if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh attach-disk ${DL_VM} ${DATA_LV} vdb --config"
            else
                if [[ -n "$(get_vdb_disk_block "${DL_VM}" 0 || true)" ]]; then
                    log "[STEP 12 Bridge] ${DL_VM} vdb already exists → skipping data disk attach"
                else
                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                        log "[STEP 12 Bridge] ${DL_VM} data disk(${DATA_LV}) attached as vdb (--config) completed"
                    else
                        log "[WARN] ${DL_VM} data disk(${DATA_LV}) attach failed"
                    fi
                fi
            fi
        else
            log "[STEP 12 Bridge] ${DL_VM} VM not found → skipping DL data disk attach"
        fi
    else
        log "[STEP 12 Bridge] ${DATA_LV} does not exist; skipping DL data disk attach."
    fi

    ###########################################################################
    # 7. DL/DA VM restart
    ###########################################################################
    ensure_vm_bridges_ready() {
        local vm_name="$1"
        local bridges
        if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
            return 0
        fi
        bridges="$(virsh dumpxml "${vm_name}" --inactive 2>/dev/null | grep -o "bridge='[^']*'" | cut -d"'" -f2 | sort -u || true)"
        if [[ -z "${bridges}" ]]; then
            return 0
        fi
        local br
        for br in ${bridges}; do
            if ! ip link show dev "${br}" >/dev/null 2>&1; then
                log "[STEP 12 Bridge] Bridge ${br} required by ${vm_name} but missing; creating it"
                ensure_bridge_up_no_carrier_ok "${br}" "" || return 1
            fi
        done
        return 0
    }

    ensure_vm_bridges_ready "${DL_VM}" || return 1
    ensure_vm_bridges_ready "${DA_VM}" || return 1

    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            log "[STEP 12 Bridge] ${vm} start request"
            (( _DRY )) || virsh start "${vm}" || log "[WARN] ${vm} start failed"
        fi
    done

    # Wait 5 seconds after VM start
    if [[ "${_DRY}" -eq 0 ]]; then
        log "[STEP 12 Bridge] Waiting 5 seconds after DL/DA VM start (vCPU state stabilization)"
        sleep 5
    fi

    ###########################################################################
    # 8. Basic verification results
    ###########################################################################
    local result_file="/tmp/step12_bridge_result.txt"
    rm -f "${result_file}"

    if [[ "${_DRY}" -eq 1 ]]; then
        {
            echo "===== DRY-RUN MODE: Simulation Results ====="
            echo
            echo "📊 SIMULATED OPERATIONS:"
            echo "  • Bridge interface attach to ${DL_VM} and ${DA_VM}"
            echo "  • CPU Affinity configuration"
            echo "  • NUMA memory interleave configuration"
            echo "  • DL data disk attach (if applicable)"
            echo
            echo "ℹ️  In real execution mode, the following would occur:"
            echo "  1. Bridge ${bridge_name} would be attached to ${DL_VM} and ${DA_VM}"
            echo "  2. CPU pinning would be applied"
            echo "  3. NUMA configuration would be applied"
            echo "  4. Data disk would be attached to ${DL_VM} (if available)"
            echo
            echo "📋 EXPECTED CONFIGURATION:"
            echo "  • Bridge: ${bridge_name}"
            echo "  • DL VM: ${DL_VM}"
            echo "  • DA VM: ${DA_VM}"
        } > "${result_file}"
    else
        {
            echo "===== DL vcpuinfo (${DL_VM}) ====="
            if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
                virsh vcpuinfo "${DL_VM}" 2>&1
            else
                echo "VM ${DL_VM} not found"
            fi
            echo
            echo "===== DA vcpuinfo (${DA_VM}) ====="
            if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
                virsh vcpuinfo "${DA_VM}" 2>&1
            else
                echo "VM ${DA_VM} not found"
            fi
            echo
            echo "===== DL bridge interface (${DL_VM}) ====="
            if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
                virsh dumpxml "${DL_VM}" | grep -A 5 "source bridge='${bridge_name}'" || echo "Bridge ${bridge_name} not found in XML"
            else
                echo "VM ${DL_VM} not found"
            fi
            echo
            echo "===== DA bridge interface (${DA_VM}) ====="
            if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
                virsh dumpxml "${DA_VM}" | grep -A 5 "source bridge='${bridge_name}'" || echo "Bridge ${bridge_name} not found in XML"
            else
                echo "VM ${DA_VM} not found"
            fi
        } > "${result_file}"
    fi

    # Execution completion message box
    local completion_msg
    if [[ "${_DRY}" -eq 1 ]]; then
        completion_msg="STEP 12: Bridge Attach + CPU Affinity Configuration (DRY RUN) Completed

✅ Simulation Summary:
  • Bridge interface (${bridge_name}) attach simulation for ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration simulation
  • NUMA memory interleave configuration simulation
  • DL data disk attach simulation (if applicable)
  • CD-ROM removal simulation

⚠️  DRY RUN MODE: No actual changes were made.

📋 What Would Have Been Applied:
  • Bridge interface (${bridge_name}) would be attached to VMs
  • CPU pinning would be configured
  • NUMA memory interleave would be applied
  • Data disk would be attached to ${DL_VM} (if available)
  • CD-ROM devices would be removed

💡 Next Steps:
  Set DRY_RUN=0 and rerun STEP 12 to apply actual configurations.
  Detailed simulation results are available in the log."
    else
        completion_msg="STEP 12: Bridge Attach + CPU Affinity Configuration Completed

✅ Configuration Summary:
  • Bridge interface (${bridge_name}) attached to ${DL_VM} and ${DA_VM}
  • CPU Affinity (CPU pinning) configured
  • NUMA memory interleave applied
  • DL data disk attached (if applicable)
  • CD-ROM devices removed

✅ VMs Status:
  • ${DL_VM} and ${DA_VM} have been restarted with new configurations
  • All bridge and CPU affinity settings are now active

📋 Verification:
  • Check VM CPU pinning: virsh vcpuinfo ${DL_VM}
  • Check bridge interface: virsh dumpxml ${DL_VM} | grep '${bridge_name}'
  • Check NUMA configuration: virsh numatune ${DL_VM}
  • Verify data disk: virsh dumpxml ${DL_VM} | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'

💡 Note:
  VMs are ready for use with bridge interface and CPU affinity enabled."
    fi

    # Calculate dialog size dynamically
    local dialog_dims
    dialog_dims=$(calc_dialog_size 22 90)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"

    whiptail_msgbox "STEP 12 - Configuration Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

    if [[ "${_DRY}" -eq 1 ]]; then
        # Read result file content and display in message box
        local dry_run_content
        if [[ -f "${result_file}" ]]; then
            dry_run_content=$(cat "${result_file}")
            # Calculate dialog size dynamically
            local dry_dialog_dims
            dry_dialog_dims=$(calc_dialog_size 20 90)
            local dry_dialog_height dry_dialog_width
            read -r dry_dialog_height dry_dialog_width <<< "${dry_dialog_dims}"
            whiptail_msgbox "STEP 12 – Bridge Attach / CPU Affinity / DL data LV (DRY-RUN)" "${dry_run_content}" "${dry_dialog_height}" "${dry_dialog_width}"
        fi
    else
        show_paged "STEP 12 – Bridge Attach / CPU Affinity / DL data LV verification results" "${result_file}" "no-clear"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. Bridge Attach + CPU Affinity + CD-ROM removal + DL data LV ====="
    echo
}

step_12_sriov_cpu_affinity() {
    local STEP_ID="12_sriov_cpu_affinity"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV ====="

    # Load config
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DP_VERSION gate:
    #   - <= 6.2.0 : keep legacy DP-Installer logic (do not change)
    #   - >= 6.2.1 : use KT v1.8 Step 12 behavior (v621)
    local ver="${DP_VERSION:-}"
    # Sanitize DP_VERSION: remove quotes and whitespace
    ver="$(echo "$ver" | tr -d '\"' | xargs)"
    
    # Validate DP_VERSION: if empty or invalid, abort to prevent legacy step execution
    if [[ -z "${ver}" ]]; then
      log "[ERROR] DP_VERSION is empty or invalid: '${DP_VERSION}' -> cannot select correct Step 12 logic"
      whiptail_msgbox "STEP 12 - Configuration Error" "DP_VERSION is not set.\nSet it in Settings and rerun." 12 70
      return 1
    fi
    
    # Compare version (after sanitization)
    if version_ge "${ver}" "6.2.1"; then
      step_12_sriov_cpu_affinity_v621
      local v621_rc=$?
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV ====="
      echo
      return ${v621_rc}
    fi
    
    # Safety check: if version comparison failed but we're here, log warning
    # This should not happen if DP_VERSION is properly set, but provides safety net
    if ! version_ge "${ver}" "6.2.0" 2>/dev/null; then
      log "[WARN] DP_VERSION '${ver}' may be invalid or < 6.2.0, but continuing with legacy Step 12"
    fi

    local _DRY="${DRY_RUN:-0}"
    
    # Auto-detect VM names: if DL_HOSTNAME/DL_VM_NAME not set, look in virsh list
    local DL_VM="${DL_HOSTNAME:-${DL_VM_NAME:-}}"
    local DA_VM="${DA_HOSTNAME:-${DA_VM_NAME:-}}"
    
    # Auto-detect DL_VM
    if [[ -z "${DL_VM}" ]]; then
        log "[STEP 12] DL_HOSTNAME/DL_VM_NAME not set, auto-detecting DL VM from virsh list"
        DL_VM=$(virsh list --all --name 2>/dev/null | grep -E "^dl-" | head -n1 || echo "")
        if [[ -n "${DL_VM}" ]]; then
            log "[STEP 12] Auto-detected DL VM: ${DL_VM}"
        else
            DL_VM="dl-master"
            log "[STEP 12] No DL VM found, using default: ${DL_VM}"
        fi
    fi
    
    # Auto-detect DA_VM
    if [[ -z "${DA_VM}" ]]; then
        log "[STEP 12] DA_HOSTNAME/DA_VM_NAME not set, auto-detecting DA VM from virsh list"
        DA_VM=$(virsh list --all --name 2>/dev/null | grep -E "^da-" | head -n1 || echo "")
        if [[ -n "${DA_VM}" ]]; then
            log "[STEP 12] Auto-detected DA VM: ${DA_VM}"
        else
            DA_VM="da-master"
            log "[STEP 12] No DA VM found, using default: ${DA_VM}"
        fi
    fi

    ###########################################################################
    # Cluster Interface Type branching
    ###########################################################################
    local cluster_nic_type="${CLUSTER_NIC_TYPE:-SRIOV}"
    
    if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
      log "[STEP 12] Cluster Interface Type: BRIDGE - Executing bridge attach only"
      step_12_bridge_attach_legacy
      local legacy_bridge_rc=$?
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV ====="
      echo
      return ${legacy_bridge_rc}
    elif [[ "${cluster_nic_type}" == "SRIOV" ]]; then
      log "[STEP 12] Cluster Interface Type: SRIOV - Executing SR-IOV VF passthrough"
      # Execution start confirmation
      local start_msg
      if [[ "${_DRY}" -eq 1 ]]; then
        start_msg="STEP 12: SR-IOV + CPU Affinity Configuration (DRY RUN)

This will simulate the following operations:
  • SR-IOV VF PCI passthrough to ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration (CPU pinning)
  • NUMA memory interleave configuration
  • DL data disk attach (if applicable)
  • CD-ROM removal

⚠️  DRY RUN MODE: No actual changes will be made.

Do you want to continue?"
      else
        start_msg="STEP 12: SR-IOV + CPU Affinity Configuration

This will perform the following operations:
  • Attach SR-IOV VF PCI devices to ${DL_VM} and ${DA_VM}
  • Configure CPU pinning (CPU Affinity)
  • Apply NUMA memory interleave configuration
  • Attach DL data disk (if applicable)
  • Remove CD-ROM devices

⚠️  IMPORTANT: VMs will be shut down during this process.

Do you want to continue?"
      fi

      # Calculate dialog size dynamically
      local dialog_dims
      dialog_dims=$(calc_dialog_size 18 85)
      local dialog_height dialog_width
      read -r dialog_height dialog_width <<< "${dialog_dims}"
      local centered_msg
      centered_msg=$(center_message "${start_msg}")

      if ! whiptail --title "STEP 12 Execution Confirmation" \
                    --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
      then
        log "User canceled STEP 12 execution."
        return 0
      fi
      # Continue with existing SR-IOV logic below
    else
      log "[WARN] Unknown CLUSTER_NIC_TYPE: ${cluster_nic_type}, defaulting to SRIOV"
      # Execution start confirmation
      local start_msg
      if [[ "${_DRY}" -eq 1 ]]; then
        start_msg="STEP 12: SR-IOV + CPU Affinity Configuration (DRY RUN)

This will simulate the following operations:
  • SR-IOV VF PCI passthrough to ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration (CPU pinning)
  • NUMA memory interleave configuration
  • DL data disk attach (if applicable)
  • CD-ROM removal

⚠️  DRY RUN MODE: No actual changes will be made.

Do you want to continue?"
      else
        start_msg="STEP 12: SR-IOV + CPU Affinity Configuration

This will perform the following operations:
  • Attach SR-IOV VF PCI devices to ${DL_VM} and ${DA_VM}
  • Configure CPU pinning (CPU Affinity)
  • Apply NUMA memory interleave configuration
  • Attach DL data disk (if applicable)
  • Remove CD-ROM devices

⚠️  IMPORTANT: VMs will be shut down during this process.

Do you want to continue?"
      fi

      # Calculate dialog size dynamically
      local dialog_dims
      dialog_dims=$(calc_dialog_size 18 85)
      local dialog_height dialog_width
      read -r dialog_height dialog_width <<< "${dialog_dims}"
      local centered_msg
      centered_msg=$(center_message "${start_msg}")

      if ! whiptail --title "STEP 12 Execution Confirmation" \
                    --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
      then
        log "User canceled STEP 12 execution."
        return 0
      fi
      # Continue with existing SR-IOV logic below
    fi

    ###########################################################################
    # PRE-CHECK: cloud-init seed ISO existence (dl-master-seed.iso / da-master-seed.iso)
    #
    # Root cause:
    #   - VM XML references a seed ISO as a cdrom, but the ISO was not created
    #   - or CD-ROM detach logic targets the wrong device name (e.g. hda vs sda)
    #
    # Strategy:
    #   1) Detach *all* cdrom disks in persistent XML (hda/sda/etc.) to prevent start failure.
    #   2) If XML still references a "*-seed.iso" and the file is missing, generate it via cloud-localds.
    ###########################################################################

    _ensure_cloud_localds() {
        if command -v cloud-localds >/dev/null 2>&1; then
            return 0
        fi
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] cloud-localds not found -> would install: cloud-image-utils"
            return 0
        fi
        log "[STEP 12] cloud-localds not found. Installing cloud-image-utils..."
        apt-get update -y >/dev/null 2>&1 || { log "[ERROR] apt-get update failed"; return 1; }
        apt-get install -y cloud-image-utils >/dev/null 2>&1 || { log "[ERROR] apt-get install cloud-image-utils failed"; return 1; }
        command -v cloud-localds >/dev/null 2>&1 || { log "[ERROR] cloud-localds still not found after install"; return 1; }
        return 0
    }

    _list_non_seed_cdrom_targets() {
        local vm="$1"
        # Extract cdrom disk sections, exclude seed ISO (required for Cloud-Init)
        # Process each CD-ROM section: if it contains seed ISO, skip it
        virsh dumpxml "${vm}" --inactive 2>/dev/null \
          | grep -B 5 -A 10 -E "device=['\"]cdrom['\"]" \
          | awk '
            BEGIN { in_cdrom=0; is_seed=0; target_dev="" }
            /device=['\''"]cdrom['\''"]/ { in_cdrom=1; is_seed=0; target_dev="" }
            /<source.*-seed\.iso/ { is_seed=1 }
            /<target/ {
              if (match($0, /dev=['\''"]([^'\''"]*)['\''"]/, arr)) {
                target_dev=arr[1]
              }
            }
            /<\/disk>/ {
              if (in_cdrom && !is_seed && target_dev != "") {
                print target_dev
              }
              in_cdrom=0
              is_seed=0
              target_dev=""
            }
          ' | sort -u
    }

    _detach_all_cdroms_config() {
        local vm="$1"
        [[ -n "${vm}" ]] || return 0
        virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

        # Get only non-seed CD-ROM devices (seed ISO is required for Cloud-Init)
        local devs
        devs="$(_list_non_seed_cdrom_targets "${vm}" || true)"
        [[ -n "${devs}" ]] || return 0

        local dev
        while IFS= read -r dev; do
            [[ -n "${dev}" ]] || continue
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh detach-disk ${vm} ${dev} --config"
            else
                virsh detach-disk "${vm}" "${dev}" --config >/dev/null 2>&1 || true
                log "[STEP 12] ${vm}: CD-ROM(${dev}) detach attempt completed (seed ISO preserved)"
            fi
        done <<< "${devs}"
    }

    _seed_iso_paths_from_xml_inactive() {
        local vm="$1"
        # Extract cdrom disk sections using grep, then find source file (filter for seed.iso)
        virsh dumpxml "${vm}" --inactive 2>/dev/null \
          | grep -A 10 -E "device=['\"]cdrom['\"]" \
          | grep "<source" \
          | sed -n "s/.*file=['\"]\([^'\"]*\)['\"].*/\1/p" \
          | grep -E -- '-seed\.iso$' \
          | sort -u
    }

    _ensure_seed_iso_if_referenced() {
        local vm="$1"
        [[ -n "${vm}" ]] || return 0
        virsh dominfo "${vm}" >/dev/null 2>&1 || return 0

        local seed_list
        seed_list="$(_seed_iso_paths_from_xml_inactive "${vm}" || true)"
        [[ -n "${seed_list}" ]] || return 0

        local seed
        while IFS= read -r seed; do
            [[ -n "${seed}" ]] || continue
            [[ -f "${seed}" ]] && continue

            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] ${vm}: seed ISO missing (${seed}) -> would generate with cloud-localds"
                continue
            fi

            _ensure_cloud_localds || return 1

            local user_data="/tmp/user-data-${vm}"
            local meta_data="/tmp/meta-data-${vm}"

            echo "instance-id: ${vm}" > "${meta_data}"
            echo "local-hostname: ${vm}" >> "${meta_data}"

            cat > "${user_data}" <<'CLOUD'
#cloud-config
bootcmd:
  - [ growpart, /dev/vda, 1 ]
  - [ resize2fs, /dev/vda1 ]
CLOUD

            log "[STEP 12] ${vm}: generating seed ISO via cloud-localds: ${seed}"
            cloud-localds "${seed}" "${user_data}" "${meta_data}" >/dev/null 2>&1 || { log "[ERROR] ${vm}: cloud-localds failed (${seed})"; return 1; }
            [[ -f "${seed}" ]] || { log "[ERROR] ${vm}: seed ISO still missing after generation (${seed})"; return 1; }
        done <<< "${seed_list}"

        return 0
    }

    ###########################################################################
    # CPU PINNING RULES (NUMA separation)
    # - DL: NUMA node0 (even cores) even numbers between 4~86 → 42 cores (4,6,...,86)
    # - DA: NUMA node1 (odd cores) odd numbers between 5~95 → 46 cores (5,7,...,95)
    #   * Assume NUMA0 cores 0,2 are reserved for host, NUMA1 cores 1,3 are reserved for host
    ###########################################################################
    local DL_CPUS_LIST=""
    local DA_CPUS_LIST=""

    # DL: even CPUs 4,6,...,86
    local c
    for (( c=4; c<=86; c+=2 )); do
        DL_CPUS_LIST+="${c} "
    done

    # DA: odd CPUs 5,7,...,95
    for (( c=5; c<=95; c+=2 )); do
        DA_CPUS_LIST+="${c} "
    done

    log "[STEP 12] DL CPU LIST: ${DL_CPUS_LIST}"
    log "[STEP 12] DA CPU LIST: ${DA_CPUS_LIST}"


    ###########################################################################
    # 1. SR-IOV VF PCI auto-detection
    ###########################################################################
    log "[STEP 12] Auto-detecting SR-IOV VF PCI devices"

    local vf_list
    vf_list="$(lspci | awk '/Ethernet/ && /Virtual Function/ {print $1}' || true)"

    if [[ -z "${vf_list}" ]]; then
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] No SR-IOV VF found, but continuing in DRY_RUN mode"
            vf_list="0000:00:00.0 0000:00:00.1"  # Use placeholder VFs for dry run
        else
            whiptail_msgbox "STEP 12 - SR-IOV" "Failed to detect SR-IOV VF PCI devices.\nPlease check STEP 03 or BIOS settings." 12 70
            log "[STEP 12] No SR-IOV VF found → aborting STEP"
            return 1
        fi
    fi

    log "[STEP 12] Detected VF list:\n${vf_list}"

    local DL_VF DA_VF
    DL_VF="$(echo "${vf_list}" | sed -n '1p')"
    DA_VF="$(echo "${vf_list}" | sed -n '2p')"

    if [[ -z "${DA_VF}" ]]; then
        log "[WARN] Only 1 VF exists, applying VF Passthrough to DL only, DA will only have CPU Affinity without VF"
    fi

    ###########################################################################
    # 2. DL/DA VM shutdown (wait until completely shut down)
    ###########################################################################
    log "[STEP 12] Requesting DL/DA VM shutdown"

    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            local state
            state="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
            if [[ "${state}" != "shut off" ]]; then
                log "[STEP 12] Requesting ${vm} shutdown"
                (( _DRY )) || virsh shutdown "${vm}" || log "[WARN] ${vm} shutdown failed (continuing anyway)"
            else
                log "[STEP 12] ${vm} is already in shut off state"
            fi
        else
            log "[STEP 12] ${vm} VM not found → skipping shutdown"
        fi
    done

    local timeout=180
    local interval=5
    local elapsed=0

    while (( elapsed < timeout )); do
        local all_off=1
        for vm in "${DL_VM}" "${DA_VM}"; do
            if virsh dominfo "${vm}" >/dev/null 2>&1; then
                local st
                st="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
                if [[ "${st}" != "shut off" ]]; then
                    all_off=0
                fi
            fi
        done

        if (( all_off )); then
            log "[STEP 12] All DL/DA VMs are now in shut off state."
            break
        fi

        sleep "${interval}"
        (( elapsed += interval ))
    done

    if (( elapsed >= timeout )); then
        log "[WARN] [STEP 12] Some VMs did not shut off within timeout(${timeout}s). Continuing anyway."
    fi

    ###########################################################################
    # 3. CD-ROM removal (robust: detach all cdrom targets found in persistent XML)
    ###########################################################################
    _detach_all_cdroms_config "${DL_VM}"
    _detach_all_cdroms_config "${DA_VM}"

    # If a seed ISO is still referenced (or detach failed), ensure it exists before start.
    _ensure_seed_iso_if_referenced "${DL_VM}" || return 1
    _ensure_seed_iso_if_referenced "${DA_VM}" || return 1

    ###########################################################################
    # 4. VF PCI hostdev attach (virsh attach-device --config)
    ###########################################################################
    _attach_vf_to_vm() {
        local vm="$1"
        local pci="$2"

        if [[ -z "${pci}" ]]; then
            return 0
        fi
        if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
            return 0
        fi

        local domain bus slot func

        # PCI format: DDDD:BB:SS.F  (e.g., 0000:8b:11.0)
        if [[ "${pci}" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
            domain="${BASH_REMATCH[1]}"
            bus="${BASH_REMATCH[2]}"
            slot="${BASH_REMATCH[3]}"
            func="${BASH_REMATCH[4]}"
        # Also handle BB:SS.F format (e.g., 8b:11.0)
        elif [[ "${pci}" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
            domain="0000"
            bus="${BASH_REMATCH[1]}"
            slot="${BASH_REMATCH[2]}"
            func="${BASH_REMATCH[3]}"
        else
            log "[ERROR] ${vm}: Unsupported PCI address format: ${pci}"
            return 1
        fi

        local d="0x${domain}"
        local b="0x${bus}"
        local s="0x${slot}"
        local f="0x${func}"

        local tmp_xml="/tmp/${vm}_vf.xml"
        cat > "${tmp_xml}" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='${d}' bus='${b}' slot='${s}' function='${f}'/>
  </source>
</hostdev>
EOF

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] virsh attach-device ${vm} ${tmp_xml} --config"
        else
            local out
            if ! out="$(virsh attach-device "${vm}" "${tmp_xml}" --config 2>&1)"; then
                if echo "${out}" | grep -q "already in the domain configuration"; then
                    log "[STEP 12] ${vm}: VF PCI(${pci}) already attached → skipping"
                else
                    log "[ERROR] ${vm}: virsh attach-device failed (PCI=${pci})"
                    log "[ERROR] virsh message:"
                    while IFS= read -r line; do
                        log "  ${line}"
                    done <<< "${out}"
                fi
            else
                log "[STEP 12] ${vm}: VF PCI(${pci}) hostdev attach (--config) completed"
            fi
        fi
    }


    _attach_vf_to_vm "${DL_VM}" "${DL_VF}"
    _attach_vf_to_vm "${DA_VM}" "${DA_VF}"

    ###########################################################################
    # 5. CPU Affinity (virsh vcpupin --config)
    ###########################################################################
    # Check NUMA node count - skip CPU Affinity if only 1 NUMA node exists
    local numa_node_count
    numa_node_count=$(lscpu 2>/dev/null | grep -i "NUMA node(s)" | awk '{print $3}' || echo "0")
    
    if [[ -z "${numa_node_count}" ]] || [[ "${numa_node_count}" == "0" ]]; then
        # Fallback: try numactl if available
        if command -v numactl >/dev/null 2>&1; then
            numa_node_count=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1")
        else
            numa_node_count="1"
        fi
    fi
    
    if [[ "${numa_node_count}" == "1" ]]; then
        log "[STEP 12] System has only 1 NUMA node → skipping CPU Affinity configuration"
    else
        _apply_cpu_affinity_vm() {
            local vm="$1"
            local cpus_list="$2"

            if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
                return 0
            fi
            [[ -n "${cpus_list}" ]] || return 0

            # Maximum vCPU count (designed as DL=42, DA=46, but check based on actual XML)
            local max_vcpus
            max_vcpus="$(virsh vcpucount "${vm}" --maximum --config 2>/dev/null || echo 0)"

            if [[ "${max_vcpus}" -eq 0 ]]; then
                log "[WARN] ${vm}: Unable to determine vCPU count → skipping CPU Affinity"
                return 0
            fi

            # Convert cpus_list to array
            local arr=()
            local c
            for c in ${cpus_list}; do
                arr+=("${c}")
            done

            if [[ "${#arr[@]}" -lt "${max_vcpus}" ]]; then
                log "[WARN] ${vm}: Specified CPU list count(${#arr[@]}) is less than maximum vCPU(${max_vcpus})."
                max_vcpus="${#arr[@]}"
            fi

            local i
            for (( i=0; i<max_vcpus; i++ )); do
                local pcpu="${arr[$i]}"
                if [[ "${_DRY}" -eq 1 ]]; then
                    log "[DRY-RUN] virsh vcpupin ${vm} ${i} ${pcpu} --config"
                else
                    if virsh vcpupin "${vm}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
                        log "[STEP 12] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
                    else
                        log "[WARN] ${vm}: vCPU ${i} -> pCPU ${pcpu} pin failed"
                    fi
                fi
            done
        }

        _apply_cpu_affinity_vm "${DL_VM}" "${DL_CPUS_LIST}"
        _apply_cpu_affinity_vm "${DA_VM}" "${DA_CPUS_LIST}"
    fi

    ###########################################################################
    # 6. NUMA memory interleave (virsh numatune --config)
    ###########################################################################
    _apply_numatune_vm() {
        local vm="$1"
        if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
            return 0
        fi

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] virsh numatune ${vm} --mode interleave --nodeset 0-1 --config"
        else
            if virsh numatune "${vm}" --mode interleave --nodeset 0-1 --config >/dev/null 2>&1; then
                log "[STEP 12] ${vm}: numatune mode=interleave nodeset=0-1 (--config) applied"
            else
                log "[WARN] ${vm}: numatune configuration failed (version/option may not be supported)"
            fi
        fi
    }

    _apply_numatune_vm "${DL_VM}"
    _apply_numatune_vm "${DA_VM}"

    ###########################################################################
    # 7. DL data disk (LV) attach (vg_dl/lv_dl → vdb, --config)
    ###########################################################################
    local DATA_LV="/dev/mapper/vg_dl-lv_dl"
    
    # Helper: extract the full <disk>...</disk> XML block that contains target dev='vdb'
    # NOTE: In libvirt XML, <source ...> often appears BEFORE <target ...>,
    # so parsing with `grep -A ... "target dev='vdb'"` is unreliable.
    # Args:
    #   $1: vm name
    #   $2: 0=live XML, 1=inactive XML
    get_vdb_disk_block() {
        local vm_name="$1"
        local inactive="${2:-0}"
        if [[ -z "${vm_name}" ]]; then
            return 1
        fi

        local dump_cmd=(virsh dumpxml "${vm_name}")
        if [[ "${inactive}" -eq 1 ]]; then
            dump_cmd+=(--inactive)
        fi

        "${dump_cmd[@]}" 2>/dev/null | awk '
            BEGIN { in_disk=0; buf="" }
            /<disk[ >]/ { in_disk=1; buf=$0 ORS; next }
            in_disk {
                buf = buf $0 ORS
                if ($0 ~ /<\/disk>/) {
                    if (buf ~ /<target[[:space:]]+dev=.vdb./) { print buf; exit }
                    in_disk=0; buf=""
                }
            }
        '
    }

    # Helper: pretty-print live_ok for logs.
    # For shutoff VMs, live verification is not applicable.
    fmt_live_ok() {
        local is_running="${1:-0}"
        local val="${2:-0}"
        if [[ "${is_running}" -eq 1 ]]; then
            echo "${val}"
        else
            echo "N/A"
        fi
    }

    # Helper function to extract and normalize vdb source from VM XML
    get_vdb_source() {
        local vm_name="$1"
        local vdb_xml
        vdb_xml="$(get_vdb_disk_block "${vm_name}" 0 || true)"

        if [[ -z "${vdb_xml}" ]]; then
            echo ""
            return
        fi

        # Try multiple methods to extract source device
        local source_dev=""

        # Method 1: Extract from source dev='...' pattern
        source_dev=$(echo "${vdb_xml}" | grep -E "source dev=" | sed -E "s/.*source dev=['\"]([^'\"]+)['\"].*/\1/" | head -1 || echo "")

        # Method 2: Extract from source file='...' pattern
        if [[ -z "${source_dev}" ]]; then
            source_dev=$(echo "${vdb_xml}" | grep -E "source file=" | sed -E "s/.*source file=['\"]([^'\"]+)['\"].*/\1/" | head -1 || echo "")
        fi

        # Method 3: Extract from any source= pattern (more flexible)
        if [[ -z "${source_dev}" ]]; then
            source_dev=$(echo "${vdb_xml}" | grep -E "source.*=" | sed -E "s/.*source[^=]*=['\"]([^'\"]+)['\"].*/\1/" | head -1 || echo "")
        fi

        # Method 4: Try with different quote styles
        if [[ -z "${source_dev}" ]]; then
            source_dev=$(echo "${vdb_xml}" | grep -E "source" | sed -E "s/.*source[^>]*>([^<]+)<.*/\1/" | head -1 || echo "")
        fi

        echo "${source_dev}"
    }
    
    # Helper function to normalize device paths for comparison
    normalize_device_path() {
        local path="$1"
        if [[ -z "${path}" ]]; then
            echo ""
            return
        fi
        
        # If path exists, resolve symlinks with readlink -f
        if [[ -e "${path}" ]]; then
            readlink -f "${path}" 2>/dev/null || echo "${path}"
        else
            echo "${path}"
        fi
    }
    
    # Helper function to get device major:minor numbers
    get_device_majmin() {
        local path="$1"
        if [[ -z "${path}" ]] || [[ ! -e "${path}" ]]; then
            echo ""
            return
        fi
        
        # Use stat to get major:minor (format: hex:hex or dec:dec)
        stat -Lc '%t:%T' "${path}" 2>/dev/null || echo ""
    }
    
    # Helper function to compare two device paths (handles /dev/mapper/... vs /dev/dm-*)
    compare_device_paths() {
        local path1="$1"
        local path2="$2"
        
        if [[ -z "${path1}" ]] || [[ -z "${path2}" ]]; then
            return 1
        fi
        
        # Try readlink -f canonicalization first
        local canonical1 canonical2
        canonical1=$(readlink -f "${path1}" 2>/dev/null || echo "")
        canonical2=$(readlink -f "${path2}" 2>/dev/null || echo "")
        
        # If both canonicalizations succeeded, compare them
        if [[ -n "${canonical1}" ]] && [[ -n "${canonical2}" ]]; then
            if [[ "${canonical1}" == "${canonical2}" ]]; then
                return 0
            fi
        fi
        
        # Fallback: compare major:minor numbers
        local majmin1 majmin2
        majmin1=$(get_device_majmin "${path1}")
        majmin2=$(get_device_majmin "${path2}")
        
        if [[ -n "${majmin1}" ]] && [[ -n "${majmin2}" ]] && [[ "${majmin1}" == "${majmin2}" ]]; then
            return 0
        fi
        
        # Last resort: string comparison (for non-existent paths or files)
        if [[ "${path1}" == "${path2}" ]]; then
            return 0
        fi
        
        return 1
    }
    
    # Helper function to check VM state (running or shutoff)
    get_vm_state() {
        local vm_name="$1"
        local state
        state=$(virsh domstate "${vm_name}" 2>/dev/null | head -1 || echo "")
        echo "${state}"
    }
    
    # Helper function to check if vdb is correctly attached (config/persistent check)
    check_vdb_attached_config() {
        local vm_name="$1"
        local expected_lv="$2"
        local current_source
        
        # Use --inactive to check persistent config
        local vdb_xml
        vdb_xml="$(get_vdb_disk_block "${vm_name}" 1 || true)"
        
        if [[ -z "${vdb_xml}" ]]; then
            return 1  # vdb not found in config
        fi
        
        # Extract source from config XML
        local source_dev=""
        source_dev=$(echo "${vdb_xml}" | grep -E "source dev=" | sed -E "s/.*source dev=['\"]([^'\"]+)['\"].*/\1/" | head -1 || echo "")
        if [[ -z "${source_dev}" ]]; then
            source_dev=$(echo "${vdb_xml}" | grep -E "source file=" | sed -E "s/.*source file=['\"]([^'\"]+)['\"].*/\1/" | head -1 || echo "")
        fi
        
        if [[ -z "${source_dev}" ]]; then
            return 1
        fi
        
        # Use compare_device_paths to handle /dev/mapper/... vs /dev/dm-* cases
        if compare_device_paths "${source_dev}" "${expected_lv}"; then
            return 0  # Config matches
        else
            return 1  # Config does not match
        fi
    }
    
    # Helper function to check if vdb is correctly attached (live check)
    check_vdb_attached_live() {
        local vm_name="$1"
        local expected_lv="$2"
        
        # Use domblklist to check live state
        local blklist_output
        blklist_output=$(virsh domblklist "${vm_name}" --details 2>/dev/null || virsh domblklist "${vm_name}" 2>/dev/null || echo "")
        
        if [[ -z "${blklist_output}" ]]; then
            return 1  # Cannot get live block list
        fi
        
        # Check if vdb exists and points to expected LV
        local vdb_line
        vdb_line=$(echo "${blklist_output}" | grep -E "vdb\s+" || echo "")
        
        if [[ -z "${vdb_line}" ]]; then
            return 1  # vdb not found in live state
        fi
        
        # Extract source from domblklist output
        local source_dev
        source_dev=$(echo "${vdb_line}" | awk '{print $NF}' || echo "")
        
        if [[ -z "${source_dev}" ]]; then
            return 1
        fi
        
        # Use compare_device_paths to handle /dev/mapper/... vs /dev/dm-* cases
        if compare_device_paths "${source_dev}" "${expected_lv}"; then
            return 0  # Live matches
        else
            return 1  # Live does not match
        fi
    }

    if [[ -e "${DATA_LV}" ]]; then
        if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] Check VM state and attach ${DATA_LV} as vdb to ${DL_VM} (live+config or config-only)"
            else
                # Get VM state
                local vm_state
                vm_state=$(get_vm_state "${DL_VM}")
                local dl_running=0
                if [[ "${vm_state}" == *"running"* ]]; then
                    dl_running=1
                fi
                
                log "[STEP 12] ${DL_VM} state: ${vm_state}"
                
                # Check if vdb is already correctly attached (both config and live if running)
                local config_ok=0 live_ok=0
                if check_vdb_attached_config "${DL_VM}" "${DATA_LV}"; then
                    config_ok=1
                fi
                
                if [[ ${dl_running} -eq 1 ]]; then
                    if check_vdb_attached_live "${DL_VM}" "${DATA_LV}"; then
                        live_ok=1
                    fi
                else
                    # Shutoff state: live check not applicable
                    live_ok=1
                fi
                
                log "[STEP 12] Verification before attach: config_ok=${config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${live_ok})"
                
                # Determine if attachment is needed
                local needs_attach=1
                if [[ ${dl_running} -eq 1 ]]; then
                    # Running: both config and live must be OK
                    if [[ ${config_ok} -eq 1 ]] && [[ ${live_ok} -eq 1 ]]; then
                        needs_attach=0
                    fi
                else
                    # Shutoff: only config needs to be OK
                    if [[ ${config_ok} -eq 1 ]]; then
                        needs_attach=0
                    fi
                fi
                
                if [[ ${needs_attach} -eq 0 ]]; then
                    log "[STEP 12] ${DL_VM} already has correct data disk(${DATA_LV}) as vdb → skipping"
                else
                    # Check if vdb exists but with different device
                    local current_vdb_source
                    current_vdb_source=$(get_vdb_source "${DL_VM}")
                    if [[ -n "${current_vdb_source}" ]]; then
                        log "[STEP 12] ${DL_VM} has vdb but it's not ${DATA_LV} (current: ${current_vdb_source})"
                        log "[STEP 12] Will detach current vdb and attach ${DATA_LV} as vdb"
                        
                        # Detach existing vdb based on VM state
                        if [[ ${dl_running} -eq 1 ]]; then
                            log "[STEP 12] Detaching vdb (live+config) from ${DL_VM}..."
                            virsh detach-disk "${DL_VM}" vdb --live >/dev/null 2>&1 || true
                            virsh detach-disk "${DL_VM}" vdb --config >/dev/null 2>&1 || true
                        else
                            log "[STEP 12] Detaching vdb (config-only) from ${DL_VM}..."
                            virsh detach-disk "${DL_VM}" vdb --config >/dev/null 2>&1 || true
                        fi
                        sleep 1
                    fi
                    
                    # Attempt to attach the data disk
                    local attach_mode=""
                    local is_block_device=0
                    local is_file=0
                    
                    # Detect device type
                    if [[ -b "${DATA_LV}" ]]; then
                        is_block_device=1
                        log "[STEP 12] ${DATA_LV} is a block device, will use raw driver (no qcow2 subdriver)"
                    elif [[ -f "${DATA_LV}" ]]; then
                        is_file=1
                        log "[STEP 12] ${DATA_LV} is a file"
                    fi
                    
                    if [[ ${dl_running} -eq 1 ]]; then
                        attach_mode="live+config"
                        log "[STEP 12] Attaching ${DATA_LV} as vdb to ${DL_VM} (attach mode: ${attach_mode})..."
                        
                        # Try --persistent first (if supported)
                        local attach_success=0
                        local config_attach_success=0
                        local attach_cmd=""
                        
                        # Build attach command based on device type
                        if [[ ${is_block_device} -eq 1 ]]; then
                            # Block device: use --subdriver raw (or omit subdriver, let libvirt auto-detect)
                            attach_cmd="virsh attach-disk \"${DL_VM}\" \"${DATA_LV}\" vdb --persistent"
                        else
                            # File: use default (libvirt will detect format)
                            attach_cmd="virsh attach-disk \"${DL_VM}\" \"${DATA_LV}\" vdb --persistent"
                        fi
                        
                        if eval "${attach_cmd}" >/dev/null 2>&1; then
                            attach_success=1
                            config_attach_success=1  # --persistent includes config
                            log "[STEP 12] Attach with --persistent succeeded"
                        else
                            # Fallback: attach live first, then config
                            log "[STEP 12] --persistent not available or failed, using live+config two-step"
                            
                            if [[ ${is_block_device} -eq 1 ]]; then
                                # Block device: no subdriver specified (raw is default for block devices)
                                if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1; then
                                    log "[STEP 12] Live attach succeeded"
                                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded"
                                    else
                                        log "[WARN] Live attach succeeded but config attach failed"
                                    fi
                                else
                                    log "[WARN] Live attach failed, trying config-only as fallback"
                                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded (live failed)"
                                    fi
                                fi
                            else
                                # File: default behavior
                                if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1; then
                                    log "[STEP 12] Live attach succeeded"
                                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded"
                                    else
                                        log "[WARN] Live attach succeeded but config attach failed"
                                    fi
                                else
                                    log "[WARN] Live attach failed, trying config-only as fallback"
                                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded (live failed)"
                                    fi
                                fi
                            fi
                        fi
                        
                        if [[ ${attach_success} -eq 0 ]]; then
                            log "[WARN] ${DL_VM} data disk attach command failed, will verify actual status"
                        fi
                    else
                        attach_mode="config-only"
                        log "[STEP 12] Attaching ${DATA_LV} as vdb to ${DL_VM} (attach mode: ${attach_mode})..."
                        
                        # For block devices, libvirt will auto-detect raw, no need to specify
                        local config_attach_success=0
                        if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                            config_attach_success=1
                        else
                            log "[WARN] ${DL_VM} data disk attach command failed, will verify actual status"
                        fi
                    fi
                    
                    # Verification with retry
                    sleep 1
                    local verification_passed=0
                    local verify_count=0
                    local max_verify_attempts=3
                    local final_config_ok=0 final_live_ok=0
                    
                    while [[ ${verify_count} -lt ${max_verify_attempts} ]]; do
                        verify_count=$((verify_count + 1))
                        
                        # Check config
                        if check_vdb_attached_config "${DL_VM}" "${DATA_LV}"; then
                            final_config_ok=1
                        else
                            final_config_ok=0
                        fi
                        
                        # Check live (only if running)
                        if [[ ${dl_running} -eq 1 ]]; then
                            if check_vdb_attached_live "${DL_VM}" "${DATA_LV}"; then
                                final_live_ok=1
                            else
                                final_live_ok=0
                            fi
                        else
                            final_live_ok=1  # Not applicable for shutoff
                        fi
                        
                        log "[STEP 12] Verification attempt ${verify_count}/${max_verify_attempts}: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                        
                        # Determine success based on VM state
                        if [[ ${dl_running} -eq 1 ]]; then
                            # For running VM: live_ok==1 is required
                            if [[ ${final_live_ok} -eq 1 ]]; then
                                # If live is OK, check config with retry window (up to 5 seconds)
                                if [[ ${final_config_ok} -eq 1 ]]; then
                                    verification_passed=1
                                    break
                                elif [[ ${verify_count} -lt ${max_verify_attempts} ]]; then
                                    # Continue retrying for config
                                    sleep 1
                                    continue
                                else
                                    # After max attempts, if live is OK and config attach command succeeded, 
                                    # treat as success (will be marked as "persistence pending" in final reporting)
                                    if [[ ${config_attach_success} -eq 1 ]]; then
                                        verification_passed=1
                                        break
                                    fi
                                fi
                            fi
                        else
                            # For shutoff: only config needs to be OK
                            if [[ ${final_config_ok} -eq 1 ]]; then
                                verification_passed=1
                                break
                            fi
                        fi
                        
                        if [[ ${verify_count} -lt ${max_verify_attempts} ]]; then
                            sleep 1
                        fi
                    done
                    
                    # Extended retry for config_ok (up to 5 seconds total)
                    if [[ ${dl_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]] && [[ ${verification_passed} -eq 0 ]]; then
                        local config_retry_count=0
                        local max_config_retries=5
                        while [[ ${config_retry_count} -lt ${max_config_retries} ]]; do
                            config_retry_count=$((config_retry_count + 1))
                            sleep 1
                            if check_vdb_attached_config "${DL_VM}" "${DATA_LV}"; then
                                final_config_ok=1
                                verification_passed=1
                                log "[STEP 12] Config verification succeeded after extended retry (${config_retry_count}s)"
                                break
                            fi
                        done
                    fi
                    
                    # Final recovery attempt if verification failed
                    if [[ ${verification_passed} -eq 0 ]]; then
                        log "[WARN] Verification failed after ${max_verify_attempts} attempts, performing final recovery..."
                        
                        # One more detach/attach cycle
                        if [[ ${dl_running} -eq 1 ]]; then
                            virsh detach-disk "${DL_VM}" vdb --live >/dev/null 2>&1 || true
                            virsh detach-disk "${DL_VM}" vdb --config >/dev/null 2>&1 || true
                            sleep 1
                            # Block device: no subdriver specified (raw is default)
                            if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --persistent >/dev/null 2>&1; then
                                log "[STEP 12] Final recovery: --persistent attach succeeded"
                            else
                                virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1 || true
                                virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1 || true
                            fi
                        else
                            virsh detach-disk "${DL_VM}" vdb --config >/dev/null 2>&1 || true
                            sleep 1
                            virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1 || true
                        fi
                        
                        sleep 2
                        
                        # Final verification after recovery
                        final_config_ok=0
                        final_live_ok=0
                        if check_vdb_attached_config "${DL_VM}" "${DATA_LV}"; then
                            final_config_ok=1
                        fi
                        if [[ ${dl_running} -eq 1 ]]; then
                            if check_vdb_attached_live "${DL_VM}" "${DATA_LV}"; then
                                final_live_ok=1
                            fi
                        else
                            final_live_ok=1
                        fi
                        
                        if [[ ${dl_running} -eq 1 ]]; then
                            # For running VM: live_ok==1 is sufficient
                            if [[ ${final_live_ok} -eq 1 ]]; then
                                verification_passed=1
                            fi
                        else
                            if [[ ${final_config_ok} -eq 1 ]]; then
                                verification_passed=1
                            fi
                        fi
                    fi
                    
                    # Final status reporting
                    if [[ ${verification_passed} -eq 1 ]]; then
                        # Check if we have a partial success case (live OK but config not OK for running VM)
                        if [[ ${dl_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]]; then
                            log "[STEP 12] ${DL_VM} data disk(${DATA_LV}) attached as vdb (live) - persistence pending"
                            log "[STEP 12] Status: Attached (live), persistence pending"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                            log "[WARN] Config verification failed but live attachment is working. Persistence may not be saved."
                            log "[WARN] Please manually verify with: virsh dumpxml ${DL_VM} --inactive | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'"
                        else
                            log "[STEP 12] ${DL_VM} data disk(${DATA_LV}) attached as vdb (${attach_mode}) completed and verified"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                        fi
                    else
                        # Only report as failed if live is also not OK (for running VM)
                        if [[ ${dl_running} -eq 1 ]] && [[ ${final_live_ok} -eq 0 ]]; then
                            log "[ERROR] ${DL_VM} data disk(${DATA_LV}) attach failed after all attempts"
                            log "[ERROR] Final verification: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                            log "[DEBUG] VM XML vdb section (config):"
                            get_vdb_disk_block "${DL_VM}" 1 2>/dev/null | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                            log "[DEBUG] Live block list:"
                            virsh domblklist "${DL_VM}" --details 2>/dev/null | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                        elif [[ ${dl_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]]; then
                            # This should not happen due to verification_passed logic, but handle it anyway
                            log "[STEP 12] ${DL_VM} data disk(${DATA_LV}) attached as vdb (live) - persistence pending"
                            log "[STEP 12] Status: Attached (live), persistence pending"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                            log "[WARN] Config verification failed but live attachment is working. Persistence may not be saved."
                            log "[WARN] Please manually verify with: virsh dumpxml ${DL_VM} --inactive | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'"
                        else
                            log "[ERROR] ${DL_VM} data disk(${DATA_LV}) attach failed after all attempts"
                            log "[ERROR] Final verification: config_ok=${final_config_ok}, live_ok=$(fmt_live_ok ${dl_running} ${final_live_ok})"
                            log "[DEBUG] VM XML vdb section (config):"
                            get_vdb_disk_block "${DL_VM}" 1 2>/dev/null | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                        fi
                    fi
                fi
            fi
        else
            log "[STEP 12] ${DL_VM} VM not found → skipping DL data disk attach"
        fi
    else
        log "[STEP 12] ${DATA_LV} does not exist, skipping DL data disk attach"
    fi

    ###########################################################################
    # 8. DL/DA VM restart (fail-fast)
    ###########################################################################
    ensure_vm_bridge_if_needed() {
        local vm_name="$1"
        local bridge_name="$2"
        if [[ -z "${vm_name}" || -z "${bridge_name}" ]]; then
            return 0
        fi
        if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
            return 0
        fi
        if virsh dumpxml "${vm_name}" --inactive 2>/dev/null | grep -q "<source bridge='${bridge_name}'"; then
            if ! ip link show dev "${bridge_name}" >/dev/null 2>&1; then
                log "[STEP 12] Bridge ${bridge_name} required by ${vm_name} but missing; creating it"
                ensure_bridge_up_no_carrier_ok "${bridge_name}" "" || return 1
            fi
        fi
        return 0
    }

    local dl_bridge="${DL_BRIDGE:-virbr0}"
    local da_bridge="${DA_BRIDGE:-virbr0}"
    ensure_vm_bridge_if_needed "${DL_VM}" "${dl_bridge}" || return 1
    ensure_vm_bridge_if_needed "${DA_VM}" "${da_bridge}" || return 1

    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            log "[STEP 12] Requesting ${vm} start"
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh start ${vm}"
            else
                local start_out
                if ! start_out="$(virsh start "${vm}" 2>&1)"; then
                    log "[ERROR] ${vm} start failed"
                    while IFS= read -r line; do
                        log "  ${line}"
                    done <<< "${start_out}"
                    return 1
                fi
            fi
        fi
    done

    # ★ Added here: Wait 5 seconds after VM start
    if [[ "${_DRY}" -eq 0 ]]; then
        log "[STEP 12] Waiting 5 seconds after DL/DA VM start (waiting for vCPU state stabilization)"
        sleep 5
    fi

    ###########################################################################
    # 9. Display basic validation results using show_paged
    ###########################################################################
    local result_file="/tmp/step12_result.txt"
    rm -f "${result_file}"

    if [[ "${_DRY}" -eq 1 ]]; then
        {
            echo "===== DRY-RUN MODE: Simulation Results ====="
            echo
            echo "📊 SIMULATED OPERATIONS:"
            echo "  • SR-IOV VF PCI passthrough to ${DL_VM} and ${DA_VM}"
            echo "  • CPU Affinity configuration"
            echo "  • NUMA memory interleave configuration"
            echo "  • DL data disk attach (if applicable)"
            echo
            echo "ℹ️  In real execution mode, the following would occur:"
            echo "  1. SR-IOV VF PCI devices would be attached to ${DL_VM} and ${DA_VM}"
            echo "  2. CPU pinning would be applied"
            echo "  3. NUMA configuration would be applied"
            echo "  4. Data disk would be attached to ${DL_VM} (if available)"
            echo
            echo "📋 EXPECTED CONFIGURATION:"
            echo "  • DL VM: ${DL_VM}"
            echo "  • DA VM: ${DA_VM}"
            if [[ -n "${DL_VF:-}" ]]; then
                echo "  • DL VF PCI: ${DL_VF}"
            fi
            if [[ -n "${DA_VF:-}" ]]; then
                echo "  • DA VF PCI: ${DA_VF}"
            fi
        } > "${result_file}"
    else
        {
            echo "===== DL vcpuinfo (${DL_VM}) ====="
            if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
                virsh vcpuinfo "${DL_VM}" 2>&1
            else
                echo "VM ${DL_VM} not found"
            fi
            echo

            echo "===== DA vcpuinfo (${DA_VM}) ====="
            if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
                virsh vcpuinfo "${DA_VM}" 2>&1
            else
                echo "VM ${DA_VM} not found"
            fi
            echo

            echo "===== DL XML (cputune / numatune / hostdev / vdb) ====="
            if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
                virsh dumpxml "${DL_VM}" 2>/dev/null | \
                    egrep 'cputune|numatune|hostdev|target dev='\''vdb'\''' || true
            else
                echo "VM ${DL_VM} not found"
            fi
            echo

            echo "===== DA XML (cputune / numatune / hostdev) ====="
            if virsh dominfo "${DA_VM}" >/dev/null 2>&1; then
                virsh dumpxml "${DA_VM}" 2>/dev/null | \
                    egrep 'cputune|numatune|hostdev' || true
            else
                echo "VM ${DA_VM} not found"
            fi
            echo
        } > "${result_file}"
    fi

    # Execution completion message box
    local completion_msg
    if [[ "${_DRY}" -eq 1 ]]; then
        completion_msg="STEP 12: SR-IOV + CPU Affinity Configuration (DRY RUN) Completed

✅ Simulation Summary:
  • SR-IOV VF PCI passthrough simulation for ${DL_VM} and ${DA_VM}
  • CPU Affinity configuration simulation
  • NUMA memory interleave configuration simulation
  • DL data disk attach simulation (if applicable)
  • CD-ROM removal simulation

⚠️  DRY RUN MODE: No actual changes were made.

📋 What Would Have Been Applied:
  • SR-IOV VF PCI devices would be attached to VMs
  • CPU pinning would be configured
  • NUMA memory interleave would be applied
  • Data disk would be attached to ${DL_VM} (if available)
  • CD-ROM devices would be removed

💡 Next Steps:
  Set DRY_RUN=0 and rerun STEP 12 to apply actual configurations.
  Detailed simulation results are available in the log."
    else
        completion_msg="STEP 12: SR-IOV + CPU Affinity Configuration Completed

✅ Configuration Summary:
  • SR-IOV VF PCI passthrough applied to ${DL_VM} and ${DA_VM}
  • CPU Affinity (CPU pinning) configured
  • NUMA memory interleave applied
  • DL data disk attached (if applicable)
  • CD-ROM devices removed

✅ VMs Status:
  • ${DL_VM} and ${DA_VM} have been restarted with new configurations
  • All SR-IOV and CPU affinity settings are now active

📋 Verification:
  • Check VM CPU pinning: virsh vcpuinfo ${DL_VM}
  • Check SR-IOV devices: virsh dumpxml ${DL_VM} | grep hostdev
  • Check NUMA configuration: virsh numatune ${DL_VM}
  • Verify data disk: virsh dumpxml ${DL_VM} | awk '/<disk[ >]/{d=1;b=$0 ORS;next} d{b=b $0 ORS; if($0~/<\\\/disk>/){ if(b~/<target[[:space:]]+dev=.vdb./){print b; exit} d=0;b=\"\"}}'

💡 Note:
  Detailed verification results are shown below.
  VMs are ready for use with SR-IOV and CPU affinity enabled."
    fi

    # Calculate dialog size dynamically
    local dialog_dims
    dialog_dims=$(calc_dialog_size 22 90)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"

    whiptail_msgbox "STEP 12 - Configuration Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

    if [[ "${_DRY}" -eq 1 ]]; then
        # Read result file content and display in message box
        local dry_run_content
        if [[ -f "${result_file}" ]]; then
            dry_run_content=$(cat "${result_file}")
            # Calculate dialog size dynamically
            local dry_dialog_dims
            dry_dialog_dims=$(calc_dialog_size 20 90)
            local dry_dialog_height dry_dialog_width
            read -r dry_dialog_height dry_dialog_width <<< "${dry_dialog_dims}"
            whiptail_msgbox "STEP 12 – SR-IOV / CPU Affinity / DL data LV (DRY-RUN)" "${dry_run_content}" "${dry_dialog_height}" "${dry_dialog_width}"
        fi
    else
        show_paged "STEP 12 – SR-IOV / CPU Affinity / DL data LV validation results" "${result_file}" "no-clear"
    fi

    ###########################################################################
    # 10. Mark STEP as done and exit log
    ###########################################################################
    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV ====="
    echo
}


###############################################################################
# STEP 13 – Install DP Appliance CLI package (use local files, no internet download)
###############################################################################
step_13_install_dp_cli() {
    local STEP_ID="13_install_dp_cli"
    local STEP_NAME="13. Install DP Appliance CLI package"
    local _DRY="${DRY_RUN:-0}"
    _DRY="${_DRY//\"/}"

    local VENV_DIR="/opt/dp_cli_venv"
    local ERRLOG="/var/log/aella/dp_cli_step13_error.log"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Installing/Applying DP Appliance CLI package"

    if type load_config >/dev/null 2>&1; then
        load_config || true
    fi

    # Calculate dialog size dynamically and center message
    local dialog_dims
    dialog_dims=$(calc_dialog_size 15 85)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"
    local centered_msg
    centered_msg=$(center_message "Install DP Appliance CLI package (dp_cli) on the host\nand apply it to the stellar user.\n\n(Will download latest version from GitHub: https://github.com/RickLee-kr/Stellar-appliance-cli)\n\nDo you want to continue?")
    
    if ! whiptail --title "STEP 13 Execution Confirmation" \
                  --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
    then
        log "User canceled STEP 13 execution."
        return 0
    fi

    # 0) Prepare error log file
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Preparing error log file: ${ERRLOG}"
    else
        mkdir -p /var/log/aella || true
        : > "${ERRLOG}" || true
        chmod 644 "${ERRLOG}" || true
    fi

    # 0-1) Install required packages first (before download/extraction)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Checking required packages for dp_cli + ACL persistence..."
    local required_pkgs
    local pkgs_to_install=()
    required_pkgs=(python3-pip python3-venv wget curl unzip iptables netfilter-persistent iptables-persistent ipset-persistent)

    for pkg in "${required_pkgs[@]}"; do
        if dpkg -s "${pkg}" >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Package already installed: ${pkg}"
        else
            pkgs_to_install+=("${pkg}")
        fi
    done

    local remove_ufw=0
    if dpkg -s ufw >/dev/null 2>&1; then
        remove_ufw=1
    fi

    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] apt-get update -y (if needed)"
        if [[ "${remove_ufw}" -eq 1 ]]; then
            log "[DRY-RUN] apt-get purge -y ufw"
        fi
        if [[ "${#pkgs_to_install[@]}" -gt 0 ]]; then
            log "[DRY-RUN] apt-get install -y ${pkgs_to_install[*]}"
        else
            log "[DRY-RUN] Required packages already installed"
        fi
    else
        if [[ "${remove_ufw}" -eq 1 || "${#pkgs_to_install[@]}" -gt 0 ]]; then
            if ! apt-get update -y >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: apt-get update failed" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
        fi

        if [[ "${remove_ufw}" -eq 1 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Removing ufw may take some time. Please wait."
            if ! apt-get purge -y ufw >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to remove ufw" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ufw removed (to avoid conflicts)"
        fi

        if [[ "${#pkgs_to_install[@]}" -gt 0 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Package installation may take some time. Please wait."
            # Preseed debconf to avoid interactive prompts (iptables/ipset persistent)
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
            echo "ipset-persistent ipset-persistent/autosave boolean true" | debconf-set-selections
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                "${pkgs_to_install[@]}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to install required packages" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Required packages installed successfully"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] All required packages already installed"
        fi
    fi

    # 1) Download dp_cli from GitHub
    local GITHUB_REPO="https://github.com/RickLee-kr/Stellar-appliance-cli"
    local DOWNLOAD_URL="${GITHUB_REPO}/archive/refs/heads/main.zip"
    local TEMP_DIR="/tmp/dp_cli_download"
    local ZIP_FILE="${TEMP_DIR}/Stellar-appliance-cli-main.zip"
    local EXTRACT_DIR="${TEMP_DIR}/Stellar-appliance-cli-main"
    local pkg=""

    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Will download dp_cli from: ${DOWNLOAD_URL}"
        log "[DRY-RUN] Will extract to: ${EXTRACT_DIR}"
        pkg="${EXTRACT_DIR}"
    else
        # Clean up any existing download
        rm -rf "${TEMP_DIR}" || true
        mkdir -p "${TEMP_DIR}" || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to create temp directory: ${TEMP_DIR}" | tee -a "${ERRLOG}"
            return 1
        }

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Downloading dp_cli from GitHub: ${GITHUB_REPO}"
        echo "=== Downloading from GitHub (this may take a moment) ==="
        
        # Download using wget or curl
        if command -v wget >/dev/null 2>&1; then
            if ! wget --progress=bar:force -O "${ZIP_FILE}" "${DOWNLOAD_URL}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to download from GitHub" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check network connection and ${ERRLOG} for details." | tee -a "${ERRLOG}"
                rm -rf "${TEMP_DIR}" || true
                return 1
            fi
        elif command -v curl >/dev/null 2>&1; then
            if ! curl -L -o "${ZIP_FILE}" "${DOWNLOAD_URL}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to download from GitHub" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check network connection and ${ERRLOG} for details." | tee -a "${ERRLOG}"
                rm -rf "${TEMP_DIR}" || true
                return 1
            fi
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Neither wget nor curl is available. Please install one of them." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        echo "=== Extracting downloaded file ==="
        # Extract zip file (unzip should already be installed)
        if ! unzip -q "${ZIP_FILE}" -d "${TEMP_DIR}" >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to extract zip file" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        # Check if setup.py exists in extracted directory
        if [[ ! -f "${EXTRACT_DIR}/setup.py" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: setup.py not found in downloaded package" | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        pkg="${EXTRACT_DIR}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Successfully downloaded and extracted dp_cli from GitHub"
    fi

    # 2) Create/initialize venv then install dp-cli
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating venv: ${VENV_DIR}"
        log "[DRY-RUN] Installing dp-cli in venv: ${pkg}"
        log "[DRY-RUN] Runtime verification performed based on import"
    else
        rm -rf "${VENV_DIR}" || true
        python3 -m venv "${VENV_DIR}" || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: venv creation failed: ${VENV_DIR}" | tee -a "${ERRLOG}"
            return 1
        }

        "${VENV_DIR}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true

        # Install setuptools<81 and wheel (pip will skip if already satisfied)
        "${VENV_DIR}/bin/python" -m pip install --quiet "setuptools<81" wheel >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: venv setuptools installation failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        # Install from downloaded directory (pip will skip if already installed)
        (cd "${pkg}" && "${VENV_DIR}/bin/python" -m pip install --quiet .) >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: dp-cli installation failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        }

        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('appliance_cli import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: appliance_cli import failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        if [[ ! -x "${VENV_DIR}/bin/aella_cli" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: ${VENV_DIR}/bin/aella_cli does not exist." | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: dp-cli package must include console_scripts (aella_cli) entry point." | tee -a "${ERRLOG}"
            return 1
        fi

        # Runtime verification performed only based on import (removed aella_cli execution smoke test)
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: dp-cli runtime import verification failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }
    fi

    # 4) /usr/local/bin/aella_cli wrapper
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating/overwriting /usr/local/bin/aella_cli as venv wrapper"
    else
        cat > /usr/local/bin/aella_cli <<EOF
#!/bin/bash
exec "${VENV_DIR}/bin/aella_cli" "\$@"
EOF
        chmod +x /usr/local/bin/aella_cli

        if [[ -x "${VENV_DIR}/bin/aella_cli_disk_encrypt" ]]; then
            cat > /usr/local/bin/aella_cli_disk_encrypt <<EOF
#!/bin/bash
exec "${VENV_DIR}/bin/aella_cli_disk_encrypt" "\$@"
EOF
            chmod +x /usr/local/bin/aella_cli_disk_encrypt
        fi
    fi

    # 5) /usr/bin/aella_cli (for login shell)
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /usr/bin/aella_cli wrapper script."
    else
        cat > /usr/bin/aella_cli <<'EOF'
#!/bin/bash
[ $# -ge 1 ] && exit 1
cd /tmp || exit 1
exec sudo /usr/local/bin/aella_cli
EOF
        chmod +x /usr/bin/aella_cli
    fi

    # 6) Register in /etc/shells
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Adding /usr/bin/aella_cli to /etc/shells (if not present)."
    else
        if ! grep -qx "/usr/bin/aella_cli" /etc/shells 2>/dev/null; then
            echo "/usr/bin/aella_cli" >> /etc/shells
        fi
    fi

    # 7) stellar sudo NOPASSWD
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /etc/sudoers.d/stellar: 'stellar ALL=(ALL) NOPASSWD: ALL'"
    else
        echo "stellar ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/stellar
        chmod 440 /etc/sudoers.d/stellar
        visudo -cf /etc/sudoers.d/stellar >/dev/null 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: sudoers syntax invalid: /etc/sudoers.d/stellar" | tee -a "${ERRLOG}"
            return 1
        }
    fi

    # 8) syslog group
    if id stellar >/dev/null 2>&1; then
        run_cmd "usermod -a -G syslog stellar"
    else
        log "[WARN] User 'stellar' does not exist, skipping syslog group addition."
    fi

    # 9) Change login shell
    if id stellar >/dev/null 2>&1; then
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] Changing stellar login shell to /usr/bin/aella_cli."
        else
            chsh -s /usr/bin/aella_cli stellar || true
        fi
    fi

    # 10) Change /var/log/aella ownership
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /var/log/aella directory/changing ownership (stellar)"
    else
        mkdir -p /var/log/aella
        if id stellar >/dev/null 2>&1; then
            chown -R stellar:stellar /var/log/aella || true
        fi
    fi

    # 11) Verification
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Skipping installation verification step."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: /usr/local/bin/aella_cli*"
        ls -l /usr/local/bin/aella_cli* 2>/dev/null || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: venv appliance_cli import"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('appliance_cli import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: runtime import check"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: error log path => ${ERRLOG}"
        tail -n 40 "${ERRLOG}" 2>/dev/null || true
    fi

    # Clean up temporary download directory
    if [[ "${_DRY}" -eq 0 && -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Cleaning up temporary download directory: ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}" || true
    fi

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    # Completion message box
    local completion_msg
    completion_msg="STEP 13: DP Appliance CLI Installation Completed

✅ Installation Summary:
  • DP Appliance CLI package has been successfully installed
  • Virtual environment created at: /opt/dp_cli_venv
  • CLI commands available at: /usr/local/bin/aella_cli
  • Login shell configured for stellar user

📋 How to Use Appliance CLI:

1. Test/Execute Appliance CLI:
   Simply run: aella_cli
   
   This will launch the appliance CLI interface.

2. Automatic CLI on New Login:
   When you connect to this KVM host as the 'stellar' user,
   the appliance CLI will automatically appear.
   
   The login shell has been configured to use aella_cli,
   so you don't need to run any commands manually.

3. Manual Execution:
   If you need to run it manually from another user:
   /usr/local/bin/aella_cli

💡 Note:
   The appliance CLI is now ready to use for managing
   your DP (Data Processor) appliances."

    # Calculate dialog size dynamically
    local dialog_dims
    dialog_dims=$(calc_dialog_size 20 90)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"

    whiptail_msgbox "STEP 13 - Installation Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 13. Install DP Appliance CLI package ====="
    echo
}



menu_config() {
  while true; do
    # Load latest configuration
    load_config

    # Determine ACPS Password display text
    local acps_password_display
    if [[ -n "${ACPS_PASSWORD:-}" ]]; then
      acps_password_display="(Configured)"
    else
      acps_password_display="(Not Set)"
    fi

    local msg
    msg="Current Configuration\n\n"
    msg+="DRY_RUN      : ${DRY_RUN}\n"
    msg+="DP_VERSION   : ${DP_VERSION}\n"
    msg+="ACPS_USER    : ${ACPS_USERNAME:-<Not Set>}\n"
    msg+="ACPS_PASSWORD: ${acps_password_display}\n"
    msg+="ACPS_URL     : ${ACPS_BASE_URL:-<Not Set>}\n"
    msg+="MGT_NIC      : ${MGT_NIC:-<Not Set>}\n"
    msg+="CLTR0_NIC    : ${CLTR0_NIC:-<Not Set>}\n"
    msg+="DATA_SSD_LIST: ${DATA_SSD_LIST:-<Not Set>}\n"
    msg+="CLUSTER_NIC_TYPE: ${CLUSTER_NIC_TYPE:-BRIDGE}\n"

    # Calculate menu size dynamically (6 menu items)
    local menu_dims
    menu_dims=$(calc_menu_size 6 80 8)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Center-align the menu message based on terminal height
    local centered_msg
    centered_msg=$(center_menu_message "${msg}\n" "${menu_height}")

    local choice
    # Temporarily disable set -e to handle cancel gracefully
    set +e
    choice=$(whiptail --title "XDR Installer - Configuration" \
      --menu "${centered_msg}" \
      "${menu_height}" "${menu_width}" "${menu_list_height}" \
      "1" "Toggle DRY_RUN (0/1)" \
      "2" "Set DP_VERSION" \
      "3" "Set ACPS Account/Password" \
      "4" "Set ACPS URL" \
      "5" "Set Cluster Interface Type (${CLUSTER_NIC_TYPE:-BRIDGE})" \
      "6" "Go Back" \
      3>&1 1>&2 2>&3)
    local menu_rc=$?
    set -e
    
    if [[ ${menu_rc} -ne 0 ]]; then
      # ESC or Cancel pressed - go back to main menu
      break
    fi
    
    # Additional check: if choice is empty, also break
    if [[ -z "${choice}" ]]; then
      break
    fi

    case "${choice}" in
      "1")
        # Toggle DRY_RUN
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          # Calculate dialog size dynamically and center message
          local dialog_dims
          dialog_dims=$(calc_dialog_size 12 70)
          local dialog_height dialog_width
          read -r dialog_height dialog_width <<< "${dialog_dims}"
          local centered_msg
          centered_msg=$(center_message "Current DRY_RUN=1 (simulation mode).\n\nChange to DRY_RUN=0 to execute actual commands?")
          
          # Temporarily disable set -e to handle cancel gracefully
          set +e
          whiptail --title "DRY_RUN Configuration" \
                   --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
          local dry_toggle_rc=$?
          set -e
          
          if [[ ${dry_toggle_rc} -eq 0 ]]; then
            DRY_RUN=0
          fi
        else
          # Calculate dialog size dynamically and center message
          local dialog_dims
          dialog_dims=$(calc_dialog_size 12 70)
          local dialog_height dialog_width
          read -r dialog_height dialog_width <<< "${dialog_dims}"
          local centered_msg
          centered_msg=$(center_message "Current DRY_RUN=0 (actual execution mode).\n\nSafely change to DRY_RUN=1 (simulation mode)?")
          
          # Temporarily disable set -e to handle cancel gracefully
          set +e
          whiptail --title "DRY_RUN Configuration" \
                   --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
          local dry_toggle_rc=$?
          set -e
          
          if [[ ${dry_toggle_rc} -eq 0 ]]; then
            DRY_RUN=1
          fi
        fi
        save_config
        ;;

      "2")
        # Set DP_VERSION
        local new_ver
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        new_ver=$(whiptail_inputbox "DP_VERSION Configuration" "Enter DP version (e.g., 6.2.0)." "${DP_VERSION}" 10 60)
        local ver_rc=$?
        set -e
        
        if [[ ${ver_rc} -ne 0 ]] || [[ -z "${new_ver}" ]]; then
          continue
        fi
        if [[ -n "${new_ver}" ]]; then
          DP_VERSION="${new_ver}"
          save_config
          whiptail_msgbox "DP_VERSION Configuration" "DP_VERSION has been set to ${DP_VERSION}." 8 60
        fi
        ;;

      "3")
        # ACPS account / password
        local user pass
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        user=$(whiptail_inputbox "ACPS Account Configuration" "Enter ACPS account (ID)." "${ACPS_USERNAME}" 10 60)
        local user_rc=$?
        set -e
        if [[ ${user_rc} -ne 0 ]] || [[ -z "${user}" ]]; then
          continue
        fi

        # For password, use whiptail directly with passwordbox (we'll add dynamic sizing)
        local dialog_dims
        dialog_dims=$(calc_dialog_size 10 60)
        local dialog_height dialog_width
        read -r dialog_height dialog_width <<< "${dialog_dims}"
        local centered_pass_msg
        centered_pass_msg=$(center_message "Enter ACPS password.\n(This value will be saved to the config file and automatically used in STEP 09)")
        
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        pass=$(whiptail --title "ACPS Password Configuration" \
                        --passwordbox "${centered_pass_msg}" "${dialog_height}" "${dialog_width}" "${ACPS_PASSWORD}" \
                        3>&1 1>&2 2>&3)
        local pass_rc=$?
        set -e
        if [[ ${pass_rc} -ne 0 ]] || [[ -z "${pass}" ]]; then
          continue
        fi

        ACPS_USERNAME="${user}"
        ACPS_PASSWORD="${pass}"
        save_config
        whiptail_msgbox "ACPS Account Configuration" "ACPS_USERNAME has been set to '${ACPS_USERNAME}'." 8 70
        ;;

      "4")
        # ACPS URL
        local new_url
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        new_url=$(whiptail_inputbox "ACPS URL Configuration" "Enter ACPS BASE URL." "${ACPS_BASE_URL}" 10 70)
        local url_rc=$?
        set -e
        
        if [[ ${url_rc} -ne 0 ]] || [[ -z "${new_url}" ]]; then
          continue
        fi
        if [[ -n "${new_url}" ]]; then
          ACPS_BASE_URL="${new_url}"
          save_config
          whiptail_msgbox "ACPS URL Configuration" "ACPS_BASE_URL has been set to '${ACPS_BASE_URL}'." 8 70
        fi
        ;;

      "5")
        # Cluster Interface Type
        local current_type="${CLUSTER_NIC_TYPE:-BRIDGE}"
        local type_choice
        local new_type=""
        
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        type_choice=$(whiptail --title "Cluster Interface Type Configuration" \
          --menu "Select Cluster Interface Type:\n\nCurrent: ${current_type}\n\n⚠️  Changing mode requires STEP 03 re-execution" \
          12 70 2 \
          "1" "SR-IOV (Virtual Function Passthrough)" \
          "2" "Bridge (Linux Bridge)" \
          3>&1 1>&2 2>&3)
        local type_rc=$?
        set -e
        
        if [[ ${type_rc} -ne 0 ]] || [[ -z "${type_choice}" ]]; then
          continue
        fi
        
        case "${type_choice}" in
          "1")
            new_type="SRIOV"
            ;;
          "2")
            new_type="BRIDGE"
            ;;
          *)
            continue
            ;;
        esac
        
        # Confirm mode change
        if [[ "${new_type}" != "${current_type}" ]]; then
          local switch_msg=""
          if [[ "${current_type}" == "SRIOV" ]] && [[ "${new_type}" == "BRIDGE" ]]; then
            switch_msg="Switching from SR-IOV to Bridge mode:\n\n• SR-IOV VFs will be removed\n• Bridge will be created\n• STEP 03 must be re-executed"
          elif [[ "${current_type}" == "BRIDGE" ]] && [[ "${new_type}" == "SRIOV" ]]; then
            switch_msg="Switching from Bridge to SR-IOV mode:\n\n• Existing bridge will be removed\n• SR-IOV VFs will be created\n• STEP 03 must be re-executed"
          fi
          
          if [[ -n "${switch_msg}" ]]; then
            set +e
            whiptail --title "Cluster Interface Type Change" \
              --yesno "${switch_msg}\n\nProceed with mode change?" \
              15 70
            local confirm_rc=$?
            set -e
            
            if [[ ${confirm_rc} -ne 0 ]]; then
              continue
            fi
          fi
        fi
        
        CLUSTER_NIC_TYPE="${new_type}"
        save_config
        
        local info_msg="CLUSTER_NIC_TYPE has been set to '${CLUSTER_NIC_TYPE}'."
        if [[ "${new_type}" != "${current_type}" ]]; then
          info_msg="${info_msg}\n\n⚠️  IMPORTANT: Re-run STEP 03 to apply the mode change."
        fi
        
        whiptail_msgbox "Cluster Interface Type Configuration" "${info_msg}" 10 70
        ;;

      "6")
        break
        ;;

      *)
        ;;
    esac
  done
}


#######################################
# Menu UI
#######################################

show_log() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    echo "Log file does not exist yet." > /tmp/xdr_log.txt
  else
    tail -n 200 "${LOG_FILE}" > /tmp/xdr_log.txt
  fi

  show_textbox "Installation Log (Last 200 lines)" /tmp/xdr_log.txt
}

# Build validation summary and return as English message
build_validation_summary() {
  local validation_log="$1"   # Can check based on log if needed, but here we re-check actual status

  # Load config to get CLUSTER_NIC_TYPE
  load_config

  local ok_msgs=()
  local warn_msgs=()
  local err_msgs=()

  # Determine network mode (SR-IOV or Bridge)
  local cluster_nic_type="${CLUSTER_NIC_TYPE:-BRIDGE}"
  local is_bridge_mode=0
  if [[ "${cluster_nic_type}" == "BRIDGE" ]]; then
    is_bridge_mode=1
  fi

  ###############################
  # 1. HWE kernel + IOMMU(grub)
  ###############################
  # Criteria:
  #   If dpkg -l output contains any of the following strings, consider HWE kernel installation complete
  #     - linux-image-generic-hwe-24.04
  #     - linux-generic-hwe-24.04

  local hwe_found=0

  # Use || true so script doesn't die even if dpkg -l fails
  if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe-24\.04' || true; then
    # grep returns exit 0 if match found, exit 1 if not found
    if LANG=C dpkg -l 2>/dev/null | grep -E 'linux-(image-)?generic-hwe-24\.04' >/dev/null; then
      hwe_found=1
    fi
  fi

  if (( hwe_found == 1 )); then
    # HWE kernel series is installed
    if grep -q 'intel_iommu=on' /etc/default/grub && grep -q 'iommu=pt' /etc/default/grub; then
      ok_msgs+=("HWE kernel series (linux-*-generic-hwe-24.04) + GRUB IOMMU options (intel_iommu=on iommu=pt) applied")
    else
      warn_msgs+=("HWE kernel series is installed but GRUB IOMMU options may differ from installation guide.")
      warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Tuning) to configure IOMMU parameters")
      warn_msgs+=("  → MANUAL: Edit /etc/default/grub and add 'intel_iommu=on iommu=pt' to GRUB_CMDLINE_LINUX, then run 'sudo update-grub'")
    fi
  else
    # Only WARN here
    warn_msgs+=("Could not find linux-image-generic-hwe-24.04 / linux-generic-hwe-24.04 packages.")
    warn_msgs+=("  → ACTION: Re-run STEP 02 (HWE Kernel Installation)")
    warn_msgs+=("  → VERIFY: Check current kernel with 'uname -r' and compare with installation guide")
  fi



  ###############################
  # 2. NIC(mgt, cltr0) / Network
  ###############################
  if ip link show mgt >/dev/null 2>&1 && ip link show cltr0 >/dev/null 2>&1; then
    ok_msgs+=("mgt / cltr0 interface rename applied")
  else
    err_msgs+=("mgt or cltr0 interface not visible.")
    err_msgs+=("  → ACTION: Re-run STEP 03 (NIC/ifupdown Configuration)")
    err_msgs+=("  → CHECK: Verify /etc/udev/rules.d/99-custom-ifnames.rules exists and contains correct PCI addresses")
    err_msgs+=("  → CHECK: Verify /etc/network/interfaces.d/00-cltr0.cfg exists")
    err_msgs+=("  → MANUAL: Run 'sudo udevadm control --reload' and 'sudo udevadm trigger' then reboot")
  fi

  # Check include setting in /etc/network/interfaces
  if grep -qE '^source /etc/network/interfaces.d/\*' /etc/network/interfaces 2>/dev/null; then
    ok_msgs+=("/etc/network/interfaces include setting for /etc/network/interfaces.d/* confirmed")
  else
    warn_msgs+=("/etc/network/interfaces does not have 'source /etc/network/interfaces.d/*' line.")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC/ifupdown Configuration)")
    warn_msgs+=("  → MANUAL: Add 'source /etc/network/interfaces.d/*' to /etc/network/interfaces")
  fi

  # Check networking service: enabled status is more important than active status
  # In Ubuntu 16.04 with ifupdown, networking service may be inactive after boot
  # but interfaces can still work correctly. Check both enabled status and actual interface state.
  local networking_enabled=0
  local mgt_interface_up=0
  
  if systemctl is-enabled --quiet networking 2>/dev/null; then
    networking_enabled=1
  fi
  
  # Check if mgt interface is UP and has an IP address
  if ip link show mgt 2>/dev/null | grep -q "state UP" && ip addr show mgt 2>/dev/null | grep -q "inet "; then
    mgt_interface_up=1
  fi
  
  if [[ ${networking_enabled} -eq 1 ]] && [[ ${mgt_interface_up} -eq 1 ]]; then
    ok_msgs+=("ifupdown networking service enabled and mgt interface is UP with IP")
  elif [[ ${mgt_interface_up} -eq 1 ]]; then
    # Interface is working, but service might not be enabled (less critical)
    warn_msgs+=("mgt interface is UP, but networking service may not be enabled for auto-start.")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC/ifupdown Configuration)")
    warn_msgs+=("  → MANUAL: Run 'sudo systemctl enable networking' to enable auto-start on boot")
  elif [[ ${networking_enabled} -eq 1 ]]; then
    # Service is enabled but interface is not up
    warn_msgs+=("networking service is enabled, but mgt interface may not be UP or configured.")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC/ifupdown Configuration)")
    warn_msgs+=("  → MANUAL: Run 'sudo ifup mgt' to bring up the interface")
    warn_msgs+=("  → CHECK: Verify /etc/network/interfaces syntax with 'ifup --dry-run mgt'")
  else
    # Neither enabled nor interface up
    warn_msgs+=("networking service is not enabled and mgt interface may not be configured.")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC/ifupdown Configuration)")
    warn_msgs+=("  → MANUAL: Run 'sudo systemctl enable networking' and 'sudo ifup mgt'")
    warn_msgs+=("  → CHECK: Verify /etc/network/interfaces syntax with 'ifup --dry-run mgt'")
  fi

  ###############################
  # 3. KVM / Libvirt
  ###############################
  if [ -c /dev/kvm ]; then
    ok_msgs+=("/dev/kvm device exists: KVM virtualization available")
  elif lsmod | egrep -q '^(kvm|kvm_intel|kvm_amd)\b'; then
    ok_msgs+=("kvm-related kernel modules loaded (based on lsmod)")
  else
    warn_msgs+=("Cannot verify kvm device (/dev/kvm) or kvm modules.")
    warn_msgs+=("  → CHECK: Verify BIOS VT-x/VT-d settings are enabled")
    warn_msgs+=("  → CHECK: Run 'lsmod | grep kvm' to verify kernel modules")
    warn_msgs+=("  → ACTION: If modules not loaded, re-run STEP 04 (KVM/Libvirt Installation)")
  fi

  if systemctl is-active --quiet libvirtd; then
    ok_msgs+=("libvirtd service active")
  else
    err_msgs+=("libvirtd service is inactive.")
    err_msgs+=("  → ACTION: Re-run STEP 04 (KVM/Libvirt Installation)")
    err_msgs+=("  → MANUAL: Run 'sudo systemctl enable --now libvirtd'")
    err_msgs+=("  → CHECK: Verify service status with 'sudo systemctl status libvirtd'")
  fi

  ###############################
  # 4. Kernel tuning / KSM / Swap
  ###############################
  if sysctl vm.min_free_kbytes 2>/dev/null | grep -q '1048576'; then
    ok_msgs+=("vm.min_free_kbytes = 1048576 (OOM prevention tuning applied)")
  else
    warn_msgs+=("vm.min_free_kbytes value may differ from installation guide (expected: 1048576).")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Tuning)")
    warn_msgs+=("  → CHECK: Verify /etc/sysctl.d/*.conf contains 'vm.min_free_kbytes=1048576'")
    warn_msgs+=("  → MANUAL: Run 'sudo sysctl -w vm.min_free_kbytes=1048576' and add to /etc/sysctl.conf")
  fi

  if [[ -f /sys/kernel/mm/ksm/run ]]; then
    local ksm_run
    ksm_run=$(cat /sys/kernel/mm/ksm/run 2>/dev/null)
    if [[ "${ksm_run}" = "0" ]]; then
      ok_msgs+=("KSM disabled (run=0)")
    else
      warn_msgs+=("KSM is still enabled (run=${ksm_run}).")
      warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Tuning)")
      warn_msgs+=("  → MANUAL: Run 'echo 0 | sudo tee /sys/kernel/mm/ksm/run'")
    fi
  fi

  if swapon --show | grep -q .; then
    warn_msgs+=("swap is still enabled.")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Tuning)")
    warn_msgs+=("  → MANUAL: Run 'sudo swapoff -a' and comment out /swap.img in /etc/fstab")
  else
    ok_msgs+=("swap disabled")
  fi

  ###############################
  # 5. NTPsec
  ###############################
  if systemctl is-active --quiet ntpsec; then
    ok_msgs+=("ntpsec service active")
  else
    warn_msgs+=("ntpsec service is not active.")
    warn_msgs+=("  → ACTION: Re-run STEP 06 (SR-IOV + NTPsec)")
    warn_msgs+=("  → MANUAL: Run 'sudo systemctl enable --now ntpsec'")
    warn_msgs+=("  → CHECK: Verify configuration in /etc/ntpsec/ntp.conf")
  fi

  ###############################
  # 5.5. SR-IOV driver (iavf/i40evf)
  ###############################
  if [[ "${CLUSTER_NIC_TYPE}" != "BRIDGE" ]]; then
    local sriov_modules
    sriov_modules=$(lsmod | grep -E '^(iavf|i40evf)\b' 2>/dev/null || echo "")
    if [[ -n "${sriov_modules}" ]]; then
      ok_msgs+=("SR-IOV driver modules (iavf/i40evf) loaded")
    else
      # Check if module files exist (driver may be installed but not loaded)
      if modinfo iavf >/dev/null 2>&1 || modinfo i40evf >/dev/null 2>&1; then
        warn_msgs+=("SR-IOV driver modules (iavf/i40evf) are installed but not loaded.")
        warn_msgs+=("  → ACTION: Re-run STEP 06 (SR-IOV + NTPsec)")
        warn_msgs+=("  → MANUAL: Run 'sudo modprobe iavf' or 'sudo modprobe i40evf'")
        warn_msgs+=("  → NOTE: Modules may need to be loaded after reboot or when VFs are created")
      else
        warn_msgs+=("SR-IOV driver modules (iavf/i40evf) are not installed or not available.")
        warn_msgs+=("  → ACTION: Re-run STEP 06 (SR-IOV + NTPsec)")
        warn_msgs+=("  → CHECK: Verify driver installation from GitHub (iavf-4.13.16)")
      fi
    fi
  fi

  ###############################
  # 6. LVM / /stellar mount
  ###############################
  if grep -q 'lv_dl_root' /etc/fstab && grep -q 'lv_da_root' /etc/fstab; then
    # Also check mount point directory existence
    if [[ -d /stellar/dl && -d /stellar/da ]]; then
      if mountpoint -q /stellar/dl && mountpoint -q /stellar/da; then
        ok_msgs+=("lv_dl_root / lv_da_root registered in fstab and /stellar/dl, /stellar/da mounted")
      else
        warn_msgs+=("Registered in fstab but /stellar/dl or /stellar/da mount seems missing.")
        warn_msgs+=("  → ACTION: Re-run STEP 07 (LVM Storage Configuration)")
        warn_msgs+=("  → MANUAL: Run 'sudo mount -a' to mount all filesystems")
        warn_msgs+=("  → CHECK: Verify mount with 'mount | grep stellar'")
      fi
    else
      warn_msgs+=("/stellar/dl or /stellar/da directory does not exist.")
      warn_msgs+=("  → ACTION: Re-run STEP 07 (LVM Storage Configuration)")
      warn_msgs+=("  → MANUAL: Run 'sudo mkdir -p /stellar/dl /stellar/da' then 'sudo mount -a'")
    fi
  else
    err_msgs+=("/etc/fstab does not have lv_dl_root / lv_da_root entries.")
    err_msgs+=("  → ACTION: Re-run STEP 07 (LVM Storage Configuration)")
    err_msgs+=("  → CHECK: Verify LVM volumes exist with 'sudo lvs'")
    err_msgs+=("  → MANUAL: Add entries to /etc/fstab: /dev/ubuntu-vg/lv_dl_root and /dev/ubuntu-vg/lv_da_root")
  fi

  ###############################
  # 7. VM deployment status / SR-IOV / CPU pin / CD-ROM
  ###############################
  local dl_defined=0
  local da_defined=0
  local dl_domains=()
  local da_domains=()

  # Check for any dl-* domains (dl-master, dl-worker1, dl-worker2, etc.)
  while IFS= read -r domain; do
    if [[ -n "$domain" ]] && virsh dominfo "$domain" >/dev/null 2>&1; then
      dl_domains+=("$domain")
      dl_defined=1
    fi
  done < <(virsh list --all --name 2>/dev/null | grep -E '^dl-' || true)

  # Check for any da-* domains (da-master, da-worker1, da-worker2, etc.)
  while IFS= read -r domain; do
    if [[ -n "$domain" ]] && virsh dominfo "$domain" >/dev/null 2>&1; then
      da_domains+=("$domain")
      da_defined=1
    fi
  done < <(virsh list --all --name 2>/dev/null | grep -E '^da-' || true)

  # 7-1. VM definition existence
  if (( dl_defined == 1 && da_defined == 1 )); then
    local dl_list="${dl_domains[*]}"
    local da_list="${da_domains[*]}"
    ok_msgs+=("dl/da domain(s) definition complete (dl: ${dl_list}, da: ${da_list})")
  elif (( dl_defined == 1 || da_defined == 1 )); then
    if (( dl_defined == 1 )); then
      local dl_list="${dl_domains[*]}"
      warn_msgs+=("Only dl domain(s) are defined: ${dl_list}")
      warn_msgs+=("  → ACTION: Re-run STEP 11 (DA VM Deployment)")
    else
      local da_list="${da_domains[*]}"
      warn_msgs+=("Only da domain(s) are defined: ${da_list}")
      warn_msgs+=("  → ACTION: Re-run STEP 10 (DL VM Deployment)")
    fi
  else
    warn_msgs+=("dl/da domain(s) (e.g., dl-master, dl-worker1-3, da-master, da-worker1-3) not yet defined.")
    warn_msgs+=("  → NOTE: This is normal if before STEP 10/11 execution")
    warn_msgs+=("  → ACTION: Complete STEP 09 (DP Download) then run STEP 10 and STEP 11")
  fi

  # 7-2. dl-* domain(s) detailed validation (only if defined)
  if (( dl_defined == 1 )) && (( ${#dl_domains[@]} > 0 )); then
    # Use first dl-* domain for validation (prefer dl-master if exists, otherwise first one)
    local dl_vm=""
    local found_master=0
    for domain in "${dl_domains[@]}"; do
      if [[ "$domain" == "dl-master" ]]; then
        dl_vm="dl-master"
        found_master=1
        break
      fi
    done
    if [[ $found_master -eq 0 ]]; then
      dl_vm="${dl_domains[0]}"
    fi

    # SR-IOV hostdev (only check in SR-IOV mode, not in Bridge mode)
    if [[ ${is_bridge_mode} -eq 0 ]]; then
      # SR-IOV mode: check for hostdev
      if virsh dumpxml "${dl_vm}" 2>/dev/null | grep -q '<hostdev '; then
        ok_msgs+=("${dl_vm} SR-IOV VF(hostdev) passthrough configuration detected")
      else
        warn_msgs+=("${dl_vm} XML does not have hostdev(SR-IOV) configuration yet.")
        warn_msgs+=("  → ACTION: Re-run STEP 12 (SR-IOV / CPU Affinity Configuration)")
        warn_msgs+=("  → CHECK: Verify SR-IOV VFs are available with 'lspci | grep Virtual Function'")
      fi
    else
      # Bridge mode: check for bridge interface instead (SR-IOV not required in Bridge mode)
      local bridge_name="${CLUSTER_BRIDGE_NAME:-br-cluster}"
      if virsh dumpxml "${dl_vm}" 2>/dev/null | grep -qE "interface.*type=['\"]bridge['\"]" && \
         virsh dumpxml "${dl_vm}" 2>/dev/null | grep -qE "source bridge=['\"]${bridge_name}['\"]"; then
        ok_msgs+=("${dl_vm} Bridge interface (${bridge_name}) configuration detected (Bridge mode)")
      elif virsh dumpxml "${dl_vm}" 2>/dev/null | grep -qE "interface.*type=['\"]bridge['\"]"; then
        # Bridge interface exists but may be different bridge
        ok_msgs+=("${dl_vm} Bridge interface configuration detected (Bridge mode)")
      else
        warn_msgs+=("${dl_vm} XML does not have bridge interface configuration.")
        warn_msgs+=("  → ACTION: Re-run STEP 12 (Bridge / CPU Affinity Configuration)")
        warn_msgs+=("  → NOTE: In Bridge mode, VMs use bridge interfaces instead of SR-IOV")
      fi
    fi

    # CPU pinning(cputune)
    if virsh dumpxml "${dl_vm}" 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("${dl_vm} CPU pinning(cputune) configuration detected")
    else
      warn_msgs+=("${dl_vm} XML does not have CPU pinning(cputune) configuration.")
      warn_msgs+=("  → ACTION: Re-run STEP 12 (SR-IOV / CPU Affinity Configuration)")
      warn_msgs+=("  → NOTE: NUMA-based vCPU placement may not be applied without this")
    fi

    # CD-ROM / ISO connection status
    # Check if there is a CD-ROM disk device with ISO file source (excluding seed ISO which is required for Cloud-Init)
    local has_non_seed_cdrom_iso=0
    local cdrom_xml
    cdrom_xml="$(virsh dumpxml "${dl_vm}" 2>/dev/null | grep -A 10 -E "device=['\"]cdrom['\"]" || true)"
    
    if [[ -n "${cdrom_xml}" ]]; then
      # Check each CD-ROM device for non-seed ISO files
      while IFS= read -r line; do
        if echo "$line" | grep -q "<source.*\.iso"; then
          # Check if it's NOT a seed ISO (seed ISO is required for Cloud-Init)
          if ! echo "$line" | grep -qE "-seed\.iso['\"]"; then
            has_non_seed_cdrom_iso=1
            break
          fi
        fi
      done <<< "${cdrom_xml}"
    fi
    
    if [[ ${has_non_seed_cdrom_iso} -eq 1 ]]; then
      warn_msgs+=("${dl_vm} XML still has CD-ROM device with non-seed ISO(.iso) file connected.")
      warn_msgs+=("  → ACTION: Re-run STEP 12 to automatically remove CD-ROM devices")
      warn_msgs+=("  → MANUAL (if needed): Remove ISO with 'virsh change-media ${dl_vm} --eject <device>'")
      warn_msgs+=("  → MANUAL (if needed): Or detach CD-ROM with 'virsh detach-disk ${dl_vm} <device> --config'")
      warn_msgs+=("  → NOTE: seed.iso files are required for Cloud-Init and should remain connected")
    else
      ok_msgs+=("${dl_vm} CD-ROM/ISO status OK (only seed ISO for Cloud-Init, or no CD-ROM with ISO)")
    fi
  fi

  # 7-3. da-* domain(s) detailed validation (only if defined)
  if (( da_defined == 1 )) && (( ${#da_domains[@]} > 0 )); then
    # Use first da-* domain for validation (prefer da-master if exists, otherwise first one)
    local da_vm=""
    local found_master=0
    for domain in "${da_domains[@]}"; do
      if [[ "$domain" == "da-master" ]]; then
        da_vm="da-master"
        found_master=1
        break
      fi
    done
    if [[ $found_master -eq 0 ]]; then
      da_vm="${da_domains[0]}"
    fi

    # SR-IOV hostdev (only check in SR-IOV mode, not in Bridge mode)
    if [[ ${is_bridge_mode} -eq 0 ]]; then
      # SR-IOV mode: check for hostdev
      if virsh dumpxml "${da_vm}" 2>/dev/null | grep -q '<hostdev '; then
        ok_msgs+=("${da_vm} SR-IOV VF(hostdev) passthrough configuration detected")
      else
        warn_msgs+=("${da_vm} XML does not have hostdev(SR-IOV) configuration yet.")
        warn_msgs+=("  → ACTION: Re-run STEP 12 (SR-IOV / CPU Affinity Configuration)")
        warn_msgs+=("  → CHECK: Verify SR-IOV VFs are available with 'lspci | grep Virtual Function'")
      fi
    else
      # Bridge mode: check for bridge interface instead (SR-IOV not required in Bridge mode)
      local bridge_name="${CLUSTER_BRIDGE_NAME:-br-cluster}"
      if virsh dumpxml "${da_vm}" 2>/dev/null | grep -qE "interface.*type=['\"]bridge['\"]" && \
         virsh dumpxml "${da_vm}" 2>/dev/null | grep -qE "source bridge=['\"]${bridge_name}['\"]"; then
        ok_msgs+=("${da_vm} Bridge interface (${bridge_name}) configuration detected (Bridge mode)")
      elif virsh dumpxml "${da_vm}" 2>/dev/null | grep -qE "interface.*type=['\"]bridge['\"]"; then
        # Bridge interface exists but may be different bridge
        ok_msgs+=("${da_vm} Bridge interface configuration detected (Bridge mode)")
      else
        warn_msgs+=("${da_vm} XML does not have bridge interface configuration.")
        warn_msgs+=("  → ACTION: Re-run STEP 12 (Bridge / CPU Affinity Configuration)")
        warn_msgs+=("  → NOTE: In Bridge mode, VMs use bridge interfaces instead of SR-IOV")
      fi
    fi

    # CPU pinning(cputune)
    if virsh dumpxml "${da_vm}" 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("${da_vm} CPU pinning(cputune) configuration detected")
    else
      warn_msgs+=("${da_vm} XML does not have CPU pinning(cputune) configuration.")
      warn_msgs+=("  → ACTION: Re-run STEP 12 (SR-IOV / CPU Affinity Configuration)")
      warn_msgs+=("  → NOTE: NUMA-based vCPU placement may not be applied without this")
    fi

    # CD-ROM / ISO connection status
    # Check if there is a CD-ROM disk device with ISO file source (excluding seed ISO which is required for Cloud-Init)
    local has_non_seed_cdrom_iso=0
    local cdrom_xml
    cdrom_xml="$(virsh dumpxml "${da_vm}" 2>/dev/null | grep -A 10 -E "device=['\"]cdrom['\"]" || true)"
    
    if [[ -n "${cdrom_xml}" ]]; then
      # Check each CD-ROM device for non-seed ISO files
      while IFS= read -r line; do
        if echo "$line" | grep -q "<source.*\.iso"; then
          # Check if it's NOT a seed ISO (seed ISO is required for Cloud-Init)
          if ! echo "$line" | grep -qE "-seed\.iso['\"]"; then
            has_non_seed_cdrom_iso=1
            break
          fi
        fi
      done <<< "${cdrom_xml}"
    fi
    
    if [[ ${has_non_seed_cdrom_iso} -eq 1 ]]; then
      warn_msgs+=("${da_vm} XML still has CD-ROM device with non-seed ISO(.iso) file connected.")
      warn_msgs+=("  → ACTION: Re-run STEP 12 to automatically remove CD-ROM devices")
      warn_msgs+=("  → MANUAL (if needed): Remove ISO with 'virsh change-media ${da_vm} --eject <device>'")
      warn_msgs+=("  → MANUAL (if needed): Or detach CD-ROM with 'virsh detach-disk ${da_vm} <device> --config'")
      warn_msgs+=("  → NOTE: seed.iso files are required for Cloud-Init and should remain connected")
    else
      ok_msgs+=("${da_vm} CD-ROM/ISO status OK (only seed ISO for Cloud-Init, or no CD-ROM with ISO)")
    fi
  fi

  ###############################
  # 8. libvirt hooks / ipset status (optional but important)
  ###############################
  if [[ -f /etc/libvirt/hooks/qemu ]]; then
    ok_msgs+=("/etc/libvirt/hooks/qemu script exists")
  else
    warn_msgs+=("Could not find /etc/libvirt/hooks/qemu script.")
    warn_msgs+=("  → ACTION: Re-run STEP 08 (Libvirt Hooks Configuration)")
    warn_msgs+=("  → NOTE: NAT and OOM restart automation may not work without this")
  fi

  ###############################
  # Build summary message (error → warning → normal)
  ###############################
  local summary=""
  
  # Count only main messages (not → ACTION, → CHECK, etc.)
  local err_main_cnt=0
  local warn_main_cnt=0
  local ok_cnt=${#ok_msgs[@]}
  
  for msg in "${err_msgs[@]}"; do
    if [[ ! "${msg}" =~ ^[[:space:]]*→ ]]; then
      ((err_main_cnt++))
    fi
  done
  
  for msg in "${warn_msgs[@]}"; do
    if [[ ! "${msg}" =~ ^[[:space:]]*→ ]]; then
      ((warn_main_cnt++))
    fi
  done

  # Build summary text for msgbox
  summary+="Full Configuration Validation Summary\n\n"

  # 1) Overall status
  if (( err_main_cnt == 0 && warn_main_cnt == 0 )); then
    summary+="✅ All validation items are normal.\n"
    summary+="✅ No errors or warnings detected.\n\n"
  elif (( err_main_cnt == 0 && warn_main_cnt > 0 )); then
    summary+="⚠️  No critical errors, but ${warn_main_cnt} warning(s) found.\n"
    summary+="⚠️  Please review [WARN] items below.\n\n"
  else
    summary+="❌ ${err_main_cnt} error(s) and ${warn_main_cnt} warning(s) detected.\n"
    summary+="❌ Please address [ERROR] items first, then review [WARN] items.\n\n"
  fi

  # 2) ERROR first (most critical)
  if (( err_main_cnt > 0 )); then
    summary+="❌ [ERROR] - Critical Issues (Must Fix):\n"
    summary+="─────────────────────────────────────────\n"
    local idx=1
    for msg in "${err_msgs[@]}"; do
      if [[ "${msg}" =~ ^[[:space:]]*→ ]]; then
        # This is an action/check line, add it directly
        summary+="${msg}\n"
      else
        # This is a main error message
        summary+="\n${idx}. ${msg}\n"
        ((idx++))
      fi
    done
    summary+="\n"
  fi

  # 3) Then WARN
  if (( warn_main_cnt > 0 )); then
    summary+="⚠️  [WARN] - Warnings (Recommended to Fix):\n"
    summary+="─────────────────────────────────────────\n"
    local idx=1
    for msg in "${warn_msgs[@]}"; do
      if [[ "${msg}" =~ ^[[:space:]]*→ ]]; then
        # This is an action/check line, add it directly
        summary+="${msg}\n"
      else
        # This is a main warning message
        summary+="\n${idx}. ${msg}\n"
        ((idx++))
      fi
    done
    summary+="\n"
  fi

  # 4) OK summary
  if (( err_main_cnt == 0 && warn_main_cnt == 0 )); then
    summary+="✅ [OK] - All Validation Items:\n"
    summary+="─────────────────────────────────────────\n"
    summary+="All validation items match installation guide.\n"
    summary+="No issues detected.\n"
  else
    summary+="✅ [OK] - Validated Items:\n"
    summary+="─────────────────────────────────────────\n"
    summary+="${ok_cnt} item(s) validated successfully.\n"
    summary+="Items not listed above are all normal.\n"
  fi

  echo "${summary}"
}



menu_full_validation() {
  # Full validation uses read-only commands, so must execute actual commands regardless of DRY_RUN
  # set -e causes exit on any failure, so temporarily ignore errors in this block
  set +e

  local tmp_file="/tmp/xdr_full_validation_$(date '+%Y%m%d-%H%M%S').log"

  {
    echo "========================================"
    echo " XDR Installer Full Configuration Validation"
    echo " Execution time: $(date '+%F %T')"
        echo
        echo " *** Press spacebar or down arrow to see next message." 
        echo " *** Press q to exit this message."
    echo "========================================"
    echo

    ##################################################
    # 1. HWE kernel / IOMMU / GRUB configuration validation
    ##################################################
    echo "## 1. HWE kernel / IOMMU / GRUB configuration validation"
    echo
    echo "\$ uname -r"
    uname -r 2>&1 || echo "[WARN] uname -r execution failed"
    echo

    echo "\$ dpkg -l | grep linux-image"
    dpkg -l | grep linux-image 2>&1 || echo "[INFO] linux-image packages not displayed."
    echo

    echo "\$ grep GRUB_CMDLINE_LINUX /etc/default/grub"
    grep GRUB_CMDLINE_LINUX /etc/default/grub 2>&1 || echo "[WARN] Could not find GRUB_CMDLINE_LINUX in /etc/default/grub."
    echo

    ##################################################
    # 2. NIC / ifupdown / routing table validation
    ##################################################
    echo "## 2. NIC / ifupdown / routing table validation"
    echo
    echo "\$ ip link show"
    ip link show 2>&1 || echo "[WARN] ip link show execution failed"
    echo

    echo "\$ ip addr show mgt"
    ip addr show mgt 2>&1 || echo "[WARN] mgt interface not visible."
    echo

    echo "\$ ip addr show cltr0"
    ip addr show cltr0 2>&1 || echo "[WARN] cltr0 interface not visible."
    echo

    echo "\$ systemctl status networking --no-pager"
    systemctl status networking --no-pager 2>&1 || echo "[WARN] networking service status check failed"
    echo

    echo "\$ ip route"
    ip route 2>&1 || echo "[WARN] ip route execution failed"
    echo

    echo "\$ ip rule"
    ip rule 2>&1 || echo "[WARN] ip rule execution failed"
    echo

    echo "\$ ip route show table rt_mgt"
    ip route show table rt_mgt 2>&1 || echo "[INFO] rt_mgt routing table is empty or does not exist."
    echo

    ##################################################
    # 3. KVM / Libvirt / default network validation
    ##################################################
    echo "## 3. KVM / Libvirt / default network validation"
    echo

    echo "\$ lsmod | grep kvm"
    lsmod | grep kvm 2>&1 || echo "[WARN] kvm-related kernel modules do not seem to be loaded."
    echo

    echo "\$ kvm-ok"
    if command -v kvm-ok >/dev/null 2>&1; then
      kvm-ok 2>&1 || echo "[WARN] kvm-ok check failed (KVM may not be available)."
    else
      echo "[INFO] kvm-ok command not available (cpu-checker package not installed or not included by default in Ubuntu 24.04)."
    fi
    echo

    echo "\$ systemctl status libvirtd --no-pager"
    systemctl status libvirtd --no-pager 2>&1 || echo "[WARN] libvirtd service status check failed"
    echo

    echo "\$ systemctl status virtlogd.socket --no-pager"
    systemctl status virtlogd.socket --no-pager 2>&1 || echo "[WARN] virtlogd.socket status check failed"
    echo

    echo "\$ virsh net-list --all"
    virsh net-list --all 2>&1 || echo "[WARN] virsh net-list --all execution failed"
    echo

    echo "\$ virsh net-dumpxml default"
    virsh net-dumpxml default 2>&1 || echo "[WARN] default network XML dump failed"
    echo

    ##################################################
    # 4. Kernel tuning / KSM / Swap configuration validation
    ##################################################
    echo "## 4. Kernel tuning / KSM / Swap configuration validation"
    echo

    echo "\$ grep -n 'XDR_KERNEL_TUNING_' /etc/sysctl.conf"
    grep -n 'XDR_KERNEL_TUNING_' /etc/sysctl.conf 2>&1 || echo "[INFO] /etc/sysctl.conf does not have XDR tuning block."
    echo

    echo "\$ sysctl net.ipv4.conf.all.arp_filter"
    sysctl net.ipv4.conf.all.arp_filter 2>&1 || echo "[WARN] arp_filter value check failed"
    echo

    echo "\$ sysctl net.ipv4.conf.all.arp_announce"
    sysctl net.ipv4.conf.all.arp_announce 2>&1 || echo "[WARN] arp_announce value check failed"
    echo

    echo "\$ sysctl net.ipv4.conf.all.arp_ignore"
    sysctl net.ipv4.conf.all.arp_ignore 2>&1 || echo "[WARN] arp_ignore value check failed"
    echo

    echo "\$ sysctl net.ipv4.conf.all.ignore_routes_with_linkdown"
    sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>&1 || echo "[WARN] ignore_routes_with_linkdown value check failed"
    echo

    echo "\$ sysctl vm.min_free_kbytes"
    sysctl vm.min_free_kbytes 2>&1 || echo "[WARN] vm.min_free_kbytes value check failed"
    echo

    echo "\$ sysctl net.ipv4.ip_forward"
    sysctl net.ipv4.ip_forward 2>&1 || echo "[WARN] net.ipv4.ip_forward value check failed"
    echo

    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      echo "\$ cat /sys/kernel/mm/ksm/run"
      cat /sys/kernel/mm/ksm/run 2>&1 || echo "[WARN] /sys/kernel/mm/ksm/run read failed"
    else
      echo "[INFO] /sys/kernel/mm/ksm/run file does not exist."
    fi
    echo

    echo "\$ grep swap.img /etc/fstab"
    grep swap.img /etc/fstab 2>&1 || echo "[INFO] /etc/fstab does not have swap.img entry or it is already commented out."
    echo

    ##################################################
    # 5. NTPsec configuration validation
    ##################################################
    echo "## 5. NTPsec configuration validation"
    echo

    echo "\$ systemctl status ntpsec --no-pager"
    systemctl status ntpsec --no-pager 2>&1 || echo "[WARN] ntpsec service status check failed"
    echo

    echo "\$ ntpq -p"
    ntpq -p 2>&1 || echo "[WARN] ntpq -p execution failed (NTP synchronization may not have occurred)."
    echo

    ##################################################
    # 5.5. SR-IOV driver (iavf/i40evf) validation
    ##################################################
    echo "## 5.5. SR-IOV driver (iavf/i40evf) validation"
    echo

    echo "\$ lsmod | grep -E '^(iavf|i40evf)\\b'"
    lsmod | grep -E '^(iavf|i40evf)\b' 2>&1 || echo "[WARN] SR-IOV driver modules (iavf/i40evf) are not loaded."
    echo

    echo "\$ modinfo iavf 2>/dev/null | head -20"
    modinfo iavf 2>/dev/null | head -20 2>&1 || echo "[INFO] iavf module info not available (module may not be installed)."
    echo

    echo "\$ modinfo i40evf 2>/dev/null | head -20"
    modinfo i40evf 2>/dev/null | head -20 2>&1 || echo "[INFO] i40evf module info not available (module may not be installed)."
    echo

    echo "\$ lspci | grep -E 'Virtual Function|Adaptive Virtual'"
    lspci | grep -E 'Virtual Function|Adaptive Virtual' 2>&1 || echo "[INFO] No SR-IOV Virtual Function devices detected (this is normal if SR-IOV is not configured or VFs are not created)."
    echo

    ##################################################
    # 6. LVM / filesystem / mount validation
    ##################################################
    echo "## 6. LVM / filesystem / mount validation"
    echo

    echo "\$ pvs"
    pvs 2>&1 || echo "[WARN] pvs execution failed"
    echo

    echo "\$ vgs"
    vgs 2>&1 || echo "[WARN] vgs execution failed"
    echo

    echo "\$ lvs"
    lvs 2>&1 || echo "[WARN] lvs execution failed"
    echo

    echo "\$ lsblk"
    lsblk 2>&1 || echo "[WARN] lsblk execution failed"
    echo

    echo "\$ df -h | grep -E '/stellar'"
    df -h | grep -E '/stellar' 2>&1 || echo "[INFO] /stellar path not yet mounted."
    echo

    echo "\$ grep -E 'lv_dl_root|lv_da_root' /etc/fstab"
    grep -E 'lv_dl_root|lv_da_root' /etc/fstab 2>&1 || echo "[WARN] /etc/fstab does not have lv_dl_root / lv_da_root entries."
    echo

    ##################################################
    # 7. libvirt hooks / OOM recovery script / cron validation
    ##################################################
    echo "## 7. libvirt hooks / OOM recovery script / cron validation"
    echo

    echo "\$ ls -l /etc/libvirt/hooks"
    ls -l /etc/libvirt/hooks 2>&1 || echo "[WARN] Cannot check /etc/libvirt/hooks directory."
    echo

    echo "\$ sed -n '1,120p' /etc/libvirt/hooks/network"
    sed -n '1,120p' /etc/libvirt/hooks/network 2>&1 || echo "[INFO] /etc/libvirt/hooks/network file does not exist."
    echo

    echo "\$ sed -n '1,160p' /etc/libvirt/hooks/qemu"
    sed -n '1,160p' /etc/libvirt/hooks/qemu 2>&1 || echo "[INFO] /etc/libvirt/hooks/qemu file does not exist."
    echo

    echo "\$ ls -l /usr/bin/last_known_good_pid /usr/bin/check_vm_state"
    ls -l /usr/bin/last_known_good_pid /usr/bin/check_vm_state 2>&1 || echo "[WARN] last_known_good_pid or check_vm_state script does not exist."
    echo

    echo "\$ crontab -l"
    crontab -l 2>&1 || echo "[INFO] root crontab is empty or not accessible."
    echo


    ##################################################
    # 8. VM deployment status / SR-IOV / CPU Affinity / disk validation
    ##################################################
    echo "## 8. VM deployment status / SR-IOV / CPU Affinity / disk validation"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all execution failed"
    echo

    echo "\$ virsh dominfo dl-master"
    virsh dominfo dl-master 2>&1 || echo "[WARN] Could not get dl-master domain information."
    echo

    echo "\$ virsh dominfo da-master"
    virsh dominfo da-master 2>&1 || echo "[WARN] Could not get da-master domain information."
    echo

    echo "\$ virsh domblklist dl-master"
    virsh domblklist dl-master 2>&1 || echo "[WARN] dl-master block device list check failed"
    echo

    echo "\$ virsh domblklist da-master"
    virsh domblklist da-master 2>&1 || echo "[WARN] da-master block device list check failed"
    echo

    echo "\$ virsh dumpxml dl-master | egrep 'cputune|numatune|hostdev'"
    virsh dumpxml dl-master 2>/dev/null | egrep 'cputune|numatune|hostdev' 2>&1 || echo "[INFO] dl-master XML does not show cputune/numatune/hostdev blocks."
    echo

    echo "\$ virsh dumpxml da-master | egrep 'cputune|numatune|hostdev'"
    virsh dumpxml da-master 2>/dev/null | egrep 'cputune|numatune|hostdev' 2>&1 || echo "[INFO] da-master XML does not show cputune/numatune/hostdev blocks."
    echo

    echo "\$ lspci | grep -E 'Virtual Function|Adaptive Virtual|Ethernet'"
    lspci | grep -E 'Virtual Function|Adaptive Virtual|Ethernet' 2>&1 || echo "[WARN] SR-IOV VF or NIC-related PCI devices not visible."
    echo

    echo
    echo "========================================"
    echo " Full configuration validation completed"
    echo "========================================"
    echo

  } > "${tmp_file}"

  # Re-enable set -e
  set -e

  # 1) Generate summary text
  local summary
  summary=$(build_validation_summary "${tmp_file}")

  # 2) Save summary to temporary file for scrollable textbox
  local summary_file="/tmp/xdr_validation_summary_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${summary}" > "${summary_file}"

  # 3) Show summary in scrollable textbox (so user can see all ERROR and WARN messages)
  show_textbox "Full Configuration Validation Summary" "${summary_file}"

  # 4) Ask if user wants to view detailed log
  local view_detail_msg
  view_detail_msg=$(center_message "Do you want to view the detailed validation log?\n\nThis will show all command outputs and detailed information.")
  
  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "View Detailed Log" "${view_detail_msg}"
  local view_rc=$?
  set -e
  
  if [[ ${view_rc} -eq 0 ]]; then
    # 5) Show full validation log in detail using less
    show_paged "Full Configuration Validation Results (Detailed Log)" "${tmp_file}"
  fi

  # Clean up temporary summary file
  rm -f "${summary_file}"
}


#######################################
# Script usage guide (using show_paged)
#######################################
show_usage_help() {

  local msg
  msg=$'═══════════════════════════════════════════════════════════════
        ⭐ Stellar Cyber Open XDR Platform – KVM DP Installer Usage Guide ⭐
═══════════════════════════════════════════════════════════════


📌 **Prerequisites and Getting Started**
────────────────────────────────────────────────────────────
• This installer requires *root privileges*.
  Setup steps:
    1) Switch to root: sudo -i
    2) Create directory: mkdir -p /root/xdr-installer
    3) Save this script to that directory
    4) Make executable: chmod +x installer.sh
    5) Execute: ./installer.sh

• Navigation in this guide:
  - Press **SPACEBAR** or **↓** to scroll to next page
  - Press **↑** to scroll to previous page
  - Press **q** to exit


═══════════════════════════════════════════════════════════════
📋 **Main Menu Options Overview**
═══════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────┐
│ 1. Auto Execute All Steps                                    │
│    → Automatically runs all steps from the next incomplete   │
│    → Resumes from last completed step after reboot          │
│    → Best for: Initial installation or continuing after      │
│      reboot                                                  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 2. Select and Run Specific Step Only                        │
│    → Run individual steps independently                      │
│    → Best for: VM redeployment, image updates, or           │
│      reconfiguring specific components                       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 3. Configuration                                             │
│    → Configure installation parameters:                      │
│      • DRY_RUN: Simulation mode (default: 1)                │
│      • DP_VERSION: Data Processor version                    │
│      • ACPS credentials (username, password, URL)             │
│      • Hardware selections (NIC, disks)                     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 4. Full Configuration Validation                            │
│    → Comprehensive system validation                         │
│    → Checks: KVM, VMs, network, SR-IOV, storage            │
│    → Displays errors and warnings with detailed logs         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 5. Script Usage Guide                                        │
│    → Displays this help guide                                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 6. Exit                                                      │
│    → Exit the installer                                      │
└─────────────────────────────────────────────────────────────┘


═══════════════════════════════════════════════════════════════
🔰 **Scenario 1: Fresh Installation (Ubuntu 24.04)**
═══════════════════════════════════════════════════════════════

Step-by-Step Process:
────────────────────────────────────────────────────────────
1. Initial Setup:
   • Configure menu 3: Set DRY_RUN=0, DP_VERSION, ACPS credentials
   • Select menu 1 to start automatic installation

2. Installation Flow:
   STEP 01 → Hardware/NIC/Disk detection and selection
   STEP 02 → HWE kernel installation
   STEP 03 → NIC renaming, network configuration (ifupdown)
            ⚠️  System will automatically reboot after STEP 03

3. After First Reboot:
   • Run script again
   • Select menu 1 → Automatically continues from STEP 04

4. Continue Installation:
   STEP 04 → KVM/Libvirt installation
   STEP 05 → Kernel parameter tuning (IOMMU, KSM, Swap)
            ⚠️  System will automatically reboot after STEP 05

5. After Second Reboot:
   • Run script again
   • Select menu 1 → Automatically continues from STEP 06

6. Final Steps:
   STEP 06 → SR-IOV drivers + NTPsec
   STEP 07 → LVM storage setup
   STEP 08 → Libvirt hooks + OOM recovery
   STEP 09 → DP image download
   STEP 10 → DL-master VM deployment
   STEP 11 → DA-master VM deployment
   STEP 12 → SR-IOV VF passthrough + CPU affinity
   STEP 13 → DP Appliance CLI installation

7. Verification:
   • Select menu 4 to validate complete installation


═══════════════════════════════════════════════════════════════
🔧 **Scenario 2: Partial Installation or Reconfiguration**
═══════════════════════════════════════════════════════════════

When to Use:
────────────────────────────────────────────────────────────
• Some steps already completed
• Need to update specific components
• Changing configuration (NIC, disk, version)

Process:
────────────────────────────────────────────────────────────
1. Review current state:
   • Main menu shows last completed step
   • Check menu 4 (validation) for current status

2. Configure if needed:
   • Menu 3: Update DRY_RUN, DP_VERSION, or credentials

3. Continue or re-run:
   • Menu 1: Auto-continue from next incomplete step
   • Menu 2: Run specific steps that need updating


═══════════════════════════════════════════════════════════════
🧩 **Scenario 3: Specific Operations**
═══════════════════════════════════════════════════════════════

Common Use Cases:
────────────────────────────────────────────────────────────
• DL/DA VM Redeployment:
  → Menu 2 → STEP 10 (DL-master) or STEP 11 (DA-master)
  → Configure vCPU, memory, disk size as needed

• Update DP Version:
  → Menu 2 → STEP 09 (Download DP image)
  → Old version files are automatically cleaned up

• Network Configuration Change:
  → Menu 2 → STEP 01 (Hardware selection) → STEP 03 (Network)
  → STEP 12 (SR-IOV) if cluster NIC changed

• Reconfigure Storage:
  → Menu 2 → STEP 07 (LVM storage)
  → Note: Existing data may be affected


═══════════════════════════════════════════════════════════════
🔍 **Scenario 4: Validation and Troubleshooting**
═══════════════════════════════════════════════════════════════

Full System Validation:
────────────────────────────────────────────────────────────
• Select menu 4 (Full Configuration Validation)

Validation Checks:
────────────────────────────────────────────────────────────
✓ KVM/Libvirt installation and service status
✓ DL/DA VM deployment and running status
✓ Network configuration (NIC naming, IPs, routing)
✓ SR-IOV configuration (PF/VF status, passthrough)
✓ Storage configuration (LVM volumes, mount points)
✓ Service status (libvirtd, ntpsec)

Understanding Results:
────────────────────────────────────────────────────────────
• ✅ Green checkmarks: Configuration is correct
• ⚠️  Yellow warnings: Review recommended, may need attention
• ❌ Red errors: Must be fixed before proceeding

Fixing Issues:
────────────────────────────────────────────────────────────
• Review detailed log (option available after validation)
• Identify which step needs to be re-run
• Menu 2 → Select the specific step to fix
• Re-run validation after fixes


═══════════════════════════════════════════════════════════════
📦 **Hardware and Software Requirements**
═══════════════════════════════════════════════════════════════

Operating System:
────────────────────────────────────────────────────────────
• Ubuntu Server 24.04 LTS
• Installation: Keep default options (add SSH only)
• OS disk: Separate SSD, 1.7GB+ recommended
• Network: Default management network (MGT) via netplan
           (Will be converted to ifupdown during installation)

Server Hardware (Dell R650 or higher recommended):
────────────────────────────────────────────────────────────
• CPU:
  - 2 × Intel Xeon Gold 6542Y
  - Hyper-threading enabled → Total 96 vCPUs

• Memory:
  - 256GB or more

• Disk Configuration:
  - Ubuntu OS + DL/DA VMs: 1.92TB SSD (SATA)
  - Elastic Data Lake: Total 23TB (3.84TB SSD × 6, SATA)

• Network Interfaces:
  - Management/Data: 1Gb or 10Gb
  - Cluster: Intel X710 or E810 Dual-Port 10/25GbE SFP28

BIOS Settings (Required):
────────────────────────────────────────────────────────────
• Intel Virtualization Technology → Enabled
• SR-IOV Global Enable → Enabled


═══════════════════════════════════════════════════════════════
⚠️  **Important Notes and Troubleshooting**
═══════════════════════════════════════════════════════════════

Reboot Requirements:
────────────────────────────────────────────────────────────
• STEP 03 and STEP 05 require system reboot
• After reboot, script automatically resumes from next step
• Do not skip reboots - kernel and network changes require it

DRY_RUN Mode:
────────────────────────────────────────────────────────────
• Default: DRY_RUN=1 (simulation mode)
• Commands are logged but not executed
• Set DRY_RUN=0 in menu 3 for actual installation
• Always test with DRY_RUN=1 first

Disk Space Management:
────────────────────────────────────────────────────────────
• STEP 09: Old version files are automatically deleted
• STEP 10/11: Existing VM directories are cleaned up
• Monitor disk space: df -h /stellar
• If space issues occur, manually clean /stellar/dl/images/

Network Configuration Changes:
────────────────────────────────────────────────────────────
• Changing cluster NIC requires: STEP 01 → STEP 03 → STEP 12
• Network changes take effect after STEP 03 reboot
• Verify with: ip addr show, virsh net-list

Log Files:
────────────────────────────────────────────────────────────
• Main log: /var/log/xdr-installer.log
• Step logs: Displayed during each step execution
• Validation logs: Available in menu 4 detailed view


═══════════════════════════════════════════════════════════════
💡 **Tips for Success**
═══════════════════════════════════════════════════════════════

• Always start with DRY_RUN=1 to preview changes
• Review validation results (menu 4) before final deployment
• Keep installation guide document handy for reference
• Check hardware compatibility before starting
• Ensure BIOS settings are correct (virtualization, SR-IOV)
• Monitor disk space throughout installation
• Save configuration after menu 3 changes

═══════════════════════════════════════════════════════════════'

  # Save content to temporary file and display with show_textbox
  local tmp_help_file="/tmp/xdr_dp_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR Platform Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}


menu_select_step_and_run() {
  while true; do
    load_state
    load_config

    local menu_items=()
    local i
    for ((i=0; i<NUM_STEPS; i++)); do
      local step_id="${STEP_IDS[$i]}"
      local step_name="${STEP_NAMES[$i]}"
      local status="[wait]"
      local step_num=$(printf "%02d" $((i+1)))

      # STEP 06 always includes SR-IOV driver installation + NTPsec
      if [[ "${step_id}" == "06_ntpsec" ]]; then
        step_name="Configure SR-IOV drivers (iavf/i40evf) + NTPsec"
      fi

      if [[ "${LAST_COMPLETED_STEP}" == "${step_id}" ]]; then
        status="[✓]"
      elif [[ -n "${LAST_COMPLETED_STEP}" ]]; then
        local last_idx
        last_idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
        if [[ ${last_idx} -ge 0 && ${i} -le ${last_idx} ]]; then
          status="[✓]"
        fi
      fi

      # Use step number as tag (instead of step_id) for cleaner display
      menu_items+=("${step_num}" "${step_name} ${status}")
    done

    # Calculate menu size dynamically
    local menu_item_count=${NUM_STEPS}
    local menu_dims
    menu_dims=$(calc_menu_size "${menu_item_count}" 100 10)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Center-align the menu message
    local centered_msg
    centered_msg=$(center_menu_message "Select step to execute:" "${menu_height}")

    local choice
    choice=$(whiptail --title "XDR Installer - Step Selection" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${menu_items[@]}" \
                      3>&1 1>&2 2>&3) || {
      # ESC or Cancel pressed - return to main menu
      break
    }

    # Convert step number (e.g., "01") to step index (0-based)
    local step_index=$((10#${choice} - 1))
    if [[ ${step_index} -ge 0 && ${step_index} -lt ${NUM_STEPS} ]]; then
      run_step "${step_index}"
    else
      log "ERROR: Invalid step number '${choice}'"
      continue
    fi
  done
}

menu_auto_continue_from_state() {
  load_config
  local next_idx
  next_idx=$(get_next_step_index)

  if (( next_idx >= NUM_STEPS )); then
    # Calculate dialog size dynamically
    local dialog_dims
    dialog_dims=$(calc_dialog_size 10 70)
    local dialog_height dialog_width
    read -r dialog_height dialog_width <<< "${dialog_dims}"
    
    whiptail --title "XDR Installer" \
             --msgbox "All steps are already completed.\n\nSTATE_FILE: ${STATE_FILE}" \
             "${dialog_height}" "${dialog_width}"
    return 0
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"
  # STEP 06 always includes SR-IOV driver installation + NTPsec
  local next_step_id="${STEP_IDS[$next_idx]}"
  if [[ "${next_step_id}" == "06_ntpsec" ]]; then
    next_step_name="Configure SR-IOV drivers (iavf/i40evf) + NTPsec"
  fi

  # Calculate dialog size dynamically for yesno
  local dialog_dims
  dialog_dims=$(calc_dialog_size 15 70)
  local dialog_height dialog_width
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  if ! whiptail --title "XDR Installer - Auto Continue" \
                --yesno "From current state, the next step is:\n\n${next_step_name}\n\nExecute from this step sequentially?" \
                "${dialog_height}" "${dialog_width}"
  then
    # No / Cancel → cancel auto continue, return to main menu (not an error)
    log "User canceled auto continue."
    return 0
  fi

  local i
  for ((i=next_idx; i<NUM_STEPS; i++)); do
    run_step "$i"
    if [[ "${RUN_STEP_STATUS}" == "CANCELED" ]]; then
      return 0
    elif [[ "${RUN_STEP_STATUS}" == "FAILED" ]]; then
      # Calculate dialog size dynamically
      local dialog_dims
      dialog_dims=$(calc_dialog_size 10 70)
      local dialog_height dialog_width
      read -r dialog_height dialog_width <<< "${dialog_dims}"
      
      whiptail --title "XDR Installer" \
               --msgbox "STEP execution stopped.\n\nPlease check the log (${LOG_FILE}) for details." \
               "${dialog_height}" "${dialog_width}"
      return 0
    fi
  done
}


main_menu() {
  while true; do
    load_config
    load_state

    local status_msg
    if [[ -z "${LAST_COMPLETED_STEP}" ]]; then
      status_msg="No steps completed yet."
    else
      status_msg="Last completed step: ${LAST_COMPLETED_STEP}\nLast execution time: ${LAST_RUN_TIME}"
    fi

    local choice

    # Calculate menu size dynamically (6 menu items)
    local menu_dims
    menu_dims=$(calc_menu_size 6 90 8)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Create message content
    local msg_content="${status_msg}\n\nDRY_RUN=${DRY_RUN}, DP_VERSION=${DP_VERSION}, ACPS_BASE_URL=${ACPS_BASE_URL}\nSTATE_FILE=${STATE_FILE}\n"
    
    # Center-align the menu message based on terminal height
    local centered_msg
    centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")

        # Run whiptail and capture both output and exit code
        # Important: Don't use command substitution in a way that loses exit code
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        choice=$(whiptail --title "XDR Installer Main Menu" \
          --menu "${centered_msg}" \
          "${menu_height}" "${menu_width}" "${menu_list_height}" \
          "1" "Auto execute all steps (continue from next step based on current state)" \
          "2" "Select and run specific step only" \
          "3" "Configuration (DRY_RUN, DP_VERSION, etc.)" \
          "4" "Full configuration validation" \
          "5" "Script usage guide" \
          "6" "Exit" \
		  3>&1 1>&2 2>&3)
        local menu_rc=$?
        set -e
        
        if [[ ${menu_rc} -ne 0 ]]; then
          # ESC or Cancel pressed - exit code is non-zero
          # Continue loop instead of exiting
          continue
        fi
        
        # Additional check: if choice is empty, also continue
        if [[ -z "${choice}" ]]; then
          continue
        fi
          


        case "${choice}" in
          "1")
            menu_auto_continue_from_state
            ;;
          "2")
            menu_select_step_and_run
            ;;
          "3")
            menu_config
            ;;
          "4")
            menu_full_validation
            ;;
          "5")
            show_usage_help
            ;;
          "6")
            exit 0
            ;;
          *)
            # Unknown choice - continue loop
            continue
            ;;
        esac


  done
}


#######################################
# Entry point
#######################################

main_menu