#!/usr/bin/env bash
#
# XDR Sensor Install Framework (SSH + Whiptail based TUI)
# Modified from OpenXDR-installer.sh for Sensor-specific use
#

set -euo pipefail

#######################################
# Basic Configuration
#######################################

# Select appropriate directory based on execution environment
if [[ "${EUID}" -eq 0 ]]; then
  BASE_DIR="/root/xdr-installer"  # Use /root when running as root
else
  BASE_DIR="${HOME}/xdr-installer"  # Use home directory when running as regular user
fi
STATE_DIR="${BASE_DIR}/state"
STEPS_DIR="${BASE_DIR}/steps"

STATE_FILE="${STATE_DIR}/xdr_install.state"
LOG_FILE="${STATE_DIR}/xdr_install.log"
CONFIG_FILE="${STATE_DIR}/xdr_install.conf" 

# Values are now read from CONFIG instead of being hardcoded in the script
DRY_RUN=1   # Default value (overridden by load_config)

# Host auto-reboot configuration
ENABLE_AUTO_REBOOT=1                 # 1: Auto-reboot after STEP completion, 0: No auto-reboot
AUTO_REBOOT_AFTER_STEP_ID="03_nic_ifupdown 05_kernel_tuning"

# SPAN NIC attachment mode configuration
: "${SPAN_ATTACH_MODE:=pci}"         # pci | bridge

# Check for whiptail availability
if ! command -v whiptail >/dev/null 2>&1; then
  echo "ERROR: whiptail command is required. Please install it first:"
  echo "  sudo apt update && sudo apt install -y whiptail"
  exit 1
fi

# Create directories
mkdir -p "${STATE_DIR}" "${STEPS_DIR}"

#######################################
# STEP Definition
#  - Managed by ID and NAME arrays
#######################################

# STEP ID (for internal use, state storage, etc.)
STEP_IDS=(
  "01_hw_detect"
  "02_hwe_kernel"
  "03_nic_ifupdown"
  "04_kvm_libvirt"
  "05_kernel_tuning"
  "06_libvirt_hooks"
  "07_sensor_download"
  "08_sensor_deploy"
  "09_sensor_passthrough"
  "10_install_dp_cli"
)

# STEP Names (descriptions displayed in UI)
STEP_NAMES=(
  "Hardware / NIC / CPU / Memory / SPAN NIC Selection"
  "HWE Kernel Installation"
  "NIC Name/ifupdown Switch and Network Configuration"
  "KVM / Libvirt Installation and Basic Configuration"
  "Kernel Parameters / KSM / Swap Tuning"
  "libvirt hooks Installation + NTPsec"
  "Sensor LV Creation + Image/Script Download"
  "Sensor VM Deployment"
  "Sensor VM Network & SPAN Interface Configuration"
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
  local message="$1"
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
  
  echo "${padding}${message}"
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

# Common whiptail textbox helper (scrollable)
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

  # Set default values
  [ -z "${HEIGHT}" ] && HEIGHT=25
  [ -z "${WIDTH}" ] && WIDTH=100
  
  # Ensure minimum size and limit maximum size
  [ "${HEIGHT}" -lt 20 ] && HEIGHT=20
  [ "${HEIGHT}" -gt 50 ] && HEIGHT=50
  [ "${WIDTH}" -lt 80 ] && WIDTH=80
  [ "${WIDTH}" -gt 120 ] && WIDTH=120

  # Ensure sufficient margin for scrolling in whiptail
  local box_height=$((HEIGHT-6))
  local box_width=$((WIDTH-6))
  
  # Ensure minimum display size
  [ "${box_height}" -lt 15 ] && box_height=15
  [ "${box_width}" -lt 70 ] && box_width=70

  if ! whiptail --title "${title}" \
                --scrolltext \
                --textbox "${file}" "${box_height}" "${box_width}"; then
    # Ignore cancel (ESC) and just return
    :
  fi
}

#######################################
# Version for viewing long output with less (color + set -e / set -u safe)
# Usage:
#   1) Direct content only: show_paged "$big_message"
#   2) Title + file: show_paged "Title" "/path/to/file"
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

  # --- Argument processing (safe for set -u environment) ---
  no_clear="0"
  if [[ $# -eq 1 ]]; then
    # Case 1: Only one argument - content string only
    title="XDR Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    # Case 2: Two or more arguments - 1 = title, 2 = file path
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
  echo -e "${GREEN}* Space/↓: Next page, ↑: Previous, q: Quit${RESET}"
  echo

  # --- Protect less from here: prevent exit due to set -e ---
  set +e
  less -R "${file}"
  local rc=$?
  set -e
  # ----------------------------------------------------

  # In single-argument mode, we created tmpfile, so remove it if it exists
  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"

  # Always consider "success" regardless of less return code
  return 0
}



#######################################
# Common Utility Functions
#######################################

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | tee -a "${LOG_FILE}"
}

# Execute command in DRY_RUN mode
run_cmd() {
  local cmd="$*"
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${cmd}"
  else
    log "[RUN] ${cmd}"
    # Execute command while showing real-time output
    eval "${cmd}" 2>&1 | tee -a "${LOG_FILE}"
    local exit_code="${PIPESTATUS[0]}"
    if [[ "${exit_code}" -ne 0 ]]; then
      log "[ERROR] Command execution failed (exit code: ${exit_code}): ${cmd}"
    fi
    return "${exit_code}"
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
    log "[DRY-RUN] Adding the following line to /etc/fstab: ${line}"
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
# VM Safe Restart Helper (Shutdown -> Destroy -> Start)
#######################################
restart_vm_safely() {
  local vm_name="$1"
  local max_retries=30  # Shutdown wait time (seconds)

  log "[INFO] Starting safe restart process for '${vm_name}' VM..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Waiting for ${vm_name} shutdown then restart (Skip)"
    return 0
  fi

  # 1. Check if running and attempt shutdown
  if virsh list --name | grep -q "^${vm_name}$"; then
    log "   -> '${vm_name}' is running. Attempting graceful shutdown (Shutdown)..."
    virsh shutdown "${vm_name}" > /dev/null 2>&1

    # 2. Wait for shutdown (Loop)
    local count=0
    while virsh list --name | grep -q "^${vm_name}$"; do
      sleep 1
      ((count++))
      # To show progress only on screen without logging, use echo -ne (here we use log for consistency)
      
      # 3. Force shutdown (Destroy) on timeout
      if [ "$count" -ge "$max_retries" ]; then
        log "   -> [Warning] Graceful shutdown timeout. Performing force shutdown (Destroy)."
        virsh destroy "${vm_name}"
        sleep 2
        break
      fi
    done
    log "   -> '${vm_name}' shutdown confirmed."
  else
    log "   -> '${vm_name}' is already stopped."
  fi

  # 4. Start VM
  log "   -> Starting '${vm_name}' again..."
  virsh start "${vm_name}"
  
  if [ $? -eq 0 ]; then
    log "[SUCCESS] '${vm_name}' restart completed."
  else
    log "[ERROR] '${vm_name}' start failed."
    return 1
  fi
}

#######################################
# Configuration Management (CONFIG_FILE)
#######################################

# CONFIG_FILE is assumed to be defined above
# Example: CONFIG_FILE="${STATE_DIR}/xdr-installer.conf"
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
  fi

  # Default values (set only if not already set)
  : "${DRY_RUN:=1}"  # Default is DRY_RUN=1 (safe mode)
  : "${STEP01_LINK_SCAN_REAL:=1}"
  : "${SENSOR_VERSION:=6.2.0}"
  : "${ACPS_USERNAME:=}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=}"

  # Auto-reboot related default values
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"

  # Set default values for NIC / disk selection to ensure they are always defined
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"
  : "${HOSTMGMT_NIC:=}"
  : "${SPAN_NICS:=}"
  : "${HOST_NIC_PCI:=}"
  : "${HOST_NIC_MAC:=}"
  : "${DATA_NIC_PCI:=}"
  : "${DATA_NIC_MAC:=}"
  : "${HOSTMGMT_NIC_PCI:=}"
  : "${HOSTMGMT_NIC_MAC:=}"
  : "${HOST_NIC_EFFECTIVE:=}"
  : "${DATA_NIC_EFFECTIVE:=}"
  : "${HOSTMGMT_NIC_EFFECTIVE:=}"
  : "${HOSTMGMT_NIC_RENAMED:=}"
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"
  : "${SPAN_ATTACH_MODE:=pci}"
  : "${SPAN_NIC_LIST:=}"
  : "${SPAN_BRIDGE_LIST:=}"
  : "${SENSOR_NET_MODE:=nat}"
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"
}


save_config() {
  # Create directory for CONFIG_FILE
  mkdir -p "$(dirname "${CONFIG_FILE}")"

  # Replace " in values with \" (to prevent config file corruption)
  local esc_sensor_version esc_acps_user esc_acps_pass esc_acps_url
  esc_sensor_version=${SENSOR_VERSION//\"/\\\"}
  esc_acps_user=${ACPS_USERNAME//\"/\\\"}
  esc_acps_pass=${ACPS_PASSWORD//\"/\\\"}
  esc_acps_url=${ACPS_BASE_URL//\"/\\\"}

  # ★ Also escape NIC / sensor related values
  local esc_host_nic esc_data_nic esc_hostmgmt_nic esc_span_nics esc_sensor_vcpus esc_sensor_memory_mb esc_sensor_passthrough_pcis
  local esc_span_attach_mode esc_span_nic_list esc_span_bridge_list esc_sensor_net_mode esc_lv_location esc_lv_size_gb
  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_data_nic=${DATA_NIC//\"/\\\"}
  esc_hostmgmt_nic=${HOSTMGMT_NIC//\"/\\\"}
  esc_span_nics=${SPAN_NICS//\"/\\\"}
  esc_sensor_vcpus=${SENSOR_VCPUS//\"/\\\"}
  esc_sensor_memory_mb=${SENSOR_MEMORY_MB//\"/\\\"}
  esc_sensor_passthrough_pcis=${SENSOR_SPAN_VF_PCIS//\"/\\\"}
  esc_span_attach_mode=${SPAN_ATTACH_MODE//\"/\\\"}
  esc_span_nic_list=${SPAN_NIC_LIST//\"/\\\"}
  esc_span_bridge_list=${SPAN_BRIDGE_LIST//\"/\\\"}
  esc_sensor_net_mode=${SENSOR_NET_MODE//\"/\\\"}
  esc_lv_location=${LV_LOCATION//\"/\\\"}
  esc_lv_size_gb=${LV_SIZE_GB//\"/\\\"}

  cat > "${CONFIG_FILE}" <<EOF
# xdr-installer environment configuration (auto-generated)
DRY_RUN=${DRY_RUN}
SENSOR_VERSION="${esc_sensor_version}"
ACPS_USERNAME="${esc_acps_user}"
ACPS_PASSWORD="${esc_acps_pass}"
ACPS_BASE_URL="${esc_acps_url}"
ENABLE_AUTO_REBOOT=${ENABLE_AUTO_REBOOT}
AUTO_REBOOT_AFTER_STEP_ID="${AUTO_REBOOT_AFTER_STEP_ID}"

# NIC / Sensor settings selected in STEP 01
HOST_NIC="${esc_host_nic}"
DATA_NIC="${esc_data_nic}"
HOSTMGMT_NIC="${esc_hostmgmt_nic}"
HOST_NIC_PCI="${HOST_NIC_PCI//\"/\\\"}"
HOST_NIC_MAC="${HOST_NIC_MAC//\"/\\\"}"
DATA_NIC_PCI="${DATA_NIC_PCI//\"/\\\"}"
DATA_NIC_MAC="${DATA_NIC_MAC//\"/\\\"}"
HOSTMGMT_NIC_PCI="${HOSTMGMT_NIC_PCI//\"/\\\"}"
HOSTMGMT_NIC_MAC="${HOSTMGMT_NIC_MAC//\"/\\\"}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE//\"/\\\"}"
DATA_NIC_EFFECTIVE="${DATA_NIC_EFFECTIVE//\"/\\\"}"
HOSTMGMT_NIC_EFFECTIVE="${HOSTMGMT_NIC_EFFECTIVE//\"/\\\"}"
HOSTMGMT_NIC_RENAMED="${HOSTMGMT_NIC_RENAMED//\"/\\\"}"
SPAN_NICS="${esc_span_nics}"
SENSOR_VCPUS="${esc_sensor_vcpus}"
SENSOR_MEMORY_MB="${esc_sensor_memory_mb}"
SENSOR_SPAN_VF_PCIS="${esc_sensor_passthrough_pcis}"
SPAN_ATTACH_MODE="${esc_span_attach_mode}"
SPAN_NIC_LIST="${esc_span_nic_list}"
SPAN_BRIDGE_LIST="${esc_span_bridge_list}"
SENSOR_NET_MODE="${esc_sensor_net_mode}"
LV_LOCATION="${esc_lv_location}"
LV_SIZE_GB="${esc_lv_size_gb}"
EOF
}


# Existing code may call save_config_var, so maintain compatibility
# by updating variables internally and calling save_config() again
save_config_var() {
  local key="$1"
  local value="$2"

  case "${key}" in
    DRY_RUN)        DRY_RUN="${value}" ;;
    SENSOR_VERSION)     SENSOR_VERSION="${value}" ;;
    ACPS_USERNAME)  ACPS_USERNAME="${value}" ;;
    ACPS_PASSWORD)  ACPS_PASSWORD="${value}" ;;
    ACPS_BASE_URL)  ACPS_BASE_URL="${value}" ;;
    ENABLE_AUTO_REBOOT)        ENABLE_AUTO_REBOOT="${value}" ;;
    AUTO_REBOOT_AFTER_STEP_ID) AUTO_REBOOT_AFTER_STEP_ID="${value}" ;;

    # ★ Added here
    HOST_NIC)       HOST_NIC="${value}" ;;
    DATA_NIC)        DATA_NIC="${value}" ;;
    HOSTMGMT_NIC)    HOSTMGMT_NIC="${value}" ;;
    HOST_NIC_PCI)    HOST_NIC_PCI="${value}" ;;
    HOST_NIC_MAC)    HOST_NIC_MAC="${value}" ;;
    DATA_NIC_PCI)    DATA_NIC_PCI="${value}" ;;
    DATA_NIC_MAC)    DATA_NIC_MAC="${value}" ;;
    HOSTMGMT_NIC_PCI) HOSTMGMT_NIC_PCI="${value}" ;;
    HOSTMGMT_NIC_MAC) HOSTMGMT_NIC_MAC="${value}" ;;
    HOST_NIC_EFFECTIVE) HOST_NIC_EFFECTIVE="${value}" ;;
    DATA_NIC_EFFECTIVE) DATA_NIC_EFFECTIVE="${value}" ;;
    HOSTMGMT_NIC_EFFECTIVE) HOSTMGMT_NIC_EFFECTIVE="${value}" ;;
    HOST_NIC_RENAMED) HOST_NIC_RENAMED="${value}" ;;
    DATA_NIC_RENAMED) DATA_NIC_RENAMED="${value}" ;;
    HOSTMGMT_NIC_RENAMED) HOSTMGMT_NIC_RENAMED="${value}" ;;
    SPAN_NICS)      SPAN_NICS="${value}" ;;
    SENSOR_VCPUS)   SENSOR_VCPUS="${value}" ;;
    SENSOR_MEMORY_MB) SENSOR_MEMORY_MB="${value}" ;;
    SENSOR_SPAN_VF_PCIS) SENSOR_SPAN_VF_PCIS="${value}" ;;
    SPAN_ATTACH_MODE) SPAN_ATTACH_MODE="${value}" ;;
    SPAN_NIC_LIST) SPAN_NIC_LIST="${value}" ;;
    SPAN_BRIDGE_LIST) SPAN_BRIDGE_LIST="${value}" ;;
    SENSOR_NET_MODE) SENSOR_NET_MODE="${value}" ;;
    LV_LOCATION) LV_LOCATION="${value}" ;;
    LV_SIZE_GB) LV_SIZE_GB="${value}" ;;
    *)
      # Unknown keys are ignored for now (can be extended here if needed)
      ;;
  esac

  save_config
}


#######################################
# State Management
#######################################

# State file format (simple text):
# LAST_COMPLETED_STEP=01_hw_detect
# LAST_RUN_TIME=2025-11-28 20:00:00

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
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
HOST_NIC="${HOST_NIC}"
DATA_NIC="${DATA_NIC}"
HOSTMGMT_NIC="${HOSTMGMT_NIC}"
HOST_NIC_PCI="${HOST_NIC_PCI}"
HOST_NIC_MAC="${HOST_NIC_MAC}"
DATA_NIC_PCI="${DATA_NIC_PCI}"
DATA_NIC_MAC="${DATA_NIC_MAC}"
HOSTMGMT_NIC_PCI="${HOSTMGMT_NIC_PCI}"
HOSTMGMT_NIC_MAC="${HOSTMGMT_NIC_MAC}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE}"
DATA_NIC_EFFECTIVE="${DATA_NIC_EFFECTIVE}"
HOSTMGMT_NIC_EFFECTIVE="${HOSTMGMT_NIC_EFFECTIVE}"
HOSTMGMT_NIC_RENAMED="${HOSTMGMT_NIC_RENAMED}"
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
    # If nothing has been done yet, start from 0
    echo "0"
    return
  fi
  local idx
  idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
  if (( idx < 0 )); then
    # If state is unknown, start from 0 again
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
# STEP Execution (Skeleton)
#######################################

run_step() {
  local idx="$1"
  local step_id="${STEP_IDS[$idx]}"
  local step_name="${STEP_NAMES[$idx]}"
  RUN_STEP_STATUS="UNKNOWN"

  # Confirm STEP execution
  if ! whiptail_yesno "XDR Installer - ${step_id}" "${step_name}\n\nDo you want to execute this step?"
  then
    # User cancellation is considered "normal flow" (not an error)
    log "User canceled execution of STEP ${step_id}."
    RUN_STEP_STATUS="CANCELED"
    return 0   # Must return 0 here so set -e doesn't trigger in main case
  fi

  log "===== STEP START: ${step_id} - ${step_name} ====="

  local rc=0

  # Call actual function for each STEP
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
    "06_libvirt_hooks")
      step_06_libvirt_hooks || rc=$?
      ;;
    "07_sensor_download")
      step_07_sensor_download || rc=$?
      ;;
    "08_sensor_deploy")
      step_08_sensor_deploy || rc=$?
      ;;
    "09_sensor_passthrough")
      step_09_sensor_passthrough || rc=$?
      ;;
    "10_install_dp_cli")
      step_10_install_dp_cli || rc=$?
      ;;
	  
    *)
      log "ERROR: Undefined STEP ID: ${step_id}"
      rc=1
      ;;
  esac

  if [[ "${rc}" -eq 0 ]]; then
    RUN_STEP_STATUS="DONE"
    log "===== STEP DONE: ${step_id} - ${step_name} ====="
    
    # State verification summary after STEP completion
    local verification_summary=""
    case "${step_id}" in
      "02_hwe_kernel")
        local hwe_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          # Check HWE package based on Ubuntu version
          local ubuntu_version
          ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
          local expected_pkg=""
          
          case "${ubuntu_version}" in
            "20.04") expected_pkg="linux-generic-hwe-20.04" ;;
            "22.04") expected_pkg="linux-generic-hwe-22.04" ;;
            "24.04") expected_pkg="linux-generic-hwe-24.04" ;;
            *) expected_pkg="linux-generic" ;;
          esac
          
          if dpkg -l | grep -q "^ii  ${expected_pkg}"; then
            hwe_status="Installed"
          elif dpkg -l | grep -q "linux-generic-hwe"; then
            hwe_status="Installed (different version)"
          else
            hwe_status="Installation failed"
          fi
        else
          hwe_status="DRY-RUN"
        fi
        verification_summary="HWE kernel package: ${hwe_status}"
        ;;
      "03_nic_ifupdown")
        verification_summary="Network interface configuration completed (applied after reboot)"
        ;;
      "04_kvm_libvirt")
        local kvm_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if systemctl is-active libvirtd >/dev/null 2>&1; then
            kvm_status="libvirtd running"
          else
            kvm_status="libvirtd stopped"
          fi
        else
          kvm_status="DRY-RUN"
        fi
        verification_summary="KVM/libvirt: ${kvm_status}"
        ;;
      "05_kernel_tuning")
        verification_summary="Kernel tuning completed (applied after reboot)"
        ;;
      "10_sensor_deploy")
        local vm_verify="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if virsh list --all | grep -q "mds"; then
            local state=$(virsh domstate mds 2>/dev/null || echo "unknown")
            vm_verify="VM created (${state})"
          else
            vm_verify="VM creation failed"
          fi
        else
          vm_verify="DRY-RUN"
        fi
        verification_summary="Sensor VM: ${vm_verify}"
        ;;
    esac
    
    if [[ -n "${verification_summary}" ]]; then
      log "Verification result: ${verification_summary}"
    fi
    
    save_state "${step_id}"

    ###############################################
    # Common auto-reboot handling
    ###############################################
	if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
	      # Process AUTO_REBOOT_AFTER_STEP_ID to allow multiple STEP IDs separated by spaces
	      for reboot_step in ${AUTO_REBOOT_AFTER_STEP_ID}; do
	        if [[ "${step_id}" == "${reboot_step}" ]]; then
	          log "AUTO_REBOOT_AFTER_STEP_ID=${AUTO_REBOOT_AFTER_STEP_ID} (current STEP=${step_id}) is included -> performing auto-reboot."

	          whiptail_msgbox "Auto Reboot" "STEP ${step_id} (${step_name}) has been completed successfully.\n\nThe system will automatically reboot." 12 70

	          if [[ "${DRY_RUN}" -eq 1 ]]; then
	            log "[DRY-RUN] Auto-reboot will not be performed."
	            # If DRY_RUN, just exit here and continue to return 0 below
	          else
	            log "[INFO] Executing system reboot..."
	            reboot
	            # ★ In sessions that call reboot, immediately exit the entire shell
	            exit 0
	          fi

	          # If reboot was handled in this STEP, no need to check other items
	          break
	        fi
	      done
	    fi
	  else
    RUN_STEP_STATUS="FAILED"
	    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    
    # Provide log file location on failure
    local log_info=""
    if [[ -f "${LOG_FILE}" ]]; then
      log_info="\n\nCheck the detailed log: tail -f ${LOG_FILE}"
    fi
    
    whiptail_msgbox "STEP Failed - ${step_id}" "An error occurred while executing STEP ${step_id} (${step_name}).\n\nPlease check the log and re-run the STEP if necessary.\nThe installer can continue to run.${log_info}" 16 80
  fi

  # ★ run_step always returns 0 so set -e doesn't trigger here
  return 0
  }


#######################################
# Hardware Detection Utilities
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

# NIC link state helper (carrier/operstate)
get_nic_link_state() {
  step01_get_link_state "$1"
}
# NIC identity helpers (PCI/MAC/resolve)
normalize_pci() {
  local p="$1"
  if [[ -z "$p" ]]; then echo ""; return 0; fi
  if [[ "$p" =~ ^0000: ]]; then echo "$p"; return 0; fi
  echo "0000:${p}"
}

normalize_mac() {
  local mac="$1"
  [[ -z "$mac" ]] && { echo ""; return 0; }
  echo "$mac" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | sed 's/-/:/g'
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

find_if_by_pci() {
  local pci="$1"
  [[ -z "$pci" ]] && { echo ""; return 0; }
  pci="$(normalize_pci "$pci")"
  local iface name iface_pci
  for iface in /sys/class/net/*; do
    name="$(basename "$iface")"
    [[ "$name" =~ ^(lo|virbr|vnet|tap|docker|br-|ovs) ]] && continue
    iface_pci="$(get_if_pci "$name")"
    if [[ "$iface_pci" == "$pci" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
}

find_if_by_mac() {
  local mac="$1"
  [[ -z "$mac" ]] && { echo ""; return 0; }
  mac="$(normalize_mac "$mac")"
  local iface name iface_mac
  for iface in /sys/class/net/*; do
    name="$(basename "$iface")"
    [[ "$name" =~ ^(lo|virbr|vnet|tap|docker|br-|ovs) ]] && continue
    iface_mac="$(get_if_mac "$name")"
    if [[ "$iface_mac" == "$mac" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
}

resolve_ifname_by_identity() {
  local pci="$1"
  local mac="$2"
  if [[ -n "$pci" ]]; then pci="$(normalize_pci "$pci")"; fi
  if [[ -n "$mac" ]]; then mac="$(normalize_mac "$mac")"; fi
  if [[ -n "$pci" ]]; then
    local found_by_pci
    found_by_pci="$(find_if_by_pci "$pci")"
    if [[ -n "$found_by_pci" ]]; then
      echo "$found_by_pci"
      return 0
    fi
  fi
  if [[ -n "$mac" ]]; then
    local found_by_mac
    found_by_mac="$(find_if_by_mac "$mac")"
    if [[ -n "$found_by_mac" ]]; then
      echo "$found_by_mac"
      return 0
    fi
  fi
  echo ""
}

get_effective_nic() {
  local nic_type="$1"
  local effective_var="" pci_var="" mac_var="" fallback_var=""
  case "$nic_type" in
    HOST)
      effective_var="HOST_NIC_EFFECTIVE"
      pci_var="HOST_NIC_PCI"
      mac_var="HOST_NIC_MAC"
      fallback_var="HOST_NIC"
      ;;
    DATA)
      effective_var="DATA_NIC_EFFECTIVE"
      pci_var="DATA_NIC_PCI"
      mac_var="DATA_NIC_MAC"
      fallback_var="DATA_NIC"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
  local effective_name="${!effective_var:-}"
  if [[ -n "$effective_name" ]] && ip link show "$effective_name" >/dev/null 2>&1; then
    echo "$effective_name"
    return 0
  fi
  local pci_val="${!pci_var:-}"
  local mac_val="${!mac_var:-}"
  if [[ -n "$pci_val" || -n "$mac_val" ]]; then
    local resolved
    resolved="$(resolve_ifname_by_identity "$pci_val" "$mac_val")"
    if [[ -n "$resolved" ]]; then
      echo "$resolved"
      return 0
    fi
  fi
  local fallback_name="${!fallback_var:-}"
  if [[ -n "$fallback_name" ]] && ip link show "$fallback_name" >/dev/null 2>&1; then
    echo "$fallback_name"
    return 0
  fi
  echo ""
  return 1
}

#######################################
# Implementation for Each STEP
#######################################

step_01_hw_detect() {
  log "[STEP 01] Hardware / NIC / SPAN NIC Selection"

  # Load latest configuration (prevent script failure if not available)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set default values to prevent set -u (empty string if not defined)
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"
  : "${HOSTMGMT_NIC:=}"
  : "${SPAN_NICS:=}"
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"
  : "${SPAN_ATTACH_MODE:=pci}"
  : "${SENSOR_NET_MODE:=nat}"
  : "${HOSTMGMT_NIC_RENAMED:=}"
  
  # Determine network mode
  local net_mode="${SENSOR_NET_MODE}"
  log "[STEP 01] Sensor network mode: ${net_mode}"

  ########################
  # 0) Whether to reuse existing values (different conditions per network mode)
  ########################
  local can_reuse_config=0
  local reuse_message=""
  local host_display data_display hostmgmt_display
  
  # Load storage configuration values
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"
  
  : "${HOST_NIC_RENAMED:=}"
  : "${DATA_NIC_RENAMED:=}"
  : "${HOSTMGMT_NIC_RENAMED:=}"
  host_display="${HOST_NIC}"
  data_display="${DATA_NIC}"
  hostmgmt_display="${HOSTMGMT_NIC}"
  if [[ -n "${HOST_NIC_RENAMED}" && "${HOST_NIC_RENAMED}" != "${HOST_NIC}" ]]; then
    host_display="${HOST_NIC} (renamed: ${HOST_NIC_RENAMED})"
  fi
  if [[ -n "${DATA_NIC_RENAMED}" && "${DATA_NIC_RENAMED}" != "${DATA_NIC}" ]]; then
    data_display="${DATA_NIC} (renamed: ${DATA_NIC_RENAMED})"
  fi
  if [[ -n "${HOSTMGMT_NIC_RENAMED}" && "${HOSTMGMT_NIC_RENAMED}" != "${HOSTMGMT_NIC}" ]]; then
    hostmgmt_display="${HOSTMGMT_NIC} (renamed: ${HOSTMGMT_NIC_RENAMED})"
  fi

  if [[ "${net_mode}" == "bridge" ]]; then
    if [[ -n "${HOST_NIC}" && -n "${DATA_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
      can_reuse_config=1
      local span_mode_label="PF PCI (Passthrough)"
      [[ "${SPAN_ATTACH_MODE}" == "bridge" ]] && span_mode_label="Bridge (virtio)"
      reuse_message="The following values are already set:\n\n- Network mode: ${net_mode}\n- HOST NIC: ${host_display}\n- DATA NIC: ${data_display}\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: ${SPAN_ATTACH_MODE}\n- SPAN ${span_mode_label}: ${SENSOR_SPAN_VF_PCIS}"
    fi
  elif [[ "${net_mode}" == "nat" ]]; then
    if [[ -n "${HOST_NIC}" && -n "${HOSTMGMT_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
      can_reuse_config=1
      local span_mode_label="PF PCI (Passthrough)"
      [[ "${SPAN_ATTACH_MODE}" == "bridge" ]] && span_mode_label="Bridge (virtio)"
      reuse_message="The following values are already set:\n\n- Network mode: ${net_mode}\n- NAT uplink NIC: ${host_display}\n- Direct access NIC: ${hostmgmt_display}\n- DATA NIC: N/A (NAT mode)\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: ${SPAN_ATTACH_MODE}\n- SPAN ${span_mode_label}: ${SENSOR_SPAN_VF_PCIS}"
    fi
  fi
  
  if [[ "${can_reuse_config}" -eq 1 ]]; then
    # Validate that configured NICs actually exist before reusing
    # Check both original names and renamed names (after STEP 03 udev rule)
    local nic_validation_failed=0
    local missing_nics=""
    
    if [[ "${net_mode}" == "bridge" ]]; then
      # Check HOST_NIC (original or renamed)
      local host_nic_found=0
      if [[ -d "/sys/class/net/${HOST_NIC}" ]]; then
        host_nic_found=1
      elif [[ -n "${HOST_NIC_RENAMED}" ]] && [[ -d "/sys/class/net/${HOST_NIC_RENAMED}" ]]; then
        host_nic_found=1
        log "[STEP 01] HOST_NIC found with renamed name: ${HOST_NIC_RENAMED} (original: ${HOST_NIC})"
      fi
      
      if [[ ${host_nic_found} -eq 0 ]]; then
        missing_nics="${missing_nics}HOST_NIC: ${HOST_NIC}"
        if [[ -n "${HOST_NIC_RENAMED}" ]]; then
          missing_nics="${missing_nics} (renamed: ${HOST_NIC_RENAMED})\n"
        else
          missing_nics="${missing_nics}\n"
        fi
        nic_validation_failed=1
      fi
      
      # Check DATA_NIC (original or renamed)
      local data_nic_found=0
      if [[ -d "/sys/class/net/${DATA_NIC}" ]]; then
        data_nic_found=1
      elif [[ -n "${DATA_NIC_RENAMED}" ]] && [[ -d "/sys/class/net/${DATA_NIC_RENAMED}" ]]; then
        data_nic_found=1
        log "[STEP 01] DATA_NIC found with renamed name: ${DATA_NIC_RENAMED} (original: ${DATA_NIC})"
      fi
      
      if [[ ${data_nic_found} -eq 0 ]]; then
        missing_nics="${missing_nics}DATA_NIC: ${DATA_NIC}"
        if [[ -n "${DATA_NIC_RENAMED}" ]]; then
          missing_nics="${missing_nics} (renamed: ${DATA_NIC_RENAMED})\n"
        else
          missing_nics="${missing_nics}\n"
        fi
        nic_validation_failed=1
      fi
    elif [[ "${net_mode}" == "nat" ]]; then
      # Check HOST_NIC (original or renamed)
      local host_nic_found=0
      if [[ -d "/sys/class/net/${HOST_NIC}" ]]; then
        host_nic_found=1
      elif [[ -n "${HOST_NIC_RENAMED}" ]] && [[ -d "/sys/class/net/${HOST_NIC_RENAMED}" ]]; then
        host_nic_found=1
        log "[STEP 01] HOST_NIC found with renamed name: ${HOST_NIC_RENAMED} (original: ${HOST_NIC})"
      fi
      
      if [[ ${host_nic_found} -eq 0 ]]; then
        missing_nics="${missing_nics}NAT uplink NIC (HOST_NIC): ${HOST_NIC}"
        if [[ -n "${HOST_NIC_RENAMED}" ]]; then
          missing_nics="${missing_nics} (renamed: ${HOST_NIC_RENAMED})\n"
        else
          missing_nics="${missing_nics}\n"
        fi
        nic_validation_failed=1
      fi

      # Check HOSTMGMT_NIC (direct access)
      local hostmgmt_nic_found=0
      if [[ -d "/sys/class/net/${HOSTMGMT_NIC}" ]]; then
        hostmgmt_nic_found=1
      elif [[ -n "${HOSTMGMT_NIC_RENAMED}" ]] && [[ -d "/sys/class/net/${HOSTMGMT_NIC_RENAMED}" ]]; then
        hostmgmt_nic_found=1
        log "[STEP 01] HOSTMGMT_NIC found with renamed name: ${HOSTMGMT_NIC_RENAMED} (original: ${HOSTMGMT_NIC})"
      fi

      if [[ ${hostmgmt_nic_found} -eq 0 ]]; then
        missing_nics="${missing_nics}Direct access NIC (HOSTMGMT_NIC): ${HOSTMGMT_NIC}"
        if [[ -n "${HOSTMGMT_NIC_RENAMED}" ]]; then
          missing_nics="${missing_nics} (renamed: ${HOSTMGMT_NIC_RENAMED})\n"
        else
          missing_nics="${missing_nics}\n"
        fi
        nic_validation_failed=1
      fi
    fi
    
    # Validate SPAN NICs (SPAN NICs are not renamed, so check original names)
    if [[ -n "${SPAN_NICS:-}" ]]; then
      for span_nic in ${SPAN_NICS}; do
        if [[ ! -d "/sys/class/net/${span_nic}" ]]; then
          missing_nics="${missing_nics}SPAN NIC: ${span_nic}\n"
          nic_validation_failed=1
        fi
      done
    fi
    
    if [[ "${nic_validation_failed}" -eq 1 ]]; then
      local available_nics
      available_nics=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | tr '\n' ' ' || echo "none")
      
      whiptail_msgbox "STEP 01 - NIC Validation Failed" "Some configured NICs do not exist on this system:\n\n${missing_nics}\nAvailable NICs: ${available_nics}\n\nPossible reasons:\n- System was rebooted and NIC names changed\n- NICs were removed or disabled\n- Network configuration changed\n\nPlease re-select NICs in STEP 01." 18 80
      log "WARNING: Some configured NICs do not exist. Missing: ${missing_nics}"
      log "Available NICs: ${available_nics}"
      # Don't reuse, continue to selection
      can_reuse_config=0
    fi
  fi
  
  if [[ "${can_reuse_config}" -eq 1 ]]; then
    log "[STEP 01] Previous selections detected:"
    log "[STEP 01] - Network mode: ${net_mode}"
    if [[ "${net_mode}" == "bridge" ]]; then
      log "[STEP 01] - HOST NIC: ${host_display}"
      log "[STEP 01] - DATA NIC: ${data_display}"
    else
      log "[STEP 01] - NAT uplink NIC: ${host_display}"
      log "[STEP 01] - Direct access NIC: ${hostmgmt_display}"
    fi
    log "[STEP 01] - SPAN NICs: ${SPAN_NICS}"
    log "[STEP 01] - SPAN attachment mode: ${SPAN_ATTACH_MODE}"
    log "[STEP 01] - SPAN PCI/Bridge: ${SENSOR_SPAN_VF_PCIS}"
    if whiptail_yesno "STEP 01 - Reuse previous selections" "${reuse_message}\n\nDo you want to reuse these values and skip STEP 01?\n\n(Select No to choose again.)" 20 80
    then
      log "User chose to reuse existing STEP 01 selection values. (Skipping STEP 01)"

      # Ensure configuration file is updated even when reusing
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "DATA_NIC"       "${DATA_NIC}"
      save_config_var "SPAN_NICS"     "${SPAN_NICS}"
      save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
      save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"

      # Reuse means 'success + nothing more to do in this step', so return 0 normally
      return 0
    fi
  fi

  ########################
  # 1) NIC candidate  and Selection
  ########################
  local nics nic_list nic name idx

  # STEP 01 link scan: temp admin UP + ethtool detection + cleanup
  step01_prepare_link_scan || log "[STEP 01] Link scan completed with warnings (continuing)"

  # list_nic_candidates  Failed set -e  script All prevent death defense
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail_msgbox "STEP 01 - NIC Detection Failed" \
             --msgbox "No available NICs could be found.\n\nPlease check 'ip link' output and modify the script if needed." 12 70
    log "No NIC candidates found. Please check 'ip link' output."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # Each NIC assigned IP Information + ethtool Speed/Duplex display
    local ipinfo speed duplex et_out link_state

    # IP Information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Default
    speed="Unknown"
    duplex="Unknown"
    link_state="unknown"

    # Link state (from pre-scan)
    link_state="${STEP01_LINK_STATE[${name}]:-unknown}"

    # ethtool Speed / Duplex get
    if command -v ethtool >/dev/null 2>&1; then
      # set -e defense: ethtool Failed script prevent death || true
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    # whiptail menu "speed=..., duplex=..., ip=..."  display
    nic_list+=("${name}" "link=${link_state}, speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
    ((idx++))
  done <<< "${nics}"

  ########################
  # 4) NIC Selection (Network mode branch)
  ########################
  
  if [[ "${net_mode}" == "bridge" ]]; then
    # Bridge Mode: HOST NIC + DATA NIC Selection
    log "[STEP 01] Bridge Mode - Selecting HOST NIC and DATA NIC."
    
    # HOST NIC Selection
    local host_nic
    # Calculate menu size dynamically
    local menu_dims
    menu_dims=$(calc_menu_size ${#nic_list[@]} 80 10)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
    
    # Center-align menu message
    local menu_msg
    menu_msg=$(center_menu_message "Please select NIC for this KVM host access (current SSH connection).\nCurrent Configuration: ${HOST_NIC:-<None>}" "${menu_height}")
    
    host_nic=$(whiptail --title "STEP 01 - HOST NIC Selection (Bridge Mode)" \
                       --menu "${menu_msg}" \
                       "${menu_height}" "${menu_width}" "${menu_list_height}" \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User canceled HOST NIC selection."
      return 1
    }

    log "Selected HOST NIC: ${host_nic}"
    HOST_NIC="${host_nic}"
    save_config_var "HOST_NIC" "${HOST_NIC}"
    save_config_var "HOST_NIC_PCI" "$(get_if_pci "${host_nic}")"
    save_config_var "HOST_NIC_MAC" "$(get_if_mac "${host_nic}")"

    # DATA NIC Selection  
    local data_nic
    # Calculate menu size dynamically
    menu_dims=$(calc_menu_size ${#nic_list[@]} 80 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
    
    # Center-align menu message
    menu_msg=$(center_menu_message "Please select management/data NIC for Sensor VM.\nCurrent Configuration: ${DATA_NIC:-<None>}" "${menu_height}")
    
    data_nic=$(whiptail --title "STEP 01 - Data NIC Selection (Bridge Mode)" \
                       --menu "${menu_msg}" \
                       "${menu_height}" "${menu_width}" "${menu_list_height}" \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User canceled Data NIC selection."
      return 1
    }

    log "Selected Data NIC: ${data_nic}"
    DATA_NIC="${data_nic}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    save_config_var "DATA_NIC_PCI" "$(get_if_pci "${data_nic}")"
    save_config_var "DATA_NIC_MAC" "$(get_if_mac "${data_nic}")"
    
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: NAT uplink NIC (1 unit only) Selection
    log "[STEP 01] NAT Mode - Selecting NAT uplink NIC (1 unit only)."
    
    local nat_nic
    # Calculate menu size dynamically
    menu_dims=$(calc_menu_size ${#nic_list[@]} 90 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
    
    # Center-align menu message
    menu_msg=$(center_menu_message "Please select NAT Network uplink NIC.\nThis NIC will be renamed to 'mgt' for external connection.\nSensor VM will be connected to virbr0 NAT bridge.\nCurrent Configuration: ${HOST_NIC:-<None>}" "${menu_height}")
    
    nat_nic=$(whiptail --title "STEP 01 - NAT uplink NIC Selection (NAT Mode)" \
                      --menu "${menu_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
      log "User canceled NAT uplink NIC selection."
      return 1
    }

    log "Selected NAT uplink NIC: ${nat_nic}"
    HOST_NIC="${nat_nic}"  # HOST_NIC variable NAT uplink NIC store
    DATA_NIC=""  # NAT Mode - DATA NIC is not used
    save_config_var "HOST_NIC" "${HOST_NIC}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    save_config_var "HOST_NIC_PCI" "$(get_if_pci "${nat_nic}")"
    save_config_var "HOST_NIC_MAC" "$(get_if_mac "${nat_nic}")"

    # Direct access NIC (hostmgmt) selection
    local hostmgmt_nic
    menu_dims=$(calc_menu_size ${#nic_list[@]} 90 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    menu_msg=$(center_menu_message "Select NIC for direct access (management) to KVM host.\n(This NIC will be automatically configured with 192.168.0.100/24 without gateway.)\nCurrent Configuration: ${HOSTMGMT_NIC:-<None>}" "${menu_height}")

    hostmgmt_nic=$(whiptail --title "STEP 01 - Select Host Access NIC (NAT Mode)" \
                      --menu "${menu_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
      log "User canceled Host Access NIC selection."
      return 1
    }

    if [[ "${hostmgmt_nic}" == "${nat_nic}" ]]; then
      whiptail_msgbox "Error" "Direct access NIC cannot be the same as NAT uplink NIC.\n\n- NAT uplink NIC: ${nat_nic}\n- Direct access NIC: ${hostmgmt_nic}" 12 80
      log "HOSTMGMT_NIC duplicate selection: ${hostmgmt_nic}"
      return 1
    fi

    log "Selected Host Access NIC: ${hostmgmt_nic}"
    HOSTMGMT_NIC="${hostmgmt_nic}"
    save_config_var "HOSTMGMT_NIC" "${HOSTMGMT_NIC}"
    save_config_var "HOSTMGMT_NIC_PCI" "$(get_if_pci "${hostmgmt_nic}")"
    save_config_var "HOSTMGMT_NIC_MAC" "$(get_if_mac "${hostmgmt_nic}")"
    
  else
    log "ERROR: Unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail_msgbox "Configuration Error" "Unknown sensor network mode: ${net_mode}\n\nPlease select a valid mode (bridge or nat) in environment configuration."
    return 1
  fi

  ########################
  # 5) SPAN NIC Selection (can Selection)
  ########################
  # Build a set of currently visible NICs for quick lookup
  local visible_nics=""
  while IFS= read -r name; do
    visible_nics="${visible_nics} ${name}"
  done <<< "${nics}"
  visible_nics="${visible_nics# }"  # Remove leading space
  
  # Add stored SPAN NICs that are not currently visible (e.g., PCI passthrough to VM)
  local stored_span_nics_not_visible=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    for stored_nic in ${SPAN_NICS}; do
      # Check if this stored NIC is in the visible list
      local is_visible=0
      for visible_nic in ${visible_nics}; do
        if [[ "${stored_nic}" == "${visible_nic}" ]]; then
          is_visible=1
          break
        fi
      done
      
      # If not visible, add to the list of stored but not visible NICs
      if [[ ${is_visible} -eq 0 ]]; then
        stored_span_nics_not_visible="${stored_span_nics_not_visible} ${stored_nic}"
      fi
    done
    stored_span_nics_not_visible="${stored_span_nics_not_visible# }"  # Remove leading space
  fi
  
  # Build SPAN NIC list: first visible NICs, then stored but not visible NICs
  local span_nic_list=()
  
  # Add currently visible NICs
  while IFS= read -r name; do
    # Each NIC assigned IP Information + ethtool Speed/Duplex display
    local ipinfo speed duplex et_out link_state

    # IP Information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Default
    speed="Unknown"
    duplex="Unknown"
    link_state="unknown"

    # Link state (from pre-scan)
    link_state="${STEP01_LINK_STATE[${name}]:-unknown}"

    # ethtool Speed / Duplex get
    if command -v ethtool >/dev/null 2>&1; then
      # set -e defense: ethtool Failed script prevent death || true
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    # Mark existing selected SPAN_NIC as ON, others as OFF
    local flag="OFF"
    for s in ${SPAN_NICS}; do
      if [[ "${s}" == "${name}" ]]; then
        flag="ON"
        break
      fi
    done
    span_nic_list+=("${name}" "link=${link_state}, speed=${speed}, duplex=${duplex}, ip=${ipinfo}" "${flag}")
  done <<< "${nics}"
  
  # Add stored but not visible NICs (e.g., PCI passthrough to VM)
  if [[ -n "${stored_span_nics_not_visible}" ]]; then
    for stored_nic in ${stored_span_nics_not_visible}; do
      # For stored NICs that are not visible, mark as ON and show as stored
      span_nic_list+=("${stored_nic}" "(stored, not visible - PCI passthrough to VM)" "ON")
      log "[STEP 01] Adding stored SPAN NIC to selection list: ${stored_nic} (not currently visible, likely PCI passthrough to VM)"
    done
  fi

  local selected_span_nics
  # Calculate menu size dynamically for checklist
  menu_dims=$(calc_menu_size ${#span_nic_list[@]} 80 10)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align menu message
  menu_msg=$(center_menu_message "Please select NIC(s) for Sensor SPAN.\n(Minimum 1 NIC selection required)\n\nCurrent Selection: ${SPAN_NICS:-<None>}" "${menu_height}")
  
  selected_span_nics=$(whiptail --title "STEP 01 - SPAN NIC Selection" \
                                --checklist "${menu_msg}" \
                                "${menu_height}" "${menu_width}" "${menu_list_height}" \
                                "${span_nic_list[@]}" \
                                3>&1 1>&2 2>&3) || {
    log "User canceled SPAN NIC selection."
    return 1
  }

  # Remove quotes from whiptail output (e.g., "nic1" "nic2" -> nic1 nic2)
  selected_span_nics=$(echo "${selected_span_nics}" | tr -d '"')

  if [[ -z "${selected_span_nics}" ]]; then
    whiptail_msgbox "SPAN NIC Selection Required" "No SPAN NICs selected.\nAt least 1 SPAN NIC is required." 10 70
    log "SPAN NIC selection is required but none selected."
    return 1
  fi
  # Prevent using direct access NIC as SPAN NIC (NAT mode only)
  if [[ "${net_mode}" == "nat" && -n "${HOSTMGMT_NIC:-}" ]]; then
    for s in ${selected_span_nics}; do
      if [[ "${s}" == "${HOSTMGMT_NIC}" ]]; then
        whiptail_msgbox "SPAN NIC Selection Error" "Direct access NIC cannot be selected as SPAN NIC.\n\nDirect access NIC: ${HOSTMGMT_NIC}\nSelected SPAN NIC: ${s}" 12 80
        log "SPAN NIC selection includes HOSTMGMT_NIC: ${s}"
        return 1
      fi
    done
    # Also prevent physical NIC overlap by PCI (direct access NIC vs SPAN NIC)
    local hostmgmt_pci
    hostmgmt_pci="$(get_if_pci "${HOSTMGMT_NIC}")"
    if [[ -n "${hostmgmt_pci}" ]]; then
      for s in ${selected_span_nics}; do
        local span_pci
        span_pci="$(get_if_pci "${s}")"
        if [[ -n "${span_pci}" && "${span_pci}" == "${hostmgmt_pci}" ]]; then
          whiptail_msgbox "SPAN NIC Selection Error" "Direct access NIC and SPAN NIC cannot be the same physical device.\n\nDirect access PCI: ${hostmgmt_pci}\nSPAN NIC: ${s} (PCI: ${span_pci})" 12 85
          log "SPAN NIC selection overlaps HOSTMGMT_NIC by PCI: ${span_pci}"
          return 1
        fi
      done
    fi
  fi

  log "Selected SPAN NICs: ${selected_span_nics}"
  SPAN_NICS="${selected_span_nics}"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  ########################
  # 6) SPAN NIC configuration (PCI passthrough or Bridge mode)
  ########################
  # SPAN_ATTACH_MODE is already set from configuration (default: pci)
  # Do not override user's selection
  
  local span_pci_list=""

  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    # PCI passthrough mode: Use Physical Function (PF) PCI address
    log "[STEP 01] SPAN attachment mode: PCI passthrough (PF direct assignment)"
    log "[STEP 01] Detecting SPAN NIC PCI addresses (PF)."
    
    # Keep track of which NICs we successfully detected PCI for
    local detected_nics=""
    local undetected_nics=""
    
    for nic in ${SPAN_NICS}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')

      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address could not be found (NIC may be PCI passthrough to VM or not exist)."
        undetected_nics="${undetected_nics} ${nic}"
        continue
      fi

      span_pci_list="${span_pci_list} ${pci_addr}"
      detected_nics="${detected_nics} ${nic}"
      log "[STEP 01] ${nic} (SPAN NIC) -> Physical PCI: ${pci_addr}"
    done
    
    # For NICs that couldn't be detected (likely PCI passthrough to VM),
    # preserve their PCI addresses from existing SENSOR_SPAN_VF_PCIS if available
    # Note: We can't directly map NIC name to PCI, so we preserve all existing PCIs
    # and let STEP 09 handle cleanup of removed NICs
    if [[ -n "${undetected_nics}" && -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
      log "[STEP 01] Some SPAN NICs are not visible (likely PCI passthrough to VM): ${undetected_nics}"
      log "[STEP 01] Preserving existing PCI addresses. STEP 09 will handle cleanup of removed NICs."
      # Add existing PCIs that aren't already in the new list
      for existing_pci in ${SENSOR_SPAN_VF_PCIS}; do
        # Check if this PCI is already in our new list
        local pci_already_included=0
        for new_pci in ${span_pci_list}; do
          if [[ "${existing_pci}" == "${new_pci}" ]]; then
            pci_already_included=1
            break
          fi
        done
        # If not already included, preserve it (might be for an undetected NIC)
        if [[ ${pci_already_included} -eq 0 ]]; then
          span_pci_list="${span_pci_list} ${existing_pci}"
          log "[STEP 01] Preserved existing PCI address: ${existing_pci} (for undetected NIC)"
        fi
      done
    fi

    # Store PCI addresses
    SENSOR_SPAN_VF_PCIS="${span_pci_list# }"  # Remove leading space
    save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
    log "SPAN NIC PCI addresses stored: ${SENSOR_SPAN_VF_PCIS}"
    if [[ -n "${undetected_nics}" ]]; then
      log "[STEP 01] Note: Some NICs could not be detected. STEP 09 will verify and clean up unused PCI addresses."
    fi
    
  elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    # Bridge mode: Create bridge interfaces (will be done in STEP 03)
    log "[STEP 01] SPAN attachment mode: Bridge (L2 bridge virtio)"
    log "[STEP 01] SPAN bridges will be created in STEP 03"
    
    # Bridge list will be created in STEP 03, not here
    # Just ensure SENSOR_SPAN_VF_PCIS is empty for bridge mode
    SENSOR_SPAN_VF_PCIS=""
    save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
  else
    log "WARNING: Unknown SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE}, defaulting to pci"
    SPAN_ATTACH_MODE="pci"
  fi
  
  # Store SPAN NIC list and connection mode
  SPAN_NIC_LIST="${SPAN_NICS}"  # Use SPAN_NICS value
  save_config_var "SPAN_NIC_LIST" "${SPAN_NIC_LIST}"
  save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
  log "SPAN NIC list stored: ${SPAN_NIC_LIST}"
  log "SPAN connection mode: ${SPAN_ATTACH_MODE}"

  ########################
  # 7) Summary display (varies by network mode)
  ########################
  local summary
  local span_info_label=""
  local span_info_value=""
  
  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    span_info_label="SPAN NIC PCIs (PF Passthrough)"
    span_info_value="${SENSOR_SPAN_VF_PCIS}"
  elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    span_info_label="SPAN Bridges"
    # SPAN_BRIDGE_LIST will be created in STEP 03, show placeholder or empty
    if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
      span_info_value="${SPAN_BRIDGE_LIST}"
    else
      span_info_value="(will be created in STEP 03)"
    fi
  else
    span_info_label="SPAN Configuration"
    span_info_value="Unknown mode"
  fi

  if [[ "${net_mode}" == "bridge" ]]; then
    summary=$(cat <<EOF
[STEP 01 Result Summary - Bridge Mode]

- Sensor Network Mode : ${net_mode}
- Host NIC         : ${HOST_NIC}
- Data NIC         : ${DATA_NIC}
- SPAN NICs       : ${SPAN_NICS}
- SPAN connection Mode    : ${SPAN_ATTACH_MODE}
- ${span_info_label}     : ${span_info_value}

Configuration File: ${CONFIG_FILE}
EOF
)
  elif [[ "${net_mode}" == "nat" ]]; then
    summary=$(cat <<EOF
[STEP 01 Result Summary - NAT Mode]

- Sensor Network Mode : ${net_mode}
- NAT uplink NIC     : ${HOST_NIC}
- Direct access NIC  : ${HOSTMGMT_NIC} (will set 192.168.0.100/24, no gateway in STEP 03)
- Data NIC         : N/A (NAT Mode - using virbr0)
- SPAN NICs       : ${SPAN_NICS}
- SPAN connection Mode    : ${SPAN_ATTACH_MODE}
- ${span_info_label}     : ${span_info_value}

Configuration File: ${CONFIG_FILE}
EOF
)
  else
    summary="[STEP 01 Result Summary]

unknown Network Mode: ${net_mode}
"
  fi

  whiptail_msgbox "STEP 01 Completed" "${summary}" 18 80

  ### Step 5 (Selection): Save configuration values
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  # Save state after STEP success
}


step_02_hwe_kernel() {
  log "[STEP 02] HWE kernel Installation"
  load_config

  #######################################
  # 0) Check Ubuntu version and HWE package
  #######################################
  local ubuntu_version pkg_name
  ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
  
  case "${ubuntu_version}" in
    "20.04")
      pkg_name="linux-generic-hwe-20.04"
      ;;
    "22.04")
      pkg_name="linux-generic-hwe-22.04"
      ;;
    "24.04")
      pkg_name="linux-generic-hwe-24.04"
      ;;
    *)
      log "[WARN] Unsupported Ubuntu version: ${ubuntu_version}. Using default kernel."
      pkg_name="linux-generic"
      ;;
  esac
  
  log "[STEP 02] Ubuntu ${ubuntu_version} detected, HWE package: ${pkg_name}"
  local tmp_status="/tmp/xdr_step02_status.txt"

  #######################################
  # 1) Current kernel / package status check
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
    echo "STEP 02 - HWE Kernel Installation Overview"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
      echo
    fi
    echo "📊 CURRENT STATUS:"
    echo "  • Current kernel (uname -r): ${cur_kernel}"
    echo "  • HWE kernel status: ${hwe_installed}"
    if [[ "${hwe_installed}" == "yes" ]]; then
      echo "    ✅ ${hwe_status_detail}"
    else
      echo "    ⚠️  ${hwe_status_detail}"
      echo "    Expected package: ${pkg_name}"
    fi
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "📋 SIMULATED EXECUTION STEPS:"
      echo "  1) apt update (simulated)"
      echo "  2) apt full-upgrade -y (simulated)"
      echo "  3) ${pkg_name} Installation (simulated, skip if already installed)"
      echo
      echo "ℹ️  In real execution mode:"
      echo "  • HWE kernel package would be installed"
      echo "  • New kernel would be available but NOT yet active"
      echo "  • Kernel would become active after reboot"
    else
      echo "📋 EXECUTION STEPS:"
      echo "  1) apt update"
      echo "  2) apt full-upgrade -y"
      echo "  3) ${pkg_name} Installation (skip if already installed)"
    fi
    echo
    echo "📝 IMPORTANT NOTES:"
    echo "  • HWE kernel will be applied after next reboot"
    echo "    (uname -r output may not change until after reboot)"
    echo
    echo "  • After STEP 03 (NIC/Network configuration) completes,"
    echo "    the system will automatically reboot"
    echo "    The new HWE kernel will be applied during that reboot"
  } > "${tmp_status}"


  # ... cur_kernel, hwe_installed  after, unit textbox   add ...

  if [[ "${hwe_installed}" == "yes" ]]; then
    local skip_msg="HWE kernel is already detected on this system.\n\n"
    skip_msg+="Status: ${hwe_status_detail}\n"
    skip_msg+="Current kernel: ${cur_kernel}\n\n"
    skip_msg+="Do you want to skip this STEP?\n\n"
    skip_msg+="(Yes: Skip / No: Continue with package update and verification)"
    if ! whiptail_yesno "STEP 02 - HWE Kernel Already Detected" "${skip_msg}" 18 80
    then
      log "User chose to skip STEP 02 entirely (HWE kernel already detected: ${hwe_status_detail})."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE kernel Installation unit" "${tmp_status}"

  if ! whiptail_yesno "STEP 02 Execution Confirmation" "Do you want to proceed?\n\n(Yes: Continue / No: Cancel)" 12 70
  then
    log "User canceled STEP 02 execution."
    return 0
  fi


  #######################################
  # 1) apt update / full-upgrade
  #######################################
  log "[STEP 02] Executing apt update / full-upgrade"
  
  echo "=== Package update in progress ==="
  log "Updating package lists..."
  run_cmd "sudo apt update"
  
  echo "=== System upgrade in progress (this may take some time) ==="
  log "Upgrading all packages to latest versions..."
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y"
    echo "=== System upgrade completed ==="

  #######################################
  # 1-1) Install ifupdown / net-tools (required for STEP 03)
  #######################################
  echo "=== Network package installation in progress ==="
  log "[STEP 02] Installing ifupdown and net-tools"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ifupdown net-tools"

  #######################################
  # 2) HWE kernel package Installation
  #######################################
  if [[ "${hwe_installed}" == "yes" ]]; then
    log "[STEP 02] ${pkg_name} package already installed -> skipping installation step"
  else
    echo "=== HWE kernel package installation in progress (this may take some time) ==="
    log "[STEP 02] Installing ${pkg_name} package..."
    log "Installing Hardware Enablement (HWE) kernel package for latest hardware support."
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg_name}"
    echo "=== HWE kernel package installation completed ==="
  fi

  #######################################
  # 3) Installation after Status Summary
  #######################################
  local new_kernel hwe_now hwe_now_detail
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # DRY-RUN Mode - Use existing uname -r and installation status
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
    hwe_now_detail="${hwe_status_detail}"
  else
    # Check current kernel and HWE package installation status
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
    echo "STEP 02 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • Previous kernel: ${cur_kernel}"
      echo "  • Current kernel:  ${cur_kernel} (unchanged in DRY-RUN)"
      echo "  • HWE kernel status: ${hwe_now}"
      if [[ "${hwe_now}" == "yes" ]]; then
        echo "    ✅ ${hwe_now_detail}"
      else
        echo "    ⚠️  ${hwe_now_detail}"
        echo "    Expected package: ${pkg_name}"
      fi
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. apt update and full-upgrade would be executed"
      echo "  2. ${pkg_name} package would be installed"
      echo "  3. HWE kernel would be installed but NOT yet active"
      echo "  4. New HWE kernel would become active after reboot"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 KERNEL STATUS:"
      echo "  • Previous kernel: ${cur_kernel}"
      echo "  • Current kernel:  ${new_kernel}"
      echo "  • HWE kernel status: ${hwe_now}"
      if [[ "${hwe_now}" == "yes" ]]; then
        echo "    ✅ ${hwe_now_detail}"
      else
        echo "    ⚠️  ${hwe_now_detail}"
        echo "    Expected package: ${pkg_name}"
        echo "    Note: HWE kernel will be active after reboot"
      fi
      echo
    fi
    echo
    echo "📝 IMPORTANT NOTES:"
    echo "  • HWE kernel will be applied after next reboot"
    echo "    (uname -r output may not change until after reboot)"
    echo
    echo "  • After STEP 03 (NIC/Network configuration) completes,"
    echo "    the system will automatically reboot"
    echo "    The new HWE kernel will be applied during that reboot"
    echo
    echo "💡 TIP: After reboot, verify the new kernel with:"
    echo "   uname -r"
  } > "${tmp_status}"


  show_textbox "STEP 02 Result Summary" "${tmp_status}"

  # Reboot will be performed after STEP 05 completes, only if AUTO_REBOOT_AFTER_STEP_ID is configured
  log "[STEP 02] HWE kernel installation step completed. HWE kernel will be applied after next reboot."

  return 0
}


step_03_nic_ifupdown() {
  log "[STEP 03] NIC naming/ifupdown transition and Network Configuration"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 03] Sensor Network Mode: ${net_mode}"

  # mode branch Execution
  if [[ "${net_mode}" == "bridge" ]]; then
    log "[STEP 03] Bridge Mode - Configuring existing L2 bridge method"
    step_03_bridge_mode
    return $?
  elif [[ "${net_mode}" == "nat" ]]; then
    log "[STEP 03] NAT Mode - Configuring OpenXDR NAT method"
    step_03_nat_mode 
    return $?
  else
    log "ERROR: Unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail_msgbox "Network Mode Error" "Unknown sensor network mode: ${net_mode}\n\nPlease select a valid mode (bridge or nat) in environment configuration."
    return 1
  fi
}

#######################################
# STEP 03 - Bridge Mode (Existing Sensor script )
#######################################
step_03_bridge_mode_declarative() {
  log "[STEP 03 Bridge Mode] Declarative bridge configuration (no runtime ip changes)"
  load_config

  if [[ -z "${HOST_NIC:-}" || -z "${DATA_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Configured" "HOST_NIC or DATA_NIC is not configured.\n\nPlease select NICs in STEP 01." 12 70
    log "HOST_NIC or DATA_NIC not configured. Cannot proceed with STEP 03 Bridge Mode."
    return 1
  fi

  cidr_to_netmask() {
    local pfx="$1"
    local mask=$(( 0xffffffff << (32-pfx) & 0xffffffff ))
    printf "%d.%d.%d.%d\n" \
      $(( (mask>>24) & 255 )) $(( (mask>>16) & 255 )) $(( (mask>>8) & 255 )) $(( mask & 255 ))
  }

  parse_host_from_interfaces() {
    local f="/etc/network/interfaces"
    local fd="/etc/network/interfaces.d"
    local ip="" netmask="" gw="" dns=""

    if [[ -f "${fd}/01-host.cfg" ]]; then
      ip="$(awk '/^[[:space:]]*address[[:space:]]+/{print $2; exit}' "${fd}/01-host.cfg" 2>/dev/null || true)"
      netmask="$(awk '/^[[:space:]]*netmask[[:space:]]+/{print $2; exit}' "${fd}/01-host.cfg" 2>/dev/null || true)"
      gw="$(awk '/^[[:space:]]*gateway[[:space:]]+/{print $2; exit}' "${fd}/01-host.cfg" 2>/dev/null || true)"
      dns="$(awk '/^[[:space:]]*dns-nameservers[[:space:]]+/{sub(/^[[:space:]]*dns-nameservers[[:space:]]+/,""); print; exit}' "${fd}/01-host.cfg" 2>/dev/null || true)"
    fi

    if [[ -z "${ip}" && -f "${f}" ]]; then
      ip="$(awk '$1=="iface" && $2=="host" {in=1} in && $1=="address" {print $2; exit}' "${f}" 2>/dev/null || true)"
      netmask="$(awk '$1=="iface" && $2=="host" {in=1} in && $1=="netmask" {print $2; exit}' "${f}" 2>/dev/null || true)"
      gw="$(awk '$1=="iface" && $2=="host" {in=1} in && $1=="gateway" {print $2; exit}' "${f}" 2>/dev/null || true)"
      dns="$(awk '$1=="iface" && $2=="host" {in=1} in && $1=="dns-nameservers" {sub(/^dns-nameservers[[:space:]]+/,""); print; exit}' "${f}" 2>/dev/null || true)"
    fi

    echo "${ip}|${netmask}|${gw}|${dns}"
  }

  local desired_host_if desired_data_if
  desired_host_if="$(resolve_ifname_by_identity "${HOST_NIC_PCI:-}" "${HOST_NIC_MAC:-}")"
  desired_data_if="$(resolve_ifname_by_identity "${DATA_NIC_PCI:-}" "${DATA_NIC_MAC:-}")"
  [[ -z "${desired_host_if}" ]] && desired_host_if="${HOST_NIC}"
  [[ -z "${desired_data_if}" ]] && desired_data_if="${DATA_NIC}"

  if [[ ! -d "/sys/class/net/${desired_host_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "HOST_NIC '${desired_host_if}' does not exist on this system.\n\nRe-run STEP 01 and select the correct NIC." 12 70
    log "ERROR: HOST_NIC '${desired_host_if}' not found in /sys/class/net"
    return 1
  fi
  if [[ ! -d "/sys/class/net/${desired_data_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "DATA_NIC '${desired_data_if}' does not exist on this system.\n\nRe-run STEP 01 and select the correct NIC." 12 70
    log "ERROR: DATA_NIC '${desired_data_if}' not found in /sys/class/net"
    return 1
  fi

  local host_pci data_pci
  host_pci="${HOST_NIC_PCI:-}"
  data_pci="${DATA_NIC_PCI:-}"
  [[ -z "${host_pci}" ]] && host_pci="$(readlink -f "/sys/class/net/${desired_host_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  [[ -z "${data_pci}" ]] && data_pci="$(readlink -f "/sys/class/net/${desired_data_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  if [[ -z "${host_pci}" || -z "${data_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI Information Error" "Could not retrieve PCI bus information for HOST_NIC or DATA_NIC.\n\nHOST: ${desired_host_if} (PCI: ${host_pci:-?})\nDATA: ${desired_data_if} (PCI: ${data_pci:-?})\n\nPlease re-run STEP 01." 14 80
    log "ERROR: PCI information missing for host/data NIC"
    return 1
  fi

  local span_udev_rules=""
  local span_nic_list_to_use="${SPAN_NIC_LIST:-${SPAN_NICS}}"
  if [[ -n "${span_nic_list_to_use}" ]]; then
    for span_nic in ${span_nic_list_to_use}; do
      local span_pci
      if [[ -d "/sys/class/net/${span_nic}" ]]; then
        span_pci="$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
        if [[ -n "${span_pci}" ]]; then
          span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci}
ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
        fi
      fi
    done
  fi

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_lib_file="/usr/lib/udev/rules.d/99-custom-ifnames.rules"
  local udev_content
  udev_content=$(cat <<EOF
# Host & Data Interface custom names (Declarative)
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${host_pci}", NAME:="host"
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${data_pci}", NAME:="data"${span_udev_rules}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${udev_file} will be created with the following content:\n${udev_content}"
    log "[DRY-RUN] ${udev_lib_file} will be created with the following content:\n${udev_content}"
    log "[DRY-RUN] Would run: sudo update-initramfs -u -k all"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
    printf "%s\n" "${udev_content}" > "${udev_lib_file}"
    chmod 644 "${udev_file}" || true
    chmod 644 "${udev_lib_file}" || true
    log "[STEP 03] Updating initramfs to apply udev rename on reboot"
    run_cmd "sudo update-initramfs -u -k all"
  fi

  save_config_var "HOST_NIC_EFFECTIVE" "host"
  save_config_var "HOST_NIC" "host"
  save_config_var "HOST_NIC_RENAMED" "host"
  save_config_var "DATA_NIC_EFFECTIVE" "data"
  save_config_var "DATA_NIC" "data"
  save_config_var "DATA_NIC_RENAMED" "data"

  local parsed ip0 nm0 gw0 dns0
  parsed="$(parse_host_from_interfaces)"
  ip0="${parsed%%|*}"; parsed="${parsed#*|}"
  nm0="${parsed%%|*}"; parsed="${parsed#*|}"
  gw0="${parsed%%|*}"; parsed="${parsed#*|}"
  dns0="${parsed}"

  local def_ip="${HOST_IP_ADDR:-$ip0}"
  local def_prefix="${HOST_IP_PREFIX:-24}"
  local def_gw="${HOST_GW:-$gw0}"
  local def_dns="${HOST_DNS:-$dns0}"
  [[ -z "${def_dns}" ]] && def_dns="8.8.8.8 8.8.4.4"

  local new_ip new_prefix new_gw new_dns
  new_ip="$(whiptail_inputbox "STEP 03 - HOST IP Configuration" "Enter HOST interface IP address:\nExample: 10.4.0.210" "${def_ip}" 10 60)" || return 1
  [[ -z "${new_ip}" ]] && return 1
  new_prefix="$(whiptail_inputbox "STEP 03 - HOST Prefix" "Enter prefix (CIDR notation):\nExample: 24" "${def_prefix}" 10 60)" || return 1
  [[ -z "${new_prefix}" ]] && return 1
  new_gw="$(whiptail_inputbox "STEP 03 - Gateway" "Enter default gateway IP:\nExample: 10.4.0.254" "${def_gw}" 10 60)" || return 1
  [[ -z "${new_gw}" ]] && return 1
  new_dns="$(whiptail_inputbox "STEP 03 - DNS" "Enter DNS server IPs (space-separated):\nExample: 8.8.8.8 8.8.4.4" "${def_dns}" 10 70)" || return 1
  [[ -z "${new_dns}" ]] && return 1

  local netmask
  netmask="$(cidr_to_netmask "${new_prefix}")"

  save_config_var "HOST_IP_ADDR" "${new_ip}"
  save_config_var "HOST_IP_PREFIX" "${new_prefix}"
  save_config_var "HOST_GW" "${new_gw}"
  save_config_var "HOST_DNS" "${new_dns}"

  local iface_file="/etc/network/interfaces"
  local iface_dir="/etc/network/interfaces.d"
  local host_cfg="${iface_dir}/01-host.cfg"
  local data_cfg="${iface_dir}/00-data.cfg"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  local iface_content
  iface_content=$(cat <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${iface_file} will be created with the following content:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  local host_content
  host_content=$(cat <<EOF
auto host
iface host inet static
    address ${new_ip}
    netmask ${netmask}
    gateway ${new_gw}
    dns-nameservers ${new_dns}
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${host_cfg} will be created with the following content:\n${host_content}"
  else
    printf "%s\n" "${host_content}" > "${host_cfg}"
  fi

  local data_content
  data_content=$(cat <<EOF
auto br-data
iface br-data inet manual
    bridge_ports data
    bridge_stp off
    bridge_fd 0
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${data_cfg} will be created with the following content:\n${data_content}"
  else
    printf "%s\n" "${data_content}" > "${data_cfg}"
  fi

  local span_attach_mode="${SPAN_ATTACH_MODE:-pci}"
  if [[ "${span_attach_mode}" == "bridge" ]]; then
    if [[ -n "${span_nic_list_to_use}" ]]; then
      local span_index=0
      for span_nic in ${span_nic_list_to_use}; do
        local bridge_name="br-span${span_index}"
        local span_cfg="${iface_dir}/01-span${span_index}.cfg"
        local span_content
        span_content=$(cat <<EOF
auto ${bridge_name}
iface ${bridge_name} inet manual
    bridge_ports ${span_nic}
    bridge_stp off
    bridge_fd 0
EOF
)
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] ${span_cfg} will be created with the following content:\n${span_content}"
        else
          printf "%s\n" "${span_content}" > "${span_cfg}"
        fi
        span_index=$((span_index + 1))
      done
    fi
  else
    if [[ "${DRY_RUN}" -ne 1 ]]; then
      rm -f "${iface_dir}/01-span"*.cfg 2>/dev/null || true
    fi
    save_config_var "SPAN_BRIDGES" ""
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    local verify_failed=0
    local verify_errors=""
    if [[ ! -f "${udev_file}" ]] || [[ ! -f "${udev_lib_file}" ]]; then
      verify_failed=1
      verify_errors="${verify_errors}\n- udev rules missing"
    fi
    # NAT mode udev mapping verification is handled in STEP 03 NAT mode
    if [[ ! -f "${iface_file}" ]] || \
       ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' "${iface_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- /etc/network/interfaces missing source line"
    fi
    if [[ ! -f "${host_cfg}" ]] || ! grep -qE '^[[:space:]]*iface[[:space:]]+host[[:space:]]+inet[[:space:]]+static' "${host_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- host config invalid: ${host_cfg}"
    fi
    if [[ ! -f "${data_cfg}" ]] || ! grep -qE '^[[:space:]]*bridge_ports[[:space:]]+data' "${data_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- data bridge config invalid: ${data_cfg}"
    fi
    if [[ "${verify_failed}" -eq 1 ]]; then
      whiptail_msgbox "STEP 03 - File Verification Failed" "Configuration file verification failed.\n\n${verify_errors}\n\nPlease check the files and re-run the step." 16 85
      log "[ERROR] STEP 03 file verification failed:${verify_errors}"
      return 1
    fi
  fi

  log "[STEP 03] Install ifupdown and disable netplan (no restart)"
  local missing_pkgs=()
  dpkg -s ifupdown >/dev/null 2>&1 || missing_pkgs+=("ifupdown")
  dpkg -s net-tools >/dev/null 2>&1 || missing_pkgs+=("net-tools")
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    run_cmd "sudo apt update"
    run_cmd "sudo apt install -y ${missing_pkgs[*]}"
  fi

  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    run_cmd "sudo mkdir -p /etc/netplan/disabled"
    run_cmd "sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
  fi

  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"
  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"

  local summary
  summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 03: Bridge Mode Configuration - Complete (Declarative)
═══════════════════════════════════════════════════════════

✅ FILES WRITTEN (no runtime changes):
* HOST NIC (renamed to host): ${HOST_NIC}
* DATA NIC (renamed to data): ${DATA_NIC}
* HOST IP: ${new_ip}/${new_prefix} (netmask ${netmask})
* Gateway: ${new_gw}
* DNS: ${new_dns}
* Bridge: br-data (L2-only)

📂 Files:
1. udev: /etc/udev/rules.d/99-custom-ifnames.rules
2. udev: /usr/lib/udev/rules.d/99-custom-ifnames.rules
3. /etc/network/interfaces
4. /etc/network/interfaces.d/01-host.cfg
5. /etc/network/interfaces.d/00-data.cfg

⚠️ REBOOT REQUIRED
Network configuration changes will be applied after reboot.
EOF
)

  whiptail_msgbox "STEP 03 complete" "${summary}" 20 80
  log "[STEP 03] Bridge mode configuration completed. Reboot required."
  return 0
}

step_03_bridge_mode() {
  step_03_bridge_mode_declarative
  return $?
}

#######################################
# STEP 03 - NAT Mode (OpenXDR NAT Configuration )
#######################################
step_03_nat_mode_declarative() {
  log "[STEP 03 NAT Mode] Declarative NAT configuration (no runtime ip changes)"
  load_config

  if [[ -z "${HOST_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - NAT NIC Not configured" "NAT uplink NIC (HOST_NIC) is not set.\n\nPlease select NAT uplink NIC in STEP 01 first." 12 70
    log "HOST_NIC (NAT uplink NIC) is empty, so STEP 03 NAT Mode cannot proceed."
    return 1
  fi
  if [[ -z "${HOSTMGMT_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - Direct Access NIC Not configured" "Direct access NIC (HOSTMGMT_NIC) is not set.\n\nPlease select direct access NIC in STEP 01 first." 12 70
    log "HOSTMGMT_NIC (direct access NIC) is empty, so STEP 03 NAT Mode cannot proceed."
    return 1
  fi

  cidr_to_netmask() {
    local pfx="$1"
    local mask=$(( 0xffffffff << (32-pfx) & 0xffffffff ))
    printf "%d.%d.%d.%d\n" \
      $(( (mask>>24) & 255 )) $(( (mask>>16) & 255 )) $(( (mask>>8) & 255 )) $(( mask & 255 ))
  }

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
      ip="$(awk '$1=="iface" && $2=="mgt" {in=1} in && $1=="address" {print $2; exit}' "${f}" 2>/dev/null || true)"
      netmask="$(awk '$1=="iface" && $2=="mgt" {in=1} in && $1=="netmask" {print $2; exit}' "${f}" 2>/dev/null || true)"
      gw="$(awk '$1=="iface" && $2=="mgt" {in=1} in && $1=="gateway" {print $2; exit}' "${f}" 2>/dev/null || true)"
      dns="$(awk '$1=="iface" && $2=="mgt" {in=1} in && $1=="dns-nameservers" {sub(/^dns-nameservers[[:space:]]+/,""); print; exit}' "${f}" 2>/dev/null || true)"
    fi

    echo "${ip}|${netmask}|${gw}|${dns}"
  }

  local desired_host_if
  desired_host_if="$(resolve_ifname_by_identity "${HOST_NIC_PCI:-}" "${HOST_NIC_MAC:-}")"
  [[ -z "${desired_host_if}" ]] && desired_host_if="${HOST_NIC}"

  if [[ ! -d "/sys/class/net/${desired_host_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "NAT uplink NIC '${desired_host_if}' does not exist on this system.\n\nRe-run STEP 01 and select the correct NIC." 12 70
    log "ERROR: NAT uplink NIC '${desired_host_if}' not found in /sys/class/net"
    return 1
  fi

  local desired_hostmgmt_if
  desired_hostmgmt_if="$(resolve_ifname_by_identity "${HOSTMGMT_NIC_PCI:-}" "${HOSTMGMT_NIC_MAC:-}")"
  [[ -z "${desired_hostmgmt_if}" ]] && desired_hostmgmt_if="${HOSTMGMT_NIC}"

  if [[ ! -d "/sys/class/net/${desired_hostmgmt_if}" ]]; then
    whiptail_msgbox "STEP 03 - NIC Not Found" "Direct access NIC '${desired_hostmgmt_if}' does not exist on this system.\n\nRe-run STEP 01 and select the correct NIC." 12 70
    log "ERROR: Direct access NIC '${desired_hostmgmt_if}' not found in /sys/class/net"
    return 1
  fi

  local nat_pci
  nat_pci="${HOST_NIC_PCI:-}"
  if [[ -z "${nat_pci}" ]]; then
    nat_pci="$(readlink -f "/sys/class/net/${desired_host_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  fi
  if [[ -z "${nat_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI Information Error" "Could not retrieve PCI bus information for NAT uplink NIC.\n\nNIC: ${desired_host_if}\n\nPlease re-run STEP 01 to verify and select the correct NIC." 14 80
    log "ERROR: NAT uplink NIC PCI information not found for ${desired_host_if}"
    return 1
  fi

  local hostmgmt_pci
  hostmgmt_pci="${HOSTMGMT_NIC_PCI:-}"
  if [[ -z "${hostmgmt_pci}" ]]; then
    hostmgmt_pci="$(readlink -f "/sys/class/net/${desired_hostmgmt_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
  fi
  if [[ -z "${hostmgmt_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI Information Error" "Could not retrieve PCI bus information for direct access NIC.\n\nNIC: ${desired_hostmgmt_if}\n\nPlease re-run STEP 01 to verify and select the correct NIC." 14 80
    log "ERROR: Direct access NIC PCI information not found for ${desired_hostmgmt_if}"
    return 1
  fi

  if [[ "${desired_host_if}" == "${desired_hostmgmt_if}" || "${nat_pci}" == "${hostmgmt_pci}" ]]; then
    whiptail_msgbox "STEP 03 - Duplicate NIC Selection" "NAT uplink NIC and Direct access NIC cannot be the same physical NIC.\n\nNAT uplink: ${desired_host_if} (PCI: ${nat_pci})\nDirect access: ${desired_hostmgmt_if} (PCI: ${hostmgmt_pci})\n\nPlease select different NICs in STEP 01." 14 85
    log "ERROR: NAT uplink NIC and Direct access NIC are duplicated"
    return 1
  fi
  # Prevent direct access NIC from overlapping with SPAN NICs (NAT mode)
  if [[ -n "${SPAN_NIC_LIST:-${SPAN_NICS}}" ]]; then
    for span_nic in ${SPAN_NIC_LIST:-${SPAN_NICS}}; do
      if [[ "${span_nic}" == "${desired_hostmgmt_if}" || "${span_nic}" == "${HOSTMGMT_NIC}" ]]; then
        whiptail_msgbox "STEP 03 - Duplicate NIC Selection" "Direct access NIC cannot be the same as any SPAN NIC.\n\nDirect access: ${desired_hostmgmt_if}\nSPAN NIC: ${span_nic}\n\nPlease select different NICs in STEP 01." 14 85
        log "ERROR: Direct access NIC overlaps with SPAN NIC: ${span_nic}"
        return 1
      fi
    done
  fi
  if [[ -n "${SPAN_NIC_LIST:-${SPAN_NICS}}" ]]; then
    for span_nic in ${SPAN_NIC_LIST:-${SPAN_NICS}}; do
      if [[ -d "/sys/class/net/${span_nic}" ]]; then
        local span_pci
        span_pci="$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
        if [[ -n "${span_pci}" && "${span_pci}" == "${hostmgmt_pci}" ]]; then
          whiptail_msgbox "STEP 03 - Duplicate NIC Selection" "Direct access NIC and SPAN NIC cannot be the same physical device.\n\nDirect access PCI: ${hostmgmt_pci}\nSPAN NIC: ${span_nic} (PCI: ${span_pci})\n\nPlease select different NICs in STEP 01." 14 90
          log "ERROR: Direct access NIC overlaps with SPAN NIC by PCI: ${span_pci}"
          return 1
        fi
      fi
    done
  fi

  local span_udev_rules=""
  local span_nic_list_to_use="${SPAN_NIC_LIST:-${SPAN_NICS}}"
  if [[ -n "${span_nic_list_to_use}" ]]; then
    for span_nic in ${span_nic_list_to_use}; do
      local span_pci
      if [[ -d "/sys/class/net/${span_nic}" ]]; then
        span_pci="$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
        if [[ -n "${span_pci}" ]]; then
          span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci}
ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
        fi
      fi
    done
  fi

  local parsed ip0 nm0 gw0 dns0
  parsed="$(parse_mgt_from_interfaces)"
  ip0="${parsed%%|*}"; parsed="${parsed#*|}"
  nm0="${parsed%%|*}"; parsed="${parsed#*|}"
  gw0="${parsed%%|*}"; parsed="${parsed#*|}"
  dns0="${parsed}"

  local def_ip="${MGT_IP_ADDR:-$ip0}"
  local def_prefix="${MGT_IP_PREFIX:-24}"
  local def_gw="${MGT_GW:-$gw0}"
  local def_dns="${MGT_DNS:-$dns0}"
  [[ -z "${def_dns}" ]] && def_dns="8.8.8.8 8.8.4.4"

  local new_ip new_prefix new_gw new_dns
  new_ip=$(whiptail_inputbox "STEP 03 - mgt NIC IP Configuration" "Enter NAT uplink NIC (mgt) IP address:" "${def_ip}" 8 60) || return 1
  [[ -z "${new_ip}" ]] && return 1
  new_prefix=$(whiptail_inputbox "STEP 03 - mgt Prefix" "Enter subnet prefix length (/ value).\nExample: 24" "${def_prefix}" 8 60) || return 1
  [[ -z "${new_prefix}" ]] && return 1
  new_gw=$(whiptail_inputbox "STEP 03 - Gateway Configuration" "Enter gateway IP:" "${def_gw}" 8 60) || return 1
  [[ -z "${new_gw}" ]] && return 1
  new_dns=$(whiptail_inputbox "STEP 03 - DNS Configuration" "Enter DNS server IPs:" "${def_dns}" 8 60) || return 1
  [[ -z "${new_dns}" ]] && return 1

  local netmask
  netmask="$(cidr_to_netmask "${new_prefix}")"

  save_config_var "MGT_IP_ADDR" "${new_ip}"
  save_config_var "MGT_IP_PREFIX" "${new_prefix}"
  save_config_var "MGT_GW" "${new_gw}"
  save_config_var "MGT_DNS" "${new_dns}"

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_lib_file="/usr/lib/udev/rules.d/99-custom-ifnames.rules"
  local udev_content
  udev_content=$(cat <<EOF
# XDR NAT Mode - Custom interface names
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${nat_pci}", NAME:="mgt"
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${hostmgmt_pci}", NAME:="hostmgmt"${span_udev_rules}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${udev_file} will be created with the following content:\n${udev_content}"
    log "[DRY-RUN] ${udev_lib_file} will be created with the following content:\n${udev_content}"
    log "[DRY-RUN] Would run: sudo update-initramfs -u -k all"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
    printf "%s\n" "${udev_content}" > "${udev_lib_file}"
    chmod 644 "${udev_file}" || true
    chmod 644 "${udev_lib_file}" || true
    log "[STEP 03 NAT Mode] Updating initramfs to apply udev rename on reboot"
    run_cmd "sudo update-initramfs -u -k all"
  fi

  if [[ "${DRY_RUN}" -ne 1 ]]; then
    save_config_var "HOST_NIC_EFFECTIVE" "mgt"
    save_config_var "HOST_NIC" "mgt"
    save_config_var "HOST_NIC_RENAMED" "mgt"
    save_config_var "HOSTMGMT_NIC_EFFECTIVE" "hostmgmt"
    save_config_var "HOSTMGMT_NIC_RENAMED" "hostmgmt"
  fi

  local iface_file="/etc/network/interfaces"
  local iface_dir="/etc/network/interfaces.d"
  local mgt_cfg="${iface_dir}/01-mgt.cfg"
  local hostmgmt_cfg="${iface_dir}/02-hostmgmt.cfg"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  local iface_content
  iface_content=$(cat <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${iface_file} will be created with the following content:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

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
    log "[DRY-RUN] ${mgt_cfg} will be created with the following content:\n${mgt_content}"
  else
    printf "%s\n" "${mgt_content}" > "${mgt_cfg}"
  fi

  local hostmgmt_content
  hostmgmt_content=$(cat <<EOF
auto hostmgmt
iface hostmgmt inet static
    address 192.168.0.100
    netmask 255.255.255.0
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${hostmgmt_cfg} will be created with the following content:\n${hostmgmt_content}"
  else
    printf "%s\n" "${hostmgmt_content}" > "${hostmgmt_cfg}"
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    local verify_failed=0
    local verify_errors=""
    if [[ ! -f "${udev_file}" ]] || [[ ! -f "${udev_lib_file}" ]]; then
      verify_failed=1
      verify_errors="${verify_errors}\n- udev rules missing"
    fi
    if [[ ! -f "${iface_file}" ]] || \
       ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' "${iface_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- /etc/network/interfaces missing source line"
    fi
    if [[ ! -f "${mgt_cfg}" ]] || ! grep -qE '^[[:space:]]*iface[[:space:]]+mgt[[:space:]]+inet[[:space:]]+static' "${mgt_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- mgt config invalid: ${mgt_cfg}"
    fi
    if [[ ! -f "${hostmgmt_cfg}" ]] || ! grep -qE '^[[:space:]]*iface[[:space:]]+hostmgmt[[:space:]]+inet[[:space:]]+static' "${hostmgmt_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- hostmgmt config invalid: ${hostmgmt_cfg}"
    fi
    if [[ "${verify_failed}" -eq 1 ]]; then
      whiptail_msgbox "STEP 03 - File Verification Failed" "Configuration file verification failed.\n\n${verify_errors}\n\nPlease check the files and re-run the step." 16 85
      log "[ERROR] STEP 03 file verification failed:${verify_errors}"
      return 1
    fi
  fi

  log "[STEP 03 NAT Mode] Install ifupdown and disable netplan (no restart)"
  local missing_pkgs=()
  dpkg -s ifupdown >/dev/null 2>&1 || missing_pkgs+=("ifupdown")
  dpkg -s net-tools >/dev/null 2>&1 || missing_pkgs+=("net-tools")
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    run_cmd "sudo apt update"
    run_cmd "sudo apt install -y ${missing_pkgs[*]}"
  fi

  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    run_cmd "sudo mkdir -p /etc/netplan/disabled"
    run_cmd "sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
  fi

  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"
  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"

  local summary
  summary=$(cat <<EOF
═══════════════════════════════════════════════════════════
  STEP 03: NAT Mode Configuration - Complete (Declarative)
═══════════════════════════════════════════════════════════

✅ FILES WRITTEN (no runtime changes):
* NAT uplink NIC: ${HOST_NIC} → mgt
* mgt IP: ${new_ip}/${new_prefix} (netmask ${netmask})
* Gateway: ${new_gw}
* DNS: ${new_dns}
* Direct access NIC: ${HOSTMGMT_NIC} → hostmgmt (192.168.0.100/24, no gateway)

📂 Files:
1. udev: /etc/udev/rules.d/99-custom-ifnames.rules
2. udev: /usr/lib/udev/rules.d/99-custom-ifnames.rules
3. /etc/network/interfaces
4. /etc/network/interfaces.d/01-mgt.cfg
5. /etc/network/interfaces.d/02-hostmgmt.cfg

⚠️ REBOOT REQUIRED
Network configuration changes will be applied after reboot.
EOF
)
  whiptail_msgbox "STEP 03 NAT Mode Completed" "${summary}" 20 80
  log "[STEP 03 NAT Mode] NAT configuration completed. Reboot required."
  return 0
}

step_03_nat_mode() {
  step_03_nat_mode_declarative
  return $?
}




step_04_kvm_libvirt() {
  log "[STEP 04] KVM / Libvirt Installation and default configuration"
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

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 04] Sensor Network Mode: ${net_mode}"

  local tmp_info="${STATE_DIR}/xdr_step04_info.txt"

  #######################################
  # 0) Current Status  
  #######################################
  local kvm_ok="no"
  local libvirtd_ok="no"

  if command -v kvm-ok >/dev/null 2>&1; then
    # Check if kvm-ok exists and execute to check "KVM acceleration can be used"
    if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
      kvm_ok="yes"
    fi
  fi

  if systemctl is-active --quiet libvirtd 2>/dev/null; then
    libvirtd_ok="yes"
  fi

  {
    echo "Current KVM / Libvirt Status"
    echo "-----------------------"
    echo "Network Mode: ${net_mode}"
    echo "KVM acceleration available: ${kvm_ok}"
    echo "libvirtd service: ${libvirtd_ok}"
    echo
    echo " Next steps to be executed:"
    echo "  1) KVM / Libvirt  package Installation"
    echo "  2) User libvirt  add"
    echo "  3) libvirtd / virtlogd service activate"
    if [[ "${net_mode}" == "bridge" ]]; then
      echo "  4) default libvirt Network(virbr0) remove (L2 bridge Mode)"
    elif [[ "${net_mode}" == "nat" ]]; then
      echo "  4) default libvirt Network(virbr0) NAT Configuration (NAT Mode)"
    fi
    echo "  5) KVM  and   Verification"
  } > "${tmp_info}"

  show_textbox "STEP 04 - KVM/Libvirt Installation unit" "${tmp_info}"

  if [[ "${kvm_ok}" == "yes" && "${libvirtd_ok}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 04 - Already Configured" "KVM libvirtd is already configured.\n\nDo you want to skip this STEP?\n\n(Yes: Skip / No: Continue)" 12 70
    then
      log "User canceled STEP 04 execution."
    else
      log "User chose to skip STEP 04 (already configured)."
      return 0
    fi
  fi

  if ! whiptail_yesno "STEP 04 Execution Confirmation" "Do you want to proceed with KVM / Libvirt installation?" 10 60
  then
    log "User canceled STEP 04 execution."
    return 0
  fi

  #######################################
  # 1) package Installation
  #######################################
  echo "=== KVM/libvirt environment installation in progress (this may take some time) ==="
  log "[STEP 04] Installing KVM / Libvirt packages"
  log "[STEP 04] Installing essential packages for KVM/Libvirt environment..."

  local packages="qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager cpu-checker qemu-utils virtinst genisoimage"
  
  log "Installing KVM/Libvirt packages: ${packages}"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${packages}"
  
  echo "=== All KVM/libvirt package installation completed ==="

  #######################################
  # 2) User libvirt  add
  #######################################
  local current_user
  current_user=$(whoami)
  log "[STEP 04] Adding ${current_user} user to libvirt group"
  run_cmd "sudo usermod -aG libvirt ${current_user}"

  #######################################
  # 3) service activate
  #######################################
  log "[STEP 04] Activating libvirtd / virtlogd services"
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

  #######################################
  # 4) default libvirt Network Configuration (Network mode branch)
  #######################################
  
  if [[ "${net_mode}" == "bridge" ]]; then
    # Bridge Mode: default Network remove ( bridge use)
    log "[STEP 04] Bridge Mode - Removing default libvirt network (sensor uses bridge)"
    
    # Existing default Network before remove
    run_cmd "sudo virsh net-destroy default || true"
    run_cmd "sudo virsh net-undefine default || true"
    
    log "Sensor VM uses br-data (DATA NIC) and br-span* (SPAN NIC) bridges."
    
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: OpenXDR NAT Network XML Creation
    log "[STEP 04] NAT Mode - Creating OpenXDR NAT Network XML (virbr0/192.168.122.0/24)"
    
    # Existing default Network remove
    run_cmd "sudo virsh net-destroy default || true"
    run_cmd "sudo virsh net-undefine default || true"
    
    # OpenXDR Method NAT Network XML Creation
    local default_net_xml="${STATE_DIR}/default.xml"
    cat > "${default_net_xml}" <<'EOF'
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
    
    log "NAT Network XML File Creation: ${default_net_xml}"
    
    # Configure and activate NAT Network
    run_cmd "sudo virsh net-define \"${default_net_xml}\""
    run_cmd "sudo virsh net-autostart default"
    run_cmd "sudo virsh net-start default"
    
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
    
    log "Sensor VM uses virbr0 NAT bridge (192.168.122.0/24)."
    
  else
    log "ERROR: Unknown network mode: ${net_mode}"
    return 1
  fi

  #######################################
  # 5) Result Verification
  #######################################
  local final_kvm_ok="unknown"
  local final_libvirtd_ok="unknown"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_kvm_ok="(DRY-RUN mode)"
    final_libvirtd_ok="(DRY-RUN mode)"
  else
    # Re-checking KVM
    if command -v kvm-ok >/dev/null 2>&1; then
      if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
        final_kvm_ok="OK"
      else
        final_kvm_ok="FAIL"
      fi
    fi

    # Re-checking libvirtd
    if systemctl is-active --quiet libvirtd; then
      final_libvirtd_ok="OK"
    else
      final_libvirtd_ok="FAIL"
    fi
  fi

  {
    echo "STEP 04 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • KVM availability: ${final_kvm_ok}"
      echo "  • libvirtd service: ${final_libvirtd_ok}"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. KVM/libvirt packages would be installed:"
      echo "     - qemu-kvm, libvirt-daemon-system, libvirt-clients"
      echo "     - bridge-utils, virt-manager, cpu-checker"
      echo "     - qemu-utils, virtinst, genisoimage"
      echo
      echo "  2. Current user would be added to libvirt group"
      echo "  3. libvirtd and virtlogd services would be enabled and started"
      echo
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "  4. Bridge Mode Network Configuration:"
        echo "     - Default libvirt network would be removed"
        echo "     - Sensor VM will use br-data and br-span* bridges"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "  4. NAT Mode Network Configuration:"
        echo "     - OpenXDR NAT network (virbr0/192.168.122.0/24) would be created"
        echo "     - Sensor VM will use virbr0 NAT bridge"
      fi
      echo
      echo "⚠️  IMPORTANT NOTES:"
      echo "  • User group changes require logout/login or reboot to take effect"
      echo "  • BIOS/UEFI must have virtualization (VT-x/VT-d) enabled"
      echo "  • KVM acceleration requires hardware virtualization support"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 INSTALLATION STATUS:"
      echo "  • KVM availability: ${final_kvm_ok}"
      echo "  • libvirtd service: ${final_libvirtd_ok}"
      echo
      echo "📦 PACKAGES INSTALLED:"
      echo "  • qemu-kvm, libvirt-daemon-system, libvirt-clients"
      echo "  • bridge-utils, virt-manager, cpu-checker"
      echo "  • qemu-utils, virtinst, genisoimage"
      echo
      echo "👤 USER CONFIGURATION:"
      echo "  • Current user added to libvirt group"
      echo "    (Group changes require logout/login or reboot)"
      echo
      echo "🔧 SERVICE STATUS:"
      echo "  • libvirtd: enabled and started"
      echo "  • virtlogd: enabled and started"
      echo
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "🌐 NETWORK CONFIGURATION (Bridge Mode):"
        echo "  • Default libvirt network: removed"
        echo "  • Sensor VM network:"
        echo "    - br-data: DATA NIC L2 bridge"
        echo "    - br-span*: SPAN NIC L2 bridge (if bridge mode configured)"
        echo "    - SPAN NIC: PCI passthrough (if pci mode configured)"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "🌐 NETWORK CONFIGURATION (NAT Mode):"
        echo "  • OpenXDR NAT network: created and started"
        echo "  • Network: virbr0 (192.168.122.0/24)"
        echo "  • Sensor VM will use virbr0 NAT bridge"
      fi
      echo
      echo "⚠️  IMPORTANT NOTES:"
      echo "  • User group changes will be applied after next login/reboot"
      echo "  • BIOS/UEFI must have virtualization (VT-x/VT-d) enabled"
      echo "  • Verify KVM with: kvm-ok"
      echo "  • Verify libvirt with: virsh list --all"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 04 Result Summary" "${tmp_info}"

  log "[STEP 04] KVM / Libvirt Installation and Configuration completed"

  return 0
}


step_05_kernel_tuning() {
  log "[STEP 05] Kernel parameter / KSM / swap tuning"
  load_config

  local tmp_status="/tmp/xdr_step05_status.txt"

  #######################################
  # 0) Current status check
  #######################################
  local grub_has_iommu="no"
  local ksm_disabled="no"

  # GRUBfrom iommu Configuration Check
  if grep -q "intel_iommu=on iommu=pt" /etc/default/grub 2>/dev/null; then
    grub_has_iommu="yes"
  fi

  # KSM disable Check
  if grep -q "KSM_ENABLED=0" /etc/default/qemu-kvm 2>/dev/null; then
    ksm_disabled="yes"
  fi

  {
    echo "Current kernel tuning Status"
    echo "-------------------"
    echo "GRUB IOMMU Configuration: ${grub_has_iommu}"
    echo "KSM disable: ${ksm_disabled}"
    echo
    echo " Next steps to be executed:"
    echo "  1) Add GRUB IOMMU parameters (intel_iommu=on iommu=pt)"
    echo "  2) Kernel parameter tuning (/etc/sysctl.conf)"
    echo "     - ARP flux configuration"
    echo "     - Memory  "
    echo "  3) KSM(Kernel Same-page Merging) disable"
    echo "  4) swap disable  "
    echo
    echo "* System will automatically reboot after STEP completion."
  } > "${tmp_status}"

  show_textbox "STEP 05 - kernel tuning unit" "${tmp_status}"

  if [[ "${grub_has_iommu}" == "yes" && "${ksm_disabled}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 05 - Already Configured" "GRUB IOMMU and KSM configuration already exists.\n\nDo you want to skip this STEP?" 12 70
    then
      log "User canceled STEP 05 execution."
    else
      log "User chose to skip STEP 05 (already configured)."
      return 0
    fi
  fi

  if ! whiptail_yesno "STEP 05 Execution Confirmation" "Do you want to proceed with kernel tuning?" 10 60
  then
    log "User canceled STEP 05 execution."
    return 0
  fi

  #######################################
  # 1) GRUB Configuration
  #######################################
  log "[STEP 05] GRUB Configuration - Adding IOMMU parameters"

  if [[ "${grub_has_iommu}" == "no" ]]; then
    local grub_file="/etc/default/grub"
    local grub_bak="${grub_file}.$(date +%Y%m%d-%H%M%S).bak"

    if [[ "${DRY_RUN}" -eq 0 && -f "${grub_file}" ]]; then
      cp -a "${grub_file}" "${grub_bak}"
      log "GRUB Configuration backup: ${grub_bak}"
    fi

    # Add IOMMU parameters to GRUB_CMDLINE_LINUX
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] GRUB_CMDLINE_LINUX 'intel_iommu=on iommu=pt' add"
    else
      # Existing GRUB_CMDLINE_LINUX  add
      sed -i 's/GRUB_CMDLINE_LINUX="/&intel_iommu=on iommu=pt /' "${grub_file}"
    fi

    run_cmd "sudo update-grub"
  else
    log "[STEP 05] GRUB IOMMU configuration already exists -> skipping GRUB configuration"
  fi

  #######################################
  # 2) Kernel parameter tuning
  #######################################
  log "[STEP 05] Kernel parameter tuning (/etc/sysctl.conf)"

  local sysctl_params="
  # XDR Installer kernel tuning (PDF this can)
  # [cite_start]IPv4   activate [cite: 53-57]
  net.ipv4.ip_forward = 1

  # Memory   (OOM not - not )
  vm.min_free_kbytes = 1048576
  "

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Adding kernel parameters to /etc/sysctl.conf:\n${sysctl_params}"
  else
    if ! grep -q "# XDR Installer kernel tuning" /etc/sysctl.conf 2>/dev/null; then
      echo "${sysctl_params}" >> /etc/sysctl.conf
      log "Added kernel parameters to /etc/sysctl.conf"
    else
      log "Kernel parameters already exist in /etc/sysctl.conf -> skipping"
    fi
  fi

  run_cmd "sudo sysctl -p"

  #######################################
  # 3) KSM disable
  #######################################
  log "[STEP 05] KSM(Kernel Same-page Merging) disable"

  if [[ "${ksm_disabled}" == "no" ]]; then
    local qemu_kvm_file="/etc/default/qemu-kvm"
    local qemu_kvm_bak="${qemu_kvm_file}.$(date +%Y%m%d-%H%M%S).bak"

    if [[ "${DRY_RUN}" -eq 0 && -f "${qemu_kvm_file}" ]]; then
      cp -a "${qemu_kvm_file}" "${qemu_kvm_bak}"
      log "qemu-kvm Configuration backup: ${qemu_kvm_bak}"
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] ${qemu_kvm_file} KSM_ENABLED=0 Configuration"
    else
      if [[ -f "${qemu_kvm_file}" ]]; then
        # If KSM_ENABLED exists, change it; otherwise add it
        if grep -q "^KSM_ENABLED=" "${qemu_kvm_file}"; then
          sed -i 's/^KSM_ENABLED=.*/KSM_ENABLED=0/' "${qemu_kvm_file}"
        else
          echo "KSM_ENABLED=0" >> "${qemu_kvm_file}"
        fi
      else
        # Filethis toif  Creation
        echo "KSM_ENABLED=0" > "${qemu_kvm_file}"
      fi
      log "KSM_ENABLED=0 Configuration Completed"
    fi
  else
    log "[STEP 05] KSM is already disabled -> skipping KSM configuration"
  fi

  #######################################
  # 4) swap disable and swap file cleanup
  #######################################
  if whiptail_yesno "STEP 05 - swap disable" "Do you want to disable swap?\n\nNote: This is recommended, but insufficient memory may cause issues.\n\nThe following will be done:\n- Disable all swap\n- Comment out swap entries in /etc/fstab\n- Remove /swapfile, /swap.img files" 16 70
  then
    log "[STEP 05] Disabling swap and removing swap files"
    
    # 1) All  swap disable
    run_cmd "sudo swapoff -a"
    
    # 2) Comment out all swap entries in /etc/fstab
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Commenting out swap entries in /etc/fstab"
    else
      # Comment out swap type or swap file path entries
      sed -i '/\sswap\s/ s/^/#/' /etc/fstab
      sed -i '/\/swap/ s/^[^#]/#&/' /etc/fstab
    fi

    # 3) in swap Files remove
    local swap_files=("/swapfile" "/swap.img" "/var/swap" "/swap")
    for swap_file in "${swap_files[@]}"; do
      if [[ -f "${swap_file}" ]]; then
        local size_info=""
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          size_info=$(du -h "${swap_file}" 2>/dev/null | cut -f1 || echo "unknown")
        fi
        log "[STEP 05] Removing swap file: ${swap_file} (Size: ${size_info})"
        run_cmd "sudo rm -f \"${swap_file}\""
      fi
    done
    
    # 4) Disable systemd-swap service (if exists)
    if systemctl is-enabled systemd-swap >/dev/null 2>&1; then
      log "[STEP 05] Disabling systemd-swap service"
      run_cmd "sudo systemctl disable systemd-swap"
      run_cmd "sudo systemctl stop systemd-swap"
    fi
    
    # 5) swap  systemctl services Check and disable
    local swap_services=$(systemctl list-units --type=swap --all --no-legend 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "${swap_services}" ]]; then
      for service in ${swap_services}; do
        if [[ "${service}" =~ \.swap$ ]]; then
          log "[STEP 05] Disabling swap: ${service}"
          run_cmd "sudo systemctl mask \"${service}\""
        fi
      done
    fi
    
    log "Swap disable and cleanup completed"
  else
    log "User canceled swap disable."
  fi

  #######################################
  # 5) Result Summary
  #######################################
  {
    echo "STEP 05 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED CONFIGURATION:"
      echo "  • GRUB IOMMU Configuration: Would be applied"
      echo "  • Kernel parameter tuning: Would be applied"
      echo "  • KSM disable: Would be applied"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. GRUB Configuration:"
      echo "     - /etc/default/grub would be modified"
      echo "     - IOMMU parameters (intel_iommu=on iommu=pt) would be added"
      echo "     - update-grub would be executed"
      echo
      echo "  2. Kernel Parameters:"
      echo "     - /etc/sysctl.conf would be updated"
      echo "     - net.ipv4.ip_forward = 1"
      echo "     - vm.min_free_kbytes = 1048576"
      echo "     - sysctl -p would be executed"
      echo
      echo "  3. KSM Disable:"
      echo "     - /etc/default/qemu-kvm would be created/updated"
      echo "     - KSM_ENABLED=0 would be set"
      echo
      # Check swap disable state
      local swap_status=""
      if swapon --show 2>/dev/null | grep -q .; then
        swap_status="enabled"
      else
        swap_status="disabled"
      fi
      if [[ "${swap_status}" == "enabled" ]]; then
        echo "  4. Swap Disable:"
        echo "     - All swap would be disabled (swapoff -a)"
        echo "     - /etc/fstab swap entries would be commented out"
        echo "     - Swap files would be removed"
        echo "     - systemd-swap service would be disabled"
      else
        echo "  4. Swap: Already disabled (no action needed)"
      fi
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • System reboot is required to apply all configuration changes"
      echo "  • GRUB changes will take effect after reboot"
      echo "  • AUTO_REBOOT_AFTER_STEP_ID is configured"
      echo "  • System will automatically reboot after STEP completion"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 CONFIGURATION APPLIED:"
      echo "  • GRUB IOMMU Configuration: Completed"
      echo "    - /etc/default/grub: IOMMU parameters added"
      echo "    - update-grub: executed"
      echo
      echo "  • Kernel Parameter Tuning: Completed"
      echo "    - /etc/sysctl.conf: updated"
      echo "    - net.ipv4.ip_forward = 1"
      echo "    - vm.min_free_kbytes = 1048576"
      echo "    - sysctl -p: executed"
      echo
      echo "  • KSM Disable: Completed"
      echo "    - /etc/default/qemu-kvm: KSM_ENABLED=0 configured"
      echo
      # Check swap disable state
      local swap_status=""
      if swapon --show 2>/dev/null | grep -q .; then
        swap_status="enabled"
      else
        swap_status="disabled"
      fi
      if [[ "${swap_status}" == "disabled" ]]; then
        echo "  • Swap Disable: Completed"
        echo "    - All swap disabled"
        echo "    - /etc/fstab swap entries commented out"
        echo "    - Swap files removed"
        echo "    - systemd-swap service disabled"
      else
        echo "  • Swap: User chose to keep swap enabled"
      fi
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • System reboot is required to apply all configuration changes"
      echo "  • GRUB changes will take effect after reboot"
      echo "  • AUTO_REBOOT_AFTER_STEP_ID is configured"
      echo "  • System will automatically reboot after STEP completion"
      echo
      echo "💡 TIP: After reboot, verify IOMMU with:"
      echo "   dmesg | grep -i iommu"
      echo "   cat /proc/cmdline | grep iommu"
    fi
  } > "${tmp_status}"

  show_textbox "STEP 05 Result Summary" "${tmp_status}"

  log "[STEP 05] Kernel tuning configuration completed. Reboot is required."

  return 0
}


step_06_libvirt_hooks() {
  log "[STEP 06] Installing libvirt hooks (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 06] Sensor Network Mode: ${net_mode}"

  local hooks_rc=0
  # mode branch Execution
  if [[ "${net_mode}" == "bridge" ]]; then
    log "[STEP 06] Bridge Mode - Installing sensor hooks"
    step_06_bridge_hooks || hooks_rc=$?
  elif [[ "${net_mode}" == "nat" ]]; then
    log "[STEP 06] NAT Mode - Installing OpenXDR NAT hooks"
    step_06_nat_hooks || hooks_rc=$?
  else
    log "ERROR: Unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail_msgbox "Network Mode Error" "Unknown sensor network mode: ${net_mode}\n\nPlease select a valid mode (bridge or nat) in environment configuration."
    return 1
  fi

  if [[ ${hooks_rc} -ne 0 ]]; then
    return ${hooks_rc}
  fi

  step_06_ntpsec_only
  return $?
}

step_06_ntpsec_only() {
  load_config

  log "[STEP 06] Configure NTPsec"
  
  local tmp_info="/tmp/xdr_step06_ntpsec_info.txt"
  : > "${tmp_info}"

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

  show_textbox "STEP 06 - NTP status" "${tmp_info}"

  # Temporarily disable set -e to handle cancel gracefully
  set +e
  whiptail_yesno "STEP 06 - confirmation" "Install and configure NTPsec on the host.\n\nProceed?"
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
      echo "   • NTPsec package installation and configuration"
      echo "   • NTPsec service restart and status check"
    else
      echo "✅ STEP 06 Execution Status: SUCCESS"
      echo
      echo "📋 ACTIONS COMPLETED:"
      echo "   • NTPsec package installation and configuration"
      echo "   • NTPsec service restarted and verified"
      echo
      echo "📊 NTPsec CONFIGURATION STATUS:"
      echo "1️⃣  NTPsec Configuration File:"
      if [[ -f "${NTP_CONF}" ]]; then
        echo "     ✅ ${NTP_CONF} updated"
      else
        echo "     ⚠️  ${NTP_CONF} not found"
        echo "     (NTPsec may not be installed)"
      fi
      echo
      echo "2️⃣  NTPsec Service Status:"
      local ntpsec_status
      ntpsec_status=$(systemctl is-active ntpsec 2>/dev/null || echo "")
      if [[ -z "${ntpsec_status}" ]] || [[ "${ntpsec_status}" != "active" ]]; then
        echo "  ⚠️  ntpsec service is inactive"
      else
        echo "  ✅ ntpsec service is active"
      fi
      echo
      echo "3️⃣  NTP Synchronization Status:"
      if command -v ntpq >/dev/null 2>&1; then
        echo "  (ntpq -p output below)"
        ntpq -p 2>/dev/null || echo "  (NTPsec may not be running or not yet synchronized)"
      else
        echo "  (ntpq command not found)"
      fi
      echo
      echo "💡 IMPORTANT NOTES:"
      echo "  • NTPsec synchronization may take a few minutes"
      echo "  • Check /etc/ntpsec/ntp.conf for server settings"
      echo "  • If NTPsec is not synchronized, check network connectivity"
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 06 - NTPsec summary" "${tmp_info}"
}

#######################################
# STEP 08 - Bridge Mode (Existing Sensor hooks)
#######################################
step_06_bridge_hooks() {
  log "[STEP 06 Bridge Mode] Installing sensor libvirt hooks"

  local tmp_info="/tmp/xdr_step08_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current hooks Status Summary
  #######################################
  {
    echo "/etc/libvirt/hooks Directory and script Status"
    echo "-------------------------------------------"
    echo
    echo "# Directory Exists "
    if [[ -d /etc/libvirt/hooks ]]; then
      echo "/etc/libvirt/hooks directory exists."
      echo
      echo "# /etc/libvirt/hooks/network (first 20 lines if exists)"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/network
      else
        echo "(network script None)"
      fi
      echo
      echo "# /etc/libvirt/hooks/qemu (first 20 lines if exists)"
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/qemu
      else
        echo "(qemu script None)"
      fi
    else
      echo "/etc/libvirt/hooks directory does not exist."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 06 - Current hooks Status" "${tmp_info}"

  local step06_msg
  step06_msg=$(center_message "Create /etc/libvirt/hooks/network and /etc/libvirt/hooks/qemu scripts based on configuration.\n\nDo you want to continue?")
  
  if ! whiptail_yesno "STEP 06 Execution Check" "${step06_msg}"; then
    log "User canceled STEP 06 execution."
    return 0
  fi

  #######################################
  # 1) /etc/libvirt/hooks Directory Creation
  #######################################
  log "[STEP 06] Creating /etc/libvirt/hooks directory (if needed)"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /etc/libvirt/hooks"
  else
    sudo mkdir -p /etc/libvirt/hooks
  fi

  #######################################
  # 2) /etc/libvirt/hooks/network Creation (HOST_NIC Based)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06] Creating ${HOOK_NET}"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Existing ${HOOK_NET} backed up to ${HOOK_NET_BAK}"
    else
      log "[DRY-RUN] Existing ${HOOK_NET} will be backed up to ${HOOK_NET_BAK}"
    fi
  fi

  local net_hook_content
  net_hook_content=$(cat <<'EOF'
#!/bin/bash
# Network hook - L2 bridge mode only (no IP routing)
# All routing logic removed for L2-only configuration
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${HOOK_NET} will be created with the following content:\n${net_hook_content}"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_NET}"

  #######################################
  # 3) /etc/libvirt/hooks/qemu Creation (XDR Sensor)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06] Creating ${HOOK_QEMU} (OOM recovery script only, NAT removed)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Existing ${HOOK_QEMU} backed up to ${HOOK_QEMU_BAK}"
    else
      log "[DRY-RUN] Existing ${HOOK_QEMU} will be backed up to ${HOOK_QEMU_BAK}"
    fi
  fi

  local qemu_hook_content
  qemu_hook_content=$(cat <<'EOF'
#!/bin/bash
# Last Update: 2025-12-06 (XDR Sensor L2 bridgefor cancorrect)
# NAT/DNAT  removedone - Sensor VMthis  IP Configuration

########################
# OOM  scriptonly not (NAT remove)
########################
if [ "${1}" = "mds" ]; then
  if [ "${2}" = "start" ] || [ "${2}" = "reconnect" ]; then
    # save last known good pid
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${HOOK_QEMU} will be created with the following content:\n${qemu_hook_content}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_QEMU}"

  ########################################
  # 4) OOM  script Installation (last_known_good_pid, check_vm_state)
  ########################################
  log "[STEP 06] Installing OOM recovery scripts (last_known_good_pid, check_vm_state)"

  local _DRY="${DRY_RUN:-0}"

  # 1) /usr/bin/last_known_good_pid Creation
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] /usr/bin/last_known_good_pid script Creation"
  else
    sudo tee /usr/bin/last_known_good_pid >/dev/null <<'EOF'
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
    sudo chmod +x /usr/bin/last_known_good_pid
  fi

  # 2) /usr/bin/check_vm_state Creation (XDR Sensorfor)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] /usr/bin/check_vm_state script Creation"
  else
    sudo tee /usr/bin/check_vm_state >/dev/null <<'EOF'
#!/bin/bash
VM_LIST=(mds)
RUN_DIR=/var/run/libvirt/qemu

for VM in ${VM_LIST[@]}; do
    # Check if VM has ended (when .xml file and .pid file do not exist)
    if [ ! -e ${RUN_DIR}/${VM}.xml -a ! -e ${RUN_DIR}/${VM}.pid ]; then
        if [ -e ${RUN_DIR}/${VM}.lkg ]; then
            LKG_PID=$(cat ${RUN_DIR}/${VM}.lkg)

            # Check dmesg for OOM-killer PID
            if dmesg | grep "Out of memory: Kill process $LKG_PID" > /dev/null 2>&1; then
                virsh start $VM
            fi
        fi
    fi
done

exit 0
EOF
    sudo chmod +x /usr/bin/check_vm_state
  fi

  # 3) cron configuration (check_vm_state execution every 5 minutes)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Root crontab will be updated with:"
    log "  SHELL=/bin/bash"
    log "  */5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1"
  else
    # Existing crontab  notdoiffrom SHELL  check_vm_state inonly 
    local tmp_cron added_flag
    tmp_cron="$(mktemp)"
    added_flag="0"

    # Existing crontab  (toif  File Creation)
    if ! sudo crontab -l 2>/dev/null > "${tmp_cron}"; then
      : > "${tmp_cron}"
    fi

    # SHELL=/bin/bash  toif add
    if ! grep -q '^SHELL=' "${tmp_cron}"; then
      echo "SHELL=/bin/bash" >> "${tmp_cron}"
      added_flag="1"
    fi

    # check_vm_state inthis toif add
    if ! grep -q 'check_vm_state' "${tmp_cron}"; then
      echo "*/5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1" >> "${tmp_cron}"
      added_flag="1"
    fi

    # Apply updated crontab
    sudo crontab "${tmp_cron}"
    rm -f "${tmp_cron}"

    if [[ "${added_flag}" = "1" ]]; then
      log "[STEP 06] Adding SHELL=/bin/bash and check_vm_state to root crontab."
    else
      log "[STEP 06] root crontab SHELL=/bin/bash and check_vm_state already exists."
    fi
  fi

  #######################################
  # 5)  Summary
  #######################################
  {
    echo "STEP 06 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED CONFIGURATION:"
      echo "  • /etc/libvirt/hooks/network: Would be created"
      echo "  • /etc/libvirt/hooks/qemu: Would be created"
      echo "  • /usr/bin/last_known_good_pid: Would be created"
      echo "  • /usr/bin/check_vm_state: Would be created"
      echo "  • Root crontab: Would be updated with OOM recovery"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. /etc/libvirt/hooks/network:"
      echo "     - L2 bridge mode hook script (no IP routing)"
      echo
      echo "  2. /etc/libvirt/hooks/qemu:"
      echo "     - OOM recovery script for Sensor VM (mds)"
      echo
      echo "  3. OOM Recovery Scripts:"
      echo "     - /usr/bin/last_known_good_pid: Save VM PID"
      echo "     - /usr/bin/check_vm_state: Check and restart on OOM"
      echo "     - Root crontab: check_vm_state every 5 minutes"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • Hooks will be activated when libvirtd restarts"
      echo "  • OOM recovery will monitor Sensor VM automatically"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 INSTALLATION STATUS:"
      local network_exists="No"
      local qemu_exists="No"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        network_exists="Yes"
      fi
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        qemu_exists="Yes"
      fi
      echo "  • /etc/libvirt/hooks/network: ${network_exists}"
      echo "  • /etc/libvirt/hooks/qemu: ${qemu_exists}"
      echo "  • /usr/bin/last_known_good_pid: Installed"
      echo "  • /usr/bin/check_vm_state: Installed"
      echo "  • Root crontab: OOM recovery configured"
      echo
      echo "📄 CONFIGURATION FILES:"
      echo
      echo "# /etc/libvirt/hooks/network (first 30 lines)"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        sed -n '1,30p' /etc/libvirt/hooks/network
      else
        echo "/etc/libvirt/hooks/network does not exist."
      fi
      echo
      echo "# /etc/libvirt/hooks/qemu (first 40 lines)"
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        sed -n '1,40p' /etc/libvirt/hooks/qemu
      else
        echo "/etc/libvirt/hooks/qemu does not exist."
      fi
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • Hooks are active and will be used by libvirtd"
      echo "  • OOM recovery will monitor Sensor VM (mds) automatically"
      echo "  • check_vm_state runs every 5 minutes via cron"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 06 - Result Summary" "${tmp_info}"

  log "[STEP 06] libvirt hooks installation completed."

  return 0
}

#######################################
# STEP 06 - NAT Mode (OpenXDR NAT hooks )
#######################################
step_06_nat_hooks() {
  log "[STEP 08 NAT Mode] Installing OpenXDR NAT libvirt hooks"

  local tmp_info="${STATE_DIR}/xdr_step06_nat_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current hooks Status Summary
  #######################################
  {
    echo "NAT Mode libvirt hooks Installation"
    echo "=============================="
    echo
    echo "Hooks to be installed:"
    echo "- /etc/libvirt/hooks/network (NAT MASQUERADE)"
    echo "- /etc/libvirt/hooks/qemu (Sensor DNAT + OOM restart)"
    echo
    echo "Sensor VM Configuration:"
    echo "- VM name: mds"
    echo "- inside IP: 192.168.122.2"
    echo "- NAT bridge: virbr0"
    echo "- Management interface: mgt"
  } > "${tmp_info}"

  show_textbox "STEP 06 NAT Mode - Installation unit" "${tmp_info}"

  if ! whiptail_yesno "STEP 06 NAT Mode Execution Check" "Install libvirt hooks for NAT Mode.\n\n- Apply OpenXDR NAT configuration\n- Configure Sensor VM (mds) DNAT\n- OOM recovery\n\nDo you want to continue?" 15 70
  then
    log "User canceled STEP 06 NAT Mode execution."
    return 0
  fi

  #######################################
  # 1) /etc/libvirt/hooks Directory Creation
  #######################################
  log "[STEP 06 NAT Mode] Creating /etc/libvirt/hooks directory"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/libvirt/hooks Directory Creation"
  else
    sudo mkdir -p /etc/libvirt/hooks
  fi

  #######################################
  # 2) /etc/libvirt/hooks/network Creation (OpenXDR Method)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08 NAT Mode] Creating ${HOOK_NET} (NAT MASQUERADE)"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Existing ${HOOK_NET} backed up to ${HOOK_NET_BAK}"
    else
      log "[DRY-RUN] Existing ${HOOK_NET} ${HOOK_NET_BAK} backup scheduled"
    fi
  fi

  local net_hook_content
  net_hook_content=$(cat <<'EOF'
#!/bin/bash
# XDR Sensor NAT Mode - Network Hook
# Based on OpenXDR NAT configuration

if [ "$1" = "default" ]; then
    MGT_BR_NET='192.168.122.0/24'
    MGT_BR_IP='192.168.122.1'
    MGT_BR_DEV='virbr0'
    RT='rt_mgt'

    if [ "$2" = "stopped" ] || [ "$2" = "reconnect" ]; then
        ip route del $MGT_BR_NET via $MGT_BR_IP dev $MGT_BR_DEV table $RT 2>/dev/null || true
        ip rule del from $MGT_BR_NET table $RT 2>/dev/null || true
        # MASQUERADE rule remove
        iptables -t nat -D POSTROUTING -s $MGT_BR_NET ! -d $MGT_BR_NET -j MASQUERADE 2>/dev/null || true
    fi

    if [ "$2" = "started" ] || [ "$2" = "reconnect" ]; then
        ip route add $MGT_BR_NET via $MGT_BR_IP dev $MGT_BR_DEV table $RT 2>/dev/null || true
        ip rule add from $MGT_BR_NET table $RT 2>/dev/null || true
        # MASQUERADE rule add
        iptables -t nat -I POSTROUTING -s $MGT_BR_NET ! -d $MGT_BR_NET -j MASQUERADE
    fi
fi
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${HOOK_NET} NAT network hook will be created"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
    sudo chmod +x "${HOOK_NET}"
  fi

  #######################################
  # 3) /etc/libvirt/hooks/qemu Creation (Sensor VM + OOM restart)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06 NAT Mode] Creating ${HOOK_QEMU} (Sensor DNAT + OOM recovery)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Existing ${HOOK_QEMU} backed up to ${HOOK_QEMU_BAK}"
    else
      log "[DRY-RUN] Existing ${HOOK_QEMU} ${HOOK_QEMU_BAK} backup scheduled"
    fi
  fi

  local qemu_hook_content
  qemu_hook_content=$(cat <<'EOF'
#!/bin/bash
# XDR Sensor NAT Mode - QEMU Hook
# Based on OpenXDR NAT configuration with sensor VM (mds) DNAT

# UI exception list (Sensor inside  IP)
UI_EXC_LIST=(192.168.122.2)
IPSET_UI='ui'

# ipset ui  toif Creation +  IP add
IPSET_CONFIG=$(echo -n $(ipset list $IPSET_UI 2>/dev/null))
if ! [[ $IPSET_CONFIG =~ $IPSET_UI ]]; then
  ipset create $IPSET_UI hash:ip 2>/dev/null || true
  for IP in ${UI_EXC_LIST[@]}; do
    ipset add $IPSET_UI $IP 2>/dev/null || true
  done
fi

########################
# mds (Sensor) NAT/DNAT configuration
########################
if [ "${1}" = "mds" ]; then
  GUEST_IP=192.168.122.2
  HOST_SSH_PORT=2222
  GUEST_SSH_PORT=22
  # Sensor ports (based on OpenXDR datasensor)
  TCP_PORTS=(514 2055 5000:6000)
  VXLAN_PORTS=(4789 8472)
  UDP_PORTS=(514 2055 5000:6000)
  BRIDGE='virbr0'
  MGT_INTF='mgt'

  if [ "${2}" = "stopped" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT 2>/dev/null || true
    /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT 2>/dev/null || true
    
    for PORT in ${TCP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT 2>/dev/null || true
      else
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT 2>/dev/null || true
      fi
    done

    for PORT in ${UDP_PORTS[@]}; do
      if [[ $PORT =~ ":" ]]; then
        DNAT_PORT=$(echo $PORT | tr -s ":" "-")
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$DNAT_PORT 2>/dev/null || true
      else
        /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT 2>/dev/null || true
      fi
    done
    
    for PORT in ${VXLAN_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p udp ! -s ${GUEST_IP} --dport $PORT -j DNAT --to $GUEST_IP:$PORT 2>/dev/null || true
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
    
    # OOM restart script start (Bridge Mode)
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# OOM restart script
########################
# (Bridge Mode OOM restart script)
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${HOOK_QEMU} Sensor DNAT + OOM recovery hook will be created"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
    sudo chmod +x "${HOOK_QEMU}"
  fi

  #######################################
  # 4) OOM restart script installation (Bridge Mode)
  #######################################
  log "[STEP 06 NAT Mode] Installing OOM recovery script (/usr/bin/last_known_good_pid)"
  # Bridge Mode and OOM restart script installation (reuse if exists)
  # (Existing step_06_bridge_hooks OOM script  )

  #######################################
  # 5) Completed whennot
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 06 NAT Mode Completed]

OpenXDR Based NAT libvirt hooks installation completed.

Installed hooks:
- /etc/libvirt/hooks/network (NAT MASQUERADE)
- /etc/libvirt/hooks/qemu (Sensor DNAT + OOM recovery)

Sensor VM Network Configuration:
- VM name: mds
- Internal IP: 192.168.122.2 (configured)
- NAT bridge: virbr0 (192.168.122.0/24)
- DNAT: mgt interface port forwarding

DNAT Ports: SSH(2222), Sensor management ports
OOM recovery: activated

* libvirtd restart may be required.
EOF
)

  whiptail_msgbox "STEP 08 NAT Mode Completed" "${summary}" 18 80

  log "[STEP 06 NAT Mode] NAT libvirt hooks installation completed"

  return 0
}


step_07_sensor_download() {
  log "[STEP 07] Sensor LV Creation + Image/script Download"
  load_config

  local SENSOR_VM="mds"
  local SENSOR_INSTALL_DIR="/var/lib/libvirt/images/mds"
  local SENSOR_IMAGE_DIR="${SENSOR_INSTALL_DIR}/images"
  local SENSOR_VM_DIR="${SENSOR_IMAGE_DIR}/${SENSOR_VM}"

  # If an existing Sensor VM is present, stop and remove it before LVM configuration
  if virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
    log "[STEP 07] Existing VM detected (${SENSOR_VM}). Destroying and undefining before LVM configuration."
    run_cmd "virsh destroy ${SENSOR_VM} || true"
    run_cmd "virsh undefine ${SENSOR_VM} --remove-all-storage || virsh undefine ${SENSOR_VM} || true"
    if [[ -d "${SENSOR_VM_DIR}" ]]; then
      run_cmd "sudo rm -rf ${SENSOR_VM_DIR}"
    fi
  fi

  # User Configuration  (OpenXDR Method: ubuntu-vg use)
  : "${LV_LOCATION:=ubuntu-vg}"
  
  #######################################
  # 0) Get LV Size from user input
  #######################################
  # Check ubuntu-vg total size and available space
  local ubuntu_vg_total_size ubuntu_lv_size ubuntu_lv_gb available_gb
  ubuntu_vg_total_size=$(vgs ubuntu-vg --noheadings --units g --nosuffix -o size 2>/dev/null | tr -d ' ' || echo "0")
  
  if command -v lvs >/dev/null 2>&1; then
    ubuntu_lv_size=$(lvs ubuntu-vg/ubuntu-lv --noheadings --units g --nosuffix -o lv_size 2>/dev/null | tr -d ' ' || echo "0")
    ubuntu_lv_gb=${ubuntu_lv_size%.*}
  else
    ubuntu_lv_gb=0
  fi
  
  local ubuntu_vg_total_gb=${ubuntu_vg_total_size%.*}
  available_gb=$((ubuntu_vg_total_gb - ubuntu_lv_gb))
  [[ ${available_gb} -lt 0 ]] && available_gb=0
  
  local disk_info_msg="Disk Information:\n- ubuntu-vg Total Size: ${ubuntu_vg_total_size}GB\n- System use (ubuntu-lv): ${ubuntu_lv_size}GB\n- Available: approximately ${available_gb}GB\n\n"
  
  local lv_size_gb
  lv_size_gb=$(whiptail_inputbox "STEP 07 - Sensor LV Creation Size" "${disk_info_msg}Enter Sensor LV Creation size (GB):\n\nDefault: 300GB\nMinimum Size: 100GB\n\nSize (GB):" "300" 16 70) || {
    log "User canceled Sensor LV size configuration."
    return 1
  }
  
  # Validate input
  if ! [[ "${lv_size_gb}" =~ ^[0-9]+$ ]]; then
    whiptail_msgbox "Input Error" "Please enter a valid number.\nInput value: ${lv_size_gb}"
    log "Invalid LV size input: ${lv_size_gb}"
    return 1
  fi
  
  # Minimum Size Verification (100GB)
  if [[ "${lv_size_gb}" -lt 100 ]]; then
    whiptail_msgbox "Size Insufficient" "Minimum size must be at least 100GB.\nInput value: ${lv_size_gb}GB"
    log "LV size too small: ${lv_size_gb}GB"
    return 1
  fi
  
  LV_SIZE_GB="${lv_size_gb}"
  save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"
  log "[STEP 07] User Configuration - LV Location: ${LV_LOCATION}, LV Size: ${LV_SIZE_GB}GB"

  local tmp_status="/tmp/xdr_step09_status.txt"

  #######################################
  # 0) Current status check
  #######################################
  local lv_exists="no"
  local mounted="no"
  local lv_path=""

  # LV Path validation (VG name not in path or all paths)
  if [[ "${LV_LOCATION}" =~ ^/dev/ ]]; then
    # If full path is provided - use default VG creation
    lv_path="sensor-vg/lv_sensor_root"
  else
    # VG name only case
    lv_path="${LV_LOCATION}/lv_sensor_root"
  fi

  if lvs "${lv_path}" >/dev/null 2>&1; then
    lv_exists="yes"
  fi

  local mount_point="/var/lib/libvirt/images/mds"
  if mountpoint -q "${mount_point}" 2>/dev/null; then
    mounted="yes"
  fi

  {
    echo "Current Sensor LV Status"
    echo "-------------------"
    echo "LV Path: ${lv_path}"
    echo "lv_sensor_root LV Exists: ${lv_exists}"
    echo "${mount_point} mount: ${mounted}"
    echo
    echo "User Configuration:"
    echo "  - LV Location: ${LV_LOCATION}"
    echo "  - LV Size: ${LV_SIZE_GB}GB"
    echo
    echo " Next steps to be executed:"
    echo "  1) LV(lv_sensor_root) Creation (${LV_SIZE_GB}GB)"
    echo "  2) ext4 FileSystem Creation and ${mount_point} mount"
    echo "  3) /etc/fstab Auto mount "
    echo "  4) Sensor image and deployment script download"
    echo "     - virt_deploy_modular_ds.sh"
    echo "     - aella-modular-ds-${SENSOR_VERSION:-6.2.0}.qcow2"
    echo "  5) Ownership configuration for libvirt/qemu"
  } > "${tmp_status}"

  show_textbox "STEP 07 - Sensor LV and Download unit" "${tmp_status}"

  # If LV is already configured, skip LV creation and only download if not already downloaded
  local skip_lv_creation="no"
  if [[ "${lv_exists}" == "yes" && "${mounted}" == "yes" ]]; then
    if whiptail_yesno "STEP 07 - LV Already Configured" "lv_sensor_root and ${mount_point} are already configured.\nPath: ${lv_path}\n\nSkip LV creation/mount and only download qcow2 if not already downloaded?" 12 80
    then
      log "LV already exists, skipping LV creation/mount and only downloading if not already downloaded."
      skip_lv_creation="yes"
    else
      log "User canceled STEP 07 execution."
    fi
  fi

  if ! whiptail_yesno "STEP 07 Execution Check" "Do you want to create Sensor LV and download image?" 10 60
  then
    log "User canceled STEP 07 execution."
    return 0
  fi

  #######################################
  # 1) LV Creation (only if it does not already exist) - OpenXDR Method
  #######################################
  if [[ "${skip_lv_creation}" == "no" ]]; then
    if [[ "${lv_exists}" == "no" ]]; then
    log "[STEP 07] Creating lv_sensor_root LV (${LV_SIZE_GB}GB)"
    
    # OpenXDR Method: Existing ubuntu-vg   use
    local UBUNTU_VG="ubuntu-vg"
    local SENSOR_ROOT_LV="lv_sensor_root"
    
    if lvs "${UBUNTU_VG}/${SENSOR_ROOT_LV}" >/dev/null 2>&1; then
      log "[STEP 07] LV ${UBUNTU_VG}/${SENSOR_ROOT_LV} already exists -> skipping creation"
      lv_path="${UBUNTU_VG}/${SENSOR_ROOT_LV}"
    else
      log "[STEP 07] Creating lv_sensor_root LV in existing ubuntu-vg"
      run_cmd "sudo lvcreate -L ${LV_SIZE_GB}G -n ${SENSOR_ROOT_LV} ${UBUNTU_VG}"
      lv_path="${UBUNTU_VG}/${SENSOR_ROOT_LV}"
      
      log "[STEP 07] Creating ext4 filesystem"
      run_cmd "sudo mkfs.ext4 -F /dev/${lv_path}"
    fi
    else
      log "[STEP 07] lv_sensor_root LV already exists (${lv_path}) -> skipping LV creation"
    fi

    #######################################
    # 2) mount point creation and mount
    #######################################
    log "[STEP 07] Creating ${mount_point} directory and mounting"
    run_cmd "sudo mkdir -p ${mount_point}"
    
    # Safety check: ensure mount point is not already mounted by different device
    local mounted_device=""
    if mountpoint -q "${mount_point}" 2>/dev/null; then
      mounted_device=$(findmnt -n -o SOURCE "${mount_point}" 2>/dev/null || echo "")
      if [[ -n "${mounted_device}" && "${mounted_device}" != "/dev/${lv_path}" ]]; then
        log "[ERROR] ${mount_point} is already mounted by ${mounted_device}, expected /dev/${lv_path}"
        whiptail_msgbox "STEP 07 - Mount Error" "${mount_point} is already mounted by a different device (${mounted_device}).\n\nPlease unmount it first or use a different mount point." 12 80
        return 1
      fi
    fi
    
    if [[ "${mounted}" == "no" ]]; then
      log "[STEP 07] LV mount: /dev/${lv_path} -> ${mount_point}"
      run_cmd "sudo mount /dev/${lv_path} ${mount_point}"
    else
      log "[STEP 07] ${mount_point} is already mounted -> skipping mount"
    fi

    #######################################
    # 3) fstab registration and mount check
    #######################################
    log "[STEP 07] Adding auto mount entry to /etc/fstab"
    local SENSOR_FSTAB_LINE="/dev/${lv_path} ${mount_point} ext4 defaults,noatime 0 2"
    append_fstab_if_missing "${SENSOR_FSTAB_LINE}" "${mount_point}"
    
    # Execute mount -a to apply fstab
    log "[STEP 07] Executing systemctl daemon-reload and mount -a"
    run_cmd "sudo systemctl daemon-reload"
    run_cmd "sudo mount -a"
    
    # Mount status check
    if mountpoint -q "${mount_point}" 2>/dev/null; then
      log "[STEP 07] ${mount_point} mount successful"
    else
      log "[WARN] ${mount_point} mount failed - mount may be required"
      run_cmd "sudo mount /dev/${lv_path} ${mount_point}"
    fi
    
    #######################################
    # 4) Ownership configuration (libvirt/qemu)
    #######################################
    log "[STEP 07] Configuring ownership for ${mount_point} (libvirt/qemu)"
    if id stellar >/dev/null 2>&1; then
      run_cmd "sudo chown -R stellar:stellar ${mount_point}"
      log "[STEP 07] ${mount_point} ownership change completed"
    else
      log "[WARN] User 'stellar' does not exist. Cannot change ownership."
    fi
  else
    log "[STEP 07] LV creation/mount is already configured -> skipping"
  fi

  #######################################
  # 5) Download Directory Configuration (create if not already exists)
  #######################################
  local SENSOR_IMAGE_DIR="/var/lib/libvirt/images/mds/images"
  run_cmd "sudo mkdir -p ${SENSOR_IMAGE_DIR}"

  #######################################
  # 6-A) Check if existing 1GB+ qcow2 file can be reused (OpenXDR pattern)
  #######################################
  local qcow2_name="aella-modular-ds-${SENSOR_VERSION}.qcow2"
  local use_local_qcow=0
  local local_qcow=""
  local local_qcow_size_h=""
  
  local search_dir="."
  
  # 1GB(=1000M) this *.qcow2     File 1unit Selection (OpenXDR Method)
  local_qcow="$(
    find "${search_dir}" -maxdepth 1 -type f -name '*.qcow2' -size +1000M -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}'
  )"
  
  if [[ -n "${local_qcow}" ]]; then
    local_qcow_size_h="$(ls -lh "${local_qcow}" 2>/dev/null | awk '{print $5}')"
    
    local msg
    msg="Found qcow2 file larger than 1GB in current directory.\n\n"
    msg+="  File: ${local_qcow}\n"
    msg+="  Size: ${local_qcow_size_h}\n\n"
    msg+="Do you want to use this file for Sensor VM deployment without downloading?\n\n"
    msg+="[Yes] Use this file (skip download)\n"
    msg+="[No] Use existing file or download"
    
    if whiptail_yesno "STEP 07 - Reuse Local qcow2" "${msg}"; then
      use_local_qcow=1
      log "[STEP 07] User chose to use local qcow2 file (${local_qcow})."
      
      # Check if target already has different version qcow2 file
      local existing_qcow2
      existing_qcow2=$(find "${SENSOR_IMAGE_DIR}" -maxdepth 1 -type f -name "aella-modular-ds-*.qcow2" 2>/dev/null | head -n1)
      
      if [[ -n "${existing_qcow2}" ]]; then
        local existing_version
        existing_version=$(basename "${existing_qcow2}" | sed -n 's/aella-modular-ds-\([0-9.]*\)\.qcow2/\1/p')
        
        if [[ "${existing_version}" != "${SENSOR_VERSION}" ]]; then
          log "[STEP 07] Existing qcow2 file with different version found: ${existing_qcow2} (version: ${existing_version})"
          log "[STEP 07] Removing old version qcow2 file before copying new version"
          if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] sudo rm -f ${existing_qcow2}"
          else
            run_cmd "sudo rm -f ${existing_qcow2}"
            log "[STEP 07] Old version qcow2 file removed: ${existing_qcow2}"
          fi
        else
          log "[STEP 07] Existing qcow2 file with same version found: ${existing_qcow2} (version: ${existing_version})"
          log "[STEP 07] Will overwrite with local qcow2 file"
        fi
      fi
      
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${SENSOR_IMAGE_DIR}/${qcow2_name}\""
      else
        run_cmd "sudo cp \"${local_qcow}\" \"${SENSOR_IMAGE_DIR}/${qcow2_name}\""
        log "[STEP 07] Local qcow2 copied to ${SENSOR_IMAGE_DIR}/${qcow2_name} (completed)"
      fi
    else
      log "[STEP 07] User chose not to use local qcow2, will use existing file/download."
    fi
  else
    log "[STEP 07] No local qcow2 file (1GB+) found -> using default download/existing file."
  fi
  
  #######################################
  # 6-B) Download file validation (Download 1GB+ qcow2 file if needed)
  #######################################
  local need_script=1  # Script download required
  local need_qcow2=0
  local script_name="virt_deploy_modular_ds.sh"
  
  log "[STEP 07] Downloading ${script_name}"
  
  # Download qcow2 file if local file is not available
  if [[ "${use_local_qcow}" -eq 0 ]]; then
    # Default to downloading qcow2 if not using local file
    need_qcow2=1
    
    # Check if existing qcow2 file with different version exists
    local existing_qcow2
    existing_qcow2=$(find "${SENSOR_IMAGE_DIR}" -maxdepth 1 -type f -name "aella-modular-ds-*.qcow2" 2>/dev/null | head -n1)
    
    if [[ -n "${existing_qcow2}" ]]; then
      local existing_version
      existing_version=$(basename "${existing_qcow2}" | sed -n 's/aella-modular-ds-\([0-9.]*\)\.qcow2/\1/p')
      
      if [[ "${existing_version}" != "${SENSOR_VERSION}" ]]; then
        log "[STEP 07] Existing qcow2 file with different version found: ${existing_qcow2} (version: ${existing_version})"
        log "[STEP 07] Removing old version qcow2 file before downloading new version"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] sudo rm -f ${existing_qcow2}"
        else
          run_cmd "sudo rm -f ${existing_qcow2}"
          log "[STEP 07] Old version qcow2 file removed: ${existing_qcow2}"
        fi
        # Keep need_qcow2=1 to download new version
      else
        log "[STEP 07] Existing qcow2 file with same version found: ${existing_qcow2} (version: ${existing_version})"
        log "[STEP 07] Skipping download - using existing file"
        need_qcow2=0
      fi
    fi
    
    if [[ "${need_qcow2}" -eq 1 ]]; then
      log "[STEP 07] Downloading ${qcow2_name}"
    fi
  else
    # When using local qcow2, check if target already has different version
    local existing_qcow2
    existing_qcow2=$(find "${SENSOR_IMAGE_DIR}" -maxdepth 1 -type f -name "aella-modular-ds-*.qcow2" 2>/dev/null | head -n1)
    
    if [[ -n "${existing_qcow2}" ]]; then
      local existing_version
      existing_version=$(basename "${existing_qcow2}" | sed -n 's/aella-modular-ds-\([0-9.]*\)\.qcow2/\1/p')
      
      if [[ "${existing_version}" != "${SENSOR_VERSION}" ]]; then
        log "[STEP 07] Existing qcow2 file with different version found: ${existing_qcow2} (version: ${existing_version})"
        log "[STEP 07] Removing old version qcow2 file before copying new version"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] sudo rm -f ${existing_qcow2}"
        else
          run_cmd "sudo rm -f ${existing_qcow2}"
          log "[STEP 07] Old version qcow2 file removed: ${existing_qcow2}"
        fi
      fi
    fi
    
    log "[STEP 07] Using local qcow2 file -> skipping download"
  fi

  #######################################
  # 7) ACPSfrom Download (Required Fileonly)
  #######################################
  local script_url="${ACPS_BASE_URL}/release/${SENSOR_VERSION}/datasensor/${script_name}"
  local image_url="${ACPS_BASE_URL}/release/${SENSOR_VERSION}/datasensor/${qcow2_name}"
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] cd ${SENSOR_IMAGE_DIR} && wget --user='${ACPS_USERNAME}' --password='***' '${script_url}'"
    
    if [[ "${need_qcow2}" -eq 1 ]]; then
      log "[DRY-RUN] cd ${SENSOR_IMAGE_DIR} && wget --user='${ACPS_USERNAME}' --password='***' '${image_url}'"
    else
      log "[DRY-RUN] ${qcow2_name} local qcow2 file will be downloaded"
    fi
  else
    # Download can be performed
    if [[ "${need_qcow2}" -eq 0 ]]; then
      log "[STEP 07] Using local qcow2 -> downloading script only."
    fi
    
    (
      cd "${SENSOR_IMAGE_DIR}" || exit 1
      
      # 1) Deployment script Download ()
      log "[STEP 07] Starting ${script_name} download: ${script_url}"
      echo "=== Deployment script download in progress ==="
      if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${script_url}" 2>&1 | tee -a "${LOG_FILE}"; then
        chmod +x "${script_name}"
        echo "=== Deployment script download completed ==="
        log "[STEP 07] ${script_name} download completed"
      else
        log "[ERROR] ${script_name} Download Failed"
        exit 1
      fi
      
      # 2) Download qcow2 image (skip if local qcow2 is being used)
      if [[ "${need_qcow2}" -eq 1 ]]; then
        # Remove existing qcow2 file if it exists (different version or same)
        if [[ -f "${qcow2_name}" ]]; then
          log "[STEP 07] Removing existing qcow2 file before download: ${qcow2_name}"
          rm -f "${qcow2_name}"
        fi
        
        log "[STEP 07] Starting ${qcow2_name} download: ${image_url}"
        echo "=== ${qcow2_name} download in progress (large file, this may take some time) ==="
        echo "File size may be large, please wait..."
        if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${image_url}" 2>&1 | tee -a "${LOG_FILE}"; then
          echo "=== ${qcow2_name} download completed ==="
          log "[STEP 07] ${qcow2_name} download completed"
        else
          log "[ERROR] ${qcow2_name} Download Failed"
          exit 1
        fi
      fi
    ) || {
      log "[ERROR] Error occurred during ACPS download"
      return 1
    }
    
    log "[STEP 07] Sensor image and script download completed"
  fi

  #######################################
  # 8) Ownership configuration (if not already done)
  #######################################
  log "[STEP 07] Verifying ownership for ${mount_point}"
  if id stellar >/dev/null 2>&1; then
    run_cmd "sudo chown -R stellar:stellar ${mount_point}"
  else
    log "[WARN] User 'stellar' does not exist. Skipping ownership change."
  fi

  #######################################
  # 9) Result Check
  #######################################
  local final_lv="unknown"
  local final_mount="unknown"
  local final_image="unknown"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_lv="(DRY-RUN mode)"
    final_mount="(DRY-RUN mode)"
    final_image="(DRY-RUN mode)"
  else
    # Re-checking LV
    if lvs "${lv_path}" >/dev/null 2>&1; then
      final_lv="OK"
    else
      final_lv="FAIL"
    fi

    # Re-checking mount
    if mountpoint -q "${mount_point}"; then
      final_mount="OK"
    else
      final_mount="FAIL"
    fi

    # Check if file already exists
    if [[ -f "${SENSOR_IMAGE_DIR}/${qcow2_name}" ]]; then
      final_image="OK"
    else
      final_image="FAIL"
    fi
  fi

  {
    echo "STEP 07 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • lv_sensor_root LV: ${final_lv}"
      echo "  • ${mount_point} mount: ${final_mount}"
      echo "  • Sensor image status: ${final_image}"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. LVM Volume Creation:"
      echo "     - lv_sensor_root (${LV_SIZE_GB}GB) would be created in ubuntu-vg"
      echo "     - ext4 filesystem would be created"
      echo
      echo "  2. Mount Configuration:"
      echo "     - ${mount_point} directory would be created"
      echo "     - LV would be mounted to ${mount_point}"
      echo "     - /etc/fstab entry would be added"
      echo
      echo "  3. Image Download:"
      echo "     - Download location: ${SENSOR_IMAGE_DIR}"
      echo "     - Image file: ${qcow2_name}"
      echo "     - Deployment script: virt_deploy_modular_ds.sh"
      echo "     - Files would be downloaded from ACPS"
      echo
      echo "  4. Ownership Configuration:"
      echo "     - ${mount_point} ownership would be set to stellar:stellar"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • LV creation requires sufficient space in ubuntu-vg"
      echo "  • Image download requires ACPS credentials"
      echo "  • Download may take significant time depending on file size"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 INSTALLATION STATUS:"
      echo "  • lv_sensor_root LV: ${final_lv}"
      echo "  • ${mount_point} mount: ${final_mount}"
      echo "  • Sensor image status: ${final_image}"
      echo
      echo "📦 STORAGE CONFIGURATION:"
      echo "  • LV Path: ${lv_path}"
      echo "  • LV Size: ${LV_SIZE_GB}GB"
      echo "  • Mount Point: ${mount_point}"
      echo "  • Filesystem: ext4"
      echo "  • Auto-mount: Configured in /etc/fstab"
      echo
      echo "📥 DOWNLOAD INFORMATION:"
      echo "  • Download Location: ${SENSOR_IMAGE_DIR}"
      echo "  • Image file: ${qcow2_name}"
      echo "  • Deployment script: virt_deploy_modular_ds.sh"
      if [[ "${final_image}" == "OK" ]]; then
        local image_size=""
        if [[ -f "${SENSOR_IMAGE_DIR}/${qcow2_name}" ]]; then
          image_size=$(ls -lh "${SENSOR_IMAGE_DIR}/${qcow2_name}" 2>/dev/null | awk '{print $5}' || echo "unknown")
        fi
        echo "  • Image file size: ${image_size}"
      fi
      echo
      echo "👤 OWNERSHIP:"
      echo "  • ${mount_point}: stellar:stellar"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • LV and mount are configured and ready for VM deployment"
      echo "  • Image files are ready for STEP 08 (VM Deployment)"
    fi
  } > "${tmp_status}"

  show_textbox "STEP 07 Result Summary" "${tmp_status}"

  log "[STEP 07] Sensor LV Creation and image download completed"

  return 0
}


step_08_sensor_deploy() {
  log "[STEP 08] Sensor VM Deployment"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 08] Sensor Network Mode: ${net_mode}"

  local tmp_status="${STATE_DIR}/xdr_step10_status.txt"

  #######################################
  # 0) Prompt for Sensor VM configuration (memory, vCPU, disk)
  #######################################
  # Calculate default values based on system resources
  # Memory allocation: 12% of total memory reserved for KVM host, remaining for Sensor
  local total_cpus total_mem_kb total_mem_gb host_reserve_gb available_mem_gb
  total_cpus=$(nproc)
  total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  total_mem_gb=$((total_mem_kb / 1024 / 1024))
  # Reserve 12% of total memory for KVM host
  host_reserve_gb=$((total_mem_gb * 12 / 100))
  available_mem_gb=$((total_mem_gb - host_reserve_gb))
  [[ ${available_mem_gb} -le 0 ]] && available_mem_gb=16
  
  # Default memory: available memory (after 12% host reserve) for Sensor
  local default_sensor_mem_gb=${available_mem_gb}
  [[ ${default_sensor_mem_gb} -lt 8 ]] && default_sensor_mem_gb=8
  
  # Default vCPU: Total CPUs minus 4 (4 CPUs reserved for host)
  local default_sensor_vcpus=$((total_cpus - 4))
  [[ ${default_sensor_vcpus} -lt 2 ]] && default_sensor_vcpus=2
  
  local default_sensor_disk_gb=300
  
  # Use existing values if set, otherwise use calculated defaults
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_VCPUS:=}"
  : "${LV_SIZE_GB:=}"
  
  # 1) Memory
  # Always use calculated default value for input box (not saved value)
  local sensor_mem_gb="${default_sensor_mem_gb}"
  local _SENSOR_MEM_INPUT
  local mem_input_rc
  _SENSOR_MEM_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM memory" "Enter memory (GB) for Sensor VM.\n\nTotal memory: ${total_mem_gb}GB\nHost reserve (12%): ${host_reserve_gb}GB\nAvailable: ${available_mem_gb}GB\nDefault value: ${default_sensor_mem_gb}GB\nExample: Enter 32" "${default_sensor_mem_gb}" 14 80)"
  mem_input_rc=$?

  if [ ${mem_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 08] User canceled memory input. Exiting step."
    return 0
  fi

  if [ -n "${_SENSOR_MEM_INPUT}" ]; then
    if [[ "${_SENSOR_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_MEM_INPUT}" -gt 0 ]; then
      sensor_mem_gb="${_SENSOR_MEM_INPUT}"
    else
      whiptail_msgbox "STEP 08 - Sensor memory" "Invalid memory value.\nUsing current default (${default_sensor_mem_gb} GB)." 10 70
      sensor_mem_gb="${default_sensor_mem_gb}"
    fi
  else
    # Empty input - use default
    sensor_mem_gb="${default_sensor_mem_gb}"
  fi

  # 2) vCPU
  local vcpu_default_msg="Total CPUs: ${total_cpus}\nReserved for host: 4\nDefault value: ${default_sensor_vcpus}"
  local _SENSOR_VCPU_INPUT
  local vcpu_input_rc
  _SENSOR_VCPU_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM vCPU" "Enter number of vCPUs for Sensor VM.\n\n${vcpu_default_msg}\nExample: Enter 8" "${default_sensor_vcpus}" 12 80)"
  vcpu_input_rc=$?

  if [ ${vcpu_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 08] User canceled vCPU input. Exiting step."
    return 0
  fi

  local sensor_vcpus="${default_sensor_vcpus}"
  if [ -n "${_SENSOR_VCPU_INPUT}" ]; then
    if [[ "${_SENSOR_VCPU_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_VCPU_INPUT}" -gt 0 ]; then
      sensor_vcpus="${_SENSOR_VCPU_INPUT}"
    else
      whiptail_msgbox "STEP 08 - Sensor vCPU" "Invalid vCPU value.\nUsing current default (${default_sensor_vcpus})." 10 70
      sensor_vcpus="${default_sensor_vcpus}"
    fi
  else
    # Empty input - use default
    sensor_vcpus="${default_sensor_vcpus}"
  fi

  # 3) Disk
  local _SENSOR_DISK_INPUT
  local disk_input_rc
  _SENSOR_DISK_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM disk" "Enter disk size (GB) for Sensor VM.\n\nDefault value: ${default_sensor_disk_gb}GB\nMinimum: 100GB\nExample: Enter 300" "${default_sensor_disk_gb}" 12 80)"
  disk_input_rc=$?

  if [ ${disk_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 08] User canceled disk input. Exiting step."
    return 0
  fi

  local sensor_disk_gb="${default_sensor_disk_gb}"
  if [ -n "${_SENSOR_DISK_INPUT}" ]; then
    if [[ "${_SENSOR_DISK_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_DISK_INPUT}" -gt 0 ]; then
      if [[ "${_SENSOR_DISK_INPUT}" -lt 100 ]]; then
        whiptail_msgbox "STEP 08 - Sensor disk" "Minimum disk size is 100GB.\nUsing current default (${default_sensor_disk_gb} GB)." 10 70
        sensor_disk_gb="${default_sensor_disk_gb}"
      else
        sensor_disk_gb="${_SENSOR_DISK_INPUT}"
      fi
    else
      whiptail_msgbox "STEP 08 - Sensor disk" "Invalid disk size value.\nUsing current default (${default_sensor_disk_gb} GB)." 10 70
      sensor_disk_gb="${default_sensor_disk_gb}"
    fi
  else
    # Empty input - use default
    sensor_disk_gb="${default_sensor_disk_gb}"
  fi

  # Convert memory to MB
  local mem_mb=$(( sensor_mem_gb * 1024 ))
  local cpus="${sensor_vcpus}"
  local disksize="${sensor_disk_gb}"

  # 4) Bridge Mode: IP Configuration (if bridge mode)
  local sensor_ip sensor_netmask sensor_gateway sensor_dns
  if [[ "${net_mode}" == "bridge" ]]; then
    # Use existing values if set, otherwise use defaults
    local default_ip="${SENSOR_VM_IP:-192.168.100.100}"
    local default_netmask="${SENSOR_VM_NETMASK:-255.255.255.0}"
    local default_gateway="${SENSOR_VM_GATEWAY:-192.168.100.1}"
    local default_dns="${SENSOR_VM_DNS:-8.8.8.8}"
    
    # IP Address
    local _SENSOR_IP_INPUT
    local ip_input_rc
    _SENSOR_IP_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM IP Address" "Enter IP address for Sensor VM (Bridge Mode).\n\nDefault value: ${default_ip}\nExample: 192.168.100.100" "${default_ip}" 12 70)"
    ip_input_rc=$?
    
    if [ ${ip_input_rc} -ne 0 ]; then
      log "[STEP 08] User canceled IP input. Exiting step."
      return 0
    fi
    
    if [ -n "${_SENSOR_IP_INPUT}" ]; then
      if [[ "${_SENSOR_IP_INPUT}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        sensor_ip="${_SENSOR_IP_INPUT}"
      else
        whiptail_msgbox "STEP 08 - Sensor VM IP" "Invalid IP address format.\nUsing default (${default_ip})." 10 70
        sensor_ip="${default_ip}"
      fi
    else
      sensor_ip="${default_ip}"
    fi
    
    # Netmask
    local _SENSOR_NETMASK_INPUT
    local netmask_input_rc
    _SENSOR_NETMASK_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM Netmask" "Enter netmask for Sensor VM (Bridge Mode).\n\nDefault value: ${default_netmask}\nExample: 255.255.255.0" "${default_netmask}" 12 70)"
    netmask_input_rc=$?
    
    if [ ${netmask_input_rc} -ne 0 ]; then
      log "[STEP 08] User canceled netmask input. Exiting step."
      return 0
    fi
    
    if [ -n "${_SENSOR_NETMASK_INPUT}" ]; then
      if [[ "${_SENSOR_NETMASK_INPUT}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        sensor_netmask="${_SENSOR_NETMASK_INPUT}"
      else
        whiptail_msgbox "STEP 08 - Sensor VM Netmask" "Invalid netmask format.\nUsing default (${default_netmask})." 10 70
        sensor_netmask="${default_netmask}"
      fi
    else
      sensor_netmask="${default_netmask}"
    fi
    
    # Gateway
    local _SENSOR_GATEWAY_INPUT
    local gateway_input_rc
    _SENSOR_GATEWAY_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM Gateway" "Enter gateway IP for Sensor VM (Bridge Mode).\n\nDefault value: ${default_gateway}\nExample: 192.168.100.1" "${default_gateway}" 12 70)"
    gateway_input_rc=$?
    
    if [ ${gateway_input_rc} -ne 0 ]; then
      log "[STEP 08] User canceled gateway input. Exiting step."
      return 0
    fi
    
    if [ -n "${_SENSOR_GATEWAY_INPUT}" ]; then
      if [[ "${_SENSOR_GATEWAY_INPUT}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        sensor_gateway="${_SENSOR_GATEWAY_INPUT}"
      else
        whiptail_msgbox "STEP 08 - Sensor VM Gateway" "Invalid gateway format.\nUsing default (${default_gateway})." 10 70
        sensor_gateway="${default_gateway}"
      fi
    else
      sensor_gateway="${default_gateway}"
    fi
    
    # DNS
    local _SENSOR_DNS_INPUT
    local dns_input_rc
    _SENSOR_DNS_INPUT="$(whiptail_inputbox "STEP 08 - Sensor VM DNS" "Enter DNS server IP for Sensor VM (Bridge Mode).\n\nDefault value: ${default_dns}\nExample: 8.8.8.8" "${default_dns}" 12 70)"
    dns_input_rc=$?
    
    if [ ${dns_input_rc} -ne 0 ]; then
      log "[STEP 08] User canceled DNS input. Exiting step."
      return 0
    fi
    
    if [ -n "${_SENSOR_DNS_INPUT}" ]; then
      if [[ "${_SENSOR_DNS_INPUT}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        sensor_dns="${_SENSOR_DNS_INPUT}"
      else
        whiptail_msgbox "STEP 08 - Sensor VM DNS" "Invalid DNS format.\nUsing default (${default_dns})." 10 70
        sensor_dns="${default_dns}"
      fi
    else
      sensor_dns="${default_dns}"
    fi
    
    # Save IP configuration
    SENSOR_VM_IP="${sensor_ip}"
    SENSOR_VM_NETMASK="${sensor_netmask}"
    SENSOR_VM_GATEWAY="${sensor_gateway}"
    SENSOR_VM_DNS="${sensor_dns}"
    save_config_var "SENSOR_VM_IP" "${SENSOR_VM_IP}"
    save_config_var "SENSOR_VM_NETMASK" "${SENSOR_VM_NETMASK}"
    save_config_var "SENSOR_VM_GATEWAY" "${SENSOR_VM_GATEWAY}"
    save_config_var "SENSOR_VM_DNS" "${SENSOR_VM_DNS}"
    
    log "[STEP 08] Bridge Mode IP Configuration: IP=${sensor_ip}, Netmask=${sensor_netmask}, Gateway=${sensor_gateway}, DNS=${sensor_dns}"
  fi

  # Save configuration
  SENSOR_MEMORY_MB="${mem_mb}"
  SENSOR_VCPUS="${cpus}"
  LV_SIZE_GB="${sensor_disk_gb}"
  save_config_var "SENSOR_MEMORY_MB" "${SENSOR_MEMORY_MB}"
  save_config_var "SENSOR_VCPUS" "${SENSOR_VCPUS}"
  save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

  log "[STEP 08] Sensor VM Configuration:"
  log "  Memory: ${sensor_mem_gb}GB (${mem_mb}MB)"
  log "  vCPU: ${cpus}"
  log "  Disk: ${sensor_disk_gb}GB"

  #######################################
  # 1) Current status check
  #######################################
  local vm_exists="no"
  local vm_running="no"

  # Skip virsh check in DRY_RUN mode
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if command -v virsh >/dev/null 2>&1; then
      if virsh list --all | grep -q "\smds\s" 2>/dev/null; then
        vm_exists="yes"
        if virsh list --state-running | grep -q "\smds\s" 2>/dev/null; then
          vm_running="yes"
        fi
      fi
    else
      log "[WARN] virsh command not found, skipping VM status check"
    fi
  else
    log "[DRY-RUN] Skipping virsh VM status check"
  fi

  {
    echo "Current Sensor VM Status"
    echo "------------------"
    echo "mds VM Exists: ${vm_exists}"
    echo "mds VM Execution: ${vm_running}"
    echo
    echo "Deployment Configuration:"
    echo "- hostname: mds"
    echo "- vCPU: ${cpus}"
    echo "- Memory: ${sensor_mem_gb}GB (${mem_mb}MB)"
    echo "- Disk Size: ${sensor_disk_gb}GB"
    echo "- Install Dir: /var/lib/libvirt/images/mds"
    echo
    echo " STEP: virt_deploy_modular_ds.sh script will be used"
    echo "Sensor VM deployment (nodownload=true execution)"
  } > "${tmp_status}"

  show_textbox "STEP 08 - Sensor VM Deployment unit" "${tmp_status}"

  if [[ "${vm_exists}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 08 - Existing VM" "mds VM already exists.\n\nDo you want to redeploy the existing VM?" 12 70
    then
      log "User canceled existing VM redeployment."
      return 0
    else
      log "[STEP 08] Removing existing mds VM"
      if [[ "${vm_running}" == "yes" ]]; then
        run_cmd "virsh destroy mds"
      fi
      run_cmd "virsh undefine mds --remove-all-storage"
      
      # Remove VM disk directory to ensure clean deployment
      local vm_disk_dir="/var/lib/libvirt/images/mds/images/mds"
      if [[ -d "${vm_disk_dir}" ]]; then
        log "[STEP 08] Removing existing VM disk directory: ${vm_disk_dir}"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] sudo rm -rf ${vm_disk_dir}"
        else
          run_cmd "sudo rm -rf ${vm_disk_dir}"
          log "[STEP 08] VM disk directory removed: ${vm_disk_dir}"
        fi
      fi
    fi
  fi

  if ! whiptail_yesno "STEP 08 Execution Check" "Do you want to deploy Sensor VM?" 10 60
  then
    log "User canceled STEP 08 execution."
    return 0
  fi

  #######################################
  # 1) Deployment script Check
  #######################################
  local script_path="/var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh"
  
  if [[ ! -f "${script_path}" && "${DRY_RUN}" -eq 0 ]]; then
    whiptail_msgbox "STEP 08 - script None" "Deployment script does not exist:\n\n${script_path}\n\nPlease execute STEP 07 first." 12 80
    log "Deployment script not found: ${script_path}"
    return 1
  fi

  #######################################
  # 2) Sensor VM Deployment
  #######################################
  log "[STEP 08] Starting sensor VM deployment"

  local release="${SENSOR_VERSION}"
  local hostname="mds"
  local installdir="/var/lib/libvirt/images/mds"
  # Use values from user input above
  # cpus, mem_mb, disksize are already set from user input
  # Check if disksize already has GB suffix
  local disksize_final
  if [[ "${disksize}" =~ GB$ ]]; then
    disksize_final="${disksize}"
  else
    disksize_final="${disksize}GB"
  fi
  
  # Auto-fix nodownload: check if image exists
  local expected_image="${installdir}/images/aella-modular-ds-${release}.qcow2"
  local nodownload="true"
  if [[ ! -f "${expected_image}" ]]; then
    log "[WARN] Expected image not found: ${expected_image}"
    log "[WARN] Setting nodownload=false (will download image)"
    nodownload="false"
  else
    log "[STEP 08] Image found: ${expected_image} (nodownload=true)"
  fi
  
  # Use mem_mb for deployment (already converted from GB to MB)
  local memory="${mem_mb}"

  # Build command line for DRY_RUN (same format as actual execution)
  local cmd_line_dry="bash \"${script_path}\" -- \
    --hostname=\"${hostname}\" \
    --release=\"${release}\" \
    --CPUS=\"${cpus}\" \
    --MEM=\"${memory}\" \
    --DISKSIZE=\"${disksize_final}\" \
    --installdir=\"${installdir}\" \
    --nodownload=\"${nodownload}\" \
    --bridge=\"${BRIDGE:-virbr0}\" \
    --ip=\"${IP:-192.168.122.2}\" \
    --netmask=\"${NETMASK:-255.255.255.0}\" \
    --gw=\"${GATEWAY:-192.168.122.1}\" \
    --dns=\"${DNS:-8.8.8.8}\" \
    --nointeract=\"true\""

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Sensor VM Deployment : ${cmd_line_dry}"
  else
    log "[STEP 08] Deployment script directory: /var/lib/libvirt/images/mds/images"
    cd "/var/lib/libvirt/images/mds/images" || {
      log "ERROR: Deployment script directory check failed"
      return 1
    }
    
    # Deployment script Execution  Check
    if [[ ! -x "virt_deploy_modular_ds.sh" ]]; then
      log "[WARN] Deployment script is not executable. Adding execute permission..."
      chmod +x virt_deploy_modular_ds.sh
    fi
    
    # Deployment   
    log "[STEP 08] Starting VM deployment:"
    log "  script: $(pwd)/virt_deploy_modular_ds.sh"
    log "  Hostname: ${hostname}"
    log "  Release: ${release}"
    log "  CPU: ${cpus}"
    log "  Memory: ${memory}MB"
    log "  Disk Size: ${disksize_final}"
    log "  InstallationDirectory: ${installdir}"
    log "  Download skip: ${nodownload}"
    
    # Execution before VM status check
    log "[STEP 08] Checking existing VM status before deployment"
    local existing_vm_count="0"
    if command -v virsh >/dev/null 2>&1; then
      existing_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
      existing_vm_count=$(echo "${existing_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
      [[ -z "${existing_vm_count}" ]] && existing_vm_count="0"
    else
      log "[WARN] virsh command not found, skipping VM count check"
    fi
    log "  Existing mds VM count: ${existing_vm_count}"
    
    # Network ModePer not Check
    if [[ "${net_mode}" == "bridge" ]]; then
      log "[STEP 08] Bridge Mode - Checking br-data bridge..."
      if ! ip link show br-data >/dev/null 2>&1; then
        log "WARNING: br-data bridge does not exist. Network configuration in STEP 03 may not be completed."
        log "WARNING: VM deployment may fail. Please complete STEP 03 and reboot the system."
      else
        log "[STEP 08] br-data bridge exists."
      fi
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode - Checking virbr0 bridge..."
      if ! ip link show virbr0 >/dev/null 2>&1; then
        log "[STEP 08] virbr0 bridge does not exist. Starting default libvirt network..."
        if command -v virsh >/dev/null 2>&1; then
          if virsh net-list --all | grep -q "default.*inactive"; then
            run_cmd "sudo virsh net-start default" || log "WARNING: default network start failed"
          elif ! virsh net-list | grep -q "default.*active"; then
            log "WARNING: default libvirt network (default) could not be activated."
          fi
        else
          log "[WARN] virsh command not found, cannot start default network"
        fi
        
        # Check again
        if ip link show virbr0 >/dev/null 2>&1; then
          log "[STEP 08] virbr0 bridge created successfully."
        else
          log "WARNING: virbr0 bridge could not be created. VM deployment may fail."
        fi
      else
        log "[STEP 08] virbr0 bridge already exists."
      fi
    fi

    # Network ModePer environment Configuration
    if [[ "${net_mode}" == "bridge" ]]; then
      log "[STEP 08] Bridge Mode - Configuring environment variables: BRIDGE=br-data"
      export BRIDGE="br-data"
      export SENSOR_BRIDGE="br-data"
      export NETWORK_MODE="bridge"
      
      # Bridge Mode - Use user-configured IP values (set in step above)
      local sensor_ip="${SENSOR_VM_IP:-192.168.100.100}"
      local sensor_netmask="${SENSOR_VM_NETMASK:-255.255.255.0}"
      local sensor_gateway="${SENSOR_VM_GATEWAY:-192.168.100.1}"
      local sensor_dns="${SENSOR_VM_DNS:-8.8.8.8}"
      
      export LOCAL_IP="${sensor_ip}"
      export IP="${sensor_ip}"  # Also set IP for consistency
      export NETMASK="${sensor_netmask}"
      export GATEWAY="${sensor_gateway}"
      export DNS="${sensor_dns}"
      
      log "[STEP 08] Bridge Mode VM IP Configuration: ${sensor_ip}/${sensor_netmask}, GW: ${sensor_gateway}, DNS: ${sensor_dns}"
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode - Configuring environment variables: BRIDGE=virbr0"
      export BRIDGE="virbr0"
      export SENSOR_BRIDGE="virbr0"
      export NETWORK_MODE="nat"
      
      # NAT Mode - Using static IP (192.168.122.2) as per Ubuntu 24.04 deployment guide
      # This prevents retrieve_ip_nat() from waiting for DHCP assignment
      export IP="192.168.122.2"
      export LOCAL_IP="192.168.122.2"
      export NETMASK="255.255.255.0"
      export GATEWAY="192.168.122.1"
      export DNS="8.8.8.8"
    fi
    
    # Configure additional environment variables for deployment script
    local disk_size_gb="${sensor_disk_gb}"
    
    # Export environment variables for deployment script
    export disksize="${disk_size_gb}"
    export hostname="${hostname}"
    export release="${release}"
    export cpus="${cpus}"
    export memory="${memory}"
    export installdir="${installdir}"
    export nodownload="${nodownload}"
    export bridge="${BRIDGE}"
    
    log "[STEP 08] Deployment script environment variables: disksize=${disk_size_gb}, bridge=${BRIDGE}"

    # NAT Mode: Ensure default network is started
    # NOTE: DHCP is disabled per Ubuntu 24.04 deployment guide, so virbr0.status file will NOT be created
    # Static IP (192.168.122.2) is used instead, so retrieve_ip_nat() will be skipped
    if [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode - Ensuring default network is ready..."
      if command -v virsh >/dev/null 2>&1; then
        if ! virsh net-list | grep -q "default.*active"; then
          log "[STEP 08] Starting default libvirt network..."
          virsh net-start default 2>/dev/null || true
          sleep 2
        fi
        
        # Verify network is active
        if virsh net-list | grep -q "default.*active"; then
          log "[STEP 08] Default network is active (DHCP disabled, using static IP 192.168.122.2)"
        else
          log "[WARNING] Default network could not be started"
        fi
      else
        log "[WARN] virsh command not found, skipping default network check"
      fi
    fi
    
    # Execute deployment script
    log "[STEP 08] Starting sensor VM deployment script execution..."
    log "[STEP 08] Network Mode: ${net_mode}, using bridge: ${BRIDGE:-None}"
    
    # Verify script exists and is executable
    if [[ ! -f "virt_deploy_modular_ds.sh" ]]; then
      log "ERROR: Deployment script not found: virt_deploy_modular_ds.sh"
      return 1
    fi
    
    if [[ ! -x "virt_deploy_modular_ds.sh" ]]; then
      log "[WARN] Deployment script is not executable. Adding execute permission..."
      chmod +x virt_deploy_modular_ds.sh
    fi
    
    # Test script execution (check if it can at least start)
    log "[STEP 08] Verifying deployment script can execute..."
    if ! head -n 1 "virt_deploy_modular_ds.sh" | grep -q "^#!"; then
      log "[WARN] Deployment script may not have proper shebang line"
    fi
    
    log "[STEP 08] ========== Deployment script output start =========="
    
    local deploy_rc deploy_log_file
    deploy_log_file="${STATE_DIR}/deploy_${hostname}.log"
    
    # Clear previous log file
    > "${deploy_log_file}"
    
    # Build command line with IP parameters for both bridge and nat modes
    # Use --key="value" format (not space-separated) for getopt compatibility
    # Add -- (end-of-options) token after script name
    local cmd_line="bash virt_deploy_modular_ds.sh -- \
      --hostname=\"${hostname}\" \
      --release=\"${release}\" \
      --CPUS=\"${cpus}\" \
      --MEM=\"${memory}\" \
      --DISKSIZE=\"${disk_size_gb}\" \
      --installdir=\"${installdir}\" \
      --nodownload=\"${nodownload}\" \
      --bridge=\"${BRIDGE}\""
    
    # Bridge Mode: Add static IP parameters
    if [[ "${net_mode}" == "bridge" ]]; then
      cmd_line="${cmd_line} \
      --ip=\"${LOCAL_IP}\" \
      --netmask=\"${NETMASK}\" \
      --gw=\"${GATEWAY}\" \
      --dns=\"${DNS}\""
      log "[STEP 08] Bridge Mode: Using static IP ${LOCAL_IP} (${NETMASK}, GW: ${GATEWAY}, DNS: ${DNS})"
    fi
    
    # NAT Mode: Add static IP parameters (always add for NAT mode)
    if [[ "${net_mode}" == "nat" ]]; then
      cmd_line="${cmd_line} \
      --ip=\"${IP}\" \
      --netmask=\"${NETMASK}\" \
      --gw=\"${GATEWAY}\" \
      --dns=\"${DNS}\""
      log "[STEP 08] NAT Mode: Using static IP ${IP} (${NETMASK}, GW: ${GATEWAY})"
    fi
    
    # Add --nointeract=true to prevent interactive prompts
    cmd_line="${cmd_line} \
      --nointeract=\"true\""
    
    log "[STEP 08] Execution command: ${cmd_line}"
    log "[STEP 08] Wait 2 minutes (120 seconds) then automatically proceed to next step."
    if [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode: Using static IP ${IP} (skips DHCP IP assignment wait and virbr0.status file check)"
    fi
    
    # Configure timeout 120 seconds (2 minutes) - same as AIO-Sensor-Installer.sh
    set +e
    timeout 120s bash -c "${cmd_line}" 2>&1 | tee "${deploy_log_file}"
    deploy_rc=${PIPESTATUS[0]}
    set -e
    
    # [Core] Exit code check and force success handling (same as AIO-Sensor-Installer.sh)
    if [[ ${deploy_rc} -eq 0 ]]; then
      log "[STEP 08] [SUCCESS] ${hostname} deployment script terminated normally."
    else
      # Check if VM is alive despite error
      if command -v virsh >/dev/null 2>&1; then
        if virsh list --state-running | grep -q "${hostname}"; then
          log "[STEP 08] [WARN] Deployment script timeout/error (rc=${deploy_rc}) but VM(${hostname}) is running. (treated as success)"
          deploy_rc=0
        else
          log "[STEP 08] [ERROR] ${hostname} deployment failed (rc=${deploy_rc}). VM is not running."
          return 1
        fi
      else
        log "[STEP 08] [ERROR] Deployment failed (rc=${deploy_rc}) and virsh command not found for VM status check."
        return 1
      fi
    fi
    
    log "[STEP 08] ========== Deployment script output completed =========="
    
    # Log deployment result
    log "[STEP 08] Deployment script execution completed (exit code: ${deploy_rc})"
    if [[ -f "${deploy_log_file}" ]]; then
      log "[STEP 08] Deployment log file: ${deploy_log_file}"
    fi
    
    # Execution after VM status check
    log "[STEP 08] Deployment after VM status check"
    local new_vm_count="0"
    if command -v virsh >/dev/null 2>&1; then
      new_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
      new_vm_count=$(echo "${new_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
      [[ -z "${new_vm_count}" ]] && new_vm_count="0"
    fi
    log "  New mds VM count: ${new_vm_count}"
    
    if [[ "${new_vm_count}" -gt "${existing_vm_count}" ]]; then
      log "[STEP 08] VM Creation Success Check"
      if command -v virsh >/dev/null 2>&1; then
        virsh list --all | grep "mds" | while read line; do
          log "  VM Information: ${line}"
        done
      fi
    else
      log "[STEP 08] VM creation check: new_vm_count=${new_vm_count}, existing_vm_count=${existing_vm_count}"
    fi
    
    # Deployment Result (deploy_rc is already checked above, if rc!=0 and VM not running, already returned 1)
    if [[ ${deploy_rc} -eq 0 ]]; then
      log "[STEP 08] Sensor VM Deployment Success"
    else
      # This should not be reached if VM is running (already handled above)
      log "[STEP 08] Sensor VM Deployment Failed (exit code: ${deploy_rc})"
      
      # Check for specific errors in log file
      if [[ -f "${deploy_log_file}" ]]; then
        if grep -q "BIOS not enabled for VT-d/IOMMU" "${deploy_log_file}" 2>/dev/null; then
          log "ERROR: BIOS VT-d/IOMMU is disabled."
          log "Solution: Enable Intel VT-d or AMD-Vi (IOMMU) in BIOS configuration."
          whiptail_msgbox "BIOS Configuration Required" "VM Deployment Failed: BIOS VT-d/IOMMU is disabled.\n\nSolution:\n1. Reboot the system\n2. Enter BIOS/UEFI configuration\n3. Enable Intel VT-d or AMD-Vi (IOMMU)\n4. Save configuration and reboot\n\nWithout this configuration, VM creation will fail." 16 70
          return 1
        fi
      fi
      
      # Check if VM was created despite error (should already be handled above, but double-check)
      if command -v virsh >/dev/null 2>&1; then
        if virsh list --all | grep -q "mds"; then
          log "[STEP 08] Deployment script error but VM exists. Continuing..."
        else
          log "[ERROR] Deployment script failed and VM creation failed"
          return 1
        fi
      else
        log "[ERROR] Deployment script failed and virsh not available for verification"
        return 1
      fi
    fi
    
    # Check VM Status
    log "[STEP 08] Current VM Status:"
    if command -v virsh >/dev/null 2>&1; then
      virsh list --all | grep "mds" | while read line; do
        log "  ${line}"
      done
    else
      log "  [WARN] virsh command not found, cannot check VM status"
    fi
    
    log "[STEP 08] Sensor VM Deployment execution completed"
  fi

  #######################################
  # 3) Result Summary
  #######################################
  log "[STEP 08] STEP 08 completed - VM deployment finished"
  log "[STEP 08] Note: Network interface configuration will be performed in STEP 09"

  #######################################
  # 4) Result Check
  #######################################
  local final_vm="unknown"
  local final_running="unknown"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_vm="(DRY-RUN mode)"
    final_running="(DRY-RUN mode)"
  else
    # VM Exists Check
    if command -v virsh >/dev/null 2>&1; then
      if virsh list --all | grep -q "\smds\s"; then
        final_vm="OK"
        
        # VM execution status check
        if virsh list --state-running | grep -q "\smds\s"; then
          final_running="OK"
        else
          final_running="STOPPED"
        fi
      else
        final_vm="FAIL"
        final_running="FAIL"
      fi
    else
      final_vm="UNKNOWN"
      final_running="UNKNOWN"
      log "[WARN] virsh command not found, cannot check final VM status"
    fi
  fi

  {
    echo "STEP 08 Execution Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • mds VM Creation: ${final_vm}"
      echo "  • mds VM Execution: ${final_running}"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. VM Deployment:"
      echo "     - Deployment script would be executed"
      echo "     - VM name: mds"
      echo "     - vCPU: ${cpus}"
      echo "     - Memory: ${memory}MB"
      echo "     - Disk: ${disksize}GB"
      echo
      echo "  2. Network Configuration:"
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "     - br-data bridge interface would be added to VM"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "     - virbr0 (default network) interface would be added to VM"
      fi
      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        echo "     - SPAN NIC PCI passthrough would be configured"
        if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
          echo "     - SPAN NIC PCIs:"
          for pci in ${SENSOR_SPAN_VF_PCIS}; do
            echo "       * ${pci}"
          done
        fi
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        echo "     - SPAN bridge interfaces would be added"
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
          for bridge_name in ${SPAN_BRIDGE_LIST}; do
            echo "       * ${bridge_name}"
          done
        fi
      fi
      echo
      echo "  3. VM XML Modification:"
      echo "     - VM XML would be modified with network interfaces"
      echo "     - VM would be redefined with new configuration"
      echo "     - VM would be started"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • VM deployment requires STEP 07 (LV and image) to be completed"
      echo "  • Network bridges must exist (STEP 03)"
      echo "  • BIOS VT-d/IOMMU must be enabled for PCI passthrough"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 VM STATUS:"
      echo "  • mds VM Creation: ${final_vm}"
      echo "  • mds VM Execution: ${final_running}"
      echo
      echo "🖥️  VM INFORMATION:"
      echo "  • Name: mds"
      echo "  • vCPU: ${cpus}"
      echo "  • Memory: ${memory}MB"
      echo "  • Disk: ${disksize}GB"
      echo
      echo "🌐 NETWORK CONFIGURATION:"
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "  • br-data bridge: L2-only bridge connected"
        echo "    (Sensor VM IP configuration required inside VM)"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "  • virbr0 (default network): NAT bridge connected"
        echo "    (Sensor VM uses static IP: 192.168.122.2/24)"
      fi
      echo "  • SPAN Connection Mode: ${SPAN_ATTACH_MODE}"
      echo
      # Display SPAN configuration based on attachment mode
      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
          echo "  • SPAN NIC PCIs: PCI passthrough connected"
          for pci in ${SENSOR_SPAN_VF_PCIS}; do
            echo "    * ${pci}"
          done
        fi
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
          echo "  • SPAN bridges: L2 bridge virtio connected"
          for bridge_name in ${SPAN_BRIDGE_LIST}; do
            echo "    * ${bridge_name}"
          done
        fi
      fi
      
      # Display network topology based on network mode and SPAN attachment mode
      echo
      echo "📡 NETWORK TOPOLOGY:"
      
      # Main network interface (DATA/HOST)
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "  [DATA_NIC]──(L2-only)──[br-data]──(virtio)──[Sensor VM NIC]"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "  [HOST_NIC (mgt)]──(NAT)──[virbr0]──(virtio)──[Sensor VM NIC]"
      fi
      
      # SPAN interface
      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        echo "  [SPAN NIC PF(s)]────(PCI passthrough via vfio-pci)──[Sensor VM]"
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        echo "  [SPAN_NIC(s)]──(L2-only)──[br-spanX]──(virtio)──[Sensor VM]"
      fi
      echo
      echo "💡 USEFUL COMMANDS:"
      echo "  • Check VM status: virsh list --all"
      echo "  • Start VM: virsh start mds"
      echo "  • View VM info: virsh dominfo mds"
      echo "  • View VM XML: virsh dumpxml mds"
      echo
      echo "⚠️  IMPORTANT:"
      if [[ "${net_mode}" == "bridge" ]]; then
        echo "  • Configure IP address on the NIC connected to br-data inside the Sensor VM"
      elif [[ "${net_mode}" == "nat" ]]; then
        echo "  • Sensor VM uses static IP: 192.168.122.2/24 (configured automatically)"
        echo "  • Gateway: 192.168.122.1 (virbr0 NAT bridge)"
      fi
      echo "  • If VM is not running, start it manually with: virsh start mds"
      echo "  • Verify network connectivity after VM starts"
    fi
  } > "${tmp_status}"

  show_textbox "STEP 08 Result Summary" "${tmp_status}"

  log "[STEP 08] Sensor VM Deployment Completed"

  return 0
}

step_09_sensor_passthrough() {
    local STEP_ID="09_sensor_passthrough"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 09. Sensor VM Network Interface Configuration (XML Modification) ====="

    # config 
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    local SENSOR_VM="mds"

    ###########################################################################
    # 1. Sensor VM Exists Check
    ###########################################################################
    if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
        whiptail_msgbox "STEP 09 - Sensor VM Not Found" "Sensor VM (${SENSOR_VM}) does not exist.\n\nPlease complete STEP 08 (Sensor Deployment) first."
        log "[STEP 09] Sensor VM not found -> STEP Abort"
        return 1
    fi

    ###########################################################################
    # 1.5. Configure VM Network Interfaces (XML Modification)
    #  - Add br-data/virbr0 and SPAN interfaces to VM XML
    ###########################################################################
    log "[STEP 09] Configuring sensor VM network interfaces"
    
    # Check network mode
    local net_mode="${SENSOR_NET_MODE:-bridge}"
    
    # br-data bridge Exists Check and Creation (Bridge mode only)
    if [[ "${net_mode}" == "bridge" ]]; then
      if [[ "${_DRY}" -eq 0 ]]; then
        if ! ip link show br-data >/dev/null 2>&1; then
          log "br-data bridge does not exist. Creating bridge..."
          if [[ -n "${DATA_NIC:-}" ]]; then
            # bridge Creation and Configuration
            ip link add name br-data type bridge
            ip link set dev br-data up
            ip link set dev "${DATA_NIC}" master br-data
            echo 0 > /sys/class/net/br-data/bridge/stp_state
            echo 0 > /sys/class/net/br-data/bridge/forward_delay
            log "br-data bridge creation completed: ${DATA_NIC} connected"
          else
            log "ERROR: DATA_NIC is not configured. Could not create br-data bridge."
            return 1
          fi
        else
          log "br-data bridge already exists."
        fi
      else
        log "[DRY-RUN] Checking br-data bridge existence and creating if required (Bridge mode)"
      fi
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 09] NAT Mode - br-data bridge is not required (using virbr0)"
      # Check virbr0
      if [[ "${_DRY}" -eq 0 ]]; then
        if ! ip link show virbr0 >/dev/null 2>&1; then
          log "WARNING: virbr0 bridge does not exist. Starting default libvirt network..."
          virsh net-start default 2>/dev/null || log "WARNING: Failed to start default network"
        fi
      fi
    fi
    
    # SPAN bridge check and creation/cleanup (based on SPAN_ATTACH_MODE)
    local span_attach_mode="${SPAN_ATTACH_MODE:-pci}"
    
    if [[ "${span_attach_mode}" == "pci" && "${_DRY}" -eq 0 ]]; then
      # PCI Mode: Clean up existing SPAN bridges (mode switch from bridge to pci)
      log "[STEP 09] SPAN_ATTACH_MODE=pci, cleaning up existing SPAN bridges..."
      
      # Check for existing SPAN bridges and remove them
      if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
        log "[STEP 09] Found existing SPAN_BRIDGE_LIST: ${SPAN_BRIDGE_LIST}"
        
        for bridge_name in ${SPAN_BRIDGE_LIST}; do
          if ip link show "${bridge_name}" >/dev/null 2>&1; then
            log "[STEP 09] Removing SPAN bridge interface: ${bridge_name}"
            # Remove NIC from bridge first
            local bridge_ports
            bridge_ports=$(brctl show "${bridge_name}" 2>/dev/null | awk 'NR>1 {print $4}' | grep -v "^$" || echo "")
            if [[ -n "${bridge_ports}" ]]; then
              for port in ${bridge_ports}; do
                ip link set dev "${port}" nomaster 2>/dev/null || true
              done
            fi
            # Delete bridge
            ip link set dev "${bridge_name}" down 2>/dev/null || true
            ip link del "${bridge_name}" 2>/dev/null || true
            log "[STEP 09] SPAN bridge ${bridge_name} removed"
          fi
        done
        
        # Clear SPAN_BRIDGE_LIST
        SPAN_BRIDGE_LIST=""
        save_config_var "SPAN_BRIDGE_LIST" "${SPAN_BRIDGE_LIST}"
        log "[STEP 09] SPAN_BRIDGE_LIST cleared (PCI passthrough mode)"
      else
        # Also check for any br-span* bridges that might exist
        local existing_span_bridges
        existing_span_bridges=$(ip link show type bridge 2>/dev/null | grep -o "br-span[0-9]*" || echo "")
        if [[ -n "${existing_span_bridges}" ]]; then
          log "[STEP 09] Found orphaned SPAN bridges: ${existing_span_bridges}"
          for bridge_name in ${existing_span_bridges}; do
            log "[STEP 09] Removing orphaned SPAN bridge: ${bridge_name}"
            local bridge_ports
            bridge_ports=$(brctl show "${bridge_name}" 2>/dev/null | awk 'NR>1 {print $4}' | grep -v "^$" || echo "")
            if [[ -n "${bridge_ports}" ]]; then
              for port in ${bridge_ports}; do
                ip link set dev "${port}" nomaster 2>/dev/null || true
              done
            fi
            ip link set dev "${bridge_name}" down 2>/dev/null || true
            ip link del "${bridge_name}" 2>/dev/null || true
          done
        else
          log "[STEP 09] No existing SPAN bridges to clean up (PCI passthrough mode)"
        fi
      fi
      
      log "[STEP 09] SPAN will use PCI passthrough mode"
    elif [[ "${span_attach_mode}" == "bridge" && "${_DRY}" -eq 0 ]]; then
      log "[STEP 09] SPAN_ATTACH_MODE=bridge, checking SPAN configuration..."
      log "[STEP 09] SPAN_BRIDGE_LIST value: '${SPAN_BRIDGE_LIST:-}'"
      log "[STEP 09] SPAN_NIC_LIST value: '${SPAN_NIC_LIST:-}'"
      
      # Use SPAN_NIC_LIST if available, otherwise fallback to SPAN_NICS
      local span_nic_list_to_use="${SPAN_NIC_LIST:-${SPAN_NICS}}"
      
      if [[ -n "${span_nic_list_to_use}" ]]; then
        # If SPAN_BRIDGE_LIST is empty, generate bridge names from SPAN_NIC_LIST (similar to br-data logic)
        local span_bridge_list_to_process="${SPAN_BRIDGE_LIST:-}"
        
        if [[ -z "${span_bridge_list_to_process}" ]]; then
          log "[STEP 09] SPAN_BRIDGE_LIST is empty. Generating bridge names from SPAN_NIC_LIST..."
          local span_index=0
          local generated_bridge_list=""
          for span_nic in ${span_nic_list_to_use}; do
            local bridge_name="br-span${span_index}"
            generated_bridge_list="${generated_bridge_list} ${bridge_name}"
            ((span_index++))
          done
          span_bridge_list_to_process="${generated_bridge_list# }"
          log "[STEP 09] Generated SPAN bridge list: ${span_bridge_list_to_process}"
          
          # Save generated bridge list to config
          SPAN_BRIDGE_LIST="${span_bridge_list_to_process}"
          save_config_var "SPAN_BRIDGE_LIST" "${SPAN_BRIDGE_LIST}"
          log "[STEP 09] SPAN_BRIDGE_LIST saved: ${SPAN_BRIDGE_LIST}"
        else
          log "[STEP 09] SPAN_BRIDGE_LIST is not empty, processing bridges: ${span_bridge_list_to_process}"
        fi
        
        # Create or verify bridges (similar to br-data creation logic)
        for bridge_name in ${span_bridge_list_to_process}; do
          if ! ip link show "${bridge_name}" >/dev/null 2>&1; then
            log "SPAN bridge ${bridge_name} does not exist. Creating bridge..."
            # Extract index from bridge name (br-span0 -> 0)
            local span_index="${bridge_name#br-span}"
            local span_nic_array=(${span_nic_list_to_use})
            if [[ "${span_index}" -lt "${#span_nic_array[@]}" ]]; then
              local span_nic="${span_nic_array[${span_index}]}"
              # Create bridge (same logic as br-data)
              ip link add name "${bridge_name}" type bridge
              ip link set dev "${bridge_name}" up
              ip link set dev "${span_nic}" master "${bridge_name}"
              echo 0 > "/sys/class/net/${bridge_name}/bridge/stp_state"
              echo 0 > "/sys/class/net/${bridge_name}/bridge/forward_delay"
              
              # Apply SPAN bridge optimizations: promiscuous mode, offload disable, ageing=0
              ip link set dev "${span_nic}" promisc on || true
              ip link set dev "${bridge_name}" promisc on || true
              
              # Disable offload features
              if ethtool -K "${span_nic}" gro off lro off gso off tso off 2>/dev/null; then
                log "[STEP 09] SPAN NIC ${span_nic}: offload disabled (gro/lro/gso/tso)"
              else
                log "[STEP 09] WARN: ethtool offload disable failed on ${span_nic} (driver may not support)"
              fi
              
              # Bridge ageing runtime correction (if brctl available)
              if command -v brctl >/dev/null 2>&1; then
                brctl setageing "${bridge_name}" 0 2>/dev/null || true
                brctl setfd "${bridge_name}" 0 2>/dev/null || true
              fi
              
              log "SPAN bridge ${bridge_name} creation completed: ${span_nic} connected"
            else
              log "ERROR: SPAN bridge ${bridge_name} corresponding NIC does not exist."
            fi
          else
            log "SPAN bridge ${bridge_name} already exists."
            # Verify physical NIC connection to bridge
            local span_index="${bridge_name#br-span}"
            local span_nic_array=(${span_nic_list_to_use})
            if [[ "${span_index}" -lt "${#span_nic_array[@]}" ]]; then
              local span_nic="${span_nic_array[${span_index}]}"
              # Check if physical NIC is connected to bridge
              local bridge_ports
              bridge_ports=$(brctl show "${bridge_name}" 2>/dev/null | awk 'NR>1 {print $4}' | grep -v "^$" | tr '\n' ' ' || echo "")
              
              if echo "${bridge_ports}" | grep -q "${span_nic}"; then
                log "[INFO] SPAN bridge ${bridge_name} already has physical NIC ${span_nic} connected."
                
                # Ensure bridge is up
                ip link set dev "${bridge_name}" up 2>/dev/null || true
                
                # Apply SPAN bridge optimizations: promiscuous mode, offload disable, ageing=0
                ip link set dev "${span_nic}" promisc on || true
                ip link set dev "${bridge_name}" promisc on || true
                
                # Disable offload features
                if ethtool -K "${span_nic}" gro off lro off gso off tso off 2>/dev/null; then
                  log "[STEP 09] SPAN NIC ${span_nic}: offload disabled (gro/lro/gso/tso)"
                else
                  log "[STEP 09] WARN: ethtool offload disable failed on ${span_nic} (driver may not support)"
                fi
                
                # Bridge ageing runtime correction (if brctl available)
                if command -v brctl >/dev/null 2>&1; then
                  brctl setageing "${bridge_name}" 0 2>/dev/null || true
                  brctl setfd "${bridge_name}" 0 2>/dev/null || true
                fi
              else
                log "WARNING: SPAN bridge ${bridge_name} exists but physical NIC ${span_nic} is not connected."
                log "Attempting to connect ${span_nic} to ${bridge_name}..."
                
                # Check if NIC exists and is not already a slave
                if ip link show "${span_nic}" >/dev/null 2>&1; then
                  # Remove NIC from any existing bridge/master
                  local current_master
                  current_master=$(ip link show "${span_nic}" 2>/dev/null | grep -oP 'master \K\S+' || echo "")
                  if [[ -n "${current_master}" && "${current_master}" != "${bridge_name}" ]]; then
                    log "[INFO] Removing ${span_nic} from ${current_master}..."
                    ip link set dev "${span_nic}" nomaster 2>/dev/null || true
                    sleep 1
                  fi
                  
                  # Connect NIC to bridge
                  if ip link set dev "${span_nic}" master "${bridge_name}" 2>/dev/null; then
                    log "Successfully connected ${span_nic} to ${bridge_name}"
                    
                    # Ensure bridge is up
                    ip link set dev "${bridge_name}" up 2>/dev/null || true
                    
                    # Apply SPAN bridge optimizations: promiscuous mode, offload disable, ageing=0
                    ip link set dev "${span_nic}" promisc on || true
                    ip link set dev "${bridge_name}" promisc on || true
                    
                    # Disable offload features
                    if ethtool -K "${span_nic}" gro off lro off gso off tso off 2>/dev/null; then
                      log "[STEP 09] SPAN NIC ${span_nic}: offload disabled (gro/lro/gso/tso)"
                    else
                      log "[STEP 09] WARN: ethtool offload disable failed on ${span_nic} (driver may not support)"
                    fi
                    
                    # Bridge ageing runtime correction (if brctl available)
                    if command -v brctl >/dev/null 2>&1; then
                      brctl setageing "${bridge_name}" 0 2>/dev/null || true
                      brctl setfd "${bridge_name}" 0 2>/dev/null || true
                    fi
                  else
                    log "ERROR: Failed to connect ${span_nic} to ${bridge_name}. Please check manually."
                  fi
                else
                  log "ERROR: Physical NIC ${span_nic} does not exist. Cannot connect to bridge."
                fi
              fi
            fi
            
          fi
        done
        
        # Final verification logging for all SPAN bridges (after all bridges are processed)
        log "[STEP 09] SPAN bridge configuration verification:"
        for bridge_name in ${span_bridge_list_to_process}; do
          local span_index="${bridge_name#br-span}"
          local span_nic_array=(${span_nic_list_to_use})
          if [[ "${span_index}" -lt "${#span_nic_array[@]}" ]]; then
            local span_nic="${span_nic_array[${span_index}]}"
            
            if [[ -n "${span_nic}" ]] && ip link show "${span_nic}" >/dev/null 2>&1; then
              # Check promiscuous mode status
              local promisc_status
              promisc_status=$(ip link show "${span_nic}" 2>/dev/null | grep -o "PROMISC" || echo "")
              if [[ -n "${promisc_status}" ]]; then
                log "[STEP 09] ✓ SPAN NIC ${span_nic}: PROMISC mode enabled"
              else
                log "[STEP 09] ⚠ SPAN NIC ${span_nic}: PROMISC mode not detected (may require interface restart)"
              fi
              
              # Check offload status (ethtool)
              if command -v ethtool >/dev/null 2>&1; then
                local offload_status
                offload_status=$(ethtool -k "${span_nic}" 2>/dev/null | grep -E "^(gro|lro|gso|tso):" | grep -v "fixed" || echo "")
                if [[ -n "${offload_status}" ]]; then
                  local offload_off_count
                  offload_off_count=$(echo "${offload_status}" | grep -c "off" || echo "0")
                  if [[ "${offload_off_count}" -ge 4 ]]; then
                    log "[STEP 09] ✓ SPAN NIC ${span_nic}: offload disabled (gro/lro/gso/tso)"
                  else
                    log "[STEP 09] ⚠ SPAN NIC ${span_nic}: some offload features may still be enabled"
                    log "[STEP 09]   Offload status: ${offload_status}"
                  fi
                else
                  log "[STEP 09] ⚠ SPAN NIC ${span_nic}: ethtool offload status check failed (driver may not support)"
                fi
              fi
              
              # Show bridge status (if brctl available)
              if command -v brctl >/dev/null 2>&1; then
                log "[STEP 09] SPAN bridge ${bridge_name} status:"
                brctl show "${bridge_name}" 2>/dev/null | while read line; do
                  log "  ${line}"
                done || true
              fi
            fi
          fi
        done
      else
        log "WARNING: SPAN_NIC_LIST and SPAN_NICS are both empty. Cannot create SPAN bridges."
        log "WARNING: Please configure SPAN NICs in STEP 01 with SPAN_ATTACH_MODE=bridge."
      fi
    elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
      log "[DRY-RUN] Checking SPAN bridge existence and creating if required"
    fi
    
    # Check VM creation and modify XML
    if [[ "${_DRY}" -eq 0 ]]; then
      # Check if VM is running - shutdown if we need to modify XML
      if virsh list --state-running | grep -q "\smds\s"; then
        log "[INFO] mds VM is currently running - shutting down for XML modification..."
        virsh shutdown mds
        # Wait for graceful shutdown (max 30 seconds)
        local shutdown_wait=0
        while [[ ${shutdown_wait} -lt 30 ]] && virsh list --state-running | grep -q "\smds\s"; do
          sleep 1
          ((shutdown_wait++))
        done
        
        # Force shutdown if still running
        if virsh list --state-running | grep -q "\smds\s"; then
          log "VM did not shutdown gracefully. Forcing shutdown..."
          virsh destroy mds 2>/dev/null || true
          sleep 2
        fi
      fi
      
      # Check if VM exists
      if ! virsh list --all | grep -q "mds"; then
        log "ERROR: mds VM was not created. Please check STEP 08 execution."
        return 1
      fi
      
      # Current XML backup
      local vm_xml_backup="${STATE_DIR}/mds_original.xml"
      if ! virsh dumpxml mds > "${vm_xml_backup}" 2>/dev/null; then
        log "ERROR: VM XML backup Failed"
        return 1
      fi
      log "Existing VM XML backup: ${vm_xml_backup}"
      
      # Create modified XML file
      local vm_xml_new="${STATE_DIR}/mds_modified.xml"
      if ! virsh dumpxml mds > "${vm_xml_new}" 2>/dev/null; then
        log "ERROR: Failed to dump VM XML"
        return 1
      fi
      
      if [[ -f "${vm_xml_new}" && -s "${vm_xml_new}" ]]; then
        # Pre-detect SPAN PCI list BEFORE cleanup (PCI mode only)
        local span_attach_mode="${SPAN_ATTACH_MODE:-pci}"
        local span_pci_list=""
        if [[ "${span_attach_mode}" == "pci" ]]; then
          log "[STEP 09] SPAN_ATTACH_MODE=pci, preparing SPAN PCI list before cleanup..."
          log "[STEP 09] SENSOR_SPAN_VF_PCIS value: '${SENSOR_SPAN_VF_PCIS:-}'"
          log "[STEP 09] SPAN_NICS value: '${SPAN_NICS:-}'"

          # If SENSOR_SPAN_VF_PCIS is empty but SPAN_NICS are configured, re-detect PCI addresses
          if [[ -z "${SENSOR_SPAN_VF_PCIS:-}" && -n "${SPAN_NICS:-}" ]]; then
            log "[STEP 09] WARNING: SENSOR_SPAN_VF_PCIS is empty. Re-detecting PCI addresses for SPAN NICs..."
            for span_nic in ${SPAN_NICS}; do
              local pci_addr
              pci_addr=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
              if [[ -n "${pci_addr}" ]]; then
                span_pci_list="${span_pci_list} ${pci_addr}"
                log "[STEP 09] Detected PCI address for ${span_nic}: ${pci_addr}"
              else
                log "[STEP 09] WARNING: Could not detect PCI address for ${span_nic}"
              fi
            done
            if [[ -n "${span_pci_list}" ]]; then
              SENSOR_SPAN_VF_PCIS="${span_pci_list# }"
              save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
              log "[STEP 09] SENSOR_SPAN_VF_PCIS updated: ${SENSOR_SPAN_VF_PCIS}"
            else
              log "[STEP 09] ERROR: Could not detect any PCI addresses for SPAN NICs."
              log "[STEP 09] Please verify SPAN NICs are correctly configured in STEP 01."
              return 1
            fi
          fi

          span_pci_list="${SENSOR_SPAN_VF_PCIS:-}"
          if [[ -z "${span_pci_list}" ]]; then
            log "[STEP 09] ERROR: SPAN PCI list is empty. Cannot proceed with PCI mode."
            log "[STEP 09] Please run STEP 01 to detect SPAN NIC PCI addresses."
            return 1
          fi
        fi

        # Clean up conflicting devices based on SPAN_ATTACH_MODE
        # This handles mode switching: PCI passthrough <-> Bridge
        log "[STEP 09] Cleaning up XML for SPAN_ATTACH_MODE=${span_attach_mode}..."
        
        # Use python for reliable XML parsing and cleanup
        if command -v python3 >/dev/null 2>&1; then
          python3 <<EOF
import sys
import xml.etree.ElementTree as ET
import re

try:
    tree = ET.parse("${vm_xml_new}")
    root = tree.getroot()
    
    # Find devices element
    devices = root.find('.//devices')
    if devices is not None:
        removed_count = 0
        span_attach_mode = "${span_attach_mode}"
        net_mode = "${net_mode}"
        span_bridge_list = "${SPAN_BRIDGE_LIST:-}".split()
        span_pci_list = "${span_pci_list}".split()
        
        # Determine expected devices based on mode
        expected_bridges = set()
        if net_mode == "bridge":
            expected_bridges.add("br-data")
        else:
            expected_bridges.add("virbr0")
        
        # Add SPAN bridges if in bridge mode
        if span_attach_mode == "bridge":
            for bridge in span_bridge_list:
                if bridge:
                    expected_bridges.add(bridge)
        
        # Step 1: Remove conflicting devices based on mode
        if span_attach_mode == "bridge":
            # Bridge mode: Remove all PCI passthrough hostdev devices
            hostdevs_to_remove = []
            for hostdev in devices.findall('hostdev'):
                if hostdev.get('type') == 'pci':
                    hostdevs_to_remove.append(hostdev)
            
            for hostdev in hostdevs_to_remove:
                devices.remove(hostdev)
                removed_count += len(hostdevs_to_remove)
                print(f"Removed {len(hostdevs_to_remove)} PCI passthrough hostdev device(s) (bridge mode)")
        
        elif span_attach_mode == "pci":
            # PCI mode: Remove SPAN bridge interfaces (br-span*)
            interfaces_to_remove = []
            for interface in devices.findall('interface'):
                source = interface.find('source')
                if source is not None:
                    bridge_name = source.get('bridge')
                    if bridge_name and bridge_name.startswith('br-span'):
                        interfaces_to_remove.append(interface)
            
            for interface in interfaces_to_remove:
                devices.remove(interface)
                removed_count += len(interfaces_to_remove)
                print(f"Removed {len(interfaces_to_remove)} SPAN bridge interface(s) (PCI passthrough mode)")
            
            # PCI mode: Remove PCI hostdev devices not in current SPAN PCI list
            expected_pcis = set()
            for pci in span_pci_list:
                if pci:
                    expected_pcis.add(pci.strip())

            if expected_pcis:
                hostdevs_to_remove = []
                for hostdev in devices.findall('hostdev'):
                    if hostdev.get('type') == 'pci':
                        source = hostdev.find('source')
                        if source is not None:
                            address = source.find('address')
                            if address is not None:
                                domain = address.get('domain', '').replace('0x', '').zfill(4)
                                bus = address.get('bus', '').replace('0x', '').zfill(2)
                                slot = address.get('slot', '').replace('0x', '').zfill(2)
                                func = address.get('function', '').replace('0x', '').zfill(1)
                                pci_addr = f"{domain}:{bus}:{slot}.{func}"
                                if pci_addr not in expected_pcis:
                                    hostdevs_to_remove.append(hostdev)

                for hostdev in hostdevs_to_remove:
                    devices.remove(hostdev)
                    removed_count += len(hostdevs_to_remove)

            # Always remove duplicate PCI hostdev devices for SPAN PCIs (keep first)
            seen_pcis = set()
            hostdevs_to_remove = []
            for hostdev in devices.findall('hostdev'):
                if hostdev.get('type') == 'pci':
                    source = hostdev.find('source')
                    if source is not None:
                        address = source.find('address')
                        if address is not None:
                            domain = address.get('domain', '').replace('0x', '').zfill(4)
                            bus = address.get('bus', '').replace('0x', '').zfill(2)
                            slot = address.get('slot', '').replace('0x', '').zfill(2)
                            func = address.get('function', '').replace('0x', '').zfill(1)
                            pci_addr = f"{domain}:{bus}:{slot}.{func}"
                            if pci_addr not in expected_pcis:
                                continue
                            if pci_addr in seen_pcis:
                                hostdevs_to_remove.append(hostdev)
                            else:
                                seen_pcis.add(pci_addr)

            for hostdev in hostdevs_to_remove:
                devices.remove(hostdev)
                removed_count += len(hostdevs_to_remove)
            if len(hostdevs_to_remove) > 0:
                print(f"Removed {len(hostdevs_to_remove)} duplicate PCI passthrough hostdev device(s)")
        
        # Step 2: Remove duplicate interfaces (keep only one per bridge/network)
        bridge_interfaces = {}
        duplicate_interfaces = []
        
        # Normalize bridge/network names (virbr0 can be 'default' network or 'virbr0' bridge)
        def normalize_bridge_name(bridge_name, network_name):
            if network_name == 'default' or bridge_name == 'virbr0':
                return 'virbr0'
            return bridge_name or network_name
        
        for interface in devices.findall('interface'):
            source = interface.find('source')
            if source is not None:
                bridge_name = source.get('bridge')
                network_name = source.get('network')
                normalized_name = normalize_bridge_name(bridge_name, network_name)
                
                if normalized_name:
                    # Handle expected bridges (including SPAN bridges in bridge mode)
                    if normalized_name in expected_bridges:
                        # Keep first occurrence, mark duplicates for removal
                        if normalized_name not in bridge_interfaces:
                            bridge_interfaces[normalized_name] = interface
                        else:
                            duplicate_interfaces.append(interface)
                    # Handle SPAN bridges not in expected_bridges (should not happen, but safety check)
                    elif normalized_name.startswith('br-span'):
                        if span_attach_mode == "pci":
                            # Remove all SPAN bridge interfaces in PCI mode
                            duplicate_interfaces.append(interface)
                        elif span_attach_mode == "bridge":
                            # In bridge mode, keep only one SPAN bridge interface per bridge
                            # (This should have been handled above if in expected_bridges, but double-check)
                            if normalized_name not in bridge_interfaces:
                                bridge_interfaces[normalized_name] = interface
                            else:
                                duplicate_interfaces.append(interface)
        
        for interface in duplicate_interfaces:
            devices.remove(interface)
            removed_count += len(duplicate_interfaces)
            if len(duplicate_interfaces) > 0:
                print(f"Removed {len(duplicate_interfaces)} duplicate interface(s)")
        
        # Step 3: Remove unexpected bridge interfaces
        unexpected_interfaces = []
        for interface in devices.findall('interface'):
            source = interface.find('source')
            if source is not None:
                bridge_name = source.get('bridge')
                network_name = source.get('network')
                normalized_name = normalize_bridge_name(bridge_name, network_name)
                
                if normalized_name and normalized_name.startswith('br-') and normalized_name not in expected_bridges:
                    unexpected_interfaces.append(interface)
                elif network_name == 'default' and normalized_name not in expected_bridges:
                    # Also check for 'default' network that should be virbr0
                    unexpected_interfaces.append(interface)
        
        for interface in unexpected_interfaces:
            devices.remove(interface)
            removed_count += len(unexpected_interfaces)
            if len(unexpected_interfaces) > 0:
                print(f"Removed {len(unexpected_interfaces)} unexpected bridge interface(s)")
        
        # Write modified XML
        ET.indent(tree, space="  ")
        tree.write("${vm_xml_new}", encoding='unicode', xml_declaration=True)
        print(f"XML cleanup completed: {removed_count} device(s) removed")
    else:
        print("ERROR: devices element not found in XML")
        sys.exit(1)
except Exception as e:
    print(f"ERROR: Failed to process XML: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF
          local python_exit_code=$?
          if [[ ${python_exit_code} -eq 0 ]]; then
            log "[STEP 09] XML cleanup completed successfully for SPAN_ATTACH_MODE=${span_attach_mode}."
          else
            log "ERROR: Failed to clean up XML using python3 (exit code: ${python_exit_code})"
            log "ERROR: XML file may be corrupted. Cannot proceed with VM redefinition."
            log "ERROR: Please check XML file manually: ${vm_xml_new}"
            return 1
          fi
        else
          log "ERROR: python3 not available. Cannot automatically clean up XML."
          log "ERROR: Please install python3 or manually remove conflicting devices from VM XML."
          return 1
        fi
        
        # Validate XML file exists and is not empty after modification
        if [[ ! -f "${vm_xml_new}" ]] || [[ ! -s "${vm_xml_new}" ]]; then
          log "ERROR: Modified XML file does not exist or is empty: ${vm_xml_new}"
          return 1
        fi
        
        # Basic XML validation (check if it's valid XML)
        if ! python3 -c "import xml.etree.ElementTree as ET; ET.parse('${vm_xml_new}')" 2>/dev/null; then
          log "ERROR: Modified XML file is not valid XML: ${vm_xml_new}"
          log "ERROR: Please check the XML file manually"
          return 1
        fi
        log "[STEP 09] XML file validation passed"
        
        # Network interface addition based on network mode
        if [[ "${net_mode}" == "bridge" ]]; then
          # Bridge Mode: Add br-data interface
          if grep -Eq "<source bridge=['\"]br-data['\"]/>" "${vm_xml_new}"; then
            log "[INFO] br-data interface already exists in XML (skipping addition)"
          else
            log "Adding br-data bridge interface to XML"
        
            # Add br-data interface before </devices>
            local br_data_interface="    <interface type='bridge'>
      <source bridge='br-data'/>
      <model type='virtio'/>
    </interface>"
        
            # Modify XML using temporary file
            local tmp_xml="${vm_xml_new}.tmp"
            awk -v interface="$br_data_interface" '
              /<\/devices>/ { print interface }
              { print }
            ' "${vm_xml_new}" > "${tmp_xml}"
            mv "${tmp_xml}" "${vm_xml_new}"
          fi
        elif [[ "${net_mode}" == "nat" ]]; then
          # NAT Mode: Check if virbr0 interface exists, add if not
          # Use python for reliable duplicate checking and addition
          if command -v python3 >/dev/null 2>&1; then
            python3 <<EOF
import sys
import xml.etree.ElementTree as ET

try:
    tree = ET.parse("${vm_xml_new}")
    root = tree.getroot()
    
    devices = root.find('.//devices')
    if devices is not None:
        # Check if virbr0 interface already exists (check both 'default' network and 'virbr0' bridge)
        virbr0_exists = False
        virbr0_interfaces = []
        
        for interface in devices.findall('interface'):
            source = interface.find('source')
            if source is not None:
                network_name = source.get('network')
                bridge_name = source.get('bridge')
                if network_name == 'default' or bridge_name == 'virbr0':
                    virbr0_interfaces.append(interface)
                    virbr0_exists = True
        
        # Remove duplicates, keep only the first one
        if len(virbr0_interfaces) > 1:
            for interface in virbr0_interfaces[1:]:
                devices.remove(interface)
            print(f"Removed {len(virbr0_interfaces) - 1} duplicate virbr0 interface(s)")
        
        # Add virbr0 interface if it doesn't exist
        if not virbr0_exists:
            interface_elem = ET.Element('interface', type='network')
            source_elem = ET.SubElement(interface_elem, 'source', network='default')
            model_elem = ET.SubElement(interface_elem, 'model', type='virtio')
            devices.append(interface_elem)
            print("virbr0 (default network) interface added")
        else:
            print("virbr0 (default network) interface already exists (skipping addition)")
        
        # Write modified XML
        ET.indent(tree, space="  ")
        tree.write("${vm_xml_new}", encoding='unicode', xml_declaration=True)
    else:
        print("ERROR: devices element not found in XML")
        sys.exit(1)
except Exception as e:
    print(f"ERROR: Failed to process XML: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF
            if [[ $? -eq 0 ]]; then
              log "[STEP 09] virbr0 interface processed successfully."
            else
              log "WARNING: Failed to process virbr0 interface using python3. Falling back to grep method."
              # Fallback to original method
              if grep -q "<source network='default'/>" "${vm_xml_new}" || grep -q "<source bridge='virbr0'/>" "${vm_xml_new}"; then
                log "[INFO] virbr0 (default network) interface already exists in XML (skipping addition)"
              else
                log "Adding virbr0 (default network) interface to XML"
            
                local virbr0_interface="    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>"
            
                local tmp_xml="${vm_xml_new}.tmp"
                awk -v interface="$virbr0_interface" '
                  /<\/devices>/ { print interface }
                  { print }
                ' "${vm_xml_new}" > "${tmp_xml}"
                mv "${tmp_xml}" "${vm_xml_new}"
              fi
            fi
          else
            # Fallback if python3 not available
            if grep -q "<source network='default'/>" "${vm_xml_new}" || grep -q "<source bridge='virbr0'/>" "${vm_xml_new}"; then
              log "[INFO] virbr0 (default network) interface already exists in XML (skipping addition)"
            else
              log "Adding virbr0 (default network) interface to XML"
          
              local virbr0_interface="    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>"
          
              local tmp_xml="${vm_xml_new}.tmp"
              awk -v interface="$virbr0_interface" '
                /<\/devices>/ { print interface }
                { print }
              ' "${vm_xml_new}" > "${tmp_xml}"
              mv "${tmp_xml}" "${vm_xml_new}"
            fi
          fi
        fi
        
        # SPAN connection mode
        if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
          # Add SPAN NICs PF PCI passthrough (hostdev)
          log "[STEP 09] SPAN_ATTACH_MODE=pci, checking SPAN PCI list..."
          log "[STEP 09] SPAN PCI list: '${span_pci_list:-}'"
          if [[ -z "${span_pci_list:-}" ]]; then
            log "[STEP 09] ERROR: SPAN PCI list is empty. Cannot add hostdev devices."
            return 1
          fi

          if command -v python3 >/dev/null 2>&1; then
            python3 <<EOF
import sys
import xml.etree.ElementTree as ET

span_pcis = "${span_pci_list}".split()

try:
    tree = ET.parse("${vm_xml_new}")
    root = tree.getroot()
    devices = root.find('.//devices')
    if devices is None:
        print("ERROR: devices element not found in XML")
        sys.exit(1)

    def pci_key_from_hostdev(hostdev):
        source = hostdev.find('source')
        if source is None:
            return None
        address = source.find('address')
        if address is None:
            return None
        domain = address.get('domain', '').replace('0x', '').zfill(4)
        bus = address.get('bus', '').replace('0x', '').zfill(2)
        slot = address.get('slot', '').replace('0x', '').zfill(2)
        func = address.get('function', '').replace('0x', '').zfill(1)
        return f"{domain}:{bus}:{slot}.{func}"

    seen = set()
    duplicates = []
    for hostdev in devices.findall('hostdev'):
        if hostdev.get('type') != 'pci':
            continue
        key = pci_key_from_hostdev(hostdev)
        if key is None or key not in span_pcis:
            continue
        if key in seen:
            duplicates.append(hostdev)
        else:
            seen.add(key)

    for hostdev in duplicates:
        devices.remove(hostdev)

    added = 0
    for pci in span_pcis:
        if pci in seen:
            continue
        try:
            domain, bus, slot_func = pci.split(':')
            slot, func = slot_func.split('.')
        except ValueError:
            print(f"WARNING: Invalid PCI address format: {pci}")
            continue

        hostdev = ET.Element('hostdev', mode='subsystem', type='pci', managed='yes')
        source = ET.SubElement(hostdev, 'source')
        ET.SubElement(
            source,
            'address',
            domain=f"0x{domain}",
            bus=f"0x{bus}",
            slot=f"0x{slot}",
            function=f"0x{func}"
        )
        devices.append(hostdev)
        added += 1

    if added > 0 or duplicates:
        ET.indent(tree, space="  ")
        tree.write("${vm_xml_new}", encoding='unicode', xml_declaration=True)
    print(f"SPAN PCI hostdev add complete: added={added}, deduped={len(duplicates)}")
except Exception as e:
    print(f"ERROR: Failed to add SPAN PCI hostdevs: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF
            if [[ $? -eq 0 ]]; then
              log "[STEP 09] SPAN PCI hostdevs processed successfully (python3)."
            else
              log "ERROR: Failed to process SPAN PCI hostdevs using python3."
              return 1
            fi
          else
            log "[STEP 09] WARNING: python3 not available. Falling back to awk hostdev add."
            log "[STEP 09] Adding SPAN NIC PCIs for PCI passthrough: ${span_pci_list}"
            for pci_full in ${span_pci_list}; do
              if [[ "${pci_full}" =~ ^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
                local domain="${BASH_REMATCH[1]}"
                local bus="${BASH_REMATCH[2]}"
                local slot="${BASH_REMATCH[3]}"
                local func="${BASH_REMATCH[4]}"
                
                local pci_already_exists=0
                if grep -q "domain='0x${domain}'.*bus='0x${bus}'.*slot='0x${slot}'.*function='0x${func}'" "${vm_xml_new}" 2>/dev/null; then
                  log "[INFO] SPAN PCI(${pci_full}) hostdev already exists in XML (skipping addition)"
                  pci_already_exists=1
                fi
                
                if [[ "${pci_already_exists}" -eq 0 ]]; then
                  local hostdev_xml="    <hostdev mode='subsystem' type='pci' managed='yes'>
        <source>
          <address domain='0x${domain}' bus='0x${bus}' slot='0x${slot}' function='0x${func}'/>
        </source>
      </hostdev>"

                  local tmp_xml="${vm_xml_new}.tmp"
                  awk -v hostdev="$hostdev_xml" '
                    /<\/devices>/ { print hostdev }
                    { print }
                  ' "${vm_xml_new}" > "${tmp_xml}"
                  mv "${tmp_xml}" "${vm_xml_new}"
                  log "SPAN PCI(${pci_full}) hostdev attached successfully"
                fi
              else
                log "WARNING: Invalid PCI address format: ${pci_full}"
              fi
            done
          fi
        elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
          # Add SPAN bridges as virtio interfaces
          # Use SPAN_BRIDGE_LIST if available, otherwise generate from SPAN_NIC_LIST
          local span_bridge_list_for_xml="${SPAN_BRIDGE_LIST:-}"
          
          if [[ -z "${span_bridge_list_for_xml}" ]]; then
            # Generate bridge names from SPAN_NIC_LIST (fallback, should not happen if bridge creation above worked)
            local span_nic_list_to_use="${SPAN_NIC_LIST:-${SPAN_NICS}}"
            if [[ -n "${span_nic_list_to_use}" ]]; then
              log "[STEP 09] SPAN_BRIDGE_LIST is empty, generating from SPAN_NIC_LIST for XML..."
              local span_index=0
              local generated_bridge_list=""
              for span_nic in ${span_nic_list_to_use}; do
                local bridge_name="br-span${span_index}"
                generated_bridge_list="${generated_bridge_list} ${bridge_name}"
                ((span_index++))
              done
              span_bridge_list_for_xml="${generated_bridge_list# }"
              log "[STEP 09] Generated SPAN bridge list for XML: ${span_bridge_list_for_xml}"
            fi
          fi
          
          if [[ -n "${span_bridge_list_for_xml}" ]]; then
            log "Adding SPAN bridges as virtio interfaces: ${span_bridge_list_for_xml}"
            
            # Use python to check and add SPAN bridge interfaces (more reliable than grep)
            if command -v python3 >/dev/null 2>&1; then
              python3 <<EOF
import sys
import xml.etree.ElementTree as ET

try:
    tree = ET.parse("${vm_xml_new}")
    root = tree.getroot()
    
    devices = root.find('.//devices')
    if devices is not None:
        span_bridges = "${span_bridge_list_for_xml}".split()
        
        # Step 1: Remove any duplicate SPAN bridge interfaces first
        # Keep only the first occurrence of each SPAN bridge
        span_bridge_interfaces = {}
        interfaces_to_remove = []
        
        for interface in devices.findall('interface'):
            source = interface.find('source')
            if source is not None:
                bridge_name = source.get('bridge')
                if bridge_name and bridge_name.startswith('br-span'):
                    if bridge_name not in span_bridge_interfaces:
                        span_bridge_interfaces[bridge_name] = interface
                    else:
                        interfaces_to_remove.append(interface)
        
        for interface in interfaces_to_remove:
            devices.remove(interface)
        if len(interfaces_to_remove) > 0:
            print(f"Removed {len(interfaces_to_remove)} duplicate SPAN bridge interface(s) before adding")
        
        # Step 2: Add missing SPAN bridge interfaces
        added_count = 0
        skipped_count = 0
        
        for bridge_name in span_bridges:
            if not bridge_name:
                continue
            
            # Check if this bridge interface already exists
            bridge_exists = False
            for interface in devices.findall('interface'):
                source = interface.find('source')
                if source is not None:
                    if source.get('bridge') == bridge_name:
                        bridge_exists = True
                        skipped_count += 1
                        print(f"SPAN bridge {bridge_name} interface already exists (skipping)")
                        break
            
            if not bridge_exists:
                # Create new interface element
                interface_elem = ET.Element('interface', type='bridge')
                source_elem = ET.SubElement(interface_elem, 'source', bridge=bridge_name)
                model_elem = ET.SubElement(interface_elem, 'model', type='virtio')
                
                # Add before </devices>
                devices.append(interface_elem)
                added_count += 1
                print(f"SPAN bridge {bridge_name} interface added")
        
        # Write modified XML
        ET.indent(tree, space="  ")
        tree.write("${vm_xml_new}", encoding='unicode', xml_declaration=True)
        print(f"SPAN bridge interfaces: {added_count} added, {skipped_count} already existed")
    else:
        print("ERROR: devices element not found in XML")
        sys.exit(1)
except Exception as e:
    print(f"ERROR: Failed to process XML: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF
              if [[ $? -eq 0 ]]; then
                log "[STEP 09] SPAN bridge interfaces processed successfully."
              else
                log "WARNING: Failed to add SPAN bridge interfaces using python3. Falling back to awk method."
                # Fallback to original method
                for bridge_name in ${span_bridge_list_for_xml}; do
                  # Check if bridge interface already exists in XML (more thorough check)
                  local existing_count
                  existing_count=$(grep -c "<source bridge='${bridge_name}'/>" "${vm_xml_new}" 2>/dev/null || echo "0")
                  if [[ "${existing_count}" -gt 0 ]]; then
                    log "[INFO] SPAN bridge ${bridge_name} interface already exists in XML (${existing_count} found, skipping addition)"
                  else
                    # Add bridge interface before </devices>
                    local span_interface="    <interface type='bridge'>
      <source bridge='${bridge_name}'/>
      <model type='virtio'/>
    </interface>"
                    
                    # Modify XML using temporary file
                    local tmp_xml="${vm_xml_new}.tmp"
                    awk -v interface="$span_interface" '
                      /<\/devices>/ { print interface }
                      { print }
                    ' "${vm_xml_new}" > "${tmp_xml}"
                    mv "${tmp_xml}" "${vm_xml_new}"
                    log "SPAN bridge ${bridge_name} virtio interface added successfully"
                  fi
                done
              fi
            else
              # Fallback if python3 not available
              for bridge_name in ${span_bridge_list_for_xml}; do
                local existing_count
                existing_count=$(grep -c "<source bridge='${bridge_name}'/>" "${vm_xml_new}" 2>/dev/null || echo "0")
                if [[ "${existing_count}" -gt 0 ]]; then
                  log "[INFO] SPAN bridge ${bridge_name} interface already exists in XML (${existing_count} found, skipping addition)"
                else
                  local span_interface="    <interface type='bridge'>
      <source bridge='${bridge_name}'/>
      <model type='virtio'/>
    </interface>"
                  
                  local tmp_xml="${vm_xml_new}.tmp"
                  awk -v interface="$span_interface" '
                    /<\/devices>/ { print interface }
                    { print }
                  ' "${vm_xml_new}" > "${tmp_xml}"
                  mv "${tmp_xml}" "${vm_xml_new}"
                  log "SPAN bridge ${bridge_name} virtio interface added successfully"
                fi
              done
            fi
          else
            log "WARNING: SPAN_BRIDGE_LIST is empty and SPAN_NIC_LIST/SPAN_NICS are also empty. Cannot add SPAN bridges to VM XML."
          fi
        else
          log "WARNING: Unknown SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE}"
        fi
        
        # Validate modified XML before redefine
        log "Validating modified XML with virsh define --validate"
        local validate_output
        validate_output=$(virsh define --validate "${vm_xml_new}" 2>&1)
        if [[ $? -ne 0 ]]; then
          log "ERROR: XML validation failed: ${vm_xml_new}"
          log "ERROR: virsh define --validate output: ${validate_output}"
          if [[ -f "${vm_xml_backup}" ]]; then
            log "Attempting rollback using original XML: ${vm_xml_backup}"
            virsh define "${vm_xml_backup}" >/dev/null 2>&1 || true
          fi
          return 1
        fi

        # Check duplicate PCI hostdev entries in modified XML
        local dup_pci_list
        dup_pci_list=$(grep -oE "0000:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-9a-f]" "${vm_xml_new}" | sort | uniq -d || true)
        if [[ -n "${dup_pci_list}" ]]; then
          log "ERROR: Duplicate PCI hostdev detected in XML: ${dup_pci_list}"
          if [[ -f "${vm_xml_backup}" ]]; then
            log "Attempting rollback using original XML: ${vm_xml_backup}"
            virsh define "${vm_xml_backup}" >/dev/null 2>&1 || true
          fi
          return 1
        fi

        # Redefine VM with modified XML (no undefine)
        log "Redefining VM with modified XML (no undefine)"
        
        # Try to define VM and capture error output
        local define_output
        define_output=$(virsh define "${vm_xml_new}" 2>&1)
        local define_exit_code=$?
        
        if [[ ${define_exit_code} -ne 0 ]]; then
          log "ERROR: Failed to define VM with modified XML (exit code: ${define_exit_code})"
          log "ERROR: virsh define error output: ${define_output}"
          log "ERROR: Please check XML file: ${vm_xml_new}"
          log "ERROR: You can validate XML with: virsh define --validate ${vm_xml_new}"
          if [[ -f "${vm_xml_backup}" ]]; then
            log "Attempting rollback using original XML: ${vm_xml_backup}"
            virsh define "${vm_xml_backup}" >/dev/null 2>&1 || true
          fi
          return 1
        fi
        log "VM XML defined successfully"
        
        # Verify VM was defined successfully
        if ! virsh dominfo mds >/dev/null 2>&1; then
          log "ERROR: VM definition failed - VM 'mds' does not exist after define"
          return 1
        fi
        log "VM redefined successfully"
        
        # Start VM
        log "Starting mds VM"
        if ! virsh start mds 2>/dev/null; then
          log "WARNING: VM start not confirmed yet (may already be running or need manual start)"
        else
          log "VM started successfully"
        fi
        
        if [[ "${net_mode}" == "bridge" ]]; then
          log "br-data bridge and SPAN interfaces added successfully"
        elif [[ "${net_mode}" == "nat" ]]; then
          log "virbr0 (default network) and SPAN interfaces added successfully"
        fi
      else
        log "ERROR: VM XML file does not exist."
        return 1
      fi
    else
      log "[DRY-RUN] Adding network and SPAN interfaces (not executed)"
      if [[ "${net_mode}" == "bridge" ]]; then
        log "[DRY-RUN] br-data bridge: <interface type='bridge'><source bridge='br-data'/><model type='virtio'/></interface>"
      elif [[ "${net_mode}" == "nat" ]]; then
        log "[DRY-RUN] virbr0 (default network): <interface type='network'><source network='default'/><model type='virtio'/></interface>"
      fi

      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
          log "[DRY-RUN] SPAN NIC PCI passthrough: ${SENSOR_SPAN_VF_PCIS}"
          for pci_full in ${SENSOR_SPAN_VF_PCIS}; do
            log "[DRY-RUN] SPAN PCI(${pci_full}) hostdev add scheduled"
          done
        fi
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
          log "[DRY-RUN] SPAN bridge virtio interfaces: ${SPAN_BRIDGE_LIST}"
          for bridge_name in ${SPAN_BRIDGE_LIST}; do

            log "[DRY-RUN] bridge ${bridge_name} virtio interface add scheduled"
          done
        fi
      fi
    fi

    ###########################################################################
    # 1.5. Verify sensor VM storage mount (no migration needed)
    #  - VM images are already created directly under /var/lib/libvirt/images/mds
    #  - Mount point verification only (no file movement required)
    ###########################################################################
    local VM_STORAGE_BASE="/var/lib/libvirt/images/mds"
    
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] (MOUNTCHK) mountpoint -q ${VM_STORAGE_BASE}"
        log "[DRY-RUN] (VERIFY) VM XML paths should reference ${VM_STORAGE_BASE}"
    else
        # Verify mount point exists and is mounted
        if ! mountpoint -q "${VM_STORAGE_BASE}" 2>/dev/null; then
            whiptail_msgbox "STEP 09 - Mount Error" "${VM_STORAGE_BASE} is not mounted.\n\nPlease complete STEP 07 (sensor LV mount) first."
            log "[STEP 09] ERROR: ${VM_STORAGE_BASE} not mounted -> STEP Abort"
            return 1
        fi

        # Verify VM exists before checking XML
        if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
            log "[STEP 09] ERROR: VM '${SENSOR_VM}' does not exist. Cannot verify storage paths."
            whiptail_msgbox "STEP 09 - VM Not Found" "VM '${SENSOR_VM}' does not exist after XML modification.\n\nPlease check the logs and re-run STEP 08 if needed."
            return 1
        fi

        # Verify VM XML paths reference the correct location
        log "[STEP 09] Verifying VM XML storage paths"
        local xml_path_check=0
        local xml_dump_output
        xml_dump_output=$(virsh dumpxml "${SENSOR_VM}" 2>/dev/null)
        if [[ $? -ne 0 || -z "${xml_dump_output}" ]]; then
            log "[STEP 09] ERROR: Failed to dump VM XML for '${SENSOR_VM}'"
            return 1
        fi
        
        while read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ "${f}" =~ ^${VM_STORAGE_BASE} ]]; then
                xml_path_check=$((xml_path_check+1))
            fi
        done < <(echo "${xml_dump_output}" | awk -F"'" '/<source file=/{print $2}')

        if [[ "${xml_path_check}" -eq 0 ]]; then
            log "[STEP 09] INFO: VM XML paths may not reference ${VM_STORAGE_BASE} (may be using different path)"
        else
            log "[STEP 09] Verified: VM XML references ${xml_path_check} file(s) under ${VM_STORAGE_BASE}"
        fi

        # Verify that files referenced in XML actually exist
        log "[STEP 09] Checking XML source file existence"
        local missing=0
        local optional_files=0
        local optional_missing_list=""
        local xml_dump_output
        xml_dump_output=$(virsh dumpxml "${SENSOR_VM}" 2>/dev/null)
        if [[ $? -ne 0 || -z "${xml_dump_output}" ]]; then
            log "[STEP 09] ERROR: Failed to dump VM XML for '${SENSOR_VM}'"
            return 1
        fi
        
        while read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ ! -e "${f}" ]]; then
                # Check if this is an optional file (cloud-init ISO files are optional)
                if [[ "${f}" =~ -cidata\.iso$ ]] || [[ "${f}" =~ cloud-init ]]; then
                    log "[STEP 09] WARNING: optional file missing (cloud-init ISO): ${f}"
                    log "[STEP 09] This file is optional and VM can run without it"
                    optional_files=$((optional_files+1))
                    optional_missing_list+="${f}"$'\n'
                else
                    log "[STEP 09] ERROR: missing required file: ${f}"
                    missing=$((missing+1))
                fi
            fi
        done < <(echo "${xml_dump_output}" | awk -F"'" '/<source file=/{print $2}')

        if [[ "${missing}" -gt 0 ]]; then
            whiptail_msgbox "STEP 09 - File Missing" "VM XML references ${missing} missing required file(s).\n\nPlease re-run STEP 08 (Deployment) or check image file locations."
            log "[STEP 09] ERROR: XML source file missing count=${missing}"
            return 1
        fi
        
        if [[ "${optional_files}" -gt 0 ]]; then
            log "[STEP 09] INFO: ${optional_files} optional file(s) missing (cloud-init ISO) - removing from VM XML..."

            if command -v python3 >/dev/null 2>&1; then
                local tmp_optional_xml="${STATE_DIR}/${SENSOR_VM}_optional_cleanup.xml"
                if ! virsh dumpxml "${SENSOR_VM}" > "${tmp_optional_xml}" 2>/dev/null; then
                    log "[STEP 09] WARNING: Failed to dump VM XML for optional cleanup"
                else
                    python3 <<EOF
import sys
import xml.etree.ElementTree as ET

missing = set(filter(None, """${optional_missing_list}""".splitlines()))
if not missing:
    sys.exit(0)

try:
    tree = ET.parse("${tmp_optional_xml}")
    root = tree.getroot()
    devices = root.find('.//devices')
    if devices is None:
        print("ERROR: devices element not found in XML")
        sys.exit(1)

    removed = 0
    for disk in list(devices.findall('disk')):
        source = disk.find('source')
        if source is not None and source.get('file') in missing:
            devices.remove(disk)
            removed += 1

    if removed > 0:
        ET.indent(tree, space="  ")
        tree.write("${tmp_optional_xml}", encoding='unicode', xml_declaration=True)
        print(f"Removed {removed} optional cloud-init disk(s) from XML")
    else:
        print("No optional cloud-init disks removed (not found in XML)")
except Exception as e:
    print(f"ERROR: Failed to remove optional disks: {e}")
    sys.exit(1)
EOF
                    local cleanup_exit_code=$?
                    if [[ ${cleanup_exit_code} -eq 0 ]]; then
                        if ! virsh define "${tmp_optional_xml}" >/dev/null 2>&1; then
                            log "[STEP 09] WARNING: Failed to redefine VM after removing optional disks"
                        else
                            log "[STEP 09] Optional cloud-init disks removed from VM XML"
                            if ! virsh list --state-running | grep -q "\s${SENSOR_VM}\s"; then
                                log "[STEP 09] Starting ${SENSOR_VM} VM after optional disk cleanup"
                                virsh start "${SENSOR_VM}" >/dev/null 2>&1 || log "[STEP 09] WARNING: Failed to start VM after optional disk cleanup"
                            fi
                        fi
                    else
                        log "[STEP 09] WARNING: Optional disk cleanup failed (exit code: ${cleanup_exit_code})"
                    fi
                fi
            else
                log "[STEP 09] WARNING: python3 not available. Cannot auto-remove optional cloud-init disks"
            fi
        fi
    fi

    ###########################################################################
    # 2. PCI Passthrough connection (Action)
    ###########################################################################
    local hostdev_count=0
    if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        log "[STEP 09] Checking PCI passthrough configuration..."
        log "[STEP 09] SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE:-<not set>}"
        log "[STEP 09] SENSOR_SPAN_VF_PCIS: '${SENSOR_SPAN_VF_PCIS:-<empty>}'"

        # If SENSOR_SPAN_VF_PCIS is still empty after XML modification, try to re-detect
        if [[ -z "${SENSOR_SPAN_VF_PCIS:-}" && -n "${SPAN_NICS:-}" ]]; then
            log "[STEP 09] SENSOR_SPAN_VF_PCIS is still empty. Re-detecting PCI addresses..."
            local span_pci_list=""
            for span_nic in ${SPAN_NICS}; do
                local pci_addr
                pci_addr=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
                if [[ -n "${pci_addr}" ]]; then
                    span_pci_list="${span_pci_list} ${pci_addr}"
                    log "[STEP 09] Detected PCI address for ${span_nic}: ${pci_addr}"
                else
                    log "[STEP 09] WARNING: Could not detect PCI address for ${span_nic}"
                fi
            done
            if [[ -n "${span_pci_list}" ]]; then
                SENSOR_SPAN_VF_PCIS="${span_pci_list# }"
                save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
                log "[STEP 09] SENSOR_SPAN_VF_PCIS updated: ${SENSOR_SPAN_VF_PCIS}"
            fi
        fi

        if [[ -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
            # Verify VM exists before attempting PCI passthrough
            if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
                log "[STEP 09] ERROR: VM '${SENSOR_VM}' does not exist. Cannot attach PCI devices."
                log "[STEP 09] Please ensure VM was successfully defined in previous steps."
                return 1
            fi

            log "[STEP 09] Starting PCI passthrough connection..."

            for pci_full in ${SENSOR_SPAN_VF_PCIS}; do
                if [[ "${pci_full}" =~ ^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
                    local d="0x${BASH_REMATCH[1]}"
                    local b="0x${BASH_REMATCH[2]}"
                    local s="0x${BASH_REMATCH[3]}"
                    local f="0x${BASH_REMATCH[4]}"

                    local pci_xml="${STATE_DIR}/pci_${pci_full//:/_}.xml"
                    cat > "${pci_xml}" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='${d}' bus='${b}' slot='${s}' function='${f}'/>
  </source>
</hostdev>
EOF
                    # Check if PCI device is already attached to VM (check full address including domain)
                    local vm_xml_check
                    vm_xml_check=$(virsh dumpxml "${SENSOR_VM}" 2>/dev/null || true)
                    if [[ $? -eq 0 && -n "${vm_xml_check}" ]]; then
                        if echo "${vm_xml_check}" | grep -q "address.*domain='${d}'.*bus='${b}'.*slot='${s}'.*function='${f}'"; then
                            log "[INFO] PCI (${pci_full}) is already connected to VM. Skipping attachment."
                        else
                            log "[ACTION] Connecting PCI (${pci_full}) to VM..."
                            if [[ "${_DRY}" -eq 0 ]]; then
                                # Check if VM is running - if not, only use --config flag
                                local attach_flags="--config"
                                if virsh list --state-running | grep -q "\s${SENSOR_VM}\s" 2>/dev/null; then
                                    attach_flags="--config --live"
                                fi

                                if virsh attach-device "${SENSOR_VM}" "${pci_xml}" ${attach_flags} 2>/dev/null; then
                                    log "[SUCCESS] PCI passthrough connection successful"
                                else
                                    log "[ERROR] PCI passthrough connection failed (device may be in use, check IOMMU configuration)"
                                fi
                            else
                                log "[DRY-RUN] virsh attach-device ${SENSOR_VM} ${pci_xml} --config --live"
                            fi
                        fi
                    else
                        log "[ERROR] Failed to dump VM XML. Cannot check PCI attachment status."
                    fi
                else
                    log "[WARN] Invalid PCI address format: ${pci_full}"
                fi
            done
        else
            log "[INFO] PCI passthrough mode is not configured."
        fi

        ###########################################################################
        # 3. Connection status verification
        ###########################################################################
        log "[STEP 09] Checking Sensor VM PCI passthrough status"

        local vm_xml_status
        vm_xml_status=$(virsh dumpxml "${SENSOR_VM}" 2>/dev/null || true)
        if [[ $? -eq 0 && -n "${vm_xml_status}" ]]; then
            if echo "${vm_xml_status}" | grep -q "<hostdev.*type='pci'"; then
                hostdev_count=$(echo "${vm_xml_status}" | grep -c "<hostdev.*type='pci'" || echo "0")
                log "[STEP 09] Sensor VM has ${hostdev_count} PCI hostdev device(s) connected"
            else
                log "[WARN] Sensor VM PCI hostdev does not exist."
            fi
        else
            log "[ERROR] Failed to dump VM XML. Cannot verify PCI passthrough status."
        fi
    else
        # Bridge mode: avoid PCI-related log output, but capture count if present.
        local vm_xml_status
        vm_xml_status=$(virsh dumpxml "${SENSOR_VM}" 2>/dev/null || true)
        if [[ -n "${vm_xml_status}" ]] && echo "${vm_xml_status}" | grep -q "<hostdev.*type='pci'"; then
            hostdev_count=$(echo "${vm_xml_status}" | grep -c "<hostdev.*type='pci'" || echo "0")
        fi
    fi

    ###########################################################################
    # 4. VM restart not needed
    # - XML modifications were applied and VM was already started
    # - PCI passthrough uses --live flag, so changes are applied immediately
    ###########################################################################
    # restart_vm_safely() removed - VM already started after XML modification

    ###########################################################################
    # 5. Result summary 
    ###########################################################################
    local vm_state
    vm_state=$(virsh domstate "${SENSOR_VM}" 2>/dev/null || echo "unknown")
    
    # Check SPAN connection mode
    local span_attach_mode="${SPAN_ATTACH_MODE:-pci}"
    
    local summary
    summary=$(cat <<EOF
[STEP 09 Result Summary]

✅ Sensor VM Configuration:
   - VM Name: ${SENSOR_VM}
   - VM Status: ${vm_state}
EOF
)
    
    # Add SPAN connection information based on mode
    if [[ "${span_attach_mode}" == "bridge" ]]; then
        # Bridge Mode: Show bridge information
        local span_bridge_count=0
        local span_bridge_list_display=""
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
            for bridge_name in ${SPAN_BRIDGE_LIST}; do
                if ip link show "${bridge_name}" >/dev/null 2>&1; then
                    ((span_bridge_count++))
                    if [[ -z "${span_bridge_list_display}" ]]; then
                        span_bridge_list_display="${bridge_name}"
                    else
                        span_bridge_list_display="${span_bridge_list_display}, ${bridge_name}"
                    fi
                fi
            done
        fi
        
        summary="${summary}"$(cat <<EOF
   - SPAN Connection Mode: Bridge (L2 bridge virtio)
EOF
)
        
        if [[ "${span_bridge_count}" -gt 0 ]]; then
            summary="${summary}"$(cat <<EOF

✅ SPAN Bridge Connection:
   - Successfully connected ${span_bridge_count} SPAN bridge(s)
   - Bridges: ${span_bridge_list_display}
   - Devices are ready for traffic monitoring
EOF
)
        else
            summary="${summary}"$(cat <<EOF

⚠️  SPAN Bridge Connection:
   - No SPAN bridges connected
   - Please check STEP 03 configuration (SPAN bridge creation)
   - Verify SPAN_BRIDGE_LIST is configured correctly
EOF
)
        fi
        
        # Also show PCI passthrough count if any (for other devices)
        if [[ "${hostdev_count}" -gt 0 ]]; then
            summary="${summary}"$(cat <<EOF
   - Additional PCI Passthrough Devices: ${hostdev_count}
EOF
)
        fi
    elif [[ "${span_attach_mode}" == "pci" ]]; then
        # PCI Mode: Show PCI passthrough information
        summary="${summary}"$(cat <<EOF
   - SPAN Connection Mode: PCI Passthrough
   - PCI Passthrough Devices: ${hostdev_count}
EOF
)
        
        if [[ "${hostdev_count}" -gt 0 ]]; then
            summary="${summary}"$(cat <<EOF

✅ PCI Passthrough:
   - Successfully connected ${hostdev_count} SPAN NIC device(s)
   - Devices are ready for traffic monitoring
EOF
)
            if [[ -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
                summary="${summary}"$(cat <<EOF

   - PCI Addresses:
EOF
)
                for pci_full in ${SENSOR_SPAN_VF_PCIS}; do
                    summary="${summary}"$(cat <<EOF
     • ${pci_full}
EOF
)
                done
            fi
        else
            summary="${summary}"$(cat <<EOF

⚠️  PCI Passthrough:
   - No PCI devices connected
   - Please check STEP 01 configuration (SPAN NIC selection)
   - Verify IOMMU is enabled in BIOS
EOF
)
        fi
    else
        # Unknown mode
        summary="${summary}"$(cat <<EOF
   - SPAN Connection Mode: ${span_attach_mode} (unknown)
   - PCI Passthrough Devices: ${hostdev_count}
EOF
)
    fi
    
    summary="${summary}"$(cat <<EOF

📝 Next Steps:
   - VM is configured and ready for operation
   - Proceed to STEP 10 (Install DP CLI) if needed
EOF
)

    whiptail_msgbox "STEP 09 Completed" "${summary}" 20 80

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} ====="
}


###############################################################################
# STEP 10 – Install DP Appliance CLI package (use local file, no internet download)
###############################################################################
step_10_install_dp_cli() {
    local STEP_ID="10_install_dp_cli"
    local STEP_NAME="10. Install DP Appliance CLI package"
    local _DRY="${DRY_RUN:-0}"
    _DRY="${_DRY//\"/}"

    local VENV_DIR="/opt/dp_cli_venv"
    local ERRLOG="/var/log/aella/dp_cli_step13_error.log"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DP Appliance CLI package Installation/Apply"

    if type load_config >/dev/null 2>&1; then
        load_config || true
    fi

    if ! whiptail_yesno "STEP 10 Execution Check" "Install DP Appliance CLI package (dp_cli) and apply to stellar user.\n\n(Will download latest version from GitHub: https://github.com/RickLee-kr/Stellar-appliance-cli)\n\nDo you want to continue?" 15 85
    then
        log "User canceled STEP 10 execution."
        return 0
    fi

    # 0) Create log file 
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Log file will be created: ${ERRLOG}"
    else
        mkdir -p /var/log/aella || true
        : > "${ERRLOG}" || true
        chmod 644 "${ERRLOG}" || true
    fi

    # 0-1) Install required packages first (before download/extraction)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Installing required packages (wget/curl, unzip, python3-pip, python3-venv)..."
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] apt-get update -y"
        log "[DRY-RUN] apt-get install -y python3-pip python3-venv wget curl unzip"
    else
        if ! apt-get update -y >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: apt-get update failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        fi
        if ! apt-get install -y python3-pip python3-venv wget curl unzip >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to install required packages" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Required packages installed successfully"
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
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to create temp directory: ${TEMP_DIR}" | tee -a "${ERRLOG}"
            return 1
        }

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Downloading dp_cli from GitHub: ${GITHUB_REPO}"
        echo "=== Downloading from GitHub (this may take a moment) ==="
        
        # Download using wget or curl
        if command -v wget >/dev/null 2>&1; then
            if ! wget --progress=bar:force -O "${ZIP_FILE}" "${DOWNLOAD_URL}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to download from GitHub" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check network connection and ${ERRLOG} for details." | tee -a "${ERRLOG}"
                rm -rf "${TEMP_DIR}" || true
                return 1
            fi
        elif command -v curl >/dev/null 2>&1; then
            if ! curl -L -o "${ZIP_FILE}" "${DOWNLOAD_URL}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to download from GitHub" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check network connection and ${ERRLOG} for details." | tee -a "${ERRLOG}"
                rm -rf "${TEMP_DIR}" || true
                return 1
            fi
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Neither wget nor curl is available. Please install one of them." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        echo "=== Extracting downloaded file ==="
        # Extract zip file (unzip should already be installed)
        if ! unzip -q "${ZIP_FILE}" -d "${TEMP_DIR}" >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to extract zip file" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        # Check if setup.py exists in extracted directory
        if [[ ! -f "${EXTRACT_DIR}/setup.py" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: setup.py not found in downloaded package" | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        fi

        pkg="${EXTRACT_DIR}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Successfully downloaded and extracted dp_cli from GitHub"
    fi

    # 2) venv Creation/ after dp-cli Installation
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] venv Creation: ${VENV_DIR}"
        log "[DRY-RUN] venv dp-cli Installation: ${pkg}"
        log "[DRY-RUN] Will verify import after installation"
    else
        rm -rf "${VENV_DIR}" || true
        python3 -m venv "${VENV_DIR}" || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: venv Creation Failed: ${VENV_DIR}" | tee -a "${ERRLOG}"
            return 1
        }

        "${VENV_DIR}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true

        # Install setuptools<81 and wheel (pip will skip if already satisfied)
        "${VENV_DIR}/bin/python" -m pip install --quiet "setuptools<81" wheel >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: venv setuptools installation failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        # Install from downloaded directory (pip will skip if already installed)
        (cd "${pkg}" && "${VENV_DIR}/bin/python" -m pip install --quiet .) >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli installation failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        }

        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('appliance_cli import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: appliance_cli import failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        if [[ ! -x "${VENV_DIR}/bin/aella_cli" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: ${VENV_DIR}/bin/aella_cli does not exist." | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: dp-cli package must include console_scripts (aella_cli) entry point." | tee -a "${ERRLOG}"
            return 1
        fi

        # Runtime verification performed only based on import (removed aella_cli execution smoke test)
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli runtime import verification failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }
    fi

    # 4) /usr/local/bin/aella_cli 
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /usr/local/bin/aella_cli wrapper script"
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

    # 5) /usr/bin/aella_cli (Login for)
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /usr/bin/aella_cli script"
    else
        cat > /usr/bin/aella_cli <<'EOF'
#!/bin/bash
[ $# -ge 1 ] && exit 1
cd /tmp || exit 1
exec sudo /usr/local/bin/aella_cli
EOF
        chmod +x /usr/bin/aella_cli
    fi

    # 6) /etc/shells 
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Adding /usr/bin/aella_cli to /etc/shells (if not exists)"
    else
        if ! grep -qx "/usr/bin/aella_cli" /etc/shells 2>/dev/null; then
            echo "/usr/bin/aella_cli" >> /etc/shells
        fi
    fi

    # 7) stellar sudo NOPASSWD
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] /etc/sudoers.d/stellar Creation: 'stellar ALL=(ALL) NOPASSWD: ALL'"
    else
        echo "stellar ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/stellar
        chmod 440 /etc/sudoers.d/stellar
        visudo -cf /etc/sudoers.d/stellar >/dev/null 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: sudoers syntax invalid: /etc/sudoers.d/stellar" | tee -a "${ERRLOG}"
            return 1
        }
    fi

    # 8) syslog 
    if id stellar >/dev/null 2>&1; then
        run_cmd "usermod -a -G syslog stellar"
    else
        log "[WARN] User 'stellar' does not exist. Cannot add to syslog group."
    fi

    # 9) login shell change
    if id stellar >/dev/null 2>&1; then
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] Changing stellar user login shell to /usr/bin/aella_cli"
        else
            chsh -s /usr/bin/aella_cli stellar || true
        fi
    fi

    # 10) /var/log/aella  change
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Creating /var/log/aella directory and changing ownership to stellar"
    else
        mkdir -p /var/log/aella
        if id stellar >/dev/null 2>&1; then
            chown -R stellar:stellar /var/log/aella || true
        fi
    fi

    # 11) Verification
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Installation verification step"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: /usr/local/bin/aella_cli*"
        ls -l /usr/local/bin/aella_cli* 2>/dev/null || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: venv appliance_cli import"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('appliance_cli import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: runtime import check"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import appliance_cli; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: error log path => ${ERRLOG}"
        tail -n 40 "${ERRLOG}" 2>/dev/null || true
    fi

    # Clean up temporary download directory
    if [[ "${_DRY}" -eq 0 && -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Cleaning up temporary download directory: ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}" || true
    fi

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    # Completion message box
    local completion_msg
    completion_msg="STEP 10: DP Appliance CLI Installation Completed

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

    whiptail_msgbox "STEP 10 - Installation Complete" "${completion_msg}" "${dialog_height}" "${dialog_width}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 13. Install DP Appliance CLI package ====="
    echo
}


menu_config() {
  while true; do
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
    msg+="DRY_RUN        : ${DRY_RUN}\n"
    msg+="SENSOR_VERSION : ${SENSOR_VERSION}\n"
    msg+="ACPS_USER      : ${ACPS_USERNAME:-<Not Set>}\n"
    msg+="ACPS_PASSWORD  : ${acps_password_display}\n"
    msg+="ACPS_URL       : ${ACPS_BASE_URL:-<Not Set>}\n"
    msg+="AUTO_REBOOT    : ${ENABLE_AUTO_REBOOT}\n"
    msg+="SPAN_MODE      : ${SPAN_ATTACH_MODE}\n"
    msg+="SENSOR_NET     : ${SENSOR_NET_MODE}\n"

    # Calculate menu size dynamically (8 menu items)
    local menu_dims
    menu_dims=$(calc_menu_size 8 80 8)
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
                      "2" "Set Sensor Version" \
                      "3" "Set ACPS Account/Password" \
                      "4" "Set ACPS URL" \
                      "5" "Set Auto Reboot (${ENABLE_AUTO_REBOOT})" \
                      "6" "Set SPAN Attachment Mode (${SPAN_ATTACH_MODE})" \
                      "7" "Set Sensor Network Mode (${SENSOR_NET_MODE})" \
                      "8" "Go Back" \
                      3>&1 1>&2 2>&3)
    local menu_rc=$?
    set -e

    # User cancelled main menu - return to previous menu
    if [[ ${menu_rc} -ne 0 ]]; then
      return 0
    fi

    # Handle empty choice (should not happen, but safety check)
    if [[ -z "${choice}" ]]; then
      continue
    fi

    case "${choice}" in
      1)
        # Toggle DRY_RUN
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          local dialog_dims
          dialog_dims=$(calc_dialog_size 12 70)
          local dialog_height dialog_width
          read -r dialog_height dialog_width <<< "${dialog_dims}"
          local centered_msg
          centered_msg=$(center_message "Current DRY_RUN=1 (simulation mode).\n\nChange to DRY_RUN=0 to execute actual commands?")

          set +e
          whiptail --title "DRY_RUN Configuration" \
                   --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
          local dry_toggle_rc=$?
          set -e

          if [[ ${dry_toggle_rc} -eq 0 ]]; then
            DRY_RUN=0
          fi
        else
          local dialog_dims
          dialog_dims=$(calc_dialog_size 12 70)
          local dialog_height dialog_width
          read -r dialog_height dialog_width <<< "${dialog_dims}"
          local centered_msg
          centered_msg=$(center_message "Current DRY_RUN=0 (actual execution mode).\n\nSafely change to DRY_RUN=1 (simulation mode)?")

          set +e
          whiptail --title "DRY_RUN Configuration" \
                   --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"
          local dry_toggle_rc=$?
          set -e

          if [[ ${dry_toggle_rc} -eq 0 ]]; then
            DRY_RUN=1
          fi
        fi
        save_config_var "DRY_RUN" "${DRY_RUN}"
        ;;
      2)
        local new_version
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        new_version=$(whiptail_inputbox "Sensor Version Configuration" "Enter sensor version." "${SENSOR_VERSION}" 10 60)
        local ver_rc=$?
        set -e
        if [[ ${ver_rc} -ne 0 ]] || [[ -z "${new_version}" ]]; then
          continue
        fi
        if [[ -n "${new_version}" ]]; then
          save_config_var "SENSOR_VERSION" "${new_version}"
          whiptail_msgbox "Sensor Version Configuration" "Sensor version has been set to ${new_version}." 8 60
        fi
        ;;
      3)
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

        local dialog_dims
        dialog_dims=$(calc_dialog_size 10 60)
        local dialog_height dialog_width
        read -r dialog_height dialog_width <<< "${dialog_dims}"
        local centered_pass_msg
        centered_pass_msg=$(center_message "Enter ACPS password.\n(This value will be saved to the config file and automatically used in STEP 09)")

        set +e
        pass=$(whiptail --title "ACPS Password Configuration" \
                        --passwordbox "${centered_pass_msg}" "${dialog_height}" "${dialog_width}" "${ACPS_PASSWORD}" \
                        3>&1 1>&2 2>&3)
        local pass_rc=$?
        set -e
        if [[ ${pass_rc} -ne 0 ]] || [[ -z "${pass}" ]]; then
          continue
        fi

        save_config_var "ACPS_USERNAME" "${user}"
        save_config_var "ACPS_PASSWORD" "${pass}"
        whiptail_msgbox "ACPS Account Configuration" "ACPS_USERNAME has been set to '${user}'." 8 70
        ;;
      4)
        local new_url
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        new_url=$(whiptail_inputbox "ACPS URL Configuration" "Enter ACPS BASE URL." "${ACPS_BASE_URL}" 10 70)
        local input_rc=$?
        set -e
        if [[ ${input_rc} -ne 0 ]] || [[ -z "${new_url}" ]]; then
          continue
        fi
        if [[ -n "${new_url}" ]]; then
          save_config_var "ACPS_BASE_URL" "${new_url}"
          whiptail_msgbox "ACPS URL Configuration" "ACPS_BASE_URL has been set to '${new_url}'." 8 70
        fi
        ;;
      5)
        local new_reboot
        if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
          new_reboot=0
        else
          new_reboot=1
        fi
        save_config_var "ENABLE_AUTO_REBOOT" "${new_reboot}"
        whiptail_msgbox "Auto Reboot Configuration" "Auto Reboot has been set to ${new_reboot}."
        ;;
      6)
        local new_mode
        set +e
        # Calculate menu size dynamically
        local menu_dims
        menu_dims=$(calc_menu_size 2 70 2)
        local menu_height menu_width menu_list_height
        read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
        
        # Center-align menu message
        local menu_msg
        menu_msg=$(center_menu_message "Select SPAN NIC connection method to sensor VM:" "${menu_height}")
        
        new_mode=$(whiptail --title "SPAN Attachment Mode Selection" \
                             --menu "${menu_msg}" \
                             "${menu_height}" "${menu_width}" "${menu_list_height}" \
                             "pci"    "PCI passthrough (PF direct assignment)" \
                             "bridge" "L2 bridge virtio NIC" \
                             3>&1 1>&2 2>&3)
        local menu_rc=$?
        set -e
        if [[ ${menu_rc} -eq 0 && -n "${new_mode}" ]]; then
          save_config_var "SPAN_ATTACH_MODE" "${new_mode}"
          whiptail_msgbox "Configuration Changed" "SPAN attachment mode has been set to ${new_mode}."
        fi
        ;;
      7)
        local new_net_mode
        set +e
        # Calculate menu size dynamically
        menu_dims=$(calc_menu_size 2 70 2)
        read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
        
        # Center-align menu message
        menu_msg=$(center_menu_message "Please select Sensor Network Mode:" "${menu_height}")
        
        new_net_mode=$(whiptail --title "Sensor Network Mode Configuration" \
                             --menu "${menu_msg}" \
                             "${menu_height}" "${menu_width}" "${menu_list_height}" \
                             "bridge" "Bridge Mode: L2 bridge Based (default)" \
                             "nat" "NAT Mode: virbr0 NAT Network Based" \
                             3>&1 1>&2 2>&3)
        local menu_rc=$?
        set -e
        if [[ ${menu_rc} -eq 0 && -n "${new_net_mode}" ]]; then
          save_config_var "SENSOR_NET_MODE" "${new_net_mode}"
          whiptail_msgbox "Configuration Changed" "Sensor Network Mode has been set to ${new_net_mode}.\n\nTo apply this change, please re-run STEP 01."
        fi
        ;;
      8)
        break
        ;;
    esac
  done
}


#######################################
# stepPer Execution menu
#######################################

menu_select_step_and_run() {
  while true; do
    load_state

    local menu_items=()
    for ((i=0; i<NUM_STEPS; i++)); do
      local step_id="${STEP_IDS[$i]}"
      local step_name="${STEP_NAMES[$i]}"
      local status=""
      local step_num=$(printf "%02d" $((i+1)))

      if [[ "${LAST_COMPLETED_STEP}" == "${step_id}" ]]; then
        status="Completed"
      elif [[ -n "${LAST_COMPLETED_STEP}" ]]; then
        local last_idx
        last_idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
        if [[ ${last_idx} -ge 0 && ${i} -le ${last_idx} ]]; then
          status="Completed"
        fi
      fi

      # Use step number as tag (instead of step_id) for cleaner display
      menu_items+=("${step_num}" "${step_name} [${status}]")
    done
    menu_items+=("back" "Return to main menu")

    # Calculate menu size dynamically
    local menu_item_count=$((NUM_STEPS + 1))
    local menu_dims
    menu_dims=$(calc_menu_size "${menu_item_count}" 100 10)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Center-align the menu message
    local centered_msg
    centered_msg=$(center_menu_message "Please select step to execute:" "${menu_height}")

    local choice
    choice=$(whiptail --title "XDR Installer - step Selection" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${menu_items[@]}" \
                      3>&1 1>&2 2>&3) || {
      # ESC or Cancel pressed - return to main menu
      return 0
    }

    # Handle empty choice (should not happen, but safety check)
    if [[ -z "${choice}" ]]; then
      return 0
    fi

    if [[ "${choice}" == "back" ]]; then
      break
    else
      # Convert step number (e.g., "01") to step index (0-based)
      local step_index=$((10#${choice} - 1))
      if [[ ${step_index} -ge 0 && ${step_index} -lt ${NUM_STEPS} ]]; then
        # Disable set -e temporarily to handle run_step errors gracefully
        set +e
        run_step "${step_index}"
        local step_rc=$?
        set -e
        # run_step always returns 0, but check anyway for safety
        if [[ ${step_rc} -ne 0 ]]; then
          log "WARNING: run_step returned non-zero exit code: ${step_rc}"
        fi
      else
        log "ERROR: Invalid step number '${choice}'"
        continue
      fi
    fi
  done
}


#######################################
# Auto Continue Execution menu
#######################################

menu_auto_continue_from_state() {
  load_state

  local next_idx
  next_idx=$(get_next_step_index)

  if [[ ${next_idx} -ge ${NUM_STEPS} ]]; then
    whiptail_msgbox "XDR Installer - Auto Execution" "All steps completed!"
    return
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"
  if ! whiptail_yesno "XDR Installer - Auto Execution" "Do you want to automatically execute from the next step?\n\nStarting step: ${next_step_name}\n\nExecution will stop if any step fails."
  then
    return
  fi

  for ((i=next_idx; i<NUM_STEPS; i++)); do
    run_step "${i}"
    if [[ "${RUN_STEP_STATUS}" == "CANCELED" ]]; then
      return
    elif [[ "${RUN_STEP_STATUS}" == "FAILED" ]]; then
      whiptail_msgbox "Auto Execution Abort" "STEP ${STEP_IDS[$i]} execution failed.\n\nAuto execution aborted."
      return
    fi
  done
}


#######################################
# in menu
#######################################

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

    # Calculate menu size dynamically (7 menu items)
    local menu_dims
    menu_dims=$(calc_menu_size 7 90 8)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Create message content
    local msg_content="${status_msg}\n\nDRY_RUN=${DRY_RUN}, STATE_FILE=${STATE_FILE}\n"
    
    # Center-align the menu message based on terminal height
    local centered_msg
    centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")

    # Run whiptail and capture both output and exit code
    choice=$(whiptail --title "XDR Sensor Installer Main Menu" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "1" "Auto execute all steps (continue from next step based on current state)" \
                      "2" "Select and run specific step only" \
                      "3" "Configuration (DRY_RUN, etc.)" \
                      "4" "Full configuration validation" \
                      "5" "Script usage guide" \
                      "6" "View log" \
                      "7" "Exit" \
                      3>&1 1>&2 2>&3) || {
      # ESC or Cancel pressed - exit code is non-zero
      # Continue loop instead of exiting
      continue
    }
    
    # Additional check: if choice is empty, also continue
    if [[ -z "${choice}" ]]; then
      continue
    fi

    case "${choice}" in
      1)
        menu_auto_continue_from_state
        ;;
      2)
        menu_select_step_and_run
        ;;
      3)
        menu_config
        ;;
      4)
        menu_full_validation
        ;;
      5)
        show_usage_help
        ;;
      6)
        if [[ -f "${LOG_FILE}" ]]; then
          show_textbox "XDR Installer Log" "${LOG_FILE}"
        else
          whiptail_msgbox "Log Not Found" "Log file does not exist yet."
        fi
        ;;
      7)
        if whiptail_yesno "Exit Confirmation" "Do you want to exit XDR Installer?"; then
          log "XDR Installer exit"
          exit 0
        fi
        ;;
    esac
  done
}

#######################################
# Full Configuration Verification
#######################################

# Build validation summary and return as English message
build_validation_summary() {
  local validation_log="$1"   # Can check based on log if needed, but here we re-check actual status

  local ok_msgs=()
  local warn_msgs=()
  local err_msgs=()

  # Load config to check network mode
  if type load_config >/dev/null 2>&1; then
    load_config 2>/dev/null || true
  fi
  local net_mode="${SENSOR_NET_MODE:-bridge}"

  ###############################
  # STEP 02: HWE Kernel Installation
  ###############################
  local hwe_found=0
  local ubuntu_version
  ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")

  # Check for HWE kernel packages based on Ubuntu version
  case "${ubuntu_version}" in
    "20.04")
      if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe-20\.04' || true; then
        hwe_found=1
      fi
      ;;
    "22.04")
      if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe-22\.04' || true; then
        hwe_found=1
      fi
      ;;
    "24.04")
      if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe-24\.04' || true; then
        hwe_found=1
      fi
      ;;
    *)
      # For other versions, check for any HWE package
      if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe' || true; then
        hwe_found=1
      fi
      ;;
  esac

  if (( hwe_found == 1 )); then
    ok_msgs+=("HWE kernel series (linux-generic-hwe) installed")
  else
    warn_msgs+=("Could not find linux-generic-hwe packages.")
    warn_msgs+=("  → ACTION: Re-run STEP 02 (HWE Kernel Installation)")
    warn_msgs+=("  → VERIFY: Check current kernel with 'uname -r'")
  fi

  ###############################
  # STEP 03: NIC/ifupdown Network Configuration
  ###############################
  if [[ "${net_mode}" == "bridge" ]]; then
    # Bridge mode: check for br-data bridge
    if ip link show br-data >/dev/null 2>&1; then
      ok_msgs+=("br-data bridge exists (Bridge mode)")
    else
      warn_msgs+=("br-data bridge does not exist (Bridge mode).")
      warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC Name/ifupdown Switch and Network Configuration)")
      warn_msgs+=("  → CHECK: Verify bridge with 'ip link show br-data'")
    fi
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT mode: check for virbr0 (libvirt default network)
    if ip link show virbr0 >/dev/null 2>&1; then
      ok_msgs+=("virbr0 bridge exists (NAT mode)")
    else
      warn_msgs+=("virbr0 bridge does not exist (NAT mode).")
      warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC Name/ifupdown Switch and Network Configuration)")
      warn_msgs+=("  → CHECK: Verify libvirt network with 'virsh net-list --all'")
    fi
  fi

  # Check ifupdown package
  # Use multiple methods to verify ifupdown is installed
  local ifupdown_installed=0
  if dpkg-query -W -f='${Status}' ifupdown 2>/dev/null | grep -q "install ok installed"; then
    ifupdown_installed=1
  elif dpkg -l 2>/dev/null | grep -qE "^ii[[:space:]]+ifupdown[[:space:]]"; then
    ifupdown_installed=1
  elif command -v ifup >/dev/null 2>&1 && command -v ifdown >/dev/null 2>&1; then
    ifupdown_installed=1
  fi
  
  if [[ "${ifupdown_installed}" -eq 1 ]]; then
    ok_msgs+=("ifupdown package installed")
  else
    warn_msgs+=("ifupdown package not installed.")
    warn_msgs+=("  → ACTION: Re-run STEP 02 (HWE Kernel Installation) or STEP 03")
    warn_msgs+=("  → MANUAL: Run 'sudo apt install -y ifupdown'")
  fi

  ###############################
  # STEP 04: KVM / Libvirt Installation
  ###############################
  if [ -c /dev/kvm ]; then
    ok_msgs+=("/dev/kvm device exists: KVM virtualization available")
  elif lsmod | grep -qE '^(kvm|kvm_intel|kvm_amd)\b'; then
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
  # STEP 05: Kernel Parameters / KSM / Swap Tuning
  ###############################
  # GRUB IOMMU configuration
  if grep -q 'intel_iommu=on' /etc/default/grub && grep -q 'iommu=pt' /etc/default/grub; then
    ok_msgs+=("GRUB IOMMU options (intel_iommu=on iommu=pt) applied")
  else
    warn_msgs+=("GRUB IOMMU options may not be configured.")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
    warn_msgs+=("  → MANUAL: Edit /etc/default/grub and add 'intel_iommu=on iommu=pt' to GRUB_CMDLINE_LINUX, then run 'sudo update-grub'")
  fi

  # Kernel parameter tuning
  if sysctl vm.min_free_kbytes 2>/dev/null | grep -q '1048576'; then
    ok_msgs+=("vm.min_free_kbytes = 1048576 (OOM prevention tuning applied)")
  else
    warn_msgs+=("vm.min_free_kbytes value may differ from installation guide (expected: 1048576).")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
    warn_msgs+=("  → CHECK: Verify /etc/sysctl.conf contains 'vm.min_free_kbytes=1048576'")
  fi

  if sysctl net.ipv4.ip_forward 2>/dev/null | grep -q '= 1'; then
    ok_msgs+=("net.ipv4.ip_forward = 1 (IPv4 forwarding enabled)")
  else
    warn_msgs+=("net.ipv4.ip_forward may not be enabled.")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
  fi

  # KSM disable check
  if [[ -f /etc/default/qemu-kvm ]]; then
    if grep -q "^KSM_ENABLED=0" /etc/default/qemu-kvm; then
      ok_msgs+=("KSM disabled (KSM_ENABLED=0 in /etc/default/qemu-kvm)")
    else
      warn_msgs+=("KSM may not be disabled.")
      warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
      warn_msgs+=("  → CHECK: Verify /etc/default/qemu-kvm contains 'KSM_ENABLED=0'")
    fi
  else
    warn_msgs+=("/etc/default/qemu-kvm file does not exist (KSM configuration missing).")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
  fi

  # Swap disable check
  if swapon --show | grep -q .; then
    warn_msgs+=("swap is still enabled.")
    warn_msgs+=("  → ACTION: Re-run STEP 05 (Kernel Parameters / KSM / Swap Tuning)")
    warn_msgs+=("  → MANUAL: Run 'sudo swapoff -a' and comment out swap entries in /etc/fstab")
  else
    ok_msgs+=("swap disabled")
  fi

  ###############################
  # STEP 06: Libvirt Hooks Installation
  ###############################
  if [[ -f /etc/libvirt/hooks/qemu ]]; then
    ok_msgs+=("/etc/libvirt/hooks/qemu script exists")
  else
    warn_msgs+=("/etc/libvirt/hooks/qemu script does not exist.")
    warn_msgs+=("  → ACTION: Re-run STEP 06 (libvirt hooks Installation)")
    warn_msgs+=("  → NOTE: VM automation features may not work without this")
  fi

  if [[ "${net_mode}" == "bridge" ]]; then
    if [[ -f /etc/libvirt/hooks/network ]]; then
      ok_msgs+=("/etc/libvirt/hooks/network script exists (Bridge mode)")
    else
      warn_msgs+=("/etc/libvirt/hooks/network script does not exist (Bridge mode).")
      warn_msgs+=("  → ACTION: Re-run STEP 06 (libvirt hooks Installation)")
    fi
  fi

  ###############################
  # STEP 07: Sensor LV Creation + Image/Script Download
  ###############################
  # Check LVM storage
  if lvs 2>/dev/null | grep -q "ubuntu-vg"; then
    ok_msgs+=("LVM volume group (ubuntu-vg) exists")
  else
    warn_msgs+=("LVM volume group (ubuntu-vg) not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify LVM volumes with 'sudo lvs'")
  fi

  # Check lv_sensor_root LV
  if lvs ubuntu-vg/lv_sensor_root >/dev/null 2>&1; then
    ok_msgs+=("lv_sensor_root LV exists")
  else
    warn_msgs+=("lv_sensor_root LV not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify with 'sudo lvs ubuntu-vg/lv_sensor_root'")
  fi

  # Check mount point
  if mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then
    ok_msgs+=("/var/lib/libvirt/images/mds mount point exists and mounted")
    
    # Check if deployment script exists
    if [[ -f /var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh ]]; then
      ok_msgs+=("Sensor deployment script (virt_deploy_modular_ds.sh) exists")
    else
      warn_msgs+=("Sensor deployment script not found in /var/lib/libvirt/images/mds/images/.")
      warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    fi
  elif [[ -d /var/lib/libvirt/images/mds ]]; then
    warn_msgs+=("/var/lib/libvirt/images/mds directory exists but may not be mounted.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify mount with 'mount | grep mds'")
  else
    warn_msgs+=("/var/lib/libvirt/images/mds mount point does not exist.")
    warn_msgs+=("  → NOTE: This is normal if before STEP 07 execution")
    warn_msgs+=("  → ACTION: Complete STEP 07 (Sensor LV Creation + Image/Script Download)")
  fi

  ###############################
  # STEP 08: Sensor VM Deployment
  ###############################
  local mds_defined=0

  if virsh dominfo mds >/dev/null 2>&1; then
    mds_defined=1
    ok_msgs+=("mds libvirt domain definition complete")
    
    # Check if VM is running
    if virsh domstate mds 2>/dev/null | grep -q "running"; then
      ok_msgs+=("mds VM is running")
    else
      warn_msgs+=("mds VM is defined but not running.")
      warn_msgs+=("  → MANUAL: Start VM with 'virsh start mds'")
      warn_msgs+=("  → CHECK: Verify VM status with 'virsh list --all'")
    fi
  else
    warn_msgs+=("mds domain not yet defined.")
    warn_msgs+=("  → NOTE: This is normal if before STEP 08 execution")
    warn_msgs+=("  → ACTION: Complete STEP 08 (Sensor VM Deployment)")
  fi

  ###############################
  # STEP 09: Sensor VM Network & SPAN Interface Configuration
  ###############################
  if (( mds_defined == 1 )); then
    # Check PCI passthrough configuration (hostdev)
    if virsh dumpxml mds 2>/dev/null | grep -q '<hostdev '; then
      ok_msgs+=("mds VM has PCI passthrough (hostdev) configuration")
    else
      # Check if SPAN_ATTACH_MODE is pci (should have passthrough)
      if [[ "${SPAN_ATTACH_MODE:-pci}" == "pci" ]]; then
        warn_msgs+=("mds VM XML does not have PCI passthrough (hostdev) configuration yet.")
        warn_msgs+=("  → ACTION: Re-run STEP 09 (Sensor VM Network & SPAN Interface Configuration)")
        warn_msgs+=("  → CHECK: Verify SPAN NIC PCI addresses in configuration")
      fi
    fi
  fi

  ###############################
  # Configuration files
  ###############################
  if [[ -f "${STATE_FILE}" ]]; then
    ok_msgs+=("State file (${STATE_FILE}) exists")
  else
    warn_msgs+=("State file (${STATE_FILE}) does not exist.")
    warn_msgs+=("  → NOTE: This is normal for first-time installation")
  fi

  if [[ -f "${CONFIG_FILE}" ]]; then
    ok_msgs+=("Configuration file (${CONFIG_FILE}) exists")
  else
    warn_msgs+=("Configuration file (${CONFIG_FILE}) does not exist.")
    warn_msgs+=("  → NOTE: This is normal for first-time installation")
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
  # All verification commands must execute actual commands regardless of DRY_RUN
  # Disable set -e during validation to prevent script exit on errors
  set +e

  local tmp_file="/tmp/xdr_sensor_validation_$(date '+%Y%m%d-%H%M%S').log"

  {
    echo "========================================"
    echo " XDR Sensor Installer - Full Configuration Verification"
    echo " Execution time: $(date '+%F %T')"
    echo
    echo " *** Press spacebar or down arrow key to see next page." 
    echo " *** Press q to exit this message."
    echo "========================================"
    echo

    ##################################################
    # 1. HWE kernel / IOMMU / GRUB Configuration Verification
    ##################################################
    echo "## 1. HWE kernel / IOMMU / GRUB Configuration Verification"
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
    # 2. Network Configuration Verification
    ##################################################
    echo "## 2. Network Configuration Verification"
    echo
    echo "\$ ip link show"
    ip link show 2>&1 || echo "[WARN] ip link show execution failed"
    echo

    echo "\$ ip addr show"
    ip addr show 2>&1 || echo "[WARN] ip addr show execution failed"
    echo

    ##################################################
    # 3. KVM / Libvirt Verification
    ##################################################
    echo "## 3. KVM / Libvirt Verification"
    echo

    echo "\$ lsmod | grep kvm"
    lsmod | grep kvm 2>&1 || echo "[WARN] kvm kernel module is not loaded."
    echo

    echo "\$ kvm-ok"
    if command -v kvm-ok >/dev/null 2>&1; then
      kvm-ok 2>&1 || echo "[WARN] kvm-ok check failed (KVM may not be available)."
    else
      echo "[INFO] kvm-ok command does not exist (cpu-checker package not installed)."
    fi
    echo

    echo "\$ systemctl status libvirtd --no-pager"
    systemctl status libvirtd --no-pager 2>&1 || echo "[WARN] libvirtd service status check failed"
    echo

    echo "\$ virsh net-list --all"
    virsh net-list --all 2>&1 || echo "[WARN] virsh net-list --all execution failed"
    echo

    ##################################################
    # 4. Sensor VM / storage Verification
    ##################################################
    echo "## 4. Sensor VM / storage Verification"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all execution failed"
    echo

    echo "\$ lvs"
    lvs 2>&1 || echo "[WARN] LVM information query failed"
    echo

    echo "\$ df -h /var/lib/libvirt/images/mds"
    df -h /var/lib/libvirt/images/mds 2>&1 || echo "[INFO] /var/lib/libvirt/images/mds mount point does not exist."
    echo

    echo "\$ ls -la /var/lib/libvirt/images/"
    ls -la /var/lib/libvirt/images/ 2>&1 || echo "[INFO] libvirt images directory does not exist."
    echo

    ##################################################
    # 5. System tuning Verification
    ##################################################
    echo "## 5. System tuning Verification"
    echo

    echo "\$ swapon --show"
    swapon --show 2>&1 || echo "[INFO] Swap is disabled."
    echo

    echo "\$ grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf"
    grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf 2>&1 || echo "[INFO] sysctl tuning configuration does not exist."
    echo

    ##################################################
    # 6. Configuration File Verification
    ##################################################
    echo "## 6. Configuration File Verification"
    echo

    echo "STATE_FILE: ${STATE_FILE}"
    if [[ -f "${STATE_FILE}" ]]; then
      echo "--- ${STATE_FILE} contents ---"
      cat "${STATE_FILE}" 2>&1 || echo "[WARN] Status file read failed"
    else
      echo "[INFO] Status file does not exist."
    fi
    echo

    echo "CONFIG_FILE: ${CONFIG_FILE}"
    if [[ -f "${CONFIG_FILE}" ]]; then
      echo "--- ${CONFIG_FILE} contents ---"
      cat "${CONFIG_FILE}" 2>&1 || echo "[WARN] Configuration file read failed"
    else
      echo "[INFO] Configuration file does not exist."
    fi
    echo

    echo "========================================"
    echo " Verification completed: $(date '+%F %T')"
    echo "========================================"

  } > "${tmp_file}" 2>&1

  # Re-enable set -e
  set -e

  # 1) Generate summary text
  local summary
  summary=$(build_validation_summary "${tmp_file}")

  # 2) Save summary to temporary file for scrollable textbox
  local summary_file="/tmp/xdr_sensor_validation_summary_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${summary}" > "${summary_file}"

  # 3) Show summary in scrollable textbox (so user can see all ERROR and WARN messages)
  show_textbox "Full Configuration Validation Summary" "${summary_file}"

  # 4) Ask if user wants to view detailed log
  local view_detail_msg
  view_detail_msg=$(center_message "Do you want to view the detailed validation log?\n\nThis will show all command outputs and detailed information.")
  
  if whiptail_yesno "View Detailed Log" "${view_detail_msg}"; then
    # 5) Show full validation log in detail using less
    show_paged "Full Configuration Validation Results (Detailed Log)" "${tmp_file}" "no-clear"
  fi

  # Clean up temporary files
  rm -f "${summary_file}"
  rm -f "${tmp_file}"
}

#######################################
# script use inside
#######################################

show_usage_help() {
  local msg
  msg=$'═══════════════════════════════════════════════════════════════
        ⭐ Stellar Cyber XDR Sensor – KVM Installer Usage Guide ⭐
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

• For detailed documentation and additional information:
  - Visit: https://kvm.xdr.ooo/
  - Comprehensive guides, troubleshooting, and advanced configuration


═══════════════════════════════════════════════════════════════
📋 **Main Menu Options Overview**
═══════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────┐
│ 1. Auto Execute All Steps                                    │
│    → Automatically runs all steps from the next incomplete   │
│    → Resumes from last completed step after reboot            │
│    → Best for: Initial installation or continuing after      │
│      reboot                                                  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 2. Select and Run Specific Step Only                         │
│    → Run individual steps independently                      │
│    → Best for: Sensor VM redeployment, network changes,     │
│      or image updates                                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 3. Configuration                                             │
│    → Configure installation parameters:                      │
│      • DRY_RUN: Simulation mode (default: 1)                 │
│      • SENSOR_VERSION: Sensor version to install             │
│      • SENSOR_NET_MODE: bridge or nat (default: nat)         │
│      • SPAN_ATTACH_MODE: pci or bridge (default: pci)       │
│      • ACPS credentials (username, password, URL)           │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 4. Full Configuration Validation                            │
│    → Comprehensive system validation                         │
│    → Checks: KVM, Sensor VM, network, SPAN, storage         │
│    → Displays errors and warnings with detailed logs         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 5. Script Usage Guide                                        │
│    → Displays this help guide                                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 6. View Log                                                   │
│    → View installation log file                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 7. Exit                                                       │
│    → Exit the installer                                       │
└─────────────────────────────────────────────────────────────┘


═══════════════════════════════════════════════════════════════
🔰 **Scenario 1: Fresh Installation (Ubuntu 24.04)**
═══════════════════════════════════════════════════════════════

Step-by-Step Process:
────────────────────────────────────────────────────────────
1. Initial Setup:
   • Configure menu 3: Set DRY_RUN=0, SENSOR_VERSION, network mode,
     SPAN attachment mode, ACPS credentials
   • Select menu 1 to start automatic installation

2. Installation Flow:
   STEP 01 → Hardware/NIC/CPU/Memory/SPAN NIC selection
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
   STEP 06 → Libvirt hooks installation
   STEP 07 → Sensor LV creation + image/script download
   STEP 08 → Sensor VM (mds) deployment
   STEP 09 → Sensor VM Network & SPAN Interface Configuration
            → Network interfaces (virbr0/br-data), SPAN PCI passthrough/bridge
   STEP 10 → DP Appliance CLI installation

7. Verification:
   • Select menu 4 to validate complete installation


═══════════════════════════════════════════════════════════════
🔧 **Scenario 2: Partial Installation or Reconfiguration**
═══════════════════════════════════════════════════════════════

When to Use:
────────────────────────────────────────────────────────────
• Some steps already completed
• Need to update specific components
• Changing configuration (NIC, network mode, SPAN mode)

Process:
────────────────────────────────────────────────────────────
1. Review current state:
   • Main menu shows last completed step
   • Check menu 4 (validation) for current status

2. Configure if needed:
   • Menu 3: Update DRY_RUN, SENSOR_VERSION, network mode,
     SPAN attachment mode, or ACPS credentials

3. Continue or re-run:
   • Menu 1: Auto-continue from next incomplete step
   • Menu 2: Run specific steps that need updating


═══════════════════════════════════════════════════════════════
🧩 **Scenario 3: Specific Operations**
═══════════════════════════════════════════════════════════════

Common Use Cases:
────────────────────────────────────────────────────────────
• Sensor VM Redeployment:
  → Menu 2 → STEP 08 (Sensor VM deployment) → STEP 09 (Network interface configuration)
  → VM resources (vCPU, memory) are automatically calculated

• Update Sensor Image:
  → Menu 2 → STEP 07 (Sensor LV + image download)
  → New image will be downloaded and deployed

• Network Configuration Change:
  → Menu 2 → STEP 01 (Hardware selection) → STEP 03 (Network)
  → Network mode changes require re-running from STEP 01

• SPAN NIC Reconfiguration:
  → Menu 3 → Update SPAN_ATTACH_MODE (if changing attachment mode)
  → Menu 2 → STEP 01 (SPAN NIC selection) → STEP 03 (SPAN bridge creation if bridge mode) → STEP 09 (Network interface configuration)
  → Reason: SPAN attachment mode affects PCI detection, bridge creation, and XML interface setup

• Change SPAN Interfaces (within same attachment mode):
  → PCI Mode - SPAN_NICS change:
    Menu 2 → STEP 01 (SPAN NIC selection, PCI detection) → STEP 03 (udev rules) → STEP 09 (XML PCI hostdev update)
  → Bridge Mode - SPAN_NICS change:
    Menu 2 → STEP 01 (SPAN NIC selection) → STEP 03 (SPAN bridge creation) → STEP 09 (XML bridge interface update)

• Change Network Mode (bridge/nat):
  → Menu 3 → Update SENSOR_NET_MODE
  → Menu 2 → STEP 01 → STEP 03 → STEP 04 → STEP 08 → STEP 09
  → Reason: Network mode affects NIC selection, network config, libvirt network, VM deployment, and XML interface setup

• Change Network Interface or IP (within same mode):
  → Bridge Mode - HOST_NIC/DATA_NIC change:
    Menu 2 → STEP 01 (NIC selection) → STEP 03 (udev rules, network config)
  → Bridge Mode - HOST_NIC IP change:
    Menu 2 → STEP 03 (network interfaces IP configuration)
  → NAT Mode - HOST_NIC (mgt) change:
    Menu 2 → STEP 01 (NIC selection) → STEP 03 (udev rules, network config)
  → NAT Mode - HOST_NIC (mgt) IP change:
    Menu 2 → STEP 03 (network interfaces IP configuration)


═══════════════════════════════════════════════════════════════
🔍 **Scenario 4: Validation and Troubleshooting**
═══════════════════════════════════════════════════════════════

Full System Validation:
────────────────────────────────────────────────────────────
• Select menu 4 (Full Configuration Validation)

Validation Checks:
────────────────────────────────────────────────────────────
✓ KVM/Libvirt installation and service status
✓ Sensor VM (mds) deployment and running status
✓ Network configuration (ifupdown conversion, NIC naming)
✓ SPAN PCI Passthrough connection status
✓ LVM storage configuration (ubuntu-vg)
✓ Service status (libvirtd)

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
• Network: Netplan will be disabled and switched to ifupdown
           during installation (STEP 03)

Server Specifications (Physical Server Recommended):
────────────────────────────────────────────────────────────
• CPU:
  - 12 vCPU or more
  - Automatically calculated based on total system cores

• Memory:
  - 16GB or more
  - Automatically calculated based on total system memory
  - Sensor VM resources are auto-calculated from available resources

• Disk:
  - Use ubuntu-vg volume group for OS and Sensor
  - Minimum free space: 100GB minimum
  - Sensor LV is created automatically in STEP 07

• Network Interfaces:
  - Management (Host/MGT): 1GbE or more (for SSH access)
  - SPAN (Data): For receiving mirroring traffic
    • PCI Passthrough mode recommended for best performance
    • Bridge mode available as alternative

BIOS Settings (Required):
────────────────────────────────────────────────────────────
• Intel VT-d / AMD-Vi (IOMMU) → Enabled (required for PCI passthrough)
• Virtualization Technology (VMX/SVM) → Enabled


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

Network Mode Selection:
────────────────────────────────────────────────────────────
• SENSOR_NET_MODE: bridge or nat (default: nat)
  - Bridge: L2 bridge based (br-data bridge for data traffic)
  - NAT: virbr0 NAT network based (DHCP disabled, uses static IP 192.168.122.2)
• Mode change requires: STEP 01 → STEP 03 → STEP 04 → STEP 08 → STEP 09
  - STEP 01: NIC selection differs (HOST_NIC/DATA_NIC vs NAT uplink NIC)
  - STEP 03: Network configuration (br-data vs NAT setup)
  - STEP 04: Libvirt network (default network removal vs virbr0 creation)
  - STEP 08: VM deployment parameters
  - STEP 09: XML interface configuration (br-data vs virbr0)
• Interface/IP change (same mode):
  - Bridge Mode: HOST_NIC/DATA_NIC change → STEP 01 → STEP 03
  - Bridge Mode: HOST_NIC IP change → STEP 03
  - NAT Mode: HOST_NIC (mgt) change → STEP 01 → STEP 03
  - NAT Mode: HOST_NIC (mgt) IP change → STEP 03

SPAN Attachment Mode:
────────────────────────────────────────────────────────────
• SPAN_ATTACH_MODE: pci (default, recommended) or bridge
  - PCI: Direct PCI passthrough (best performance)
  - Bridge: L2 bridge virtio NIC
• PCI mode requires IOMMU enabled in BIOS
• Mode change requires: STEP 01 → STEP 03 → STEP 09
  - STEP 01: SPAN NIC PCI address detection (pci mode) or bridge mode setup
  - STEP 03: SPAN bridge creation (bridge mode only)
  - STEP 09: XML interface configuration (PCI hostdev vs bridge interface)
• Interface change (same mode):
  - PCI Mode: SPAN_NICS change → STEP 01 → STEP 03 → STEP 09
  - Bridge Mode: SPAN_NICS change → STEP 01 → STEP 03 → STEP 09

Disk Space Management:
────────────────────────────────────────────────────────────
• Monitor disk space: df -h, vgs, lvs
• Sensor LV is created in ubuntu-vg volume group
• Ensure sufficient space in ubuntu-vg before STEP 07

Network Configuration:
────────────────────────────────────────────────────────────
• Netplan is disabled and replaced with ifupdown in STEP 03
• Network changes take effect after STEP 03 reboot
• Verify with: ip addr show, virsh net-list

Log Files:
────────────────────────────────────────────────────────────
• Main log: /var/log/xdr-installer.log
• View logs: Menu 6 (View Log)
• Step logs: Displayed during each step execution
• Validation logs: Available in menu 4 detailed view


═══════════════════════════════════════════════════════════════
💡 **Tips for Success**
═══════════════════════════════════════════════════════════════

• Always start with DRY_RUN=1 to preview changes
• Review validation results (menu 4) before final deployment
• Choose appropriate network mode (bridge/nat) based on your network
• PCI passthrough for SPAN provides best performance
• Ensure IOMMU is enabled in BIOS for PCI passthrough
• Monitor disk space in ubuntu-vg throughout installation
• Save configuration after menu 3 changes
• VM resources are auto-calculated - no manual configuration needed

═══════════════════════════════════════════════════════════════
📚 **Additional Resources**
═══════════════════════════════════════════════════════════════

For comprehensive documentation, detailed guides, troubleshooting, and
advanced configuration options, please visit:

  🌐 https://kvm.xdr.ooo/

The documentation site includes:
• Step-by-step installation guides
• Network configuration examples
• Troubleshooting procedures
• Advanced configuration scenarios
• Best practices and recommendations

═══════════════════════════════════════════════════════════════'

  # Save content to temporary file and display with show_textbox
  local tmp_help_file="/tmp/xdr_sensor_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR Sensor Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}

# in Execution
main_menu