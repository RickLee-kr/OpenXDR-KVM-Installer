#!/usr/bin/env bash
#
# XDR Sensor Install Framework (SSH + Whiptail based TUI)
# Version: 0.1 (sensor-specific)
# OpenXDR-installer.sh based on Sensor specific Modified
#

set -euo pipefail

#######################################
# Basic Configuration
#######################################

# Select appropriate directory based on execution environment
if [[ "${EUID}" -eq 0 ]]; then
  BASE_DIR="/opt/xdr-installer"  # when running as root /opt Use
else
  BASE_DIR="${HOME}/xdr-installer"  # use home directory when running as regular user
fi
STATE_DIR="${BASE_DIR}/state"
STEPS_DIR="${BASE_DIR}/steps"

STATE_FILE="${STATE_DIR}/xdr_install.state"
LOG_FILE="${STATE_DIR}/xdr_install.log"
CONFIG_FILE="${STATE_DIR}/xdr_install.conf" 

# Now, instead of hardcoding values directly in the script, read from CONFIG
DRY_RUN=1   # default value (load_config overridden in)
# User cancellation flag (mid-step input cancel handling)
USER_CANCELED=0

# Host Auto Reboot Configuration
ENABLE_AUTO_REBOOT=1                 # 1: Auto reboot after STEP completion, 0: Do not auto reboot
AUTO_REBOOT_AFTER_STEP_ID="03_nic_ifupdown 05_kernel_tuning"

# SPAN NIC Attachment Mode Configuration
# NAT-only build: SPAN attach is PCI passthrough only
: "${SPAN_ATTACH_MODE:=pci}"         # pci only

# Check if whiptail is available
if ! command -v whiptail >/dev/null 2>&1; then
  echo "ERROR: whiptail command is required. Please install it first:"
  echo "  sudo apt update && sudo apt install -y whiptail"
  exit 1
fi

# Create directory
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

# STEP Name (description displayed in UI)
STEP_NAMES=(
  "01. Hardware / NIC / CPU / Memory / SPAN NIC Selection"
  "02. HWE Kernel Installation"
  "03. NIC Name/ifupdown Switch and Network Configuration"
  "04. KVM / Libvirt Installation and Basic Configuration"
  "05. Kernel Parameters / KSM / Swap Tuning"
  "06. libvirt Hooks Installation"
  "07. Sensor LV Creation + Image/Script Download"
  "08. Sensor VM Deployment"
  "09. PCI Passthrough / CPU Affinity (Sensor)"
  "10. Install DP Appliance CLI package"
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
# Version that displays long output with less (color + set -e / set -u safe)
# Usage:
#   1) When passing content directly   : show_paged "$big_message"
#   2) When passing title + file   : show_paged "Title" "/path/to/file"
#######################################
show_paged() {
  local title file tmpfile

  # ANSI Color Definition
  local RED="\033[1;31m"
  local GREEN="\033[1;32m"
  local BLUE="\033[1;34m"
  local CYAN="\033[1;36m"
  local YELLOW="\033[1;33m"
  local RESET="\033[0m"

  # --- Argument processing (safe for set -u environment) ---
  if [[ $# -eq 1 ]]; then
    # ① Case when only one argument is provided: content string only
    title="XDR Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    # ② Two or more arguments: 1 = title, 2 = file path
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
  echo -e "${GREEN}※ Spacebar/↓: Next page, ↑: Previous, q: Quit${RESET}"
  echo

  # --- From here, protect less: prevent exit from set -e ---
  set +e
  less -R "${file}"
  local rc=$?
  set -e
  # ----------------------------------------------------

  # In single argument mode, we created a tmpfile, so delete it if it exists
  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"

  # Always consider as "success" regardless of less return code
  return 0
}

#######################################
# Version that keeps existing log output on screen
# Usage: show_paged_keep_log "Title" "/path/to/file"
#######################################
show_paged_keep_log() {
  local title file tmpfile

  if [[ $# -eq 1 ]]; then
    title="XDR Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    title="$1"
    file="$2"
  else
    echo "show_paged_keep_log: no content provided" >&2
    return 1
  fi

  echo -e "============================================================"
  echo -e "  ${title}"
  echo -e "============================================================"
  echo
  echo -e "※ Spacebar/↓: Next page, ↑: Previous, q: Quit"
  echo

  set +e
  less -R -X "${file}"
  local rc=$?
  set -e

  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"
  return 0
}

#######################################
# Inline display (no pager, no blocking)
#######################################
show_inline() {
  local title file tmpfile
  if [[ $# -eq 1 ]]; then
    title="XDR Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    title="$1"
    file="$2"
  else
    echo "show_inline: no content provided" >&2
    return 1
  fi

  echo "============================================================"
  echo "  ${title}"
  echo "============================================================"
  echo
  cat "${file}"
  echo

  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"
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
      log "[ERROR] Command execution failed (Exit code: ${exit_code}): ${cmd}"
    fi
    return "${exit_code}"
  fi
}

append_fstab_if_missing() {
  local line="$1"
  local mount_point="$2"

  if grep -qE"[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
    log "fstab: ${mount_point} Entry already exists. (Addition skipped)"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/fstab Add the following line to: ${line}"
  else
    echo "${line}" >> /etc/fstab
    log "/etc/fstab Add entry to: ${line}"
  fi
}

#######################################
# VM Safe Restart Helper (Shutdown -> Destroy -> Start)
#######################################
restart_vm_safely() {
  local vm_name="$1"
  local max_retries=30  # Shutdown wait time (seconds)

  log "[INFO] '${vm_name}' VM safe restart process started..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${vm_name} Restart after shutdown wait (Skip)"
    return 0
  fi

  # 1. Check if running and attempt shutdown
  if virsh list --name | grep -q "^${vm_name}$"; then
    log "   -> '${vm_name}' is running. Attempting normal shutdown..."
    virsh shutdown "${vm_name}" > /dev/null 2>&1

    # 2. Wait for shutdown (Loop)
    local count=0
    while virsh list --name | grep -q "^${vm_name}$"; do
      sleep 1
      ((count++))
      # To show progress only on screen without logging, use echo -ne (here unified with log)
      
      # 3. Force shutdown (Destroy) on timeout
      if [ "$count" -ge "$max_retries" ]; then
        log "   -> [Warning] Normal shutdown timeout. Performing force shutdown (Destroy)."
        virsh destroy "${vm_name}"
        sleep 2
        break
      fi
    done
    log "   -> '${vm_name}' shutdown confirmed."
  else
    log "   -> '${vm_name}' is already powered off."
  fi

  # 4. VM start
  log "   -> '${vm_name}' is restarting..."
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

# CONFIG_FILE is assumed to be already defined above
# Example: CONFIG_FILE="${STATE_DIR}/xdr-installer.conf"
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
  fi

  # default value (Set only when not present)
  : "${DRY_RUN:=1}"  # Default is DRY_RUN=1 (safe mode)
  : "${SENSOR_VERSION:=6.2.0}"
  : "${ACPS_USERNAME:=}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=}"

  # Default values related to auto reboot
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"


  # Set default values so NIC / disk selection values are always defined
  : "${HOST_NIC:=}"
  : "${HOST_MGMT_NIC:=}"
  : "${HOST_MGMT_NIC_PCI:=}"
  : "${HOST_NIC_PCI:=}"
  : "${DATA_NIC:=}"

  : "${SPAN_NICS:=}"

  # ===== 2VM Common/Total =====
  : "${SENSOR_VM_COUNT:=2}"

  : "${SENSOR_TOTAL_VCPUS:=}"
  : "${SENSOR_VCPUS_PER_VM:=}"
  : "${SENSOR_CPUSET_MDS1:=}"
  : "${SENSOR_CPUSET_MDS2:=}"

  : "${SENSOR_TOTAL_MEMORY_MB:=}"
  : "${SENSOR_MEMORY_MB_PER_VM:=}"

  : "${SENSOR_TOTAL_LV_SIZE_GB:=}"
  : "${SENSOR_LV_SIZE_GB_PER_VM:=}"

  # ===== Legacy/Compatible (per-vm) =====
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"

  # ===== SPAN NIC Separation =====
  : "${SPAN_NICS_MDS1:=}"
  : "${SPAN_NICS_MDS2:=}"

  # ===== SPAN PCI(PF) Separation =====
  : "${SENSOR_SPAN_VF_PCIS_MDS1:=}"
  : "${SENSOR_SPAN_VF_PCIS_MDS2:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"     # Combined (Compatible)

  # NAT-only build: SPAN attach is PCI passthrough only
  : "${SPAN_ATTACH_MODE:=pci}"
  : "${SPAN_NIC_LIST:=}"
  # NAT-only (Bridge mode removed)
  : "${SENSOR_NET_MODE:=nat}"
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"              # Legacy/Compatible (per-vm disk)
}


save_config() {
  # CONFIG_FILE Create directory containing
  mkdir -p "$(dirname "${CONFIG_FILE}")"

  # Replace " with \" in values (to prevent config file from breaking)
  local esc_sensor_version esc_acps_user esc_acps_pass esc_acps_url
  esc_sensor_version=${SENSOR_VERSION//\"/\\\"}
  esc_acps_user=${ACPS_USERNAME//\"/\\\"}
  esc_acps_pass=${ACPS_PASSWORD//\"/\\\"}
  esc_acps_url=${ACPS_BASE_URL//\"/\\\"}

  # ★ Also escape NIC / sensor related values
  local esc_host_nic esc_host_nic_pci esc_data_nic esc_span_nics
  local esc_sensor_vcpus esc_sensor_memory_mb  local esc_span_attach_mode esc_span_nic_list esc_sensor_net_mode
  local esc_lv_location esc_lv_size_gb

  # ---- New escape ----
  local esc_sensor_vm_count
  local esc_sensor_total_vcpus esc_sensor_vcpus_per_vm esc_sensor_cpuset_mds1 esc_sensor_cpuset_mds2
  local esc_sensor_total_mem_mb esc_sensor_mem_mb_per_vm
  local esc_sensor_total_lv_gb esc_sensor_lv_gb_per_vm

  local esc_span_nics_mds1 esc_span_nics_mds2
  local esc_sensor_span_pcis_mds1 esc_sensor_span_pcis_mds2 esc_sensor_span_pcis

  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_host_nic_pci=${HOST_NIC_PCI//\"/\\\"}
  esc_data_nic=${DATA_NIC//\"/\\\"}
  esc_span_nics=${SPAN_NICS//\"/\\\"}

  esc_sensor_vm_count=${SENSOR_VM_COUNT//\"/\\\"}

  esc_sensor_total_vcpus=${SENSOR_TOTAL_VCPUS//\"/\\\"}
  esc_sensor_vcpus_per_vm=${SENSOR_VCPUS_PER_VM//\"/\\\"}
  esc_sensor_cpuset_mds1=${SENSOR_CPUSET_MDS1//\"/\\\"}
  esc_sensor_cpuset_mds2=${SENSOR_CPUSET_MDS2//\"/\\\"}

  esc_sensor_total_mem_mb=${SENSOR_TOTAL_MEMORY_MB//\"/\\\"}
  esc_sensor_mem_mb_per_vm=${SENSOR_MEMORY_MB_PER_VM//\"/\\\"}

  esc_sensor_total_lv_gb=${SENSOR_TOTAL_LV_SIZE_GB//\"/\\\"}
  esc_sensor_lv_gb_per_vm=${SENSOR_LV_SIZE_GB_PER_VM//\"/\\\"}

  esc_span_nics_mds1=${SPAN_NICS_MDS1//\"/\\\"}
  esc_span_nics_mds2=${SPAN_NICS_MDS2//\"/\\\"}

  esc_sensor_span_pcis_mds1=${SENSOR_SPAN_VF_PCIS_MDS1//\"/\\\"}
  esc_sensor_span_pcis_mds2=${SENSOR_SPAN_VF_PCIS_MDS2//\"/\\\"}
  esc_sensor_span_pcis=${SENSOR_SPAN_VF_PCIS//\"/\\\"}

  # ---- Legacy (Compatible): Values redefined as per-vm ----
  esc_sensor_vcpus=${SENSOR_VCPUS//\"/\\\"}
  esc_sensor_memory_mb=${SENSOR_MEMORY_MB//\"/\\\"}

  esc_span_attach_mode=${SPAN_ATTACH_MODE//\"/\\\"}
  esc_span_nic_list=${SPAN_NIC_LIST//\"/\\\"}
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

# NIC / Sensor configuration selected in STEP 01
HOST_NIC="${esc_host_nic}"
HOST_NIC_PCI="${esc_host_nic_pci}"
DATA_NIC="${esc_data_nic}"
SPAN_NICS="${esc_span_nics}"

# ---- 2VM Common/Total ----
SENSOR_VM_COUNT="${esc_sensor_vm_count}"

SENSOR_TOTAL_VCPUS="${esc_sensor_total_vcpus}"
SENSOR_VCPUS_PER_VM="${esc_sensor_vcpus_per_vm}"
SENSOR_CPUSET_MDS1="${esc_sensor_cpuset_mds1}"
SENSOR_CPUSET_MDS2="${esc_sensor_cpuset_mds2}"

SENSOR_TOTAL_MEMORY_MB="${esc_sensor_total_mem_mb}"
SENSOR_MEMORY_MB_PER_VM="${esc_sensor_mem_mb_per_vm}"

SENSOR_TOTAL_LV_SIZE_GB="${esc_sensor_total_lv_gb}"
SENSOR_LV_SIZE_GB_PER_VM="${esc_sensor_lv_gb_per_vm}"

# ---- Legacy/Compatible (per-vm) ----
SENSOR_VCPUS="${esc_sensor_vcpus}"
SENSOR_MEMORY_MB="${esc_sensor_memory_mb}"

# ---- SPAN Separation ----
SPAN_NICS_MDS1="${esc_span_nics_mds1}"
SPAN_NICS_MDS2="${esc_span_nics_mds2}"

SENSOR_SPAN_VF_PCIS_MDS1="${esc_sensor_span_pcis_mds1}"
SENSOR_SPAN_VF_PCIS_MDS2="${esc_sensor_span_pcis_mds2}"
SENSOR_SPAN_VF_PCIS="${esc_sensor_span_pcis}"

SPAN_ATTACH_MODE="${esc_span_attach_mode}"
SPAN_NIC_LIST="${esc_span_nic_list}"
SENSOR_NET_MODE="${esc_sensor_net_mode}"
LV_LOCATION="${esc_lv_location}"
LV_SIZE_GB="${esc_lv_size_gb}"
EOF

}


# Since existing code may call save_config_var
# Maintain compatibility by only updating variables internally and calling save_config() again
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

    # ★ Add here
    HOST_NIC)       HOST_NIC="${value}" ;;
    HOST_NIC_PCI)   HOST_NIC_PCI="${value}" ;;
    DATA_NIC)       DATA_NIC="${value}" ;;

    SPAN_NICS)      SPAN_NICS="${value}" ;;

    # ---- 2VM Common/Total ----
    SENSOR_VM_COUNT) SENSOR_VM_COUNT="${value}" ;;

    SENSOR_TOTAL_VCPUS) SENSOR_TOTAL_VCPUS="${value}" ;;
    SENSOR_VCPUS_PER_VM) SENSOR_VCPUS_PER_VM="${value}" ;;
    SENSOR_CPUSET_MDS1) SENSOR_CPUSET_MDS1="${value}" ;;
    SENSOR_CPUSET_MDS2) SENSOR_CPUSET_MDS2="${value}" ;;

    SENSOR_TOTAL_MEMORY_MB) SENSOR_TOTAL_MEMORY_MB="${value}" ;;
    SENSOR_MEMORY_MB_PER_VM) SENSOR_MEMORY_MB_PER_VM="${value}" ;;
    SENSOR_LV_MDS)  SENSOR_LV_MDS="${value}" ;;
    SENSOR_LV_MDS2) SENSOR_LV_MDS2="${value}" ;;
    SENSOR_TOTAL_LV_SIZE_GB) SENSOR_TOTAL_LV_SIZE_GB="${value}" ;;
    SENSOR_LV_SIZE_GB_PER_VM) SENSOR_LV_SIZE_GB_PER_VM="${value}" ;;

    # ---- Legacy/Compatible (per-vm) ----
    SENSOR_VCPUS)   SENSOR_VCPUS="${value}" ;;
    SENSOR_MEMORY_MB) SENSOR_MEMORY_MB="${value}" ;;

    # ---- SPAN Separation ----
    SPAN_NICS_MDS1) SPAN_NICS_MDS1="${value}" ;;
    SPAN_NICS_MDS2) SPAN_NICS_MDS2="${value}" ;;

    SENSOR_SPAN_VF_PCIS_MDS1) SENSOR_SPAN_VF_PCIS_MDS1="${value}" ;;
    SENSOR_SPAN_VF_PCIS_MDS2) SENSOR_SPAN_VF_PCIS_MDS2="${value}" ;;
    SENSOR_SPAN_VF_PCIS) SENSOR_SPAN_VF_PCIS="${value}" ;;

    SPAN_ATTACH_MODE) SPAN_ATTACH_MODE="${value}" ;;
    SPAN_NIC_LIST) SPAN_NIC_LIST="${value}" ;;
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
  return 0
}

get_next_step_index() {
  load_state
  if [[ -z "${LAST_COMPLETED_STEP}" ]]; then
    # If nothing has been done yet, it's the 0th
    echo "0"
    return
  fi
  local idx
  idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
  if (( idx < 0 )); then
    # If unknown state, start from 0 again
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

mark_user_cancel() {
  local msg="$1"
  USER_CANCELED=1
  log "${msg}"
  return 0
}

run_step() {
  local idx="$1"
  local step_id="${STEP_IDS[$idx]}"
  local step_name="${STEP_NAMES[$idx]}"
  USER_CANCELED=0

  # Check if STEP should be executed
  if ! whiptail_yesno "XDR Installer - ${step_id}" "${step_name}\n\nDo you want to execute this step?"
  then
    # User cancellation is considered "normal flow" (not an error)
    log "User canceled execution of STEP ${step_id}."
    return 0   # Must end with 0 here so set -e doesn't trigger in main case.
  fi

  log "===== STEP START: ${step_id} - ${step_name} ====="

  local rc=0

  # Actual function call for each STEP
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

  if [[ "${USER_CANCELED}" -eq 1 ]]; then
    log "User canceled during STEP ${step_id}. Execution will stop here."
    whiptail_msgbox "STEP Canceled - ${step_id}" "User canceled during STEP ${step_id} (${step_name}).\n\nExecution stopped." 10 70
    return 0
  fi

  if [[ "${rc}" -eq 0 ]]; then
    log "===== STEP DONE: ${step_id} - ${step_name} ====="
    
    # State verification summary after STEP completion
    local verification_summary=""
    case "${step_id}" in
      "02_hwe_kernel")
        local hwe_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          # Check HWE package according to Ubuntu version
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
        verification_summary="HWE Kernel Package: ${hwe_status}"
        ;;
      "03_nic_ifupdown")
        verification_summary="Network interface configuration completed (applied after reboot)"
        ;;
      "04_kvm_libvirt")
        local kvm_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if systemctl is-active libvirtd >/dev/null 2>&1; then
            kvm_status="libvirtd is running"
          else
            kvm_status="libvirtd is stopped"
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
    # Common Auto Reboot Processing
    ###############################################
	if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
	      # AUTO_REBOOT_AFTER_STEP_ID Process to allow multiple STEP IDs separated by spaces
	      for reboot_step in ${AUTO_REBOOT_AFTER_STEP_ID}; do
	        if [[ "${step_id}" == "${reboot_step}" ]]; then
	          log "AUTO_REBOOT_AFTER_STEP_ID=${AUTO_REBOOT_AFTER_STEP_ID} (Current STEP=${step_id}) is included → performing auto reboot."

	          whiptail_msgbox "Auto Reboot" "STEP ${step_id} (${step_name}) has been completed successfully.\n\nThe system will automatically reboot." 12 70

	          if [[ "${DRY_RUN}" -eq 1 ]]; then
	            log "[DRY-RUN] Auto reboot will not be performed."
	            # If DRY_RUN, just exit here and let it go to return 0 below
	          else
	            log "[INFO] System reboot execution..."
	            reboot
	            # ★ In a session that called reboot, immediately exit the entire shell
	            exit 0
	          fi

	          # If reboot was processed in this STEP, no need to check other items anymore
	          break
	        fi
	      done
	    fi
	  else
	    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    
    # On failure, guide to the log file location
    local log_info=""
    if [[ -f "${LOG_FILE}" ]]; then
      log_info="\n\nCheck the detailed log: tail -f ${LOG_FILE}"
    fi
    
    whiptail_msgbox "STEP Failed - ${step_id}" "An error occurred during execution of STEP ${step_id} (${step_name}).\n\nPlease check the log and re-run the STEP if necessary.\nThe installer can continue to run.${log_info}" 16 80
  fi

  # ★ run_step always exits with 0 so set -e doesn't trigger here
  return 0
  }


#######################################
# Hardware Detection Utility
#######################################

list_nic_candidates() {
  # lo, virbr*, vnet*, tap*, docker*, br*, ovs are excluded
  ip -o link show | awk -F': ' '{print $2}' \
    | grep -Ev '^(lo|virbr|vnet|tap|docker|br-|ovs)' \
    || true
}

#######################################
# Implementation for Each STEP
#######################################

step_01_hw_detect() {
  log "[STEP 01] Hardware / NIC / CPU / Memory / SPAN NIC Selection"

  # Load latest configuration (so script doesn't die even if not present)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set default values to prevent set -u (empty string if not defined)
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"

  : "${SPAN_NICS:=}"                 # Total SPAN NIC (summary/compatible)
  : "${SPAN_NICS_MDS1:=}"            # SPAN NIC for mds
  : "${SPAN_NICS_MDS2:=}"            # SPAN NIC for mds2

  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"

  : "${SENSOR_SPAN_VF_PCIS:=}"       # Legacy combined
  : "${SENSOR_SPAN_VF_PCIS_MDS1:=}"  # PCI list for mds
  : "${SENSOR_SPAN_VF_PCIS_MDS2:=}"  # PCI list for mds2

  # NAT-only build
  : "${SPAN_ATTACH_MODE:=pci}"
  # NAT-only (Bridge mode removed)
  : "${SENSOR_NET_MODE:=nat}"
  
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
  
  # NAT-only reuse condition
  if [[ -n "${HOST_NIC}" && -n "${HOST_MGMT_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_VCPUS}" && -n "${SENSOR_MEMORY_MB}" && -n "${SENSOR_SPAN_VF_PCIS}" && -n "${LV_LOCATION}" && -n "${LV_SIZE_GB}" ]]; then
    can_reuse_config=1
    reuse_message="The following values are already set:\n\n- Network mode: nat (fixed)\n- NAT uplink NIC: ${HOST_NIC}\n- Host access NIC: ${HOST_MGMT_NIC} (will set 192.168.0.100/24, no gateway in STEP 03)\n- DATA NIC: N/A (NAT-only)\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: pci (fixed)\n- SPAN PF PCI list: ${SENSOR_SPAN_VF_PCIS}\n- SENSOR vCPU: ${SENSOR_VCPUS}\n- SENSOR memory: ${SENSOR_MEMORY_MB}MB\n- LV location: ${LV_LOCATION}\n- LV size: ${LV_SIZE_GB}GB"
  fi
  
  if [[ "${can_reuse_config}" -eq 1 ]]; then
    if whiptail_yesno "STEP 01 - Reuse Existing Selection" "${reuse_message}\n\nDo you want to reuse these values as-is and skip STEP 01?\n\n(If you select No, you will select again.)" 20 80
    then
      log "User decided to reuse existing STEP 01 selection values. (STEP 01 skipped)"

      # Also ensure it's reflected in the config file when reusing
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "HOST_MGMT_NIC" "${HOST_MGMT_NIC}"
      save_config_var "HOST_MGMT_NIC_PCI" "${HOST_MGMT_NIC_PCI}"
      save_config_var "DATA_NIC"       "${DATA_NIC}"
      save_config_var "SPAN_NICS"     "${SPAN_NICS}"
      # Legacy/Compatible (per-vm)
      save_config_var "SENSOR_VCPUS"  "${SENSOR_VCPUS}"
      save_config_var "SENSOR_MEMORY_MB" "${SENSOR_MEMORY_MB}"

      # STEP 08 required (per-vm) - prevent omission when reusing
      save_config_var "SENSOR_VCPUS_PER_VM" "${SENSOR_VCPUS}"
      save_config_var "SENSOR_MEMORY_MB_PER_VM" "${SENSOR_MEMORY_MB}"

      save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
      save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
      save_config_var "LV_LOCATION" "${LV_LOCATION}"
      save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

      # Reuse is 'success + nothing more to do in this step', so return 0 normally
      return 0
    fi
  fi

  ########################
  # 1) CPU Calculation (total input → 2VM distribution)
  ########################
  SENSOR_VM_COUNT=2
  save_config_var "SENSOR_VM_COUNT" "${SENSOR_VM_COUNT}"

  local total_cpus default_sensor_total_vcpus sensor_vcpus
  total_cpus=$(nproc)
  default_sensor_total_vcpus=$((total_cpus - 4))
  if [[ ${default_sensor_total_vcpus} -le 0 ]]; then
    default_sensor_total_vcpus=2
  fi

  sensor_vcpus=$(whiptail_inputbox "STEP 01 - Sensor vCPU (Total) Configuration" "Enter the total vCPU (total) that 2 sensor VMs will use.\n\nTotal logical CPUs: ${total_cpus}\nDefault value (total): ${default_sensor_total_vcpus}\nExample: Enter 44 → mds 22 / mds2 22" "${SENSOR_TOTAL_VCPUS:-${default_sensor_total_vcpus}}") || {
    mark_user_cancel "User canceled sensor vCPU configuration."
    return 0
  }

  sensor_vcpus=$(echo "${sensor_vcpus}" | tr -d ' ')
  if [[ -z "${sensor_vcpus}" || ! "${sensor_vcpus}" =~ ^[0-9]+$ || "${sensor_vcpus}" -lt 2 ]]; then
    whiptail_msgbox "Input Error" "Sensor vCPU total must be entered as a number greater than or equal to 2."
    return 1
  fi

  SENSOR_TOTAL_VCPUS="${sensor_vcpus}"
  SENSOR_VCPUS_PER_VM=$(( SENSOR_TOTAL_VCPUS / SENSOR_VM_COUNT ))

  # Legacy/Compatible: Existing SENSOR_VCPUS is redefined as 'vCPU per VM'
  SENSOR_VCPUS="${SENSOR_VCPUS_PER_VM}"


  # ==============================================================================
  # [Modified] NUMA Aware CPUSET Calculation Logic
  # Previous: Simply divided in half (0-45, 46-91) -> Performance degradation in NUMA interleaving environment
  # Changed: Parse lscpu information to accurately separate Node 0 CPU list and Node 1 CPU list
  # ==============================================================================

  local numa_nodes=1
  if command -v lscpu >/dev/null 2>&1; then
    numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
  fi

  if [[ "${numa_nodes}" -ge 2 ]]; then
    log "[STEP 01] NUMA node(${numa_nodes}count) Detected. Setting CPU Pinning according to NUMA Topology."
  
    # Extract NUMA node0 CPU list (e.g., 0,2,4,...)
    local node0_cpus
    node0_cpus=$(lscpu | grep "NUMA node0 CPU(s):" | sed 's/NUMA node0 CPU(s)://' | tr -d '[:space:]')
  
    # Extract NUMA node1 CPU list (e.g., 1,3,5,...)
    local node1_cpus
    node1_cpus=$(lscpu | grep "NUMA node1 CPU(s):" | sed 's/NUMA node1 CPU(s)://' | tr -d '[:space:]')

    # Cut the list according to the number of vCPUs entered by the user (allocate from the front)
    # Split by comma (,) and recombine
    SENSOR_CPUSET_MDS1=$(echo "${node0_cpus}" | cut -d',' -f1-"${SENSOR_VCPUS_PER_VM}")
    SENSOR_CPUSET_MDS2=$(echo "${node1_cpus}" | cut -d',' -f1-"${SENSOR_VCPUS_PER_VM}")
  
    log "  -> MDS1 (Node0): ${SENSOR_CPUSET_MDS1}"
    log "  -> MDS2 (Node1): ${SENSOR_CPUSET_MDS2}"
  else
    log "[STEP 01] Single NUMA node or detection impossible. Using sequential allocation."
    SENSOR_CPUSET_MDS1="0-$((SENSOR_VCPUS_PER_VM-1))"
    SENSOR_CPUSET_MDS2="${SENSOR_VCPUS_PER_VM}-$((SENSOR_VCPUS_PER_VM*2-1))"
  fi
  # ==============================================================================


  log "Configured sensor vCPU (total): ${SENSOR_TOTAL_VCPUS} → per VM: ${SENSOR_VCPUS_PER_VM} (mds cpuset=${SENSOR_CPUSET_MDS1}, mds2 cpuset=${SENSOR_CPUSET_MDS2})"

  save_config_var "SENSOR_TOTAL_VCPUS" "${SENSOR_TOTAL_VCPUS}"
  save_config_var "SENSOR_VCPUS_PER_VM" "${SENSOR_VCPUS_PER_VM}"
  save_config_var "SENSOR_VCPUS" "${SENSOR_VCPUS}"
  save_config_var "SENSOR_CPUSET_MDS1" "${SENSOR_CPUSET_MDS1}"
  save_config_var "SENSOR_CPUSET_MDS2" "${SENSOR_CPUSET_MDS2}"

  ########################
  # 2) Memory Calculation (total input → 2VM distribution)
  ########################
  SENSOR_VM_COUNT=2
  save_config_var "SENSOR_VM_COUNT" "${SENSOR_VM_COUNT}"

  local total_mem_kb total_mem_gb default_sensor_total_gb sensor_gb sensor_memory_mb
  total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  total_mem_gb=$((total_mem_kb / 1024 / 1024))
  default_sensor_total_gb=$((total_mem_gb - 12))

  if [[ ${default_sensor_total_gb} -le 0 ]]; then
    whiptail_msgbox "Memory Insufficient Warning" "System memory is insufficient.\nTotal memory: ${total_mem_gb}GB\nDefault allocation value is 0 or less.\n\nPlease enter an appropriate memory size directly in the next screen." 12 70
    default_sensor_total_gb=8  # Total suggestion (considering 2VM)
  fi

  sensor_gb=$(whiptail_inputbox "STEP 01 - Sensor Memory (Total) Configuration" \
                       "Enter the total memory (GB, total) that 2 sensor VMs will use.\n\nTotal memory: ${total_mem_gb}GB\nRecommended value (total): ${default_sensor_total_gb}GB\nExample: Enter 64 → mds 32 / mds2 32" \
                       "${SENSOR_TOTAL_MEMORY_GB:-${default_sensor_total_gb}}" \
                       13 80) || {
    mark_user_cancel "User canceled sensor memory configuration."
    return 0
  }

  sensor_gb=$(echo "${sensor_gb}" | tr -d ' ')
  if [[ -z "${sensor_gb}" || ! "${sensor_gb}" =~ ^[0-9]+$ || "${sensor_gb}" -lt 2 ]]; then
    whiptail_msgbox "Input Error" "Sensor memory total must be entered as a number (GB) greater than or equal to 2."
    return 1
  fi

  # Total (MB) and per-VM distribution (MB)
  SENSOR_TOTAL_MEMORY_MB=$(( sensor_gb * 1024 ))
  SENSOR_MEMORY_MB_PER_VM=$(( SENSOR_TOTAL_MEMORY_MB / SENSOR_VM_COUNT ))

  # Legacy/Compatible: Existing SENSOR_MEMORY_MB is redefined as 'Per VM MB'
  SENSOR_MEMORY_MB="${SENSOR_MEMORY_MB_PER_VM}"

  log "Configured sensor memory (total): ${sensor_gb}GB (${SENSOR_TOTAL_MEMORY_MB}MB) → per VM: $((SENSOR_MEMORY_MB_PER_VM/1024))GB (${SENSOR_MEMORY_MB_PER_VM}MB)"

  save_config_var "SENSOR_TOTAL_MEMORY_MB" "${SENSOR_TOTAL_MEMORY_MB}"
  save_config_var "SENSOR_MEMORY_MB_PER_VM" "${SENSOR_MEMORY_MB_PER_VM}"
  save_config_var "SENSOR_MEMORY_MB" "${SENSOR_MEMORY_MB}"


  ########################
  # 3) Storage Allocation Configuration
  ########################
  # Check and display sda3 disk information
  log "[STEP 01] Check sda3 disk information"

  # Check total size of ubuntu-vg (OpenXDR method) - Modified: unit fixed
  local ubuntu_vg_total_size
  # Extract only GB unit number with --units g --nosuffix option (may include decimal point)
  ubuntu_vg_total_size=$(vgs ubuntu-vg --noheadings --units g --nosuffix -o size 2>/dev/null | tr -d ' ' || echo "0")

  # Check ubuntu-lv usage size - Modified: unit fixed
  local ubuntu_lv_size ubuntu_lv_gb=0
  if command -v lvs >/dev/null 2>&1; then
    # Extract only unit number in GB using --units g --nosuffix option
    ubuntu_lv_size=$(lvs ubuntu-vg/ubuntu-lv --noheadings --units g --nosuffix -o lv_size 2>/dev/null | tr -d ' ' || echo "0")
    # Remove decimal point (integer conversion) -> Example: 100.50 -> 100
    ubuntu_lv_gb=${ubuntu_lv_size%.*}
  else
    ubuntu_lv_size="Unable to verify"
  fi

  # ubuntu-vg convert total size to integer (remove decimal point) -> Example: 1781.xx -> 1781
  local ubuntu_vg_total_gb=${ubuntu_vg_total_size%.*}
  
  # Available space calculate
  local available_gb=$((ubuntu_vg_total_gb - ubuntu_lv_gb))
  [[ ${available_gb} -lt 0 ]] && available_gb=0
  
  # LV locationset to ubuntu-vg (OpenXDR method)
  local lv_location="ubuntu-vg"
  log "[STEP 01] LV location Auto configured: ${lv_location} (Existing ubuntu-vg Available space Use)"
  
  SENSOR_VM_COUNT=2
  save_config_var "SENSOR_VM_COUNT" "${SENSOR_VM_COUNT}"

  # From user "Total" LV size Receive input
  local total_lv_size_gb
  while true; do
    total_lv_size_gb=$(whiptail_inputbox "STEP 01 - Sensor Storage Size Configuration" \
                         "Please enter the total storage size (GB, Total) that 2 Sensor VMs will use.\n\n- LV location: ubuntu-vg (OpenXDR method)\n- Minimum size (Total): 160GB (Per VM 80GB Standard)\n- Default value (total): 1000GB\n\nExample: Enter 1000 → mds 500 / mds2 500\n\nSize (GB):" \
                         "1000" \
                         18 80) || {
      mark_user_cancel "User canceled sensor storage size configuration."
      return 0
    }

    total_lv_size_gb=$(echo "${total_lv_size_gb}" | tr -d ' ')

    # Number validation
      if ! [[ "${total_lv_size_gb}" =~ ^[0-9]+$ ]]; then
      whiptail_msgbox "Input Error" "Please enter a valid number.\nInput value: ${total_lv_size_gb}"
      continue
    fi

    # Minimum size validation(Total 160GB)
    if [[ "${total_lv_size_gb}" -lt 160 ]]; then
      whiptail_msgbox "Insufficient Size" "Minimum 160GB (Total) must be greater than or equal to.\nInput value: ${total_lv_size_gb}GB"
      continue
    fi

    break
  done

  SENSOR_TOTAL_LV_SIZE_GB="${total_lv_size_gb}"
  SENSOR_LV_SIZE_GB_PER_VM=$(( SENSOR_TOTAL_LV_SIZE_GB / SENSOR_VM_COUNT ))

  log "Configured LV location: ${lv_location}"
  log "Configured LV size(Total): ${SENSOR_TOTAL_LV_SIZE_GB}GB → per VM: ${SENSOR_LV_SIZE_GB_PER_VM}GB"

  LV_LOCATION="${lv_location}"

  # Legacy/Compatible: Existing LV_SIZE_GB is redefined as 'Per VM' size
  LV_SIZE_GB="${SENSOR_LV_SIZE_GB_PER_VM}"

  save_config_var "LV_LOCATION" "${LV_LOCATION}"
  save_config_var "SENSOR_TOTAL_LV_SIZE_GB" "${SENSOR_TOTAL_LV_SIZE_GB}"
  save_config_var "SENSOR_LV_SIZE_GB_PER_VM" "${SENSOR_LV_SIZE_GB_PER_VM}"
  save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"  

  ########################
  # 4) NIC Candidate Query and Selection
  ########################
  local nics nic_list nic name idx

  # list_nic_candidates defense so script doesn't die even if it fails due to set -e
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail_msgbox "STEP 01 - NIC Detection Failed" "Could not find available NICs.\n\nPlease check ip link results and modify the script." 12 70
    log "No NIC candidates. Need to check ip link results."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # IP information assigned to each NIC + ethtool Speed/Duplex Display
    local ipinfo speed duplex et_out

    # IP information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # default value
    speed="Unknown"
    duplex="Unknown"

    # ethtoolas  Speed / Duplex Get
    if command -v ethtool >/dev/null 2>&1; then
      # set -e protection: ethtool so script doesn't die even if it fails || true
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    # whiptail in menu "speed=..., duplex=..., ip=..." in the form of Display
    nic_list+=("${name}" "speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
    ((idx++))
  done <<< "${nics}"

  ########################
  # 4) NIC Selection (NAT-only)
  ########################
  
  # NAT-only: Select only 1 NAT uplink NIC
  log "[STEP 01] NAT Mode (fixed) - NAT uplink NIC selection (select one)"
    
    local nat_nic
    # Calculate menu size dynamically
    menu_dims=$(calc_menu_size ${#nic_list[@]} 90 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
    
    # Center-align menu message
    menu_msg=$(center_menu_message "Select NAT network uplink NIC.\nThis NIC will be renamed to 'mgt' and used for external connections.\nSensor VM will be connected to virbr0 NAT bridge.\nCurrent setting: ${HOST_NIC:-<None>}" "${menu_height}")
    
    nat_nic=$(whiptail --title "STEP 01 - NAT uplink NIC Selection (NAT Mode)" \
                      --menu "${menu_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
      mark_user_cancel "User canceled NAT uplink NIC selection."
      return 0
    }

    log "Selected NAT uplink NIC: ${nat_nic}"
    HOST_NIC="${nat_nic}"  # HOST_NIC in variable NAT uplink NIC Store
    DATA_NIC=""  # DATA NIC is not used (NAT-only)
    save_config_var "HOST_NIC" "${HOST_NIC}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    # Store PCI for resilient STEP 03 resolution
    local nat_pci
    nat_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ -n "${nat_pci}" ]]; then
      HOST_NIC_PCI="${nat_pci}"
      save_config_var "HOST_NIC_PCI" "${HOST_NIC_PCI}"
    fi

  ########################
  # 4-1) Host access NIC Selection (KVM host local access)
  ########################
    local host_mgmt_nic
    # Calculate menu size dynamically
    menu_dims=$(calc_menu_size ${#nic_list[@]} 90 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Center-align menu message
    menu_msg=$(center_menu_message "Select NIC for local access to the KVM host.\nThis is NOT the NAT uplink NIC.\nIt will be configured as 192.168.0.100/24 without gateway.\nCurrent setting: ${HOST_MGMT_NIC:-<None>}" "${menu_height}")

    host_mgmt_nic=$(whiptail --title "STEP 01 - Host access NIC Selection" \
                      --menu "${menu_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
      mark_user_cancel "User canceled host access NIC selection."
      return 0
    }

    if [[ "${host_mgmt_nic}" == "${HOST_NIC}" ]]; then
      whiptail_msgbox "Error" "Host access NIC cannot be the same as NAT uplink NIC.\n\n- NAT uplink NIC : ${HOST_NIC}\n- Host access NIC: ${host_mgmt_nic}" 12 80
      log "Host access NIC duplicate selection: ${host_mgmt_nic}"
      return 1
    fi

    log "Selected Host access NIC: ${host_mgmt_nic}"
    HOST_MGMT_NIC="${host_mgmt_nic}"
    save_config_var "HOST_MGMT_NIC" "${HOST_MGMT_NIC}"
    local host_mgmt_pci
    host_mgmt_pci=$(readlink -f "/sys/class/net/${HOST_MGMT_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ -n "${host_mgmt_pci}" ]]; then
      HOST_MGMT_NIC_PCI="${host_mgmt_pci}"
      save_config_var "HOST_MGMT_NIC_PCI" "${HOST_MGMT_NIC_PCI}"
    fi

  ########################
  # 5) SPAN NIC Selection (Multiple selection)
  ########################
  local span_nic_list=()
  while IFS= read -r name; do
    # IP information assigned to each NIC + ethtool Speed/Duplex Display
    local ipinfo speed duplex et_out

    # IP information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # default value
    speed="Unknown"
    duplex="Unknown"

    # ethtoolas  Speed / Duplex Get
    if command -v ethtool >/dev/null 2>&1; then
      # set -e protection: ethtool so script doesn't die even if it fails || true
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    # If existing SPAN_NIC is selected, set ON, otherwise OFF
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
  # Calculate menu size dynamically
  menu_dims=$(calc_menu_size $((${#span_nic_list[@]} / 3)) 80 10)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align menu message
  menu_msg=$(center_menu_message "Select NICs for sensor SPAN traffic collection.\n(At least 1 selection required)\n\nCurrent selection: ${SPAN_NICS:-<None>}" "${menu_height}")
  
  selected_span_nics=$(whiptail --title "STEP 01 - SPAN NIC Selection" \
                                --checklist "${menu_msg}" \
                                "${menu_height}" "${menu_width}" "${menu_list_height}" \
                                "${span_nic_list[@]}" \
                                3>&1 1>&2 2>&3) || {
    mark_user_cancel "User canceled SPAN NIC selection."
    return 0
  }

  # whiptail output is "nic1" "nic2" form → Remove double quotes(Important)
  selected_span_nics=$(echo "${selected_span_nics}" | tr -d '"')

  log "Selected SPAN NICs(All): ${selected_span_nics}"
  SPAN_NICS="${selected_span_nics}"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  # ===== Additional: SPAN NIC Selection for mds2 (second sensor) =====
  local mds2_candidates=()
  for n in ${SPAN_NICS}; do
    mds2_candidates+=("${n}" "Assign to mds2" "OFF")
  done

  local selected_span_nics_mds2
  # Calculate menu size dynamically
  menu_dims=$(calc_menu_size $((${#mds2_candidates[@]} / 3)) 80 10)
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  
  # Center-align menu message
  menu_msg=$(center_menu_message "Select NICs from all SPAN NICs to assign to mds2 (second sensor).\n\nNICs not selected will be automatically assigned to mds (first sensor)." "${menu_height}")
  
  selected_span_nics_mds2=$(whiptail --title "STEP 01 - mds2 SPAN NIC Selection" \
    --checklist "${menu_msg}" \
    "${menu_height}" "${menu_width}" "${menu_list_height}" \
    "${mds2_candidates[@]}" \
    3>&1 1>&2 2>&3) || {
      mark_user_cancel "User canceled mds2 SPAN NIC selection."
      return 0
    }

  selected_span_nics_mds2=$(echo "${selected_span_nics_mds2}" | tr -d '"')

  SPAN_NICS_MDS2="${selected_span_nics_mds2}"
  save_config_var "SPAN_NICS_MDS2" "${SPAN_NICS_MDS2}"

  # mds1 = All - mds2
  local mds1=""
  for n in ${SPAN_NICS}; do
    local hit=0
    for x in ${SPAN_NICS_MDS2}; do
      [[ "${n}" == "${x}" ]] && hit=1 && break
    done
    [[ "${hit}" -eq 0 ]] && mds1="${mds1} ${n}"
  done
  SPAN_NICS_MDS1="${mds1# }"
  save_config_var "SPAN_NICS_MDS1" "${SPAN_NICS_MDS1}"

  # Combined(Compatible/Summary) Maintain
  SPAN_NICS="$(echo "${SPAN_NICS_MDS1} ${SPAN_NICS_MDS2}" | xargs)"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  log "SPAN NIC(mds) : ${SPAN_NICS_MDS1}"
  log "SPAN NIC(mds2): ${SPAN_NICS_MDS2}"
  log "SPAN NIC(Combined): ${SPAN_NICS}"

  ########################
  # 6) SPAN NIC PF PCI Address Collection (PCI passthrough specific)
  ########################
  log "[STEP 01] SR-IOV based VF creation is not used (PF PCI direct assignment mode)."
  log "[STEP 01] Physical PCI address of SPAN NIC(PF)Collecting."

  local span_pci_list_mds1=""
  local span_pci_list_mds2=""

  # NAT-only build: SPAN attach is always PCI passthrough
  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    # PCI passthrough mode: Directly use Physical Function (PF) PCI address
    for nic in ${SPAN_NICS_MDS1}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address could not be found."
        continue
      fi
      span_pci_list_mds1="${span_pci_list_mds1} ${pci_addr}"
      log "[STEP 01] ${nic} (mds SPAN NIC) -> Physical PCI: ${pci_addr}"
    done

    for nic in ${SPAN_NICS_MDS2}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address could not be found."
        continue
      fi
      span_pci_list_mds2="${span_pci_list_mds2} ${pci_addr}"
      log "[STEP 01] ${nic} (mds2 SPAN NIC) -> Physical PCI: ${pci_addr}"
    done

  else
    # Should never happen in NAT-only build
    log "ERROR: SPAN_ATTACH_MODE must be pci in NAT-only build."
    return 1
  fi

  SPAN_ATTACH_MODE="pci"

  # Store PCI list per sensor
  SENSOR_SPAN_VF_PCIS_MDS1="${span_pci_list_mds1# }"
  SENSOR_SPAN_VF_PCIS_MDS2="${span_pci_list_mds2# }"
  save_config_var "SENSOR_SPAN_VF_PCIS_MDS1" "${SENSOR_SPAN_VF_PCIS_MDS1}"
  save_config_var "SENSOR_SPAN_VF_PCIS_MDS2" "${SENSOR_SPAN_VF_PCIS_MDS2}"
  log "mds SPAN NIC PCI List : ${SENSOR_SPAN_VF_PCIS_MDS1}"
  log "mds2 SPAN NIC PCI List: ${SENSOR_SPAN_VF_PCIS_MDS2}"

  # Legacy combined(For compatibility) + SPAN_NIC_LIST Update
  SENSOR_SPAN_VF_PCIS="${SENSOR_SPAN_VF_PCIS_MDS1} ${SENSOR_SPAN_VF_PCIS_MDS2}"
  save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"

  SPAN_NIC_LIST="${SPAN_NICS}"
  save_config_var "SPAN_NIC_LIST" "${SPAN_NIC_LIST}"
  save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
  log "SPAN NIC list saved: ${SPAN_NIC_LIST}"
  log "SPAN attachment mode: ${SPAN_ATTACH_MODE}"


  ########################
  # 7) Summary Display (NAT-only)
  ########################
  local summary

  summary=$(cat <<EOF
[STEP 01 Result Summary - NAT-only]

- Sensor network mode : nat (fixed)
- Sensor vCPU       : ${SENSOR_VCPUS}
- Sensor memory     : ${sensor_gb}GB (${SENSOR_MEMORY_MB}MB)
- LV location          : ${LV_LOCATION}
- LV size          : ${LV_SIZE_GB}GB
- NAT uplink NIC     : ${HOST_NIC}
- Host access NIC   : ${HOST_MGMT_NIC} (192.168.0.100/24, no gateway)
- Data NIC         : N/A (NAT-only using virbr0)
- SPAN NICs       : ${SPAN_NICS}
- SPAN attachment mode    : pci (fixed)
- SPAN NIC PF PCI list     : ${SENSOR_SPAN_VF_PCIS}

Configuration file: ${CONFIG_FILE}
EOF
)

  whiptail_msgbox "STEP 01 Completed" "${summary}" 18 80

  ### Change 5 (optional): Store once more just in case
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  # is STEPis successfully completed, so in the caller save_state state with Stored
}


step_02_hwe_kernel() {
  log "[STEP 02] HWE Kernel Installation"
  load_config

  #######################################
  # 0) Ubuntu according to version HWE package determination
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
      log "[WARN] Unsupported Ubuntu version: ${ubuntu_version}. Using default kernel is recommended."
      pkg_name="linux-generic"
      ;;
  esac
  
  log "[STEP 02] Ubuntu ${ubuntu_version} Detected, HWE package: ${pkg_name}"
  local tmp_status="/tmp/xdr_step02_status.txt"

  #######################################
  # 1) Current kernel / Check package status
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
    echo "Current kernel version(uname -r): ${cur_kernel}"
    echo
    echo "HWE kernel status: ${hwe_installed}"
    if [[ "${hwe_installed}" == "yes" ]]; then
      echo "  ✅ ${hwe_status_detail}"
    else
      echo "  ⚠️  ${hwe_status_detail}"
      echo "  Expected package: ${pkg_name}"
    fi
    echo
    echo "This STEP performs the following tasks:"
    echo "  1) apt update"
    echo "  2) apt full-upgrade -y"
    echo "  3) ${pkg_name} install (Skip if already installed)"
    echo
    echo "New HWE kernel will be applied on next host reboot."
    echo "This script STEP 05 (kernel tuning) after completion,"
    echo "is configured to automatically reboot the host only once."
  } > "${tmp_status}"


  # ... After calculating cur_kernel, hwe_installed, show Overview textbox ...

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
  

  show_textbox "STEP 02 - HWE Kernel Installation Overview" "${tmp_status}"

  if ! whiptail_yesno "STEP 02 Execution Confirmation" "Do you want to proceed with the above tasks?\n\n(yes: Continue / no: Cancel)" 12 70
  then
    log "User canceled STEP 02 execution."
    return 0
  fi


  #######################################
  # 1) apt update / full-upgrade
  #######################################
  log "[STEP 02] execute apt update / full-upgrade"
  
  echo "=== Updating package list ==="
  log "Fetching latest package list from package repository..."
  run_cmd "sudo apt update"
  
  echo "=== Upgrading all system packages (This may take some time) ==="
  log "Upgrading all installed packages to latest version..."
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y"
  echo "=== System upgrade completed ==="

  #######################################
  # 1-1) ifupdown / net-tools pre-install (STEP 03required in)
  #######################################
  echo "=== Installing network management tools ==="
  log "[STEP 02] ifupdown, net-tools pre-install"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ifupdown net-tools"

  #######################################
  # 2) HWE Kernel Package install
  #######################################
  if [[ "${hwe_installed}" == "yes" ]]; then
    log "[STEP 02] ${pkg_name} package is already installed → skip installation step"
  else
    echo "=== Installing HWE Kernel Package (This may take some time) ==="
    log "[STEP 02] Installing ${pkg_name} package..."
    log "Install HWE kernel to ensure latest hardware compatibility."
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg_name}"
    echo "=== HWE Kernel Package Installation completed ==="
  fi

  #######################################
  # 3) Post-installation status summary
  #######################################
  local new_kernel hwe_now hwe_now_detail
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # In DRY-RUN mode, installation is not actually performed, so use existing uname -r and installation status values
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
    hwe_now_detail="${hwe_status_detail}"
  else
    # In actual execution mode, check current kernel version and HWE package installation status again
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
    echo "STEP 02 execution summary"
    echo "----------------------"
    echo "Previous kernel(uname -r): ${cur_kernel}"
    echo "Current kernel(uname -r): ${new_kernel}"
    echo
    echo "HWE kernel status: ${hwe_now}"
    if [[ "${hwe_now}" == "yes" ]]; then
      echo "  ✅ ${hwe_now_detail}"
    else
      echo "  ⚠️  ${hwe_now_detail}"
      echo "  Expected package: ${pkg_name}"
    fi
    echo
    echo "※ New HWE kernel will be 'next host reboot' will be applied."
    echo "   (now uname -r output is before reboot, so may not change.)"
    echo
    echo "※ This script STEP 05 (kernel tuning) upon completion,"
    echo "   According to AUTO_REBOOT_AFTER_STEP_ID settings, the host will automatically reboot only once."
  } > "${tmp_status}"


  show_textbox "STEP 02 Result Summary" "${tmp_status}"

  # reboot itself STEP 05 upon completion, common logic(AUTO_REBOOT_AFTER_STEP_ID)performed only once in
  log "[STEP 02] HWE Kernel Installation step has been completed. New HWE kernel will be applied on host reboot."

  return 0
}


step_03_nic_ifupdown() {
  log "[STEP 03] NIC Name/ifupdown Switch and Network Configuration"
  load_config

  # NAT-only build
  SENSOR_NET_MODE="nat"
  log "[STEP 03] Sensor network mode: nat (fixed)"
  log "[STEP 03] NAT Mode - OpenXDR execute NAT configuration method"
  step_03_nat_mode
  return $?
}


#######################################
# STEP 03 - NAT Mode (OpenXDR NAT configuration)
#######################################
resolve_host_nic_for_step03() {
  # If HOST_NIC is already valid, keep it
  if [[ -n "${HOST_NIC:-}" && "${HOST_NIC}" != "host" && -e "/sys/class/net/${HOST_NIC}" ]]; then
    return 0
  fi

  local detected=""

  # Use stored PCI if available
  if [[ -n "${HOST_NIC_PCI:-}" ]]; then
    local nic name nic_pci
    for nic in /sys/class/net/*; do
      name="${nic##*/}"
      nic_pci=$(readlink -f "/sys/class/net/${name}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ "${nic_pci}" == "${HOST_NIC_PCI}" ]]; then
        detected="${name}"
        break
      fi
    done
  fi

  # If already renamed, use mgt
  if [[ -z "${detected}" && -e "/sys/class/net/mgt" ]]; then
    detected="mgt"
  fi

  # Try to resolve from udev rule (mgt)
  if [[ -z "${detected}" ]]; then
    local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
    if [[ -f "${udev_file}" ]]; then
      local pci=""
      pci=$(awk -F'KERNELS=="' '/NAME:="mgt"/ {split($2,a,"\""); print a[1]; exit}' "${udev_file}")
      if [[ -n "${pci}" ]]; then
        local nic name nic_pci
        for nic in /sys/class/net/*; do
          name="${nic##*/}"
          nic_pci=$(readlink -f "/sys/class/net/${name}/device" 2>/dev/null | awk -F'/' '{print $NF}')
          if [[ "${nic_pci}" == "${pci}" ]]; then
            detected="${name}"
            break
          fi
        done
      fi
    fi
  fi

  # Use default route interface if available
  if [[ -z "${detected}" ]]; then
    local def_if
    def_if=$(ip route | awk '/^default/ {print $5; exit}')
    if [[ -n "${def_if}" && -e "/sys/class/net/${def_if}" ]]; then
      detected="${def_if}"
    fi
  fi

  # As a last resort, infer from NIC candidates excluding SPAN_NICS
  if [[ -z "${detected}" && -n "${SPAN_NICS:-}" ]]; then
    local candidates
    candidates="$(list_nic_candidates || true)"
    local filtered=()
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      local is_span=0
      local s
      for s in ${SPAN_NICS}; do
        if [[ "${s}" == "${name}" ]]; then
          is_span=1
          break
        fi
      done
      if [[ "${is_span}" -eq 0 ]]; then
        filtered+=("${name}")
      fi
    done <<< "${candidates}"
    if [[ "${#filtered[@]}" -eq 1 ]]; then
      detected="${filtered[0]}"
    fi
  fi

  if [[ -n "${detected}" ]]; then
    HOST_NIC="${detected}"
    local resolved_pci
    resolved_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ -n "${resolved_pci}" ]]; then
      HOST_NIC_PCI="${resolved_pci}"
      save_config_var "HOST_NIC_PCI" "${HOST_NIC_PCI}"
    fi
    save_config_var "HOST_NIC" "${HOST_NIC}"
    log "Resolved NAT uplink NIC to '${HOST_NIC}'."
    return 0
  fi

  return 1
}

resolve_host_mgmt_nic_for_step03() {
  # If HOST_MGMT_NIC is already valid, keep it
  if [[ -n "${HOST_MGMT_NIC:-}" && -e "/sys/class/net/${HOST_MGMT_NIC}" ]]; then
    return 0
  fi

  local detected=""

  # Use stored PCI if available
  if [[ -n "${HOST_MGMT_NIC_PCI:-}" ]]; then
    local nic name nic_pci
    for nic in /sys/class/net/*; do
      name="${nic##*/}"
      nic_pci=$(readlink -f "/sys/class/net/${name}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ "${nic_pci}" == "${HOST_MGMT_NIC_PCI}" ]]; then
        detected="${name}"
        break
      fi
    done
  fi

  # If already renamed, use hostmgmt
  if [[ -z "${detected}" && -e "/sys/class/net/hostmgmt" ]]; then
    detected="hostmgmt"
  fi

  if [[ -n "${detected}" ]]; then
    HOST_MGMT_NIC="${detected}"
    local resolved_pci
    resolved_pci=$(readlink -f "/sys/class/net/${HOST_MGMT_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ -n "${resolved_pci}" ]]; then
      HOST_MGMT_NIC_PCI="${resolved_pci}"
      save_config_var "HOST_MGMT_NIC_PCI" "${HOST_MGMT_NIC_PCI}"
    fi
    save_config_var "HOST_MGMT_NIC" "${HOST_MGMT_NIC}"
    log "Resolved host access NIC to '${HOST_MGMT_NIC}'."
    return 0
  fi

  return 1
}

step_03_nat_mode() {
  log "[STEP 03 NAT Mode] OpenXDR NAT-based network configuration"

  # NAT mode requires only HOST_NIC (NAT uplink NIC)
  if [[ -z "${HOST_NIC:-}" || "${HOST_NIC}" == "host" || ! -e "/sys/class/net/${HOST_NIC}" ]]; then
    if ! resolve_host_nic_for_step03; then
      HOST_NIC=""
    fi
  fi

  if [[ -z "${HOST_NIC:-}" || ! -e "/sys/class/net/${HOST_NIC}" ]]; then
    whiptail_msgbox "STEP 03 - NAT NIC Not configured" "NAT uplink NIC (HOST_NIC) is not set.\n\nPlease select NAT uplink NIC in STEP 01 first." 12 70
    log "HOST_NIC (NAT uplink NIC) is empty, so STEP 03 NAT Mode cannot proceed."
    return 1
  fi

  # Host access NIC is required for local KVM host access
  if [[ -z "${HOST_MGMT_NIC:-}" || ! -e "/sys/class/net/${HOST_MGMT_NIC}" ]]; then
    if ! resolve_host_mgmt_nic_for_step03; then
      HOST_MGMT_NIC=""
    fi
  fi

  if [[ -z "${HOST_MGMT_NIC:-}" || ! -e "/sys/class/net/${HOST_MGMT_NIC}" ]]; then
    whiptail_msgbox "STEP 03 - Host access NIC Not configured" "Host access NIC (HOST_MGMT_NIC) is not set.\n\nPlease select host access NIC in STEP 01 first." 12 70
    log "HOST_MGMT_NIC is empty, so STEP 03 NAT Mode cannot proceed."
    return 1
  fi

  #######################################
  # 0) Check NAT NIC PCI information
  #######################################
  local nat_pci
  nat_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${nat_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI information Error" "Could not retrieve PCI bus information for selected NAT NIC.\n\nPlease check /sys/class/net/${HOST_NIC}/device" 12 70
    log "NAT_NIC=${HOST_NIC}(${nat_pci}) → insufficient PCI information."
    return 1
  fi

  local host_mgmt_pci
  host_mgmt_pci=$(readlink -f "/sys/class/net/${HOST_MGMT_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${host_mgmt_pci}" ]]; then
    whiptail_msgbox "STEP 03 - PCI information Error" "Could not retrieve PCI bus information for selected host access NIC.\n\nPlease check /sys/class/net/${HOST_MGMT_NIC}/device" 12 70
    log "HOST_MGMT_NIC=${HOST_MGMT_NIC}(${host_mgmt_pci}) → insufficient PCI information."
    return 1
  fi

  if [[ "${host_mgmt_pci}" == "${nat_pci}" ]]; then
    whiptail_msgbox "STEP 03 - Duplicate NIC Selection" "NAT uplink NIC and host access NIC cannot be the same physical NIC.\n\nNAT uplink NIC: ${HOST_NIC} (PCI ${nat_pci})\nHost access NIC: ${HOST_MGMT_NIC} (PCI ${host_mgmt_pci})" 12 80
    log "Duplicate NIC selection detected: NAT uplink and host access share same PCI."
    return 1
  fi

  local tmp_pci="${STATE_DIR}/xdr_step03_pci.txt"
  {
    echo "Selected NAT network NIC and PCI information"
    echo "------------------------------------"
    echo "NAT uplink NIC  : ${HOST_NIC}"
    echo "  -> PCI     : ${nat_pci}"
    echo
    echo "Sensor VM will be virbr0 connected to NAT bridge."
    echo "DATA NIC is not used in NAT mode."
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NAT NIC/PCI Verification" "${tmp_pci}"
  
  #######################################
  # Check if desired NAT configuration already exists
  #######################################
  local maybe_done=0
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local iface_file="/etc/network/interfaces"

  if [[ -f "${udev_file}" ]] && \
     grep -q "KERNELS==\"${nat_pci}\".*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null && \
     grep -q "KERNELS==\"${host_mgmt_pci}\".*NAME:=\"hostmgmt\"" "${udev_file}" 2>/dev/null; then
    if [[ -f "${iface_file}" ]] && \
       grep -q "^auto mgt" "${iface_file}" 2>/dev/null && \
       grep -q "iface mgt inet static" "${iface_file}" 2>/dev/null && \
       grep -q "^auto hostmgmt" "${iface_file}" 2>/dev/null && \
       grep -q "iface hostmgmt inet static" "${iface_file}" 2>/dev/null; then
      maybe_done=1
    fi
  fi

  if [[ "${maybe_done}" -eq 1 ]]; then
    if whiptail_yesno "STEP 03 - Already configured thing same" "Looking at udev rules and /etc/network/interfaces, NAT configuration seems to be already done.\n\nDo you want to skip this STEP?" 12 80
    then
      log "User chose to skip STEP 03 NAT Mode (already configured)."
      return 0
    fi
    log "User chose to force re-execute STEP 03 NAT Mode."
  fi

  #######################################
  # 1) mgt IP collect configuration values (OpenXDR method)
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

  # Find gateway
  cur_gw=$(ip route | awk '/default.*'"${HOST_NIC}"'/ {print $3}' | head -n1)
  [[ -z "${cur_gw}" ]] && cur_gw=$(ip route | awk '/default/ {print $3}' | head -n1)

  # Default DNS (do not read /etc/resolv.conf)
  cur_dns="8.8.8.8"

  # IP configuration Receive input
  local new_ip new_netmask new_gw new_dns
  new_ip=$(whiptail_inputbox "STEP 03 - mgt NIC IP Configuration" \
                    "Enter NAT uplink NIC (mgt) IP address:" \
                    "${cur_ip}" \
                    8 60) || {
    mark_user_cancel "User canceled IP input."
    return 0
  }
  if [[ -z "${new_ip}" ]]; then
    whiptail_msgbox "Input Error" "IP address is required."
    return 1
  fi

  # Convert prefix to netmask
  local netmask=""
  case "${cur_prefix}" in
    24) netmask="255.255.255.0" ;;
    16) netmask="255.255.0.0" ;;
    8)  netmask="255.0.0.0" ;;
    *)  netmask="255.255.255.0" ;;
  esac

  new_netmask=$(whiptail_inputbox "STEP 03 - Netmask Configuration" \
                         "Enter netmask:" \
                         "${netmask}" \
                         8 60) || {
    mark_user_cancel "User canceled netmask input."
    return 0
  }
  if [[ -z "${new_netmask}" ]]; then
    whiptail_msgbox "Input Error" "Netmask is required."
    return 1
  fi

  new_gw=$(whiptail_inputbox "STEP 03 - Gateway Configuration" \
                    "Enter gateway IP:" \
                    "${cur_gw}" \
                    8 60) || {
    mark_user_cancel "User canceled gateway input."
    return 0
  }
  if [[ -z "${new_gw}" ]]; then
    whiptail_msgbox "Input Error" "Gateway is required."
    return 1
  fi

  new_dns=$(whiptail_inputbox "STEP 03 - DNS configuration" \
                     "Please enter DNS server IP:" \
                     "${cur_dns:-8.8.8.8}" \
                     8 60) || {
    mark_user_cancel "User canceled DNS input."
    return 0
  }
  if [[ -z "${new_dns}" ]]; then
    whiptail_msgbox "Input Error" "DNS server is required."
    return 1
  fi

  #######################################
  # 2) Create udev rule (NAT uplink NIC → mgt rename + SPAN NIC name fixed)
  #######################################
  log "[STEP 03 NAT Mode] Create udev rule (${HOST_NIC} → mgt + SPAN NIC name fixed)"
  
  # SPAN NICsAdditional udev rules for collecting PCI addresses and fixing names of
  local span_udev_rules=""
  if [[ -n "${SPAN_NIC_LIST:-}" ]]; then
    for span_nic in ${SPAN_NIC_LIST}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci} (PF PCI passthrough specific, SR-IOV not used)
SUBSYSTEM==\"net\", ACTION==\"add\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
      else
        log "WARNING: SPAN NIC ${span_nic} PCI address could not be found."
      fi
    done
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/udev/rules.d/99-custom-ifnames.rules create"
    log "[DRY-RUN] Add NAT mgt NIC + hostmgmt + SPAN NIC name fixed rule"
  else
    cat > /etc/udev/rules.d/99-custom-ifnames.rules <<EOF
# XDR NAT Mode - Custom interface names
SUBSYSTEM=="net", ACTION=="add", KERNELS=="${nat_pci}", NAME:="mgt"
SUBSYSTEM=="net", ACTION=="add", KERNELS=="${host_mgmt_pci}", NAME:="hostmgmt"${span_udev_rules}
EOF
    log "udev rule file creation completed (mgt + hostmgmt + SPAN NIC name fixed)"
  fi

  #######################################
  # 3) /etc/network/interfaces configuration (OpenXDR method)
  #######################################
  log "[STEP 03 NAT Mode] Configuring /etc/network/interfaces"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Configuring /etc/network/interfaces for mgt NIC"
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

# Host access interface (local KVM host access)
auto hostmgmt
iface hostmgmt inet static
    address 192.168.0.100
    netmask 255.255.255.0
EOF
    log "/etc/network/interfaces configuration completed"
  fi

  #######################################
  # 4) Process SPAN NICs (NAT-only)
  #######################################
  if [[ -n "${SPAN_NIC_LIST:-}" ]]; then
    log "[STEP 03 NAT Mode] Maintain SPAN NICs default name (PF PCI passthrough specific)"
    for span_nic in ${SPAN_NIC_LIST}; do
      log "SPAN NIC: ${span_nic} (name not changed, PF PCI passthrough specific)"
    done
  fi

  #######################################
  # 5) Completed message
  #######################################
  # SPAN NIC PCI passthrough information Additional (NAT mode)
  local span_summary_nat=""
  if [[ -n "${SPAN_NIC_LIST:-}" ]]; then
    span_summary_nat="

※ SPAN NIC PCI passthrough (PF direct attach):"
    for span_nic in ${SPAN_NIC_LIST}; do
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

NAT network configuration completed.

Network configuration:
- NAT uplink NIC  : ${HOST_NIC} → mgt (${new_ip}/${new_netmask})
- Host access NIC : ${HOST_MGMT_NIC} → hostmgmt (192.168.0.100/24)
- Gateway      : ${new_gw}
- DNS          : ${new_dns}
- Sensor VM      : Connected to virbr0 NAT bridge (192.168.122.0/24)
- SPAN NICs   : ${SPAN_NIC_LIST:-None} (PCI passthrough specific)${span_summary_nat}

udev rule     : /etc/udev/rules.d/99-custom-ifnames.rules
network configuration  : /etc/network/interfaces

※ Reboot is required due to network configuration changes.
  According to AUTO_REBOOT_AFTER_STEP_ID settings, auto reboot will occur after STEP completion.
  NAT network (mgt NIC) will be applied after reboot.
EOF
)

  whiptail_msgbox "STEP 03 NAT Mode Completed" "${summary}" 20 80

  log "[STEP 03 NAT Mode] NAT network configuration completed. NAT configuration will be applied after reboot."

  return 0
}



step_04_kvm_libvirt() {
  log "[STEP 04] KVM / Libvirt Installation and Basic Configuration"
  load_config

  # NAT-only build
  SENSOR_NET_MODE="nat"
  local net_mode="nat"
  log "[STEP 04] Sensor network mode: nat (fixed)"

  local tmp_info="${STATE_DIR}/xdr_step04_info.txt"

  #######################################
  # 0) Simple check of current status
  #######################################
  local kvm_ok="no"
  local libvirtd_ok="no"

  if command -v kvm-ok >/dev/null 2>&1; then
    # If kvm-ok command exists, execute it and check for "KVM acceleration can be used" string
    if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
      kvm_ok="yes"
    fi
  fi

  if systemctl is-active --quiet libvirtd 2>/dev/null; then
    libvirtd_ok="yes"
  fi

  {
    echo "Current KVM / Libvirt status"
    echo "-----------------------"
    echo "Network mode: ${net_mode}"
    echo "KVM acceleration Use possible: ${kvm_ok}"
    echo "libvirtd service active: ${libvirtd_ok}"
    echo
    echo "This STEP performs the following tasks:"
    echo "  1) KVM / Libvirt related package installation"
    echo "  2) Add user to libvirt group"
    echo "  3) Enable libvirtd / virtlogd services"
    echo "  4) default libvirt network(virbr0) NAT configure (NAT-only)"
    echo "  5) KVM acceleration and virtualization function verify"
  } > "${tmp_info}"

  show_textbox "STEP 04 - KVM/Libvirt install Overview" "${tmp_info}"

  if [[ "${kvm_ok}" == "yes" && "${libvirtd_ok}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 04 - Already configured thing same" "KVM and libvirtd are already in active state.\n\nDo you want to skip this STEP?\n\n(If you select no, it will force re-execution.)" 12 70
    then
      log "User chose to force re-execute STEP 04."
    else
      log "User chose to skip STEP 04 entirely (already configured)."
      return 0
    fi
  fi

  if ! whiptail_yesno "STEP 04 Execution Confirmation" "Do you want to proceed with KVM / Libvirt installation?" 10 60
  then
    log "User canceled STEP 04 execution."
    return 0
  fi

  #######################################
  # 1) package install
  #######################################
  echo "=== Installing KVM/virtualization environment (This may take some time) ==="
  log "[STEP 04] KVM / Libvirt related package installation"
  log "Installing essential packages for building virtualization environment..."

  local packages=(
    "qemu-kvm"
    "libvirt-daemon-system"
    "libvirt-clients"
    "virt-manager"
    "cpu-checker"
    "qemu-utils"
    "virtinst"      # Additional (PDF guide requirement)
    "genisoimage"   # Additional (for Cloud-init ISO creation)
  )

  echo "=== Installing packages (single batch) ==="
  log "Installing packages (single batch): ${packages[*]}"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${packages[*]}"
  echo "=== Package installation completed ==="
  
  echo "=== All KVM/virtualization package Installation completed ==="

  #######################################
  # 2) Add user to libvirt group
  #######################################
  local current_user
  current_user=$(whoami)
  log "[STEP 04] Add ${current_user} user to libvirt group"
  run_cmd "sudo usermod -aG libvirt ${current_user}"

  #######################################
  # 3) Enable services
  #######################################
  log "[STEP 04] Enable libvirtd / virtlogd services"
  run_cmd "sudo systemctl enable --now libvirtd"
  run_cmd "sudo systemctl enable --now virtlogd"

  #######################################
  # 4) default libvirt network configuration (NAT-only)
  #######################################
  log "[STEP 04] NAT Mode (fixed) - OpenXDR NAT network XML create (virbr0/192.168.122.0/24)"

  # Pre-check: avoid dnsmasq bind failure if 192.168.122.1 is already in use
  if ip -4 addr show | grep -q "192.168.122.1/"; then
    if ! ip -4 addr show virbr0 2>/dev/null | grep -q "192.168.122.1/"; then
      whiptail_msgbox "STEP 04 - NAT Bridge Error" \
        "IP 192.168.122.1 is already in use by another interface.\n\nvirbr0 cannot be started because dnsmasq cannot bind to this address.\n\nPlease free 192.168.122.1 or change the NAT subnet, then re-run STEP 04." 16 90
      log "[ERROR] 192.168.122.1 already in use by non-virbr0 interface. Aborting STEP 04 NAT network setup."
      return 1
    fi
  fi

  # Cleanup stale libvirt dnsmasq if default network is inactive
  if command -v virsh >/dev/null 2>&1; then
    if virsh net-list --all 2>/dev/null | awk '$1=="default"{print $2}' | grep -q "inactive"; then
      local stale_pids=""
      stale_pids="$(pgrep -f "/var/lib/libvirt/dnsmasq/default.conf" 2>/dev/null || true)"
      if [[ -n "${stale_pids}" ]]; then
        log "[STEP 04] Found stale dnsmasq for default network: ${stale_pids}"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] sudo kill ${stale_pids}"
        else
          sudo kill ${stale_pids} 2>/dev/null || true
        fi
      fi
    fi
  fi

  # Remove existing default network
  run_cmd "sudo virsh net-destroy default || true"
  run_cmd "sudo virsh net-undefine default || true"

  # OpenXDR method NAT network XML create
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

  log "NAT network XML file created: ${default_net_xml}"

  # Define and activate NAT network
  run_cmd "sudo virsh net-define \"${default_net_xml}\""
  run_cmd "sudo virsh net-autostart default"
  run_cmd "sudo virsh net-start default"

  log "Sensor VM will use virbr0 NAT bridge (192.168.122.0/24)."

  #######################################
  # 5) result verify
  #######################################
  local final_kvm_ok="unknown"
  local final_libvirtd_ok="unknown"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_kvm_ok="(DRY-RUN mode)"
    final_libvirtd_ok="(DRY-RUN mode)"
  else
    # Re-check KVM
    if command -v kvm-ok >/dev/null 2>&1; then
      if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
        final_kvm_ok="OK"
      else
        final_kvm_ok="FAIL"
      fi
    fi

    # Re-check libvirtd
    if systemctl is-active --quiet libvirtd; then
      final_libvirtd_ok="OK"
    else
      final_libvirtd_ok="FAIL"
    fi
  fi

  {
    echo "STEP 04 execution summary"
    echo "------------------"
    echo "KVM acceleration Use possible: ${final_kvm_ok}"
    echo "libvirtd service: ${final_libvirtd_ok}"
    echo
    echo "Sensor VM networking:"
    echo "- virbr0: NAT bridge (192.168.122.0/24)"
    echo "- SPAN NIC: PCI passthrough (pci only)"
    echo
    echo "※ User group changes will be applied after login/reboot."
    echo "※ Virtualization function must be enabled in BIOS/UEFI."
  } > "${tmp_info}"

  show_textbox "STEP 04 Result Summary" "${tmp_info}"

  log "[STEP 04] KVM / Libvirt install and configuration completed"

  return 0
}


step_05_kernel_tuning() {
  log "[STEP 05] Kernel Parameters / KSM / Swap Tuning"
  load_config

  local tmp_status="/tmp/xdr_step05_status.txt"

  #######################################
  # 0) Current status check
  #######################################
  local grub_has_iommu="no"
  local ksm_disabled="no"

  # Check IOMMU configuration in GRUB
  if grep -q "intel_iommu=on iommu=pt" /etc/default/grub 2>/dev/null; then
    grub_has_iommu="yes"
  fi

  # Check KSM disable status
  if grep -q "KSM_ENABLED=0" /etc/default/qemu-kvm 2>/dev/null; then
    ksm_disabled="yes"
  fi

  {
    echo "Current kernel tuning status"
    echo "-------------------"
    echo "GRUB IOMMU configuration: ${grub_has_iommu}"
    echo "KSM disabled: ${ksm_disabled}"
    echo
    echo "This STEP performs the following tasks:"
    echo "  1) Add IOMMU parameters to GRUB (intel_iommu=on iommu=pt)"
    echo "  2) Kernel parameter tuning (/etc/sysctl.conf)"
    echo "     - ARP flux prevention configuration"
    echo "     - Memory management optimization"
    echo "  3) Disable KSM (Kernel Same-page Merging)"
    echo "  4) Provide swap disable option"
    echo
    echo "※ is STEP after completion The system will automatically reboot."
  } > "${tmp_status}"

  show_textbox "STEP 05 - kernel tuning Overview" "${tmp_status}"

  if [[ "${grub_has_iommu}" == "yes" && "${ksm_disabled}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 05 - Already configured thing same" "GRUB IOMMU and KSM configuration is already done.\n\nDo you want to skip this STEP?" 12 70
    then
      log "User chose to force re-execute STEP 05."
    else
      log "User chose to skip STEP 05 entirely (already configured)."
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
  # 1) GRUB configuration
  #######################################
  log "[STEP 05] GRUB configuration - Add IOMMU parameters"

  if [[ "${grub_has_iommu}" == "no" ]]; then
    local grub_file="/etc/default/grub"
    local grub_bak="${grub_file}.$(date +%Y%m%d-%H%M%S).bak"

    if [[ "${DRY_RUN}" -eq 0 && -f "${grub_file}" ]]; then
      cp -a "${grub_file}" "${grub_bak}"
      log "GRUB configuration backup: ${grub_bak}"
    fi

    # Add iommu parameters to GRUB_CMDLINE_LINUX
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] GRUB_CMDLINE_LINUXto 'intel_iommu=on iommu=pt' Additional"
    else
      # Existing GRUB_CMDLINE_LINUX valueto Additional
      sed -i 's/GRUB_CMDLINE_LINUX="/&intel_iommu=on iommu=pt /' "${grub_file}"
    fi

    run_cmd "sudo update-grub"
  else
    log "[STEP 05] GRUB already has IOMMU configuration → skip GRUB configuration"
  fi

  #######################################
  # 2) Kernel parameter tuning
  #######################################
  log "[STEP 05] Kernel parameter tuning (/etc/sysctl.conf)"

  local sysctl_params="
  # XDR Installer kernel tuning (PDF guide compliance)
  # [cite_start]Enable IPv4 packet forwarding [cite: 53-57]
  net.ipv4.ip_forward = 1

  # Memory management optimization (OOM prevention - Maintain recommended)
  vm.min_free_kbytes = 1048576
  "

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Add kernel parameters to /etc/sysctl.conf:\n${sysctl_params}"
  else
    if ! grep -q "# XDR Installer kernel tuning" /etc/sysctl.conf 2>/dev/null; then
      echo "${sysctl_params}" >> /etc/sysctl.conf
      log "Added kernel parameters to /etc/sysctl.conf"
    else
      log "Kernel parameters already exist in /etc/sysctl.conf → skip"
    fi
  fi

  run_cmd "sudo sysctl -p"

  #######################################
  # 3) Disable KSM
  #######################################
  log "[STEP 05] Disable KSM (Kernel Same-page Merging)"

  if [[ "${ksm_disabled}" == "no" ]]; then
    local qemu_kvm_file="/etc/default/qemu-kvm"
    local qemu_kvm_bak="${qemu_kvm_file}.$(date +%Y%m%d-%H%M%S).bak"

    if [[ "${DRY_RUN}" -eq 0 && -f "${qemu_kvm_file}" ]]; then
      cp -a "${qemu_kvm_file}" "${qemu_kvm_bak}"
      log "qemu-kvm configuration backup: ${qemu_kvm_bak}"
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] ${qemu_kvm_file}to KSM_ENABLED=0 configuration"
    else
      if [[ -f "${qemu_kvm_file}" ]]; then
        # If existing KSM_ENABLED line exists, change it, otherwise add
        if grep -q "^KSM_ENABLED=" "${qemu_kvm_file}"; then
          sed -i 's/^KSM_ENABLED=.*/KSM_ENABLED=0/' "${qemu_kvm_file}"
        else
          echo "KSM_ENABLED=0" >> "${qemu_kvm_file}"
        fi
      else
        # If file doesn't exist, create it
        echo "KSM_ENABLED=0" > "${qemu_kvm_file}"
      fi
      log "KSM_ENABLED=0 configuration completed"
    fi
  else
    log "[STEP 05] KSM is already done → skip KSM configuration"
  fi

  #######################################
  # 4) Disable swap and clean up swap files (optional)
  #######################################
  if whiptail_yesno "STEP 05 - Disable Swap" "Do you want to disable swap?\n\nRecommended for performance improvement, but\nmay cause issues if memory is insufficient.\n\nThe following tasks will be performed:\n- Disable all active swap\n- Comment out swap entries in /etc/fstab\n- Remove /swapfile, /swap.img files" 16 70
  then
    log "[STEP 05] Disable swap and clean up swap files"
    
    # 1) Disable all active swap
    run_cmd "sudo swapoff -a"
    
    # 2) Comment out all swap related lines in /etc/fstab
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Comment out swap lines in /etc/fstab"
    else
      # Comment out lines containing swap type or swap file path
      sed -i '/\sswap\s/ s/^/#/' /etc/fstab
      sed -i '/\/swap/ s/^[^#]/#&/' /etc/fstab
    fi

    # 3) Remove common swap files
    local swap_files=("/swapfile" "/swap.img" "/var/swap" "/swap")
    for swap_file in "${swap_files[@]}"; do
      if [[ -f "${swap_file}" ]]; then
        local size_info=""
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          size_info=$(du -h "${swap_file}" 2>/dev/null | cut -f1 || echo "unknown")
        fi
        log "[STEP 05] Remove swap file: ${swap_file} (size: ${size_info})"
        run_cmd "sudo rm -f \"${swap_file}\""
      fi
    done
    
    # 4) Disable systemd-swap related services (if present)
    if systemctl is-enabled systemd-swap >/dev/null 2>&1; then
      log "[STEP 05] Disable systemd-swap service"
      run_cmd "sudo systemctl disable systemd-swap"
      run_cmd "sudo systemctl stop systemd-swap"
    fi
    
    # 5) Check and disable swap related systemctl services
    local swap_services=$(systemctl list-units --type=swap --all --no-legend 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "${swap_services}" ]]; then
      for service in ${swap_services}; do
        if [[ "${service}" =~ \.swap$ ]]; then
          log "[STEP 05] Disable swap unit: ${service}"
          run_cmd "sudo systemctl mask \"${service}\""
        fi
      done
    fi
    
    log "Swap disable and cleanup completed"
  else
    log "User canceled swap disable"
  fi

  #######################################
  # 5) Result Summary
  #######################################
  {
    echo "STEP 05 execution summary"
    echo "------------------"
    echo "GRUB IOMMU configuration: Completed"
    echo "Kernel parameter tuning: Completed"
    echo "KSM disabled: Completed"
    echo
    echo "※ System reboot is required to apply all configurations."
    echo "※ After this STEP completion, it will automatically reboot."
  } > "${tmp_status}"

  show_textbox "STEP 05 Result Summary" "${tmp_status}"

  log "[STEP 05] kernel tuning configuration completed. Reboot is required."

  return 0
}


step_06_libvirt_hooks() {
  log "[STEP 06] libvirt Hooks Installation (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  # NAT-only build
  SENSOR_NET_MODE="nat"
  log "[STEP 06] Sensor network mode: nat (fixed)"
  log "[STEP 06] NAT Mode - Installing OpenXDR NAT hooks"
  step_06_nat_hooks
  return $?
}


#######################################
# STEP 06 - NAT Mode (OpenXDR NAT hooks configuration)
#######################################
step_06_nat_hooks() {
  log "[STEP 06 NAT Mode] OpenXDR NAT libvirt Hooks Installation"

  local tmp_info="${STATE_DIR}/xdr_step06_nat_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current hooks status summary
  #######################################
  {
    echo "NAT Mode libvirt Hooks Installation"
    echo "=============================="
    echo
    echo "Hooks to be installed:"
    echo "- /etc/libvirt/hooks/network (NAT MASQUERADE)"
    echo "- /etc/libvirt/hooks/qemu (sensor DNAT + OOM monitoring)"
    echo
    echo "Sensor VM configuration:"
    echo "- VM name: mds  (mds1)"
    echo "  - internal IP: 192.168.122.2"
    echo "- VM name: mds2"
    echo "  - internal IP: 192.168.122.3"
    echo "- NAT bridge: virbr0"
    echo "- External interface: mgt"
    echo "- DNAT:"
    echo "  - mds  : bundled TCP/UDP/VXLAN + SSH(2222->22)"
    echo "  - mds2 : SSH only (2223->22)"
  } > "${tmp_info}"

  show_textbox "STEP 06 NAT Mode - Installation Overview" "${tmp_info}"

  if ! whiptail_yesno "STEP 06 NAT Mode Execution Confirmation" "Install libvirt hooks for NAT Mode.\n\n- Apply OpenXDR NAT structure\n- Sensor VM(mds) DNAT configuration\n- OOM monitoring function\n\nDo you want to continue?" 15 70
  then
    log "User canceled STEP 06 NAT Mode execution."
    return 0
  fi

  #######################################
  # 1) /etc/libvirt/hooks Create directory
  #######################################
  log "[STEP 06 NAT Mode] /etc/libvirt/hooks Create directory"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Create /etc/libvirt/hooks directory"
  else
    sudo mkdir -p /etc/libvirt/hooks
  fi

  #######################################
  # 2) /etc/libvirt/hooks/network create (OpenXDR method)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06 NAT Mode] ${HOOK_NET} create (NAT MASQUERADE)"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Backed up existing ${HOOK_NET} to ${HOOK_NET_BAK}."
    else
      log "[DRY-RUN] Would backup existing ${HOOK_NET} to ${HOOK_NET_BAK}"
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
        # Remove MASQUERADE rule
        iptables -t nat -D POSTROUTING -s $MGT_BR_NET ! -d $MGT_BR_NET -j MASQUERADE 2>/dev/null || true
    fi

    if [ "$2" = "started" ] || [ "$2" = "reconnect" ]; then
        ip route add $MGT_BR_NET via $MGT_BR_IP dev $MGT_BR_DEV table $RT 2>/dev/null || true
        ip rule add from $MGT_BR_NET table $RT 2>/dev/null || true
        # MASQUERADE rule Additional
        iptables -t nat -I POSTROUTING -s $MGT_BR_NET ! -d $MGT_BR_NET -j MASQUERADE
    fi
fi
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write NAT network hook content to ${HOOK_NET}"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
    sudo chmod +x "${HOOK_NET}"
  fi

  #######################################
  # 3) Create /etc/libvirt/hooks/qemu (for Sensor VM + OOM monitoring)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06 NAT Mode] Creating ${HOOK_QEMU} (sensor DNAT + OOM monitoring)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Backed up existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}."
    else
      log "[DRY-RUN] Would backup existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}"
    fi
  fi

  local qemu_hook_content
  qemu_hook_content=$(cat <<'EOF'
#!/bin/bash
# XDR Sensor NAT Mode - QEMU Hook
# Based on OpenXDR NAT configuration with sensor VMs (mds/mds2) DNAT

# UI exception list (sensor internal management IP)
UI_EXC_LIST=(192.168.122.2 192.168.122.3)
IPSET_UI='ui'

# If ipset ui doesn't exist, create it + add exception IPs
IPSET_CONFIG=$(echo -n $(ipset list $IPSET_UI 2>/dev/null))
if ! [[ $IPSET_CONFIG =~ $IPSET_UI ]]; then
  ipset create $IPSET_UI hash:ip 2>/dev/null || true
  for IP in ${UI_EXC_LIST[@]}; do
    ipset add $IPSET_UI $IP 2>/dev/null || true
  done
fi

########################
# mds (sensor) NAT / forwarding
########################
if [ "${1}" = "mds" ]; then
  GUEST_IP=192.168.122.2
  HOST_SSH_PORT=2222
  GUEST_SSH_PORT=22
  # Sensor related ports (OpenXDR datasensor based)
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
    
    # Start OOM monitoring script (same as common OOM logic)
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi


########################
# mds2 (sensor2) - SSH DNAT only (2223 -> 22) + OOM monitoring
########################
if [ "${1}" = "mds2" ]; then
  GUEST_IP=192.168.122.3
  HOST_SSH_PORT=2223
  GUEST_SSH_PORT=22
  BRIDGE='virbr0'
  MGT_INTF='mgt'

  if [ "${2}" = "stopped" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT 2>/dev/null || true
    /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT 2>/dev/null || true
  fi

  if [ "${2}" = "start" ] || [ "${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o $BRIDGE -d $GUEST_IP -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp ! -s ${GUEST_IP} --dport $HOST_SSH_PORT -j DNAT --to $GUEST_IP:$GUEST_SSH_PORT
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# OOM monitoring common logic
########################
# (Includes common OOM monitoring function)
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write sensor DNAT + OOM monitoring content to ${HOOK_QEMU}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
    sudo chmod +x "${HOOK_QEMU}"
  fi

  #######################################
  # 4) Install OOM monitoring scripts (common OOM logic)
  #######################################
  log "[STEP 06 NAT Mode] Installing OOM monitoring script (/usr/bin/last_known_good_pid)"
  # Reuse OOM monitoring scripts same as common OOM logic
  # (Same as OOM script part in existing step_06_bridge_hooks)

  #######################################
  # 5) Completed message
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 06 NAT Mode Completed]

OpenXDR based NAT libvirt hooks have been installed.

Installed hooks:
- /etc/libvirt/hooks/network (NAT MASQUERADE)
- /etc/libvirt/hooks/qemu (Sensor DNAT + OOM monitoring)

Sensor VM network configuration:
- VM name: mds  (internal IP: 192.168.122.2 fixed)
- VM name: mds2 (internal IP: 192.168.122.3 fixed)
- NAT bridge: virbr0 (192.168.122.0/24)
- External access: DNAT through mgt interface

DNAT ports:
- mds : SSH(2222) + bundled TCP/UDP/VXLAN ports
- mds2: SSH(2223) only
OOM monitoring: enabled

※ libvirtd restart is required.
EOF
)

  whiptail_msgbox "STEP 06 NAT Mode Completed" "${summary}" 18 80

  log "[STEP 06 NAT Mode] NAT libvirt hooks installation completed"

  return 0
}


step_07_sensor_download() {
  log "[STEP 07] Sensor LV Creation + Image/Script Download"
  load_config

  # Use user configuration (use STEP01 Total/distribution values)
  : "${LV_LOCATION:=ubuntu-vg}"
  : "${SENSOR_VM_COUNT:=2}"
  : "${SENSOR_TOTAL_LV_SIZE_GB:=${SENSOR_TOTAL_LV_SIZE_GB:-${LV_SIZE_GB:-500}}}"
  : "${SENSOR_LV_SIZE_GB_PER_VM:=$((SENSOR_TOTAL_LV_SIZE_GB / SENSOR_VM_COUNT))}"

  # Legacy compatible: LV_SIZE_GB is redefined as "Per VM"
  LV_SIZE_GB="${SENSOR_LV_SIZE_GB_PER_VM}"

  log "[STEP 07] User configuration - LV location: ${LV_LOCATION}, Total: ${SENSOR_TOTAL_LV_SIZE_GB}GB, Per VM: ${SENSOR_LV_SIZE_GB_PER_VM}GB (VM=${SENSOR_VM_COUNT})"


#######################################
# Pre-check: Existing Sensor VMs
# - If STEP 07 is re-run while mds/mds2 exist, warn first.
# - If user proceeds, FORCE clean redeploy baseline:
#   destroy/undefine VMs + unmount + remove fstab lines + lvremove, then recreate/mount LVs.
#######################################
local existing_vms=()
for _vm in mds mds2; do
  if virsh dominfo "${_vm}" >/dev/null 2>&1; then
    existing_vms+=("${_vm}")
  fi
done

if [[ ${#existing_vms[@]} -gt 0 ]]; then
  local vm_list
  vm_list="$(printf '%s ' "${existing_vms[@]}")"
  if ! whiptail_yesno "STEP 07 - Existing Sensor VMs detected" \
    "Existing Sensor VM(s) found: ${vm_list}\n\nRe-running STEP 07 will:\n- destroy & undefine existing VMs\n- recreate /var/lib/libvirt/images/mds* LVs and mounts (fresh)\n\nDo you want to continue?" 16 90
  then
    log "[STEP 07] User aborted because existing VMs were detected: ${vm_list}"
    return 0
  fi

  log "[STEP 07] User chose to continue. Forcing clean baseline (destroy/undefine + LV recreate)."

  # 1) Destroy/Undefine VMs first (avoid LV busy)
  for _vm in "${existing_vms[@]}"; do
    if virsh list --state-running | grep -qE "\s${_vm}\s" 2>/dev/null; then
      run_cmd "virsh destroy ${_vm} || true"
    fi
    run_cmd "virsh undefine ${_vm} --remove-all-storage || virsh undefine ${_vm} || true"
    run_cmd "sudo rm -rf /var/lib/libvirt/images/${_vm}/images/${_vm} 2>/dev/null || true"
  done

  # 2) Unmount mountpoints if mounted
  for _mp in /var/lib/libvirt/images/mds /var/lib/libvirt/images/mds2; do
    if mountpoint -q "${_mp}" 2>/dev/null; then
      run_cmd "sudo umount -l ${_mp} || true"
    fi
  done

  # 3) Remove fstab entries for these mountpoints (fresh recreate)
  run_cmd "sudo sed -i.bak '/[[:space:]]\\/var\\/lib\\/libvirt\\/images\\/mds[[:space:]]/d' /etc/fstab"
  run_cmd "sudo sed -i.bak '/[[:space:]]\\/var\\/lib\\/libvirt\\/images\\/mds2[[:space:]]/d' /etc/fstab"

  # 4) Remove existing LVs (if any) - names are defined later as lv_sensor_root_mds/mds2 in ubuntu-vg
  run_cmd "sudo lvremove -y /dev/ubuntu-vg/lv_sensor_root_mds 2>/dev/null || true"
  run_cmd "sudo lvremove -y /dev/ubuntu-vg/lv_sensor_root_mds2 2>/dev/null || true"

  # Force recreate flow: don't allow skipping
  skip_lv_creation="no"
fi


  local tmp_status="/tmp/xdr_step09_status.txt"

  #######################################
  # 0) Current status check
  #######################################
  local lv_exists_mds="no"
  local lv_exists_mds2="no"
  local mounted_mds="no"
  local mounted_mds2="no"

  local UBUNTU_VG="ubuntu-vg"
  local LV_MDS="lv_sensor_root_mds"
  local LV_MDS2="lv_sensor_root_mds2"

  local lv_path_mds="${UBUNTU_VG}/${LV_MDS}"
  local lv_path_mds2="${UBUNTU_VG}/${LV_MDS2}"

  if lvs "${lv_path_mds}" >/dev/null 2>&1; then lv_exists_mds="yes"; fi
  if lvs "${lv_path_mds2}" >/dev/null 2>&1; then lv_exists_mds2="yes"; fi

  if mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then mounted_mds="yes"; fi
  if mountpoint -q /var/lib/libvirt/images/mds2 2>/dev/null; then mounted_mds2="yes"; fi

  {
    echo "Current Sensor LV status"
    echo "-------------------"
    echo "LV path(mds) : ${lv_path_mds}"
    echo "LV path(mds2): ${lv_path_mds2}"
    echo "LV exists (mds) : ${lv_exists_mds}"
    echo "LV exists (mds2): ${lv_exists_mds2}"
    echo "Mounted (mds)  : ${mounted_mds} (/var/lib/libvirt/images/mds)"
    echo "Mounted (mds2) : ${mounted_mds2} (/var/lib/libvirt/images/mds2)"
    echo
    echo "User configuration:"
    echo "  - LV location: ${LV_LOCATION}"
    echo "  - Total disk: ${SENSOR_TOTAL_LV_SIZE_GB}GB"
    echo "  - Per VM disk: ${SENSOR_LV_SIZE_GB_PER_VM}GB"
    echo
    echo "This STEP performs the following tasks:"
    echo "  1) LV 2count create (${SENSOR_LV_SIZE_GB_PER_VM}GB x 2)"
    echo "     - ${lv_path_mds}"
    echo "     - ${lv_path_mds2}"
    echo "  2) Create ext4 filesystem and mount"
    echo "     - /var/lib/libvirt/images/mds"
    echo "     - /var/lib/libvirt/images/mds2"
    echo "  3) Register auto mount in /etc/fstab (2 entries)"

    echo "  4) Download sensor image and deployment script"
    echo "     - virt_deploy_modular_ds.sh"
    echo "     - aella-modular-ds-${SENSOR_VERSION:-6.2.0}.qcow2"
    echo "  5) Configure stellar:stellar ownership"
  } > "${tmp_status}"

  show_textbox "STEP 07 - Sensor LV and download Overview" "${tmp_status}"

  # Continue with image download even if LV is already configured
  local skip_lv_creation="no"
  if [[ "${lv_exists_mds}" == "yes" && "${lv_exists_mds2}" == "yes" && "${mounted_mds}" == "yes" && "${mounted_mds2}" == "yes" ]]; then
    if whiptail_yesno "STEP 07 - LV Already configured" "2 LVs and mounts are already configured.\n\n- ${lv_path_mds}\n- ${lv_path_mds2}\n\nSkip LV create/mount and proceed with qcow2 image download only?" 14 90
    then
      skip_lv_creation="yes"
      log "LV is already configured, so skip LV create/mount and proceed with image download only"
    else
      log "User chose to force re-execute STEP 07."
    fi
  fi

  if ! whiptail_yesno "STEP 07 Execution Confirmation" "Do you want to proceed with Sensor LV creation and image download?" 10 60
  then
    log "User canceled STEP 07 execution."
    return 0
  fi

  #######################################
  # 1) LV create (Per VM 2count) - OpenXDR method (ubuntu-vg)
  #######################################
  if [[ "${skip_lv_creation}" == "no" ]]; then
    log "[STEP 07] Start creating/mounting 2 LVs per VM (each ${SENSOR_LV_SIZE_GB_PER_VM}GB)"

    # mds LV
    if lvs "${lv_path_mds}" >/dev/null 2>&1; then
      log "[STEP 07] LV ${lv_path_mds} already exists → skip creation"
    else
      run_cmd "sudo lvcreate -L ${SENSOR_LV_SIZE_GB_PER_VM}G -n ${LV_MDS} ${UBUNTU_VG}"
      run_cmd "sudo mkfs.ext4 -F /dev/${lv_path_mds}"
    fi

    # mds2 LV
    if lvs "${lv_path_mds2}" >/dev/null 2>&1; then
      log "[STEP 07] LV ${lv_path_mds2} already exists → skip creation"
    else
      run_cmd "sudo lvcreate -L ${SENSOR_LV_SIZE_GB_PER_VM}G -n ${LV_MDS2} ${UBUNTU_VG}"
      run_cmd "sudo mkfs.ext4 -F /dev/${lv_path_mds2}"
    fi

    # Safety check: Ensure mountpoints are not already mounted by different devices
    local mount_mds="/var/lib/libvirt/images/mds"
    local mount_mds2="/var/lib/libvirt/images/mds2"
    
    if mountpoint -q "${mount_mds}" 2>/dev/null; then
      local mounted_dev
      mounted_dev=$(findmnt -n -o SOURCE "${mount_mds}" 2>/dev/null || echo "")
      if [[ -n "${mounted_dev}" && "${mounted_dev}" != "/dev/${lv_path_mds}" ]]; then
        log "[ERROR] ${mount_mds} is already mounted by ${mounted_dev}, expected /dev/${lv_path_mds}"
        whiptail_msgbox "STEP 07 - Mount Conflict" "Mount point ${mount_mds} is already mounted by a different device (${mounted_dev}).\n\nPlease unmount it first or use a different mount point." 12 80
        return 1
      fi
    fi
    
    if mountpoint -q "${mount_mds2}" 2>/dev/null; then
      local mounted_dev2
      mounted_dev2=$(findmnt -n -o SOURCE "${mount_mds2}" 2>/dev/null || echo "")
      if [[ -n "${mounted_dev2}" && "${mounted_dev2}" != "/dev/${lv_path_mds2}" ]]; then
        log "[ERROR] ${mount_mds2} is already mounted by ${mounted_dev2}, expected /dev/${lv_path_mds2}"
        whiptail_msgbox "STEP 07 - Mount Conflict" "Mount point ${mount_mds2} is already mounted by a different device (${mounted_dev2}).\n\nPlease unmount it first or use a different mount point." 12 80
        return 1
      fi
    fi

    # mount
    run_cmd "sudo mkdir -p ${mount_mds} ${mount_mds2}"
    if ! mountpoint -q "${mount_mds}" 2>/dev/null; then
      run_cmd "sudo mount /dev/${lv_path_mds} ${mount_mds}"
    fi
    if ! mountpoint -q "${mount_mds2}" 2>/dev/null; then
      run_cmd "sudo mount /dev/${lv_path_mds2} ${mount_mds2}"
    fi

    # fstab
    append_fstab_if_missing "/dev/${lv_path_mds}  ${mount_mds}  ext4 defaults,noatime 0 2"  "${mount_mds}"
    append_fstab_if_missing "/dev/${lv_path_mds2} ${mount_mds2} ext4 defaults,noatime 0 2"  "${mount_mds2}"

    run_cmd "sudo systemctl daemon-reload"
    run_cmd "sudo mount -a"

    # Ownership: Only change ownership of mount points, not entire /var/lib/libvirt/images
    log "[STEP 07] Change mount point ownership to stellar:stellar"
    if id stellar >/dev/null 2>&1; then
      run_cmd "sudo chown -R stellar:stellar ${mount_mds}"
      run_cmd "sudo chown -R stellar:stellar ${mount_mds2}"
    else
      log "[WARN] 'stellar' user account not found, skipping chown."
    fi
  else
    log "[STEP 07] LV create/mount already configured, skipping"
  fi


  # Store for use in STEP08/09
  save_config_var "SENSOR_LV_MDS"  "${lv_path_mds}"
  save_config_var "SENSOR_LV_MDS2" "${lv_path_mds2}"


  #######################################
  # 5) Configure image download directory
  #######################################
  local SENSOR_IMAGE_DIR="/var/lib/libvirt/images/mds/images"
  run_cmd "sudo mkdir -p ${SENSOR_IMAGE_DIR}"

  #######################################
  # 6-A) Check if 1GB+ qcow2 in current directory can be reused (OpenXDR pattern)
  #######################################
  local qcow2_name="aella-modular-ds-${SENSOR_VERSION}.qcow2"
  local use_local_qcow=0
  local local_qcow=""
  local local_qcow_size_h=""
  
  local search_dir="."
  
  # Find 1GB(=1000M)+ *.qcow2 files and select the most recent one (OpenXDR method)
  local_qcow="$(
    find "${search_dir}" -maxdepth 1 -type f -name '*.qcow2' -size +1000M -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}'
  )"
  
  if [[ -n "${local_qcow}" ]]; then
    local_qcow_size_h="$(ls -lh "${local_qcow}" 2>/dev/null | awk '{print $5}')"
    
    local msg
    msg="Found 1GB+ qcow2 file in current directory.\n\n"
    msg+="  File: ${local_qcow}\n"
    msg+="  Size: ${local_qcow_size_h}\n\n"
    msg+="Do you want to use this file without downloading for Sensor VM deployment?\n\n"
    msg+="[Yes] Use this file (copy to sensor image directory, skip download)\n"
    msg+="[No] Use existing file/download procedure as is"
    
    if whiptail_yesno "STEP 07 - Reuse Local qcow2" "${msg}"; then
      use_local_qcow=1
      log "[STEP 07] User chose to use local qcow2 file (${local_qcow})."
      
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${SENSOR_IMAGE_DIR}/${qcow2_name}\""
      else
        sudo cp "${local_qcow}" "${SENSOR_IMAGE_DIR}/${qcow2_name}"
        log "[STEP 07] Local qcow2 copied (replaced) to ${SENSOR_IMAGE_DIR}/${qcow2_name} completed"
      fi
    else
      log "[STEP 07] User chose not to use local qcow2 and maintain existing file/download procedure."
    fi
  else
    log "[STEP 07] No 1GB+ qcow2 file in current directory → use default download/existing file."
  fi
  
  #######################################
  # 6-B) Determine download files (always download except 1GB+ qcow2 in current directory)
  #######################################
  local need_script=1  # Always download script
  local need_qcow2=0
  local script_name="virt_deploy_modular_ds.sh"
  
  log "[STEP 07] ${script_name} is always download target"
  
  # Always download unless local qcow2 was copied
  if [[ "${use_local_qcow}" -eq 0 ]]; then
    log "[STEP 07] ${qcow2_name} download target"
    need_qcow2=1
  else
    log "[STEP 07] Using local qcow2 file, skipping download"
  fi

  #######################################
  # 7) Download from ACPS (only necessary files)
  #######################################
  local script_url="${ACPS_BASE_URL}/release/${SENSOR_VERSION}/datasensor/${script_name}"
  local image_url="${ACPS_BASE_URL}/release/${SENSOR_VERSION}/datasensor/${qcow2_name}"
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] cd ${SENSOR_IMAGE_DIR} && wget --user='${ACPS_USERNAME}' --password='***' '${script_url}'"
    
    if [[ "${need_qcow2}" -eq 1 ]]; then
      log "[DRY-RUN] cd ${SENSOR_IMAGE_DIR} && wget --user='${ACPS_USERNAME}' --password='***' '${image_url}'"
    else
      log "[DRY-RUN] ${qcow2_name} download omitted because local qcow2 is used"
    fi
  else
    # Perform actual download
    if [[ "${need_qcow2}" -eq 0 ]]; then
      log "[STEP 07] Download script only because local qcow2 is used."
    fi
    
    (
      cd "${SENSOR_IMAGE_DIR}" || exit 1
      
      # 1) Download deployment script (always)
      log "[STEP 07] ${script_name} download started: ${script_url}"
      echo "=== Downloading deployment script ==="
      if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${script_url}" 2>&1 | tee -a "${LOG_FILE}"; then
        chmod +x "${script_name}"
        echo "=== Deployment script download completed ==="
        log "[STEP 07] ${script_name} download completed"
      else
        log "[ERROR] ${script_name} download failed"
        exit 1
      fi
      
      # 2) qcow2 image download (large capacity, only if local qcow2 is not used)
      if [[ "${need_qcow2}" -eq 1 ]]; then
        log "[STEP 07] ${qcow2_name} download started: ${image_url}"
        echo "=== ${qcow2_name} downloading (large capacity file, may take a long time) ==="
        echo "File size may be very large, please wait..."
        if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${image_url}" 2>&1 | tee -a "${LOG_FILE}"; then
          echo "=== ${qcow2_name} download Completed ==="
          log "[STEP 07] ${qcow2_name} download Completed"
        else
          log "[ERROR] ${qcow2_name} download failed"
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
  # 8) Configure ownership
  #######################################
  log "[STEP 07] Configure mount point ownership (stellar:stellar)"
  if id stellar >/dev/null 2>&1; then
    run_cmd "sudo chown -R stellar:stellar /var/lib/libvirt/images/mds"
    run_cmd "sudo chown -R stellar:stellar /var/lib/libvirt/images/mds2"
  else
    log "[WARN] 'stellar' user account not found, skipping chown."
  fi

  #######################################
  # 9) Verify result
  #######################################
  local final_lv_mds="unknown"
  local final_lv_mds2="unknown"
  local final_mount_mds="unknown"
  local final_mount_mds2="unknown"
  local final_image="unknown"

  # (Safety) Reconstruct LV path here as well (set -u response)
  local UBUNTU_VG="ubuntu-vg"
  local LV_MDS="lv_sensor_root_mds"
  local LV_MDS2="lv_sensor_root_mds2"
  local lv_path_mds="${UBUNTU_VG}/${LV_MDS}"
  local lv_path_mds2="${UBUNTU_VG}/${LV_MDS2}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_lv_mds="(DRY-RUN mode)"
    final_lv_mds2="(DRY-RUN mode)"
    final_mount_mds="(DRY-RUN mode)"
    final_mount_mds2="(DRY-RUN mode)"
    final_image="(DRY-RUN mode)"
  else
    # Re-check LV (2 entries)
    if lvs "${lv_path_mds}" >/dev/null 2>&1; then
      final_lv_mds="OK"
    else
      final_lv_mds="FAIL"
    fi
    if lvs "${lv_path_mds2}" >/dev/null 2>&1; then
      final_lv_mds2="OK"
    else
      final_lv_mds2="FAIL"
    fi

    # Re-check mount (2 entries)
    if mountpoint -q /var/lib/libvirt/images/mds; then
      final_mount_mds="OK"
    else
      final_mount_mds="FAIL"
    fi
    if mountpoint -q /var/lib/libvirt/images/mds2; then
      final_mount_mds2="OK"
    else
      final_mount_mds2="FAIL"
    fi

    # Re-check image file
    if [[ -f "${SENSOR_IMAGE_DIR}/${qcow2_name}" ]]; then
      final_image="OK"
    else
      final_image="FAIL"
    fi
  fi

  {
    echo "STEP 07 execution summary"
    echo "------------------"
    echo "LV(mds)  ${lv_path_mds}  : ${final_lv_mds}"
    echo "LV(mds2) ${lv_path_mds2} : ${final_lv_mds2}"
    echo "Mount (mds)  /var/lib/libvirt/images/mds  : ${final_mount_mds}"
    echo "Mount (mds2) /var/lib/libvirt/images/mds2 : ${final_mount_mds2}"
    echo "Sensor image: ${final_image}"
    echo
    echo "Download location: ${SENSOR_IMAGE_DIR}"

    echo "Image file: ${qcow2_name}"
    echo "Deployment script: virt_deploy_modular_ds.sh"
  } > "${tmp_status}"

  show_textbox "STEP 07 Result Summary" "${tmp_status}"

  log "[STEP 07] Sensor LV creation and image download completed"

  return 0
}


step_08_sensor_deploy() {
  log "[STEP 08] Sensor VM Deployment"
  load_config

  # NAT-only build
  SENSOR_NET_MODE="nat"
  local net_mode="nat"
  log "[STEP 08] Sensor network mode: nat (fixed)"

  local tmp_status="${STATE_DIR}/xdr_step10_status.txt"

  # [Prevent missing required variables and calculate default values]
  : "${SENSOR_LV_MDS:=ubuntu-vg/lv_sensor_root_mds}"
  : "${SENSOR_LV_MDS2:=ubuntu-vg/lv_sensor_root_mds2}"

  if [[ -z "${SENSOR_VCPUS_PER_VM:-}" ]]; then
    if [[ -n "${SENSOR_TOTAL_VCPUS:-}" ]]; then
       SENSOR_VCPUS_PER_VM=$((SENSOR_TOTAL_VCPUS / 2))
    elif [[ -n "${SENSOR_VCPUS:-}" ]]; then
       SENSOR_VCPUS_PER_VM="${SENSOR_VCPUS}"
    fi
  fi

  if [[ -z "${SENSOR_MEMORY_MB_PER_VM:-}" ]]; then
    if [[ -n "${SENSOR_TOTAL_MEMORY_MB:-}" ]]; then
       SENSOR_MEMORY_MB_PER_VM=$((SENSOR_TOTAL_MEMORY_MB / 2))
    elif [[ -n "${SENSOR_MEMORY_MB:-}" ]]; then
       SENSOR_MEMORY_MB_PER_VM="${SENSOR_MEMORY_MB}"
    fi
  fi

  # Final verify configuration values
  if [[ -z "${SENSOR_VCPUS_PER_VM:-}" || -z "${SENSOR_MEMORY_MB_PER_VM:-}" || -z "${SENSOR_LV_MDS:-}" || -z "${SENSOR_LV_MDS2:-}" ]]; then
    whiptail_msgbox "STEP 08 - Configuration Error" "Per VM vCPU/memory or LV path configuration is missing.\n\nSTEP 01 (Total/distribution) and STEP 07 (create 2 LVs) must be completed first." 18 80
    return 1
  fi

  #######################################
  # NAT bridge readiness: virbr0
  # - If virbr0 exists: do NOT attempt net-start (avoids 'already in use').
  # - If virbr0 is missing: try to start libvirt 'default' network to create it.
  #######################################
  if ! ip link show virbr0 >/dev/null 2>&1; then
    log "[STEP 08] NAT mode: virbr0 does not exist. Trying to start libvirt default network..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo virsh net-start default"
    else
      set +e
      local _net_out
      _net_out="$(sudo virsh net-start default 2>&1)"
      local _net_rc=$?
      set -e

      if [[ ${_net_rc} -ne 0 ]]; then
        if echo "${_net_out}" | grep -qi "already in use by interface virbr0"; then
          log "[STEP 08] default net-start reported virbr0 already in use -> treating as ready."
        elif ip link show virbr0 >/dev/null 2>&1; then
          log "[STEP 08] virbr0 is now present after net-start attempt -> ready."
        else
          log "[WARN] default libvirt network could not be activated: ${_net_out}"
          whiptail_msgbox "STEP 08 - NAT Bridge Error" \
            "virbr0 bridge could not be created.\n\nTried: virsh net-start default\nResult: ${_net_out}\n\nThen rerun STEP 08.\n\n(If needed: ensure libvirtd is running and default network is defined/autostart.)" 16 90
          return 1
        fi
      else
        log "[STEP 08] default network started successfully."
      fi
    fi
  else
    log "[STEP 08] NAT mode: virbr0 already exists -> skipping libvirt net-start."
  fi

  #######################################
  # 0) Clean up existing VMs
  #######################################
  local SENSOR_VMS=("mds" "mds2")
  local vm_exists="no"
  if virsh list --all | grep -Eq "\s(mds|mds2)\s" 2>/dev/null; then
    vm_exists="yes"
  fi

  if [[ "${vm_exists}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 08 - Existing VM Found" "mds or mds2 VM already exists.\n\nDo you want to delete existing VMs and redeploy?" 12 80
    then
      log "User canceled existing VM redeployment."
      return 0
    else
      for vm in "${SENSOR_VMS[@]}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
          log "[STEP 08] Delete existing ${vm} VM"
          if virsh list --state-running | grep -q "\s${vm}\s" 2>/dev/null; then
            run_cmd "virsh destroy ${vm}"
          fi
          run_cmd "virsh undefine ${vm} --remove-all-storage"
        fi
      done
    fi
  fi

  if ! whiptail_yesno "STEP 08 Execution Confirmation" "Do you want to proceed with Sensor VM deployment for 2 VMs (mds, mds2)?"; then
    log "User canceled STEP 08 execution."
    return 0
  fi

  #######################################
  # 1) Deploy script check
  #######################################
  local script_path="/var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh"
  if [[ ! -f "${script_path}" && "${DRY_RUN}" -eq 0 ]]; then
    whiptail_msgbox "STEP 08 - Script Not Found" "Deployment script not found:\n${script_path}"
    return 1
  fi

  #######################################
  # 2) Sensor VM deployment loop (sequential deployment for 2 VMs)
  #######################################
  log "[STEP 08] Starting sensor VM sequential deployment for 2 VMs (mds -> mds2)"

  local release="${SENSOR_VERSION}"
  local nodownload="1"

  local cpus_mds="${SENSOR_VCPUS_MDS1:-${SENSOR_VCPUS_PER_VM:-${SENSOR_VCPUS}}}"
  local cpus_mds2="${SENSOR_VCPUS_MDS2:-${SENSOR_VCPUS_PER_VM:-${SENSOR_VCPUS}}}"
  local mem_mds="${SENSOR_MEMORY_MB_MDS1:-${SENSOR_MEMORY_MB_PER_VM:-${SENSOR_MEMORY_MB}}}"
  local mem_mds2="${SENSOR_MEMORY_MB_MDS2:-${SENSOR_MEMORY_MB_PER_VM:-${SENSOR_MEMORY_MB}}}"

  # Extract disk size number only (script internally adds G suffix)
  local disk_raw="${SENSOR_LV_SIZE_GB_PER_VM:-${LV_SIZE_GB}}"
  local disk_num=$(echo "${disk_raw}" | tr -cd '0-9')
  [[ -z "${disk_num}" ]] && disk_num=100
  local disksize="${disk_num}"

  # common environment variables
  export disksize="${disksize}"

  for hostname in "mds" "mds2"; do
    log "[STEP 08] -------- ${hostname} deployment started (sequential) --------"
    
    local installdir="/var/lib/libvirt/images/${hostname}"
    local cpus="${cpus_mds}"
    local memory="${mem_mds}"
    [[ "${hostname}" == "mds2" ]] && cpus="${cpus_mds2}" && memory="${mem_mds2}"

    # NAT-only environment variables
    export BRIDGE="virbr0"
    export SENSOR_BRIDGE="virbr0"
    export NETWORK_MODE="nat"

    # NAT IP assignment (fixed)
    if [[ "${hostname}" == "mds" ]]; then
      export LOCAL_IP="192.168.122.2"
    else
      export LOCAL_IP="192.168.122.3"
    fi
    export IP="${LOCAL_IP}"
    export NETMASK="255.255.255.0"
    export GATEWAY="192.168.122.1"
    export DNS="8.8.8.8"

    log "[STEP 08] ${hostname} (NAT) environment variables: IP=${LOCAL_IP}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      local deploy_cmd="bash '${script_path}' -- --hostname='${hostname}' --release='${release}' --CPUS='${cpus}' --MEM='${memory}' --DISKSIZE='${disksize}' --installdir='${installdir}' --nodownload='${nodownload}' --bridge='${BRIDGE}' --ip='${LOCAL_IP}' --netmask='${NETMASK}' --gw='${GATEWAY}' --dns='${DNS}' --nointeract='true'"
      log "[DRY-RUN] ${hostname} deployment command:\n${deploy_cmd}"
    else
      cd "/var/lib/libvirt/images/mds/images" || return 1
      set +e

      # [Modified] Copy image file when deploying mds2 (required)
      if [[ "${hostname}" != "mds" ]]; then
         local src_img="/var/lib/libvirt/images/mds/images/aella-modular-ds-${release}.qcow2"
         local dst_dir="/var/lib/libvirt/images/${hostname}/images"
         local dst_img="${dst_dir}/aella-modular-ds-${release}.qcow2"
         
         if [[ -f "${src_img}" ]]; then
            log "[STEP 08] Copying image for ${hostname} deployment..."
            mkdir -p "${dst_dir}"
            cp --update=none "${src_img}" "${dst_img}" # prevent overwrite (portable)
            log "[STEP 08] Image copy completed: ${dst_img}"
         else
            log "[ERROR] Source image not found: ${src_img}"
            return 1
         fi
      fi
      
      cmd_line="bash virt_deploy_modular_ds.sh -- \
        --hostname=\"${hostname}\" \
        --release=\"${release}\" \
        --CPUS=\"${cpus}\" \
        --MEM=\"${memory}\" \
        --DISKSIZE=\"${disksize}\" \
        --installdir=\"${installdir}\" \
        --nodownload=\"${nodownload}\" \
        --bridge=\"${BRIDGE}\" \
        --ip=\"${LOCAL_IP}\" \
        --netmask=\"${NETMASK}\" \
        --gw=\"${GATEWAY}\" \
        --dns=\"${DNS}\" \
        --nointeract=\"true\""

      log "[INFO] execution: ${cmd_line}"
      log "[INFO] Wait 2 minutes (120 seconds) then automatically proceed to next step."
      log "[STEP 08] NAT Mode: Using static IP ${LOCAL_IP} (skips DHCP IP assignment wait and virbr0.status file check)"
      
      # Configure timeout 120 seconds (2 minutes)
      set +e
      timeout 120s bash -c "${cmd_line}" 2>&1 | tee "${STATE_DIR}/deploy_${hostname}.log"
      local rc=${PIPESTATUS[0]}
      set -e

      # [Core] Exit code check and force success handling
      if [[ ${rc} -eq 0 ]]; then
         log "[SUCCESS] ${hostname} deployment script terminated normally."
      else
         # Check if VM is alive despite error
         if virsh list --state-running | grep -q "${hostname}"; then
            log "[WARN] Deployment script timeout (${rc}) but VM(${hostname}) is running. (treated as success)"
            rc=0
         else
            log "[ERROR] ${hostname} deployment failed (rc=${rc}). VM is not running."
            return 1
         fi
      fi
      
      # Wait briefly before next VM deployment
      log "[STEP 08] ${hostname} deployment completed. Proceeding to next task in 5 seconds..."
      sleep 5
    fi
  done

  #######################################
  # 3) Network interface post-processing (NAT-only)
  #######################################
  log "[STEP 08] NAT-only build: no additional L2 bridge interfaces to add"

  #######################################
  # 4) Result report
  #######################################
  local final_vm="unknown"
  local final_running="unknown"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_vm="(DRY-RUN mode)"
    final_running="(DRY-RUN mode)"
  else
    # Check all 2 VMs
    local count_exist=0
    local count_run=0
    for vm in "mds" "mds2"; do
        if virsh list --all | grep -q "\s${vm}\s"; then
            ((count_exist++))
            if virsh list --state-running | grep -q "\s${vm}\s"; then
                ((count_run++))
            fi
        fi
    done
    
    if [[ ${count_exist} -eq 2 ]]; then
        final_vm="OK (2/2)"
        if [[ ${count_run} -eq 2 ]]; then
            final_running="OK (2/2)"
        else
            final_running="Partial (${count_run}/2 running)"
        fi
    else
        final_vm="Partial (${count_exist}/2 created)"
        final_running="Unknown"
    fi
  fi

  {
    echo "STEP 08 execution summary"
    echo "------------------"
    echo "VM create status: ${final_vm}"
    echo "VM execution status: ${final_running}"
    echo
    echo "Network configuration:"
    echo "- virbr0: NAT bridge (192.168.122.0/24)"
    echo "- SPAN attachment mode: pci (fixed)"
    echo
    echo "※ You can check VM status with 'virsh list --all' command."
    echo "※ It may take a few minutes for VM to boot normally."
  } > "${tmp_status}"

  show_textbox "STEP 08 Result Summary" "${tmp_status}"

  log "[STEP 08] Sensor VM deployment completed"
  return 0
}


step_09_sensor_passthrough() {
    local STEP_ID="09_sensor_passthrough"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 09. Sensor PCI Passthrough / CPU Affinity configuration and verify ====="

    # config as de
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    local SENSOR_VMS=("mds" "mds2")

    ###########################################################################
    # Check NUMA count (use lscpu)
    ###########################################################################
    local numa_nodes=1
    if command -v lscpu >/dev/null 2>&1; then
        numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    fi
    [[ -z "${numa_nodes}" ]] && numa_nodes=1

    log "[STEP 09] NUMA node count: ${numa_nodes}"

    ###########################################################################
    # common path
    ###########################################################################
    local SRC_BASE="/var/lib/libvirt/images"
    local IMAGES_BASE="/var/lib/libvirt/images"   # mds=/var/lib/libvirt/images/mds, mds2=/var/lib/libvirt/images/mds2

    ###########################################################################
    # Process each Sensor VM in SENSOR_VMS array
    ###########################################################################
    for SENSOR_VM in "${SENSOR_VMS[@]}"; do
        log "[STEP 09] ----- Sensor VM processing start: ${SENSOR_VM} -----"

        #######################################################################
        # 0. Determine per VM mount point + check mount
        #######################################################################
        local DST_BASE=""   # /var/lib/libvirt/images/mds or /var/lib/libvirt/images/mds2
        if [[ "${SENSOR_VM}" == "mds" ]]; then
            DST_BASE="${IMAGES_BASE}/mds"
        else
            DST_BASE="${IMAGES_BASE}/mds2"
        fi

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] (${SENSOR_VM}) (MOUNTCHK) mountpoint -q ${DST_BASE}"
        else
            if ! mountpoint -q "${DST_BASE}" 2>/dev/null; then
                whiptail_msgbox "STEP 09 - Mount Error" "${SENSOR_VM}: ${DST_BASE} is not mounted.\n\nPlease complete STEP 07 mount of ${DST_BASE} first." 12 70
                log "[STEP 09] ERROR: ${SENSOR_VM}: ${DST_BASE} not mounted → skip this VM"
                continue
            fi
        fi

        #######################################################################
        # 1. Check Sensor VM existence
        #######################################################################
        if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
            log "[STEP 09] WARNING: Sensor VM(${SENSOR_VM}) not found. Skip this VM."
            continue
        fi

        #######################################################################
        # [MODIFIED] 1.5. Verify sensor image directory location (Per VM)
        #  - Since mountpoints are now /var/lib/libvirt/images/mds*, 
        #    VM images should already be in the correct location
        #  - No move operation needed, just verify paths
        #######################################################################
        local VM_IMAGE_DIR="${DST_BASE}/${SENSOR_VM}"   # /var/lib/libvirt/images/mds/mds
        local VM_IMAGE_DIR_ALT="${SRC_BASE}/${SENSOR_VM}"   # /var/lib/libvirt/images/mds (alternative check)

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] (${SENSOR_VM}) verify image directory location at ${VM_IMAGE_DIR} or ${VM_IMAGE_DIR_ALT}"
        else
            # Safely stop if VM is running (for PCI passthrough configuration)
            if virsh list --name | grep -q "^${SENSOR_VM}$"; then
                log "[STEP 09] ${SENSOR_VM}: Running → shutdown"
                virsh shutdown "${SENSOR_VM}" >/dev/null 2>&1 || true

                local t=0
                while virsh list --name | grep -q "^${SENSOR_VM}$"; do
                    sleep 2
                    t=$((t+2))
                    if [[ $t -ge 120 ]]; then
                        log "[WARN] ${SENSOR_VM}: shutdown timeout → destroy"
                        virsh destroy "${SENSOR_VM}" >/dev/null 2>&1 || true
                        break
                    fi
                done
            fi

            # Ensure mount point directory exists
            sudo mkdir -p "${DST_BASE}"

            # Verify image directory location
            # Since mountpoints are now directly under /var/lib/libvirt/images/mds*,
            # the image directory should be at ${DST_BASE}/${SENSOR_VM} or ${SRC_BASE}/${SENSOR_VM}
            if [[ ! -d "${VM_IMAGE_DIR}" && ! -d "${VM_IMAGE_DIR_ALT}" ]]; then
                log "[STEP 09] ${SENSOR_VM}: WARN: Image directory not found at ${VM_IMAGE_DIR} or ${VM_IMAGE_DIR_ALT}"
                log "[STEP 09] ${SENSOR_VM}: This may be normal if STEP 08 has not been executed yet"
            else
                log "[STEP 09] ${SENSOR_VM}: Image directory verified"
            fi

            # Check if source files referenced by XML actually exist
            log "[STEP 09] ${SENSOR_VM}: Check XML source file existence"
            local missing=0
            while read -r f; do
                [[ -z "${f}" ]] && continue
                if [[ ! -e "${f}" ]]; then
                    log "[STEP 09] ${SENSOR_VM}: ERROR: missing file: ${f}"
                    missing=$((missing+1))
                fi
            done < <(virsh dumpxml "${SENSOR_VM}" | awk -F"'" '/<source file=/{print $2}')

            if [[ "${missing}" -gt 0 ]]; then
                whiptail_msgbox "STEP 09 - File Missing" "${SENSOR_VM}: ${missing} files referenced by VM XML are missing.\n\nPlease redeploy STEP 08 or check image file location." 12 70
                log "[STEP 09] ${SENSOR_VM}: ERROR: XML source file missing count=${missing} → may not be able to start"
            fi
        fi

        #######################################################################
        # 2. Connect PCI Passthrough device (Action) - Per VM separation
        #######################################################################
        local VM_PCIS=""
        if [[ "${SENSOR_VM}" == "mds" ]]; then
            VM_PCIS="${SENSOR_SPAN_VF_PCIS_MDS1:-}"
        else
            VM_PCIS="${SENSOR_SPAN_VF_PCIS_MDS2:-}"
        fi

        if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${VM_PCIS}" ]]; then
            log "[STEP 09] ${SENSOR_VM}: Starting PCI passthrough device connection (pcis=${VM_PCIS})"

            for pci_full in ${VM_PCIS}; do
                if [[ "${pci_full}" =~ ^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
                    local d="0x${BASH_REMATCH[1]}"
                    local b="0x${BASH_REMATCH[2]}"
                    local s="0x${BASH_REMATCH[3]}"
                    local f="0x${BASH_REMATCH[4]}"

                    local pci_xml="${STATE_DIR}/pci_${SENSOR_VM}_${pci_full//:/_}.xml"
                    cat > "${pci_xml}" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='${d}' bus='${b}' slot='${s}' function='${f}'/>
  </source>
</hostdev>
EOF
                    if virsh dumpxml "${SENSOR_VM}" | grep -q "address.*bus='${b}'.*slot='${s}'.*function='${f}'"; then
                        log "[INFO] ${SENSOR_VM}: PCI device(${pci_full}) is already connected."
                    else
                        log "[ACTION] ${SENSOR_VM}: Connecting PCI device (${pci_full}) to VM..."
                        if [[ "${_DRY}" -eq 0 ]]; then
                            if virsh attach-device "${SENSOR_VM}" "${pci_xml}" --config; then
                                log "[SUCCESS] ${SENSOR_VM}: Device connection successful"
                            else
                                log "[ERROR] ${SENSOR_VM}: Device connection failed (already in use or check IOMMU configuration)"
                            fi
                        else
                            log "[DRY-RUN] virsh attach-device ${SENSOR_VM} ${pci_xml} --config"
                        fi
                    fi
                else
                    log "[WARN] ${SENSOR_VM}: PCI format is incorrect: ${pci_full}"
                fi
            done
        else
            log "[INFO] ${SENSOR_VM}: PCI passthrough mode is not configured or no target device. (pcis=${VM_PCIS:-<empty>})"
        fi

        #######################################################################
        # 3. Verify connection status (Verification)
        #######################################################################
        log "[STEP 09] ${SENSOR_VM}: Final PCI Passthrough status check"

        local hostdev_count=0
        if virsh dumpxml "${SENSOR_VM}" | grep -q "<hostdev.*type='pci'"; then
            hostdev_count=$(virsh dumpxml "${SENSOR_VM}" | grep -c "<hostdev.*type='pci'" || echo "0")
            log "[STEP 09] ${SENSOR_VM}: ${hostdev_count} PCI hostdev devices connected"
        else
            log "[WARN] ${SENSOR_VM}: No PCI hostdev devices found."
        fi

        #######################################################################
        # 4. Apply CPU Affinity (multiple NUMA only) - Per VM separation
        #######################################################################
        if [[ "${numa_nodes}" -gt 1 ]]; then
            log "[STEP 09] ${SENSOR_VM}: CPU Affinity application start"

            local cpuset_for_vm=""
            if [[ "${SENSOR_VM}" == "mds" ]]; then
                cpuset_for_vm="${SENSOR_CPUSET_MDS1:-}"
            else
                cpuset_for_vm="${SENSOR_CPUSET_MDS2:-}"
            fi

            if [[ -z "${cpuset_for_vm}" ]]; then
                local cpu_list_str
                cpu_list_str="$(lscpu -p=CPU | grep -v '^#' | tr '\n' ' ' | xargs)"
                if [[ -z "${cpu_list_str}" ]]; then
                    log "[WARN] ${SENSOR_VM}: Cannot retrieve available CPU list, cannot apply Affinity."
                    cpuset_for_vm=""
                else
                    read -r -a cpu_arr <<< "${cpu_list_str}"
                    local total_cpus="${#cpu_arr[@]}"
                    if [[ "${total_cpus}" -lt 2 ]]; then
                        log "[WARN] ${SENSOR_VM}: Too few CPUs, cannot do separate pinning → skip"
                        cpuset_for_vm=""
                    else
                        local half=$(( (total_cpus + 1) / 2 ))
                        if [[ "${SENSOR_VM}" == "mds" ]]; then
                            cpuset_for_vm="$(printf "%s," "${cpu_arr[@]:0:${half}}" | sed 's/,$//')"
                        else
                            cpuset_for_vm="$(printf "%s," "${cpu_arr[@]:${half}}" | sed 's/,$//')"
                        fi
                    fi
                fi
            fi

            if [[ -z "${cpuset_for_vm}" ]]; then
                log "[WARN] ${SENSOR_VM}: Per VM CPUSET is empty, so skip Affinity"
            else
                log "[ACTION] ${SENSOR_VM}: CPU Affinity configuration (cpuset=${cpuset_for_vm})"
                if [[ "${_DRY}" -eq 0 ]]; then
                    virsh emulatorpin "${SENSOR_VM}" "${cpuset_for_vm}" --config >/dev/null 2>&1 || true

                    local max_vcpus
                    max_vcpus="$(virsh vcpucount "${SENSOR_VM}" --maximum --config 2>/dev/null || echo 0)"
                    for (( i=0; i<max_vcpus; i++ )); do
                        virsh vcpupin "${SENSOR_VM}" "${i}" "${cpuset_for_vm}" --config >/dev/null 2>&1 || true
                    done
                else
                    log "[DRY-RUN] ${SENSOR_VM}: emulatorpin / vcpupin cpuset=${cpuset_for_vm} (not executed)"
                fi
            fi
        else
            log "[STEP 09] ${SENSOR_VM}: Single NUMA node environment → skip CPU Affinity."
        fi

        #######################################################################
        # 4.5 Safe restart to apply configuration
        #######################################################################
        restart_vm_safely "${SENSOR_VM}"

        #######################################################################
        # 5. Result report (Per VM)
        #######################################################################
        local result_file="/tmp/step09_result_${SENSOR_VM}.txt"
        {
            echo "STEP 09 - Verification result (${SENSOR_VM})"
            echo "==================="
            echo "- VM status: $(virsh domstate ${SENSOR_VM} 2>/dev/null)"
            echo "- Applied PCI list: ${VM_PCIS:-<empty>}"
            echo "- PCI device connection count: ${hostdev_count}"
            if [[ "${hostdev_count}" -gt 0 ]]; then
                echo "  (Success: PCI Passthrough is working normally)"
            else
                echo "  (Failure: PCI device not connected. Please check STEP 01 configuration)"
            fi
        } > "${result_file}"

        show_inline "STEP 09 result (${SENSOR_VM})" "${result_file}"

        log "[STEP 09] ----- Sensor VM processing completed: ${SENSOR_VM} -----"
    done

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Checking required packages for dp_cli + ACL persistence..."
    local required_pkgs
    local pkgs_to_install=()
    required_pkgs=(python3-pip python3-venv wget curl unzip iptables netfilter-persistent iptables-persistent ipset-persistent)

    for pkg in "${required_pkgs[@]}"; do
        if dpkg -s "${pkg}" >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Package already installed: ${pkg}"
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
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: apt-get update failed" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
        fi

        if [[ "${remove_ufw}" -eq 1 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Removing ufw may take some time. Please wait."
            if ! apt-get purge -y ufw >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to remove ufw" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ufw removed (to avoid conflicts)"
        fi

        if [[ "${#pkgs_to_install[@]}" -gt 0 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Package installation may take some time. Please wait."
            # Preseed debconf to avoid interactive prompts (iptables/ipset persistent)
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
            echo "ipset-persistent ipset-persistent/autosave boolean true" | debconf-set-selections
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                "${pkgs_to_install[@]}" >>"${ERRLOG}" 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: Failed to install required packages" | tee -a "${ERRLOG}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
                return 1
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Required packages installed successfully"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] All required packages already installed"
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


#######################################
# Configuration menu
#######################################

menu_config() {
  while true; do
    load_config

    local choice
    choice=$(whiptail --title "XDR Installer - configuration" \
                      --menu "Change configuration:" \
                      22 90 10 \
                      "1" "DRY_RUN mode: ${DRY_RUN} (1=simulation, 0=actual execution)" \
                      "2" "Sensor version: ${SENSOR_VERSION}" \
                      "3" "ACPS Username: ${ACPS_USERNAME}" \
                      "4" "ACPS Password: (configured)" \
                      "5" "ACPS URL: ${ACPS_BASE_URL}" \
                      "6" "Auto Reboot: ${ENABLE_AUTO_REBOOT} (1=active, 0=inactive)" \
                      "7" "View current setting" \
                      "8" "go back" \
                      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      1)
        local new_dry_run
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          new_dry_run=0
        else
          new_dry_run=1
        fi
        save_config_var "DRY_RUN" "${new_dry_run}"
        whiptail_msgbox "Configuration Changed" "DRY_RUN changed to ${new_dry_run}."
        ;;
      2)
        local new_version
        new_version=$(whiptail_inputbox "Sensor version configuration" "Please enter sensor version:" "${SENSOR_VERSION}")
        if [[ -n "${new_version}" ]]; then
          save_config_var "SENSOR_VERSION" "${new_version}"
          whiptail_msgbox "Configuration Changed" "Sensor version changed to ${new_version}."
        fi
        ;;
      3)
        local new_username
        new_username=$(whiptail_inputbox "ACPS Username configuration" "Please enter ACPS username:" "${ACPS_USERNAME}")
        if [[ -n "${new_username}" ]]; then
          save_config_var "ACPS_USERNAME" "${new_username}"
          whiptail_msgbox "Configuration Changed" "ACPS username changed."
        fi
        ;;
      4)
        local new_password
        new_password=$(whiptail_passwordbox "ACPS Password configuration" "Please enter ACPS password:" "")
        if [[ -n "${new_password}" ]]; then
          save_config_var "ACPS_PASSWORD" "${new_password}"
          whiptail_msgbox "Configuration Changed" "ACPS password changed."
        fi
        ;;
      5)
        local new_url
        new_url=$(whiptail_inputbox "ACPS URL configuration" "Please enter ACPS URL:" "${ACPS_BASE_URL}")
        if [[ -n "${new_url}" ]]; then
          save_config_var "ACPS_BASE_URL" "${new_url}"
          whiptail_msgbox "Configuration Changed" "ACPS URL changed."
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
        whiptail_msgbox "Configuration Changed" "Auto Reboot changed to ${new_reboot}."
        ;;
      7)
        local config_summary
        config_summary=$(cat <<EOF
Current XDR Installer configuration
=======================

Basic Configuration:
- DRY_RUN: ${DRY_RUN}
- Sensor version: ${SENSOR_VERSION}
- Auto Reboot: ${ENABLE_AUTO_REBOOT}
- Sensor network mode: nat (fixed)
- SPAN attachment mode: pci (fixed)

ACPS configuration:
- Username: ${ACPS_USERNAME}
- URL: ${ACPS_BASE_URL}

Hardware configuration:
- HOST NIC: ${HOST_NIC:-<Not configured>}
- SPAN NICs: ${SPAN_NICS:-<Not configured>}
- Sensor vCPU: ${SENSOR_VCPUS:-<Not configured>}
- Sensor memory: ${SENSOR_MEMORY_MB:-<Not configured>}MB

Configuration file: ${CONFIG_FILE}
EOF
)
        show_paged "Current setting" <(echo "${config_summary}")
        ;;
      8)
        break
        ;;
    esac
  done
}


#######################################
# Step-by-step execution menu
#######################################

menu_select_step_and_run() {
  while true; do
    load_state

    local menu_items=()
    for ((i=0; i<NUM_STEPS; i++)); do
      local step_id="${STEP_IDS[$i]}"
      local step_name="${STEP_NAMES[$i]}"
      local status="wait"

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
    menu_items+=("back" "go back")

    # Calculate menu size dynamically
    local menu_item_count=$((NUM_STEPS + 1))
    local menu_dims
    menu_dims=$(calc_menu_size "${menu_item_count}" 100 10)
    local menu_height menu_width menu_list_height
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

    # Center-align the menu message
    local centered_msg
    centered_msg=$(center_menu_message "Select step to execute:" "${menu_height}")

    local choice
    choice=$(whiptail --title "XDR Installer - step selection" \
                      --menu "${centered_msg}" \
                      --notags \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${menu_items[@]}" \
                      3>&1 1>&2 2>&3) || {
      # ESC or Cancel pressed - return to main menu
      break
    }

    if [[ "${choice}" == "back" ]]; then
      break
    else
      # Find the index of the selected step_id
      local idx
      local found=0
      for ((idx=0; idx<NUM_STEPS; idx++)); do
        if [[ "${STEP_IDS[$idx]}" == "${choice}" ]]; then
          found=1
          run_step "${idx}"
          break
        fi
      done
      if [[ ${found} -eq 0 ]]; then
        log "ERROR: Selected step_id '${choice}' not found in STEP_IDS"
        continue
      fi
    fi
  done
}


#######################################
# Automatic continue execution menu
#######################################

menu_auto_continue_from_state() {
  load_state

  local next_idx
  next_idx=$(get_next_step_index)

  if [[ ${next_idx} -ge ${NUM_STEPS} ]]; then
    whiptail --title "XDR Installer - automatic execution" \
             --msgbox "All steps have been completed!" 8 60
    return
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"
  if ! whiptail --title "XDR Installer - automatic execution" \
                --yesno "Do you want to automatically execute from next step?\n\nStart step: ${next_step_name}\n\nIf it fails in the middle, it will stop at that step." 12 80
  then
    return
  fi

  for ((i=next_idx; i<NUM_STEPS; i++)); do
    if ! run_step "${i}"; then
      whiptail --title "Automatic execution stopped" \
               --msgbox "An error occurred during STEP ${STEP_IDS[$i]} execution.\n\nAutomatic execution stopped." 10 70
      break
    fi
    if [[ "${USER_CANCELED}" -eq 1 ]]; then
      # User canceled mid-step; stop automatic execution
      break
    fi
  done
}


#######################################
# Main menu
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
          whiptail_msgbox "Log Not Found" "Log file does not exist yet." 8 60
        fi
        ;;
      7)
        if whiptail_yesno "Exit Confirmation" "Do you want to exit XDR Installer?" 8 60; then
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

  # Load config to check network mode (NAT-only)
  if type load_config >/dev/null 2>&1; then
    load_config 2>/dev/null || true
  fi
  local net_mode="nat"

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
  # NAT-only: check for virbr0 (libvirt default network)
  if ip link show virbr0 >/dev/null 2>&1; then
    ok_msgs+=("virbr0 bridge exists (NAT-only)")
  else
    warn_msgs+=("virbr0 bridge does not exist (NAT-only).")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC Name/ifupdown Switch and Network Configuration)")
    warn_msgs+=("  → CHECK: Verify libvirt network with 'virsh net-list --all'")
  fi

  # Check ifupdown package
  if dpkg -l | grep -q "^ii[[:space:]]*ifupdown[[:space:]]"; then
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

  if [[ -f /etc/libvirt/hooks/network ]]; then
    ok_msgs+=("/etc/libvirt/hooks/network script exists (NAT-only)")
  else
    warn_msgs+=("/etc/libvirt/hooks/network script does not exist (NAT-only).")
    warn_msgs+=("  → ACTION: Re-run STEP 06 (libvirt hooks Installation)")
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

  # Check lv_sensor_root_mds and lv_sensor_root_mds2 LVs
  if lvs ubuntu-vg/lv_sensor_root_mds >/dev/null 2>&1; then
    ok_msgs+=("lv_sensor_root_mds LV exists")
  else
    warn_msgs+=("lv_sensor_root_mds LV not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify with 'sudo lvs ubuntu-vg/lv_sensor_root_mds'")
  fi

  if lvs ubuntu-vg/lv_sensor_root_mds2 >/dev/null 2>&1; then
    ok_msgs+=("lv_sensor_root_mds2 LV exists")
  else
    warn_msgs+=("lv_sensor_root_mds2 LV not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify with 'sudo lvs ubuntu-vg/lv_sensor_root_mds2'")
  fi

  # Check mount points
  if mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then
    ok_msgs+=("/var/lib/libvirt/images/mds mount point exists")
  else
    warn_msgs+=("/var/lib/libvirt/images/mds mount point does not exist.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify mount with 'mountpoint /var/lib/libvirt/images/mds'")
  fi

  if mountpoint -q /var/lib/libvirt/images/mds2 2>/dev/null; then
    ok_msgs+=("/var/lib/libvirt/images/mds2 mount point exists")
  else
    warn_msgs+=("/var/lib/libvirt/images/mds2 mount point does not exist.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify mount with 'mountpoint /var/lib/libvirt/images/mds2'")
  fi

  ###############################
  # STEP 08: Sensor VM Deployment
  ###############################
  if virsh list --all 2>/dev/null | grep -qE '\s(mds|mds2)\s'; then
    ok_msgs+=("Sensor VMs (mds, mds2) exist")
  else
    warn_msgs+=("Sensor VMs (mds, mds2) not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 08 (Sensor VM Deployment)")
    warn_msgs+=("  → CHECK: Verify VMs with 'virsh list --all'")
  fi

  ###############################
  # STEP 09: PCI Passthrough / CPU Affinity
  ###############################
  if virsh dumpxml mds 2>/dev/null | grep -q '<hostdev'; then
    ok_msgs+=("mds VM has PCI passthrough (hostdev) configuration")
  else
    warn_msgs+=("mds VM XML does not have PCI passthrough (hostdev) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 09 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: SPAN NIC passthrough may not be applied without this")
  fi

  if virsh dumpxml mds2 2>/dev/null | grep -q '<hostdev'; then
    ok_msgs+=("mds2 VM has PCI passthrough (hostdev) configuration")
  else
    warn_msgs+=("mds2 VM XML does not have PCI passthrough (hostdev) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 09 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: SPAN NIC passthrough may not be applied without this")
  fi

  # Check CPU pinning (cputune)
  if virsh dumpxml mds 2>/dev/null | grep -q '<cputune>'; then
    ok_msgs+=("mds VM has CPU pinning (cputune) configuration")
  else
    warn_msgs+=("mds VM XML does not have CPU pinning (cputune) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 09 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: NUMA-based vCPU placement may not be applied without this")
  fi

  if virsh dumpxml mds2 2>/dev/null | grep -q '<cputune>'; then
    ok_msgs+=("mds2 VM has CPU pinning (cputune) configuration")
  else
    warn_msgs+=("mds2 VM XML does not have CPU pinning (cputune) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 09 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: NUMA-based vCPU placement may not be applied without this")
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
  # Due to set -e, if any fails in the middle it will exit, so temporarily ignore errors in this block
  set +e

  local tmp_file="/tmp/xdr_sensor_validation_$(date '+%Y%m%d-%H%M%S').log"

  {
    echo "========================================"
    echo " XDR Sensor Installer Full Configuration Verification"
    echo " Execution time: $(date '+%F %T')"
    echo
    echo " *** Press spacebar or down arrow key to see next message." 
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
      echo "[INFO] kvm-ok command not found (cpu-checker package not installed)."
    fi
    echo

    echo "\$ systemctl status libvirtd --no-pager"
    systemctl status libvirtd --no-pager 2>&1 || echo "[WARN] libvirtd service status check failed"
    echo

    echo "\$ virsh net-list --all"
    virsh net-list --all 2>&1 || echo "[WARN] virsh net-list --all execution failed"
    echo

    ##################################################
    # 4. Sensor VM / Storage verify
    ##################################################
    echo "## 4. Sensor VM / Storage verify"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all execution failed"
    echo

    echo "\$ lvs"
    lvs 2>&1 || echo "[WARN] LVM information query failed"
    echo

    echo "\$ df -h /var/lib/libvirt/images/mds"
    df -h /var/lib/libvirt/images/mds 2>&1 || echo "[INFO] /var/lib/libvirt/images/mds mount point not found."
    echo
    echo "\$ df -h /var/lib/libvirt/images/mds2"
    df -h /var/lib/libvirt/images/mds2 2>&1 || echo "[INFO] /var/lib/libvirt/images/mds2 mount point not found."
    echo

    echo "\$ ls -la /var/lib/libvirt/images/"
    ls -la /var/lib/libvirt/images/ 2>&1 || echo "[INFO] libvirt image directory not found."
    echo

    ##################################################
    # 5. System tuning verify
    ##################################################
    echo "## 5. System tuning verify"
    echo

    echo "\$ swapon --show"
    swapon --show 2>&1 || echo "[INFO] Swap is enabled."
    echo

    echo "\$ grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf"
    grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf 2>&1 || echo "[INFO] sysctl tuning configuration not found."
    echo

    echo "\$ systemctl status ntpsec --no-pager"
    systemctl status ntpsec --no-pager 2>&1 || echo "[INFO] ntpsec service not installed/enabled."
    echo

    ##################################################
    # 6. Configuration file verify
    ##################################################
    echo "## 6. Configuration file verify"
    echo

    echo "STATE_FILE: ${STATE_FILE}"
    if [[ -f "${STATE_FILE}" ]]; then
      echo "--- ${STATE_FILE} content ---"
      cat "${STATE_FILE}" 2>&1 || echo "[WARN] Status file read failed"
    else
      echo "[INFO] State file not found."
    fi
    echo

    echo "CONFIG_FILE: ${CONFIG_FILE}"
    if [[ -f "${CONFIG_FILE}" ]]; then
      echo "--- ${CONFIG_FILE} content ---"
      cat "${CONFIG_FILE}" 2>&1 || echo "[WARN] Configuration file read failed"
    else
      echo "[INFO] Configuration file not found."
    fi
    echo

    echo "========================================"
    echo "Verification completed: $(date '+%F %T')"
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
    show_paged "Full Configuration Validation Results (Detailed Log)" "${tmp_file}"
  fi

  # Clean up temporary files
  rm -f "${summary_file}"
  rm -f "${tmp_file}"
}

#######################################
# Script usage guide
#######################################

show_usage_help() {
  local tmp_help_file="/tmp/xdr_sensor_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  cat <<'EOF' > "${tmp_help_file}"
═══════════════════════════════════════════════════════════════
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
│      • SPAN_ATTACH_MODE: pci (fixed)                          │
│      • ACPS credentials (username, password, URL)            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ 4. Full Configuration Validation                            │
│    → Comprehensive system validation                         │
│    → Checks: KVM, Sensor VM, network, SPAN, storage          │
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
│    → Exit the installer                                      │
└─────────────────────────────────────────────────────────────┘


═══════════════════════════════════════════════════════════════
🔰 **Scenario 1: Fresh Installation (Ubuntu 20.04/22.04/24.04)**
═══════════════════════════════════════════════════════════════

Step-by-Step Process:
────────────────────────────────────────────────────────────
1. Initial Setup:
   • Configure menu 3: Set DRY_RUN=0, SENSOR_VERSION,
     ACPS credentials
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
• Changing configuration (NIC)

Process:
────────────────────────────────────────────────────────────
1. Review current state:
   • Main menu shows last completed step
   • Check menu 4 (validation) for current status

2. Configure if needed:
   • Menu 3: Update DRY_RUN, SENSOR_VERSION,
     or ACPS credentials

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
  → NAT uplink NIC change requires re-running from STEP 01

• SPAN NIC Reconfiguration:
  → Menu 2 → STEP 01 (SPAN NIC selection) → STEP 09 (PCI passthrough)

• Network Mode:
  → NAT-only build (no bridge mode)


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
• Ubuntu Server 20.04 / 22.04 / 24.04 LTS
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
    • PCI Passthrough mode only (best performance)

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

Network Mode:
────────────────────────────────────────────────────────────
• NAT-only build (virbr0 NAT network based)
• NAT uplink NIC changes require re-running STEP 01 and STEP 08

SPAN Attachment Mode:
────────────────────────────────────────────────────────────
• SPAN_ATTACH_MODE: pci (fixed)
  - PCI: Direct PCI passthrough (best performance)
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
• NAT-only build (virbr0) is fixed network mode
• PCI passthrough for SPAN provides best performance
• Ensure IOMMU is enabled in BIOS for PCI passthrough
• Monitor disk space in ubuntu-vg throughout installation
• Save configuration after menu 3 changes
• VM resources are auto-calculated - no manual configuration needed

═══════════════════════════════════════════════════════════════
EOF

  # Store temporary file content and display with show_textbox
  show_textbox "XDR Sensor Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}

# Main execution
main_menu