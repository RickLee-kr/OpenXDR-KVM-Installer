#!/usr/bin/env bash
#
# XDR AIO & Sensor Installer Framework (SSH + Whiptail based TUI)
# OpenXDR-installer.sh based on AIO + Sensor deployment scenario
#

set -euo pipefail

#######################################
# Basic Configuration
#######################################

# Select appropriate directory based on execution environment
if [[ "${EUID}" -eq 0 ]]; then
  BASE_DIR="/root/xdr-installer"  # when running as root /root Use
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

# Host Auto Reboot Configuration
ENABLE_AUTO_REBOOT=1                 # 1: Auto reboot after STEP completion, 0: Do not auto reboot
AUTO_REBOOT_AFTER_STEP_ID="03_nic_ifupdown 05_kernel_tuning"

# SPAN NIC Attachment Mode Configuration
: "${SPAN_ATTACH_MODE:=pci}"         # pci | bridge

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
  "07_lvm_storage"
  "08_dp_download"
  "09_aio_deploy"
  "10_sensor_lv_download"
  "11_sensor_deploy"
  "12_sensor_passthrough"
  "13_install_dp_cli"
)

# STEP Name (description displayed in UI)
STEP_NAMES=(
  "01. Hardware / NIC / SPAN NIC Selection"
  "02. HWE Kernel Installation"
  "03. NIC Name/ifupdown Switch and Network Configuration"
  "04. KVM / Libvirt Installation and Basic Configuration"
  "05. Kernel Parameters / KSM / Swap Tuning"
  "06. libvirt Hooks Installation"
  "07. LVM Storage Configuration (AIO)"
  "08. DP Download (AIO)"
  "09. AIO VM Deployment"
  "10. Sensor LV Creation + Image/Script Download"
  "11. Sensor VM Deployment"
  "12. PCI Passthrough / CPU Affinity"
  "13. Install DP Appliance CLI package"
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
  local title file tmpfile no_clear

  # ANSI Color Definition
  local RED="\033[1;31m"
  local GREEN="\033[1;32m"
  local BLUE="\033[1;34m"
  local CYAN="\033[1;36m"
  local YELLOW="\033[1;33m"
  local RESET="\033[0m"

  # --- Argument processing (safe for set -u environment) ---
  no_clear="0"
  if [[ $# -eq 1 ]]; then
    # ① Case when only one argument is provided: content string only
    title="XDR AIO & Sensor Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    # ② Two or more arguments: 1 = title, 2 = file path
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
# VM Destroy Confirmation Helper
#######################################
confirm_destroy_vm() {
  local vm_name="$1"
  local step_name="$2"

  if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    return 0
  fi

  local state
  state=$(virsh domstate "${vm_name}" 2>/dev/null | tr -d '\r')

  local msg="The ${vm_name} VM is currently defined. (State: ${state})\n\
\n\
Continuing this step will:\n\
  - Destroy and undefine the ${vm_name} VM\n\
  - Delete existing disk image files (${vm_name}.raw / ${vm_name}.log, etc.).\n\
\n\
This can significantly impact the running cluster (DL / DA services).\n\
\n\
Are you sure you want to proceed with redeployment?"

  if command -v whiptail >/dev/null 2>&1; then
      # Calculate dialog size dynamically and center message
      local dialog_dims
      dialog_dims=$(calc_dialog_size 18 80)
      local dialog_height dialog_width
      read -r dialog_height dialog_width <<< "${dialog_dims}"
      local centered_msg
      centered_msg=$(center_message "${msg}")
      
      if ! whiptail --title "${step_name} - ${vm_name} Redeployment Confirmation" \
                    --defaultno \
                    --yesno "${centered_msg}" "${dialog_height}" "${dialog_width}"; then
          log "[${step_name}] ${vm_name} redeployment canceled by user."
          return 1
      fi
  else
  
    echo
    echo "====================================================="
    echo " ${step_name}: ${vm_name} Redeployment Warning"
    echo "====================================================="
    echo -e "${msg}"
    echo
    read -r -p "Do you want to continue? (Enter 'yes' to proceed) [default: no] : " answer
    case "${answer}" in
      yes|y|Y) ;;
      *)
        log "[${step_name}] ${vm_name} redeployment canceled by user."
        return 1
        ;;
    esac
  fi

  return 0
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
  : "${DP_VERSION:=6.2.0}"  # DP version for AIO deployment (default: 6.2.0)
  : "${SENSOR_VERSION:=6.2.0}"
  : "${ACPS_USERNAME:=}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=}"

  # Default values related to auto reboot
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"


  # Set default values so NIC / disk selection values are always defined
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"
  : "${HOST_ACCESS_NIC:=}"
  : "${HOST_NIC_PCI:=}"
  : "${HOST_NIC_MAC:=}"
  : "${HOST_NIC_EFFECTIVE:=}"
  : "${HOST_ACCESS_NIC_PCI:=}"
  : "${HOST_ACCESS_NIC_MAC:=}"
  : "${HOST_ACCESS_NIC_EFFECTIVE:=}"
  : "${DATA_NIC_PCI:=}"
  : "${DATA_NIC_MAC:=}"
  : "${DATA_NIC_EFFECTIVE:=}"
  
  # Load renamed interface names if available
  : "${HOST_NIC_RENAMED:=}"

  : "${SPAN_NICS:=}"

  # ===== Storage Configuration =====
  : "${DATA_SSD_LIST:=}"

  # ===== AIO Configuration =====
  : "${AIO_VM_COUNT:=1}"
  : "${AIO_VCPUS:=}"
  : "${AIO_MEMORY_GB:=}"
  : "${AIO_MEMORY_MB:=}"
  : "${AIO_DISK_GB:=}"
  : "${AIO_CPUSET:=}"

  # ===== 1VM (mds only) =====
  : "${SENSOR_VM_COUNT:=1}"

  : "${SENSOR_TOTAL_VCPUS:=}"
  : "${SENSOR_VCPUS_PER_VM:=}"
  : "${SENSOR_CPUSET_MDS:=}"

  : "${SENSOR_TOTAL_MEMORY_MB:=}"
  : "${SENSOR_MEMORY_MB_PER_VM:=}"

  : "${SENSOR_TOTAL_LV_SIZE_GB:=}"
  : "${SENSOR_LV_SIZE_GB_PER_VM:=}"

  # ===== Legacy/Compatible (per-vm) =====
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"

  # ===== SPAN NIC (mds only) =====
  : "${SPAN_NICS_MDS:=}"

  # ===== SPAN PCI(PF) (mds only) =====
  : "${SENSOR_SPAN_VF_PCIS_MDS:=}"
  : "${SENSOR_SPAN_VF_PCIS:=}"     # Combined (Compatible)

  : "${SPAN_ATTACH_MODE:=sriov}"
  : "${SPAN_NIC_LIST:=}"
  : "${SPAN_BRIDGE_LIST:=}"
  : "${SENSOR_NET_MODE:=nat}"  # NAT mode only (bridge mode not supported)
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"              # Legacy/Compatible (per-vm disk)
}


save_config() {
  # CONFIG_FILE Create directory containing
  mkdir -p "$(dirname "${CONFIG_FILE}")"

  # Replace " with \" in values (to prevent config file from breaking)
  local esc_dp_version esc_sensor_version esc_acps_user esc_acps_pass esc_acps_url
  esc_dp_version=${DP_VERSION//\"/\\\"}
  esc_sensor_version=${SENSOR_VERSION//\"/\\\"}
  esc_acps_user=${ACPS_USERNAME//\"/\\\"}
  esc_acps_pass=${ACPS_PASSWORD//\"/\\\"}
  esc_acps_url=${ACPS_BASE_URL//\"/\\\"}

  # ★ Also escape NIC / sensor related values
  local esc_host_nic esc_data_nic esc_host_access_nic esc_span_nics
  local esc_sensor_vcpus esc_sensor_memory_mb
  local esc_span_attach_mode esc_span_nic_list esc_span_bridge_list esc_sensor_net_mode
  local esc_lv_location esc_lv_size_gb esc_data_ssd_list

  # ---- New escape ----
  local esc_sensor_vm_count
  local esc_sensor_total_vcpus esc_sensor_vcpus_per_vm esc_sensor_cpuset_mds
  local esc_sensor_total_mem_mb esc_sensor_mem_mb_per_vm
  local esc_sensor_total_lv_gb esc_sensor_lv_gb_per_vm
  local esc_aio_vcpus esc_aio_memory_gb esc_aio_memory_mb esc_aio_disk_gb esc_aio_cpuset

  local esc_span_nics_mds
  local esc_sensor_span_pcis_mds esc_sensor_span_pcis

  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_data_nic=${DATA_NIC//\"/\\\"}
  esc_host_access_nic=${HOST_ACCESS_NIC//\"/\\\"}
  esc_span_nics=${SPAN_NICS//\"/\\\"}

  esc_sensor_vm_count=${SENSOR_VM_COUNT//\"/\\\"}

  esc_sensor_total_vcpus=${SENSOR_TOTAL_VCPUS//\"/\\\"}
  esc_sensor_vcpus_per_vm=${SENSOR_VCPUS_PER_VM//\"/\\\"}
  esc_sensor_cpuset_mds=${SENSOR_CPUSET_MDS//\"/\\\"}

  esc_sensor_total_mem_mb=${SENSOR_TOTAL_MEMORY_MB//\"/\\\"}
  esc_sensor_mem_mb_per_vm=${SENSOR_MEMORY_MB_PER_VM//\"/\\\"}

  esc_sensor_total_lv_gb=${SENSOR_TOTAL_LV_SIZE_GB//\"/\\\"}
  esc_sensor_lv_gb_per_vm=${SENSOR_LV_SIZE_GB_PER_VM//\"/\\\"}

  esc_aio_vcpus=${AIO_VCPUS//\"/\\\"}
  esc_aio_memory_gb=${AIO_MEMORY_GB//\"/\\\"}
  esc_aio_memory_mb=${AIO_MEMORY_MB//\"/\\\"}
  esc_aio_disk_gb=${AIO_DISK_GB//\"/\\\"}
  esc_aio_cpuset=${AIO_CPUSET//\"/\\\"}

  esc_span_nics_mds=${SPAN_NICS_MDS//\"/\\\"}

  esc_sensor_span_pcis_mds=${SENSOR_SPAN_VF_PCIS_MDS//\"/\\\"}
  esc_sensor_span_pcis=${SENSOR_SPAN_VF_PCIS//\"/\\\"}

  # ---- Legacy (Compatible): Values redefined as per-vm ----
  esc_sensor_vcpus=${SENSOR_VCPUS//\"/\\\"}
  esc_sensor_memory_mb=${SENSOR_MEMORY_MB//\"/\\\"}

  esc_span_attach_mode=${SPAN_ATTACH_MODE//\"/\\\"}
  esc_span_nic_list=${SPAN_NIC_LIST//\"/\\\"}
  esc_span_bridge_list=${SPAN_BRIDGE_LIST//\"/\\\"}
  esc_sensor_net_mode=${SENSOR_NET_MODE//\"/\\\"}
  esc_lv_location=${LV_LOCATION//\"/\\\"}
  esc_lv_size_gb=${LV_SIZE_GB//\"/\\\"}
  esc_data_ssd_list=${DATA_SSD_LIST//\"/\\\"}

  cat > "${CONFIG_FILE}" <<EOF
# xdr-installer environment configuration (auto-generated)
DRY_RUN=${DRY_RUN}
DP_VERSION="${esc_dp_version}"
SENSOR_VERSION="${esc_sensor_version}"
ACPS_USERNAME="${esc_acps_user}"
ACPS_PASSWORD="${esc_acps_pass}"
ACPS_BASE_URL="${esc_acps_url}"
ENABLE_AUTO_REBOOT=${ENABLE_AUTO_REBOOT}
AUTO_REBOOT_AFTER_STEP_ID="${AUTO_REBOOT_AFTER_STEP_ID}"

# NIC / Sensor configuration selected in STEP 01
HOST_NIC="${esc_host_nic}"
DATA_NIC="${esc_data_nic}"
HOST_ACCESS_NIC="${esc_host_access_nic}"
HOST_NIC_PCI="${HOST_NIC_PCI//\"/\\\"}"
HOST_NIC_MAC="${HOST_NIC_MAC//\"/\\\"}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE//\"/\\\"}"
HOST_ACCESS_NIC_PCI="${HOST_ACCESS_NIC_PCI//\"/\\\"}"
HOST_ACCESS_NIC_MAC="${HOST_ACCESS_NIC_MAC//\"/\\\"}"
HOST_ACCESS_NIC_EFFECTIVE="${HOST_ACCESS_NIC_EFFECTIVE//\"/\\\"}"
DATA_NIC_PCI="${DATA_NIC_PCI//\"/\\\"}"
DATA_NIC_MAC="${DATA_NIC_MAC//\"/\\\"}"
DATA_NIC_EFFECTIVE="${DATA_NIC_EFFECTIVE//\"/\\\"}"
SPAN_NICS="${esc_span_nics}"

# ---- AIO Configuration ----
AIO_VM_COUNT="1"
AIO_TOTAL_VCPUS="${esc_aio_vcpus}"
AIO_VCPUS_PER_VM="${esc_aio_vcpus}"
AIO_CPUSET="${esc_aio_cpuset}"
AIO_MEMORY_GB="${esc_aio_memory_gb}"
AIO_MEMORY_MB="${esc_aio_memory_mb}"
AIO_DISK_GB="${esc_aio_disk_gb}"

# ---- 1VM (mds only) ----
SENSOR_VM_COUNT="${esc_sensor_vm_count}"

SENSOR_TOTAL_VCPUS="${esc_sensor_total_vcpus}"
SENSOR_VCPUS_PER_VM="${esc_sensor_vcpus_per_vm}"
SENSOR_CPUSET_MDS="${esc_sensor_cpuset_mds}"

SENSOR_TOTAL_MEMORY_MB="${esc_sensor_total_mem_mb}"
SENSOR_MEMORY_MB_PER_VM="${esc_sensor_mem_mb_per_vm}"

SENSOR_TOTAL_LV_SIZE_GB="${esc_sensor_total_lv_gb}"
SENSOR_LV_SIZE_GB_PER_VM="${esc_sensor_lv_gb_per_vm}"

# ---- Legacy/Compatible (per-vm) ----
SENSOR_VCPUS="${esc_sensor_vcpus}"
SENSOR_MEMORY_MB="${esc_sensor_memory_mb}"

# ---- SPAN (mds only) ----
SPAN_NICS_MDS="${esc_span_nics_mds}"

SENSOR_SPAN_VF_PCIS_MDS="${esc_sensor_span_pcis_mds}"
SENSOR_SPAN_VF_PCIS="${esc_sensor_span_pcis}"

SPAN_ATTACH_MODE="${esc_span_attach_mode}"
SPAN_NIC_LIST="${esc_span_nic_list}"
SPAN_BRIDGE_LIST="${esc_span_bridge_list}"
SENSOR_NET_MODE="${esc_sensor_net_mode}"
LV_LOCATION="${esc_lv_location}"
LV_SIZE_GB="${esc_lv_size_gb}"
DATA_SSD_LIST="${esc_data_ssd_list}"
EOF

}


# Since existing code may call save_config_var
# Maintain compatibility by only updating variables internally and calling save_config() again
save_config_var() {
  local key="$1"
  local value="$2"

  case "${key}" in
    DRY_RUN)        DRY_RUN="${value}" ;;
    DP_VERSION)      DP_VERSION="${value}" ;;
    SENSOR_VERSION)     SENSOR_VERSION="${value}" ;;
    ACPS_USERNAME)  ACPS_USERNAME="${value}" ;;
    ACPS_PASSWORD)  ACPS_PASSWORD="${value}" ;;
    ACPS_BASE_URL)  ACPS_BASE_URL="${value}" ;;
    ENABLE_AUTO_REBOOT)        ENABLE_AUTO_REBOOT="${value}" ;;
    AUTO_REBOOT_AFTER_STEP_ID) AUTO_REBOOT_AFTER_STEP_ID="${value}" ;;

    # ★ Add here
    HOST_NIC)       HOST_NIC="${value}" ;;
    DATA_NIC)       DATA_NIC="${value}" ;;
    HOST_ACCESS_NIC) HOST_ACCESS_NIC="${value}" ;;
    HOST_NIC_PCI)   HOST_NIC_PCI="${value}" ;;
    HOST_NIC_MAC)   HOST_NIC_MAC="${value}" ;;
    HOST_NIC_EFFECTIVE) HOST_NIC_EFFECTIVE="${value}" ;;
    HOST_ACCESS_NIC_PCI) HOST_ACCESS_NIC_PCI="${value}" ;;
    HOST_ACCESS_NIC_MAC) HOST_ACCESS_NIC_MAC="${value}" ;;
    HOST_ACCESS_NIC_EFFECTIVE) HOST_ACCESS_NIC_EFFECTIVE="${value}" ;;
    DATA_NIC_PCI)   DATA_NIC_PCI="${value}" ;;
    DATA_NIC_MAC)   DATA_NIC_MAC="${value}" ;;
    DATA_NIC_EFFECTIVE) DATA_NIC_EFFECTIVE="${value}" ;;
    SPAN_NICS)      SPAN_NICS="${value}" ;;
    HOST_NIC_RENAMED) HOST_NIC_RENAMED="${value}" ;;

    # ---- AIO Configuration ----
    AIO_VM_COUNT) AIO_VM_COUNT="${value}" ;;
    AIO_TOTAL_VCPUS) AIO_TOTAL_VCPUS="${value}" ;;
    AIO_VCPUS_PER_VM) AIO_VCPUS_PER_VM="${value}" ;;
    AIO_CPUSET) AIO_CPUSET="${value}" ;;
    AIO_VCPUS) AIO_VCPUS="${value}" ;;
    AIO_MEMORY_GB) AIO_MEMORY_GB="${value}" ;;
    AIO_MEMORY_MB) AIO_MEMORY_MB="${value}" ;;
    AIO_DISK_GB) AIO_DISK_GB="${value}" ;;

    # ---- 1VM (mds only) ----
    SENSOR_VM_COUNT) SENSOR_VM_COUNT="${value}" ;;

    SENSOR_TOTAL_VCPUS) SENSOR_TOTAL_VCPUS="${value}" ;;
    SENSOR_VCPUS_PER_VM) SENSOR_VCPUS_PER_VM="${value}" ;;
    SENSOR_CPUSET_MDS) SENSOR_CPUSET_MDS="${value}" ;;

    SENSOR_TOTAL_MEMORY_MB) SENSOR_TOTAL_MEMORY_MB="${value}" ;;
    SENSOR_MEMORY_MB_PER_VM) SENSOR_MEMORY_MB_PER_VM="${value}" ;;
    SENSOR_LV_MDS)  SENSOR_LV_MDS="${value}" ;;
    SENSOR_TOTAL_LV_SIZE_GB) SENSOR_TOTAL_LV_SIZE_GB="${value}" ;;
    SENSOR_LV_SIZE_GB_PER_VM) SENSOR_LV_SIZE_GB_PER_VM="${value}" ;;

    # ---- Legacy/Compatible (per-vm) ----
    SENSOR_VCPUS)   SENSOR_VCPUS="${value}" ;;
    SENSOR_MEMORY_MB) SENSOR_MEMORY_MB="${value}" ;;

    # ---- SPAN (mds only) ----
    SPAN_NICS_MDS) SPAN_NICS_MDS="${value}" ;;

    SENSOR_SPAN_VF_PCIS_MDS) SENSOR_SPAN_VF_PCIS_MDS="${value}" ;;
    SENSOR_SPAN_VF_PCIS) SENSOR_SPAN_VF_PCIS="${value}" ;;

    SPAN_ATTACH_MODE) SPAN_ATTACH_MODE="${value}" ;;
    SPAN_NIC_LIST) SPAN_NIC_LIST="${value}" ;;
    SPAN_BRIDGE_LIST) SPAN_BRIDGE_LIST="${value}" ;;
    SENSOR_NET_MODE) SENSOR_NET_MODE="${value}" ;;
    LV_LOCATION) LV_LOCATION="${value}" ;;
    LV_SIZE_GB) LV_SIZE_GB="${value}" ;;
    DATA_SSD_LIST) DATA_SSD_LIST="${value}" ;;

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
HOST_ACCESS_NIC="${HOST_ACCESS_NIC}"
HOST_NIC_PCI="${HOST_NIC_PCI}"
HOST_NIC_MAC="${HOST_NIC_MAC}"
HOST_NIC_EFFECTIVE="${HOST_NIC_EFFECTIVE}"
HOST_ACCESS_NIC_PCI="${HOST_ACCESS_NIC_PCI}"
HOST_ACCESS_NIC_MAC="${HOST_ACCESS_NIC_MAC}"
HOST_ACCESS_NIC_EFFECTIVE="${HOST_ACCESS_NIC_EFFECTIVE}"
DATA_NIC_PCI="${DATA_NIC_PCI}"
DATA_NIC_MAC="${DATA_NIC_MAC}"
DATA_NIC_EFFECTIVE="${DATA_NIC_EFFECTIVE}"
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

run_step() {
  local idx="$1"
  local step_id="${STEP_IDS[$idx]}"
  local step_name="${STEP_NAMES[$idx]}"

  # Check if STEP should be executed
  # Generate step-specific description
  local step_description=""
  case "${step_id}" in
    "01_hw_detect")
      step_description="This step will detect hardware, configure NICs, and storage settings."
      ;;
    "02_hwe_kernel")
      step_description="This step will install Hardware Enablement (HWE) kernel for better hardware support."
      ;;
    "03_nic_ifupdown")
      step_description="This step will configure network interfaces using ifupdown (NAT mode)."
      ;;
    "04_kvm_libvirt")
      step_description="This step will install and configure KVM/libvirt for VM management."
      ;;
    "05_kernel_tuning")
      step_description="This step will configure kernel parameters, disable KSM, and optionally disable swap."
      ;;
    "06_libvirt_hooks")
      step_description="This step will install libvirt hooks for NAT/DNAT configuration and OOM monitoring."
      ;;
    "07_lvm_storage")
      step_description="This step will configure LVM storage for AIO and Sensor VMs."
      ;;
    "08_dp_download")
      step_description="This step will download AIO deployment script and image from ACPS."
      ;;
    "09_aio_deploy")
      step_description="This step will deploy the AIO VM."
      ;;
    "10_sensor_lv_download")
      step_description="This step will create sensor logical volume and download sensor image/script."
      ;;
    "11_sensor_deploy")
      step_description="This step will deploy the Sensor VM (mds)."
      ;;
    "12_sensor_passthrough")
      step_description="This step will configure PCI passthrough and CPU affinity for the AIO & Sensor VM."
      ;;
    "13_install_dp_cli")
      step_description="This step will install DP Appliance CLI package."
      ;;
    *)
      step_description="This step will perform the configured operations."
      ;;
  esac

  if ! whiptail_yesno "XDR AIO & Sensor Installer - ${step_id}" "${step_name}\n\n${step_description}\n\nDo you want to execute this step?"
  then
    # User cancellation is considered "normal flow" (not an error)
    log "[$(date '+%Y-%m-%d %H:%M:%S')] User canceled execution of STEP ${step_id} (${step_name})."
    return 0   # Must end with 0 here so set -e doesn't trigger in main case.
  fi

  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${step_id} - ${step_name} ====="
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
    "07_lvm_storage")
      step_07_lvm_storage || rc=$?
      ;;
    "08_dp_download")
      step_08_dp_download || rc=$?
      ;;
    "09_aio_deploy")
      step_09_aio_deploy || rc=$?
      ;;
    "10_sensor_lv_download")
      step_10_sensor_lv_download || rc=$?
      ;;
    "11_sensor_deploy")
      step_11_sensor_deploy || rc=$?
      ;;
    "12_sensor_passthrough")
      step_12_sensor_passthrough || rc=$?
      ;;
    "13_install_dp_cli")
      step_13_install_dp_cli || rc=$?
      ;;	  
    *)
      log "ERROR: Undefined STEP ID: ${step_id}"
      rc=1
      ;;
  esac

  if [[ "${rc}" -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP DONE: ${step_id} - ${step_name} ====="
    log "===== STEP DONE: ${step_id} - ${step_name} ====="
    
    # State verification summary after STEP completion
    local verification_summary=""
    case "${step_id}" in
      "02_hwe_kernel")
        local hwe_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          # Check HWE package according to Ubuntu version (multiple methods)
          local ubuntu_version
          ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
          local expected_pkg=""
          
          case "${ubuntu_version}" in
            "20.04") expected_pkg="linux-generic-hwe-20.04" ;;
            "22.04") expected_pkg="linux-generic-hwe-22.04" ;;
            "24.04") expected_pkg="linux-generic-hwe-24.04" ;;
            *) expected_pkg="linux-generic" ;;
          esac
          
          if dpkg -l | grep -qE "^ii[[:space:]]+${expected_pkg}[[:space:]]"; then
            hwe_status="Installed (${expected_pkg})"
          elif dpkg -l | grep -qE "^ii[[:space:]]+linux-generic-hwe-"; then
            local hwe_pkg=$(dpkg -l | grep -E "^ii[[:space:]]+linux-generic-hwe-" | head -1 | awk '{print $2}')
            hwe_status="Installed (${hwe_pkg})"
          elif dpkg -l | grep -qE "^ii[[:space:]]+linux-image-generic-hwe-"; then
            local hwe_img=$(dpkg -l | grep -E "^ii[[:space:]]+linux-image-generic-hwe-" | head -1 | awk '{print $2}')
            hwe_status="Installed (${hwe_img})"
          elif dpkg -l | grep -qE "^ii[[:space:]]+linux-headers-generic-hwe-"; then
            local hwe_headers=$(dpkg -l | grep -E "^ii[[:space:]]+linux-headers-generic-hwe-" | head -1 | awk '{print $2}')
            hwe_status="Installed (${hwe_headers})"
          else
            hwe_status="Not detected"
          fi
        else
          hwe_status="DRY-RUN"
        fi
        verification_summary="HWE Kernel: ${hwe_status}"
        ;;
      "03_nic_ifupdown")
        local net_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if [[ -f /etc/network/interfaces ]] && grep -q "mgt" /etc/network/interfaces 2>/dev/null; then
            net_status="Configured (mgt interface found)"
          elif [[ -f /etc/udev/rules.d/99-custom-ifnames.rules ]]; then
            net_status="Configured (udev rules found)"
          else
            net_status="Configuration pending (reboot required)"
          fi
        else
          net_status="DRY-RUN"
        fi
        verification_summary="Network: ${net_status}"
        ;;
      "04_kvm_libvirt")
        local kvm_status="Unverified"
        local libvirt_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if command -v kvm-ok >/dev/null 2>&1 && kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
            kvm_status="Available"
          else
            kvm_status="Not available"
          fi
          if systemctl is-active libvirtd >/dev/null 2>&1; then
            libvirt_status="Running"
          else
            libvirt_status="Stopped"
          fi
        else
          kvm_status="DRY-RUN"
          libvirt_status="DRY-RUN"
        fi
        verification_summary="KVM: ${kvm_status}, libvirtd: ${libvirt_status}"
        ;;
      "05_kernel_tuning")
        local tuning_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if grep -q "intel_iommu=on iommu=pt" /etc/default/grub 2>/dev/null && \
             grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf 2>/dev/null; then
            tuning_status="Applied (reboot required)"
          elif grep -q "intel_iommu=on iommu=pt" /etc/default/grub 2>/dev/null || \
               grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf 2>/dev/null; then
            tuning_status="Partially applied (reboot required)"
          else
            tuning_status="Pending (reboot required)"
          fi
        else
          tuning_status="DRY-RUN"
        fi
        verification_summary="Kernel tuning: ${tuning_status}"
        ;;
      "06_libvirt_hooks")
        local hooks_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if [[ -f /etc/libvirt/hooks/network ]] && [[ -f /etc/libvirt/hooks/qemu ]]; then
            hooks_status="Installed (network + qemu hooks)"
          elif [[ -f /etc/libvirt/hooks/network ]] || [[ -f /etc/libvirt/hooks/qemu ]]; then
            hooks_status="Partially installed"
          else
            hooks_status="Not installed"
          fi
        else
          hooks_status="DRY-RUN"
        fi
        verification_summary="Libvirt hooks: ${hooks_status}"
        ;;
      "07_lvm_storage")
        local lvm_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if vgs vg_aio >/dev/null 2>&1 && lvs ubuntu-vg/lv_aio_root >/dev/null 2>&1 && \
             mountpoint -q /stellar/aio 2>/dev/null; then
            lvm_status="Configured (VG/LV created, mounted)"
          elif vgs vg_aio >/dev/null 2>&1 || lvs ubuntu-vg/lv_aio_root >/dev/null 2>&1; then
            lvm_status="Partially configured"
          else
            lvm_status="Not configured"
          fi
        else
          lvm_status="DRY-RUN"
        fi
        verification_summary="LVM storage: ${lvm_status}"
        ;;
      "08_dp_download")
        local download_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if [[ -f /stellar/aio/images/virt_deploy_uvp_centos.sh ]] && \
             [[ -f /stellar/aio/images/aella-dataprocessor-*.qcow2 ]]; then
            download_status="Completed (script + image)"
          elif [[ -f /stellar/aio/images/virt_deploy_uvp_centos.sh ]] || \
               [[ -f /stellar/aio/images/aella-dataprocessor-*.qcow2 ]]; then
            download_status="Partially downloaded"
          else
            download_status="Not downloaded"
          fi
        else
          download_status="DRY-RUN"
        fi
        verification_summary="DP download: ${download_status}"
        ;;
      "09_aio_deploy")
        local aio_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if virsh dominfo aio >/dev/null 2>&1; then
            local aio_state=$(virsh domstate aio 2>/dev/null || echo "unknown")
            aio_status="VM created (${aio_state})"
          else
            aio_status="VM not found"
          fi
        else
          aio_status="DRY-RUN"
        fi
        verification_summary="AIO VM: ${aio_status}"
        ;;
      "10_sensor_lv_download")
        local sensor_lv_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if lvs ubuntu-vg/lv_sensor_root_mds >/dev/null 2>&1 && \
             mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null && \
             [[ -f /var/lib/libvirt/images/mds/aella-modular-ds-*.qcow2 ]]; then
            sensor_lv_status="Completed (LV + mount + image)"
          elif lvs ubuntu-vg/lv_sensor_root_mds >/dev/null 2>&1 && \
               mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then
            sensor_lv_status="LV created (image pending)"
          elif lvs ubuntu-vg/lv_sensor_root_mds >/dev/null 2>&1; then
            sensor_lv_status="LV created (mount pending)"
          else
            sensor_lv_status="Not configured"
          fi
        else
          sensor_lv_status="DRY-RUN"
        fi
        verification_summary="Sensor LV: ${sensor_lv_status}"
        ;;
      "11_sensor_deploy")
        local vm_verify="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if virsh dominfo mds >/dev/null 2>&1; then
            local state=$(virsh domstate mds 2>/dev/null || echo "unknown")
            vm_verify="VM created (${state})"
          else
            vm_verify="VM not found"
          fi
        else
          vm_verify="DRY-RUN"
        fi
        verification_summary="Sensor VM: ${vm_verify}"
        ;;
      "12_sensor_passthrough")
        local passthrough_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if virsh dominfo mds >/dev/null 2>&1; then
            local hostdev_count
            hostdev_count=$(virsh dumpxml mds 2>/dev/null | grep -c "<hostdev" 2>/dev/null || echo "0")
            # Remove all whitespace and convert to integer
            hostdev_count=$(echo "${hostdev_count}" | tr -d '[:space:]')
            # Ensure it's a valid integer, default to 0 if not
            if ! [[ "${hostdev_count}" =~ ^[0-9]+$ ]]; then
              hostdev_count="0"
            fi
            # Convert to integer for comparison
            hostdev_count=$((hostdev_count + 0))
            if [[ "${hostdev_count}" -gt 0 ]]; then
              passthrough_status="Configured (${hostdev_count} PCI device(s))"
            else
              passthrough_status="Not configured (no PCI devices)"
            fi
          else
            passthrough_status="VM not found"
          fi
        else
          passthrough_status="DRY-RUN"
        fi
        verification_summary="PCI passthrough: ${passthrough_status}"
        ;;
      "13_install_dp_cli")
        local cli_status="Unverified"
        if [[ "${DRY_RUN}" -eq 0 ]]; then
          if [[ -x /usr/local/bin/aella_cli ]] && \
             [[ -d /opt/dp_cli_venv ]] && \
             /opt/dp_cli_venv/bin/python -c "import appliance_cli" >/dev/null 2>&1; then
            cli_status="Installed (venv + CLI)"
          elif [[ -x /usr/local/bin/aella_cli ]] || [[ -d /opt/dp_cli_venv ]]; then
            cli_status="Partially installed"
          else
            cli_status="Not installed"
          fi
        else
          cli_status="DRY-RUN"
        fi
        verification_summary="DP CLI: ${cli_status}"
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
	    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
	    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    
    # On failure, guide to the log file location and suggest which step to re-run
    local log_info=""
    if [[ -f "${LOG_FILE}" ]]; then
      log_info="\n\nCheck the detailed log: tail -f ${LOG_FILE}"
    fi
    
    # Determine which step to re-run based on the failed step
    local rerun_step=""
    case "${step_id}" in
      "01_hw_detect")
        rerun_step="Please re-run STEP 01 to fix the configuration."
        ;;
      "02_hwe_kernel")
        rerun_step="Please re-run STEP 02 to complete kernel installation."
        ;;
      "03_nic_ifupdown")
        rerun_step="Please re-run STEP 03 to fix network configuration.\nIf network settings are missing, re-run STEP 01 first."
        ;;
      "04_kvm_libvirt")
        rerun_step="Please re-run STEP 04 to complete KVM/libvirt installation."
        ;;
      "05_kernel_tuning")
        rerun_step="Please re-run STEP 05 to complete kernel tuning."
        ;;
      "06_libvirt_hooks")
        rerun_step="Please re-run STEP 06 to complete libvirt hooks installation."
        ;;
      "07_lvm_storage")
        rerun_step="Please re-run STEP 01 to configure data disks (DATA_SSD_LIST),\nthen re-run STEP 07."
        ;;
      "08_dp_download")
        rerun_step="Please re-run STEP 08 to complete AIO image download.\nCheck ACPS credentials and network connectivity."
        ;;
      "09_aio_deploy")
        rerun_step="Please re-run STEP 09 to complete AIO VM deployment.\nEnsure STEP 07 and STEP 08 are completed first."
        ;;
      "10_sensor_lv_download")
        rerun_step="Please re-run STEP 10 to complete sensor LV creation and image download.\nEnsure STEP 01 is completed first."
        ;;
      "11_sensor_deploy")
        rerun_step="Please re-run STEP 11 to complete Sensor VM deployment.\nEnsure STEP 10 is completed first."
        ;;
      "12_sensor_passthrough")
        rerun_step="Please re-run STEP 12 to complete PCI passthrough configuration.\nEnsure STEP 01 (SPAN NIC selection) and STEP 11 are completed first."
        ;;
      "13_install_dp_cli")
        rerun_step="Please re-run STEP 13 to complete DP CLI installation."
        ;;
      *)
        rerun_step="Please check the log and re-run this STEP if necessary."
        ;;
    esac
    
    whiptail_msgbox "STEP Failed - ${step_id}" "An error occurred during execution of STEP ${step_id} (${step_name}).\n\n${rerun_step}\n\nThe installer can continue to run.${log_info}" 18 80
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
    HOST_ACCESS)
      effective_var="HOST_ACCESS_NIC_EFFECTIVE"
      pci_var="HOST_ACCESS_NIC_PCI"
      mac_var="HOST_ACCESS_NIC_MAC"
      fallback_var="HOST_ACCESS_NIC"
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
  local STEP_ID="01_hw_detect"
  local STEP_NAME="01. Hardware / NIC / SPAN NIC Selection"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 01] Hardware / NIC / SPAN NIC Selection"
  log "[STEP 01] This step will configure hardware, NICs, and storage settings."

  # Load latest configuration (so script doesn't die even if not present)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set default values to prevent set -u (empty string if not defined)
  : "${HOST_NIC:=}"
  : "${DATA_NIC:=}"

  : "${SPAN_NICS:=}"                 # Total SPAN NIC (summary/compatible)
  : "${SPAN_NICS_MDS:=}"             # SPAN NIC for mds

  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_MEMORY_MB:=}"

  : "${SENSOR_SPAN_VF_PCIS:=}"       # Legacy combined
  : "${SENSOR_SPAN_VF_PCIS_MDS:=}"   # PCI list for mds

  : "${SPAN_ATTACH_MODE:=pci}"  # Force PCI passthrough only (no bridge mode)  
  : "${SENSOR_NET_MODE:=nat}"  # Force NAT mode only
  
  # Determine network mode (force NAT)
  local net_mode="nat"
  SENSOR_NET_MODE="nat"
  log "[STEP 01] Sensor network mode: ${net_mode} (NAT only)"

  ########################
  # 0) Whether to reuse existing values (NAT mode only)
  ########################
  local can_reuse_config=0
  local reuse_message=""
  
  # Load storage configuration values
  : "${LV_LOCATION:=}"
  : "${LV_SIZE_GB:=}"
  : "${DATA_SSD_LIST:=}"
  
  # NAT mode only
  if [[ -n "${HOST_NIC}" && -n "${SPAN_NICS}" && -n "${SENSOR_SPAN_VF_PCIS}" && -n "${LV_LOCATION}" && -n "${DATA_SSD_LIST}" ]]; then
      can_reuse_config=1
      local span_mode_label="PF PCI (Passthrough)"
    reuse_message="The following values are already set:\n\n- Network mode: ${net_mode} (NAT only)\n- NAT uplink NIC: ${HOST_NIC}\n- SPAN NICs: ${SPAN_NICS}\n- SPAN attachment mode: ${SPAN_ATTACH_MODE}\n- SPAN ${span_mode_label}: ${SENSOR_SPAN_VF_PCIS}\n- LV location: ${LV_LOCATION}\n- Data disks: ${DATA_SSD_LIST}"
  fi
  
  if [[ "${can_reuse_config}" -eq 1 ]]; then
    if whiptail_yesno "STEP 01 - Reuse Existing Selection" "${reuse_message}\n\nDo you want to reuse these values as-is and skip STEP 01?\n\n(If you select No, you will select again.)" 20 80
    then
      log "User decided to reuse existing STEP 01 selection values. (STEP 01 skipped)"

      # Also ensure it's reflected in the config file when reusing
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "DATA_NIC"       "${DATA_NIC}"
      save_config_var "SPAN_NICS"     "${SPAN_NICS}"
      save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
      save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
      save_config_var "LV_LOCATION" "${LV_LOCATION}"
      save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

      # Reuse is 'success + nothing more to do in this step', so return 0 normally
      return 0
    fi
  fi

  ########################
  # 1) Sensor VM Count Configuration
  ########################
  SENSOR_VM_COUNT=1
  save_config_var "SENSOR_VM_COUNT" "${SENSOR_VM_COUNT}"

  ########################
  # 2) LV Location Configuration (Sensor only)
  ########################
  # LV location set to ubuntu-vg (OpenXDR method)
  local lv_location="ubuntu-vg"
  log "[STEP 01] LV location Auto configured: ${lv_location} (Existing ubuntu-vg Available space Use)"

  LV_LOCATION="${lv_location}"
  save_config_var "LV_LOCATION" "${LV_LOCATION}"

  ########################
  # 3) Select data disks for LVM (AIO storage)
  ########################
  log "[STEP 01] Select data disks for LVM storage (AIO)"

  # Initialize variables
  local root_info="OS Disk: detection failed (needs check)"
  local disk_list=()
  local all_disks

  # List all physical disks (exclude loop, ram; include only type disk)
  all_disks=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1, $2, $3}')

  if [[ -z "${all_disks}" ]]; then
    whiptail_msgbox "STEP 01 - Disk detection failed" "No physical disks found.\nCheck lsblk output." 12 70
    return 1
  fi

  # Iterate over disks
  while read -r d_name d_size d_model; do
    # Check if any child of the disk is mounted at /
    if lsblk "/dev/${d_name}" -r -o MOUNTPOINT | grep -qE "^/$"; then
      # OS disk found -> omit from list; keep for notice
      root_info="OS Disk: ${d_name} (${d_size}) ${d_model} -> Ubuntu Linux (excluded)"
    else
      # Data disk candidate -> add to checklist
      local flag="OFF"
      for selected in ${DATA_SSD_LIST:-}; do
        if [[ "${selected}" == "${d_name}" ]]; then
          flag="ON"
          break
        fi
      done
      disk_list+=("${d_name}" "${d_size}_${d_model}" "${flag}")
    fi
  done <<< "${all_disks}"

  # If no data disk candidates
  if [[ ${#disk_list[@]} -eq 0 ]]; then
    whiptail_msgbox "Warning" "No additional disks available for data.\n\nDetected OS disk:\n${root_info}" 12 70
    return 1
  fi

  # Build guidance message
  local msg_guide="Select disks for LVM/ES data storage (AIO).\n(Space: toggle, Enter: confirm)\n\n"
  msg_guide+="==================================================\n"
  msg_guide+=" [System protection] ${root_info}\n"
  msg_guide+="==================================================\n\n"
  msg_guide+="Select data disks from the list below:"

  # Calculate menu size dynamically for disk selection
  local disk_count=$(( ${#disk_list[@]} / 3 ))
  local menu_dims
  menu_dims=$(calc_menu_size "${disk_count}" 90 8)
  local menu_height menu_width menu_list_height
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"

  # Center-align the menu message
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
  # 4) NIC Selection (NAT mode only)
  ########################
  
  # NAT Mode: Select only 1 NAT uplink NIC
  if [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: Select only 1 NAT uplink NIC
    log "[STEP 01] NAT Mode - NAT uplink NIC selection (select one)"
    
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
      log "User canceled NAT uplink NIC selection."
      return 1
    }

    log "Selected NAT uplink NIC: ${nat_nic}"
    HOST_NIC="${nat_nic}"  # HOST_NIC stores NAT uplink NIC
    DATA_NIC=""  # DATA NIC is not used in NAT mode
    save_config_var "HOST_NIC" "${HOST_NIC}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    save_config_var "HOST_NIC_PCI" "$(get_if_pci "${nat_nic}")"
    save_config_var "HOST_NIC_MAC" "$(get_if_mac "${nat_nic}")"
    save_config_var "SENSOR_NET_MODE" "${net_mode}"
  else
    log "ERROR: Network mode must be NAT. Current: ${net_mode}"
    whiptail_msgbox "Configuration Error" "Network mode must be NAT.\n\nCurrent mode: ${net_mode}"
    return 1
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
    log "User canceled SPAN NIC selection."
    return 1
  }

  # whiptail output is "nic1" "nic2" form → Remove double quotes(Important)
  selected_span_nics=$(echo "${selected_span_nics}" | tr -d '"')

  log "Selected SPAN NICs(All): ${selected_span_nics}"
  SPAN_NICS="${selected_span_nics}"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  # All SPAN NICs are assigned to mds (single sensor)
  SPAN_NICS_MDS="${SPAN_NICS}"
  save_config_var "SPAN_NICS_MDS" "${SPAN_NICS_MDS}"

  log "SPAN NIC(mds): ${SPAN_NICS_MDS}"

  ########################
  # 5-1) Select HOST access NIC (for direct KVM host access only, 192.168.0.100/24)
  ########################
  log "[STEP 01] Host access NIC selection (for direct KVM host access)"
  
  # Get available NICs (exclude already selected NICs)
  # nic_list format: [NIC_name, description, NIC_name, description, ...]
  local available_nics=()
  local i
  for ((i=0; i<${#nic_list[@]}; i+=2)); do
    local nic_name="${nic_list[i]}"
    local nic_desc="${nic_list[i+1]}"
    # Exclude already selected NICs
    if [[ "${nic_name}" != "${HOST_NIC}" ]] && \
       [[ ! "${SPAN_NICS}" =~ ${nic_name} ]]; then
      available_nics+=("${nic_name}" "${nic_desc}")
    fi
  done
  
  if [[ ${#available_nics[@]} -eq 0 ]]; then
    log "[STEP 01] No available NICs for host access (all NICs are already used). Skipping host access NIC selection."
    HOST_ACCESS_NIC=""
  else
    # Calculate menu size dynamically
    menu_dims=$(calc_menu_size ${#available_nics[@]} 90 10)
    read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
    
    # Center-align menu message
    local msg_content="Select NIC for direct access (management) to KVM host.\n(This NIC will be automatically configured with 192.168.0.100/24 without gateway.)\n\nCurrent setting: ${HOST_ACCESS_NIC:-<none>}\n"
    local centered_msg
    centered_msg=$(center_menu_message "${msg_content}" "${menu_height}")
    
    local host_access_nic
    host_access_nic=$(whiptail --title "STEP 01 - Select Host Access NIC" \
                      --menu "${centered_msg}" \
                      "${menu_height}" "${menu_width}" "${menu_list_height}" \
                      "${available_nics[@]}" \
                      3>&1 1>&2 2>&3) || {
      log "User canceled HOST_ACCESS_NIC selection."
      HOST_ACCESS_NIC=""
    }
    
    if [[ -n "${host_access_nic}" ]]; then
      # Remove quotes from whiptail output
      host_access_nic=$(echo "${host_access_nic}" | tr -d '"')
      log "Selected HOST_ACCESS_NIC: ${host_access_nic}"
      HOST_ACCESS_NIC="${host_access_nic}"
      save_config_var "HOST_ACCESS_NIC" "${HOST_ACCESS_NIC}"
      save_config_var "HOST_ACCESS_NIC_PCI" "$(get_if_pci "${host_access_nic}")"
      save_config_var "HOST_ACCESS_NIC_MAC" "$(get_if_mac "${host_access_nic}")"
    else
      HOST_ACCESS_NIC=""
      save_config_var "HOST_ACCESS_NIC" "${HOST_ACCESS_NIC}"
    fi
  fi

  ########################
  # 6) SPAN NIC PF PCI Address Collection (PCI passthrough specific)
  ########################
  log "[STEP 01] SR-IOV based VF creation is not used (PF PCI direct assignment mode)."
  log "[STEP 01] Physical PCI address of SPAN NIC(PF)Collecting."

  local span_pci_list_mds=""

  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    # PCI passthrough mode: Directly use Physical Function (PF) PCI address
    for nic in ${SPAN_NICS_MDS}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address could not be found."
        continue
      fi
      span_pci_list_mds="${span_pci_list_mds} ${pci_addr}"
      log "[STEP 01] ${nic} (mds SPAN NIC) -> Physical PCI: ${pci_addr}"
    done

  fi

  SPAN_ATTACH_MODE="pci"

  # Store PCI list for mds
  SENSOR_SPAN_VF_PCIS_MDS="${span_pci_list_mds# }"
  save_config_var "SENSOR_SPAN_VF_PCIS_MDS" "${SENSOR_SPAN_VF_PCIS_MDS}"
  log "mds SPAN NIC PCI List: ${SENSOR_SPAN_VF_PCIS_MDS}"

  # Legacy combined(For compatibility) + SPAN_NIC_LIST Update
  SENSOR_SPAN_VF_PCIS="${SENSOR_SPAN_VF_PCIS_MDS}"
  save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"

  SPAN_NIC_LIST="${SPAN_NICS}"
  save_config_var "SPAN_NIC_LIST" "${SPAN_NIC_LIST}"
  save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
  log "SPAN NIC list saved: ${SPAN_NIC_LIST}"
  log "SPAN attachment mode: ${SPAN_ATTACH_MODE}"


  ########################
  # 7) Summary Display (Different messages per Network mode)
  ########################
  local summary
  local pci_label="SPAN NIC PCIs (PF Passthrough)"

  # NAT mode only
  if [[ "${net_mode}" == "nat" ]]; then
    summary=$(cat <<EOF
[STEP 01 Result Summary - NAT Mode]

- Sensor network mode : ${net_mode}
- LV location          : ${LV_LOCATION}
- NAT uplink NIC     : ${HOST_NIC}
- Data disks (LVM)  : ${DATA_SSD_LIST}
- SPAN NICs       : ${SPAN_NICS}
- SPAN attachment mode    : ${SPAN_ATTACH_MODE} (PCI passthrough only)
- ${pci_label}     : ${SENSOR_SPAN_VF_PCIS}

Configuration file: ${CONFIG_FILE}
EOF
)
  else
    summary="[STEP 01 Result Summary]

Unknown Network mode: ${net_mode}
"
  fi

  whiptail_msgbox "STEP 01 Completed" "${summary}" 18 80

  ### Change 5 (optional): Store once more just in case
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  # is STEPis successfully completed, so in the caller save_state state with Stored
}


step_02_hwe_kernel() {
  local STEP_ID="02_hwe_kernel"
  local STEP_NAME="02. HWE Kernel Installation"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 02] HWE Kernel Installation"
  log "[STEP 02] This step will install Hardware Enablement (HWE) kernel for better hardware support."
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
    echo "STEP 02 - HWE Kernel Installation Overview"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
      echo
    fi
    echo "📊 CURRENT STATUS:"
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
    echo
    echo "  • After STEP 05 (kernel tuning) completes,"
    echo "    the system will automatically reboot again"
    echo "    According to AUTO_REBOOT_AFTER_STEP_ID settings,"
    echo "    the host will automatically reboot only once per step"
  } > "${tmp_status}"


  # ... After calculating cur_kernel, hwe_installed, show Overview textbox ...

  if [[ "${hwe_installed}" == "yes" ]]; then
    local skip_msg="HWE kernel is already detected on this system.\n\n"
    skip_msg+="Status: ${hwe_status_detail}\n"
    skip_msg+="Current kernel: ${cur_kernel}\n\n"
    skip_msg+="Do you want to skip this STEP?\n\n"
    skip_msg+="(Yes: Skip / No: Continue with package update and verification)"
    if whiptail_yesno "STEP 02 - HWE Kernel Already Detected" "${skip_msg}" 18 80
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
    echo "STEP 02 - HWE Kernel Installation Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • Previous kernel (uname -r): ${cur_kernel}"
      echo "  • Current kernel (uname -r): ${new_kernel}"
      echo "  • HWE kernel status: ${hwe_now}"
      if [[ "${hwe_now}" == "yes" ]]; then
        echo "    ✅ ${hwe_now_detail}"
      else
        echo "    ⚠️  ${hwe_now_detail}"
        echo "    Expected package: ${pkg_name}"
      fi
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. Package update (apt update)"
      echo "  2. System upgrade (apt full-upgrade -y)"
      echo "  3. Network tools installation (ifupdown, net-tools)"
      echo "     - Required for STEP 03 (NIC configuration)"
      echo "  4. HWE kernel package installation (${pkg_name})"
      echo "     - Would be skipped if already installed"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 KERNEL STATUS:"
      echo "  • HWE kernel status: ${hwe_now}"
      if [[ "${hwe_now}" == "yes" ]]; then
        echo "    ✅ ${hwe_now_detail}"
      else
        echo "    ⚠️  ${hwe_now_detail}"
        echo "    Expected package: ${pkg_name}"
        echo "    Note: HWE kernel will be active after reboot"
      fi
    fi
    echo
    echo "📝 IMPORTANT NOTES:"
    echo "  • New HWE kernel will be applied after next host reboot"
    echo "    (uname -r output may not change until after reboot)"
    echo
    echo "  • After STEP 03 (NIC/Network configuration) completes,"
    echo "    the system will automatically reboot"
    echo "    The new HWE kernel will be applied during that reboot"
    echo
    echo "  • After STEP 05 (kernel tuning) completes,"
    echo "    the system will automatically reboot again"
    echo "    According to AUTO_REBOOT_AFTER_STEP_ID settings,"
    echo "    the host will automatically reboot only once per step"
    echo
    echo "💡 TIP: After reboot, verify the new kernel with:"
    echo "   uname -r"
    echo "   dpkg -l | grep ${pkg_name}"
  } > "${tmp_status}"


  show_textbox "STEP 02 Result Summary" "${tmp_status}"

  # reboot itself STEP 05 upon completion, common logic(AUTO_REBOOT_AFTER_STEP_ID)performed only once in
  log "[STEP 02] HWE Kernel Installation step has been completed. New HWE kernel will be applied on host reboot."
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 02] HWE kernel installation completed successfully. New kernel will be active after reboot."

  return 0
}


step_03_nic_ifupdown() {
  local STEP_ID="03_nic_ifupdown"
  local STEP_NAME="03. NIC Name/ifupdown Switch and Network Configuration"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 03] NIC Name/ifupdown Switch and Network Configuration"
  log "[STEP 03] This step will configure network interfaces using ifupdown (NAT mode only)."
  load_config

  # Force NAT mode only
  local net_mode="nat"
  SENSOR_NET_MODE="nat"
  log "[STEP 03] Sensor network mode: ${net_mode} (NAT only)"

  # Execute NAT mode only
    log "[STEP 03] NAT Mode - OpenXDR execute NAT configuration method"
    step_03_nat_mode 
    return $?
}

#######################################
# STEP 03 - NAT Mode (OpenXDR NAT configuration)
#######################################
step_03_nat_mode() {
  log "[STEP 03 NAT Mode] OpenXDR NAT-based network configuration (Declarative)"
  load_config

  if [[ -z "${HOST_NIC:-}" ]]; then
    whiptail_msgbox "STEP 03 - NAT NIC Not configured" "NAT uplink NIC (HOST_NIC) is not set.\n\nPlease select NAT uplink NIC in STEP 01 first." 12 70
    log "HOST_NIC (NAT uplink NIC) is empty, so STEP 03 NAT Mode cannot proceed."
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

  local host_access_pci=""
      if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
    local desired_host_access_if
    desired_host_access_if="$(resolve_ifname_by_identity "${HOST_ACCESS_NIC_PCI:-}" "${HOST_ACCESS_NIC_MAC:-}")"
    [[ -z "${desired_host_access_if}" ]] && desired_host_access_if="${HOST_ACCESS_NIC}"
    if [[ ! -d "/sys/class/net/${desired_host_access_if}" ]]; then
      whiptail_msgbox "STEP 03 - NIC Not Found" "HOST_ACCESS_NIC '${desired_host_access_if}' does not exist on this system.\n\nRe-run STEP 01 and select the correct NIC." 12 70
      log "ERROR: HOST_ACCESS_NIC '${desired_host_access_if}' not found in /sys/class/net"
      return 1
    fi
    host_access_pci="${HOST_ACCESS_NIC_PCI:-}"
    if [[ -z "${host_access_pci}" ]]; then
      host_access_pci="$(readlink -f "/sys/class/net/${desired_host_access_if}/device" 2>/dev/null | awk -F'/' '{print $NF}' || true)"
    fi
    if [[ -z "${host_access_pci}" ]]; then
      whiptail_msgbox "STEP 03 - PCI Information Error" "Could not retrieve PCI bus information for HOST_ACCESS_NIC.\n\nNIC: ${desired_host_access_if}\n\nPlease re-run STEP 01 to verify and select the correct NIC." 14 80
      log "ERROR: HOST_ACCESS_NIC PCI information not found for ${desired_host_access_if}"
      return 1
    fi
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
  new_ip="$(whiptail_inputbox "STEP 03 - mgt NIC IP Configuration" "Enter NAT uplink NIC (mgt) IP address:" "${def_ip}" 8 60)" || return 1
  [[ -z "${new_ip}" ]] && return 1
  new_prefix="$(whiptail_inputbox "STEP 03 - mgt Prefix" "Enter subnet prefix length (/ value).\nExample: 24" "${def_prefix}" 8 60)" || return 1
  [[ -z "${new_prefix}" ]] && return 1
  new_gw="$(whiptail_inputbox "STEP 03 - Gateway Configuration" "Enter gateway IP:" "${def_gw}" 8 60)" || return 1
  [[ -z "${new_gw}" ]] && return 1
  new_dns="$(whiptail_inputbox "STEP 03 - DNS configuration" "Please enter DNS server IPs (space-separated):" "${def_dns}" 8 70)" || return 1
  [[ -z "${new_dns}" ]] && return 1

  local netmask
  netmask="$(cidr_to_netmask "${new_prefix}")"

  save_config_var "MGT_IP_ADDR" "${new_ip}"
  save_config_var "MGT_IP_PREFIX" "${new_prefix}"
  save_config_var "MGT_GW" "${new_gw}"
  save_config_var "MGT_DNS" "${new_dns}"

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

  # Host access NIC (hostmgmt) udev rule
  local hostmgmt_udev_rule=""
  if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
    local host_access_pci
    local actual_host_access_nic=""
    actual_host_access_nic="$(get_effective_nic "HOST_ACCESS")" || true
    [[ -z "${actual_host_access_nic}" ]] && actual_host_access_nic="${HOST_ACCESS_NIC}"
    host_access_pci=$(readlink -f "/sys/class/net/${actual_host_access_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ -n "${host_access_pci}" ]]; then
      hostmgmt_udev_rule="

# Host direct management interface (no gateway) PCI-bus ${host_access_pci}
SUBSYSTEM==\"net\", ACTION==\"add\", KERNELS==\"${host_access_pci}\", NAME:=\"hostmgmt\""
      log "[STEP 03 NAT Mode] Host access NIC ${HOST_ACCESS_NIC} (PCI: ${host_access_pci}) will be renamed to hostmgmt"
    else
      log "WARNING: HOST_ACCESS_NIC ${HOST_ACCESS_NIC} PCI address could not be found. Skipping hostmgmt udev rule."
    fi
  fi

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_lib_file="/usr/lib/udev/rules.d/99-custom-ifnames.rules"
  local udev_content
  udev_content=$(cat <<EOF
# XDR NAT Mode - Custom interface names
SUBSYSTEM=="net", ACTION=="add", KERNELS=="${nat_pci}", NAME:="mgt"${hostmgmt_udev_rule}${span_udev_rules}
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
    log "udev rule file creation completed (mgt + hostmgmt + SPAN NIC name fixed)"
    log "[STEP 03 NAT Mode] Updating initramfs to apply udev rename on reboot"
    run_cmd "sudo update-initramfs -u -k all"
  fi

  #######################################
  # 2.5) Update state file with renamed interface name (NAT Mode)
  #######################################
  log "[STEP 03 NAT Mode] Updating state file with renamed interface name"

  if [[ "${DRY_RUN}" -ne 1 ]]; then
    save_config_var "HOST_NIC_EFFECTIVE" "mgt"
    save_config_var "HOST_NIC" "mgt"
    save_config_var "HOST_NIC_RENAMED" "mgt"
    if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
      save_config_var "HOST_ACCESS_NIC_EFFECTIVE" "hostmgmt"
      save_config_var "HOST_ACCESS_NIC" "hostmgmt"
      log "[STEP 03 NAT Mode] HOST_ACCESS_NIC will be renamed to hostmgmt after reboot"
    else
      log "[INFO] HOST_ACCESS_NIC not set; hostmgmt will not be configured"
    fi
  else
    log "[DRY-RUN] Would save HOST_NIC_EFFECTIVE/HOST_ACCESS_NIC_EFFECTIVE"
  fi

  #######################################
  # 3) /etc/network/interfaces configuration (Declarative)
  #######################################
  log "[STEP 03 NAT Mode] Configuring /etc/network/interfaces (declarative)"

  local iface_file="/etc/network/interfaces"
  local iface_dir="/etc/network/interfaces.d"
  local mgt_cfg="${iface_dir}/01-mgt.cfg"
  local host_cfg="${iface_dir}/02-hostmgmt.cfg"

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
    log "[DRY-RUN] Will write to ${mgt_cfg}:\n${mgt_content}"
  else
    printf "%s\n" "${mgt_content}" > "${mgt_cfg}"
  fi

  if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
    local host_content
    host_content=$(cat <<EOF
auto hostmgmt
iface hostmgmt inet static
    address 192.168.0.100
    netmask 255.255.255.0
EOF
)
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will write the following content to ${host_cfg}:\n${host_content}"
    else
      printf "%s\n" "${host_content}" > "${host_cfg}"
    fi
  else
    log "[STEP 03 NAT Mode] HOST_ACCESS_NIC not set, skipping hostmgmt interface configuration"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      rm -f "${host_cfg}" 2>/dev/null || true
    fi
  fi

  #######################################
  # 3-1) File-based verification (no runtime checks)
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[STEP 03] DRY-RUN: Skipping file-based verification"
  else
    local verify_failed=0
    local verify_errors=""

    if [[ ! -f "${udev_file}" ]] || [[ ! -f "${udev_lib_file}" ]] || \
       ! grep -qE "KERNELS==\"${nat_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null || \
       ! grep -qE "KERNELS==\"${nat_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"mgt\"" "${udev_lib_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- udev rules missing or invalid: ${udev_file}"
      verify_errors="${verify_errors}\n- udev rules missing or invalid: ${udev_lib_file}"
    fi

    if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
      if [[ -z "${host_access_pci}" ]] || \
         ! grep -qE "KERNELS==\"${host_access_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"hostmgmt\"" "${udev_file}" 2>/dev/null || \
         ! grep -qE "KERNELS==\"${host_access_pci}\"[[:space:]]*,[[:space:]]*NAME:=\"hostmgmt\"" "${udev_lib_file}" 2>/dev/null; then
        verify_failed=1
        verify_errors="${verify_errors}\n- hostmgmt udev rule missing or invalid"
      fi
    fi

    if [[ ! -f "${iface_file}" ]] || \
       ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' "${iface_file}" 2>/dev/null || \
       ! grep -qE '^[[:space:]]*auto[[:space:]]+lo([[:space:]]|$)' "${iface_file}" 2>/dev/null || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+lo[[:space:]]+inet[[:space:]]+loopback([[:space:]]|$)' "${iface_file}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- /etc/network/interfaces is missing required base content"
    fi

    if [[ ! -f "${mgt_cfg}" ]] || \
       ! grep -qE '^[[:space:]]*iface[[:space:]]+mgt[[:space:]]+inet[[:space:]]+static' "${mgt_cfg}" 2>/dev/null || \
       ! grep -qE "^[[:space:]]*address[[:space:]]+${new_ip}$" "${mgt_cfg}" 2>/dev/null || \
       ! grep -qE "^[[:space:]]*netmask[[:space:]]+${netmask}$" "${mgt_cfg}" 2>/dev/null || \
       ! grep -qE "^[[:space:]]*gateway[[:space:]]+${new_gw}$" "${mgt_cfg}" 2>/dev/null || \
       ! grep -qE "^[[:space:]]*dns-nameservers[[:space:]]+${new_dns}$" "${mgt_cfg}" 2>/dev/null; then
      verify_failed=1
      verify_errors="${verify_errors}\n- mgt config invalid: ${mgt_cfg}"
    fi

    if [[ -n "${HOST_ACCESS_NIC:-}" ]]; then
      if [[ ! -f "${host_cfg}" ]] || \
         ! grep -qE '^[[:space:]]*iface[[:space:]]+hostmgmt[[:space:]]+inet[[:space:]]+static' "${host_cfg}" 2>/dev/null || \
         ! grep -qE '^[[:space:]]*address[[:space:]]+192\.168\.0\.100$' "${host_cfg}" 2>/dev/null || \
         ! grep -qE '^[[:space:]]*netmask[[:space:]]+255\.255\.255\.0$' "${host_cfg}" 2>/dev/null; then
        verify_failed=1
        verify_errors="${verify_errors}\n- hostmgmt config invalid: ${host_cfg}"
      fi
    fi

    if [[ "${verify_failed}" -eq 1 ]]; then
      whiptail_msgbox "STEP 03 - File Verification Failed" "설정 파일 검증에 실패했습니다.\n\n${verify_errors}\n\n파일 내용을 확인 후 다시 실행해주세요." 16 85
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

  #######################################
  # 4) Process SPAN NICs
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
- NAT uplink NIC  : ${HOST_NIC} → mgt (${new_ip}/${netmask})
- Gateway      : ${new_gw}
- DNS          : ${new_dns}
- Sensor VM      : Connected to virbr0 NAT bridge (192.168.122.0/24)${HOST_ACCESS_NIC:+
- Host access NIC : ${HOST_ACCESS_NIC} → hostmgmt (192.168.0.100/24, no gateway)}
- SPAN NICs   : ${SPAN_NIC_LIST:-None} (PCI passthrough specific)${span_summary_nat}

udev rule     : /etc/udev/rules.d/99-custom-ifnames.rules + /usr/lib/udev/rules.d/99-custom-ifnames.rules
network configuration  : /etc/network/interfaces${HOST_ACCESS_NIC:+
hostmgmt configuration : /etc/network/interfaces.d/02-hostmgmt.cfg}

※ Reboot is required due to network configuration changes.
  According to AUTO_REBOOT_AFTER_STEP_ID settings, auto reboot will occur after STEP completion.
  NAT network (mgt NIC) will be applied after reboot.
EOF
)

  whiptail_msgbox "STEP 03 NAT Mode Completed" "${summary}" 20 80

  log "[STEP 03 NAT Mode] NAT network configuration completed. NAT configuration will be applied after reboot."
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 03] Network configuration completed successfully. Changes will be applied after reboot."

  return 0
}



step_04_kvm_libvirt() {
  local STEP_ID="04_kvm_libvirt"
  local STEP_NAME="04. KVM / Libvirt Installation and Basic Configuration"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 04] KVM / Libvirt Installation and Basic Configuration"
  log "[STEP 04] This step will install and configure KVM/libvirt for VM management."
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

  # Force NAT mode only
  local net_mode="nat"
  SENSOR_NET_MODE="nat"
  log "[STEP 04] Sensor network mode: ${net_mode} (NAT only)"

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
    echo "  4) default libvirt network(virbr0) NAT configure (NAT mode)"
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
      "bridge-utils"
      "virt-manager"
      "cpu-checker"
      "qemu-utils"
      "virtinst"      # Additional (PDF guide requirement)
      "genisoimage"   # Additional (for Cloud-init ISO creation)
      "ipset"         # Required for libvirt hooks DNAT (UI port filtering)
    )

  local pkg_count=0
  local total_pkgs=${#packages[@]}
  
  for pkg in "${packages[@]}"; do
    ((pkg_count++))
    echo "=== Installing package $pkg_count/$total_pkgs: $pkg ==="
    log "Installing package: $pkg ($pkg_count/$total_pkgs)"
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg}"
    echo "=== $pkg Installation completed ==="
  done
  
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
  # 4) default libvirt network configuration (NAT mode only)
  #######################################
  
  if [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: OpenXDR NAT network XML create
    log "[STEP 04] NAT Mode - OpenXDR NAT network XML create (virbr0/192.168.122.0/24)"
    
    # Remove existing default network
    run_cmd "sudo virsh net-destroy default || true"
    run_cmd "sudo virsh net-undefine default || true"
    
    # OpenXDR methodof  NAT network XML create
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
  <firewall>
    <driver name='none'/>
  </firewall>
</network>
EOF
    
    log "NAT network XML file created: ${default_net_xml}"
    
    # Define and activate NAT network
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
    
    log "Sensor VM will use virbr0 NAT bridge (192.168.122.0/24)."
    
  else
    log "ERROR: Unknown network mode: ${net_mode}"
    return 1
  fi

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
    echo "STEP 04 - KVM / Libvirt Installation Summary"
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
      echo "  4. NAT Mode Network Configuration:"
      echo "     - OpenXDR NAT network (virbr0/192.168.122.0/24) would be created"
      echo "     - AIO and Sensor VMs will use virbr0 NAT bridge"
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
      echo "  • ipset (required for libvirt hooks DNAT)"
      echo
      echo "👤 USER CONFIGURATION:"
      echo "  • Current user added to libvirt group"
      echo "    (Group changes require logout/login or reboot)"
      echo
      echo "🔧 SERVICE STATUS:"
      echo "  • libvirtd: enabled and started"
      echo "  • virtlogd: enabled and started"
      echo
      echo "🌐 NETWORK CONFIGURATION (NAT Mode):"
      echo "  • OpenXDR NAT network: created and started"
      echo "  • Network: virbr0 (192.168.122.0/24)"
      echo "  • AIO VM will use virbr0 NAT bridge (192.168.122.2)"
      echo "  • Sensor VM will use virbr0 NAT bridge (192.168.122.3)"
      echo
      echo "⚠️  IMPORTANT NOTES:"
      echo "  • User group changes will be applied after next login/reboot"
      echo "  • BIOS/UEFI must have virtualization (VT-x/VT-d) enabled"
      echo "  • Verify KVM with: kvm-ok"
      echo "  • Verify libvirt with: virsh list --all"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 04 Result Summary" "${tmp_info}"

  log "[STEP 04] KVM / Libvirt install and configuration completed"
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 04] KVM/libvirt installation and configuration completed successfully."

  return 0
}


step_05_kernel_tuning() {
  local STEP_ID="05_kernel_tuning"
  local STEP_NAME="05. Kernel Parameters / KSM / Swap Tuning"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 05] Kernel Parameters / KSM / Swap Tuning"
  log "[STEP 05] This step will configure kernel parameters, disable KSM, and optionally disable swap."
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

  if ! whiptail_yesno "STEP 05 Execution Confirmation" "Do you want to proceed with kernel tuning?"
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
  # XDR AIO & Sensor Installer kernel tuning (PDF guide compliance)
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
    echo "STEP 05 - Kernel Tuning Configuration Summary"
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

  log "[STEP 05] kernel tuning configuration completed. Reboot is required."
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 05] Kernel tuning configuration completed successfully. Reboot is required for changes to take effect."

  return 0
}


step_06_libvirt_hooks() {
  log "[STEP 06] libvirt Hooks Installation (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  # Force NAT mode only
  local net_mode="nat"
  SENSOR_NET_MODE="nat"
  log "[STEP 06] Sensor network mode: ${net_mode} (NAT only)"
  
  # Execute NAT mode only
    log "[STEP 06] NAT Mode - Installing OpenXDR NAT hooks"
    step_06_nat_hooks
    return $?
}

#######################################
# STEP 06 - NAT Mode (OpenXDR NAT hooks configuration)
#######################################
step_06_nat_hooks() {
  local STEP_ID="06_libvirt_hooks"
  local STEP_NAME="06. libvirt Hooks Installation"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 06 NAT Mode] OpenXDR NAT libvirt Hooks Installation"
  log "[STEP 06] This step will install libvirt hooks for NAT/DNAT configuration and OOM monitoring."

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
    echo "- /etc/libvirt/hooks/qemu (AIO & Sensor DNAT + OOM monitoring)"
    echo
    echo "VM network configuration:"
    echo "- AIO VM name: aio"
    echo "- AIO internal IP: 192.168.122.2"
    echo "- Sensor VM name: mds"
    echo "- Sensor internal IP: 192.168.122.3"
    echo "- NAT bridge: virbr0 (192.168.122.0/24)"
    echo "- External interface: mgt"
    echo
    echo "DNAT port forwarding:"
    echo "- AIO: SSH(2222), UI(80,443), TCP(6640-6648,8443,8888,8889), UDP(162)"
    echo "- Sensor: SSH(2223), sensor forwarder ports"
  } > "${tmp_info}"

  show_textbox "STEP 06 NAT Mode - Installation Overview" "${tmp_info}"

  if ! whiptail_yesno "STEP 06 NAT Mode Execution Confirmation" "Install libvirt hooks for NAT Mode.\n\n- Apply OpenXDR NAT structure\n- AIO VM (aio) DNAT configuration\n- Sensor VM (mds) DNAT configuration\n- OOM monitoring function\n\nDo you want to continue?" 16 70
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

  log "[STEP 06 NAT Mode] Creating ${HOOK_QEMU} (AIO & Sensor DNAT + OOM monitoring)"

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
# Last Update: 2025-12-06 (AIO-Sensor unified)
# AIO + Sensor (mds) NAT / forwarding configuration

# UI exception list (internal management IP addresses of AIO, mds)
UI_EXC_LIST=(192.168.122.2 192.168.122.3)
IPSET_UI='ui'

# Create ipset ui if missing + add exception IPs
# Note: ipset package must be installed (STEP 04)
if command -v ipset >/dev/null 2>&1; then
  IPSET_CONFIG=$(echo -n $(ipset list $IPSET_UI 2>/dev/null))
  if ! [[ $IPSET_CONFIG =~ $IPSET_UI ]]; then
    if ipset create $IPSET_UI hash:ip 2>/dev/null; then
      for IP in ${UI_EXC_LIST[@]}; do
        ipset add $IPSET_UI $IP 2>/dev/null || true
      done
    else
      echo "ERROR: Failed to create ipset '$IPSET_UI'. UI port DNAT rules may not work correctly." >&2
      echo "Please check: sudo ipset list" >&2
    fi
  fi
else
  echo "WARNING: ipset command not found. UI port DNAT rules may not work correctly." >&2
  echo "Please install ipset package: sudo apt install -y ipset" >&2
  echo "Then re-run: sudo /etc/libvirt/hooks/qemu aio reconnect" >&2
fi

########################
# aio NAT / forwarding
########################
if [ "${1}" = "aio" ]; then
  GUEST_IP=192.168.122.2
  HOST_SSH_PORT=2222
  GUEST_SSH_PORT=22
  UI_PORTS=(80 443)
  TCP_PORTS=(6640 6641 6642 6643 6644 6645 6646 6647 6648 8443 8888 8889)
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
    for PORT in ${UI_PORTS[@]}; do
      /sbin/iptables -t nat -D PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_UI src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
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
    for PORT in ${UI_PORTS[@]}; do
      /sbin/iptables -t nat -I PREROUTING -i $MGT_INTF -p tcp -m set ! --match-set $IPSET_UI src --dport $PORT -j DNAT --to $GUEST_IP:$PORT
    done
    # save last known good pid
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# mds NAT / forwarding
########################
if [ "${1}" = "mds" ]; then
  GUEST_IP=192.168.122.3
  HOST_SSH_PORT=2223
  GUEST_SSH_PORT=22
  TCP_PORTS=(514 2055 5044 5123 5100:5200 5500:5800 5900)
  VXLAN_PORTS=(4789 8472)
  UDP_PORTS=(514 2055 5044 5100:5200 5500:5800 5900)
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

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write AIO & Sensor DNAT + OOM monitoring content to ${HOOK_QEMU}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
    sudo chmod +x "${HOOK_QEMU}"
  fi

  #######################################
  # 4) Install OOM recovery scripts (last_known_good_pid, check_vm_state)
  #######################################
  log "[STEP 06 NAT Mode] Installing OOM recovery scripts (last_known_good_pid, check_vm_state)"

  local _DRY="${DRY_RUN:-0}"

  # 1) Create /usr/bin/last_known_good_pid (per docs)
  log "[STEP 06 NAT Mode] Creating /usr/bin/last_known_good_pid script"
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
  log "[STEP 06 NAT Mode] Creating /usr/bin/check_vm_state script"
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would create /usr/bin/check_vm_state script"
  else
    local check_vm_state_content
    check_vm_state_content=$(cat <<'EOF'
#!/bin/bash
VM_LIST=(aio mds)
RUN_DIR=/var/run/libvirt/qemu

for VM in ${VM_LIST[@]}; do
    # Detect if VM is down (.xml and .pid absent)
    if [ ! -e ${RUN_DIR}/${VM}.xml -a ! -e ${RUN_DIR}/${VM}.pid ]; then
        if [ -e ${RUN_DIR}/${VM}.lkg ]; then
            LKG_PID=$(cat ${RUN_DIR}/${VM}.lkg)

            # Check dmesg to see if OOM-killer killed that PID
            if dmesg | grep "Out of memory: Kill process $LKG_PID" > /dev/null 2>&1; then
                virsh start $VM
            fi
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
      log "[STEP 06 NAT Mode] Added/updated SHELL=/bin/bash and check_vm_state entries in root crontab."
    else
      log "[STEP 06 NAT Mode] root crontab already has SHELL=/bin/bash and check_vm_state entries."
    fi
  fi

  #######################################
  # 5) Completed message
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 06 NAT Mode Completed]

OpenXDR based NAT libvirt hooks have been installed.

Installed hooks:
- /etc/libvirt/hooks/network (NAT MASQUERADE)
- /etc/libvirt/hooks/qemu (AIO & Sensor DNAT + OOM monitoring)

VM network configuration:
- AIO VM name: aio
- AIO internal IP: 192.168.122.2
- Sensor VM name: mds
- Sensor internal IP: 192.168.122.3
- NAT bridge: virbr0 (192.168.122.0/24)
- External access: DNAT through mgt interface

AIO DNAT ports: SSH(2222), UI(80,443), TCP(6640-6648,8443,8888,8889), UDP(162)
Sensor DNAT ports: SSH(2223), sensor forwarder ports
OOM monitoring: enabled

📝 NEXT STEPS:
  • libvirtd restart is required for hooks to take effect
  • Proceed to STEP 07 (LVM Storage Configuration)
EOF
)

  whiptail_msgbox "STEP 06 NAT Mode Completed" "${summary}" 18 80

  log "[STEP 06 NAT Mode] NAT libvirt hooks installation completed"
  
  # Display DNAT verification commands
  log "[STEP 06] DNAT verification commands:"
  log "  • Check iptables DNAT rules: sudo iptables -t nat -L PREROUTING -v -n | grep -E '(443|2222|80)'"
  log "  • Check FORWARD rules: sudo iptables -L FORWARD -v -n | grep virbr0"
  log "  • Check mgt interface: ip link show mgt"
  log "  • Check ipset: sudo ipset list ui"
  log "  • Check libvirt hooks: ls -la /etc/libvirt/hooks/"
  log "  • Manually trigger hook (if needed): sudo /etc/libvirt/hooks/qemu aio reconnect"
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 06] Libvirt hooks installation completed successfully. DNAT and OOM monitoring are configured."

  return 0
}


step_07_lvm_storage() {
  local STEP_ID="07_lvm_storage"
  local STEP_NAME="07. LVM Storage Configuration (AIO)"
  
  log "[STEP 07] Start LVM storage configuration (AIO)"

  load_config

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

  local AIO_ROOT_LV="lv_aio_root"
  local ES_VG="vg_aio"
  local ES_LV="lv_aio"

  # Debug: Log DATA_SSD_LIST value after load_config
  log "[STEP 07] DATA_SSD_LIST value after load_config: '${DATA_SSD_LIST:-<empty>}'"
  
  # Check if DATA_SSD_LIST is empty or contains only whitespace
  # Also check if it's unset or empty string
  local data_ssd_list_trimmed
  data_ssd_list_trimmed="${DATA_SSD_LIST// /}"
  data_ssd_list_trimmed="${data_ssd_list_trimmed//	/}"  # Remove tabs too
  
  if [[ -z "${DATA_SSD_LIST:-}" ]] || [[ -z "${data_ssd_list_trimmed}" ]]; then
    log "[STEP 07] ERROR: DATA_SSD_LIST is empty or contains only whitespace"
    log "[STEP 07] Current CONFIG_FILE: ${CONFIG_FILE}"
    if [[ -f "${CONFIG_FILE}" ]]; then
      log "[STEP 07] CONFIG_FILE exists, checking contents..."
      local config_data_ssd
      config_data_ssd=$(grep "^DATA_SSD_LIST=" "${CONFIG_FILE}" | cut -d'=' -f2- | tr -d '"' || echo "")
      log "[STEP 07] DATA_SSD_LIST from CONFIG_FILE: '${config_data_ssd}'"
      if [[ -n "${config_data_ssd}" ]]; then
        log "[STEP 07] WARNING: DATA_SSD_LIST exists in CONFIG_FILE but was not loaded properly"
        log "[STEP 07] Attempting to reload from CONFIG_FILE..."
        # Try to reload the specific variable
        eval "$(grep "^DATA_SSD_LIST=" "${CONFIG_FILE}")"
        log "[STEP 07] DATA_SSD_LIST after manual reload: '${DATA_SSD_LIST:-<empty>}'"
        # Re-check after manual reload
        data_ssd_list_trimmed="${DATA_SSD_LIST// /}"
        data_ssd_list_trimmed="${data_ssd_list_trimmed//	/}"
        if [[ -z "${DATA_SSD_LIST:-}" ]] || [[ -z "${data_ssd_list_trimmed}" ]]; then
          log "[STEP 07] ERROR: DATA_SSD_LIST still empty after manual reload"
        else
          log "[STEP 07] SUCCESS: DATA_SSD_LIST loaded after manual reload: ${DATA_SSD_LIST}"
        fi
      else
        log "[STEP 07] DATA_SSD_LIST not found in CONFIG_FILE or is empty"
      fi
    else
      log "[STEP 07] CONFIG_FILE does not exist: ${CONFIG_FILE}"
    fi
    
    # Final check after potential manual reload
    data_ssd_list_trimmed="${DATA_SSD_LIST// /}"
    data_ssd_list_trimmed="${data_ssd_list_trimmed//	/}"
    if [[ -z "${DATA_SSD_LIST:-}" ]] || [[ -z "${data_ssd_list_trimmed}" ]]; then
      whiptail_msgbox "STEP 07 - data disks not set" "DATA_SSD_LIST is empty or not configured.\n\nPlease re-run STEP 01 to select data disks.\n\nCurrent value: '${DATA_SSD_LIST:-<empty>}'\n\nCONFIG_FILE: ${CONFIG_FILE}" 16 70
      log "DATA_SSD_LIST empty; cannot proceed with STEP 07."
      return 1
    fi
  fi
  
  log "[STEP 07] DATA_SSD_LIST is set: ${DATA_SSD_LIST}"

  #######################################
  # If LVM/mounts seem present, ask to skip
  #######################################
  local already_lvm=0

  # ES_VG, UBUNTU_VG, AIO_ROOT_LV are predefined above
  if vgs "${ES_VG}" >/dev/null 2>&1 && \
     lvs "${UBUNTU_VG}/${AIO_ROOT_LV}" >/dev/null 2>&1; then
    # Also check /stellar/aio mount
    if mount | grep -qE "on /stellar/aio "; then
      already_lvm=1
    fi
  fi

  if [[ "${already_lvm}" -eq 1 ]]; then
    if whiptail_yesno "STEP 07 - appears already configured" "vg_aio / lv_aio and ${UBUNTU_VG}/${AIO_ROOT_LV}\nplus /stellar/aio mount already exist.\n\nThis STEP recreates disk partitions and should not normally be rerun.\n\nSkip this STEP?"
    then
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
    echo "     - vg_aio (for ES data storage)"
    echo "     - ${UBUNTU_VG} (for AIO root volume)"
    echo "     Note: Sensor root volume will be created in ${UBUNTU_VG} during STEP 10"
    echo "  7. Create Logical Volumes (LV) for AIO:"
    echo "     - lv_aio (ES data for AIO)"
    echo "     - ${AIO_ROOT_LV} (AIO root, 545GB)"
    echo "     Note: Sensor LV (lv_sensor_root_mds) will be created during STEP 10"
    echo "  8. Format volumes with ext4"
    echo "  9. Mount volume at /stellar/aio (AIO root)"
    echo "     Note: Sensor mount (/var/lib/libvirt/images/mds) will be configured during STEP 10"
    echo "  10. Add entry to /etc/fstab"
    echo "  11. Set ownership to stellar:stellar"
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • This operation is IRREVERSIBLE"
    echo "  • All data on selected disks will be lost"
    echo "  • Ensure you have backups if needed"
    echo "  • OS disk is automatically excluded from selection"
    echo
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes will be made"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 07 - Pre-execution warning and actions" "${tmp_info}"

  if ! whiptail_yesno "STEP 07 - WARNING" "All existing partitions/data on /dev/${DATA_SSD_LIST}\nwill be deleted and used exclusively for LVM.\n\nThis operation is IRREVERSIBLE.\n\nContinue?"
  then
    log "User canceled STEP 07 disk initialization."
    return 0
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

  #######################################
  # 2) Create PV / VG / LV (for ES data)
  #######################################
  log "[STEP 07] Create ES-only VG/LV (vg_aio / lv_aio)"

  local pv_list=""
  local stripe_count=0
  for d in ${DATA_SSD_LIST}; do
    pv_list+=" /dev/${d}1"
    ((stripe_count++))
  done

  # pvcreate
  run_cmd "sudo pvcreate${pv_list}"

  # vgcreate vg_aio
  run_cmd "sudo vgcreate ${ES_VG}${pv_list}"

  # lvcreate --extents 100%FREE --stripes <N> --name lv_aio vg_aio
  run_cmd "sudo lvcreate --extents 100%FREE --stripes ${stripe_count} --name ${ES_LV} ${ES_VG}"

  #######################################
  # 3) Create AIO Root LV (ubuntu-vg)
  #######################################
  log "[STEP 07] Create AIO Root LV (${UBUNTU_VG}/${AIO_ROOT_LV})"

  if lvs "${UBUNTU_VG}/${AIO_ROOT_LV}" >/dev/null 2>&1; then
    log "LV ${UBUNTU_VG}/${AIO_ROOT_LV} already exists → skip create"
  else
    run_cmd "sudo lvcreate -L 545G -n ${AIO_ROOT_LV} ${UBUNTU_VG}"
  fi

  #######################################
  # 4) mkfs.ext4 (AIO Root + ES Data)
  #######################################
  log "[STEP 07] Format LVs (mkfs.ext4)"

  local DEV_AIO_ROOT="/dev/${UBUNTU_VG}/${AIO_ROOT_LV}"
  local DEV_ES_DATA="/dev/${ES_VG}/${ES_LV}"

  if ! blkid "${DEV_AIO_ROOT}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_AIO_ROOT}"
  else
    log "Filesystem already exists: ${DEV_AIO_ROOT} → skip mkfs"
  fi

  if ! blkid "${DEV_ES_DATA}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_ES_DATA}"
  else
    log "Filesystem already exists: ${DEV_ES_DATA} → skip mkfs"
  fi

  #######################################
  # 5) Create mount points
  #######################################
  log "[STEP 07] Create /stellar/aio directory"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /stellar/aio"
  else
    sudo mkdir -p /stellar/aio
  fi

  #######################################
  # 6) Add entries to /etc/fstab (per docs)
  #######################################
  log "[STEP 07] Register /etc/fstab entry"

  local FSTAB_AIO_LINE="${DEV_AIO_ROOT} /stellar/aio ext4 defaults,noatime 0 2"
  append_fstab_if_missing "${FSTAB_AIO_LINE}" "/stellar/aio"

  #######################################
  # 7) Run mount -a and verify
  #######################################
  log "[STEP 07] Run mount -a and verify mount state"

  run_cmd "sudo systemctl daemon-reload"
  run_cmd "sudo mount -a"

  #######################################
  # 7.5) Change ownership of /stellar (after mount)
  #######################################
  log "[STEP 07] Set /stellar ownership to stellar:stellar (per docs)"

  if id stellar >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo chown -R stellar:stellar /stellar"
    else
      run_cmd "sudo chown -R stellar:stellar /stellar"
      log "[STEP 07] /stellar ownership update complete"
    fi
  else
    log "[WARN] 'stellar' user not found; skipping chown."
  fi

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
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • LVM volumes: Would be created"
      echo "  • Mount points: Would be configured"
      echo "  • Filesystems: Would be formatted"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. LVM Volume Creation:"
      echo "     - Physical Volumes (PV) would be created on selected disks"
      echo "     - Volume Group (vg_aio) would be created"
      echo "     - Logical Volume (lv_aio) would be created for ES data"
      echo "     - AIO Root LV (${AIO_ROOT_LV}, 545GB) would be created in ${UBUNTU_VG}"
      echo
      echo "  2. Filesystem Creation:"
      echo "     - ext4 filesystem would be created on lv_aio"
      echo "     - ext4 filesystem would be created on ${AIO_ROOT_LV}"
      echo
      echo "  3. Mount Configuration:"
      echo "     - /stellar/aio directory would be created"
      echo "     - ${AIO_ROOT_LV} would be mounted to /stellar/aio"
      echo "     - /etc/fstab entry would be added"
      echo
      echo "  4. Ownership Configuration:"
      echo "     - /stellar ownership would be set to stellar:stellar"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 INSTALLATION STATUS:"
      echo
      echo "1️⃣  Mount Points:"
      local mount_info
      mount_info=$(df -h | egrep '/stellar/aio' 2>/dev/null || echo "  ⚠️  No /stellar/aio mount info found")
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
            echo "  ⚠️  /stellar ownership: ${stellar_owner} (expected: stellar:stellar)"
            echo "  💡 Ownership should have been set to stellar:stellar during STEP 07 execution"
            echo "  💡 If this persists, manually run: sudo chown -R stellar:stellar /stellar"
          fi
        else
          echo "  ⚠️  'stellar' user not found"
          echo "  💡 The 'stellar' user will be created during VM deployment (STEP 09)"
        fi
      else
        echo "  ℹ️  /stellar directory does not exist yet"
        echo "  💡 This should have been created during STEP 07 execution"
      fi
      echo
      echo "📦 STORAGE CONFIGURATION:"
      echo "  • Volume Group: vg_aio (ES data storage)"
      echo "  • Logical Volume: lv_aio (ES data)"
      echo "  • AIO Root LV: ${UBUNTU_VG}/${AIO_ROOT_LV} (545GB)"
      echo "  • Mount Point: /stellar/aio"
      echo "  • Filesystem: ext4"
      echo "  • Auto-mount: Configured in /etc/fstab"
    fi
    echo
    echo "💡 IMPORTANT NOTES:"
    echo "  • LVM volumes are created and mounted at /stellar/aio"
    echo "  • This mount point will be used for AIO VM storage"
    echo "  • Ensure all volumes are properly mounted before proceeding"
    echo
    echo "📝 NEXT STEPS:"
    echo "  • Proceed to STEP 08 (DP Download)"
  } > "${tmp_df}" 2>&1

  #######################################
  # 8) Show summary
  #######################################
  show_textbox "STEP 07 summary" "${tmp_df}"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 07] LVM storage configuration completed successfully. AIO and Sensor storage are ready."

  # STEP success → save_state called in run_step()
}

step_08_dp_download() {
  local STEP_ID="08_dp_download"
  local STEP_NAME="08. DP Download (AIO)"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 08] Download DP deploy script and image (virt_deploy_uvp_centos.sh + qcow2)"
  log "[STEP 08] This step will download AIO deployment script and qcow2 image from ACPS."
  load_config
  local tmp_info="/tmp/xdr_step08_info.txt"

  #######################################
  # 0) Check configuration values
  #######################################
  local ver="${DP_VERSION:-6.2.0}"  # Default to 6.2.0 if not set
  local acps_user="${ACPS_USERNAME:-}"
  local acps_pass="${ACPS_PASSWORD:-}"
  local acps_url="${ACPS_BASE_URL:-https://acps.stellarcyber.ai}"

  # Check required values (DP_VERSION now has default, so only check ACPS credentials)
  local missing=""
  [[ -z "${acps_user}" ]] && missing+="\n - ACPS_USERNAME"
  [[ -z "${acps_pass}" ]] && missing+="\n - ACPS_PASSWORD"

  if [[ -n "${missing}" ]]; then
    local msg="The following items are missing in config:${missing}\n\nSet them in Settings, then rerun."
    log "[STEP 08] Missing config values: ${missing}"
    whiptail_msgbox "STEP 08 - Missing config" "${msg}" 15 70
    log "[STEP 08] Skipping STEP 08 due to missing config."
    return 0
  fi

  # Normalize URL (trim trailing slash)
  acps_url="${acps_url%/}"

  #######################################
  # 1) Prepare download directory
  #######################################
  local aio_img_dir="/stellar/aio/images"
  log "[STEP 08] Download directory: ${aio_img_dir}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p ${aio_img_dir}"
  else
    sudo mkdir -p "${aio_img_dir}"
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

  log "[STEP 08] Configuration summary:"
  log "  - DP_VERSION   = ${ver}"
  log "  - ACPS_USERNAME= ${acps_user}"
  log "  - ACPS_BASE_URL= ${acps_url}"
  log "  - download path= ${aio_img_dir}"

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
    msg+="[Yes] Use this file (copy to AIO image dir; skip/replace download)\n"
    msg+="[No] Keep existing download process"

    # Calculate dialog size dynamically and center message
    if whiptail_yesno "STEP 08 - reuse local qcow2" "${msg}"; then
      use_local_qcow=1
      log "[STEP 08] User chose to use local qcow2 file (${local_qcow})."

      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${aio_img_dir}/${qcow2}\""
      else
        sudo mkdir -p "${aio_img_dir}"
        sudo cp "${local_qcow}" "${aio_img_dir}/${qcow2}"
        log "[STEP 08] Copied local qcow2 to ${aio_img_dir}/${qcow2}"
      fi
    else
      log "[STEP 08] User kept normal flow; not using local qcow2."
    fi
  else
    log "[STEP 08] No qcow2 >=1GB in current directory → use default download/existing files."
  fi

  #######################################
  # 3-B) Clean up old version files (if different version exists)
  #######################################
  log "[STEP 08] Checking for old version files to remove..."
  log "[STEP 08] Current version: ${ver}, Current qcow2: ${qcow2}, Current sha1: ${sha1}"
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will check and remove old version files from ${aio_img_dir}"
  else
    # Find all qcow2 files and remove those that don't match current version
    log "[STEP 08] Scanning for old version qcow2 files in ${aio_img_dir}..."
    local file
    while IFS= read -r -d '' file; do
      local basename_file
      basename_file=$(basename "${file}")
      if [[ "${basename_file}" != "${qcow2}" ]]; then
        log "[STEP 08] Removing old qcow2: ${file}"
        sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
      else
        log "[STEP 08] Keeping current version qcow2: ${basename_file}"
      fi
    done < <(find "${aio_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2" -print0 2>/dev/null || true)
    
    # Find all sha1 files and remove those that don't match current version
    log "[STEP 08] Scanning for old version sha1 files in ${aio_img_dir}..."
    while IFS= read -r -d '' file; do
      local basename_file
      basename_file=$(basename "${file}")
      if [[ "${basename_file}" != "${sha1}" ]]; then
        log "[STEP 08] Removing old sha1: ${file}"
        sudo rm -f "${file}" || log "[WARN] Failed to remove ${file}"
      else
        log "[STEP 08] Keeping current version sha1: ${basename_file}"
      fi
    done < <(find "${aio_img_dir}" -maxdepth 1 -type f -name "aella-dataprocessor-*.qcow2.sha1" -print0 2>/dev/null || true)
    
    # Remove old virt_deploy_uvp_centos.sh if it exists (will be replaced with new version)
    if [[ -f "${aio_img_dir}/${dp_script}" ]]; then
      log "[STEP 08] Removing existing ${dp_script} (will be replaced with new version)"
      sudo rm -f "${aio_img_dir}/${dp_script}" || log "[WARN] Failed to remove ${aio_img_dir}/${dp_script}"
    fi
    
    log "[STEP 08] Old version files cleanup completed"
  fi

  #######################################
  # 3-C) Check existing files (download only missing)
  # Note: Only check script and sha1. qcow2 is handled by local file check above.
  #######################################
  local need_script=0
  local need_qcow2=0
  local need_sha1=0

  # Script: always check if exists in download directory
  if [[ -f "${aio_img_dir}/${dp_script}" ]]; then
    log "[STEP 08] ${aio_img_dir}/${dp_script} already exists → skip download"
  else
    log "[STEP 08] ${aio_img_dir}/${dp_script} missing → will download"
    need_script=1
  fi

  # qcow2: only need download if local qcow2 was not used
  if [[ "${use_local_qcow}" -eq 1 ]]; then
    log "[STEP 08] Using local qcow2 file → skip qcow2 download"
    need_qcow2=0
  else
    # Don't check /stellar/aio/images - only check current directory (already done above)
    log "[STEP 08] ${qcow2} missing → will download"
    need_qcow2=1
  fi

  # sha1: always check if exists in download directory
  if [[ -f "${aio_img_dir}/${sha1}" ]]; then
    log "[STEP 08] ${aio_img_dir}/${sha1} already exists → skip download"
  else
    log "[STEP 08] ${aio_img_dir}/${sha1} missing → will download (used for sha1 verify if present)"
    need_sha1=1
  fi

  # If all files are present (script exists, qcow2 from local or exists, sha1 exists), skip download
  if [[ "${need_script}" -eq 0 && "${need_qcow2}" -eq 0 && "${need_sha1}" -eq 0 ]]; then
    log "[STEP 08] All required files already present; no download needed."
    if [[ "${use_local_qcow}" -eq 1 ]]; then
      log "[STEP 08] Using local qcow2 file and existing script/sha1 files."
    fi
  fi

  #######################################
  # 4) Download files (curl with auth)
  #######################################
  log "[STEP 08] Starting download from ACPS..."

  if [[ "${need_script}" -eq 1 ]]; then
    log "[STEP 08] Downloading ${dp_script}..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] curl -u '${acps_user}:***' -o '${aio_img_dir}/${dp_script}' '${url_script}'"
    else
      if curl -u "${acps_user}:${acps_pass}" -o "${aio_img_dir}/${dp_script}" "${url_script}"; then
        log "[STEP 08] ${dp_script} download completed"
        run_cmd "sudo chmod +x ${aio_img_dir}/${dp_script}"
      else
        log "[ERROR] ${dp_script} download failed"
        whiptail_msgbox "STEP 08 - Download Error" "Failed to download ${dp_script}.\n\nCheck network connection and ACPS credentials." 12 70
        return 1
      fi
    fi
  fi

  if [[ "${need_qcow2}" -eq 1 && "${use_local_qcow}" -eq 0 ]]; then
    log "[STEP 08] Downloading ${qcow2} (this may take a while)..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] curl -u '${acps_user}:***' -o '${aio_img_dir}/${qcow2}' '${url_qcow2}'"
    else
      if curl -u "${acps_user}:${acps_pass}" -o "${aio_img_dir}/${qcow2}" "${url_qcow2}"; then
        log "[STEP 08] ${qcow2} download completed"
      else
        log "[ERROR] ${qcow2} download failed"
        whiptail_msgbox "STEP 08 - Download Error" "Failed to download ${qcow2}.\n\nCheck network connection and ACPS credentials." 12 70
        return 1
      fi
    fi
  fi

  if [[ "${need_sha1}" -eq 1 ]]; then
    log "[STEP 08] Downloading ${sha1}..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] curl -u '${acps_user}:***' -o '${aio_img_dir}/${sha1}' '${url_sha1}'"
    else
      if curl -u "${acps_user}:${acps_pass}" -o "${aio_img_dir}/${sha1}" "${url_sha1}"; then
        log "[STEP 08] ${sha1} download completed"
      else
        log "[WARN] ${sha1} download failed (non-critical)"
      fi
    fi
  fi

  #######################################
  # 5) Verify SHA1 (if available)
  #######################################
  if [[ -f "${aio_img_dir}/${sha1}" && -f "${aio_img_dir}/${qcow2}" ]]; then
    log "[STEP 08] Verifying SHA1 checksum..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sha1sum -c ${aio_img_dir}/${sha1}"
    else
      (
        cd "${aio_img_dir}" || exit 2

        # Check if sha1 file has proper format (checksum + filename)
        local sha1_content
        sha1_content=$(cat "${sha1}" 2>/dev/null | tr -d '\r\n' | sed 's/[[:space:]]*$//')
        
        # If sha1 file contains only checksum (no filename), create proper format
        if [[ "${sha1_content}" =~ ^[0-9a-f]{40}$ ]]; then
          # Only checksum found, add filename
          log "[STEP 08] sha1 file contains only checksum, adding filename for proper format"
          echo "${sha1_content}  ${qcow2}" > "${sha1}.tmp"
          mv "${sha1}.tmp" "${sha1}"
        elif [[ "${sha1_content}" =~ ^[0-9a-f]{40}[[:space:]]+ ]]; then
          # Already has checksum + filename format, but may need filename update
          local existing_checksum
          existing_checksum=$(echo "${sha1_content}" | awk '{print $1}')
          if [[ -n "${existing_checksum}" ]]; then
            # Update filename if it doesn't match
            if ! echo "${sha1_content}" | grep -q "${qcow2}"; then
              log "[STEP 08] Updating sha1 file to include correct filename"
              echo "${existing_checksum}  ${qcow2}" > "${sha1}.tmp"
              mv "${sha1}.tmp" "${sha1}"
            fi
          fi
        fi

        # Now verify with sha1sum -c
        if ! sha1sum -c "${sha1}"; then
          log "[WARN] sha1sum verification failed."

          if whiptail_yesno "STEP 08 - SHA1 verification failed" "SHA1 checksum verification failed.\n\nThe downloaded file may be corrupted.\n\nProceed anyway?\n\n[Yes] continue\n[No] stop STEP 08" 14 80
          then
            log "[STEP 08] User chose to continue despite SHA1 failure."
            exit 0   # allowed → subshell succeeds
          else
            log "[STEP 08] User stopped STEP 08 due to SHA1 failure."
            exit 3   # user-abort code
          fi
        fi

        # sha1sum succeeded
        log "[STEP 08] SHA1 checksum verification passed"
        exit 0
      )

      local sha_rc=$?
      case "${sha_rc}" in
        0)
          # ok
          ;;
        2)
          log "[STEP 08] Failed to access directory during SHA1 check (cd ${aio_img_dir})"
          return 1
          ;;
        3)
          log "[STEP 08] User aborted STEP 08 due to SHA1 failure"
          return 1
          ;;
        *)
          log "[STEP 08] Unknown error during SHA1 verification (code=${sha_rc})"
          return 1
          ;;
      esac
    fi
  else
    if [[ -f "${aio_img_dir}/${sha1}" ]]; then
      log "[STEP 08] ${aio_img_dir}/${sha1} found but ${aio_img_dir}/${qcow2} missing; skipping SHA1 verification."
    elif [[ -f "${aio_img_dir}/${qcow2}" ]]; then
      log "[STEP 08] ${aio_img_dir}/${qcow2} found but ${aio_img_dir}/${sha1} missing; skipping SHA1 verification."
    fi
  fi

  #######################################
  # 6) Set ownership
  #######################################
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo chown -R stellar:stellar ${aio_img_dir}"
  else
    if id stellar >/dev/null 2>&1; then
      sudo chown -R stellar:stellar "${aio_img_dir}"
      log "[STEP 08] Set ownership to stellar:stellar"
    else
      log "[WARN] 'stellar' user not found; skipping chown."
    fi
  fi

  #######################################
  # 7) Summary
  #######################################
  {
    echo "STEP 08 - DP Download Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual downloads were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • Download directory: ${aio_img_dir}"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. Download deployment script: ${dp_script}"
      echo "  2. Download AIO image: ${qcow2}"
      echo "  3. Download SHA1 checksum: ${sha1} (optional)"
      echo "  4. Verify SHA1 checksum (if available)"
      echo "  5. Set ownership to stellar:stellar"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • Downloads require ACPS credentials (ACPS_USERNAME, ACPS_PASSWORD)"
      echo "  • Download may take significant time depending on file size"
      echo "  • Network connectivity to ACPS is required"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 DOWNLOAD STATUS:"
      echo "  • Download directory: ${aio_img_dir}"
      echo
      echo "📦 FILES DOWNLOADED:"
      if [[ -f "${aio_img_dir}/${dp_script}" ]]; then
        echo "  ✅ ${dp_script}: OK"
      else
        echo "  ❌ ${dp_script}: MISSING"
      fi
      if [[ -f "${aio_img_dir}/${qcow2}" ]]; then
        local qcow2_size
        qcow2_size=$(ls -lh "${aio_img_dir}/${qcow2}" 2>/dev/null | awk '{print $5}')
        echo "  ✅ ${qcow2}: OK (${qcow2_size})"
      else
        echo "  ❌ ${qcow2}: MISSING"
      fi
      if [[ -f "${aio_img_dir}/${sha1}" ]]; then
        echo "  ✅ ${sha1}: OK"
      else
        echo "  ⚠️  ${sha1}: MISSING (optional)"
      fi
      echo
      echo "👤 OWNERSHIP:"
      if id stellar >/dev/null 2>&1; then
        echo "  • ${aio_img_dir}: stellar:stellar"
      else
        echo "  • ⚠️  'stellar' user not found (ownership not set)"
      fi
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • Files are ready for STEP 09 (AIO VM Deployment)"
      echo "  • Ensure all files are present before proceeding"
    fi
  } > "${tmp_info}"

  show_textbox "STEP 08 - DP Download Summary" "${tmp_info}"

  log "[STEP 08] DP download completed"
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 08] AIO deployment script and image download completed successfully."
  
  return 0
}

step_09_aio_deploy() {
    local STEP_ID="09_aio_deploy"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 09. AIO VM deployment ====="

    # Load configuration
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DRY_RUN default value guard
    local _DRY_RUN="${DRY_RUN:-0}"

    # Default configuration values
    local AIO_HOSTNAME="${AIO_HOSTNAME:-aio}"
    local AIO_CLUSTERSIZE="1"  # Fixed to 1 for AIO

    # Note: AIO_VCPUS and AIO_MEMORY_GB will be calculated based on system resources below
    # Do not set hardcoded defaults here - they will be calculated from NUMA configuration
    local AIO_DISK_GB="${AIO_DISK_GB:-500}"           # in GB

    local AIO_INSTALL_DIR="${AIO_INSTALL_DIR:-/stellar/aio}"
    local AIO_BRIDGE="${AIO_BRIDGE:-virbr0}"

    local AIO_IP="${AIO_IP:-192.168.122.2}"
    local AIO_NETMASK="${AIO_NETMASK:-255.255.255.0}"
    local AIO_GW="${AIO_GW:-192.168.122.1}"
    local AIO_DNS="${AIO_DNS:-8.8.8.8}"

    # DP_VERSION is managed in config (default to 6.2.0 if not set)
    local _DP_VERSION="${DP_VERSION:-6.2.0}"

    # AIO image directory (same as STEP 08)
    local AIO_IMAGE_DIR="${AIO_INSTALL_DIR}/images"

    ############################################################
    # Clean up all VM directories in /stellar/aio/images/ before deployment
    ############################################################
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will clean up all VM directories in ${AIO_IMAGE_DIR}/"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Cleaning up all existing VM directories in ${AIO_IMAGE_DIR}/..."
        local vm_dir
        while IFS= read -r -d '' vm_dir; do
            if [[ -d "${vm_dir}" ]]; then
                local dir_name
                dir_name=$(basename "${vm_dir}")
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Removing VM directory: ${dir_name}/"
                sudo rm -rf "${vm_dir}" 2>/dev/null || log "[WARN] Failed to remove ${vm_dir}"
            fi
        done < <(find "${AIO_IMAGE_DIR}" -maxdepth 1 -type d ! -path "${AIO_IMAGE_DIR}" -print0 2>/dev/null || true)
        log "[STEP 09] VM directories cleanup completed"
    fi

    # Locate virt_deploy_uvp_centos.sh
    local DP_SCRIPT_PATH_CANDIDATES=()
    [ -n "${DP_SCRIPT_PATH:-}" ] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")

    # STEP 08 standard location
    DP_SCRIPT_PATH_CANDIDATES+=("${AIO_IMAGE_DIR}/virt_deploy_uvp_centos.sh")
    DP_SCRIPT_PATH_CANDIDATES+=("${AIO_INSTALL_DIR}/virt_deploy_uvp_centos.sh")
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
            whiptail_msgbox "STEP 09 - AIO deploy" "Could not find virt_deploy_uvp_centos.sh.\nComplete STEP 08 (download script/image) first.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] virt_deploy_uvp_centos.sh not found. Skipping."
            return 0
        fi
    fi

    # Check AIO image presence → if missing set nodownload=false
    local QCOW2_PATH="${AIO_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local AIO_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        AIO_NODOWNLOAD="false"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] AIO qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=false."
    fi

    # Ensure AIO LV is mounted on /stellar/aio
    if ! mount | grep -q "on ${AIO_INSTALL_DIR} "; then
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] ${AIO_INSTALL_DIR} is not mounted, but continuing in DRY_RUN mode"
        else
            whiptail_msgbox "STEP 09 - AIO deploy" "${AIO_INSTALL_DIR} is not mounted.\nComplete STEP 07 (LVM) and fstab setup, then rerun.\nSkipping this step." 14 80
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] ${AIO_INSTALL_DIR} not mounted. Skipping."
            return 0
        fi
    fi

    # AIO OTP: use from config or prompt/save once
    local _AIO_OTP="${AIO_OTP:-}"
    if [ -z "${_AIO_OTP}" ]; then
        # Always prompt for OTP (both dry run and actual mode)
        local otp_prompt_msg="Enter OTP for AIO (issued from Stellar Cyber)."
        if [[ "${_DRY_RUN}" -eq 1 ]]; then
            otp_prompt_msg="Enter OTP for AIO (issued from Stellar Cyber).\n\n(DRY-RUN mode: You can skip this, but OTP will be required for actual deployment.)"
        fi
        _AIO_OTP="$(whiptail_passwordbox "STEP 09 - AIO deploy" "${otp_prompt_msg}" "")"
        if [ $? -ne 0 ] || [ -z "${_AIO_OTP}" ]; then
            if [[ "${_DRY_RUN}" -eq 1 ]]; then
                log "[DRY-RUN] AIO_OTP not provided, but continuing in DRY_RUN mode with placeholder"
                _AIO_OTP="dry-run-otp"  # Use placeholder for dry run
            else
                whiptail_msgbox "STEP 09 - AIO deploy" "No OTP provided. Skipping AIO deploy." 10 70
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] AIO_OTP not provided. Skipping."
                return 0
            fi
        else
            # User provided OTP - save it
            AIO_OTP="${_AIO_OTP}"
            if [[ "${_DRY_RUN}" -eq 1 ]]; then
                log "[DRY-RUN] AIO_OTP provided by user (will be used in dry run command)"
            fi
            if type save_config >/dev/null 2>&1; then
                save_config
            fi
        fi
    fi

    # If aio already exists, warn and allow destroy/cleanup
    if virsh dominfo "${AIO_HOSTNAME}" >/dev/null 2>&1; then
        if ! confirm_destroy_vm "${AIO_HOSTNAME}" "STEP 09 - AIO deploy"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Existing VM detected, user kept it. Skipping."
            return 0
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Destroying and undefining existing ${AIO_HOSTNAME}..."

        local AIO_VM_DIR="${AIO_IMAGE_DIR}/${AIO_HOSTNAME}"

        if [ "${_DRY_RUN}" -eq 1 ]; then
            echo "[DRY_RUN] virsh destroy ${AIO_HOSTNAME} || true"
            echo "[DRY_RUN] virsh undefine ${AIO_HOSTNAME} --nvram || virsh undefine ${AIO_HOSTNAME} || true"
            echo "[DRY_RUN] rm -f '${AIO_VM_DIR}/${AIO_HOSTNAME}.raw' || true"
            echo "[DRY_RUN] rm -f '${AIO_VM_DIR}/${AIO_HOSTNAME}.log' || true"
        else
            virsh destroy "${AIO_HOSTNAME}" >/dev/null 2>&1 || true
            virsh undefine "${AIO_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${AIO_HOSTNAME}" >/dev/null 2>&1 || true

            if [ -d "${AIO_VM_DIR}" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Removing old AIO image files in ${AIO_VM_DIR}."
                sudo rm -rf "${AIO_VM_DIR}"/* 2>/dev/null || true
                sudo rmdir "${AIO_VM_DIR}" 2>/dev/null || true
                log "[STEP 09] Old AIO image directory ${AIO_VM_DIR} cleaned up"
            fi
        fi
    fi

    ############################################################
    # Prompt for AIO VM configuration (memory, vCPU, disk)
    ############################################################
    # Calculate default values based on system resources
    # Memory allocation: 12% of total memory reserved for KVM host, remaining 70% for AIO, 30% for MDS
    local total_cpus total_mem_kb total_mem_gb host_reserve_gb available_mem_gb
    total_cpus=$(nproc)
    total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    total_mem_gb=$((total_mem_kb / 1024 / 1024))
    # Reserve 12% of total memory for KVM host
    host_reserve_gb=$((total_mem_gb * 12 / 100))
    available_mem_gb=$((total_mem_gb - host_reserve_gb))
    [[ ${available_mem_gb} -le 0 ]] && available_mem_gb=16
    
    # Check NUMA configuration for AIO vCPU default calculation
    # AIO default: All NUMA0 vCPUs
    local numa_nodes=1
    local node0_cpus="" node0_count=0
    if command -v lscpu >/dev/null 2>&1; then
      numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
      if [[ "${numa_nodes}" -ge 2 ]]; then
        # Extract NUMA node0 CPU list
        node0_cpus=$(lscpu | grep "NUMA node0 CPU(s):" | sed 's/NUMA node0 CPU(s)://' | tr -d '[:space:]')
        # Count CPUs in NUMA node0
        if [[ -n "${node0_cpus}" ]]; then
          node0_count=$(echo "${node0_cpus}" | tr ',' '\n' | wc -l)
        fi
      fi
    fi
    
    # Default memory: 70% of available memory (after 12% host reserve) for AIO
    local default_aio_mem_gb=$((available_mem_gb * 70 / 100))
    [[ ${default_aio_mem_gb} -lt 8 ]] && default_aio_mem_gb=8
    
    # Default vCPU: All NUMA0 CPUs (if NUMA0 detected)
    # This ensures AIO gets all CPUs from NUMA0
    local default_aio_vcpus
    if [[ "${numa_nodes}" -ge 2 && ${node0_count} -gt 0 ]]; then
      # Allocate all NUMA0 CPUs to AIO
      default_aio_vcpus=${node0_count}
    else
      # NUMA detection failed: Use half of total CPUs as fallback
      default_aio_vcpus=$((total_cpus / 2))
      [[ ${default_aio_vcpus} -lt 2 ]] && default_aio_vcpus=2
    fi
    
    local default_aio_disk_gb=500
    
    # Use existing values if set, otherwise use calculated defaults
    : "${AIO_MEMORY_GB:=${default_aio_mem_gb}}"
    : "${AIO_VCPUS:=${default_aio_vcpus}}"
    : "${AIO_DISK_GB:=${default_aio_disk_gb}}"
    
    # 1) Memory
    # Always use calculated default value for input box (not saved value)
    local _AIO_MEM_INPUT
    _AIO_MEM_INPUT="$(whiptail_inputbox "STEP 09 - AIO memory" "Enter memory (GB) for AIO VM.\n\nTotal memory: ${total_mem_gb}GB\nHost reserve (12%): ${host_reserve_gb}GB\nAvailable: ${available_mem_gb}GB\nDefault value: ${default_aio_mem_gb}GB (70% of available)\nExample: Enter 136" "${default_aio_mem_gb}" 14 80)"

    if [ $? -eq 0 ] && [ -n "${_AIO_MEM_INPUT}" ]; then
        if [[ "${_AIO_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_AIO_MEM_INPUT}" -gt 0 ]; then
            AIO_MEMORY_GB="${_AIO_MEM_INPUT}"
        else
            whiptail_msgbox "STEP 09 - AIO memory" "Invalid memory value.\nUsing current default (${default_aio_mem_gb} GB)." 10 70
            AIO_MEMORY_GB="${default_aio_mem_gb}"
        fi
    else
        # User canceled or empty input - use default
        AIO_MEMORY_GB="${default_aio_mem_gb}"
    fi

    # 2) vCPU
    local aio_vcpu_msg
    if [[ "${numa_nodes}" -ge 2 && ${node0_count} -gt 0 ]]; then
      aio_vcpu_msg="Enter number of vCPUs for AIO VM.\n\nTotal logical CPUs: ${total_cpus}\nNUMA0 CPUs: ${node0_count}\nDefault value: ${default_aio_vcpus} (all NUMA0 CPUs)\nExample: Enter 46"
    else
      aio_vcpu_msg="Enter number of vCPUs for AIO VM.\n\nTotal logical CPUs: ${total_cpus}\nDefault value: ${default_aio_vcpus} (half of total CPUs)\nExample: Enter 46"
    fi
    local _AIO_VCPU_INPUT
    _AIO_VCPU_INPUT="$(whiptail_inputbox "STEP 09 - AIO vCPU" "${aio_vcpu_msg}" "${AIO_VCPUS}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_AIO_VCPU_INPUT}" ]; then
        if [[ "${_AIO_VCPU_INPUT}" =~ ^[0-9]+$ ]] && [ "${_AIO_VCPU_INPUT}" -gt 0 ]; then
            AIO_VCPUS="${_AIO_VCPU_INPUT}"
        else
            whiptail_msgbox "STEP 09 - AIO vCPU" "Invalid vCPU value.\nUsing current default (${AIO_VCPUS})." 10 70
        fi
    else
        # User canceled or empty input - use default
        AIO_VCPUS="${default_aio_vcpus}"
    fi

    # 3) Disk size
    local _AIO_DISK_INPUT
    _AIO_DISK_INPUT="$(whiptail_inputbox "STEP 09 - AIO disk" "Enter disk size (GB) for AIO VM.\n\nMinimum size: 100GB\nDefault value: ${default_aio_disk_gb}GB\nExample: Enter 500" "${AIO_DISK_GB}" 12 70)"

    if [ $? -eq 0 ] && [ -n "${_AIO_DISK_INPUT}" ]; then
        if [[ "${_AIO_DISK_INPUT}" =~ ^[0-9]+$ ]] && [ "${_AIO_DISK_INPUT}" -gt 0 ]; then
            if [[ "${_AIO_DISK_INPUT}" -lt 100 ]]; then
                whiptail_msgbox "STEP 09 - AIO disk" "Minimum disk size is 100GB.\nUsing current default (${AIO_DISK_GB} GB)." 10 70
            else
                AIO_DISK_GB="${_AIO_DISK_INPUT}"
            fi
        else
            whiptail_msgbox "STEP 09 - AIO disk" "Invalid disk size value.\nUsing current default (${AIO_DISK_GB} GB)." 10 70
        fi
    else
        # User canceled or empty input - use default
        AIO_DISK_GB="${default_aio_disk_gb}"
    fi

    if type save_config >/dev/null 2>&1; then
        save_config
    fi

    # Convert memory to MB
    local AIO_MEMORY_MB=$(( AIO_MEMORY_GB * 1024 ))

    # Build command to run virt_deploy_uvp_centos.sh
    # Note: --local-ip is set to same as --ip (VM IP) for AIO deployment
    local CMD
    CMD="sudo bash '${DP_SCRIPT_PATH}' -- \
--hostname=${AIO_HOSTNAME} \
--cluster-size=${AIO_CLUSTERSIZE} \
--release=${_DP_VERSION} \
--local-ip=${AIO_IP} \
--node-role=AIO \
--bridge=${AIO_BRIDGE} \
--CPUS=${AIO_VCPUS} \
--MEM=${AIO_MEMORY_MB} \
--DISKSIZE=${AIO_DISK_GB} \
--nodownload=${AIO_NODOWNLOAD} \
--installdir=${AIO_INSTALL_DIR} \
--OTP=${_AIO_OTP} \
--ip=${AIO_IP} \
--netmask=${AIO_NETMASK} \
--gw=${AIO_GW} \
--dns=${AIO_DNS}"

    # Final confirmation
    local SUMMARY
    SUMMARY="Deploy AIO VM with:

  Hostname      : ${AIO_HOSTNAME}
  Cluster size  : ${AIO_CLUSTERSIZE}
  DP version    : ${_DP_VERSION}
  Bridge        : ${AIO_BRIDGE}
  vCPU          : ${AIO_VCPUS}
  Memory        : ${AIO_MEMORY_GB} GB (${AIO_MEMORY_MB} MB)
  Disk size     : ${AIO_DISK_GB} GB
  installdir    : ${AIO_INSTALL_DIR}
  VM IP         : ${AIO_IP}
  Netmask       : ${AIO_NETMASK}
  Gateway       : ${AIO_GW}
  DNS           : ${AIO_DNS}
  nodownload    : ${AIO_NODOWNLOAD}
  Script path   : ${DP_SCRIPT_PATH}

Run virt_deploy_uvp_centos.sh with these settings?"

    if ! whiptail_yesno "STEP 09 - AIO deploy" "${SUMMARY}"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] User canceled AIO deploy."
        return 0
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] Running AIO deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Command not executed (DRY_RUN=1)."
        whiptail_msgbox "STEP 09 - AIO deploy (DRY RUN)" "DRY_RUN mode.\n\nCommand printed but not executed:\n\n${CMD}" 20 80
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Would execute: ${CMD}"
        log "[DRY-RUN] AIO VM deployment skipped in DRY_RUN mode"
    else
        eval "${CMD}"
        local deploy_rc=$?

        if [ "${deploy_rc}" -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] AIO VM deployment completed successfully."
            
            # Apply CPU affinity to NUMA0
            if [[ -n "${NUMA_NODES:-}" && "${NUMA_NODES}" -gt 1 ]]; then
                log "[STEP 09] Applying CPU affinity to NUMA0 for AIO VM"
                local numa0_cpus
                numa0_cpus=$(lscpu | grep "NUMA node0 CPU(s):" | sed 's/NUMA node0 CPU(s)://' | tr -d '[:space:]')
                if [[ -n "${numa0_cpus}" ]]; then
                    virsh emulatorpin "${AIO_HOSTNAME}" "${numa0_cpus}" --config >/dev/null 2>&1 || true
                    local max_vcpus
                    max_vcpus="$(virsh vcpucount "${AIO_HOSTNAME}" --maximum --config 2>/dev/null || echo 0)"
                    for (( i=0; i<max_vcpus; i++ )); do
                        virsh vcpupin "${AIO_HOSTNAME}" "${i}" "${numa0_cpus}" --config >/dev/null 2>&1 || true
                    done
                    log "[STEP 09] CPU affinity applied to NUMA0 (cpuset=${numa0_cpus})"
                fi
            fi
            
            # Create summary message
            local tmp_summary="/tmp/step09_summary.txt"
            {
                echo "STEP 09 - AIO VM Deployment Summary"
                echo "═══════════════════════════════════════════════════════════"
                echo "✅ EXECUTION COMPLETED"
                echo
                echo "📊 DEPLOYMENT STATUS:"
                local vm_state="unknown"
                if virsh dominfo "${AIO_HOSTNAME}" >/dev/null 2>&1; then
                    vm_state=$(virsh domstate "${AIO_HOSTNAME}" 2>/dev/null || echo "unknown")
                    echo "  • VM name: ${AIO_HOSTNAME}"
                    echo "  • VM status: ${vm_state}"
                    echo "    ✅ AIO VM created successfully"
                else
                    echo "  • VM name: ${AIO_HOSTNAME}"
                    echo "  • VM status: Not found"
                    echo "    ⚠️  VM creation may have failed"
                fi
                echo
                echo "🖥️  VM CONFIGURATION:"
                echo "  • Hostname: ${AIO_HOSTNAME}"
                echo "  • Node role: AIO"
                echo "  • Cluster size: ${AIO_CLUSTERSIZE}"
                echo "  • vCPU: ${AIO_VCPUS}"
                echo "  • Memory: ${AIO_MEMORY_GB}GB (${AIO_MEMORY_MB}MB)"
                echo "  • Disk: ${AIO_DISK_GB}GB"
                echo
                echo "🌐 NETWORK CONFIGURATION:"
                echo "  • Network mode: NAT"
                echo "  • Bridge: ${AIO_BRIDGE}"
                echo "  • IP address: ${AIO_IP}"
                echo "  • Netmask: ${AIO_NETMASK}"
                echo "  • Gateway: ${AIO_GW}"
                echo "  • DNS: ${AIO_DNS}"
                echo
                echo "📦 STORAGE CONFIGURATION:"
                echo "  • Install directory: ${AIO_INSTALL_DIR}"
                echo "  • Image directory: ${AIO_IMAGE_DIR}"
                echo
                if [[ -n "${NUMA_NODES:-}" && "${NUMA_NODES}" -gt 1 ]]; then
                    echo "⚙️  CPU AFFINITY:"
                    echo "  • NUMA node: NUMA0"
                    if [[ -n "${numa0_cpus:-}" ]]; then
                        echo "  • CPU set: ${numa0_cpus}"
                        echo "    ✅ CPU affinity configured successfully"
                    fi
                    echo
                fi
                echo "⚠️  IMPORTANT:"
                echo "  • Initial boot may take time due to Cloud-Init operations"
                echo "  • Check VM status with: virsh list --all"
                echo "  • Access VM console with: virsh console ${AIO_HOSTNAME}"
                echo "  • Proceed to STEP 10 for Sensor VM deployment"
            } > "${tmp_summary}"
            
            show_textbox "STEP 09 - AIO VM Deployment Summary" "${tmp_summary}"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 09] AIO VM deployment failed (rc=${deploy_rc})."
            whiptail_msgbox "STEP 09 - AIO deploy" "AIO VM deployment failed.\n\nCheck logs for details." 12 70
            return 1
        fi
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - 09. AIO VM deployment ====="
    log "[STEP 09] AIO VM deployment completed successfully."
    return 0
}

step_10_sensor_lv_download() {
  local STEP_ID="10_sensor_lv_download"
  local STEP_NAME="10. Sensor LV Creation + Image/Script Download"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 10] Sensor LV Creation + Image/Script Download"
  log "[STEP 10] This step will create sensor logical volume and download sensor image/script."
  load_config

  # LV location configuration
  : "${LV_LOCATION:=ubuntu-vg}"
  SENSOR_VM_COUNT=1  # Fixed to 1 for single mds deployment
  save_config_var "SENSOR_VM_COUNT" "${SENSOR_VM_COUNT}"

  #######################################
  # Prompt for Sensor LV size configuration
  #######################################
  # Check total size of ubuntu-vg (OpenXDR method)
  local ubuntu_vg_total_size
  ubuntu_vg_total_size=$(vgs ubuntu-vg --noheadings --units g --nosuffix -o size 2>/dev/null | tr -d ' ' || echo "0")

  # Check ubuntu-lv usage size
  local ubuntu_lv_size ubuntu_lv_gb=0
  if command -v lvs >/dev/null 2>&1; then
    ubuntu_lv_size=$(lvs ubuntu-vg/ubuntu-lv --noheadings --units g --nosuffix -o lv_size 2>/dev/null | tr -d ' ' || echo "0")
    ubuntu_lv_gb=${ubuntu_lv_size%.*}
  fi

  # ubuntu-vg convert total size to integer
  local ubuntu_vg_total_gb=${ubuntu_vg_total_size%.*}
  
  # Available space calculate
  local available_gb=$((ubuntu_vg_total_gb - ubuntu_lv_gb))
  [[ ${available_gb} -lt 0 ]] && available_gb=0
  
  # Default LV size
  local default_sensor_disk_gb=200
  
  # Prompt for LV size
  local lv_size_gb
  while true; do
    lv_size_gb=$(whiptail_inputbox "STEP 10 - Sensor (MDS) Storage Size Configuration" \
                         "Please enter the storage size (GB) for the sensor VM (mds).\n\n- LV location: ubuntu-vg (OpenXDR method)\n- Available space: ${available_gb}GB\n- Minimum size: 80GB\n- Default value: ${default_sensor_disk_gb}GB\n\nExample: Enter 200\n\nSize (GB):" \
                         "${SENSOR_LV_SIZE_GB_PER_VM:-${default_sensor_disk_gb}}" \
                         18 80) || {
      log "User canceled sensor storage size configuration."
      return 1
    }

    lv_size_gb=$(echo "${lv_size_gb}" | tr -d ' ')

    # Number validation
    if ! [[ "${lv_size_gb}" =~ ^[0-9]+$ ]]; then
      whiptail_msgbox "Input Error" "Please enter a valid number.\nInput value: ${lv_size_gb}"
      continue
    fi

    # Minimum size validation (80GB)
    if [[ "${lv_size_gb}" -lt 80 ]]; then
      whiptail_msgbox "Insufficient Size" "Minimum 80GB must be greater than or equal to.\nInput value: ${lv_size_gb}GB"
      continue
    fi

    break
  done

  SENSOR_LV_SIZE_GB_PER_VM="${lv_size_gb}"
  SENSOR_TOTAL_LV_SIZE_GB="${lv_size_gb}"
  LV_SIZE_GB="${lv_size_gb}"

  log "[STEP 10] Configured LV location: ${LV_LOCATION}"
  log "[STEP 10] Configured LV size: ${SENSOR_LV_SIZE_GB_PER_VM}GB"

  save_config_var "SENSOR_TOTAL_LV_SIZE_GB" "${SENSOR_TOTAL_LV_SIZE_GB}"
  save_config_var "SENSOR_LV_SIZE_GB_PER_VM" "${SENSOR_LV_SIZE_GB_PER_VM}"
  save_config_var "LV_SIZE_GB" "${LV_SIZE_GB}"

  local tmp_status="/tmp/xdr_step09_status.txt"

  #######################################
  # 0) Current status check
  #######################################
  local lv_exists_mds="no"
  local mounted_mds="no"

  local UBUNTU_VG="ubuntu-vg"
  local LV_MDS="lv_sensor_root_mds"

  local lv_path_mds="${UBUNTU_VG}/${LV_MDS}"

  if lvs "${lv_path_mds}" >/dev/null 2>&1; then lv_exists_mds="yes"; fi

  if mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then mounted_mds="yes"; fi

  {
    echo "Current Sensor LV status"
    echo "-------------------"
    echo "LV path(mds) : ${lv_path_mds}"
    echo "LV exists (mds) : ${lv_exists_mds}"
    echo "Mounted (mds)  : ${mounted_mds} (/var/lib/libvirt/images/mds)"
    echo
    echo "User configuration:"
    echo "  - LV location: ${LV_LOCATION}"
    echo "  - Disk size: ${SENSOR_LV_SIZE_GB_PER_VM}GB"
    echo
    echo "This STEP performs the following tasks:"
    echo "  1) LV create (${SENSOR_LV_SIZE_GB_PER_VM}GB)"
    echo "     - ${lv_path_mds}"
    echo "  2) Create ext4 filesystem and mount"
    echo "     - /var/lib/libvirt/images/mds"
    echo "  3) Register auto mount in /etc/fstab"

    echo "  4) Download sensor image and deployment script"
    echo "     - virt_deploy_modular_ds.sh"
    echo "     - aella-modular-ds-${SENSOR_VERSION:-6.2.0}.qcow2"
    echo "  5) Configure stellar:stellar ownership"
  } > "${tmp_status}"

  show_textbox "STEP 07 - Sensor LV and download Overview" "${tmp_status}"

  # Continue with image download even if LV is already configured
  local skip_lv_creation="no"
  if [[ "${lv_exists_mds}" == "yes" && "${mounted_mds}" == "yes" ]]; then
    if whiptail_yesno "STEP 07 - LV Already configured" "LV and mount are already configured.\n\n- ${lv_path_mds}\n\nSkip LV create/mount and proceed with qcow2 image download only?" 14 90
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
  # 1) LV create (mds single) - OpenXDR method (ubuntu-vg)
  #######################################
  if [[ "${skip_lv_creation}" == "no" ]]; then
    log "[STEP 07] Start creating/mounting LV for mds (${SENSOR_LV_SIZE_GB_PER_VM}GB)"

    # mds LV
    if lvs "${lv_path_mds}" >/dev/null 2>&1; then
      log "[STEP 07] LV ${lv_path_mds} already exists → skip creation"
    else
      run_cmd "sudo lvcreate -L ${SENSOR_LV_SIZE_GB_PER_VM}G -n ${LV_MDS} ${UBUNTU_VG}"
      run_cmd "sudo mkfs.ext4 -F /dev/${lv_path_mds}"
    fi

    # Safety check: Ensure mountpoint is not already mounted by different device
    local mount_mds="/var/lib/libvirt/images/mds"
    
    if mountpoint -q "${mount_mds}" 2>/dev/null; then
      local mounted_dev
      mounted_dev=$(findmnt -n -o SOURCE "${mount_mds}" 2>/dev/null || echo "")
      if [[ -n "${mounted_dev}" && "${mounted_dev}" != "/dev/${lv_path_mds}" ]]; then
        log "[ERROR] ${mount_mds} is already mounted by ${mounted_dev}, expected /dev/${lv_path_mds}"
        whiptail_msgbox "STEP 07 - Mount Conflict" "Mount point ${mount_mds} is already mounted by a different device (${mounted_dev}).\n\nPlease unmount it first or use a different mount point." 12 80
        return 1
      fi
    fi

    # mount
    run_cmd "sudo mkdir -p ${mount_mds}"
    if ! mountpoint -q "${mount_mds}" 2>/dev/null; then
      run_cmd "sudo mount /dev/${lv_path_mds} ${mount_mds}"
    fi

    # fstab
    append_fstab_if_missing "/dev/${lv_path_mds}  ${mount_mds}  ext4 defaults,noatime 0 2"  "${mount_mds}"

    run_cmd "sudo systemctl daemon-reload"
    run_cmd "sudo mount -a"

    # Ownership: Only change ownership of mount point, not entire /var/lib/libvirt/images
    log "[STEP 10] Change mount point ownership to stellar:stellar"
    if id stellar >/dev/null 2>&1; then
      run_cmd "sudo chown -R stellar:stellar ${mount_mds}"
    else
      log "[WARN] 'stellar' user account not found, skipping chown."
    fi
  else
    log "[STEP 10] LV create/mount already configured, skipping"
  fi


  # Store for use in STEP08/09
  save_config_var "SENSOR_LV_MDS"  "${lv_path_mds}"


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
        log "[STEP 10] Local qcow2 copied (replaced) to ${SENSOR_IMAGE_DIR}/${qcow2_name} completed"
      fi
    else
      log "[STEP 10] User chose not to use local qcow2 and maintain existing file/download procedure."
    fi
  else
    log "[STEP 10] No 1GB+ qcow2 file in current directory → use default download/existing file."
  fi
  
  #######################################
  # 6-B) Determine download files (always download except 1GB+ qcow2 in current directory)
  #######################################
  local need_script=1  # Always download script
  local need_qcow2=0
  local script_name="virt_deploy_modular_ds.sh"
  
  log "[STEP 10] ${script_name} is always download target"
  
  # Always download unless local qcow2 was copied
  if [[ "${use_local_qcow}" -eq 0 ]]; then
    log "[STEP 10] ${qcow2_name} download target"
    need_qcow2=1
  else
    log "[STEP 10] Using local qcow2 file, skipping download"
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
      log "[STEP 10] Download script only because local qcow2 is used."
    fi
    
    (
      cd "${SENSOR_IMAGE_DIR}" || exit 1
      
      # 1) Download deployment script (always)
      log "[STEP 10] ${script_name} download started: ${script_url}"
      echo "=== Downloading deployment script ==="
      if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${script_url}" 2>&1 | tee -a "${LOG_FILE}"; then
        chmod +x "${script_name}"
        echo "=== Deployment script download completed ==="
        log "[STEP 10] ${script_name} download completed"
      else
        log "[ERROR] ${script_name} download failed"
        exit 1
      fi
      
      # 2) qcow2 image download (large capacity, only if local qcow2 is not used)
      if [[ "${need_qcow2}" -eq 1 ]]; then
        log "[STEP 10] ${qcow2_name} download started: ${image_url}"
        echo "=== ${qcow2_name} downloading (large capacity file, may take a long time) ==="
        echo "File size may be very large, please wait..."
        if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${image_url}" 2>&1 | tee -a "${LOG_FILE}"; then
          echo "=== ${qcow2_name} download Completed ==="
          log "[STEP 10] ${qcow2_name} download Completed"
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
  log "[STEP 10] Configure mount point ownership (stellar:stellar)"
  if id stellar >/dev/null 2>&1; then
    run_cmd "sudo chown -R stellar:stellar /var/lib/libvirt/images/mds"
  else
    log "[WARN] 'stellar' user account not found, skipping chown."
  fi

  #######################################
  # 9) Verify result
  #######################################
  local final_lv_mds="unknown"
  local final_mount_mds="unknown"
  local final_image="unknown"

  # (Safety) Reconstruct LV path here as well (set -u response)
  local UBUNTU_VG="ubuntu-vg"
  local LV_MDS="lv_sensor_root_mds"
  local lv_path_mds="${UBUNTU_VG}/${LV_MDS}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    final_lv_mds="(DRY-RUN mode)"
    final_mount_mds="(DRY-RUN mode)"
    final_image="(DRY-RUN mode)"
  else
    # Re-check LV
    if lvs "${lv_path_mds}" >/dev/null 2>&1; then
      final_lv_mds="OK"
    else
      final_lv_mds="FAIL"
    fi

    # Re-check mount
    if mountpoint -q /var/lib/libvirt/images/mds; then
      final_mount_mds="OK"
    else
      final_mount_mds="FAIL"
    fi

    # Re-check image file
    if [[ -f "${SENSOR_IMAGE_DIR}/${qcow2_name}" ]]; then
      final_image="OK"
    else
      final_image="FAIL"
    fi
  fi

  {
    echo "STEP 10 - Sensor LV Creation + Image Download Summary"
    echo "═══════════════════════════════════════════════════════════"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual changes were made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • lv_sensor_root LV (mds): ${final_lv_mds}"
      echo "  • /var/lib/libvirt/images/mds mount: ${final_mount_mds}"
      echo "  • Sensor image status: ${final_image}"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. LVM Volume Creation:"
      echo "     - lv_sensor_root (${SENSOR_LV_SIZE_GB_PER_VM:-${SENSOR_LV_SIZE_GB:-200}}GB) would be created"
      echo "     - ext4 filesystem would be created"
      echo
      echo "  2. Mount Configuration:"
      echo "     - /var/lib/libvirt/images/mds directory would be created"
      echo "     - LV would be mounted to /var/lib/libvirt/images/mds"
      echo "     - /etc/fstab entry would be added"
      echo
      echo "  3. Image Download:"
      echo "     - Download location: ${SENSOR_IMAGE_DIR}"
      echo "     - Image file: ${qcow2_name}"
      echo "     - Deployment script: virt_deploy_modular_ds.sh"
      echo "     - Files would be downloaded from ACPS"
      echo
      echo "  4. Ownership Configuration:"
      echo "     - /var/lib/libvirt/images/mds ownership would be set to stellar:stellar"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • LV creation requires sufficient space in ubuntu-vg"
      echo "  • Image download requires ACPS credentials"
      echo "  • Download may take significant time depending on file size"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 INSTALLATION STATUS:"
      echo "  • lv_sensor_root LV (mds): ${final_lv_mds}"
      echo "  • /var/lib/libvirt/images/mds mount: ${final_mount_mds}"
      echo "  • Sensor image status: ${final_image}"
      echo
      echo "📦 STORAGE CONFIGURATION:"
      echo "  • LV Path: ${lv_path_mds}"
      echo "  • LV Size: ${SENSOR_LV_SIZE_GB_PER_VM:-${SENSOR_LV_SIZE_GB:-200}}GB"
      echo "  • Mount Point: /var/lib/libvirt/images/mds"
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
      echo "  • /var/lib/libvirt/images/mds: stellar:stellar"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • LV and mount are configured and ready for VM deployment"
      echo "  • Image files are ready for STEP 11 (Sensor VM Deployment)"
    fi
  } > "${tmp_status}"

  show_textbox "STEP 10 Result Summary" "${tmp_status}"

  log "[STEP 10] Sensor LV creation and image download completed"
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 10] Sensor LV creation and image download completed successfully."

  return 0
}


step_11_sensor_deploy() {
  local STEP_ID="11_sensor_deploy"
  local STEP_NAME="11. Sensor VM Deployment"
  
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 11] Sensor VM Deployment"
  log "[STEP 11] This step will deploy the Sensor VM (mds) using NAT network mode."
  load_config

  # Determine network mode (force NAT)
  local net_mode="nat"
  SENSOR_NET_MODE="nat"
  log "[STEP 11] Sensor network mode: ${net_mode} (NAT only)"

  #######################################
  # 0) Clean up existing VMs
  #######################################
  local SENSOR_VMS=("mds")
  local vm_exists="no"
  if virsh list --all | grep -Eq "\smds\s" 2>/dev/null; then
    vm_exists="yes"
  fi

  if [[ "${vm_exists}" == "yes" ]]; then
    if ! whiptail_yesno "STEP 11 - Existing VM Found" "mds VM already exists.\n\nDo you want to delete existing VM and redeploy?" 12 80
    then
      log "User canceled existing VM redeployment."
      return 0
    else
      for vm in "${SENSOR_VMS[@]}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
          log "[STEP 11] Delete existing ${vm} VM"
          if virsh list --state-running | grep -q "\s${vm}\s" 2>/dev/null; then
            run_cmd "virsh destroy ${vm}"
          fi
          run_cmd "virsh undefine ${vm} --remove-all-storage"
        fi
      done
    fi
  fi

  if ! whiptail_yesno "STEP 11 Execution Confirmation" "Do you want to proceed with Sensor VM deployment for mds?"; then
    log "User canceled STEP 11 execution."
    return 0
  fi

  #######################################
  # 1) Deploy script check
  #######################################
  local script_path="/var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh"
  if [[ ! -f "${script_path}" && "${DRY_RUN}" -eq 0 ]]; then
    whiptail_msgbox "STEP 11 - Script Not Found" "Deployment script not found:\n${script_path}"
    return 1
  fi

  #######################################
  # 2) Prompt for Sensor VM configuration (memory, vCPU, disk)
  #######################################
  # Calculate default values based on system resources
  # Memory allocation: 12% of total memory reserved for KVM host, remaining 30% for Sensor
  local total_cpus total_mem_kb total_mem_gb host_reserve_gb available_mem_gb
  total_cpus=$(nproc)
  total_mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  total_mem_gb=$((total_mem_kb / 1024 / 1024))
  # Reserve 12% of total memory for KVM host
  host_reserve_gb=$((total_mem_gb * 12 / 100))
  available_mem_gb=$((total_mem_gb - host_reserve_gb))
  [[ ${available_mem_gb} -le 0 ]] && available_mem_gb=16
  
  # Check NUMA configuration for Sensor vCPU default calculation
  # Sensor default: NUMA1 vCPUs minus 4 (4 CPUs reserved for host)
  local numa_nodes=1
  local node1_cpus="" node1_count=0
  if command -v lscpu >/dev/null 2>&1; then
    numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    if [[ "${numa_nodes}" -ge 2 ]]; then
      # Extract NUMA node1 CPU list
      node1_cpus=$(lscpu | grep "NUMA node1 CPU(s):" | sed 's/NUMA node1 CPU(s)://' | tr -d '[:space:]')
      # Count CPUs in NUMA node1
      if [[ -n "${node1_cpus}" ]]; then
        node1_count=$(echo "${node1_cpus}" | tr ',' '\n' | wc -l)
      fi
    fi
  fi
  
  # Default memory: 30% of available memory (after 12% host reserve) for Sensor
  local default_sensor_mem_gb=$((available_mem_gb * 30 / 100))
  [[ ${default_sensor_mem_gb} -lt 8 ]] && default_sensor_mem_gb=8
  
  # Default vCPU: NUMA1 CPUs minus 4 (4 CPUs reserved for host)
  # This ensures Sensor gets NUMA1 CPUs except 4 reserved for host
  local default_sensor_vcpus
  if [[ "${numa_nodes}" -ge 2 && ${node1_count} -gt 0 ]]; then
    # Allocate NUMA1 CPUs minus 4 (4 CPUs reserved for host)
    default_sensor_vcpus=$((node1_count - 4))
    [[ ${default_sensor_vcpus} -lt 2 ]] && default_sensor_vcpus=2
  else
    # NUMA detection failed: Total CPUs minus 4 as fallback
    default_sensor_vcpus=$((total_cpus - 4))
    [[ ${default_sensor_vcpus} -lt 2 ]] && default_sensor_vcpus=2
  fi
  
  local default_sensor_disk_gb=200
  
  # Use existing values if set, otherwise use calculated defaults
  : "${SENSOR_MEMORY_MB:=}"
  : "${SENSOR_VCPUS:=}"
  : "${SENSOR_LV_SIZE_GB_PER_VM:=}"
  
  # 1) Memory
  # Always use calculated default value for input box (not saved value)
  local sensor_mem_gb="${default_sensor_mem_gb}"
  local _SENSOR_MEM_INPUT
  local mem_input_rc
  _SENSOR_MEM_INPUT="$(whiptail_inputbox "STEP 11 - Sensor (MDS) memory" "Enter memory (GB) for Sensor VM (mds).\n\nTotal memory: ${total_mem_gb}GB\nHost reserve (12%): ${host_reserve_gb}GB\nAvailable: ${available_mem_gb}GB\nDefault value: ${default_sensor_mem_gb}GB (30% of available)\nExample: Enter 32" "${default_sensor_mem_gb}" 14 80)"
  mem_input_rc=$?

  if [ ${mem_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 11] User canceled memory input. Exiting step."
    return 0
  fi

  if [ -n "${_SENSOR_MEM_INPUT}" ]; then
    if [[ "${_SENSOR_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_MEM_INPUT}" -gt 0 ]; then
      sensor_mem_gb="${_SENSOR_MEM_INPUT}"
    else
      whiptail_msgbox "STEP 11 - Sensor memory" "Invalid memory value.\nUsing current default (${default_sensor_mem_gb} GB)." 10 70
      sensor_mem_gb="${default_sensor_mem_gb}"
    fi
  else
    # Empty input - use default
    sensor_mem_gb="${default_sensor_mem_gb}"
  fi

  # 2) vCPU
  local vcpu_default_msg
  if [[ "${numa_nodes}" -ge 2 && ${node1_count} -gt 0 ]]; then
    vcpu_default_msg="Enter number of vCPUs for Sensor VM (mds).\n\nTotal logical CPUs: ${total_cpus}\nNUMA1 CPUs: ${node1_count}\nDefault value: ${default_sensor_vcpus} (NUMA1 CPUs - 4)\nExample: Enter 22"
  else
    vcpu_default_msg="Enter number of vCPUs for Sensor VM (mds).\n\nTotal logical CPUs: ${total_cpus}\nDefault value: ${default_sensor_vcpus} (total CPUs - 4)\nExample: Enter 22"
  fi
  local _SENSOR_VCPU_INPUT
  local vcpu_input_rc
  _SENSOR_VCPU_INPUT="$(whiptail_inputbox "STEP 11 - Sensor (MDS) vCPU" "${vcpu_default_msg}" "${SENSOR_VCPUS:-${default_sensor_vcpus}}" 12 70)"
  vcpu_input_rc=$?

  local sensor_vcpus
  if [ ${vcpu_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 11] User canceled vCPU input. Exiting step."
    return 0
  fi

  if [ -n "${_SENSOR_VCPU_INPUT}" ]; then
    if [[ "${_SENSOR_VCPU_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_VCPU_INPUT}" -gt 0 ]; then
      sensor_vcpus="${_SENSOR_VCPU_INPUT}"
    else
      whiptail_msgbox "STEP 11 - Sensor vCPU" "Invalid vCPU value.\nUsing current default (${default_sensor_vcpus})." 10 70
      sensor_vcpus="${default_sensor_vcpus}"
    fi
  else
    # Empty input - use default
    sensor_vcpus="${default_sensor_vcpus}"
  fi

  # 3) Disk size
  local _SENSOR_DISK_INPUT
  local disk_input_rc
  _SENSOR_DISK_INPUT="$(whiptail_inputbox "STEP 11 - Sensor (MDS) disk" "Enter disk size (GB) for Sensor VM (mds).\n\nMinimum size: 80GB\nDefault value: ${default_sensor_disk_gb}GB\nExample: Enter 200" "${SENSOR_LV_SIZE_GB_PER_VM:-${default_sensor_disk_gb}}" 12 70)"
  disk_input_rc=$?

  local sensor_disk_gb
  if [ ${disk_input_rc} -ne 0 ]; then
    # User canceled
    log "[STEP 11] User canceled disk size input. Exiting step."
    return 0
  fi

  if [ -n "${_SENSOR_DISK_INPUT}" ]; then
    if [[ "${_SENSOR_DISK_INPUT}" =~ ^[0-9]+$ ]] && [ "${_SENSOR_DISK_INPUT}" -gt 0 ]; then
      if [[ "${_SENSOR_DISK_INPUT}" -lt 80 ]]; then
        whiptail_msgbox "STEP 11 - Sensor disk" "Minimum disk size is 80GB.\nUsing current default (${default_sensor_disk_gb} GB)." 10 70
        sensor_disk_gb="${default_sensor_disk_gb}"
      else
        sensor_disk_gb="${_SENSOR_DISK_INPUT}"
      fi
    else
      whiptail_msgbox "STEP 11 - Sensor disk" "Invalid disk size value.\nUsing current default (${default_sensor_disk_gb} GB)." 10 70
      sensor_disk_gb="${default_sensor_disk_gb}"
    fi
  else
    # Empty input - use default
    sensor_disk_gb="${default_sensor_disk_gb}"
  fi

  # Convert memory to MB
  local mem_mds=$(( sensor_mem_gb * 1024 ))
  local cpus_mds="${sensor_vcpus}"
  local disksize="${sensor_disk_gb}"

  # NUMA Aware CPUSET Calculation Logic for mds (NUMA1)
  local numa_nodes=1
  local node1_cpus=""
  if command -v lscpu >/dev/null 2>&1; then
    numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    if [[ "${numa_nodes}" -ge 2 ]]; then
      # Extract NUMA node1 CPU list
      node1_cpus=$(lscpu | grep "NUMA node1 CPU(s):" | sed 's/NUMA node1 CPU(s)://' | tr -d '[:space:]')
    fi
  fi

  local sensor_cpuset_mds
  if [[ "${numa_nodes}" -ge 2 && -n "${node1_cpus}" ]]; then
    log "[STEP 11] NUMA node(${numa_nodes}) Detected. Setting CPU Pinning for mds on NUMA1."
    # Cut the list according to the number of vCPUs entered by the user (allocate from the front)
    sensor_cpuset_mds=$(echo "${node1_cpus}" | cut -d',' -f1-"${sensor_vcpus}")
    log "  -> MDS (Node1): ${sensor_cpuset_mds}"
  else
    log "[STEP 11] NUMA detection failed. Using sequential allocation."
    sensor_cpuset_mds="0-$((sensor_vcpus-1))"
  fi

  # Save configuration
  SENSOR_MEMORY_MB="${mem_mds}"
  SENSOR_MEMORY_MB_PER_VM="${mem_mds}"
  SENSOR_TOTAL_MEMORY_MB="${mem_mds}"
  SENSOR_VCPUS="${cpus_mds}"
  SENSOR_VCPUS_PER_VM="${cpus_mds}"
  SENSOR_TOTAL_VCPUS="${cpus_mds}"
  SENSOR_CPUSET_MDS="${sensor_cpuset_mds}"
  SENSOR_LV_SIZE_GB_PER_VM="${sensor_disk_gb}"
  SENSOR_TOTAL_LV_SIZE_GB="${sensor_disk_gb}"
  LV_SIZE_GB="${sensor_disk_gb}"

  log "Configured sensor vCPU: ${SENSOR_VCPUS} (mds cpuset=${SENSOR_CPUSET_MDS})"

  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  #######################################
  # 3) Sensor VM deployment (mds single)
  #######################################
  log "[STEP 11] Starting sensor VM deployment for mds"

  local release="${SENSOR_VERSION}"
  local nodownload="1"

  # common environment variables
  export disksize="${disksize}"

  local hostname="mds"
  log "[STEP 11] -------- ${hostname} deployment started --------"
    
    local installdir="/var/lib/libvirt/images/${hostname}"
    local cpus="${cpus_mds}"
    local memory="${mem_mds}"

  # Configure environment variables (NAT mode only)
  export BRIDGE="virbr0"
  export SENSOR_BRIDGE="virbr0"
  export NETWORK_MODE="nat"
  
  # NAT IP assignment (mds uses 192.168.122.3)
  # NOTE: DHCP is disabled per Ubuntu 24.04 deployment guide, so virbr0.status file will NOT be created
  # Static IP (192.168.122.3) is used instead, so retrieve_ip_nat() will be skipped
  export IP="192.168.122.3"
  export LOCAL_IP="192.168.122.3"
  export NETMASK="255.255.255.0"
  export GATEWAY="192.168.122.1"
  export DNS="8.8.8.8"
  
  log "[STEP 11] ${hostname} (NAT) environment variables: IP=${LOCAL_IP}"
  
  # NAT Mode: Ensure default network is started
  if [[ "${DRY_RUN}" -ne 1 ]]; then
    log "[STEP 11] NAT Mode - Ensuring default network is ready..."
    if ! virsh net-list | grep -q "default.*active"; then
      log "[STEP 11] Starting default libvirt network..."
      virsh net-start default 2>/dev/null || true
      sleep 2
    fi
    
    # Verify network is active
    if virsh net-list | grep -q "default.*active"; then
      log "[STEP 11] Default network is active (DHCP disabled, using static IP ${LOCAL_IP})"
    else
      log "[WARNING] Default network could not be started"
    fi
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # For NAT mode, add --ip to specify static IP and skip retrieve_ip_nat() wait
    local deploy_cmd="bash '${script_path}' -- --hostname='${hostname}' --release='${release}' --CPUS='${cpus}' --MEM='${memory}' --DISKSIZE='${disksize}' --installdir='${installdir}' --nodownload='${nodownload}' --bridge='${BRIDGE}' --ip='${LOCAL_IP}' --netmask='${NETMASK}' --gw='${GATEWAY}' --dns='${DNS}' --nointeract='true'"
    log "[DRY-RUN] ${hostname} deployment command:\n${deploy_cmd}"
  else
    cd "/var/lib/libvirt/images/mds/images" || return 1
    
    # Verify script exists and is executable
    if [[ ! -f "virt_deploy_modular_ds.sh" ]]; then
      log "ERROR: Deployment script not found: virt_deploy_modular_ds.sh"
      return 1
    fi
    
    if [[ ! -x "virt_deploy_modular_ds.sh" ]]; then
      log "[WARN] Deployment script is not executable. Adding execute permission..."
      chmod +x virt_deploy_modular_ds.sh
    fi
    
    set +e
      
    # NAT Mode: Add static IP parameters to skip retrieve_ip_nat() wait
    # Add --nointeract=true to prevent interactive prompts
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
    log "[INFO] NAT Mode: Using static IP ${LOCAL_IP} (skips DHCP IP assignment wait and virbr0.status file check)"

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
    fi

  log "[STEP 11] Sensor VM deployment completed"
  
  # Create summary message
  local tmp_summary="/tmp/step11_summary.txt"
  {
    echo "STEP 11 - Sensor VM Deployment Summary"
    echo "═══════════════════════════════════════════════════════════"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "🔍 DRY-RUN MODE: No actual deployment was made"
      echo
      echo "📊 SIMULATED STATUS:"
      echo "  • VM name: mds"
      echo "  • VM status: Would be created"
      echo
      echo "ℹ️  In real execution mode, the following would occur:"
      echo "  1. VM Deployment:"
      echo "     - Sensor VM (mds) would be created"
      echo "     - Hostname: mds"
      echo "     - Network: NAT mode (virbr0, 192.168.122.3)"
      echo "     - vCPU: ${cpus_mds}"
      echo "     - Memory: ${mem_mds}MB"
      echo "     - Disk: ${disksize}GB"
      echo
      echo "  2. Network Configuration:"
      echo "     - Bridge: virbr0 (NAT)"
      echo "     - IP: 192.168.122.3"
      echo "     - Gateway: 192.168.122.1"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • VM deployment requires sensor image and script from STEP 10"
      echo "  • Initial boot may take time due to Cloud-Init operations"
    else
      echo "✅ EXECUTION COMPLETED"
      echo
      echo "📊 DEPLOYMENT STATUS:"
      local vm_state="unknown"
      if virsh dominfo mds >/dev/null 2>&1; then
        vm_state=$(virsh domstate mds 2>/dev/null || echo "unknown")
        echo "  • VM name: mds"
        echo "  • VM status: ${vm_state}"
        echo "    ✅ Sensor VM created successfully"
      else
        echo "  • VM name: mds"
        echo "  • VM status: Not found"
        echo "    ⚠️  VM creation may have failed"
      fi
      echo
      echo "🖥️  VM CONFIGURATION:"
      echo "  • Hostname: mds"
      echo "  • vCPU: ${cpus_mds}"
      echo "  • Memory: ${mem_mds}MB"
      echo "  • Disk: ${disksize}GB"
      echo
      echo "🌐 NETWORK CONFIGURATION:"
      echo "  • Network mode: NAT"
      echo "  • Bridge: virbr0"
      echo "  • IP address: 192.168.122.3"
      echo "  • Gateway: 192.168.122.1"
      echo "  • Netmask: 255.255.255.0"
      echo
      echo "⚠️  IMPORTANT:"
      echo "  • Initial boot may take time due to Cloud-Init operations"
      echo "  • Check VM status with: virsh list --all"
      echo "  • Access VM console with: virsh console mds"
      echo "  • Proceed to STEP 12 for PCI passthrough and CPU affinity"
    fi
  } > "${tmp_summary}"
  
  show_textbox "STEP 11 - Sensor VM Deployment Summary" "${tmp_summary}"
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - ${STEP_NAME} ====="
  log "[STEP 11] Sensor VM deployment completed successfully."
  
  return 0
}


step_12_sensor_passthrough() {
    local STEP_ID="12_sensor_passthrough"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. Sensor PCI Passthrough / CPU Affinity configuration and verify ====="

    # config as de
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    local SENSOR_VMS=("mds")

    ###########################################################################
    # Check NUMA count (use lscpu)
    ###########################################################################
    local numa_nodes=1
    if command -v lscpu >/dev/null 2>&1; then
        numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    fi
    [[ -z "${numa_nodes}" ]] && numa_nodes=1

    log "[STEP 12] NUMA node count: ${numa_nodes}"

    ###########################################################################
    # common path
    ###########################################################################
    local SRC_BASE="/var/lib/libvirt/images"
    local IMAGES_BASE="/var/lib/libvirt/images"   # mds=/var/lib/libvirt/images/mds

    ###########################################################################
    # Process each Sensor VM in SENSOR_VMS array
    ###########################################################################
    # Store sensor results for combined display
    local sensor_result_files=()
    
    for SENSOR_VM in "${SENSOR_VMS[@]}"; do
        log "[STEP 12] ----- Sensor VM processing start: ${SENSOR_VM} -----"

        #######################################################################
        # 0. Determine mount point + check mount
        #######################################################################
        local DST_BASE="${IMAGES_BASE}/mds"

        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] (${SENSOR_VM}) (MOUNTCHK) mountpoint -q ${DST_BASE}"
        else
            if ! mountpoint -q "${DST_BASE}" 2>/dev/null; then
                whiptail_msgbox "STEP 12 - Mount Error" "${SENSOR_VM}: ${DST_BASE} is not mounted.\n\nPlease complete STEP 10 mount of ${DST_BASE} first." 12 70
                log "[STEP 12] ERROR: ${SENSOR_VM}: ${DST_BASE} not mounted → skip this VM"
                continue
            fi
        fi

        #######################################################################
        # 1. Check Sensor VM existence
        #######################################################################
        if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
            log "[STEP 12] WARNING: Sensor VM(${SENSOR_VM}) not found. Skip this VM."
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
                log "[STEP 12] ${SENSOR_VM}: Running → shutdown"
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
                log "[STEP 12] ${SENSOR_VM}: WARN: Image directory not found at ${VM_IMAGE_DIR} or ${VM_IMAGE_DIR_ALT}"
                log "[STEP 12] ${SENSOR_VM}: This may be normal if STEP 11 has not been executed yet"
            else
                log "[STEP 12] ${SENSOR_VM}: Image directory verified"
            fi

            # Check if source files referenced by XML actually exist
            log "[STEP 12] ${SENSOR_VM}: Check XML source file existence"
            local missing=0
            while read -r f; do
                [[ -z "${f}" ]] && continue
                if [[ ! -e "${f}" ]]; then
                    log "[STEP 12] ${SENSOR_VM}: ERROR: missing file: ${f}"
                    missing=$((missing+1))
                fi
            done < <(virsh dumpxml "${SENSOR_VM}" | awk -F"'" '/<source file=/{print $2}')

            if [[ "${missing}" -gt 0 ]]; then
                whiptail_msgbox "STEP 12 - File Missing" "${SENSOR_VM}: ${missing} files referenced by VM XML are missing.\n\nPlease redeploy STEP 11 or check image file location." 12 70
                log "[STEP 12] ${SENSOR_VM}: ERROR: XML source file missing count=${missing} → may not be able to start"
            fi
        fi

        #######################################################################
        # 2. Connect PCI Passthrough device (Action) - mds only
        #######################################################################
        local VM_PCIS="${SENSOR_SPAN_VF_PCIS_MDS:-}"

        if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${VM_PCIS}" ]]; then
            log "[STEP 12] ${SENSOR_VM}: Starting PCI passthrough device connection (pcis=${VM_PCIS})"

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
                            # Check if VM is running
                            local vm_running=0
                            if virsh list --state-running | grep -q "^${SENSOR_VM}$"; then
                                vm_running=1
                            fi
                            
                            # Use --live only if VM is running, otherwise use --config only
                            local attach_opts="--config"
                            if [[ "${vm_running}" -eq 1 ]]; then
                                attach_opts="--config --live"
                                log "[INFO] ${SENSOR_VM}: VM is running, using --live option"
                            else
                                log "[INFO] ${SENSOR_VM}: VM is not running, using --config only"
                            fi
                            
                            if virsh attach-device "${SENSOR_VM}" "${pci_xml}" ${attach_opts}; then
                                log "[SUCCESS] ${SENSOR_VM}: Device connection successful"
                            else
                                log "[ERROR] ${SENSOR_VM}: Device connection failed (already in use or check IOMMU configuration)"
                            fi
                        else
                            log "[DRY-RUN] virsh attach-device ${SENSOR_VM} ${pci_xml} --config --live"
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
        log "[STEP 12] ${SENSOR_VM}: Final PCI Passthrough status check"

        local hostdev_count=0
        if virsh dumpxml "${SENSOR_VM}" | grep -q "<hostdev.*type='pci'"; then
            hostdev_count=$(virsh dumpxml "${SENSOR_VM}" | grep -c "<hostdev.*type='pci'" || echo "0")
            log "[STEP 12] ${SENSOR_VM}: ${hostdev_count} PCI hostdev devices connected"
        else
            log "[WARN] ${SENSOR_VM}: No PCI hostdev devices found."
        fi

        #######################################################################
        # 4. Apply CPU Affinity (multiple NUMA only) - mds uses NUMA1
        #######################################################################
        if [[ "${numa_nodes}" -gt 1 ]]; then
            log "[STEP 12] ${SENSOR_VM}: CPU Affinity application start"

            local cpuset_for_vm="${SENSOR_CPUSET_MDS:-}"

            if [[ -z "${cpuset_for_vm}" ]]; then
                # Extract NUMA node1 CPU list for mds
                local node1_cpus
                node1_cpus=$(lscpu | grep "NUMA node1 CPU(s):" | sed 's/NUMA node1 CPU(s)://' | tr -d '[:space:]')
                if [[ -n "${node1_cpus}" ]]; then
                    cpuset_for_vm="${node1_cpus}"
                else
                    log "[WARN] ${SENSOR_VM}: Cannot retrieve NUMA node1 CPU list, cannot apply Affinity."
                    cpuset_for_vm=""
                fi
            fi

            if [[ -z "${cpuset_for_vm}" ]]; then
                log "[WARN] ${SENSOR_VM}: Per VM CPUSET is empty, so skip Affinity"
            else
                # Convert cpuset string to array (e.g., "48,49,50" -> array with 48, 49, 50)
                local cpu_arr=()
                local c
                for c in $(echo "${cpuset_for_vm}" | tr ',' ' '); do
                    cpu_arr+=("${c}")
                done

                if [[ "${#cpu_arr[@]}" -eq 0 ]]; then
                    log "[WARN] ${SENSOR_VM}: CPU array is empty, so skip Affinity"
                else
                    log "[ACTION] ${SENSOR_VM}: CPU Affinity configuration (CPU list: ${cpuset_for_vm})"
                    
                    # Get maximum vCPU count
                    local max_vcpus
                    max_vcpus="$(virsh vcpucount "${SENSOR_VM}" --maximum --config 2>/dev/null || echo 0)"
                    max_vcpus=$(echo "${max_vcpus}" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
                    [[ -z "${max_vcpus}" ]] && max_vcpus="0"

                    if [[ "${max_vcpus}" -eq 0 ]]; then
                        log "[WARN] ${SENSOR_VM}: Unable to determine vCPU count → skipping CPU Affinity"
                    else
                        # Limit vCPU count to available CPUs
                        if [[ "${#cpu_arr[@]}" -lt "${max_vcpus}" ]]; then
                            log "[WARN] ${SENSOR_VM}: CPU list count(${#cpu_arr[@]}) is less than maximum vCPU(${max_vcpus}). Limiting to ${#cpu_arr[@]} vCPUs."
                            max_vcpus="${#cpu_arr[@]}"
                        fi

                        # Set emulatorpin to all CPUs in the list (for emulator thread)
                        local emulator_cpuset
                        emulator_cpuset=$(echo "${cpuset_for_vm}" | tr ' ' ',')
                        if [[ "${_DRY}" -eq 0 ]]; then
                            virsh emulatorpin "${SENSOR_VM}" "${emulator_cpuset}" --config >/dev/null 2>&1 || true
                            
                            # Pin each vCPU to individual pCPU
                            local i
                            for (( i=0; i<max_vcpus; i++ )); do
                                local pcpu="${cpu_arr[$i]}"
                                if virsh vcpupin "${SENSOR_VM}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
                                    log "[STEP 12] ${SENSOR_VM}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
                                else
                                    log "[WARN] ${SENSOR_VM}: vCPU ${i} -> pCPU ${pcpu} pin failed"
                                fi
                            done
                        else
                            log "[DRY-RUN] ${SENSOR_VM}: emulatorpin cpuset=${emulator_cpuset} (not executed)"
                            for (( i=0; i<max_vcpus; i++ )); do
                                local pcpu="${cpu_arr[$i]}"
                                log "[DRY-RUN] ${SENSOR_VM}: vcpupin ${i} ${pcpu} --config (not executed)"
                            done
                        fi
                    fi
            fi
        fi
    fi

        #######################################################################
        # 4.5 Safe restart to apply configuration
        #######################################################################
        if ! restart_vm_safely "${SENSOR_VM}"; then
            log "[WARN] ${SENSOR_VM}: VM restart failed, but continuing..."
        fi

        #######################################################################
        # 5. Result report (Per VM)
        #######################################################################
        # Get actual CPU affinity setting for display
        local actual_cpuset=""
        if [[ "${numa_nodes}" -gt 1 ]]; then
            actual_cpuset="${cpuset_for_vm:-}"
            if [[ -z "${actual_cpuset}" ]]; then
                # Try to get from virsh if already configured
                actual_cpuset=$(virsh emulatorpin "${SENSOR_VM}" --config 2>/dev/null | grep "emulator: CPU Affinity" | sed 's/.*: //' || echo "")
            fi
        fi
        
        local result_file="/tmp/step12_result_${SENSOR_VM}.txt"
        {
            echo "STEP 12 - PCI Passthrough / CPU Affinity Verification (${SENSOR_VM})"
            echo "═══════════════════════════════════════════════════════════"
            if [[ "${_DRY}" -eq 1 ]]; then
                echo "🔍 DRY-RUN MODE: No actual changes were made"
                echo
                echo "📊 SIMULATED STATUS:"
                echo "  • VM status: Would be checked"
                echo "  • PCI passthrough: Would be configured"
                echo "  • CPU affinity: Would be applied"
                echo
                echo "ℹ️  In real execution mode, the following would occur:"
                echo "  1. PCI Passthrough Configuration:"
                if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${VM_PCIS}" ]]; then
                    echo "     - SPAN NIC PCI devices would be attached to ${SENSOR_VM}"
                    echo "     - PCI devices: ${VM_PCIS}"
                    echo "     - VM XML would be modified to include hostdev entries"
                else
                    echo "     - No PCI passthrough configured (SPAN_ATTACH_MODE=${SPAN_ATTACH_MODE:-<not set>})"
                fi
                echo
                echo "  2. CPU Affinity Configuration:"
                if [[ "${numa_nodes}" -gt 1 ]]; then
                    echo "     - CPU pinning would be applied to NUMA1 CPUs"
                    if [[ -n "${actual_cpuset}" ]]; then
                        echo "     - CPU set: ${actual_cpuset}"
                    fi
                    echo "     - Emulator pinning would be configured"
                fi
                echo
                echo "  3. VM Restart:"
                echo "     - ${SENSOR_VM} would be safely restarted to apply changes"
            else
                echo "✅ EXECUTION COMPLETED"
                echo
                echo "📊 CONFIGURATION STATUS:"
                local vm_state
                vm_state=$(virsh domstate ${SENSOR_VM} 2>/dev/null || echo "unknown")
                echo "  • VM status: ${vm_state}"
                echo
                echo "🔌 PCI PASSTHROUGH:"
                if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${VM_PCIS}" ]]; then
                    echo "  • Applied PCI list: ${VM_PCIS}"
                    echo "  • PCI device connection count: ${hostdev_count}"
            if [[ "${hostdev_count}" -gt 0 ]]; then
                        echo "    ✅ Success: PCI Passthrough is working normally"
                    else
                        echo "    ❌ Failure: PCI device not connected"
                        echo "    💡 Please check STEP 01 configuration (SPAN NIC selection)"
                    fi
                else
                    echo "  • PCI passthrough: Not configured"
                    echo "    - SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE:-<not set>}"
                    echo "    - PCI devices: ${VM_PCIS:-<empty>}"
                fi
                echo
                echo "⚙️  CPU AFFINITY:"
                if [[ "${numa_nodes}" -gt 1 ]]; then
                    if [[ -n "${actual_cpuset}" ]]; then
                        echo "  • CPU set: ${actual_cpuset}"
                        echo "  • NUMA node: NUMA1"
                        echo "    ✅ CPU affinity configured successfully"
                    else
                        echo "  • ⚠️  CPU affinity not configured (NUMA1 CPU detection failed)"
                    fi
                fi
            fi
            echo
            echo "⚠️  IMPORTANT:"
            echo "  • PCI passthrough requires IOMMU to be enabled (configured in STEP 05)"
            echo "  • VM must be stopped before PCI passthrough configuration"
            echo "  • Verify PCI passthrough with: virsh dumpxml ${SENSOR_VM} | grep hostdev"
            echo "  • Verify CPU affinity with: virsh vcpupin ${SENSOR_VM}"
        } > "${result_file}"

        # Store result file for combined display (don't show individually)
        sensor_result_files+=("${result_file}")

        log "[STEP 12] ----- Sensor VM processing completed: ${SENSOR_VM} -----"
    done

    ###########################################################################
    # Process AIO VM CPU Affinity (if multiple NUMA nodes)
    ###########################################################################
    log "[STEP 12] ===== Starting AIO VM CPU Affinity processing ====="
    log "[STEP 12] NUMA nodes count: ${numa_nodes}"
    if [[ "${numa_nodes}" -gt 1 ]]; then
        log "[STEP 12] ----- AIO VM CPU Affinity processing start: aio -----"
        
        local AIO_VM="aio"
        
        # Check AIO VM existence
        local actual_cpuset_aio=""
        local cpuset_for_aio=""
        
        if ! virsh dominfo "${AIO_VM}" >/dev/null 2>&1; then
            log "[STEP 12] WARNING: AIO VM(${AIO_VM}) not found. Skip CPU affinity configuration."
        else
            log "[STEP 12] ${AIO_VM}: CPU Affinity application start"
            
            cpuset_for_aio="${AIO_CPUSET:-}"
            
            if [[ -z "${cpuset_for_aio}" ]]; then
                # Extract NUMA node0 CPU list for aio
                local node0_cpus
                node0_cpus=$(lscpu | grep "NUMA node0 CPU(s):" | sed 's/NUMA node0 CPU(s)://' | tr -d '[:space:]')
                if [[ -n "${node0_cpus}" ]]; then
                    cpuset_for_aio="${node0_cpus}"
                else
                    log "[WARN] ${AIO_VM}: Cannot retrieve NUMA node0 CPU list, cannot apply Affinity."
                    cpuset_for_aio=""
                fi
            fi
            
            if [[ -z "${cpuset_for_aio}" ]]; then
                log "[WARN] ${AIO_VM}: CPUSET is empty, so skip Affinity"
            else
                # Convert cpuset string to array (e.g., "0,2,4,6" -> array with 0, 2, 4, 6)
                local cpu_arr=()
                local c
                for c in $(echo "${cpuset_for_aio}" | tr ',' ' '); do
                    cpu_arr+=("${c}")
                done

                if [[ "${#cpu_arr[@]}" -eq 0 ]]; then
                    log "[WARN] ${AIO_VM}: CPU array is empty, so skip Affinity"
                else
                    log "[ACTION] ${AIO_VM}: CPU Affinity configuration (CPU list: ${cpuset_for_aio})"
                    
                    # Safely stop if VM is running (for CPU affinity configuration)
                    if virsh list --name | grep -q "^${AIO_VM}$"; then
                        log "[STEP 12] ${AIO_VM}: Running → shutdown"
                        virsh shutdown "${AIO_VM}" >/dev/null 2>&1 || true
                        
                        local t=0
                        while virsh list --name | grep -q "^${AIO_VM}$"; do
                            sleep 2
                            t=$((t+2))
                            if [[ $t -ge 120 ]]; then
                                log "[WARN] ${AIO_VM}: shutdown timeout → destroy"
                                virsh destroy "${AIO_VM}" >/dev/null 2>&1 || true
                                break
                            fi
                        done
                    fi
                    
                    # Get maximum vCPU count
                    local max_vcpus
                    max_vcpus="$(virsh vcpucount "${AIO_VM}" --maximum --config 2>/dev/null || echo 0)"
                    max_vcpus=$(echo "${max_vcpus}" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
                    [[ -z "${max_vcpus}" ]] && max_vcpus="0"

                    if [[ "${max_vcpus}" -eq 0 ]]; then
                        log "[WARN] ${AIO_VM}: Unable to determine vCPU count → skipping CPU Affinity"
                    else
                        # Limit vCPU count to available CPUs
                        if [[ "${#cpu_arr[@]}" -lt "${max_vcpus}" ]]; then
                            log "[WARN] ${AIO_VM}: CPU list count(${#cpu_arr[@]}) is less than maximum vCPU(${max_vcpus}). Limiting to ${#cpu_arr[@]} vCPUs."
                            max_vcpus="${#cpu_arr[@]}"
                        fi

                        # Set emulatorpin to all CPUs in the list (for emulator thread)
                        local emulator_cpuset
                        emulator_cpuset=$(echo "${cpuset_for_aio}" | tr ' ' ',')
                        if [[ "${_DRY}" -eq 0 ]]; then
                            virsh emulatorpin "${AIO_VM}" "${emulator_cpuset}" --config >/dev/null 2>&1 || true
                            
                            # Pin each vCPU to individual pCPU
                            local i
                            for (( i=0; i<max_vcpus; i++ )); do
                                local pcpu="${cpu_arr[$i]}"
                                if virsh vcpupin "${AIO_VM}" "${i}" "${pcpu}" --config >/dev/null 2>&1; then
                                    log "[STEP 12] ${AIO_VM}: vCPU ${i} -> pCPU ${pcpu} pin (--config) completed"
                                else
                                    log "[WARN] ${AIO_VM}: vCPU ${i} -> pCPU ${pcpu} pin failed"
                                fi
                            done
                            log "[STEP 12] ${AIO_VM}: CPU Affinity applied to NUMA0 (CPU list: ${cpuset_for_aio})"
                            
                            # Get actual CPU affinity setting for display
                            actual_cpuset_aio=$(virsh emulatorpin "${AIO_VM}" --config 2>/dev/null | grep "emulator: CPU Affinity" | sed 's/.*: //' || echo "")
                            if [[ -z "${actual_cpuset_aio}" ]]; then
                                actual_cpuset_aio="${emulator_cpuset}"
                            fi
                            
                            # Save AIO_CPUSET to configuration
                            AIO_CPUSET="${cpuset_for_aio}"
                            if type save_config >/dev/null 2>&1; then
                                save_config
                            fi
                        else
                            log "[DRY-RUN] ${AIO_VM}: emulatorpin cpuset=${emulator_cpuset} (not executed)"
                            for (( i=0; i<max_vcpus; i++ )); do
                                local pcpu="${cpu_arr[$i]}"
                                log "[DRY-RUN] ${AIO_VM}: vcpupin ${i} ${pcpu} --config (not executed)"
                            done
                            actual_cpuset_aio="${emulator_cpuset}"
                        fi
                        
                        # Safe restart to apply configuration
                        restart_vm_safely "${AIO_VM}"
                    fi
                fi
            fi
        fi
        
        log "[STEP 12] ----- AIO VM CPU Affinity processing completed: aio -----"
    fi
    
    #######################################################################
    # AIO data disk (LV) attach (vg_aio/lv_aio → vdb, --config)
    # This is done regardless of NUMA configuration
    #######################################################################
    local AIO_VM="aio"
    local DATA_LV="/dev/mapper/vg_aio-lv_aio"
    local data_disk_attached=0
    local data_disk_status=""
    
    # Helper function to extract and normalize vdb source from VM XML
    get_vdb_source() {
        local vm_name="$1"
        local vdb_xml
        vdb_xml=$(virsh dumpxml "${vm_name}" 2>/dev/null | grep -A 20 "target dev='vdb'" | head -20 || echo "")
        
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
        vdb_xml=$(virsh dumpxml "${vm_name}" --inactive 2>/dev/null | grep -A 20 "target dev='vdb'" | head -20 || echo "")
        
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
    
    # Helper function to check if vdb is correctly attached (backward compatible)
    check_vdb_attached() {
        local vm_name="$1"
        local expected_lv="$2"
        local current_source
        
        current_source=$(get_vdb_source "${vm_name}")
        
        if [[ -z "${current_source}" ]]; then
            return 1  # vdb not found
        fi
        
        # Normalize both paths for comparison
        local normalized_current normalized_expected
        normalized_current=$(normalize_device_path "${current_source}")
        normalized_expected=$(normalize_device_path "${expected_lv}")
        
        local current_clean expected_clean
        current_clean=$(echo "${normalized_current}" | tr -d '[:space:]' || echo "${normalized_current}")
        expected_clean=$(echo "${normalized_expected}" | tr -d '[:space:]' || echo "${normalized_expected}")
        
        if [[ "${normalized_current}" == "${normalized_expected}" ]] || \
           [[ "${current_source}" == "${expected_lv}" ]] || \
           [[ "${current_clean}" == "${expected_clean}" ]]; then
            return 0  # Correctly attached
        else
            return 1  # Different device attached
        fi
    }
    
    if [[ -e "${DATA_LV}" ]]; then
        if virsh dominfo "${AIO_VM}" >/dev/null 2>&1; then
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] Check VM state and attach ${DATA_LV} as vdb to ${AIO_VM} (live+config or config-only)"
                data_disk_status="Would be attached"
                data_disk_attached=1
            else
                # Get VM state
                local vm_state
                vm_state=$(get_vm_state "${AIO_VM}")
                local aio_running=0
                if [[ "${vm_state}" == *"running"* ]]; then
                    aio_running=1
                fi
                
                log "[STEP 12] ${AIO_VM} state: ${vm_state}"
                
                # Check if vdb is already correctly attached (both config and live if running)
                local config_ok=0 live_ok=0
                if check_vdb_attached_config "${AIO_VM}" "${DATA_LV}"; then
                    config_ok=1
                fi
                
                if [[ ${aio_running} -eq 1 ]]; then
                    if check_vdb_attached_live "${AIO_VM}" "${DATA_LV}"; then
                        live_ok=1
                    fi
                else
                    # Shutoff state: live check not applicable
                    live_ok=1
                fi
                
                log "[STEP 12] Verification before attach: config_ok=${config_ok}, live_ok=${live_ok}"
                
                # Determine if attachment is needed
                local needs_attach=1
                if [[ ${aio_running} -eq 1 ]]; then
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
                    log "[STEP 12] ${AIO_VM} already has correct data disk(${DATA_LV}) as vdb → skipping"
                    data_disk_attached=1
                    data_disk_status="Already attached"
                else
                    # Check if vdb exists but with different device
                    local current_vdb_source
                    current_vdb_source=$(get_vdb_source "${AIO_VM}")
                    if [[ -n "${current_vdb_source}" ]]; then
                        log "[STEP 12] ${AIO_VM} has vdb but it's not ${DATA_LV} (current: ${current_vdb_source})"
                        log "[STEP 12] Will detach current vdb and attach ${DATA_LV} as vdb"
                        
                        # Detach existing vdb based on VM state
                        if [[ ${aio_running} -eq 1 ]]; then
                            log "[STEP 12] Detaching vdb (live+config) from ${AIO_VM}..."
                            virsh detach-disk "${AIO_VM}" vdb --live >/dev/null 2>&1 || true
                            virsh detach-disk "${AIO_VM}" vdb --config >/dev/null 2>&1 || true
                        else
                            log "[STEP 12] Detaching vdb (config-only) from ${AIO_VM}..."
                            virsh detach-disk "${AIO_VM}" vdb --config >/dev/null 2>&1 || true
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
                    
                    if [[ ${aio_running} -eq 1 ]]; then
                        attach_mode="live+config"
                        log "[STEP 12] Attaching ${DATA_LV} as vdb to ${AIO_VM} (attach mode: ${attach_mode})..."
                        
                        # Try --persistent first (if supported)
                        local attach_success=0
                        local config_attach_success=0
                        local attach_cmd=""
                        
                        # Build attach command based on device type
                        if [[ ${is_block_device} -eq 1 ]]; then
                            # Block device: use --subdriver raw (or omit subdriver, let libvirt auto-detect)
                            attach_cmd="virsh attach-disk \"${AIO_VM}\" \"${DATA_LV}\" vdb --persistent"
                        else
                            # File: use default (libvirt will detect format)
                            attach_cmd="virsh attach-disk \"${AIO_VM}\" \"${DATA_LV}\" vdb --persistent"
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
                                if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1; then
                                    log "[STEP 12] Live attach succeeded"
                                    if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded"
                                    else
                                        log "[WARN] Live attach succeeded but config attach failed"
                                    fi
                                else
                                    log "[WARN] Live attach failed, trying config-only as fallback"
                                    if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded (live failed)"
                                    fi
                                fi
                            else
                                # File: default behavior
                                if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1; then
                                    log "[STEP 12] Live attach succeeded"
                                    if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded"
                                    else
                                        log "[WARN] Live attach succeeded but config attach failed"
                                    fi
                                else
                                    log "[WARN] Live attach failed, trying config-only as fallback"
                                    if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                                        attach_success=1
                                        config_attach_success=1
                                        log "[STEP 12] Config attach succeeded (live failed)"
                                    fi
                                fi
                            fi
                        fi
                        
                        if [[ ${attach_success} -eq 0 ]]; then
                            log "[WARN] ${AIO_VM} data disk attach command failed, will verify actual status"
                        fi
                    else
                        attach_mode="config-only"
                        log "[STEP 12] Attaching ${DATA_LV} as vdb to ${AIO_VM} (attach mode: ${attach_mode})..."
                        
                        # For block devices, libvirt will auto-detect raw, no need to specify
                        local config_attach_success=0
                        if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                            config_attach_success=1
                        else
                            log "[WARN] ${AIO_VM} data disk attach command failed, will verify actual status"
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
                        if check_vdb_attached_config "${AIO_VM}" "${DATA_LV}"; then
                            final_config_ok=1
                        else
                            final_config_ok=0
                        fi
                        
                        # Check live (only if running)
                        if [[ ${aio_running} -eq 1 ]]; then
                            if check_vdb_attached_live "${AIO_VM}" "${DATA_LV}"; then
                                final_live_ok=1
                            else
                                final_live_ok=0
                            fi
                        else
                            final_live_ok=1  # Not applicable for shutoff
                        fi
                        
                        log "[STEP 12] Verification attempt ${verify_count}/${max_verify_attempts}: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                        
                        # Determine success based on VM state
                        if [[ ${aio_running} -eq 1 ]]; then
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
                    if [[ ${aio_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]] && [[ ${verification_passed} -eq 0 ]]; then
                        local config_retry_count=0
                        local max_config_retries=5
                        while [[ ${config_retry_count} -lt ${max_config_retries} ]]; do
                            config_retry_count=$((config_retry_count + 1))
                            sleep 1
                            if check_vdb_attached_config "${AIO_VM}" "${DATA_LV}"; then
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
                        if [[ ${aio_running} -eq 1 ]]; then
                            virsh detach-disk "${AIO_VM}" vdb --live >/dev/null 2>&1 || true
                            virsh detach-disk "${AIO_VM}" vdb --config >/dev/null 2>&1 || true
                            sleep 1
                            # Block device: no subdriver specified (raw is default)
                            if virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --persistent >/dev/null 2>&1; then
                                log "[STEP 12] Final recovery: --persistent attach succeeded"
                            else
                                virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --live >/dev/null 2>&1 || true
                                virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1 || true
                            fi
                        else
                            virsh detach-disk "${AIO_VM}" vdb --config >/dev/null 2>&1 || true
                            sleep 1
                            virsh attach-disk "${AIO_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1 || true
                        fi
                        
                        sleep 2
                        
                        # Final verification after recovery
                        final_config_ok=0
                        final_live_ok=0
                        if check_vdb_attached_config "${AIO_VM}" "${DATA_LV}"; then
                            final_config_ok=1
                        fi
                        if [[ ${aio_running} -eq 1 ]]; then
                            if check_vdb_attached_live "${AIO_VM}" "${DATA_LV}"; then
                                final_live_ok=1
                            fi
                        else
                            final_live_ok=1
                        fi
                        
                        if [[ ${aio_running} -eq 1 ]]; then
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
                        if [[ ${aio_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]]; then
                            log "[STEP 12] ${AIO_VM} data disk(${DATA_LV}) attached as vdb (live) - persistence pending"
                            log "[STEP 12] Status: Attached (live), persistence pending"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                            log "[WARN] Config verification failed but live attachment is working. Persistence may not be saved."
                            log "[WARN] Please manually verify with: virsh dumpxml ${AIO_VM} --inactive | grep vdb"
                            data_disk_attached=1
                            data_disk_status="Attached (live), persistence pending"
                        else
                            log "[STEP 12] ${AIO_VM} data disk(${DATA_LV}) attached as vdb (${attach_mode}) completed and verified"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                            data_disk_attached=1
                            data_disk_status="Attached successfully"
                        fi
                    else
                        # Only report as failed if live is also not OK (for running VM)
                        if [[ ${aio_running} -eq 1 ]] && [[ ${final_live_ok} -eq 0 ]]; then
                            log "[ERROR] ${AIO_VM} data disk(${DATA_LV}) attach failed after all attempts"
                            log "[ERROR] Final verification: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                            log "[DEBUG] VM XML vdb section (config):"
                            virsh dumpxml "${AIO_VM}" --inactive 2>/dev/null | grep -A 10 "target dev='vdb'" | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                            log "[DEBUG] Live block list:"
                            virsh domblklist "${AIO_VM}" --details 2>/dev/null | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                            data_disk_status="Attach failed"
                        elif [[ ${aio_running} -eq 1 ]] && [[ ${final_live_ok} -eq 1 ]] && [[ ${final_config_ok} -eq 0 ]]; then
                            # This should not happen due to verification_passed logic, but handle it anyway
                            log "[STEP 12] ${AIO_VM} data disk(${DATA_LV}) attached as vdb (live) - persistence pending"
                            log "[STEP 12] Status: Attached (live), persistence pending"
                            log "[STEP 12] Final verification: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                            log "[WARN] Config verification failed but live attachment is working. Persistence may not be saved."
                            log "[WARN] Please manually verify with: virsh dumpxml ${AIO_VM} --inactive | grep vdb"
                            data_disk_attached=1
                            data_disk_status="Attached (live), persistence pending"
                        else
                            log "[ERROR] ${AIO_VM} data disk(${DATA_LV}) attach failed after all attempts"
                            log "[ERROR] Final verification: config_ok=${final_config_ok}, live_ok=${final_live_ok}"
                            log "[DEBUG] VM XML vdb section (config):"
                            virsh dumpxml "${AIO_VM}" --inactive 2>/dev/null | grep -A 10 "target dev='vdb'" | while read -r line; do
                                log "[DEBUG]   ${line}"
                            done
                            data_disk_status="Attach failed"
                        fi
                    fi
                fi
            fi
        else
            log "[STEP 12] ${AIO_VM} VM not found → skipping AIO data disk attach"
            data_disk_status="VM not found"
        fi
    else
        log "[STEP 12] ${DATA_LV} does not exist, skipping AIO data disk attach"
        data_disk_status="LV does not exist"
    fi
    
    # Create summary for AIO VM (after data disk attachment)
    # Get actual CPU affinity setting for display (similar to Sensor VM)
    local actual_cpuset_aio_display=""
    if [[ "${numa_nodes}" -gt 1 ]]; then
        # First try to use AIO_CPUSET if available
        actual_cpuset_aio_display="${AIO_CPUSET:-}"
        if [[ -z "${actual_cpuset_aio_display}" ]]; then
            # Try to get from NUMA node0 CPU list
            if command -v lscpu >/dev/null 2>&1; then
                local node0_cpus
                node0_cpus=$(lscpu | grep "NUMA node0 CPU(s):" | sed 's/NUMA node0 CPU(s)://' | tr -d '[:space:]')
                if [[ -n "${node0_cpus}" ]]; then
                    actual_cpuset_aio_display="${node0_cpus}"
                fi
            fi
        fi
        if [[ -z "${actual_cpuset_aio_display}" ]]; then
            # Last resort: try to get from virsh if VM exists
            if virsh dominfo "${AIO_VM}" >/dev/null 2>&1; then
                # Try multiple parsing methods for virsh emulatorpin output
                local emulatorpin_output
                emulatorpin_output=$(virsh emulatorpin "${AIO_VM}" --config 2>/dev/null || echo "")
                if [[ -n "${emulatorpin_output}" ]]; then
                    # Method 1: grep for "emulator: CPU Affinity" and extract after colon
                    actual_cpuset_aio_display=$(echo "${emulatorpin_output}" | grep -i "emulator.*CPU.*Affinity" | sed -E 's/.*[Cc][Pp][Uu].*[Aa]ffinity[^:]*:\s*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
                    # Method 2: if still empty, try to extract from any line with numbers
                    if [[ -z "${actual_cpuset_aio_display}" ]]; then
                        actual_cpuset_aio_display=$(echo "${emulatorpin_output}" | grep -oE '[0-9]+([,-][0-9]+)*' | head -1 || echo "")
                    fi
                fi
            fi
        fi
    fi
    
    local aio_result_file="/tmp/step12_result_aio.txt"
    {
        echo "STEP 12 - CPU Affinity & Data Disk Verification (${AIO_VM})"
        echo "═══════════════════════════════════════════════════════════"
        if [[ "${_DRY}" -eq 1 ]]; then
            echo "🔍 DRY-RUN MODE: No actual changes were made"
            echo
            echo "📊 SIMULATED STATUS:"
            echo "  • VM status: Would be checked"
            echo "  • CPU affinity: Would be applied to NUMA0"
            echo "  • Data disk: Would be attached as vdb"
        else
            echo "✅ EXECUTION COMPLETED"
            echo
            echo "📊 CONFIGURATION STATUS:"
            local aio_state
            aio_state=$(virsh dominfo "${AIO_VM}" 2>/dev/null | grep "^State:" | awk '{print $2}' || echo "unknown")
            echo "  • VM status: ${aio_state}"
            echo
            echo "⚙️  CPU AFFINITY:"
            if [[ "${numa_nodes}" -gt 1 ]]; then
                if [[ -n "${actual_cpuset_aio_display}" ]]; then
                    echo "  • CPU set: ${actual_cpuset_aio_display}"
                    echo "  • NUMA node: NUMA0"
                    echo "    ✅ CPU affinity configured successfully"
                else
                    echo "  • ⚠️  CPU affinity not configured (NUMA0 CPU detection failed)"
                fi
            fi
            echo
            echo "💾 DATA DISK:"
            if [[ -e "${DATA_LV}" ]]; then
                echo "  • Data disk: ${DATA_LV}"
                echo "  • Attached as: vdb"
                if [[ "${data_disk_attached}" -eq 1 ]]; then
                    if [[ "${data_disk_status}" == "Already attached" ]]; then
                        echo "    ✅ Data disk already attached (skipped)"
                    elif [[ "${data_disk_status}" == "Attached successfully" ]]; then
                        echo "    ✅ Data disk attached successfully"
                    elif [[ "${data_disk_status}" == "Would be attached" ]]; then
                        echo "    ✅ Data disk would be attached (DRY-RUN)"
                    else
                        echo "    ⚠️  Status: ${data_disk_status}"
                    fi
                else
                    echo "  • Status: ${data_disk_status}"
                    if [[ "${data_disk_status}" == "Attach failed" ]]; then
                        echo "    ❌ Data disk attachment failed"
                    elif [[ "${data_disk_status}" == "Attach verification failed" ]]; then
                        echo "    ⚠️  Data disk attach command succeeded but verification failed"
                        echo "    💡 Please verify manually: virsh dumpxml ${AIO_VM} | grep -A 5 'target dev=\"vdb\"'"
                    elif [[ "${data_disk_status}" == "VM not found" ]]; then
                        echo "    ⚠️  Data disk attachment skipped (VM not found)"
                    elif [[ "${data_disk_status}" == "LV does not exist" ]]; then
                        echo "    ⚠️  Data disk LV does not exist"
                    else
                        echo "    ⚠️  Data disk attachment skipped"
                    fi
                fi
            else
                echo "  • Data disk: ${DATA_LV}"
                echo "  • Status: ${data_disk_status}"
                echo "    ⚠️  Data disk LV does not exist"
            fi
        fi
        echo
        echo "⚠️  IMPORTANT:"
        echo "  • CPU affinity requires multiple NUMA nodes"
        echo "  • VM must be stopped before CPU affinity configuration"
        echo "  • Verify CPU affinity with: virsh vcpupin ${AIO_VM}"
        echo "  • Verify data disk with: virsh dumpxml ${AIO_VM} | grep -A 5 'target dev=\"vdb\"'"
    } > "${aio_result_file}"
    
    ###########################################################################
    # Combine all results (Sensor VMs + AIO VM) into a single message box
    ###########################################################################
    local combined_result_file="/tmp/step12_combined_result.txt"
    {
        echo "STEP 12 - PCI Passthrough / CPU Affinity Configuration Result"
        echo "════════════════════════════════════════════════════════════════════════"
        echo
        echo "This step automatically configured PCI passthrough and CPU affinity for"
        echo "all VMs (Sensor and AIO)."
        echo
        echo "════════════════════════════════════════════════════════════════════════"
        echo
        
        # Display Sensor VM results
        if [[ ${#sensor_result_files[@]} -gt 0 ]]; then
            echo "📡 SENSOR VM RESULTS:"
            echo "────────────────────────────────────────────────────────────────────"
            for result_file in "${sensor_result_files[@]}"; do
                if [[ -f "${result_file}" ]]; then
                    # Skip the header line (title) and separator line, show content from line 3
                    tail -n +3 "${result_file}"
                    echo
                fi
            done
        else
            echo "📡 SENSOR VM RESULTS:"
            echo "────────────────────────────────────────────────────────────────────"
            echo "  • No Sensor VMs processed"
            echo
        fi
        
        echo "════════════════════════════════════════════════════════════════════════"
        echo
        
        # Display AIO VM results
        echo "🖥️  AIO VM RESULTS:"
        echo "────────────────────────────────────────────────────────────────────"
        if [[ -f "${aio_result_file}" ]]; then
            # Skip the header line (title) and separator line, show content from line 3
            tail -n +3 "${aio_result_file}"
        else
            echo "  • AIO VM results not available"
        fi
        echo
        echo "════════════════════════════════════════════════════════════════════════"
        echo
        echo "✅ STEP 12 completed automatically for all VMs"
        echo
        echo "⚠️  IMPORTANT NOTES:"
        echo "  • PCI passthrough requires IOMMU to be enabled (configured in STEP 05)"
        echo "  • VM must be stopped before PCI passthrough configuration"
        echo "  • CPU affinity requires multiple NUMA nodes"
        echo "  • Verify PCI passthrough: virsh dumpxml <vm_name> | grep hostdev"
        echo "  • Verify CPU affinity: virsh vcpupin <vm_name>"
    } > "${combined_result_file}"
    
    # Display combined result in a single message box
    show_textbox "STEP 12 - PCI Passthrough / CPU Affinity Result (All VMs)" "${combined_result_file}"

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END: ${STEP_ID} - 12. PCI Passthrough / CPU Affinity (Sensor + AIO) configuration and verify ====="
    log "[STEP 12] Sensor PCI passthrough and CPU affinity configuration completed successfully."
    log "[STEP 12] AIO VM CPU affinity configuration completed successfully."
}

###############################################################################
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

    if ! whiptail_yesno "STEP 13 Execution Confirmation" "Install DP Appliance CLI package (dp_cli) on host and apply to stellar user.\n\n(Will download latest version from GitHub: https://github.com/RickLee-kr/Stellar-appliance-cli)\n\nDo you want to continue?" 15 85
    then
        log "User canceled STEP 13 execution."
        return 0
    fi

    # 0) Prepare error log file
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Prepare error log file: ${ERRLOG}"
    else
        mkdir -p /var/log/aella || true
        : > "${ERRLOG}" || true
        chmod 644 "${ERRLOG}" || true
    fi

    # 0-1) Install required packages first (before download/extraction)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Installing required packages (wget/curl, unzip, python3-pip, python3-venv)..."
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] apt-get update -y"
        log "[DRY-RUN] apt-get install -y python3-pip python3-venv wget curl unzip"
    else
        if ! apt-get update -y >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: apt-get update failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        fi
        if ! apt-get install -y python3-pip python3-venv wget curl unzip >>"${ERRLOG}" 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: Failed to install required packages" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG} for details." | tee -a "${ERRLOG}"
            return 1
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] Required packages installed successfully"
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
        log "[DRY-RUN] Create/overwrite /usr/local/bin/aella_cli as venv wrapper"
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
        log "[DRY-RUN] Create /usr/bin/aella_cli wrapper script."
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
        log "[DRY-RUN] Adding /usr/bin/aella_cli to /etc/shells (if not exists)"
    else
        if ! grep -qx "/usr/bin/aella_cli" /etc/shells 2>/dev/null; then
            echo "/usr/bin/aella_cli" >> /etc/shells
        fi
    fi

    # 7) stellar sudo NOPASSWD
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] /etc/sudoers.d/stellar create: 'stellar ALL=(ALL) NOPASSWD: ALL'"
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
        log "[WARN] User 'stellar' not found, skip adding to syslog group."
    fi

    # 9) Change login shell
    if id stellar >/dev/null 2>&1; then
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] Change stellar login shell to /usr/bin/aella_cli."
        else
            chsh -s /usr/bin/aella_cli stellar || true
        fi
    fi

    # 10) Change /var/log/aella owner
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Create /var/log/aella directory / change owner (stellar)"
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
      acps_password_display="(Not Set)"
    fi

    local msg
    msg="Current Configuration\n\n"
    msg+="DRY_RUN        : ${DRY_RUN}\n"
    msg+="DP_VERSION     : ${DP_VERSION:-<Not Set>}\n"
    msg+="SENSOR_VERSION : ${SENSOR_VERSION:-<Not Set>}\n"
    msg+="ACPS_USER      : ${ACPS_USERNAME:-<Not Set>}\n"
    msg+="ACPS_PASSWORD  : ${acps_password_display}\n"
    msg+="ACPS_URL       : ${ACPS_BASE_URL:-<Not Set>}\n"
    msg+="AUTO_REBOOT    : ${ENABLE_AUTO_REBOOT}\n"
    msg+="SPAN_MODE      : ${SPAN_ATTACH_MODE}\n"

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
                      "2" "Set DP_VERSION" \
                      "3" "Set Sensor Version" \
                      "4" "Set ACPS Account/Password" \
                      "5" "Set ACPS URL" \
                      "6" "Set Auto Reboot (${ENABLE_AUTO_REBOOT})" \
                      "7" "Set SPAN Attachment Mode (${SPAN_ATTACH_MODE})" \
                      "8" "Go Back" \
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
      "2")
        local new_dp_version
        # Temporarily disable set -e to handle cancel gracefully
        set +e
        new_dp_version=$(whiptail_inputbox "DP Version Configuration" "Enter DP version (e.g., 6.2.0):" "${DP_VERSION:-}")
        local ver_rc=$?
        set -e
        if [[ ${ver_rc} -ne 0 ]] || [[ -z "${new_dp_version}" ]]; then
          continue
        fi
        if [[ -n "${new_dp_version}" ]]; then
          save_config_var "DP_VERSION" "${new_dp_version}"
          whiptail_msgbox "DP_VERSION Configuration" "DP_VERSION has been set to ${new_dp_version}." 8 60
        fi
        ;;
      "3")
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
      "4")
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
      "5")
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
      "6")
        local new_auto_reboot
        if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
          new_auto_reboot=0
        else
          new_auto_reboot=1
        fi
        save_config_var "ENABLE_AUTO_REBOOT" "${new_auto_reboot}"
        whiptail_msgbox "Auto Reboot Configuration" "Auto Reboot has been set to ${new_auto_reboot}."
        ;;
      "7")
        whiptail_msgbox "SPAN Attachment Mode Configuration" "SPAN attachment mode is fixed to 'pci' (PCI passthrough only).\nBridge mode is not supported in this installer." 10 70
        ;;
      "8")
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
      local status="[wait]"
      local step_num=$(printf "%02d" $((i+1)))

      if [[ "${LAST_COMPLETED_STEP}" == "${step_id}" ]]; then
        status="[✓]"
      elif [[ -n "${LAST_COMPLETED_STEP}" ]]; then
        local last_idx
        last_idx=$(get_step_index_by_id "${LAST_COMPLETED_STEP}")
        if [[ ${last_idx} -ge 0 && ${i} -le ${last_idx} ]]; then
          status="[✓]"
        fi
      fi

      # Extract step name without number prefix for cleaner display
      local display_name="${step_name#*. }"
      
      # Use step number as tag (instead of step_id) for cleaner display
      # Display without step number prefix
      menu_items+=("${step_num}" "${display_name} ${status}")
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
    choice=$(whiptail --title "XDR AIO & Sensor Installer - Step Selection" \
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


#######################################
# Automatic continue execution menu
#######################################

menu_auto_continue_from_state() {
  load_state

  local next_idx
  next_idx=$(get_next_step_index)

  if [[ ${next_idx} -ge ${NUM_STEPS} ]]; then
    whiptail_msgbox "XDR AIO & Sensor Installer - Automatic Execution" "All steps have been completed!" 8 60
    return
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"
  local auto_exec_msg="Do you want to automatically execute from next step?\n\nStart step: ${next_step_name}\n\nIf it fails in the middle, it will stop at that step."
  if ! whiptail_yesno "XDR AIO & Sensor Installer - Automatic Execution" "${auto_exec_msg}" 12 80
  then
    return
  fi

  for ((i=next_idx; i<NUM_STEPS; i++)); do
    if ! run_step "${i}"; then
      whiptail_msgbox "Automatic execution stopped" "An error occurred during STEP ${STEP_IDS[$i]} execution.\n\nAutomatic execution stopped." 10 70
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
    choice=$(whiptail --title "XDR AIO & Sensor Installer Main Menu" \
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
          show_textbox "XDR AIO & Sensor Installer Log" "${LOG_FILE}"
        else
          whiptail_msgbox "Log Not Found" "Log file does not exist yet." 8 60
        fi
        ;;
      7)
        if whiptail_yesno "Exit Confirmation" "Do you want to exit XDR AIO & Sensor Installer?" 8 60; then
          log "XDR AIO & Sensor Installer exit"
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
  local net_mode="${SENSOR_NET_MODE:-nat}"

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
  # NAT mode: check for virbr0 (libvirt default network)
  if ip link show virbr0 >/dev/null 2>&1; then
    ok_msgs+=("virbr0 bridge exists (NAT mode)")
  else
    warn_msgs+=("virbr0 bridge does not exist (NAT mode).")
    warn_msgs+=("  → ACTION: Re-run STEP 03 (NIC Name/ifupdown Switch and Network Configuration)")
    warn_msgs+=("  → CHECK: Verify libvirt network with 'virsh net-list --all'")
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

  if [[ -f /etc/libvirt/hooks/network ]]; then
    ok_msgs+=("/etc/libvirt/hooks/network script exists (NAT mode)")
  else
    warn_msgs+=("/etc/libvirt/hooks/network script does not exist (NAT mode).")
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

  # Check lv_sensor_root_mds LV
  if lvs ubuntu-vg/lv_sensor_root_mds >/dev/null 2>&1; then
    ok_msgs+=("lv_sensor_root_mds LV exists")
  else
    warn_msgs+=("lv_sensor_root_mds LV not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify with 'sudo lvs ubuntu-vg/lv_sensor_root_mds'")
  fi

  # Check mount point
  if mountpoint -q /var/lib/libvirt/images/mds 2>/dev/null; then
    ok_msgs+=("/var/lib/libvirt/images/mds mount point exists")
  else
    warn_msgs+=("/var/lib/libvirt/images/mds mount point does not exist.")
    warn_msgs+=("  → ACTION: Re-run STEP 07 (Sensor LV Creation + Image/Script Download)")
    warn_msgs+=("  → CHECK: Verify mount with 'mountpoint /var/lib/libvirt/images/mds'")
  fi

  ###############################
  # STEP 08: AIO VM Deployment
  ###############################
  if virsh list --all 2>/dev/null | grep -qE '\saio\s'; then
    ok_msgs+=("AIO VM (aio) exists")
  else
    warn_msgs+=("AIO VM (aio) not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 09 (AIO VM Deployment)")
    warn_msgs+=("  → CHECK: Verify VMs with 'virsh list --all'")
  fi

  ###############################
  # STEP 11: Sensor VM Deployment
  ###############################
  if virsh list --all 2>/dev/null | grep -qE '\smds\s'; then
    ok_msgs+=("Sensor VM (mds) exists")
  else
    warn_msgs+=("Sensor VM (mds) not found.")
    warn_msgs+=("  → ACTION: Re-run STEP 11 (Sensor VM Deployment)")
    warn_msgs+=("  → CHECK: Verify VMs with 'virsh list --all'")
  fi

  ###############################
  # STEP 12: PCI Passthrough / CPU Affinity
  ###############################
  # Check AIO VM CPU affinity (cputune)
  if virsh dumpxml aio 2>/dev/null | grep -q '<cputune>'; then
    # Get actual CPU affinity for display
    local aio_cpuset
    aio_cpuset=$(virsh emulatorpin aio --config 2>/dev/null | grep "emulator: CPU Affinity" | sed 's/.*: //' || echo "")
    if [[ -n "${aio_cpuset}" ]]; then
      ok_msgs+=("aio VM has CPU pinning (cputune) configuration (cpuset: ${aio_cpuset})")
    else
      ok_msgs+=("aio VM has CPU pinning (cputune) configuration")
    fi
  else
    warn_msgs+=("aio VM XML does not have CPU pinning (cputune) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 12 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: NUMA0-based vCPU placement may not be applied without this")
  fi

  # Check Sensor VM PCI passthrough
  if virsh dumpxml mds 2>/dev/null | grep -q '<hostdev'; then
    ok_msgs+=("mds VM has PCI passthrough (hostdev) configuration")
  else
    warn_msgs+=("mds VM XML does not have PCI passthrough (hostdev) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 12 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: SPAN NIC passthrough may not be applied without this")
  fi

  # Check Sensor VM CPU pinning (cputune)
  if virsh dumpxml mds 2>/dev/null | grep -q '<cputune>'; then
    # Get actual CPU affinity for display
    local mds_cpuset
    mds_cpuset=$(virsh emulatorpin mds --config 2>/dev/null | grep "emulator: CPU Affinity" | sed 's/.*: //' || echo "")
    if [[ -n "${mds_cpuset}" ]]; then
      ok_msgs+=("mds VM has CPU pinning (cputune) configuration (cpuset: ${mds_cpuset})")
    else
      ok_msgs+=("mds VM has CPU pinning (cputune) configuration")
    fi
  else
    warn_msgs+=("mds VM XML does not have CPU pinning (cputune) configuration.")
    warn_msgs+=("  → ACTION: Re-run STEP 12 (PCI Passthrough / CPU Affinity)")
    warn_msgs+=("  → NOTE: NUMA1-based vCPU placement may not be applied without this")
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
    echo " XDR AIO & Sensor Installer Full Configuration Verification"
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
    # 4. AIO & Sensor VM / Storage verify
    ##################################################
    echo "## 4. AIO & Sensor VM / Storage verify"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all execution failed"
    echo

    echo "\$ lvs"
    lvs 2>&1 || echo "[WARN] LVM information query failed"
    echo

    echo "\$ df -h /stellar/aio"
    df -h /stellar/aio 2>&1 || echo "[INFO] /stellar/aio mount point not found."
    echo

    echo "\$ df -h /var/lib/libvirt/images/mds"
    df -h /var/lib/libvirt/images/mds 2>&1 || echo "[INFO] /var/lib/libvirt/images/mds mount point not found."
    echo
    echo

    echo "\$ ls -la /var/lib/libvirt/images/"
    ls -la /var/lib/libvirt/images/ 2>&1 || echo "[INFO] libvirt image directory not found."
    echo

    echo "## 4.1. Sensor VM CPU Affinity Verification"
    echo
    if virsh dominfo mds >/dev/null 2>&1; then
      echo "\$ virsh emulatorpin mds --config"
      virsh emulatorpin mds --config 2>&1 || echo "[WARN] Failed to get Sensor VM emulator pinning"
      echo

      echo "\$ virsh vcpupin mds --config"
      virsh vcpupin mds --config 2>&1 || echo "[WARN] Failed to get Sensor VM vCPU pinning"
      echo

      echo "\$ virsh dumpxml mds | grep -A 10 '<cputune>'"
      virsh dumpxml mds 2>/dev/null | grep -A 10 '<cputune>' || echo "[INFO] Sensor VM does not have cputune configuration"
      echo
    else
      echo "[INFO] Sensor VM (mds) not found"
      echo
    fi

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
    show_paged "Full Configuration Validation Results (Detailed Log)" "${tmp_file}" "no-clear"
  fi

  # Clean up temporary files
  rm -f "${summary_file}"
  rm -f "${tmp_file}"
}

#######################################
# Script usage guide
#######################################

show_usage_help() {
  local msg
  msg=$'═══════════════════════════════════════════════════════════════
        ⭐ Stellar Cyber XDR AIO & Sensor – KVM Installer Usage Guide ⭐
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
│      • Network mode: NAT only (bridge mode not supported)      │
│      • SPAN_ATTACH_MODE: pci only (bridge mode not supported) │
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
   STEP 07 → LVM Storage Configuration (AIO)
   STEP 08 → DP Download (AIO)
   STEP 09 → AIO VM Deployment
   STEP 10 → Sensor LV Creation + Image/Script Download
   STEP 11 → Sensor VM (mds) Deployment
   STEP 12 → PCI Passthrough + CPU Affinity (Sensor, SPAN NIC)
   STEP 13 → DP Appliance CLI Installation

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
• AIO VM Redeployment:
  → Menu 2 → STEP 09 (AIO VM deployment)
  → VM resources (vCPU, memory) are automatically calculated

• Sensor VM Redeployment:
  → Menu 2 → STEP 11 (Sensor VM deployment)
  → VM resources (vCPU, memory) are automatically calculated

• Update AIO Image:
  → Menu 2 → STEP 08 (DP Download for AIO)
  → New image will be downloaded and deployed

• Update Sensor Image:
  → Menu 2 → STEP 10 (Sensor LV + image download)
  → New image will be downloaded and deployed

• Network Configuration Change:
  → Menu 2 → STEP 01 (Hardware selection) → STEP 03 (Network)
  → Network mode changes require re-running from STEP 01

• SPAN NIC Reconfiguration:
  → Menu 2 → STEP 01 (SPAN NIC selection) → STEP 12 (PCI passthrough)
  → SPAN attachment mode can be changed in menu 3

• Change Network Mode (NAT only):
  → Menu 3 → Update SENSOR_NET_MODE (NAT mode only)
  → Menu 2 → STEP 01 → STEP 11 (to apply new network mode)


═══════════════════════════════════════════════════════════════
🔍 **Scenario 4: Validation and Troubleshooting**
═══════════════════════════════════════════════════════════════

Full System Validation:
────────────────────────────────────────────────────────────
• Select menu 4 (Full Configuration Validation)

Validation Checks:
────────────────────────────────────────────────────────────
✓ KVM/Libvirt installation and service status
✓ AIO VM (aio) deployment and running status
✓ Sensor VM (mds) deployment and running status
✓ Network configuration (ifupdown conversion, NIC naming, NAT mode)
✓ SPAN PCI Passthrough connection status (mds only)
✓ LVM storage configuration (AIO: vg_aio, Sensor: ubuntu-vg)
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
    • PCI Passthrough mode recommended for best performance

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
• Network mode: NAT only (bridge mode not supported)
  - NAT: virbr0 NAT network based
• Changes require re-running STEP 01 and STEP 03

SPAN Attachment Mode:
────────────────────────────────────────────────────────────
• SPAN_ATTACH_MODE: pci only (bridge mode not supported)
  - PCI: Direct PCI passthrough (best performance)
• PCI mode requires IOMMU enabled in BIOS
• Changes require re-running STEP 01 and STEP 12

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
• Network mode: NAT only (bridge mode not supported in this installer)
• PCI passthrough for SPAN provides best performance
• Ensure IOMMU is enabled in BIOS for PCI passthrough
• Monitor disk space in ubuntu-vg throughout installation
• Save configuration after menu 3 changes
• VM resources are auto-calculated - no manual configuration needed

═══════════════════════════════════════════════════════════════'

  # Store temporary file content and display with show_textbox
  local tmp_help_file="/tmp/xdr_sensor_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR AIO & Sensor Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}

# Main execution
main_menu