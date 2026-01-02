#!/usr/bin/env bash
#
# XDR Sensor Install Framework (SSH + Whiptail based TUI)
# Version: 0.1 (sensor-specific)
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
  "libvirt hooks Installation"
  "Sensor LV Creation + Image/Script Download"
  "Sensor VM Deployment"
  "PCI Passthrough / CPU Affinity (Sensor)"
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
  local dialog_height=$((HEIGHT - 4))
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
  local title file tmpfile

  # ANSI color definitions
  local RED="\033[1;31m"
  local GREEN="\033[1;32m"
  local BLUE="\033[1;34m"
  local CYAN="\033[1;36m"
  local YELLOW="\033[1;33m"
  local RESET="\033[0m"

  # --- Argument processing (safe for set -u environment) ---
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
  else
    echo "show_paged: no content provided" >&2
    return 1
  fi

  clear
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

append_fstab_if_missing() {
  local line="$1"
  local mount_point="$2"

  if grep -qE"[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
    log "fstab: ${mount_point} entry already exists. (Skipping addition)"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Adding the following line to /etc/fstab: ${line}"
  else
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
  : "${SPAN_NICS:=}"
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"
  : "${SPAN_ATTACH_MODE:=pci}"
  : "${SPAN_NIC_LIST:=}"
  : "${SPAN_BRIDGE_LIST:=}"
  : "${SENSOR_NET_MODE:=bridge}"
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
  local esc_host_nic esc_data_nic esc_span_nics esc_sensor_vcpus esc_sensor_memory_mb esc_sensor_passthrough_pcis
  local esc_span_attach_mode esc_span_nic_list esc_span_bridge_list esc_sensor_net_mode esc_lv_location esc_lv_size_gb
  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_data_nic=${DATA_NIC//\"/\\\"}
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

  # Confirm STEP execution
  if ! whiptail_yesno "XDR Installer - ${step_id}" "${step_name}\n\nDo you want to execute this step?"
  then
    # User cancellation is considered "normal flow" (not an error)
    log "User canceled execution of STEP ${step_id}."
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

	          whiptail --title "Auto Reboot" \
	                   --msgbox "STEP ${step_id} (${step_name}) has been completed successfully.\n\nThe system will automatically reboot." 12 70

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
	    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    
    # Provide log file location on failure
    local log_info=""
    if [[ -f "${LOG_FILE}" ]]; then
      log_info="\n\nCheck the detailed log: tail -f ${LOG_FILE}"
    fi
    
    whiptail --title "STEP Failed - ${step_id}" \
             --msgbox "An error occurred while executing STEP ${step_id} (${step_name}).\n\nPlease check the log and re-run the STEP if necessary.\nThe installer can continue to run.${log_info}" 16 80
  fi

  # ★ run_step always returns 0 so set -e doesn't trigger here
  return 0
  }


#######################################
# Hardware Detection Utilities
#######################################

list_nic_candidates() {
  # Exclude lo, virbr*, vnet*, tap*, docker*, br*, ovs, etc.
  ip -o link show | awk -F': ' '{print $2}' \
    | grep -Ev '^(lo|virbr|vnet|tap|docker|br-|ovs)' \
    || true
}

#######################################
# Implementation for Each STEP
#######################################

step_01_hw_detect() {
  log "[STEP 01] Hardware / NIC / CPU / Memory / SPAN NIC Selection"

  # Load latest configuration (prevent script failure if not available)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set default values to prevent set -u (empty string if not defined)
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"
  : "${SPAN_NICS:=}"
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"
  : "${SPAN_ATTACH_MODE:=pci}"
  : "${SENSOR_NET_MODE:=bridge}"
  
  # Determine network mode
  local net_mode="${SENSOR_NET_MODE}"
  log "[STEP 01] Sensor network mode: ${net_mode}"

  ########################
  # 0) Whether to reuse existing values (different conditions per network mode)
  ########################
  local can_reuse_config=0
  local reuse_message=""
  
  # Load storage configuration values
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"
  
  if [[ "${net_mode}" == "bridge" ]]; then
    if [[ -n "${HOST_NIC}" && -n "${DATA_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_VCPUS}" && -n "${SENSOR_MEMORY_MB}" && -n "${SENSOR_SPAN_VF_PCIS}" && -n "${LV_LOCATION}" && -n "${LV_SIZE_GB}" ]]; then
      can_reuse_config=1
      local span_mode_label="PF PCI (Passthrough)"
      [[ "${SPAN_ATTACH_MODE}" == "bridge" ]] && span_mode_label="Bridge (virtio)"
      reuse_message="The following values are already configured:\n\n- Network mode: ${net_mode}\n- HOST NIC: ${HOST_NIC}\n- DATA NIC: ${DATA_NIC}\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: ${SPAN_ATTACH_MODE}\n- SPAN ${span_mode_label}: ${SENSOR_SPAN_VF_PCIS}\n- SENSOR vCPU: ${SENSOR_VCPUS}\n- SENSOR Memory: ${SENSOR_MEMORY_MB}MB\n- LV Location: ${LV_LOCATION}\n- LV Size: ${LV_SIZE_GB}GB"
    fi
  elif [[ "${net_mode}" == "nat" ]]; then
    if [[ -n "${HOST_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_VCPUS}" && -n "${SENSOR_MEMORY_MB}" && -n "${SENSOR_SPAN_VF_PCIS}" && -n "${LV_LOCATION}" && -n "${LV_SIZE_GB}" ]]; then
      can_reuse_config=1
      local span_mode_label="PF PCI (Passthrough)"
      [[ "${SPAN_ATTACH_MODE}" == "bridge" ]] && span_mode_label="Bridge (virtio)"
      reuse_message="The following values are already configured:\n\n- Network mode: ${net_mode}\n- NAT uplink NIC: ${HOST_NIC}\n- DATA NIC: N/A (NAT mode)\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: ${SPAN_ATTACH_MODE}\n- SPAN ${span_mode_label}: ${SENSOR_SPAN_VF_PCIS}\n- SENSOR vCPU: ${SENSOR_VCPUS}\n- SENSOR Memory: ${SENSOR_MEMORY_MB}MB\n- LV Location: ${LV_LOCATION}\n- LV Size: ${LV_SIZE_GB}GB"
    fi
  fi
  
  if [[ "${can_reuse_config}" -eq 1 ]]; then
    if whiptail --title "STEP 01 - Reuse Existing Selection" \
                --yesno "${reuse_message}\n\nDo you want to reuse these values and skip STEP 01?\n\n(Select No to choose again.)" 20 80
    then
      log "User chose to reuse existing STEP 01 selection values. (Skipping STEP 01)"

      # Ensure configuration file is updated even when reusing
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "DATA_NIC"       "${DATA_NIC}"
      save_config_var "SPAN_NICS"     "${SPAN_NICS}"
      save_config_var "SENSOR_VCPUS"  "${SENSOR_VCPUS}"
      save_config_var "SENSOR_MEMORY_MB" "${SENSOR_MEMORY_MB}"
      save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
      save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
      save_config_var "LV_LOCATION" "${LV_LOCATION}"
      save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

      # Reuse means 'success + nothing more to do in this step', so return 0 normally
      return 0
    fi
  fi

  ########################
  # 1) CPU Calculation
  ########################
  local total_cpus default_sensor_cpus sensor_vcpus
  total_cpus=$(nproc)
  default_sensor_cpus=$((total_cpus - 4))
  
  if [[ ${default_sensor_cpus} -le 0 ]]; then
    default_sensor_cpus=1
  fi
  
  sensor_vcpus=$(whiptail --title "STEP 01 - Sensor vCPU Configuration" \
                          --inputbox "Enter the number of vCPUs to allocate to the sensor VM.\n\nTotal logical CPUs: ${total_cpus}\nDefault: ${default_sensor_cpus}" \
                          12 70 "${default_sensor_cpus}" \
                          3>&1 1>&2 2>&3) || {
    log "User canceled sensor vCPU configuration."
    return 1
  }

  log "Configured sensor vCPU: ${sensor_vcpus}"
  SENSOR_VCPUS="${sensor_vcpus}"
  save_config_var "SENSOR_VCPUS" "${SENSOR_VCPUS}"

  ########################
  # 2) Memory Calculation
  ########################
  local total_mem_kb total_mem_gb default_sensor_gb sensor_gb sensor_memory_mb
  total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  total_mem_gb=$((total_mem_kb / 1024 / 1024))
  default_sensor_gb=$((total_mem_gb - 12))
  
  if [[ ${default_sensor_gb} -le 0 ]]; then
    whiptail --title "Memory Insufficient Warning" \
             --msgbox "System memory is insufficient.\nTotal memory: ${total_mem_gb}GB\nDefault allocation value is 0 or less.\n\nPlease enter an appropriate memory size in the next screen." 12 70
    default_sensor_gb=4  # Suggest 4GB as default
  fi
  
  sensor_gb=$(whiptail --title "STEP 01 - Sensor Memory Configuration" \
                       --inputbox "Enter the memory (GB) to allocate to the sensor VM.\n\nTotal memory: ${total_mem_gb}GB\nRecommended: ${default_sensor_gb}GB" \
                       12 70 "${default_sensor_gb}" \
                       3>&1 1>&2 2>&3) || {
    log "User canceled sensor memory configuration."
    return 1
  }

  sensor_memory_mb=$((sensor_gb * 1024))
  log "Configured sensor memory: ${sensor_gb}GB (${sensor_memory_mb}MB)"
  SENSOR_MEMORY_MB="${sensor_memory_mb}"
  save_config_var "SENSOR_MEMORY_MB" "${SENSOR_MEMORY_MB}"

  ########################
  # 3) Storage Allocation Configuration
  ########################
  # Check and display sda3 disk information
  log "[STEP 01] Checking sda3 disk information"

  # Check ubuntu-vg total size (OpenXDR method) - Modified: fixed unit
  local ubuntu_vg_total_size
  # Extract only GB unit numbers using --units g --nosuffix option (may include decimals)
  ubuntu_vg_total_size=$(vgs ubuntu-vg --noheadings --units g --nosuffix -o size 2>/dev/null | tr -d ' ' || echo "0")

  # Check ubuntu-lv used size - Modified: fixed unit
  local ubuntu_lv_size ubuntu_lv_gb=0
  if command -v lvs >/dev/null 2>&1; then
    # Extract only GB unit numbers using --units g --nosuffix option
    ubuntu_lv_size=$(lvs ubuntu-vg/ubuntu-lv --noheadings --units g --nosuffix -o lv_size 2>/dev/null | tr -d ' ' || echo "0")
    # Remove decimal point (integer conversion) -> Example: 100.50 -> 100
    ubuntu_lv_gb=${ubuntu_lv_size%.*}
  else
    ubuntu_lv_size="Unable to check"
  fi

  # Convert ubuntu-vg total size to integer (remove decimal point) -> Example: 1781.xx -> 1781
  local ubuntu_vg_total_gb=${ubuntu_vg_total_size%.*}
  
  # Calculate available space
  local available_gb=$((ubuntu_vg_total_gb - ubuntu_lv_gb))
  [[ ${available_gb} -lt 0 ]] && available_gb=0
  
  # Configure LV location to ubuntu-vg (OpenXDR method)
  local lv_location="ubuntu-vg"
  log "[STEP 01] Auto-configuring LV location: ${lv_location} (Using existing ubuntu-vg free space)"
  
  # Get LV size input from user
  local lv_size_gb
  while true; do
    lv_size_gb=$(whiptail --title "STEP 01 - Sensor Storage Size Configuration" \
                         --inputbox "Enter sensor VM storage size (GB):\n\nubuntu-vg Total Size: ${ubuntu_vg_total_size}\nSystem use: ${ubuntu_lv_size}\nAvailable: approximately ${available_gb}GB\n\nInstallation Location: ubuntu-vg (OpenXDR Method)\nMinimum Size: 80GB\nDefault: 500GB\n\nSize (GB):" \
                         16 65 "100" \
                         3>&1 1>&2 2>&3) || {
      log "User canceled sensor storage size configuration."
      return 1
    }
      
      # numeric format Verification
      if ! [[ "${lv_size_gb}" =~ ^[0-9]+$ ]]; then
        whiptail_msgbox "Input Error" "Please enter a valid number.\nInput value: ${lv_size_gb}"
        continue
      fi
      
      # Minimum Size Verification (80GB)
      if [[ "${lv_size_gb}" -lt 80 ]]; then
        whiptail_msgbox "Size Insufficient" "Minimum size must be at least 80GB.\nInput value: ${lv_size_gb}GB"
        continue
      fi
      
      # If valid, exit loop
      break
    done
    
    log "Configured LV Location: ${lv_location}"
    log "Configured LV Size: ${lv_size_gb}GB"
    
    # Configuration store
    LV_LOCATION="${lv_location}"
    LV_SIZE_GB="${lv_size_gb}"
    save_config_var "LV_LOCATION" "${LV_LOCATION}"
    save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

  ########################
  # 4) NIC candidate  and Selection
  ########################
  local nics nic_list nic name idx

  # list_nic_candidates  Failed set -e  script All prevent death defense
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail --title "STEP 01 - NIC Detection Failed" \
             --msgbox "No available NICs could be found.\n\nPlease check 'ip link' output and modify the script if needed." 12 70
    log "No NIC candidates found. Please check 'ip link' output."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # Each NIC assigned IP Information + ethtool Speed/Duplex display
    local ipinfo speed duplex et_out

    # IP Information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Default
    speed="Unknown"
    duplex="Unknown"

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
    nic_list+=("${name}" "speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
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
    host_nic=$(whiptail --title "STEP 01 - HOST NIC Selection (Bridge Mode)" \
                       --menu "Please select NIC for host access (current SSH connection).\nCurrent Configuration: ${HOST_NIC:-<None>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User canceled HOST NIC selection."
      return 1
    }

    log "Selected HOST NIC: ${host_nic}"
    HOST_NIC="${host_nic}"
    save_config_var "HOST_NIC" "${HOST_NIC}"

    # DATA NIC Selection  
    local data_nic
    data_nic=$(whiptail --title "STEP 01 - Data NIC Selection (Bridge Mode)" \
                       --menu "Please select management/data NIC for Sensor VM.\nCurrent Configuration: ${DATA_NIC:-<None>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User canceled Data NIC selection."
      return 1
    }

    log "Selected Data NIC: ${data_nic}"
    DATA_NIC="${data_nic}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: NAT uplink NIC (1 unit only) Selection
    log "[STEP 01] NAT Mode - Selecting NAT uplink NIC (1 unit only)."
    
    local nat_nic
    nat_nic=$(whiptail --title "STEP 01 - NAT uplink NIC Selection (NAT Mode)" \
                      --menu "Please select NAT Network uplink NIC.\nThis NIC will be renamed to 'mgt' for external connection.\nSensor VM will be connected to virbr0 NAT bridge.\nCurrent Configuration: ${HOST_NIC:-<None>}" \
                      20 90 10 \
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
    
  else
    log "ERROR: Unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail_msgbox "Configuration Error" "Unknown sensor network mode: ${net_mode}\n\nPlease select a valid mode (bridge or nat) in environment configuration."
    return 1
  fi

  ########################
  # 5) SPAN NIC Selection (can Selection)
  ########################
  local span_nic_list=()
  while IFS= read -r name; do
    # Each NIC assigned IP Information + ethtool Speed/Duplex display
    local ipinfo speed duplex et_out

    # IP Information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Default
    speed="Unknown"
    duplex="Unknown"

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
    span_nic_list+=("${name}" "speed=${speed}, duplex=${duplex}, ip=${ipinfo}" "${flag}")
  done <<< "${nics}"

  local selected_span_nics
  selected_span_nics=$(whiptail --title "STEP 01 - SPAN NIC Selection" \
                                --checklist "Please select NIC(s) for Sensor SPAN.\n(Minimum 1 NIC selection required)\n\nCurrent Selection: ${SPAN_NICS:-<None>}" \
                                20 80 10 \
                                "${span_nic_list[@]}" \
                                3>&1 1>&2 2>&3) || {
    log "User canceled SPAN NIC selection."
    return 1
  }

  # Remove quotes from whiptail output (e.g., "nic1" "nic2" -> nic1 nic2)
  selected_span_nics=$(echo "${selected_span_nics}" | tr -d '"')

  if [[ -z "${selected_span_nics}" ]]; then
    whiptail --title "SPAN NIC Selection Required" \
             --msgbox "No SPAN NICs selected.\nAt least 1 SPAN NIC is required." 10 70
    log "SPAN NIC selection is required but none selected."
    return 1
  fi

  log "Selected SPAN NICs: ${selected_span_nics}"
  SPAN_NICS="${selected_span_nics}"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  ########################
  # 6) SPAN NIC PF PCI address detection (PCI passthrough mode)
  ########################
  log "[STEP 01] SR-IOV based VF creation not used (PF PCI passthrough mode)."
  log "[STEP 01] Detecting SPAN NIC PCI addresses (PF)."

  local span_pci_list=""

  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    # PCI passthrough mode: Use Physical Function (PF) PCI address
    for nic in ${SPAN_NICS}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')

      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address could not be found."
        continue
      fi

      span_pci_list="${span_pci_list} ${pci_addr}"
      log "[STEP 01] ${nic} (SPAN NIC) -> Physical PCI: ${pci_addr}"
    done

  else
    # Bridge Modeis PCI passthrough Required
    log "[STEP 01] Bridge Mode - PCI passthrough Required"
  fi

  # SPAN connection Mode PCI passthrough  
  SPAN_ATTACH_MODE="pci"

  # NOTE: VF name is not used (only PF PCI address)
  # Currently storing SPAN NIC PF PCI addresses (not VF)
  # Store PCI addresses
  SENSOR_SPAN_VF_PCIS="${span_pci_list# }"  # Remove leading space
  save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
  log "SPAN NIC PCI addresses stored: ${SENSOR_SPAN_VF_PCIS}"
  
  # Store SPAN NIC list and connection mode
  SPAN_NIC_LIST="${SPAN_NICS}"  # Use SPAN_NICS value
  save_config_var "SPAN_NIC_LIST" "${SPAN_NIC_LIST}"
  save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
  log "SPAN NIC list stored: ${SPAN_NIC_LIST}"
  log "SPAN connection mode: ${SPAN_ATTACH_MODE} (pci=PF PCI passthrough)"

  ########################
  # 7) Summary display (varies by network mode)
  ########################
  local summary
  local pci_label="SPAN NIC PCIs (PF Passthrough)"
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    pci_label="SPAN interfaces (Bridge)"
  fi

  if [[ "${net_mode}" == "bridge" ]]; then
    summary=$(cat <<EOF
[STEP 01 Result Summary - Bridge Mode]

- Sensor Network Mode : ${net_mode}
- Sensor vCPU        : ${SENSOR_VCPUS}
- Sensor Memory       : ${sensor_gb}GB (${SENSOR_MEMORY_MB}MB)
- LV Location          : ${LV_LOCATION}
- LV Size          : ${LV_SIZE_GB}GB
- Host NIC         : ${HOST_NIC}
- Data NIC         : ${DATA_NIC}
- SPAN NICs       : ${SPAN_NICS}
- SPAN connection Mode    : ${SPAN_ATTACH_MODE}
- ${pci_label}     : ${SENSOR_SPAN_VF_PCIS}

Configuration File: ${CONFIG_FILE}
EOF
)
  elif [[ "${net_mode}" == "nat" ]]; then
    summary=$(cat <<EOF
[STEP 01 Result Summary - NAT Mode]

- Sensor Network Mode : ${net_mode}
- Sensor vCPU        : ${SENSOR_VCPUS}
- Sensor Memory       : ${sensor_gb}GB (${SENSOR_MEMORY_MB}MB)
- LV Location          : ${LV_LOCATION}
- LV Size          : ${LV_SIZE_GB}GB
- NAT uplink NIC     : ${HOST_NIC}
- Data NIC         : N/A (NAT Mode - using virbr0)
- SPAN NICs       : ${SPAN_NICS}
- SPAN connection Mode    : ${SPAN_ATTACH_MODE}
- ${pci_label}     : ${SENSOR_SPAN_VF_PCIS}

Configuration File: ${CONFIG_FILE}
EOF
)
  else
    summary="[STEP 01 Result Summary]

unknown Network Mode: ${net_mode}
"
  fi

  whiptail --title "STEP 01 Completed" \
           --msgbox "${summary}" 18 80

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
  local cur_kernel hwe_installed
  cur_kernel=$(uname -r 2>/dev/null || echo "unknown")
  if dpkg -l | grep -q "^ii  ${pkg_name}[[:space:]]"; then
    hwe_installed="yes"
  else
    hwe_installed="no"
  fi

  {
    echo "Current kernel (uname -r): ${cur_kernel}"
    echo
    echo "${pkg_name} installation status: ${hwe_installed}"
    echo
    echo " Next steps to be executed:"
    echo "  1) apt update"
    echo "  2) apt full-upgrade -y"
    echo "  3) ${pkg_name} Installation (skip if already installed)"
    echo
    echo "HWE kernel will be applied after next reboot."
    echo "After STEP 05 (kernel tuning) completes,"
    echo "Auto Reboot is configured only after STEP 05 (kernel tuning) completes."
  } > "${tmp_status}"


  # ... cur_kernel, hwe_installed  after, unit textbox   add ...

  if [[ "${hwe_installed}" == "yes" ]]; then
    if ! whiptail --title "STEP 02 - HWE Kernel Already Installed" \
                  --yesno "linux-generic-hwe-24.04 package is already installed.\n\nDo you want to skip this STEP?" 18 80
    then
      log "User chose to skip STEP 02 (already installed)."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE kernel Installation unit" "${tmp_status}"

  if ! whiptail --title "STEP 02 Execution Confirmation" \
                 --yesno "Do you want to proceed?\n\n(Yes: Continue / No: Cancel)" 12 70
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
  local new_kernel hwe_now
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # DRY-RUN Mode - Use existing uname -r and installation status
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
  else
    # Check current kernel and HWE package installation status
    new_kernel=$(uname -r 2>/dev/null || echo "unknown")
    if dpkg -l | grep -q "^ii  ${pkg_name}[[:space:]]"; then
      hwe_now="yes"
    else
      hwe_now="no"
    fi
  fi

  {
    echo "STEP 02 execution summary"
    echo "----------------------"
    echo "Previous kernel(uname -r): ${cur_kernel}"
    echo "Current kernel(uname -r): ${new_kernel}"
    echo
    echo "${pkg_name} installation status: ${hwe_now}"
    echo
    echo "*  HWE kernel will be applied after next reboot."
    echo "   (uname -r output may not change until after reboot.)"
    echo
    echo "*  After STEP 05 (kernel tuning) completes,"
    echo "   AUTO_REBOOT_AFTER_STEP_ID configuration: Auto reboot will be performed after STEP completes."
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
step_03_bridge_mode() {
  log "[STEP 03 Bridge Mode] Configuring L2 bridge based network"

  # Check if HOST_NIC and DATA_NIC are configured
  if [[ -z "${HOST_NIC:-}" || -z "${DATA_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NIC Not Configured" \
             --msgbox "HOST_NIC or DATA_NIC is not configured.\n\nPlease select NICs in STEP 01." 12 70
    log "HOST_NIC or DATA_NIC not configured. Cannot proceed with STEP 03 Bridge Mode."
    return 1
  fi

  #######################################
  # 0) Current SPAN NIC/PCI Information Check (SR-IOV Apply )
  #######################################
  local tmp_pci="${STATE_DIR}/xdr_step03_pci.txt"
  {
    echo "Selected SPAN NIC and PCI Information (SR-IOV Apply)"
    echo "--------------------------------------------"
    echo "HOST_NIC  : ${HOST_NIC} (SR-IOV not applied)"
    echo "DATA_NIC  : ${DATA_NIC} (SR-IOV not applied)"
    echo
    echo "SPAN NICs (SR-IOV Apply ):"
    
    if [[ -z "${SPAN_NICS:-}" ]]; then
      echo "  Warning: SPAN_NICS is not configured."
      echo "   Please select SPAN NICs in STEP 01."
    else
      local span_error=0
      for span_nic in ${SPAN_NICS}; do
        local span_pci
        span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
        if [[ -n "${span_pci}" ]]; then
          echo "  ${span_nic}  -> PCI: ${span_pci}"
        else
          echo "  ${span_nic}  -> PCI: Information None (Error)"
          span_error=1
        fi
      done
      
      if [[ ${span_error} -eq 1 ]]; then
        echo
        echo "* Some SPAN NIC PCI information is missing."
        echo "   Please check and select correct NICs in STEP 01."
      fi
    fi
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NIC/PCI Check" "${tmp_pci}"
  
  #######################################
  # Check if network configuration already exists
  #######################################
  local maybe_done=0
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local iface_file="/etc/network/interfaces"

  # HOST/DATA NIC default Configuration Check
  if [[ -f "${udev_file}" ]] && \
     grep -q "NAME:=\"host\"" "${udev_file}" 2>/dev/null && \
     grep -q "NAME:=\"data\"" "${udev_file}" 2>/dev/null; then
    if [[ -f "${iface_file}" ]] && \
       grep -q "^auto host" "${iface_file}" 2>/dev/null && \
       grep -q "iface host inet static" "${iface_file}" 2>/dev/null && \
       grep -q "^auto br-data" "${iface_file}" 2>/dev/null; then
      maybe_done=1
    fi
  fi

  if [[ "${maybe_done}" -eq 1 ]]; then
    if whiptail --title "STEP 03 - Already Configured  " \
                --yesno "udev rule and /etc/network/interfaces are already configured.\n\nDo you want to skip this STEP?" 18 80
    then
      log "User chose to skip STEP 03 (already configured)."
      return 0
    fi
    log "User canceled STEP 03 execution."
  fi

  #######################################
  # 1) HOST IP Configuration (Default: Current Configuration)
  #######################################
  local cur_cidr cur_ip cur_prefix cur_gw cur_dns
  cur_cidr=$(ip -4 -o addr show dev "${HOST_NIC}" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -n "${cur_cidr}" ]]; then
    cur_ip="${cur_cidr%/*}"
    cur_prefix="${cur_cidr#*/}"
  else
    cur_ip=""
    cur_prefix="24"
  fi
  cur_gw=$(ip route show default 0.0.0.0/0 dev "${HOST_NIC}" 2>/dev/null | awk '{print $3}' | head -n1)
  if [[ -z "${cur_gw}" ]]; then
    cur_gw=$(ip route show default 0.0.0.0/0 | awk '{print $3}' | head -n1)
  fi
  # DNS Default
  cur_dns="8.8.8.8 8.8.4.4"

  # IP address
  local new_ip
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    new_ip="${cur_ip}"
    log "[DRY-RUN] HOST IP Configuration: ${new_ip} (Default use)"
  else
    new_ip=$(whiptail --title "STEP 03 - HOST IP Configuration" \
                      --inputbox "Enter HOST interface IP address:\nExample: 10.4.0.210" \
                      10 60 "${cur_ip}" \
                      3>&1 1>&2 2>&3) || return 0
  fi

  # s
  local new_prefix
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    new_prefix="${cur_prefix}"
    log "[DRY-RUN] HOST Prefix Configuration: /${new_prefix} (Default use)"
  else
    new_prefix=$(whiptail --title "STEP 03 - HOST Prefix" \
                          --inputbox "Enter prefix (CIDR notation):\nExample: 24" \
                          10 60 "${cur_prefix}" \
                          3>&1 1>&2 2>&3) || return 0
  fi

  # Gateway
  local new_gw
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    new_gw="${cur_gw}"
    log "[DRY-RUN] Gateway Configuration: ${new_gw} (Default use)"
  else
    new_gw=$(whiptail --title "STEP 03 - Gateway" \
                      --inputbox "Enter default gateway IP:\nExample: 10.4.0.254" \
                      10 60 "${cur_gw}" \
                      3>&1 1>&2 2>&3) || return 0
  fi

  # DNS
  local new_dns
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    new_dns="${cur_dns}"
    log "[DRY-RUN] DNS Configuration: ${new_dns} (Default use)"
  else
    new_dns=$(whiptail --title "STEP 03 - DNS" \
                       --inputbox "Enter DNS server IPs (space-separated):\nExample: 8.8.8.8 8.8.4.4" \
                       10 70 "${cur_dns}" \
                       3>&1 1>&2 2>&3) || return 0
  fi

  # DATA_NICfor IP Configuration removedone (L2-only bridge Configuration)

  # prefix -> netmask   (HOSTfor)
  local netmask
  case "${new_prefix}" in
    8)  netmask="255.0.0.0" ;;
    16) netmask="255.255.0.0" ;;
    24) netmask="255.255.255.0" ;;
    25) netmask="255.255.255.128" ;;
    26) netmask="255.255.255.192" ;;
    27) netmask="255.255.255.224" ;;
    28) netmask="255.255.255.240" ;;
    29) netmask="255.255.255.248" ;;
    30) netmask="255.255.255.252" ;;
    *)
      netmask=$(whiptail --title "STEP 03 - HOST Netmask Input" \
                         --inputbox "Unknown HOST prefix (/${new_prefix}).\nPlease enter netmask:\nExample: 255.255.255.0" \
                         10 70 "255.255.255.0" \
                         3>&1 1>&2 2>&3) || return 1
      ;;
  esac

  # DATA netmask  removedone (L2-only bridge)

  #######################################
  # 3) udev 99-custom-ifnames.rules Creation
  #######################################
  log "[STEP 03] Creating /etc/udev/rules.d/99-custom-ifnames.rules"

  # HOST_NIC/DATA_NIC PCI address get
  local host_pci data_pci
  host_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
  data_pci=$(readlink -f "/sys/class/net/${DATA_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${host_pci}" || -z "${data_pci}" ]]; then
    whiptail --title "STEP 03 - udev Rule Error" \
             --msgbox "PCI address for HOST_NIC (${HOST_NIC}) or DATA_NIC (${DATA_NIC}) could not be found.\n\nCould not create udev rule." 12 70
    log "HOST_NIC=${HOST_NIC}(${host_pci}), DATA_NIC=${DATA_NIC}(${data_pci}) -> PCI information insufficient, skipping udev rule creation"
    return 1
  fi

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_bak="${udev_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${udev_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${udev_file}" "${udev_bak}"
    log "Existing ${udev_file} backup: ${udev_bak}"
  fi

  # Add udev rule for SPAN NICs PCI address and name mapping
  local span_udev_rules=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci} (PF PCI passthrough mode, SR-IOV not used)
ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
      else
        log "WARNING: SPAN NIC ${span_nic} PCI address could not be found."
      fi
    done
  fi

  local udev_content
  udev_content=$(cat <<EOF
# Host & Data Interface custom names (Auto Creation)
# HOST_NIC=${HOST_NIC}, PCI=${host_pci}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${host_pci}", NAME:="host"

# Data Interface PCI-bus ${data_pci}, SR-IOV not applied
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${data_pci}", NAME:="data"${span_udev_rules}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${udev_file} will be created with the following content:\n${udev_content}"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
  fi

  # udev reload
  run_cmd "sudo udevadm control --reload"
  run_cmd "sudo udevadm trigger --type=devices --action=add"

  #######################################
  # 4) /etc/network/interfaces Creation
  #######################################
  log "[STEP 03] Creating /etc/network/interfaces"

  local iface_file="/etc/network/interfaces"
  local iface_bak="${iface_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${iface_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${iface_file}" "${iface_bak}"
    log "Existing ${iface_file} backup: ${iface_bak}"
  fi

  local iface_content
  iface_content=$(cat <<EOF
source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The host network interface (for)
auto host
iface host inet static
    address ${new_ip}
    netmask ${netmask}
    gateway ${new_gw}
    dns-nameservers ${new_dns}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${iface_file} will be created with the following content:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  #######################################
  # 5) /etc/network/interfaces.d/00-data.cfg Creation (br-data L2 bridge)
  #######################################
  log "[STEP 03] Creating /etc/network/interfaces.d/00-data.cfg (br-data L2 bridge)"

  local iface_dir="/etc/network/interfaces.d"
  local data_cfg="${iface_dir}/00-data.cfg"
  local data_bak="${data_cfg}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  if [[ -f "${data_cfg}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${data_cfg}" "${data_bak}"
    log "Existing ${data_cfg} backup: ${data_bak}"
  fi

  local data_content
  data_content="auto br-data
iface br-data inet manual
    bridge_ports data
    bridge_stp off
    bridge_fd 0"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${data_cfg} will be created with the following content:\n${data_content}"
  else
    printf "%s\n" "${data_content}" > "${data_cfg}"
  fi

  #######################################
  # 5-1) SPAN bridge Creation (SPAN_ATTACH_MODE=bridgein case)
  #######################################
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    log "[STEP 03] Creating SPAN L2 bridge (SPAN_ATTACH_MODE=bridge)"
    
    if [[ -n "${SPAN_NIC_LIST:-}" ]]; then
      local span_bridge_list=""
      local span_index=0
      
      for span_nic in ${SPAN_NIC_LIST}; do
        local bridge_name="br-span${span_index}"
        local span_cfg="${iface_dir}/01-span${span_index}.cfg"
        local span_bak="${span_cfg}.$(date +%Y%m%d-%H%M%S).bak"
        
        if [[ -f "${span_cfg}" && "${DRY_RUN}" -eq 0 ]]; then
          cp -a "${span_cfg}" "${span_bak}"
          log "Existing ${span_cfg} backup: ${span_bak}"
        fi
        
        local span_content
        span_content="auto ${bridge_name}
iface ${bridge_name} inet manual
    bridge_ports ${span_nic}
    bridge_stp off
    bridge_fd 0"
        
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] ${span_cfg} will be created with the following content:\n${span_content}"
        else
          printf "%s\n" "${span_content}" > "${span_cfg}"
        fi
        
        # bridge s add
        span_bridge_list="${span_bridge_list} ${bridge_name}"
        log "SPAN bridge ${bridge_name} -> ${span_nic} Configuration Completed"
        
        ((span_index++))
      done
      
      # bridge s store
      SPAN_BRIDGE_LIST="${span_bridge_list# }"
      save_config_var "SPAN_BRIDGE_LIST" "${SPAN_BRIDGE_LIST}"
      log "SPAN bridge list stored: ${SPAN_BRIDGE_LIST}"
    else
      log "WARNING: SPAN_NIC_LIST exists but SPAN bridge creation may fail if bridge does not exist."
    fi
  else
    log "[STEP 03] Creating SPAN bridge (SPAN_ATTACH_MODE=${SPAN_ATTACH_MODE})"
  fi

  #######################################
  # 6) /etc/iproute2/rt_tables  rt_host 
  #######################################
  log "[STEP 03] Configuring /etc/iproute2/rt_tables for rt_host"

  local rt_file="/etc/iproute2/rt_tables"
  if [[ ! -f "${rt_file}" && "${DRY_RUN}" -eq 0 ]]; then
    touch "${rt_file}"
  fi

  if grep -qE '^[[:space:]]*1[[:space:]]+rt_host' "${rt_file}" 2>/dev/null; then
    log "rt_tables: 1 rt_host already exists."
  else
    local rt_line="1 rt_host"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Adding '${rt_line}' to ${rt_file}"
    else
      echo "${rt_line}" >> "${rt_file}"
      log "Added '${rt_line}' to ${rt_file}"
    fi
  fi

  # Add rt_data entry
  if grep -qE '^[[:space:]]*2[[:space:]]+rt_data' "${rt_file}" 2>/dev/null; then
    log "rt_tables: 2 rt_data already exists."
  else
    local rt_data_line="2 rt_data"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Adding '${rt_data_line}' to ${rt_file}"
    else
      echo "${rt_data_line}" >> "${rt_file}"
      log "Added '${rt_data_line}' to ${rt_file}"
    fi
  fi

  #######################################
  # 7)   rule Configuration script Creation
  #######################################
  log "[STEP 03] Creating routing rule configuration script"

  # Reboot after Execution  rule script Creation
  local routing_script="/etc/network/if-up.d/xdr-routing"
  local routing_bak="${routing_script}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${routing_script}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${routing_script}" "${routing_bak}"
    log "Existing ${routing_script} backup: ${routing_bak}"
  fi

  local routing_content
  routing_content=$(cat <<EOF
#!/bin/bash
# XDR Sensor   rule (Auto Creation)
# Bring interface up

IFACE="\$1"

case "\$IFACE" in
  host)
    # HOST Network  rule
    ip route add default via ${new_gw} dev host table rt_host 2>/dev/null || true
    ip rule add from ${new_ip}/32 table rt_host priority 100 2>/dev/null || true
    ip rule add to ${new_ip}/32 table rt_host priority 100 2>/dev/null || true
    ;;
  data)
EOF
)

  # DATA (br-data) is L2-only bridge - no routing rules required
  routing_content="${routing_content}    # DATA(br-data) L2-only bridge - no routing rules"

  routing_content="${routing_content}
    ;;
esac"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${routing_script} will be created with the following content:\n${routing_content}"
  else
    printf "%s\n" "${routing_content}" | sudo tee "${routing_script}" >/dev/null
    sudo chmod +x "${routing_script}"
  fi

  #######################################
  # 8) netplan disable + ifupdown before
  #######################################
  log "[STEP 03] Disabling netplan and transitioning to ifupdown (reboot required to apply)"

  # Check for netplan configuration files
  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo mkdir -p /etc/netplan/disabled"
      log "[DRY-RUN] sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
    else
      sudo mkdir -p /etc/netplan/disabled
      sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/
    fi
  else
    log "No netplan yaml file found (may already be disabled)."
  fi

  #######################################
  # 7-1) systemd-networkd / netplan service disable + legacy networking activate
  #######################################
  log "[STEP 03] systemd-networkd / netplan service disable and networking service activate"

  # systemd-networkd / netplan  service disable
  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"

  # legacy networking service activate
  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"

  #######################################
  # 9) Summary and Reboot 
  #######################################
  local summary
  # DATA IP Configuration removedone (L2-only bridge)
  local summary_data_extra="
  * br-data     : L2-only bridge (IP None)"

  # SPAN bridge Summary Information add
  local summary_span_extra=""
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" && -n "${SPAN_BRIDGE_LIST:-}" ]]; then
    summary_span_extra="

- SPAN bridge (SPAN_ATTACH_MODE=bridge)"
    for bridge_name in ${SPAN_BRIDGE_LIST}; do
      # bridge ins  NIC 
      local bridge_index="${bridge_name#br-span}"
      local span_nic_array=(${SPAN_NIC_LIST})
      if [[ "${bridge_index}" -lt "${#span_nic_array[@]}" ]]; then
        local span_nic="${span_nic_array[${bridge_index}]}"
        summary_span_extra="${summary_span_extra}
  * ${bridge_name} -> ${span_nic} (L2-only)"
      fi
    done
  elif [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    summary_span_extra="

- SPAN connection Mode: PCI passthrough (SPAN NIC PF directly to Sensor VM)"
  fi

  # SPAN NIC PCI passthrough Information add
  local span_summary=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    span_summary="

* SPAN NIC PCI passthrough (PF direct attach):"
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_summary="${span_summary}
  * ${span_nic} -> PCI ${span_pci}"
      fi
    done
  fi

  summary=$(cat <<EOF
[STEP 03 Result Summary]

- udev rule File      : /etc/udev/rules.d/99-custom-ifnames.rules
  * host  -> PCI ${host_pci}
  * data  -> PCI ${data_pci}${span_summary}

- /etc/network/interfaces
  * host IP     : ${new_ip}/${new_prefix} (netmask ${netmask})
  * gateway     : ${new_gw}
  * dns         : ${new_dns}

- /etc/network/interfaces.d/00-data.cfg${summary_data_extra}${summary_span_extra}

- /etc/iproute2/rt_tables
  * 1 rt_host, 2 rt_data add

- /etc/network/if-up.d/xdr-routing
  *   rule (Reboot after Auto Apply)

- netplan disabled, ifupdown and networking service enabled

* Reboot is required for network configuration changes to take effect.
  AUTO_REBOOT_AFTER_STEP_ID configuration: Auto reboot will be performed after STEP completes.
  Reboot is required for new NIC names (host, data, br-*) to be applied.
EOF
)

  whiptail --title "STEP 03 Completed" \
           --msgbox "${summary}" 25 80

  log "[STEP 03] NIC ifupdown transition and Network Configuration completed. Reboot required for new network configuration to be applied."

  return 0
}

#######################################
# STEP 03 - NAT Mode (OpenXDR NAT Configuration )
#######################################
step_03_nat_mode() {
  log "[STEP 03 NAT Mode] Configuring OpenXDR NAT based network"

  # NAT Mode: HOST_NIC (NAT uplink NIC) is required
  if [[ -z "${HOST_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NAT NIC Not Configured" \
             --msgbox "NAT uplink NIC (HOST_NIC) is not configured.\n\nPlease select NAT uplink NIC in STEP 01." 12 70
    log "HOST_NIC (NAT uplink NIC) not configured. Cannot proceed with STEP 03 NAT Mode."
    return 1
  fi

  #######################################
  # 0) NAT NIC PCI Information Check
  #######################################
  local nat_pci
  nat_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${nat_pci}" ]]; then
    whiptail --title "STEP 03 - PCI Information Error" \
             --msgbox "Selected NAT NIC PCI bus information not found.\n\nPlease check /sys/class/net/${HOST_NIC}/device" 12 70
    log "NAT_NIC=${HOST_NIC}(${nat_pci}) -> PCI information insufficient."
    return 1
  fi

  local tmp_pci="${STATE_DIR}/xdr_step03_pci.txt"
  {
    echo "Selected NAT Network NIC and PCI Information"
    echo "------------------------------------"
    echo "NAT uplink NIC  : ${HOST_NIC}"
    echo "  -> PCI     : ${nat_pci}"
    echo
    echo "Sensor VM virbr0 NAT bridge will be connected."
    echo "DATA NIC is not used in NAT Mode."
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NAT NIC/PCI Check" "${tmp_pci}"
  
  #######################################
  # Check if NAT configuration already exists
  #######################################
  local maybe_done=0
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local iface_file="/etc/network/interfaces"

  if [[ -f "${udev_file}" ]] && \
     grep -q "KERNELS==\"${nat_pci}\".*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null; then
    if [[ -f "${iface_file}" ]] && \
       grep -q "^auto mgt" "${iface_file}" 2>/dev/null && \
       grep -q "iface mgt inet static" "${iface_file}" 2>/dev/null; then
      maybe_done=1
    fi
  fi

  if [[ "${maybe_done}" -eq 1 ]]; then
    if whiptail --title "STEP 03 - Already Configured" \
                --yesno "udev rule and /etc/network/interfaces NAT configuration already exists.\n\nDo you want to skip this STEP?" 12 80
    then
      log "User chose to skip STEP 03 NAT Mode (already configured)."
      return 0
    fi
    log "User canceled STEP 03 NAT Mode execution."
  fi

  #######################################
  # 1) mgt IP Configuration (OpenXDR Method)
  #######################################
  local cur_cidr cur_ip cur_prefix cur_gw cur_dns
  cur_cidr=$(ip -4 -o addr show dev "${HOST_NIC}" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -n "${cur_cidr}" ]]; then
    cur_ip="${cur_cidr%/*}"
    cur_prefix="${cur_cidr#*/}"
  else
    cur_ip=""
    cur_prefix="24"
  fi

  # gateway 
  cur_gw=$(ip route | awk '/default.*'"${HOST_NIC}"'/ {print $3}' | head -n1)
  [[ -z "${cur_gw}" ]] && cur_gw=$(ip route | awk '/default/ {print $3}' | head -n1)

  # DNS 
  cur_dns=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
  [[ -z "${cur_dns}" ]] && cur_dns="8.8.8.8"

  # IP Configuration Input 
  local new_ip new_netmask new_gw new_dns
  new_ip=$(whiptail --title "STEP 03 - mgt NIC IP Configuration" \
                    --inputbox "Enter NAT uplink NIC (mgt) IP address:" \
                    8 60 "${cur_ip}" \
                    3>&1 1>&2 2>&3)
  if [[ -z "${new_ip}" ]]; then
    log "User canceled IP input."
    return 1
  fi

  # prefix netmask 
  local netmask=""
  case "${cur_prefix}" in
    24) netmask="255.255.255.0" ;;
    16) netmask="255.255.0.0" ;;
    8)  netmask="255.0.0.0" ;;
    *)  netmask="255.255.255.0" ;;
  esac

  new_netmask=$(whiptail --title "STEP 03 - Netmask Configuration" \
                         --inputbox "Enter netmask:" \
                         8 60 "${netmask}" \
                         3>&1 1>&2 2>&3)
  if [[ -z "${new_netmask}" ]]; then
    log "User canceled netmask input."
    return 1
  fi

  new_gw=$(whiptail --title "STEP 03 - Gateway Configuration" \
                    --inputbox "Enter gateway IP:" \
                    8 60 "${cur_gw}" \
                    3>&1 1>&2 2>&3)
  if [[ -z "${new_gw}" ]]; then
    log "User canceled gateway input."
    return 1
  fi

  new_dns=$(whiptail --title "STEP 03 - DNS Configuration" \
                     --inputbox "Enter DNS server IPs:" \
                     8 60 "${cur_dns}" \
                     3>&1 1>&2 2>&3)
  if [[ -z "${new_dns}" ]]; then
    log "User canceled DNS input."
    return 1
  fi

  #######################################
  # 2) Create udev rule (NAT uplink NIC -> mgt rename + SPAN NIC name mapping)
  #######################################
  log "[STEP 03 NAT Mode] Creating udev rule (${HOST_NIC} -> mgt + SPAN NIC name mapping)"
  
  # Add udev rule for SPAN NICs PCI address and name mapping
  local span_udev_rules=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci} (PF PCI passthrough mode, SR-IOV not used)
SUBSYSTEM==\"net\", ACTION==\"add\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
      else
        log "WARNING: SPAN NIC ${span_nic} PCI address could not be found."
      fi
    done
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/udev/rules.d/99-custom-ifnames.rules Creation"
    log "[DRY-RUN] Adding NAT mgt NIC + SPAN NIC name mapping rule"
  else
    cat > /etc/udev/rules.d/99-custom-ifnames.rules <<EOF
# XDR NAT Mode - Custom interface names
SUBSYSTEM=="net", ACTION=="add", KERNELS=="${nat_pci}", NAME:="mgt"${span_udev_rules}
EOF
    log "udev rule file creation completed (mgt + SPAN NIC name mapping)"
  fi

  #######################################
  # 3) /etc/network/interfaces Configuration (OpenXDR Method)
  #######################################
  log "[STEP 03 NAT Mode] Configuring /etc/network/interfaces"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/network/interfaces mgt NIC Configuration"
  else
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d-%H%M%S)
    
    cat > /etc/network/interfaces <<EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# Management interface (NAT uplink)
auto mgt
iface mgt inet static
    address ${new_ip}
    netmask ${new_netmask}
    gateway ${new_gw}
    dns-nameservers ${new_dns}
EOF
    log "/etc/network/interfaces Configuration Completed"
  fi

  #######################################
  # 4) SPAN NICs (Bridge Mode)
  #######################################
  if [[ -n "${SPAN_NICS:-}" ]]; then
    log "[STEP 03 NAT Mode] SPAN NICs keep default name (PF PCI passthrough mode)"
    for span_nic in ${SPAN_NICS}; do
      log "SPAN NIC: ${span_nic} (no name change, PF PCI passthrough mode)"
    done
  fi

  #######################################
  # 5) Completed whennot
  #######################################
  # SPAN NIC PCI passthrough Information add (NAT Mode)
  local span_summary_nat=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    span_summary_nat="

* SPAN NIC PCI passthrough (PF direct attach):"
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_summary_nat="${span_summary_nat}
- ${span_nic} -> PCI ${span_pci}"
      fi
    done
  fi

  local summary
  summary=$(cat <<EOF
[STEP 03 NAT Mode Completed]

NAT Network Configuration completed.

Network Configuration:
- NAT uplink NIC  : ${HOST_NIC} -> mgt (${new_ip}/${new_netmask})
- Gateway      : ${new_gw}
- DNS          : ${new_dns}
- Sensor VM      : virbr0 NAT bridge connection (192.168.122.0/24)
- SPAN NICs   : ${SPAN_NICS:-None} (PCI passthrough mode)${span_summary_nat}

udev rule     : /etc/udev/rules.d/99-custom-ifnames.rules
Network Configuration  : /etc/network/interfaces

* Reboot is required for network configuration changes to take effect.
  AUTO_REBOOT_AFTER_STEP_ID is configured - Auto reboot will be performed after STEP completes.
  Reboot is required for NAT Network (mgt NIC) configuration to be applied.
EOF
)

  whiptail --title "STEP 03 NAT Mode Completed" \
           --msgbox "${summary}" 20 80

  log "[STEP 03 NAT Mode] NAT Network Configuration completed. Reboot required for NAT configuration to be applied."

  return 0
}


step_04_kvm_libvirt() {
  log "[STEP 04] KVM / Libvirt Installation and default configuration"
  load_config

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
    if ! whiptail --title "STEP 04 - Already Configured" \
                  --yesno "KVM libvirtd is already configured.\n\nDo you want to skip this STEP?\n\n(Yes: Skip / No: Continue)" 12 70
    then
      log "User canceled STEP 04 execution."
    else
      log "User chose to skip STEP 04 (already configured)."
      return 0
    fi
  fi

  if ! whiptail --title "STEP 04 Execution Confirmation" \
                 --yesno "Do you want to proceed with KVM / Libvirt installation?" 10 60
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

  local packages=(
      "qemu-kvm"
      "libvirt-daemon-system"
      "libvirt-clients"
      "bridge-utils"
      "virt-manager"
      "cpu-checker"
      "qemu-utils"
      "virtinst"      # adddone (PDF this )
      "genisoimage"   # adddone (Cloud-init ISO Creationfor)
    )

  local pkg_count=0
  local total_pkgs=${#packages[@]}
  
  for pkg in "${packages[@]}"; do
    ((pkg_count++))
    echo "=== Installing package $pkg_count/$total_pkgs: $pkg (this may take some time) ==="
    log "Installing package: $pkg ($pkg_count/$total_pkgs)"
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg}"
    echo "=== $pkg installation completed ==="
  done
  
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
    echo "STEP 04 execution summary"
    echo "------------------"
    echo "KVM  use available: ${final_kvm_ok}"
    echo "libvirtd service: ${final_libvirtd_ok}"
    echo
    echo "Sensor VM :"
    echo "- br-data: DATA NIC L2 bridge"
    echo "- br-span*: SPAN NIC L2 bridge (bridge mode if configured)"
    echo "- SPAN NIC: PCI passthrough (pci mode if configured)"
    echo
    echo "* User group changes will be applied after next login/reboot."
    echo "*   BIOS/UEFI must have virtualization enabled."
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
    if ! whiptail --title "STEP 05 - Already Configured" \
                  --yesno "GRUB IOMMU and KSM configuration already exists.\n\nDo you want to skip this STEP?" 12 70
    then
      log "User canceled STEP 05 execution."
    else
      log "User chose to skip STEP 05 (already configured)."
      return 0
    fi
  fi

  if ! whiptail --title "STEP 05 Execution Confirmation" \
                 --yesno "Do you want to proceed with kernel tuning?" 10 60
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
  if whiptail --title "STEP 05 - swap disable" \
              --yesno "Do you want to disable swap?\n\nNote: This is recommended, but insufficient memory may cause issues.\n\nThe following will be done:\n- Disable all swap\n- Comment out swap entries in /etc/fstab\n- Remove /swapfile, /swap.img files" 16 70
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
    echo "STEP 05 execution summary"
    echo "------------------"
    echo "GRUB IOMMU Configuration: Completed"
    echo "Kernel parameter tuning: Completed"
    echo "KSM disable: Completed"
    echo
    echo "* System reboot is required to apply all configuration changes."
    echo "* System will automatically reboot after STEP completion."
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
  
  # mode branch Execution
  if [[ "${net_mode}" == "bridge" ]]; then
    log "[STEP 06] Bridge Mode - Installing sensor hooks"
    step_06_bridge_hooks
    return $?
  elif [[ "${net_mode}" == "nat" ]]; then
    log "[STEP 06] NAT Mode - Installing OpenXDR NAT hooks"
    step_06_nat_hooks
    return $?
  else
    log "ERROR: Unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail_msgbox "Network Mode Error" "Unknown sensor network mode: ${net_mode}\n\nPlease select a valid mode (bridge or nat) in environment configuration."
    return 1
  fi
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

  if ! whiptail --title "STEP 08 Execution Check" \
                 --yesno "Create /etc/libvirt/hooks/network and /etc/libvirt/hooks/qemu scripts based on configuration.\n\nDo you want to continue?" 13 80
  then
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

  log "[STEP 08] Creating ${HOOK_QEMU} (OOM recovery script only, NAT removed)"

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
  log "[STEP 08] Installing OOM recovery scripts (last_known_good_pid, check_vm_state)"

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
      log "[STEP 08] Adding SHELL=/bin/bash and check_vm_state to root crontab."
    else
      log "[STEP 08] root crontab SHELL=/bin/bash and check_vm_state already exists."
    fi
  fi

  #######################################
  # 5)  Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 08 execution summary"
    echo "----------------------"
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
  } >> "${tmp_info}"

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

  if ! whiptail --title "STEP 06 NAT Mode Execution Check" \
                 --yesno "Install libvirt hooks for NAT Mode.\n\n- Apply OpenXDR NAT configuration\n- Configure Sensor VM (mds) DNAT\n- OOM recovery\n\nDo you want to continue?" 15 70
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
  TCP_PORTS=(514 2055 5044 5123 5100:5200 5500:5800 5900)
  VXLAN_PORTS=(4789 8472)
  UDP_PORTS=(514 2055 5044 5100:5200 5500:5800 5900)
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

  whiptail --title "STEP 08 NAT Mode Completed" \
           --msgbox "${summary}" 18 80

  log "[STEP 06 NAT Mode] NAT libvirt hooks installation completed"

  return 0
}


step_07_sensor_download() {
  log "[STEP 07] Sensor LV Creation + Image/script Download"
  load_config

  # User Configuration  (OpenXDR Method: ubuntu-vg use)
  : "${LV_LOCATION:=ubuntu-vg}"
  : "${LV_SIZE_GB:=500}"
  
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
    if whiptail --title "STEP 07 - LV Already Configured" \
                --yesno "lv_sensor_root and ${mount_point} are already configured.\nPath: ${lv_path}\n\nSkip LV creation/mount and only download qcow2 if not already downloaded?" 12 80
    then
      log "LV already exists, skipping LV creation/mount and only downloading if not already downloaded."
      skip_lv_creation="yes"
    else
      log "User canceled STEP 07 execution."
    fi
  fi

  if ! whiptail --title "STEP 07 Execution Check" \
                 --yesno "Do you want to create Sensor LV and download image?" 10 60
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
        whiptail --title "STEP 07 - Mount Error" \
                 --msgbox "${mount_point} is already mounted by a different device (${mounted_device}).\n\nPlease unmount it first or use a different mount point." 12 80
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
      
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${SENSOR_IMAGE_DIR}/${qcow2_name}\""
      else
        sudo cp "${local_qcow}" "${SENSOR_IMAGE_DIR}/${qcow2_name}"
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
    log "[STEP 07] Downloading ${qcow2_name}"
    need_qcow2=1
  else
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
    echo "STEP 07 execution summary"
    echo "------------------"
    echo "lv_sensor_root LV: ${final_lv}"
    echo "${mount_point} mount: ${final_mount}"
    echo "Sensor image status: ${final_image}"
    echo
    echo "Download Location: ${SENSOR_IMAGE_DIR}"
    echo "Image file: ${qcow2_name}"
    echo "Deployment script: virt_deploy_modular_ds.sh"
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

  # Configuration check
  if [[ -z "${SENSOR_VCPUS:-}" || -z "${SENSOR_MEMORY_MB:-}" ]]; then
    whiptail --title "STEP 08 - Configuration Error" \
             --msgbox "Sensor vCPU or Memory configuration does not exist.\n\nPlease complete Hardware Configuration in STEP 01." 12 70
    log "SENSOR_VCPUS or SENSOR_MEMORY_MB is not configured"
    return 1
  fi

  #######################################
  # 0) Current status check
  #######################################
  local vm_exists="no"
  local vm_running="no"

  if virsh list --all | grep -q "\smds\s" 2>/dev/null; then
    vm_exists="yes"
    if virsh list --state-running | grep -q "\smds\s" 2>/dev/null; then
      vm_running="yes"
    fi
  fi

  {
    echo "Current Sensor VM Status"
    echo "------------------"
    echo "mds VM Exists: ${vm_exists}"
    echo "mds VM Execution: ${vm_running}"
    echo
    echo "Deployment Configuration:"
    echo "- hostname: mds"
    echo "- vCPU: ${SENSOR_VCPUS}"
    echo "- Memory: ${SENSOR_MEMORY_MB}MB"
    echo "- Disk Size: ${LV_SIZE_GB}GB"
    echo "- Install Dir: /var/lib/libvirt/images/mds"
    echo
    echo " STEP: virt_deploy_modular_ds.sh script will be used"
    echo "Sensor VM deployment (nodownload=1 execution)"
  } > "${tmp_status}"

  show_textbox "STEP 08 - Sensor VM Deployment unit" "${tmp_status}"

  if [[ "${vm_exists}" == "yes" ]]; then
    if ! whiptail --title "STEP 08 - Existing VM" \
                  --yesno "mds VM already exists.\n\nDo you want to redeploy the existing VM?" 12 70
    then
      log "User canceled existing VM redeployment."
      return 0
    else
      log "[STEP 08] Removing existing mds VM"
      if [[ "${vm_running}" == "yes" ]]; then
        run_cmd "virsh destroy mds"
      fi
      run_cmd "virsh undefine mds --remove-all-storage"
    fi
  fi

  if ! whiptail --title "STEP 08 Execution Check" \
                 --yesno "Do you want to deploy Sensor VM?" 10 60
  then
    log "User canceled STEP 08 execution."
    return 0
  fi

  #######################################
  # 1) Deployment script Check
  #######################################
  local script_path="/var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh"
  
  if [[ ! -f "${script_path}" && "${DRY_RUN}" -eq 0 ]]; then
    whiptail --title "STEP 08 - script None" \
             --msgbox "Deployment script does not exist:\n\n${script_path}\n\nPlease execute STEP 07 first." 12 80
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
  local cpus="${SENSOR_VCPUS}"
  local memory="${SENSOR_MEMORY_MB}"
  # Check if LV_SIZE_GB already has GB suffix
  local disksize
  if [[ "${LV_SIZE_GB}" =~ GB$ ]]; then
    disksize="${LV_SIZE_GB}"
  else
    disksize="${LV_SIZE_GB}GB"
  fi
  local nodownload="1"

  local deploy_cmd="bash '${script_path}' -- --hostname='${hostname}' --release='${release}' --CPUS='${cpus}' --MEM='${memory}' --DISKSIZE='${disksize}' --installdir='${installdir}' --nodownload='${nodownload}'"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Sensor VM Deployment :\n${deploy_cmd}"
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
    log "  Disk Size: ${disksize}"
    log "  InstallationDirectory: ${installdir}"
    log "  Download skip: ${nodownload}"
    
    # Execution before VM status check
    log "[STEP 08] Checking existing VM status before deployment"
    local existing_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
    existing_vm_count=$(echo "${existing_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
    [[ -z "${existing_vm_count}" ]] && existing_vm_count="0"
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
        if virsh net-list --all | grep -q "default.*inactive"; then
          run_cmd "sudo virsh net-start default" || log "WARNING: default network start failed"
        elif ! virsh net-list | grep -q "default.*active"; then
          log "WARNING: default libvirt network (default) could not be activated."
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
      
      # Bridge Mode - Required IP Configuration (Default or User Configuration)
      local sensor_ip="${SENSOR_VM_IP:-192.168.100.100}"
      local sensor_netmask="${SENSOR_VM_NETMASK:-255.255.255.0}"
      local sensor_gateway="${SENSOR_VM_GATEWAY:-192.168.100.1}"
      
      export LOCAL_IP="${sensor_ip}"
      export NETMASK="${sensor_netmask}"
      export GATEWAY="${sensor_gateway}"
      
      log "[STEP 08] Bridge Mode VM IP Configuration: ${sensor_ip}/${sensor_netmask}, GW: ${sensor_gateway}"
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode - Configuring environment variables: BRIDGE=virbr0"
      export BRIDGE="virbr0"
      export SENSOR_BRIDGE="virbr0"
      export NETWORK_MODE="nat"
      
      # NAT Mode - Using DHCP
      export LOCAL_IP="192.168.122.2"
      export NETMASK="255.255.255.0"
      export GATEWAY="192.168.122.1"
    fi
    
    # Configure additional environment variables for deployment script
    local disk_size_gb
    if [[ "${disksize}" =~ ^([0-9]+)GB$ ]]; then
      disk_size_gb="${BASH_REMATCH[1]}"
    elif [[ "${disksize}" =~ ^([0-9]+)$ ]]; then
      disk_size_gb="${disksize}"
    else
      disk_size_gb="100"  # Default
    fi
    
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

    # Execute deployment script
    log "[STEP 08] Starting sensor VM deployment script execution..."
    local deploy_cmd="bash virt_deploy_modular_ds.sh -- --hostname=\"${hostname}\" --release=\"${release}\" --CPUS=\"${cpus}\" --MEM=\"${memory}\" --DISKSIZE=\"${disk_size_gb}\" --installdir=\"${installdir}\" --nodownload=\"${nodownload}\" --bridge=\"${BRIDGE}\""
    log "[STEP 08] Execution command: ${deploy_cmd}"
    log "[STEP 08] Network Mode: ${net_mode}, using bridge: ${BRIDGE:-None}"
    log "[STEP 08] ========== Deployment script output start =========="
    
    local deploy_output deploy_rc deploy_log_file
    deploy_log_file="${STATE_DIR}/deploy_output.log"
    

	# Timeout: 180s (3 minutes) - if VM creation succeeds, timeout is acceptable
    timeout 180s bash virt_deploy_modular_ds.sh -- \
         --hostname="${hostname}" \
         --release="${release}" \
         --CPUS="${cpus}" \
         --MEM="${memory}" \
         --DISKSIZE="${disk_size_gb}" \
         --installdir="${installdir}" \
         --nodownload="${nodownload}" \
         --bridge="${BRIDGE}" 2>&1 | tee "${deploy_log_file}"

    # Timeout (124) is acceptable if VM exists and is running
    deploy_rc=${PIPESTATUS[0]}
    if [[ ${deploy_rc} -eq 124 ]]; then
      if virsh list --all | grep -q "mds.*running"; then
         log "[INFO] Deployment script timeout - but VM is running successfully."
         deploy_rc=0
      fi
    fi

    
    log "[STEP 08] ========== Deployment script output completed =========="
    
    # Read output from log file
    if [[ -f "${deploy_log_file}" ]]; then
      deploy_output=$(cat "${deploy_log_file}")
    else
      deploy_output=""
    fi
    
    # Log all output
    log "[STEP 08] Deployment script execution completed (exit code: ${deploy_rc})"
    if [[ -n "${deploy_output}" ]]; then
      log "[STEP 08] Deployment script full output:"
      log "----------------------------------------"
      log "${deploy_output}"
      log "----------------------------------------"
    else
      log "[STEP 08] Deployment script output is empty"
    fi
    
    # Execution after VM status check
    log "[STEP 08] Deployment after VM status check"
    local new_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
    new_vm_count=$(echo "${new_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
    [[ -z "${new_vm_count}" ]] && new_vm_count="0"
    log "  New mds VM count: ${new_vm_count}"
    
    if [[ "${new_vm_count}" -gt "${existing_vm_count}" ]]; then
      log "[STEP 08] VM Creation Success Check"
      virsh list --all | grep "mds" | while read line; do
        log "  VM Information: ${line}"
      done
    else
      log "WARNING: VM creation failed or VM already exists"
    fi
    # Deployment Result 
    if [[ ${deploy_rc} -ne 0 ]]; then
      log "[STEP 08] Sensor VM Deployment Failed (exit code: ${deploy_rc})"
      
      # Check for specific errors
      if echo "${deploy_output}" | grep -q "BIOS not enabled for VT-d/IOMMU"; then
        log "ERROR: BIOS VT-d/IOMMU is disabled."
        log "Solution: Enable Intel VT-d or AMD-Vi (IOMMU) in BIOS configuration."
        whiptail --title "BIOS Configuration Required" \
                 --msgbox "VM Deployment Failed: BIOS VT-d/IOMMU is disabled.\n\nSolution:\n1. Reboot the system\n2. Enter BIOS/UEFI configuration\n3. Enable Intel VT-d or AMD-Vi (IOMMU)\n4. Save configuration and reboot\n\nWithout this configuration, VM creation will fail." 16 70
        return 1
      fi
      
      # Check if VM was created despite error
      if virsh list --all | grep -q "mds"; then
        log "[STEP 08] Deployment script error but VM creation completed. Continuing..."
      else
        log "ERROR: Deployment script failed and VM creation failed"
        return 1
      fi
    else
      log "[STEP 08] Sensor VM Deployment Success"
    fi
    
    # Check VM Status
    log "[STEP 08] Current VM Status:"
    virsh list --all | grep "mds" | while read line; do
      log "  ${line}"
    done
    
    log "[STEP 08] Sensor VM Deployment execution completed"
  fi

  #######################################
  # 3) br-data and SPAN bridge Check, VM SPAN connection
  #######################################
  log "[STEP 08] Adding sensor VM network interfaces (SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE})"
  
  # br-data bridge Exists Check and Creation
  if [[ "${DRY_RUN}" -eq 0 ]]; then
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
      fi
    else
      log "br-data bridge already exists."
    fi
  else
    log "[DRY-RUN] Checking br-data bridge existence and creating if required"
  fi
  
  # SPAN bridge check and creation (bridge mode if configured)
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" && "${DRY_RUN}" -eq 0 ]]; then
    if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
      for bridge_name in ${SPAN_BRIDGE_LIST}; do
        if ! ip link show "${bridge_name}" >/dev/null 2>&1; then
          log "SPAN bridge ${bridge_name} does not exist. Creating bridge..."
          # bridge namefrom ins  (br-span0 -> 0)
          local span_index="${bridge_name#br-span}"
          # SPAN_NIC_LISTfrom  ins NIC 
          local span_nic_array=(${SPAN_NIC_LIST})
          if [[ "${span_index}" -lt "${#span_nic_array[@]}" ]]; then
            local span_nic="${span_nic_array[${span_index}]}"
            ip link add name "${bridge_name}" type bridge
            ip link set dev "${bridge_name}" up
            ip link set dev "${span_nic}" master "${bridge_name}"
            echo 0 > "/sys/class/net/${bridge_name}/bridge/stp_state"
            echo 0 > "/sys/class/net/${bridge_name}/bridge/forward_delay"
            log "SPAN bridge ${bridge_name} creation completed: ${span_nic} connected"
          else
            log "ERROR: SPAN bridge ${bridge_name} corresponding NIC does not exist."
          fi
        else
          log "SPAN bridge ${bridge_name} already exists."
        fi
      done
    else
      log "WARNING: SPAN_BRIDGE_LIST exists."
    fi
  elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    log "[DRY-RUN] Checking SPAN bridge existence and creating if required"
  fi
  
  # Check VM creation and modify XML
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    # Shutdown VM if running
    if virsh list --state-running | grep -q "\smds\s"; then
      log "Shutting down mds VM..."
      virsh shutdown mds
      sleep 5
    fi
    
    # Check if VM exists
    if ! virsh list --all | grep -q "mds"; then
      log "ERROR: mds VM was not created. Please check deployment script execution."
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
      # Check if br-data interface already exists in XML
      if grep -q "<source bridge='br-data'/>" "${vm_xml_new}"; then
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
      
      # SPAN connection mode
      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        # Add SPAN NICs PF PCI passthrough (hostdev)
        if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
          log "Adding SPAN NIC PCIs for PCI passthrough: ${SENSOR_SPAN_VF_PCIS}"
          for pci_full in ${SENSOR_SPAN_VF_PCIS}; do
            if [[ "${pci_full}" =~ ^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
              local domain="${BASH_REMATCH[1]}"
              local bus="${BASH_REMATCH[2]}"
              local slot="${BASH_REMATCH[3]}"
              local func="${BASH_REMATCH[4]}"

              # </devices>   hostdev add
              local hostdev_xml="    <hostdev mode='subsystem' type='pci' managed='yes'>
        <source>
          <address domain='0x${domain}' bus='0x${bus}' slot='0x${slot}' function='0x${func}'/>
        </source>
      </hostdev>"

              # Update XML file paths
              local tmp_xml="${vm_xml_new}.tmp"
              awk -v hostdev="$hostdev_xml" '
                /<\/devices>/ { print hostdev }
                { print }
              ' "${vm_xml_new}" > "${tmp_xml}"
              mv "${tmp_xml}" "${vm_xml_new}"
              log "SPAN PCI(${pci_full}) hostdev attached successfully"
            else
              log "WARNING: Invalid PCI address format: ${pci_full}"
            fi
          done
        else
          log "WARNING: SENSOR_SPAN_VF_PCIS is empty."
        fi
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        # Add SPAN bridges as virtio interfaces
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
          log "Adding SPAN bridges as virtio interfaces: ${SPAN_BRIDGE_LIST}"
          for bridge_name in ${SPAN_BRIDGE_LIST}; do
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
          done
        else
          log "WARNING: SPAN_BRIDGE_LIST is empty."
        fi
      else
        log "WARNING: Unknown SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE}"
      fi
      
      # Redefine VM with modified XML
      log "Redefining VM with modified XML"
      virsh undefine mds
      virsh define "${vm_xml_new}"
      
      # Start VM
      log "Starting mds VM"
      virsh start mds
      
      log "br-data bridge and SPAN interfaces added successfully"
    else
      log "ERROR: VM XML file does not exist."
      return 1
    fi
  else
    log "[DRY-RUN] Adding br-data bridge and SPAN interfaces (not executed)"
    log "[DRY-RUN] br-data bridge: <interface type='bridge'><source bridge='br-data'/><model type='virtio'/></interface>"

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
  fi

  {
    echo "STEP 08 execution summary"
    echo "------------------"
    echo "mds VM Creation: ${final_vm}"
    echo "mds VM Execution: ${final_running}"
    echo
    echo "VM Information:"
    echo "- name: mds"
    echo "- vCPU: ${cpus}"
    echo "- Memory: ${memory}MB"
    echo "- Disk: ${disksize}GB"
    echo
    echo "Network Configuration:"
    echo "- br-data bridge: L2-only bridge connected (Sensor VM IP configuration required)"
    echo "- SPAN Connection Mode: ${SPAN_ATTACH_MODE}"

    if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
      if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
        echo "- SPAN NIC PCIs: PCI passthrough connected"
        for pci in ${SENSOR_SPAN_VF_PCIS}; do
          echo "  * ${pci}"
        done
      fi
      echo
      echo "Sensor Network Topology:"
      echo "[DATA_NIC]──(L2-only)──[br-data]──(virtio)──[Sensor VM NIC]"
      echo "[SPAN NIC PF(s)]────(PCI passthrough via vfio-pci)──[Sensor VM]"
    elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
      if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
        echo "- SPAN bridges: L2 bridge virtio connected"
        for bridge_name in ${SPAN_BRIDGE_LIST}; do
          echo "  * ${bridge_name}"
        done
      fi
      echo
      echo "Sensor Network Topology:"
      echo "[DATA_NIC]──(L2-only)──[br-data]──(virtio)──[Sensor VM NIC]"
      echo "[SPAN_NIC(s)]──(L2-only)──[br-spanX]──(virtio)──[Sensor VM]"
    fi
    echo
    echo "* Use 'virsh list --all' to check VM status."
    echo "* If VM is not running, start it manually."
    echo "* Configure IP address on the NIC connected to br-data inside the Sensor VM."
  } > "${tmp_status}"

  show_textbox "STEP 08 Result Summary" "${tmp_status}"

  log "[STEP 08] Sensor VM Deployment Completed"

  return 0
}

step_09_sensor_passthrough() {
    local STEP_ID="09_sensor_passthrough"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 09. Sensor PCI Passthrough / CPU Affinity Configuration and Verification ====="

    # config 
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    local SENSOR_VM="mds"

    ###########################################################################
    # NUMA node count check (using lscpu)
    ###########################################################################
    local numa_nodes=1
    if command -v lscpu >/dev/null 2>&1; then
        numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    fi
    [[ -z "${numa_nodes}" ]] && numa_nodes=1

    log "[STEP 09] NUMA node count: ${numa_nodes}"

    ###########################################################################
    # 1. Sensor VM Exists Check
    ###########################################################################
    if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
        whiptail_msgbox "STEP 09 - Sensor VM Not Found" "Sensor VM (${SENSOR_VM}) does not exist.\n\nPlease complete STEP 08 (Sensor Deployment) first."
        log "[STEP 09] Sensor VM not found -> STEP Abort"
        return 1
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

        # Verify VM XML paths reference the correct location
        log "[STEP 09] Verifying VM XML storage paths"
        local xml_path_check=0
        while read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ "${f}" =~ ^${VM_STORAGE_BASE} ]]; then
                xml_path_check=$((xml_path_check+1))
            fi
        done < <(virsh dumpxml "${SENSOR_VM}" | awk -F"'" '/<source file=/{print $2}')

        if [[ "${xml_path_check}" -eq 0 ]]; then
            log "[STEP 09] INFO: VM XML paths may not reference ${VM_STORAGE_BASE} (may be using different path)"
        else
            log "[STEP 09] Verified: VM XML references ${xml_path_check} file(s) under ${VM_STORAGE_BASE}"
        fi

        # Verify that files referenced in XML actually exist
        log "[STEP 09] Checking XML source file existence"
        local missing=0
        while read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ ! -e "${f}" ]]; then
                log "[STEP 09] ERROR: missing file: ${f}"
                missing=$((missing+1))
            fi
        done < <(virsh dumpxml "${SENSOR_VM}" | awk -F"'" '/<source file=/{print $2}')

        if [[ "${missing}" -gt 0 ]]; then
            whiptail_msgbox "STEP 09 - File Missing" "VM XML references ${missing} missing file(s).\n\nPlease re-run STEP 08 (Deployment) or check image file locations."
            log "[STEP 09] ERROR: XML source file missing count=${missing}"
            return 1
        fi
    fi

    ###########################################################################
    # 2. PCI Passthrough connection (Action)
    ###########################################################################
    if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
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
                if virsh dumpxml "${SENSOR_VM}" | grep -q "address.*bus='${b}'.*slot='${s}'.*function='${f}'"; then
                    log "[INFO] PCI (${pci_full}) is already connected."
                else
                    log "[ACTION] Connecting PCI (${pci_full}) to VM..."
                    if [[ "${_DRY}" -eq 0 ]]; then
                        if virsh attach-device "${SENSOR_VM}" "${pci_xml}" --config --live; then
                            log "[SUCCESS] PCI passthrough connection successful"
                        else
                            log "[ERROR] PCI passthrough connection failed (device may be in use, check IOMMU configuration)"
                        fi
                    else
                        log "[DRY-RUN] virsh attach-device ${SENSOR_VM} ${pci_xml} --config --live"
                    fi
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

    local hostdev_count=0
    if virsh dumpxml "${SENSOR_VM}" | grep -q "<hostdev.*type='pci'"; then
        hostdev_count=$(virsh dumpxml "${SENSOR_VM}" | grep -c "<hostdev.*type='pci'" || echo "0")
        log "[STEP 09] Sensor VM has ${hostdev_count} PCI hostdev device(s) connected"
    else
        log "[WARN] Sensor VM PCI hostdev does not exist."
    fi

    ###########################################################################
    # 4. CPU Affinity configuration (only if multiple NUMA nodes)
    ###########################################################################
    if [[ "${numa_nodes}" -gt 1 ]]; then
        log "[STEP 09] Sensor VM CPU Affinity Apply Start"

        local available_cpus
        available_cpus=$(lscpu -p=CPU | grep -v '^#' | tr '\n' ',' | sed 's/,$//')

        if [[ -n "${available_cpus}" ]]; then
            log "[ACTION] Configuring CPU Affinity (All CPUs)"
            if [[ "${_DRY}" -eq 0 ]]; then
                virsh emulatorpin "${SENSOR_VM}" "${available_cpus}" --config >/dev/null 2>&1 || true

                local max_vcpus
                max_vcpus="$(virsh vcpucount "${SENSOR_VM}" --maximum --config 2>/dev/null || echo 0)"
                for (( i=0; i<max_vcpus; i++ )); do
                    virsh vcpupin "${SENSOR_VM}" "${i}" "${available_cpus}" --config >/dev/null 2>&1 || true
                done
            else
                log "[DRY-RUN] virsh emulatorpin/vcpupin ${SENSOR_VM} ${available_cpus} --config"
            fi
        fi
    fi

    ###########################################################################
    # 4.5 Restart VM to apply configuration changes
    ###########################################################################
    restart_vm_safely "${SENSOR_VM}"

    ###########################################################################
    # 5. Result summary 
    ###########################################################################
    local result_file="/tmp/step09_result.txt"
    {
        echo "STEP 09 - Verification Result"
        echo "==================="
        echo "- VM Status: $(virsh domstate ${SENSOR_VM} 2>/dev/null)"
        echo "- PCI passthrough devices: ${hostdev_count}"
        if [[ "${hostdev_count}" -gt 0 ]]; then
            echo "  (Success: PCI Passthrough correctly applied)"
        else
            echo "  (Failed: PCI passthrough connection failed. Please check STEP 01 configuration)"
        fi
    } > "${result_file}"

    show_paged "STEP 09 Result" "${result_file}"

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

    if ! whiptail --title "STEP 10 Execution Check" \
                  --yesno "Install DP Appliance CLI package (dp_cli) and apply to stellar user.\n\n(Will download latest version from GitHub: https://github.com/RickLee-kr/Stellar-appliance-cli)\n\nDo you want to continue?" 15 85
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

        # setuptools<81 pin
        "${VENV_DIR}/bin/python" -m pip install --upgrade pip "setuptools<81" wheel >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: venv pip/setuptools Installation Failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        }

        # Install from downloaded directory
        (cd "${pkg}" && "${VENV_DIR}/bin/python" -m pip install --upgrade --force-reinstall .) >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli Installation Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            rm -rf "${TEMP_DIR}" || true
            return 1
        }

        (cd /tmp && "${VENV_DIR}/bin/python" -c "import dp_cli; print('dp_cli import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp_cli import Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        }

        if [[ ! -x "${VENV_DIR}/bin/aella_cli" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: ${VENV_DIR}/bin/aella_cli  does not exist." | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: dp-cli package console_scripts (aella_cli) entry point may not be available." | tee -a "${ERRLOG}"
            return 1
        fi

        # Verify runtime import (aella_cli execution smoke test removed)
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; import dp_cli; from dp_cli import aella_cli_aio_appliance; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli  import Verification Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
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

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: venv dp_cli import"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import dp_cli; print('dp_cli import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: venv pkg_resources"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; print('pkg_resources OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] verify: runtime import check"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; import dp_cli; from dp_cli import aella_cli_aio_appliance; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || true

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

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 13. Install DP Appliance CLI package ====="
    echo
}


menu_config() {
  while true; do
    # Latest Configuration 
    load_config

    local msg
    msg="Current Configuration\n\n"
    msg+="DRY_RUN      : ${DRY_RUN}\n"
    msg+="DP_VERSION   : ${DP_VERSION}\n"
    msg+="ACPS_USER    : ${ACPS_USERNAME:-<not configured>}\n"
        msg+="ACPS_PASSWORD: ${ACPS_PASSWORD:-<not configured>}\n"
    msg+="ACPS_URL     : ${ACPS_BASE_URL:-<not configured>}\n"
    msg+="MGT_NIC      : ${MGT_NIC:-<not configured>}\n"
    msg+="CLTR0_NIC    : ${CLTR0_NIC:-<not configured>}\n"
    msg+="DATA_SSD_LIST: ${DATA_SSD_LIST:-<not configured>}\n"

    local choice
    choice=$(whiptail --title "XDR Installer - environment Configuration" \
      --menu "${msg}" 22 80 10 \
      "1" "DRY_RUN  (0/1)" \
      "2" "DP_VERSION Configuration" \
      "3" "ACPS Username/Password Configuration" \
      "4" "ACPS URL Configuration" \
      "5" " " \
      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      "1")
        # DRY_RUN 
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=1 (simulation mode).\n\nDo you want to change to DRY_RUN=0 (actual execution mode)?" 12 70
          then
            DRY_RUN=0
          fi
        else
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=0 (actual execution mode).\n\nDo you want to change to DRY_RUN=1 (simulation mode)?" 12 70
          then
            DRY_RUN=1
          fi
        fi
        save_config
        ;;

      "2")
        # DP_VERSION Configuration
        local new_ver
        new_ver=$(whiptail --title "DP_VERSION Configuration" \
                           --inputbox "Please enter DP version (e.g., 6.2.1):" 10 60 "${DP_VERSION}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_ver}" ]]; then
          DP_VERSION="${new_ver}"
          save_config
          whiptail --title "DP_VERSION Configuration" \
                   --msgbox "DP_VERSION has been set to ${DP_VERSION}." 8 60
        fi
        ;;

      "3")
        # ACPS Username/Password Configuration
        local user pass
        user=$(whiptail --title "ACPS Username Configuration" \
                        --inputbox "Please enter ACPS username (ID):" 10 60 "${ACPS_USERNAME}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${user}" ]]; then
          continue
        fi

        pass=$(whiptail --title "ACPS  Configuration" \
                        --passwordbox "Please enter ACPS password.\n(Password will be stored in configuration file and automatically used in STEP 09)" 10 60 "${ACPS_PASSWORD}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${pass}" ]]; then
          continue
        fi

        ACPS_USERNAME="${user}"
        ACPS_PASSWORD="${pass}"
        save_config
        whiptail --title "ACPS Username Configuration" \
                 --msgbox "ACPS_USERNAME has been set to '${ACPS_USERNAME}'." 8 70
        ;;

      "4")
        # ACPS URL
        local new_url
        new_url=$(whiptail --title "ACPS URL Configuration" \
                           --inputbox "Please enter ACPS BASE URL:" 10 70 "${ACPS_BASE_URL}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_url}" ]]; then
          ACPS_BASE_URL="${new_url}"
          save_config
          whiptail --title "ACPS URL Configuration" \
                   --msgbox "ACPS_BASE_URL has been set to '${ACPS_BASE_URL}'." 8 70
        fi
        ;;

      "5")
        break
        ;;

      *)
        ;;
    esac
  done
}



#######################################
# Configuration menu
#######################################

menu_config() {
  while true; do
    load_config

    # Determine ACPS Password display text
    local acps_password_display
    if [[ -n "${ACPS_PASSWORD:-}" ]]; then
      acps_password_display="(Configured)"
    else
      acps_password_display="(Not configured)"
    fi

    local choice
    # Disable set -e temporarily to handle whiptail cancel gracefully
    set +e
    choice=$(whiptail --title "XDR Installer - Configuration" \
                      --menu "Please select configuration to change:" \
                      22 90 9 \
                      "1" "DRY_RUN Mode: ${DRY_RUN} (1=simulation, 0=actual execution)" \
                      "2" "Sensor version: ${SENSOR_VERSION}" \
                      "3" "ACPS Username: ${ACPS_USERNAME:-<not configured>}" \
                      "4" "ACPS Password: ${acps_password_display}" \
                      "5" "ACPS URL: ${ACPS_BASE_URL}" \
                      "6" "Auto Reboot: ${ENABLE_AUTO_REBOOT} (1=active, 0=inactive)" \
                      "7" "SPAN attachment mode: ${SPAN_ATTACH_MODE} (pci/bridge)" \
                      "8" "Sensor Network Mode: ${SENSOR_NET_MODE} (bridge/nat)" \
                      "9" "Go back" \
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
        local new_dry_run
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          new_dry_run=0
        else
          new_dry_run=1
        fi
        save_config_var "DRY_RUN" "${new_dry_run}"
        whiptail_msgbox "Configuration Changed" "DRY_RUN has been set to ${new_dry_run}."
        ;;
      2)
        local new_version
        set +e
        new_version=$(whiptail_inputbox "Sensor Version Configuration" "Enter sensor version:" "${SENSOR_VERSION}")
        local input_rc=$?
        set -e
        if [[ ${input_rc} -eq 0 && -n "${new_version}" ]]; then
          save_config_var "SENSOR_VERSION" "${new_version}"
          whiptail_msgbox "Configuration Changed" "Sensor version has been set to ${new_version}."
        fi
        ;;
      3)
        local new_username
        set +e
        new_username=$(whiptail_inputbox "ACPS Username Configuration" "Enter ACPS username:" "${ACPS_USERNAME:-}")
        local input_rc=$?
        set -e
        if [[ ${input_rc} -eq 0 && -n "${new_username}" ]]; then
          save_config_var "ACPS_USERNAME" "${new_username}"
          whiptail_msgbox "Configuration Changed" "ACPS username has been changed."
        fi
        ;;
      4)
        local new_password
        set +e
        new_password=$(whiptail_passwordbox "ACPS Password Configuration" "Enter ACPS password:" "")
        local input_rc=$?
        set -e
        if [[ ${input_rc} -eq 0 && -n "${new_password}" ]]; then
          save_config_var "ACPS_PASSWORD" "${new_password}"
          whiptail_msgbox "Configuration Changed" "ACPS password has been changed."
        fi
        ;;
      5)
        local new_url
        set +e
        new_url=$(whiptail_inputbox "ACPS URL Configuration" "Enter ACPS URL:" "${ACPS_BASE_URL}")
        local input_rc=$?
        set -e
        if [[ ${input_rc} -eq 0 && -n "${new_url}" ]]; then
          save_config_var "ACPS_BASE_URL" "${new_url}"
          whiptail_msgbox "Configuration Changed" "ACPS URL has been changed."
        fi
        ;;
      6)
        local new_reboot
        if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
          new_reboot=0
        else
          new_reboot=1
        fi
        save_config_var "ENABLE_AUTO_REBOOT" "${new_reboot}"
        whiptail_msgbox "Configuration Changed" "Auto Reboot has been set to ${new_reboot}."
        ;;
      7)
        local new_mode
        set +e
        new_mode=$(whiptail --title "SPAN Attachment Mode Selection" \
                             --menu "Select SPAN NIC connection method to sensor VM:" \
                             12 70 2 \
                             "pci"    "PCI passthrough (PF direct, SR-IOV not used)" \
                             "bridge" "L2 bridge virtio NIC" \
                             3>&1 1>&2 2>&3)
        local menu_rc=$?
        set -e
        if [[ ${menu_rc} -eq 0 && -n "${new_mode}" ]]; then
          save_config_var "SPAN_ATTACH_MODE" "${new_mode}"
          whiptail_msgbox "Configuration Changed" "SPAN attachment mode has been set to ${new_mode}."
        fi
        ;;
      8)
        local new_net_mode
        set +e
        new_net_mode=$(whiptail --title "Sensor Network Mode Configuration" \
                             --menu "Please select Sensor Network Mode:" \
                             15 70 2 \
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
      9)
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

      if [[ "${LAST_COMPLETED_STEP}" == "${step_id}" ]]; then
        status="Completed"
      elif [[ -n "${LAST_COMPLETED_STEP}" ]]; then
        local last_idx
        last_idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
        if [[ ${last_idx} -ge 0 && ${i} -le ${last_idx} ]]; then
          status="Completed"
        fi
      fi

      # Use STEP_IDS as menu tags instead of numeric indices
      menu_items+=("${step_id}" "${step_name} [${status}]")
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
      # Find the index of the selected step_id
      local idx
      local found=0
      for ((idx=0; idx<NUM_STEPS; idx++)); do
        if [[ "${STEP_IDS[$idx]}" == "${choice}" ]]; then
          found=1
          # Disable set -e temporarily to handle run_step errors gracefully
          set +e
          run_step "${idx}"
          local step_rc=$?
          set -e
          break
        fi
      done
      if [[ ${found} -eq 0 ]]; then
        log "ERROR: Selected step_id '${choice}' not found in STEP_IDS"
        continue
      fi
      # run_step always returns 0, but check anyway for safety
      if [[ ${step_rc} -ne 0 ]]; then
        log "WARNING: run_step returned non-zero exit code: ${step_rc}"
      fi
    else
      log "WARNING: Invalid choice selected: ${choice}"
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
    if ! run_step "${i}"; then
      whiptail_msgbox "Auto Execution Abort" "STEP ${STEP_IDS[$i]} execution failed.\n\nAuto execution aborted."
      break
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
    # 2. SR-IOV / NIC Verification
    ##################################################
    echo "## 2. SR-IOV / NIC Verification"
    echo
    echo "\$ ip link show"
    ip link show 2>&1 || echo "[WARN] ip link show execution failed"
    echo

    echo "\$ lspci | grep -i ethernet"
    lspci | grep -i ethernet 2>&1 || echo "[WARN] lspci ethernet information query failed"
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

    echo "\$ systemctl status ntpsec --no-pager"
    systemctl status ntpsec --no-pager 2>&1 || echo "[INFO] ntpsec service is not installed or not activated."
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

  show_textbox "XDR Sensor Full Configuration Verification" "${tmp_file}"

  # Clean up temporary file
  rm -f "${tmp_file}"
  
  # Re-enable set -e
  set -e
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
│      • SENSOR_NET_MODE: bridge or nat                            │
│      • SPAN_ATTACH_MODE: pci or bridge                        │
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
   STEP 09 → PCI passthrough + CPU affinity (SPAN NIC)
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
  → Menu 2 → STEP 08 (Sensor VM deployment)
  → VM resources (vCPU, memory) are automatically calculated

• Update Sensor Image:
  → Menu 2 → STEP 07 (Sensor LV + image download)
  → New image will be downloaded and deployed

• Network Configuration Change:
  → Menu 2 → STEP 01 (Hardware selection) → STEP 03 (Network)
  → Network mode changes require re-running from STEP 01

• SPAN NIC Reconfiguration:
  → Menu 2 → STEP 01 (SPAN NIC selection) → STEP 09 (PCI passthrough)
  → SPAN attachment mode can be changed in menu 3

• Change Network Mode (bridge/nat):
  → Menu 3 → Update SENSOR_NET_MODE
  → Menu 2 → STEP 01 → STEP 08 (to apply new network mode)


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
  - Minimum free space: 100GB recommended (80GB minimum)
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
• SENSOR_NET_MODE: bridge (default) or nat
  - Bridge: L2 bridge based (recommended for most cases)
  - NAT: virbr0 NAT network based
• Changes require re-running STEP 01 and STEP 08

SPAN Attachment Mode:
────────────────────────────────────────────────────────────
• SPAN_ATTACH_MODE: pci (recommended) or bridge
  - PCI: Direct PCI passthrough (best performance)
  - Bridge: L2 bridge virtio NIC
• PCI mode requires IOMMU enabled in BIOS
• Changes require re-running STEP 01 and STEP 09

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

═══════════════════════════════════════════════════════════════'

  # Save content to temporary file and display with show_textbox
  local tmp_help_file="/tmp/xdr_sensor_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR Sensor Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}

# in Execution
main_menu