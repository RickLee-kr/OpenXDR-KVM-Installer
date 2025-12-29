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
  BASE_DIR="/opt/xdr-installer"  # Use /opt when running as root
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
  "01. Hardware / NIC / CPU / Memory / SPAN NIC Selection"
  "02. HWE Kernel Installation"
  "03. NIC Name/ifupdown Switch and Network Configuration"
  "04. KVM / Libvirt Installation and Basic Configuration"
  "05. Kernel Parameters / KSM / Swap Tuning"
  "06. libvirt hooks Installation"
  "07. Sensor LV Creation + Image/Script Download"
  "08. Sensor VM Deployment"
  "09. PCI Passthrough / CPU Affinity (Sensor)"
  "10. Install DP Appliance CLI package"
)

NUM_STEPS=${#STEP_IDS[@]}


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
  : "${ACPS_USERNAME:=AellaMeta}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=WroTQfm/W6x10}"

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
  if ! whiptail --title "XDR Installer - ${step_id}" \
                --yesno "${step_name}\n\nDo you want to execute this step?" 12 70
  then
    # User cancellation is considered "normal flow" (not an error)
    log "User cancelled execution of STEP ${step_id}."
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
      log_info="\n\nCheck detailed log: tail -f ${LOG_FILE}"
    fi
    
    whiptail --title "STEP Failed - ${step_id}" \
             --msgbox "An error occurred while executing STEP ${step_id} (${step_name}).\n\nPlease check the log and re-run the STEP if necessary.\nThe script can continue to be used.${log_info}" 16 80
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
    log "User cancelled sensor vCPU configuration."
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
    log "User cancelled sensor memory configuration."
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
    lv_size_gb=$(whiptail --title "STEP 01 - Sensor storage Size Configuration" \
                         --inputbox "Sensor VMfor storage Size(GB) please enter.\n\nubuntu-vg Total Size: ${ubuntu_vg_total_size}\nSystem use: ${ubuntu_lv_size}\nuse available: approximately ${available_gb}GB\n\nInstallation Location: ubuntu-vg (OpenXDR Method)\nMinimum Size: 80GB\nDefault: 500GB\n\nSize(GB):" \
                         16 65 "100" \
                         3>&1 1>&2 2>&3) || {
      log "User Sensor storage Size Configuration cancelled."
      return 1
    }
      
      # numeric format Verification
      if ! [[ "${lv_size_gb}" =~ ^[0-9]+$ ]]; then
        whiptail --title "Input Error" --msgbox "correct  please enter.\nInput value: ${lv_size_gb}" 8 50
        continue
      fi
      
      # Minimum Size Verification (80GB)
      if [[ "${lv_size_gb}" -lt 80 ]]; then
        whiptail --title "Size insufficient" --msgbox "Minimum 80GB must be at least.\nInput value: ${lv_size_gb}GB" 8 50
        continue
      fi
      
      # valid thisif exit loop
      break
    done
    
    log "Configurationdone LV Location: ${lv_location}"
    log "Configurationdone LV Size: ${lv_size_gb}GB"
    
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
    whiptail --title "STEP 01 - NIC feelnot Failed" \
             --msgbox "use available NIC could not find.\n\nip link Result check and script must be modified." 12 70
    log "NIC candidate None. ip link Result check required."
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
    log "[STEP 01] Bridge Mode - HOST NICand DATA NIC each selection."
    
    # HOST NIC Selection
    local host_nic
    host_nic=$(whiptail --title "STEP 01 - HOST NIC Selection (Bridge Mode)" \
                       --menu "KVM s for access NIC please select (Current SSH connectionfor).\nCurrent Configuration: ${HOST_NIC:-<None>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User HOST NIC selection cancelled."
      return 1
    }

    log "Selectiondone HOST NIC: ${host_nic}"
    HOST_NIC="${host_nic}"
    save_config_var "HOST_NIC" "${HOST_NIC}"

    # DATA NIC Selection  
    local data_nic
    data_nic=$(whiptail --title "STEP 01 - Data NIC Selection (Bridge Mode)" \
                       --menu "Sensor VM for management/data NIC please select.\nCurrent Configuration: ${DATA_NIC:-<None>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
      log "User Data NIC selection cancelled."
      return 1
    }

    log "Selectiondone Data NIC: ${data_nic}"
    DATA_NIC="${data_nic}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: NAT uplink NIC 1unitonly Selection
    log "[STEP 01] NAT Mode - NAT uplink NIC 1unitonly Selectiondo."
    
    local nat_nic
    nat_nic=$(whiptail --title "STEP 01 - NAT uplink NIC Selection (NAT Mode)" \
                      --menu "NAT Network uplink NIC please select.\nthis NICis 'mgt' renamed to for external connection will be used.\nSensor VM virbr0 NAT bridge will be connected.\nCurrent Configuration: ${HOST_NIC:-<None>}" \
                      20 90 10 \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
      log "User NAT uplink NIC selection cancelled."
      return 1
    }

    log "Selectiondone NAT uplink NIC: ${nat_nic}"
    HOST_NIC="${nat_nic}"  # HOST_NIC variable NAT uplink NIC store
    DATA_NIC=""  # NAT Modefromis DATA NIC not used
    save_config_var "HOST_NIC" "${HOST_NIC}"
    save_config_var "DATA_NIC" "${DATA_NIC}"
    
  else
    log "ERROR: unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail --title "Configuration Error" --msgbox "unknown Sensor Network Modeis: ${net_mode}\n\nin environment configuration correct Mode(bridge or nat) please select." 12 70
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

    # Existing Selected SPAN_NIC existallif ON, if OFF
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
                                --checklist "Sensor SPAN  canfor NIC please select.\n(Minimum 1unit this Selection Required)\n\nCurrent Selection: ${SPAN_NICS:-<None>}" \
                                20 80 10 \
                                "${span_nic_list[@]}" \
                                3>&1 1>&2 2>&3) || {
    log "User SPAN NIC selection cancelled."
    return 1
  }

  # whiptail Output "nic1" "nic2"  ->  remove
  selected_span_nics=$(echo "${selected_span_nics}" | tr -d '"')

  if [[ -z "${selected_span_nics}" ]]; then
    whiptail --title "" \
             --msgbox "SPAN NIC Selectionbecomenot all.\nMinimum 1unit this SPAN NIC Requireddo." 10 70
    log "SPAN NIC Selectionbecomenot ."
    return 1
  fi

  log "Selected SPAN NICs: ${selected_span_nics}"
  SPAN_NICS="${selected_span_nics}"
  save_config_var "SPAN_NICS" "${SPAN_NICS}"

  ########################
  # 6) SPAN NIC PF PCI address can (PCI passthrough beforefor)
  ########################
  log "[STEP 01] SR-IOV Based VF Creation usedonot all (PF PCI  will do Mode)."
  log "[STEP 01] SPAN NIC  PCI address(PF) cando."

  local span_pci_list=""

  if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
    # PCI passthrough Mode: Physical Function (PF) PCI address  use
    for nic in ${SPAN_NICS}; do
      pci_addr=$(readlink -f "/sys/class/net/${nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')

      if [[ -z "${pci_addr}" ]]; then
        log "WARNING: ${nic} PCI address  can does not exist."
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

  # NOTE: to VFfor name  existnotonly,
  # Currentis SPAN NIC PF PCI address  notdo.
  # can store
  SENSOR_SPAN_VF_PCIS="${span_pci_list# }"  #   remove
  save_config_var "SENSOR_SPAN_VF_PCIS" "${SENSOR_SPAN_VF_PCIS}"
  log "candone SPAN NIC PCI address : ${SENSOR_SPAN_VF_PCIS}"
  
  # SPAN NIC sand connection Mode store
  SPAN_NIC_LIST="${SPAN_NICS}"  # SPAN_NICS   use
  save_config_var "SPAN_NIC_LIST" "${SPAN_NIC_LIST}"
  save_config_var "SPAN_ATTACH_MODE" "${SPAN_ATTACH_MODE}"
  log "SPAN NIC s storedone: ${SPAN_NIC_LIST}"
  log "SPAN connection Mode: ${SPAN_ATTACH_MODE} (pci=PF PCI passthrough)"

  ########################
  # 7) Summary display (Network ModePer all whennot)
  ########################
  local summary
  local pci_label="SPAN NIC PCIs (PF Passthrough)"
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    pci_label="SPAN interfacethiss (Bridge)"
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
- Data NIC         : N/A (NAT Modefromis virbr0 use)
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

  ### change 5 (Selection): when   from    store
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  #  STEPthis Successto to from save_state  Status storedone
}


step_02_hwe_kernel() {
  log "[STEP 02] HWE kernel Installation"
  load_config

  #######################################
  # 0) Ubuntu before  HWE package correct
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
      log "[WARN] notdonot is Ubuntu before: ${ubuntu_version}. default kernel use do."
      pkg_name="linux-generic"
      ;;
  esac
  
  log "[STEP 02] Ubuntu ${ubuntu_version} feelnotdone, HWE package: ${pkg_name}"
  local tmp_status="/tmp/xdr_step02_status.txt"

  #######################################
  # 1) Current kernel / package Status Check
  #######################################
  local cur_kernel hwe_installed
  cur_kernel=$(uname -r 2>/dev/null || echo "unknown")
  if dpkg -l | grep -q "^ii  ${pkg_name}[[:space:]]"; then
    hwe_installed="yes"
  else
    hwe_installed="no"
  fi

  {
    echo "Current kernel before(uname -r): ${cur_kernel}"
    echo
    echo "${pkg_name} Installation Status: ${hwe_installed}"
    echo
    echo " STEP Next  candodo:"
    echo "  1) apt update"
    echo "  2) apt full-upgrade -y"
    echo "  3) ${pkg_name} Installation (Already Installationbecome existtoif skip)"
    echo
    echo " HWE kernel Next s Reboot when Applywill be done."
    echo " scriptis STEP 05 (kernel tuning) Completed after,"
    echo "s  only Autoto Rebootdo Configurationbecome exists."
  } > "${tmp_status}"


  # ... cur_kernel, hwe_installed  after, unit textbox   add ...

  if [[ "${hwe_installed}" == "yes" ]]; then
    if ! whiptail --title "STEP 02 - Already HWE kernel Installationdone" \
                  --yesno "linux-generic-hwe-24.04 package Already Installationdone Statusis...." 18 80
    then
      log "User 'Already Installationdone' to STEP 02 All skipdo."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE kernel Installation unit" "${tmp_status}"

  if ! whiptail --title "STEP 02 Execution Check" \
                 --yesno "  truedodowhenwill you?\n\n(: Continue / : Cancelled)" 12 70
  then
    log "User STEP 02 Execution Cancelleddid."
    return 0
  fi


  #######################################
  # 1) apt update / full-upgrade
  #######################################
  log "[STEP 02] apt update / full-upgrade Execution"
  
  echo "=== package  this during ==="
  log "package storefrom Latest package  is duringis..."
  run_cmd "sudo apt update"
  
  echo "=== System All this during (whenthis  can exists) ==="
  log "Installationdone All package Latest beforeto thisdois duringis..."
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y"
  echo "=== System this Completed ==="

  #######################################
  # 1-1) ifupdown / net-tools not Installation (STEP 03from Required)
  #######################################
  echo "=== Network   Installation during ==="
  log "[STEP 02] ifupdown, net-tools not Installation"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ifupdown net-tools"

  #######################################
  # 2) HWE kernel package Installation
  #######################################
  if [[ "${hwe_installed}" == "yes" ]]; then
    log "[STEP 02] ${pkg_name} package Already Installationbecome exist -> Installation step skip"
  else
    echo "=== HWE kernel package Installation during (whenthis  can exists) ==="
    log "[STEP 02] ${pkg_name} package Installation during..."
    log "Hardware not s(HWE) kernel Installationdo Latest Hardware  do."
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg_name}"
    echo "=== HWE kernel package Installation Completed ==="
  fi

  #######################################
  # 3) Installation after Status Summary
  #######################################
  local new_kernel hwe_now
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # DRY-RUN Modefromis  Installation donot to uname -r / Installation Status  Existing  use
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
  else
    #  Execution Modefromis Current kernel before HWE package Installation  allwhen Check
    new_kernel=$(uname -r 2>/dev/null || echo "unknown")
    if dpkg -l | grep -q "^ii  ${pkg_name}[[:space:]]"; then
      hwe_now="yes"
    else
      hwe_now="no"
    fi
  fi

  {
    echo "STEP 02 Execution Result Summary"
    echo "----------------------"
    echo "Previous kernel(uname -r): ${cur_kernel}"
    echo "Current kernel(uname -r): ${new_kernel}"
    echo
    echo "${pkg_name} Installation  (not ): ${hwe_now}"
    echo
    echo "*  HWE kernel 'Next s Reboot' when Applywill be done."
    echo "   (not uname -r Output Reboot beforethis not  can exists.)"
    echo
    echo "*  scriptis STEP 05 (kernel tuning) Completed when,"
    echo "   AUTO_REBOOT_AFTER_STEP_ID Configuration  s  only Autoto Rebootdo."
  } > "${tmp_status}"


  show_textbox "STEP 02 Result Summary" "${tmp_status}"

  # Reboot is STEP 05 Completed when,  (AUTO_REBOOT_AFTER_STEP_ID)  only cando
  log "[STEP 02] HWE kernel Installation step Completedbecame.  HWE kernel thisafter s Reboot when Applywill be done."

  return 0
}


step_03_nic_ifupdown() {
  log "[STEP 03] NIC name/ifupdown before and Network Configuration"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 03] Sensor Network Mode: ${net_mode}"

  # mode branch Execution
  if [[ "${net_mode}" == "bridge" ]]; then
    log "[STEP 03] Bridge Mode - Existing L2 bridge Method Execution"
    step_03_bridge_mode
    return $?
  elif [[ "${net_mode}" == "nat" ]]; then
    log "[STEP 03] NAT Mode - OpenXDR NAT Configuration Method Execution"
    step_03_nat_mode 
    return $?
  else
    log "ERROR: unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail --title "Network Mode Error" --msgbox "unknown Sensor Network Mode: ${net_mode}\n\nin environment configuration correct Mode(bridge or nat) please select." 12 70
    return 1
  fi
}

#######################################
# STEP 03 - Bridge Mode (Existing Sensor script )
#######################################
step_03_bridge_mode() {
  log "[STEP 03 Bridge Mode] L2 bridge Based Network Configuration"

  # HOST_NIC DATA_NICthis Configurationbecome existisnot Check
  if [[ -z "${HOST_NIC:-}" || -z "${DATA_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NIC notConfiguration" \
             --msgbox "HOST_NIC or DATA_NICthis Configurationbecome existnot all.\n\n STEP 01from NIC Selection do." 12 70
    log "HOST_NIC or DATA_NICthis exist STEP 03 Bridge Mode truedo ."
    return 1
  fi

  #######################################
  # 0) Current SPAN NIC/PCI Information Check (SR-IOV Apply )
  #######################################
  local tmp_pci="${STATE_DIR}/xdr_step03_pci.txt"
  {
    echo "Selectiondone SPAN NIC and PCI Information (SR-IOV Apply)"
    echo "--------------------------------------------"
    echo "HOST_NIC  : ${HOST_NIC} (SR-IOV notApply)"
    echo "DATA_NIC  : ${DATA_NIC} (SR-IOV notApply)"
    echo
    echo "SPAN NICs (SR-IOV Apply ):"
    
    if [[ -z "${SPAN_NICS:-}" ]]; then
      echo "  Warning: SPAN_NICS Configurationbecomenot all."
      echo "   STEP 01from SPAN NIC Selection do."
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
        echo "* Some SPAN NIC PCI Information not did."
        echo "   STEP 01from correct NIC Selectionisnot Checkplease do."
      fi
    fi
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NIC/PCI Check" "${tmp_pci}"
  
  #######################################
  # Already dois Network Configurationthis existisnot  Per
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
                --yesno "udev rule /etc/network/interfaces if Already Configured  all.\n\nthis STEP skipdowhenwill you?" 18 80
    then
      log "User 'Already Configured' to STEP 03 All skipdo."
      return 0
    fi
    log "User STEP 03  allwhen Executiondo selection."
  fi

  #######################################
  # 1) HOST IP Configuration can (Default Current Configurationfrom )
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
                      --inputbox "HOST interfacethiss IP address please enter.\n: 10.4.0.210" \
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
                          --inputbox "from prefix(/) please enter.\n: 24" \
                          10 60 "${cur_prefix}" \
                          3>&1 1>&2 2>&3) || return 0
  fi

  # thisthis
  local new_gw
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    new_gw="${cur_gw}"
    log "[DRY-RUN] Gateway Configuration: ${new_gw} (Default use)"
  else
    new_gw=$(whiptail --title "STEP 03 - Gateway" \
                      --inputbox "default thisthis IP please enter.\n: 10.4.0.254" \
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
                       --inputbox "DNS froms to  please enter.\n: 8.8.8.8 8.8.4.4" \
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
      netmask=$(whiptail --title "STEP 03 - HOST Netmask  Input" \
                         --inputbox "unknown HOST prefix(/${new_prefix}) is.\n netmask please enter.\n: 255.255.255.0" \
                         10 70 "255.255.255.0" \
                         3>&1 1>&2 2>&3) || return 1
      ;;
  esac

  # DATA netmask  removedone (L2-only bridge)

  #######################################
  # 3) udev 99-custom-ifnames.rules Creation
  #######################################
  log "[STEP 03] /etc/udev/rules.d/99-custom-ifnames.rules Creation"

  # HOST_NIC/DATA_NIC PCI address get
  local host_pci data_pci
  host_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
  data_pci=$(readlink -f "/sys/class/net/${DATA_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${host_pci}" || -z "${data_pci}" ]]; then
    whiptail --title "STEP 03 - udev rule Error" \
             --msgbox "HOST_NIC(${HOST_NIC}) or DATA_NIC(${DATA_NIC}) PCI address  can does not exist.\n\nudev rule Creation all." 12 70
    log "HOST_NIC=${HOST_NIC}(${host_pci}), DATA_NIC=${DATA_NIC}(${data_pci}) -> PCI Information insufficient, udev rule Creation skip"
    return 1
  fi

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_bak="${udev_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${udev_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${udev_file}" "${udev_bak}"
    log "Existing ${udev_file} backup: ${udev_bak}"
  fi

  # SPAN NICs PCI address can and name correct  udev rule add
  local span_udev_rules=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci} (PF PCI passthrough beforefor, SR-IOV notuse)
ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
      else
        log "WARNING: SPAN NIC ${span_nic} PCI address  can does not exist."
      fi
    done
  fi

  local udev_content
  udev_content=$(cat <<EOF
# Host & Data Interface custom names (Auto Creation)
# HOST_NIC=${HOST_NIC}, PCI=${host_pci}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${host_pci}", NAME:="host"

# Data Interface PCI-bus ${data_pci}, SR-IOV notApply
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${data_pci}", NAME:="data"${span_udev_rules}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${udev_file}  Next insidefor  scheduled:\n${udev_content}"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
  fi

  # udev reload
  run_cmd "sudo udevadm control --reload"
  run_cmd "sudo udevadm trigger --type=devices --action=add"

  #######################################
  # 4) /etc/network/interfaces Creation
  #######################################
  log "[STEP 03] /etc/network/interfaces Creation"

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
    log "[DRY-RUN] ${iface_file}  Next insidefor  scheduled:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  #######################################
  # 5) /etc/network/interfaces.d/00-data.cfg Creation (br-data L2 bridge)
  #######################################
  log "[STEP 03] /etc/network/interfaces.d/00-data.cfg Creation (br-data L2 bridge)"

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
    log "[DRY-RUN] ${data_cfg}  Next insidefor  scheduled:\n${data_content}"
  else
    printf "%s\n" "${data_content}" > "${data_cfg}"
  fi

  #######################################
  # 5-1) SPAN bridge Creation (SPAN_ATTACH_MODE=bridgein case)
  #######################################
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    log "[STEP 03] SPAN L2 bridge Creation (SPAN_ATTACH_MODE=bridge)"
    
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
          log "[DRY-RUN] ${span_cfg}  Next insidefor  scheduled:\n${span_content}"
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
      log "SPAN bridge s storedone: ${SPAN_BRIDGE_LIST}"
    else
      log "WARNING: SPAN_NIC_LIST exist SPAN bridge Creationwill do can does not exist."
    fi
  else
    log "[STEP 03] SPAN bridge Creation  (SPAN_ATTACH_MODE=${SPAN_ATTACH_MODE})"
  fi

  #######################################
  # 6) /etc/iproute2/rt_tables  rt_host 
  #######################################
  log "[STEP 03] /etc/iproute2/rt_tables  rt_host "

  local rt_file="/etc/iproute2/rt_tables"
  if [[ ! -f "${rt_file}" && "${DRY_RUN}" -eq 0 ]]; then
    touch "${rt_file}"
  fi

  if grep -qE '^[[:space:]]*1[[:space:]]+rt_host' "${rt_file}" 2>/dev/null; then
    log "rt_tables: 1 rt_host this Already Existsdo."
  else
    local rt_line="1 rt_host"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] ${rt_file}  '${rt_line}' add scheduled"
    else
      echo "${rt_line}" >> "${rt_file}"
      log "${rt_file}  '${rt_line}' add"
    fi
  fi

  # rt_data this add
  if grep -qE '^[[:space:]]*2[[:space:]]+rt_data' "${rt_file}" 2>/dev/null; then
    log "rt_tables: 2 rt_data this Already Existsdo."
  else
    local rt_data_line="2 rt_data"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] ${rt_file}  '${rt_data_line}' add scheduled"
    else
      echo "${rt_data_line}" >> "${rt_file}"
      log "${rt_file}  '${rt_data_line}' add"
    fi
  fi

  #######################################
  # 7)   rule Configuration script Creation
  #######################################
  log "[STEP 03]   rule Configuration script Creation"

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
# interfacethiss up  Executiondone

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

  # DATAis L2-only bridgethis  rule Required
  routing_content="${routing_content}    # DATA(br-data) L2-only bridge -  rule None"

  routing_content="${routing_content}
    ;;
esac"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${routing_script}  Next insidefor  scheduled:\n${routing_content}"
  else
    printf "%s\n" "${routing_content}" | sudo tee "${routing_script}" >/dev/null
    sudo chmod +x "${routing_script}"
  fi

  #######################################
  # 8) netplan disable + ifupdown before
  #######################################
  log "[STEP 03] netplan disable and ifupdown before (Reboot after Apply)"

  # netplan Configuration File this
  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo mkdir -p /etc/netplan/disabled"
      log "[DRY-RUN] sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
    else
      sudo mkdir -p /etc/netplan/disabled
      sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/
    fi
  else
    log "thiswill do netplan yaml File None (Already thisbecome can exist)."
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

- SPAN connection Mode: PCI passthrough (SPAN NIC PF Sensor VM  will do)"
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

- netplan , ifupdown + networking service before

* Network Configuration changeto in Rebootthis Requireddo.
  AUTO_REBOOT_AFTER_STEP_ID Configuration   STEP Completed after Auto Rebootwill be done.
  Reboot after New NIC name(host, data, br-*) Applywill be done.
EOF
)

  whiptail --title "STEP 03 Completed" \
           --msgbox "${summary}" 25 80

  log "[STEP 03] NIC ifupdown before and Network Configurationthis Completedbecame. Reboot after New Network Configurationthis Applywill be done."

  return 0
}

#######################################
# STEP 03 - NAT Mode (OpenXDR NAT Configuration )
#######################################
step_03_nat_mode() {
  log "[STEP 03 NAT Mode] OpenXDR NAT Configuration Based Network Configuration"

  # NAT Modefromis HOST_NIC(NAT uplink NIC)only Required
  if [[ -z "${HOST_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NAT NIC notConfiguration" \
             --msgbox "NAT uplink NIC(HOST_NIC) Configurationbecome existnot all.\n\n STEP 01from NAT uplink NIC Selection do." 12 70
    log "HOST_NIC(NAT uplink NIC) exist STEP 03 NAT Mode truedo ."
    return 1
  fi

  #######################################
  # 0) NAT NIC PCI Information Check
  #######################################
  local nat_pci
  nat_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${nat_pci}" ]]; then
    whiptail --title "STEP 03 - PCI Information Error" \
             --msgbox "Selected NAT NIC PCI bus Information not did.\n\n/sys/class/net/${HOST_NIC}/device  Check do." 12 70
    log "NAT_NIC=${HOST_NIC}(${nat_pci}) -> PCI Information insufficient."
    return 1
  fi

  local tmp_pci="${STATE_DIR}/xdr_step03_pci.txt"
  {
    echo "Selectiondone NAT Network NIC and PCI Information"
    echo "------------------------------------"
    echo "NAT uplink NIC  : ${HOST_NIC}"
    echo "  -> PCI     : ${nat_pci}"
    echo
    echo "Sensor VM virbr0 NAT bridge will be connected."
    echo "DATA NICis NAT Modefrom usedonot all."
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NAT NIC/PCI Check" "${tmp_pci}"
  
  #######################################
  # Already dois NAT Configurationthis existisnot Per
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
    if whiptail --title "STEP 03 - Already Configured  " \
                --yesno "udev rule /etc/network/interfaces  if NAT Configurationthis Already become existis  all.\n\nthis STEP skipdowhenwill you?" 12 80
    then
      log "User 'Already Configured' to STEP 03 NAT Mode skipdo."
      return 0
    fi
    log "User STEP 03 NAT Mode  allwhen Executiondo selection."
  fi

  #######################################
  # 1) mgt IP Configuration can (OpenXDR Method)
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
                    --inputbox "NAT uplink NIC(mgt) IP address please enter:" \
                    8 60 "${cur_ip}" \
                    3>&1 1>&2 2>&3)
  if [[ -z "${new_ip}" ]]; then
    log "User IP Input cancelled."
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

  new_netmask=$(whiptail --title "STEP 03 - s Configuration" \
                         --inputbox "s please enter:" \
                         8 60 "${netmask}" \
                         3>&1 1>&2 2>&3)
  if [[ -z "${new_netmask}" ]]; then
    log "User s Input cancelled."
    return 1
  fi

  new_gw=$(whiptail --title "STEP 03 - Gateway Configuration" \
                    --inputbox "Gateway IP please enter:" \
                    8 60 "${cur_gw}" \
                    3>&1 1>&2 2>&3)
  if [[ -z "${new_gw}" ]]; then
    log "User Gateway Input cancelled."
    return 1
  fi

  new_dns=$(whiptail --title "STEP 03 - DNS Configuration" \
                     --inputbox "DNS from IP please enter:" \
                     8 60 "${cur_dns}" \
                     3>&1 1>&2 2>&3)
  if [[ -z "${new_dns}" ]]; then
    log "User DNS Input cancelled."
    return 1
  fi

  #######################################
  # 2) udev rule Creation (NAT uplink NIC -> mgt rename + SPAN NIC name correct)
  #######################################
  log "[STEP 03 NAT Mode] udev rule Creation (${HOST_NIC} -> mgt + SPAN NIC name correct)"
  
  # SPAN NICs PCI address can and name correct  udev rule add
  local span_udev_rules=""
  if [[ -n "${SPAN_NICS:-}" ]]; then
    for span_nic in ${SPAN_NICS}; do
      local span_pci
      span_pci=$(readlink -f "/sys/class/net/${span_nic}/device" 2>/dev/null | awk -F'/' '{print $NF}')
      if [[ -n "${span_pci}" ]]; then
        span_udev_rules="${span_udev_rules}

# SPAN Interface ${span_nic} PCI-bus ${span_pci} (PF PCI passthrough beforefor, SR-IOV notuse)
SUBSYSTEM==\"net\", ACTION==\"add\", KERNELS==\"${span_pci}\", NAME:=\"${span_nic}\""
      else
        log "WARNING: SPAN NIC ${span_nic} PCI address  can does not exist."
      fi
    done
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/udev/rules.d/99-custom-ifnames.rules Creation"
    log "[DRY-RUN] NAT mgt NIC + SPAN NIC name correct rule add"
  else
    cat > /etc/udev/rules.d/99-custom-ifnames.rules <<EOF
# XDR NAT Mode - Custom interface names
SUBSYSTEM=="net", ACTION=="add", KERNELS=="${nat_pci}", NAME:="mgt"${span_udev_rules}
EOF
    log "udev rule File Creation Completed (mgt + SPAN NIC name correct)"
  fi

  #######################################
  # 3) /etc/network/interfaces Configuration (OpenXDR Method)
  #######################################
  log "[STEP 03 NAT Mode] /etc/network/interfaces Configuration"
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
  # 4) SPAN NICs  (Bridge Modeand )
  #######################################
  if [[ -n "${SPAN_NICS:-}" ]]; then
    log "[STEP 03 NAT Mode] SPAN NICs default name not (PF PCI passthrough beforefor)"
    for span_nic in ${SPAN_NICS}; do
      log "SPAN NIC: ${span_nic} (name change None, PF PCI passthrough beforefor)"
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

NAT Network Configurationthis Completedbecame.

Network Configuration:
- NAT uplink NIC  : ${HOST_NIC} -> mgt (${new_ip}/${new_netmask})
- Gateway      : ${new_gw}
- DNS          : ${new_dns}
- Sensor VM      : virbr0 NAT bridge connection (192.168.122.0/24)
- SPAN NICs   : ${SPAN_NICS:-None} (PCI passthrough beforefor)${span_summary_nat}

udev rule     : /etc/udev/rules.d/99-custom-ifnames.rules
Network Configuration  : /etc/network/interfaces

* Network Configuration changeto in Rebootthis Requireddo.
  AUTO_REBOOT_AFTER_STEP_ID Configuration   STEP Completed after Auto Rebootwill be done.
  Reboot after NAT Network(mgt NIC) Applywill be done.
EOF
)

  whiptail --title "STEP 03 NAT Mode Completed" \
           --msgbox "${summary}" 20 80

  log "[STEP 03 NAT Mode] NAT Network Configurationthis Completedbecame. Reboot after NAT Configurationthis Applywill be done."

  return 0
}


step_04_kvm_libvirt() {
  log "[STEP 04] KVM / Libvirt Installation and default Configuration"
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
    # kvm-ok this existtoif Executionfrom "KVM acceleration can be used"  Check
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
    echo "KVM  use available: ${kvm_ok}"
    echo "libvirtd service : ${libvirtd_ok}"
    echo
    echo " STEP Next  candodo:"
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
    if ! whiptail --title "STEP 04 - Already Configured  " \
                  --yesno "KVM libvirtd Already  Statusis.\n\nthis STEP skipdowhenwill you?\n\n( selectionif  allwhen Executiondo.)" 12 70
    then
      log "User STEP 04  allwhen Executiondo selection."
    else
      log "User 'Already Configured' to STEP 04 All skipdo."
      return 0
    fi
  fi

  if ! whiptail --title "STEP 04 Execution Check" \
                 --yesno "KVM / Libvirt Installation truedodowhenwill you?" 10 60
  then
    log "User STEP 04 Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) package Installation
  #######################################
  echo "=== KVM/ environment Installation during (whenthis  can exists) ==="
  log "[STEP 04] KVM / Libvirt  package Installation"
  log " environment   can packages Installationdo..."

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
    echo "=== package $pkg_count/$total_pkgs: $pkg Installation during ==="
    log "package Installation during: $pkg ($pkg_count/$total_pkgs)"
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg}"
    echo "=== $pkg Installation Completed ==="
  done
  
  echo "=== All KVM/ package Installation Completed ==="

  #######################################
  # 2) User libvirt  add
  #######################################
  local current_user
  current_user=$(whoami)
  log "[STEP 04] ${current_user} User libvirt  add"
  run_cmd "sudo usermod -aG libvirt ${current_user}"

  #######################################
  # 3) service activate
  #######################################
  log "[STEP 04] libvirtd / virtlogd service activate"
  run_cmd "sudo systemctl enable --now libvirtd"
  run_cmd "sudo systemctl enable --now virtlogd"

  #######################################
  # 4) default libvirt Network Configuration (Network mode branch)
  #######################################
  
  if [[ "${net_mode}" == "bridge" ]]; then
    # Bridge Mode: default Network remove ( bridge use)
    log "[STEP 04] Bridge Mode - default libvirt Network(default) remove (Sensoris  bridge use)"
    
    # Existing default Network before remove
    run_cmd "sudo virsh net-destroy default || true"
    run_cmd "sudo virsh net-undefine default || true"
    
    log "Sensor VM br-data(DATA NIC) and br-span*(SPAN NIC) bridge usedo."
    
  elif [[ "${net_mode}" == "nat" ]]; then
    # NAT Mode: OpenXDR NAT Network XML Creation
    log "[STEP 04] NAT Mode - OpenXDR NAT Network XML Creation (virbr0/192.168.122.0/24)"
    
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
    
    # NAT Network correct and activate
    run_cmd "sudo virsh net-define \"${default_net_xml}\""
    run_cmd "sudo virsh net-autostart default"
    run_cmd "sudo virsh net-start default"
    
    log "Sensor VM virbr0 NAT bridge(192.168.122.0/24) usedo."
    
  else
    log "ERROR: unknown Network Mode: ${net_mode}"
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
    # KVM againCheck
    if command -v kvm-ok >/dev/null 2>&1; then
      if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
        final_kvm_ok="OK"
      else
        final_kvm_ok="FAIL"
      fi
    fi

    # libvirtd againCheck
    if systemctl is-active --quiet libvirtd; then
      final_libvirtd_ok="OK"
    else
      final_libvirtd_ok="FAIL"
    fi
  fi

  {
    echo "STEP 04 Execution Result"
    echo "------------------"
    echo "KVM  use available: ${final_kvm_ok}"
    echo "libvirtd service: ${final_libvirtd_ok}"
    echo
    echo "Sensor VM :"
    echo "- br-data: DATA NIC L2 bridge"
    echo "- br-span*: SPAN NIC L2 bridge (bridge Modein case)"
    echo "- SPAN NIC: PCI passthrough (pci Modein case)"
    echo
    echo "* User  change Next Login/Reboot when Applywill be done."
    echo "*   BIOS/UEFIfrom activatebecome exist do."
  } > "${tmp_info}"

  show_textbox "STEP 04 Result Summary" "${tmp_info}"

  log "[STEP 04] KVM / Libvirt Installation and Configuration Completed"

  return 0
}


step_05_kernel_tuning() {
  log "[STEP 05] kernel paranotfrom / KSM / swap tuning"
  load_config

  local tmp_status="/tmp/xdr_step05_status.txt"

  #######################################
  # 0) Current Status Check
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
    echo " STEP Next  candodo:"
    echo "  1) GRUB IOMMU paranotfrom add (intel_iommu=on iommu=pt)"
    echo "  2) kernel paranotfrom tuning (/etc/sysctl.conf)"
    echo "     - ARP flux not Configuration"
    echo "     - Memory  "
    echo "  3) KSM(Kernel Same-page Merging) disable"
    echo "  4) swap disable  "
    echo
    echo "*  STEP Completed after Systemthis Autoto Rebootwill be done."
  } > "${tmp_status}"

  show_textbox "STEP 05 - kernel tuning unit" "${tmp_status}"

  if [[ "${grub_has_iommu}" == "yes" && "${ksm_disabled}" == "yes" ]]; then
    if ! whiptail --title "STEP 05 - Already Configured  " \
                  --yesno "GRUB IOMMUand KSM Configurationthis Already become exists.\n\nthis STEP skipdowhenwill you?" 12 70
    then
      log "User STEP 05  allwhen Executiondo selection."
    else
      log "User 'Already Configured' to STEP 05 All skipdo."
      return 0
    fi
  fi

  if ! whiptail --title "STEP 05 Execution Check" \
                 --yesno "kernel tuning truedodowhenwill you?" 10 60
  then
    log "User STEP 05 Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) GRUB Configuration
  #######################################
  log "[STEP 05] GRUB Configuration - IOMMU paranotfrom add"

  if [[ "${grub_has_iommu}" == "no" ]]; then
    local grub_file="/etc/default/grub"
    local grub_bak="${grub_file}.$(date +%Y%m%d-%H%M%S).bak"

    if [[ "${DRY_RUN}" -eq 0 && -f "${grub_file}" ]]; then
      cp -a "${grub_file}" "${grub_bak}"
      log "GRUB Configuration backup: ${grub_bak}"
    fi

    # GRUB_CMDLINE_LINUX iommu paranotfrom add
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] GRUB_CMDLINE_LINUX 'intel_iommu=on iommu=pt' add"
    else
      # Existing GRUB_CMDLINE_LINUX  add
      sed -i 's/GRUB_CMDLINE_LINUX="/&intel_iommu=on iommu=pt /' "${grub_file}"
    fi

    run_cmd "sudo update-grub"
  else
    log "[STEP 05] GRUB Already IOMMU Configurationthis exist -> GRUB Configuration skip"
  fi

  #######################################
  # 2) kernel paranotfrom tuning
  #######################################
  log "[STEP 05] kernel paranotfrom tuning (/etc/sysctl.conf)"

  local sysctl_params="
  # XDR Installer kernel tuning (PDF this can)
  # [cite_start]IPv4   activate [cite: 53-57]
  net.ipv4.ip_forward = 1

  # Memory   (OOM not - not )
  vm.min_free_kbytes = 1048576
  "

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] /etc/sysctl.conf  kernel paranotfrom add:\n${sysctl_params}"
  else
    if ! grep -q "# XDR Installer kernel tuning" /etc/sysctl.conf 2>/dev/null; then
      echo "${sysctl_params}" >> /etc/sysctl.conf
      log "kernel paranotfrom /etc/sysctl.conf add"
    else
      log "kernel paranotfrom Already /etc/sysctl.conf exist -> skip"
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
        # Existing KSM_ENABLED inthis existtoif change, toif add
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
    log "[STEP 05] KSMthis Already disablebecome exist -> KSM Configuration skip"
  fi

  #######################################
  # 4) swap disable and swap File correct ()
  #######################################
  if whiptail --title "STEP 05 - swap disable" \
              --yesno "swap disabledowhenwill you?\n\n   becomenotonly,\nMemory insufficient when will do can exists.\n\nNext this candowill be done:\n- All  swap disable\n- /etc/fstabfrom swap   \n- /swapfile, /swap.img File remove" 16 70
  then
    log "[STEP 05] swap disable and swap File correct"
    
    # 1) All  swap disable
    run_cmd "sudo swapoff -a"
    
    # 2) /etc/fstabfrom All swap  in  
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] /etc/fstab swap ins  "
    else
      # swap  or swap File Path dodone ins  
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
        log "[STEP 05] swap File remove: ${swap_file} (Size: ${size_info})"
        run_cmd "sudo rm -f \"${swap_file}\""
      fi
    done
    
    # 4) systemd-swap  service disable (existis case)
    if systemctl is-enabled systemd-swap >/dev/null 2>&1; then
      log "[STEP 05] systemd-swap service disable"
      run_cmd "sudo systemctl disable systemd-swap"
      run_cmd "sudo systemctl stop systemd-swap"
    fi
    
    # 5) swap  systemctl services Check and disable
    local swap_services=$(systemctl list-units --type=swap --all --no-legend 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "${swap_services}" ]]; then
      for service in ${swap_services}; do
        if [[ "${service}" =~ \.swap$ ]]; then
          log "[STEP 05] swap  disable: ${service}"
          run_cmd "sudo systemctl mask \"${service}\""
        fi
      done
    fi
    
    log "swap disable and correct Completed"
  else
    log "User swap disable cancelled"
  fi

  #######################################
  # 5) Result Summary
  #######################################
  {
    echo "STEP 05 Execution Result"
    echo "------------------"
    echo "GRUB IOMMU Configuration: Completed"
    echo "kernel paranotfrom tuning: Completed"
    echo "KSM disable: Completed"
    echo
    echo "* All Configuration Applydoif System Rebootthis Requireddo."
    echo "*  STEP Completed after Autoto Rebootwill be done."
  } > "${tmp_status}"

  show_textbox "STEP 05 Result Summary" "${tmp_status}"

  log "[STEP 05] kernel tuning Configuration Completed. Rebootthis Requireddo."

  return 0
}


step_06_libvirt_hooks() {
  log "[STEP 06] libvirt hooks Installation (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 06] Sensor Network Mode: ${net_mode}"
  
  # mode branch Execution
  if [[ "${net_mode}" == "bridge" ]]; then
    log "[STEP 06] Bridge Mode - Sensor beforefor hooks Installation"
    step_06_bridge_hooks
    return $?
  elif [[ "${net_mode}" == "nat" ]]; then
    log "[STEP 06] NAT Mode - OpenXDR NAT hooks Installation"
    step_06_nat_hooks
    return $?
  else
    log "ERROR: unknown SENSOR_NET_MODE: ${net_mode}"
    whiptail --title "Network Mode Error" --msgbox "unknown Sensor Network Mode: ${net_mode}\n\nin environment configuration correct Mode(bridge or nat) please select." 12 70
    return 1
  fi
}

#######################################
# STEP 08 - Bridge Mode (Existing Sensor hooks)
#######################################
step_06_bridge_hooks() {
  log "[STEP 06 Bridge Mode] Sensor beforefor libvirt hooks Installation"

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
      echo "/etc/libvirt/hooks Directory Existsdo."
      echo
      echo "# /etc/libvirt/hooks/network (existtoif  20)"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/network
      else
        echo "(network script None)"
      fi
      echo
      echo "# /etc/libvirt/hooks/qemu (existtoif  20)"
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/qemu
      else
        echo "(qemu script None)"
      fi
    else
      echo "/etc/libvirt/hooks Directory  does not exist."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 06 - Current hooks Status" "${tmp_info}"

  if ! whiptail --title "STEP 08 Execution Check" \
                 --yesno "/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu script\nfrom Basedto before Creation/all.\n\nContinue truedodowhenwill you?" 13 80
  then
    log "User STEP 06 Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) /etc/libvirt/hooks Directory Creation
  #######################################
  log "[STEP 06] /etc/libvirt/hooks Directory Creation (toif)"
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

  log "[STEP 06] ${HOOK_NET} Creation/"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Existing ${HOOK_NET}  ${HOOK_NET_BAK}  backupdid."
    else
      log "[DRY-RUN] Existing ${HOOK_NET}  ${HOOK_NET_BAK}  backup scheduled"
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
    log "[DRY-RUN] ${HOOK_NET}  Next insidefor  scheduled:\n${net_hook_content}"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_NET}"

  #######################################
  # 3) /etc/libvirt/hooks/qemu Creation (XDR Sensorfor)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] ${HOOK_QEMU} Creation/ (OOM againStart scriptonly, NAT removedone)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Existing ${HOOK_QEMU}  ${HOOK_QEMU_BAK}  backupdid."
    else
      log "[DRY-RUN] Existing ${HOOK_QEMU}  ${HOOK_QEMU_BAK}  backup scheduled"
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
    log "[DRY-RUN] ${HOOK_QEMU}  Next insidefor  scheduled:\n${qemu_hook_content}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_QEMU}"

  ########################################
  # 4) OOM  script Installation (last_known_good_pid, check_vm_state)
  ########################################
  log "[STEP 08] OOM  script Installation (last_known_good_pid, check_vm_state)"

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
    # VMthis Enddone Statusinnot Check (.xml File, .pid Filethis not exist case)
    if [ ! -e ${RUN_DIR}/${VM}.xml -a ! -e ${RUN_DIR}/${VM}.pid ]; then
        if [ -e ${RUN_DIR}/${VM}.lkg ]; then
            LKG_PID=$(cat ${RUN_DIR}/${VM}.lkg)

            # dmesgfrom OOM-killer  PID isnot Check
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

  # 3) cron  (5all check_vm_state Execution)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] root  Next   will do scheduled:"
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

    # changedone crontab Apply
    sudo crontab "${tmp_cron}"
    rm -f "${tmp_cron}"

    if [[ "${added_flag}" = "1" ]]; then
      log "[STEP 08] root crontab  SHELL=/bin/bash and check_vm_state  /did."
    else
      log "[STEP 08] root crontab  SHELL=/bin/bash and check_vm_state  Already Existsdo."
    fi
  fi

  #######################################
  # 5)  Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 08 Execution Result Summary"
    echo "----------------------"
    echo
    echo "# /etc/libvirt/hooks/network ( 30)"
    if [[ -f /etc/libvirt/hooks/network ]]; then
      sed -n '1,30p' /etc/libvirt/hooks/network
    else
      echo "/etc/libvirt/hooks/network  Existsdonot all."
    fi
    echo
    echo "# /etc/libvirt/hooks/qemu ( 40)"
    if [[ -f /etc/libvirt/hooks/qemu ]]; then
      sed -n '1,40p' /etc/libvirt/hooks/qemu
    else
      echo "/etc/libvirt/hooks/qemu  Existsdonot all."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 06 - Result Summary" "${tmp_info}"

  log "[STEP 06] libvirt hooks Installation Completedbecame."

  return 0
}

#######################################
# STEP 06 - NAT Mode (OpenXDR NAT hooks )
#######################################
step_06_nat_hooks() {
  log "[STEP 08 NAT Mode] OpenXDR NAT libvirt hooks Installation"

  local tmp_info="${STATE_DIR}/xdr_step06_nat_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current hooks Status Summary
  #######################################
  {
    echo "NAT Mode libvirt hooks Installation"
    echo "=============================="
    echo
    echo "Installationwill do hooks:"
    echo "- /etc/libvirt/hooks/network (NAT MASQUERADE)"
    echo "- /etc/libvirt/hooks/qemu (Sensor DNAT + OOM feelwhen)"
    echo
    echo "Sensor VM Configuration:"
    echo "- VM name: mds"
    echo "- inside IP: 192.168.122.2"
    echo "- NAT bridge: virbr0"
    echo "-  interfacethiss: mgt"
  } > "${tmp_info}"

  show_textbox "STEP 06 NAT Mode - Installation unit" "${tmp_info}"

  if ! whiptail --title "STEP 06 NAT Mode Execution Check" \
                 --yesno "NAT Modefor libvirt hooks Installationdo.\n\n- OpenXDR NAT  Apply\n- Sensor VM(mds) DNAT Configuration\n- OOM feelwhen \n\nContinue truedodowhenwill you?" 15 70
  then
    log "User STEP 06 NAT Mode Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) /etc/libvirt/hooks Directory Creation
  #######################################
  log "[STEP 06 NAT Mode] /etc/libvirt/hooks Directory Creation"
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

  log "[STEP 08 NAT Mode] ${HOOK_NET} Creation (NAT MASQUERADE)"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Existing ${HOOK_NET} ${HOOK_NET_BAK} backupdid."
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
    log "[DRY-RUN] ${HOOK_NET} NAT network hook insidefor  scheduled"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
    sudo chmod +x "${HOOK_NET}"
  fi

  #######################################
  # 3) /etc/libvirt/hooks/qemu Creation (Sensor VMfor + OOM feelwhen)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 06 NAT Mode] ${HOOK_QEMU} Creation (Sensor DNAT + OOM feelwhen)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Existing ${HOOK_QEMU} ${HOOK_QEMU_BAK} backupdid."
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
# mds (Sensor) NAT / 
########################
if [ "${1}" = "mds" ]; then
  GUEST_IP=192.168.122.2
  HOST_SSH_PORT=2222
  GUEST_SSH_PORT=22
  # Sensor  s (OpenXDR datasensor Based)
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
    
    # OOM feelwhen script Start (Bridge Modeand )
    /usr/bin/last_known_good_pid ${1} > /dev/null 2>&1 &
  fi
fi

########################
# OOM feelwhen  
########################
# (Bridge Mode OOM feelwhen scriptand   do)
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] ${HOOK_QEMU} Sensor DNAT + OOM feelwhen insidefor  scheduled"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
    sudo chmod +x "${HOOK_QEMU}"
  fi

  #######################################
  # 4) OOM feelwhen script Installation (Bridge Modeand )
  #######################################
  log "[STEP 06 NAT Mode] OOM feelwhen script (/usr/bin/last_known_good_pid) Installation"
  # Bridge Modeand  OOM feelwhen script Installation  againuse
  # (Existing step_06_bridge_hooks OOM script  )

  #######################################
  # 5) Completed whennot
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 06 NAT Mode Completed]

OpenXDR Based NAT libvirt hooks Installationbecame.

Installationdone hooks:
- /etc/libvirt/hooks/network (NAT MASQUERADE)
- /etc/libvirt/hooks/qemu (Sensor DNAT + OOM feelwhen)

Sensor VM Network Configuration:
- VM name: mds
- inside IP: 192.168.122.2 (correct)
- NAT bridge: virbr0 (192.168.122.0/24)
-  : mgt interfacethiss  DNAT

DNAT : SSH(2222), Sensor thisfrom s
OOM feelwhen: activatedone

* libvirtd againStartthis Requireddo.
EOF
)

  whiptail --title "STEP 08 NAT Mode Completed" \
           --msgbox "${summary}" 18 80

  log "[STEP 06 NAT Mode] NAT libvirt hooks Installation Completed"

  return 0
}


step_07_sensor_download() {
  log "[STEP 07] Sensor LV Creation + Alreadynot/script Download"
  load_config

  # User Configuration  (OpenXDR Method: ubuntu-vg use)
  : "${LV_LOCATION:=ubuntu-vg}"
  : "${LV_SIZE_GB:=500}"
  
  log "[STEP 07] User Configuration - LV Location: ${LV_LOCATION}, LV Size: ${LV_SIZE_GB}GB"

  local tmp_status="/tmp/xdr_step09_status.txt"

  #######################################
  # 0) Current Status Check
  #######################################
  local lv_exists="no"
  local mounted="no"
  local lv_path=""

  # LV Path correct (VG nameinnot All Pathinnot )
  if [[ "${LV_LOCATION}" =~ ^/dev/ ]]; then
    # All Path s in case - default VG Creation correct
    lv_path="sensor-vg/lv_sensor_root"
  else
    # VG nameonly true case
    lv_path="${LV_LOCATION}/lv_sensor_root"
  fi

  if lvs "${lv_path}" >/dev/null 2>&1; then
    lv_exists="yes"
  fi

  if mountpoint -q /stellar/sensor 2>/dev/null; then
    mounted="yes"
  fi

  {
    echo "Current Sensor LV Status"
    echo "-------------------"
    echo "LV Path: ${lv_path}"
    echo "lv_sensor_root LV Exists: ${lv_exists}"
    echo "/stellar/sensor mount: ${mounted}"
    echo
    echo "User Configuration:"
    echo "  - LV Location: ${LV_LOCATION}"
    echo "  - LV Size: ${LV_SIZE_GB}GB"
    echo
    echo " STEP Next  candodo:"
    echo "  1) LV(lv_sensor_root) Creation (${LV_SIZE_GB}GB)"
    echo "  2) ext4 FileSystem Creation and /stellar/sensor mount"
    echo "  3) /etc/fstab Auto mount "
    echo "  4) Sensor Alreadynot and Deployment script Download"
    echo "     - virt_deploy_modular_ds.sh"
    echo "     - aella-modular-ds-${SENSOR_VERSION:-6.2.0}.qcow2"
    echo "  5) stellar:stellar  Configuration"
  } > "${tmp_status}"

  show_textbox "STEP 07 - Sensor LV and Download unit" "${tmp_status}"

  # LV Already Configurationbecome exist Alreadynot Downloadis Continue truedo
  local skip_lv_creation="no"
  if [[ "${lv_exists}" == "yes" && "${mounted}" == "yes" ]]; then
    if whiptail --title "STEP 07 - LV Already Configurationdone" \
                --yesno "lv_sensor_rootand /stellar/sensor Already Configurationbecome exists.\nPath: ${lv_path}\n\nLV Creation/mount skipdo qcow2 Alreadynot Downloadonly truedodowhenwill you?" 12 80
    then
      log "LVis Already Configurationbecome existto LV Creation/mount skipdo Alreadynot Downloadonly truedo"
      skip_lv_creation="yes"
    else
      log "User STEP 07  allwhen Executiondo selection."
    fi
  fi

  if ! whiptail --title "STEP 07 Execution Check" \
                 --yesno "Sensor LV Creation and Alreadynot Download truedodowhenwill you?" 10 60
  then
    log "User STEP 07 Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) LV Creation (Already not exist caseonly) - OpenXDR Method
  #######################################
  if [[ "${skip_lv_creation}" == "no" ]]; then
    if [[ "${lv_exists}" == "no" ]]; then
    log "[STEP 07] lv_sensor_root LV Creation (${LV_SIZE_GB}GB)"
    
    # OpenXDR Method: Existing ubuntu-vg   use
    local UBUNTU_VG="ubuntu-vg"
    local SENSOR_ROOT_LV="lv_sensor_root"
    
    if lvs "${UBUNTU_VG}/${SENSOR_ROOT_LV}" >/dev/null 2>&1; then
      log "[STEP 07] LV ${UBUNTU_VG}/${SENSOR_ROOT_LV} Already Existsdo -> Creation skip"
      lv_path="${UBUNTU_VG}/${SENSOR_ROOT_LV}"
    else
      log "[STEP 07] Existing ubuntu-vg   lv_sensor_root LV Creation"
      run_cmd "sudo lvcreate -L ${LV_SIZE_GB}G -n ${SENSOR_ROOT_LV} ${UBUNTU_VG}"
      lv_path="${UBUNTU_VG}/${SENSOR_ROOT_LV}"
      
      log "[STEP 07] ext4 FileSystem Creation"
      run_cmd "sudo mkfs.ext4 -F /dev/${lv_path}"
    fi
    else
      log "[STEP 07] lv_sensor_root LV Already Existsdo (${lv_path}) -> LV Creation skip"
    fi

    #######################################
    # 2) mount in Creation and mount
    #######################################
    log "[STEP 07] /stellar/sensor Directory Creation and mount"
    run_cmd "sudo mkdir -p /stellar/sensor"
    
    if [[ "${mounted}" == "no" ]]; then
      log "[STEP 07] LV mount: /dev/${lv_path} -> /stellar/sensor"
      run_cmd "sudo mount /dev/${lv_path} /stellar/sensor"
    else
      log "[STEP 07] /stellar/sensor Already mountbecome exist -> mount skip"
    fi

    #######################################
    # 3) fstab  and mount Check (OpenXDR )
    #######################################
    log "[STEP 07] /etc/fstab Auto mount "
    local SENSOR_FSTAB_LINE="/dev/${lv_path} /stellar/sensor ext4 defaults,noatime 0 2"
    append_fstab_if_missing "${SENSOR_FSTAB_LINE}" "/stellar/sensor"
    
    # mount -a Executiondo fstab Apply (OpenXDR Method)
    log "[STEP 07] systemctl daemon-reload and mount -a Execution"
    run_cmd "sudo systemctl daemon-reload"
    run_cmd "sudo mount -a"
    
    # mount Status Check
    if mountpoint -q /stellar/sensor 2>/dev/null; then
      log "[STEP 07] /stellar/sensor mount Success"
    else
      log "[WARN] /stellar/sensor mount Failed - can mount when"
      run_cmd "sudo mount /dev/${lv_path} /stellar/sensor"
    fi
    
    #######################################
    # 4) /stellar  change (OpenXDR )
    #######################################
    log "[STEP 07] /stellar  stellar:stellar change"
    if id stellar >/dev/null 2>&1; then
      run_cmd "sudo chown -R stellar:stellar /stellar"
      log "[STEP 07] /stellar  change Completed"
    else
      log "[WARN] 'stellar' User correct  can  chown all."
    fi
  else
    log "[STEP 07] LV Creation/mount Already Configurationbecome existto skip"
  fi

  #######################################
  # 5) Alreadynot Download Directory Configuration
  #######################################
  local SENSOR_IMAGE_DIR="/var/lib/libvirt/images/mds/images"
  run_cmd "sudo mkdir -p ${SENSOR_IMAGE_DIR}"

  #######################################
  # 6-A) Current from 1GB this qcow2 againuse  Check (OpenXDR )
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
    msg="Current fromfrom 1GB thisin qcow2 File did.\n\n"
    msg+="  File: ${local_qcow}\n"
    msg+="  Size: ${local_qcow_size_h}\n\n"
    msg+=" File  Downloaddonot   Sensor VM Deployment usedowhenwill you?\n\n"
    msg+="[]  File use (Sensor Alreadynot from , Download skip)\n"
    msg+="[] Existing File/Download   use"
    
    if whiptail --title "STEP 07 - color qcow2 againuse" --yesno "${msg}" 18 80; then
      use_local_qcow=1
      log "[STEP 07] User color qcow2 File(${local_qcow}) usedo selection."
      
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] sudo cp \"${local_qcow}\" \"${SENSOR_IMAGE_DIR}/${qcow2_name}\""
      else
        sudo cp "${local_qcow}" "${SENSOR_IMAGE_DIR}/${qcow2_name}"
        log "[STEP 07] color qcow2 ${SENSOR_IMAGE_DIR}/${qcow2_name} () Completed"
      fi
    else
      log "[STEP 07] User color qcow2 usedonot , Existing File/Download  notdo selection."
    fi
  else
    log "[STEP 07] Current from 1GB this qcow2 Filethis None -> default Download/Exists File use."
  fi
  
  #######################################
  # 6-B) Download File correct (Current from 1GB+ qcow2 do  Download)
  #######################################
  local need_script=1  # scriptis  Download
  local need_qcow2=0
  local script_name="virt_deploy_modular_ds.sh"
  
  log "[STEP 07] ${script_name}  Download "
  
  # color qcow2  case if  Download
  if [[ "${use_local_qcow}" -eq 0 ]]; then
    log "[STEP 07] ${qcow2_name} Download "
    need_qcow2=1
  else
    log "[STEP 07] color qcow2 File usedo Download skip"
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
      log "[DRY-RUN] ${qcow2_name} color qcow2 useto Download "
    fi
  else
    #  Download cando
    if [[ "${need_qcow2}" -eq 0 ]]; then
      log "[STEP 07] color qcow2 useto scriptonly Downloaddo."
    fi
    
    (
      cd "${SENSOR_IMAGE_DIR}" || exit 1
      
      # 1) Deployment script Download ()
      log "[STEP 07] ${script_name} Download Start: ${script_url}"
      echo "=== Deployment script Download during ==="
      if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${script_url}" 2>&1 | tee -a "${LOG_FILE}"; then
        chmod +x "${script_name}"
        echo "=== Deployment script Download Completed ==="
        log "[STEP 07] ${script_name} Download Completed"
      else
        log "[ERROR] ${script_name} Download Failed"
        exit 1
      fi
      
      # 2) qcow2 Alreadynot Download (for, color qcow2 usedonot is caseonly)
      if [[ "${need_qcow2}" -eq 1 ]]; then
        log "[STEP 07] ${qcow2_name} Download Start: ${image_url}"
        echo "=== ${qcow2_name} Download during (for File, whenthis   can exists) ==="
        echo "File Size   can existto when all..."
        if wget --progress=bar:force --user="${ACPS_USERNAME}" --password="${ACPS_PASSWORD}" "${image_url}" 2>&1 | tee -a "${LOG_FILE}"; then
          echo "=== ${qcow2_name} Download Completed ==="
          log "[STEP 07] ${qcow2_name} Download Completed"
        else
          log "[ERROR] ${qcow2_name} Download Failed"
          exit 1
        fi
      fi
    ) || {
      log "[ERROR] ACPS Download during Error "
      return 1
    }
    
    log "[STEP 07] Sensor Alreadynot and script Download Completed"
  fi

  #######################################
  # 8)  Configuration
  #######################################
  log "[STEP 07] /stellar  Configuration (stellar:stellar)"
  run_cmd "sudo chown -R stellar:stellar /stellar"

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
    # LV againCheck
    if lvs "${lv_path}" >/dev/null 2>&1; then
      final_lv="OK"
    else
      final_lv="FAIL"
    fi

    # mount againCheck
    if mountpoint -q /stellar/sensor; then
      final_mount="OK"
    else
      final_mount="FAIL"
    fi

    # Alreadynot File againCheck
    if [[ -f "${SENSOR_IMAGE_DIR}/${qcow2_name}" ]]; then
      final_image="OK"
    else
      final_image="FAIL"
    fi
  fi

  {
    echo "STEP 07 Execution Result"
    echo "------------------"
    echo "lv_sensor_root LV: ${final_lv}"
    echo "/stellar/sensor mount: ${final_mount}"
    echo "Sensor Alreadynot: ${final_image}"
    echo
    echo "Download Location: ${SENSOR_IMAGE_DIR}"
    echo "Alreadynot File: ${qcow2_name}"
    echo "Deployment script: virt_deploy_modular_ds.sh"
  } > "${tmp_status}"

  show_textbox "STEP 07 Result Summary" "${tmp_status}"

  log "[STEP 07] Sensor LV Creation and Alreadynot Download Completed"

  return 0
}


step_08_sensor_deploy() {
  log "[STEP 08] Sensor VM Deployment"
  load_config

  # Network Mode Check
  local net_mode="${SENSOR_NET_MODE:-bridge}"
  log "[STEP 08] Sensor Network Mode: ${net_mode}"

  local tmp_status="${STATE_DIR}/xdr_step10_status.txt"

  # can Configuration Check
  if [[ -z "${SENSOR_VCPUS:-}" || -z "${SENSOR_MEMORY_MB:-}" ]]; then
    whiptail --title "STEP 08 - Configuration Error" \
             --msgbox "Sensor vCPU or Memory Configurationthis does not exist.\n\n STEP 01from Hardware Configuration Completed do." 12 70
    log "SENSOR_VCPUS or SENSOR_MEMORY_MB Configurationbecomenot "
    return 1
  fi

  #######################################
  # 0) Current Status Check
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
    echo " STEP virt_deploy_modular_ds.sh script usedo"
    echo "Sensor VM Deploymentdo. (nodownload=1 Execution)"
  } > "${tmp_status}"

  show_textbox "STEP 08 - Sensor VM Deployment unit" "${tmp_status}"

  if [[ "${vm_exists}" == "yes" ]]; then
    if ! whiptail --title "STEP 08 - Existing VM " \
                  --yesno "mds VMthis Already Existsdo.\n\nExisting VM do  Deploymentdowhenwill you?" 12 70
    then
      log "User Existing VM againDeployment cancelled."
      return 0
    else
      log "[STEP 08] Existing mds VM "
      if [[ "${vm_running}" == "yes" ]]; then
        run_cmd "virsh destroy mds"
      fi
      run_cmd "virsh undefine mds --remove-all-storage"
    fi
  fi

  if ! whiptail --title "STEP 08 Execution Check" \
                 --yesno "Sensor VM Deployment truedodowhenwill you?" 10 60
  then
    log "User STEP 08 Execution Cancelleddid."
    return 0
  fi

  #######################################
  # 1) Deployment script Check
  #######################################
  local script_path="/var/lib/libvirt/images/mds/images/virt_deploy_modular_ds.sh"
  
  if [[ ! -f "${script_path}" && "${DRY_RUN}" -eq 0 ]]; then
    whiptail --title "STEP 08 - script None" \
             --msgbox "Deployment script  can does not exist:\n\n${script_path}\n\n STEP 07 Execution do." 12 80
    log "Deployment script None: ${script_path}"
    return 1
  fi

  #######################################
  # 2) Sensor VM Deployment
  #######################################
  log "[STEP 08] Sensor VM Deployment Start"

  local release="${SENSOR_VERSION}"
  local hostname="mds"
  local installdir="/var/lib/libvirt/images/mds"
  local cpus="${SENSOR_VCPUS}"
  local memory="${SENSOR_MEMORY_MB}"
  # LV_SIZE_GB Already GB  dobecome existisnot Check
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
    log "[STEP 08] Deployment script Directory this: /var/lib/libvirt/images/mds/images"
    cd "/var/lib/libvirt/images/mds/images" || {
      log "ERROR: Deployment script Directory this Failed"
      return 1
    }
    
    # Deployment script Execution  Check
    if [[ ! -x "virt_deploy_modular_ds.sh" ]]; then
      log "WARNING: Deployment script Execution this None.  add during..."
      chmod +x virt_deploy_modular_ds.sh
    fi
    
    # Deployment   
    log "[STEP 08] Executionwill do Deployment :"
    log "  script: $(pwd)/virt_deploy_modular_ds.sh"
    log "  s: ${hostname}"
    log "  : ${release}"
    log "  CPU: ${cpus}unit"
    log "  Memory: ${memory}MB"
    log "  sSize: ${disksize}"
    log "  InstallationDirectory: ${installdir}"
    log "  Downloadskip: ${nodownload}"
    
    # Execution before VM Status Check
    log "[STEP 08] Deployment before Existing VM Status Check"
    local existing_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
    existing_vm_count=$(echo "${existing_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
    [[ -z "${existing_vm_count}" ]] && existing_vm_count="0"
    log "  Existing mds VM unitcan: ${existing_vm_count}unit"
    
    # Network ModePer not Check
    if [[ "${net_mode}" == "bridge" ]]; then
      log "[STEP 08] Bridge Modefrom br-data not Check..."
      if ! ip link show br-data >/dev/null 2>&1; then
        log "WARNING: br-data not does not exist. STEP 03from Network Configurationthis  Completedbecomenot  can exists."
        log "WARNING: VM Deployment Failedwill do can exists. STEP 03 allwhen Executiondo System Rebootplease do."
      else
        log "[STEP 08] br-data not Existsdo."
      fi
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Modefrom virbr0 not Check..."
      if ! ip link show virbr0 >/dev/null 2>&1; then
        log "[STEP 08] virbr0 not does not exist. default libvirt Network Startdo..."
        if virsh net-list --all | grep -q "default.*inactive"; then
          run_cmd "sudo virsh net-start default" || log "WARNING: default Network Start Failed"
        elif ! virsh net-list | grep -q "default.*active"; then
          log "WARNING: default libvirt Network(default) correctbecomenot  activatebecomenot all."
        fi
        
        # allwhen Check
        if ip link show virbr0 >/dev/null 2>&1; then
          log "[STEP 08] virbr0 not Successto Creationbecame."
        else
          log "WARNING: virbr0 not Creationwill do can does not exist. VM Deployment Failedwill do can exists."
        fi
      else
        log "[STEP 08] virbr0 not Already Existsdo."
      fi
    fi

    # Network ModePer environment Configuration
    if [[ "${net_mode}" == "bridge" ]]; then
      log "[STEP 08] Bridge Mode environment can Configuration: BRIDGE=br-data"
      export BRIDGE="br-data"
      export SENSOR_BRIDGE="br-data"
      export NETWORK_MODE="bridge"
      
      # Bridge Modefrom Required IP Configuration (Default or User Configuration)
      local sensor_ip="${SENSOR_VM_IP:-192.168.100.100}"
      local sensor_netmask="${SENSOR_VM_NETMASK:-255.255.255.0}"
      local sensor_gateway="${SENSOR_VM_GATEWAY:-192.168.100.1}"
      
      export LOCAL_IP="${sensor_ip}"
      export NETMASK="${sensor_netmask}"
      export GATEWAY="${sensor_gateway}"
      
      log "[STEP 08] Bridge Mode VM IP Configuration: ${sensor_ip}/${sensor_netmask}, GW: ${sensor_gateway}"
    elif [[ "${net_mode}" == "nat" ]]; then
      log "[STEP 08] NAT Mode environment can Configuration: BRIDGE=virbr0"
      export BRIDGE="virbr0"
      export SENSOR_BRIDGE="virbr0"
      export NETWORK_MODE="nat"
      
      # NAT Modefromis DHCP use
      export LOCAL_IP="192.168.122.2"
      export NETMASK="255.255.255.0"
      export GATEWAY="192.168.122.1"
    fi
    
    # Deployment script  add environment can Configuration
    local disk_size_gb
    if [[ "${disksize}" =~ ^([0-9]+)GB$ ]]; then
      disk_size_gb="${BASH_REMATCH[1]}"
    elif [[ "${disksize}" =~ ^([0-9]+)$ ]]; then
      disk_size_gb="${disksize}"
    else
      disk_size_gb="100"  # Default
    fi
    
    # this from  environment can Configuration
    export disksize="${disk_size_gb}"
    export hostname="${hostname}"
    export release="${release}"
    export cpus="${cpus}"
    export memory="${memory}"
    export installdir="${installdir}"
    export nodownload="${nodownload}"
    export bridge="${BRIDGE}"
    
    log "[STEP 08] Deployment script environment can: disksize=${disk_size_gb}, bridge=${BRIDGE}"

    # Deployment script Execution
    log "[STEP 08] Sensor VM Deployment script Execution Start..."
    local deploy_cmd="bash virt_deploy_modular_ds.sh -- --hostname=\"${hostname}\" --release=\"${release}\" --CPUS=\"${cpus}\" --MEM=\"${memory}\" --DISKSIZE=\"${disk_size_gb}\" --installdir=\"${installdir}\" --nodownload=\"${nodownload}\" --bridge=\"${BRIDGE}\""
    log "[STEP 08] Execution : ${deploy_cmd}"
    log "[STEP 08] Network Mode: ${net_mode}, usewill do bridge: ${BRIDGE:-None}"
    log "[STEP 08] ========== Deployment script when Output Start =========="
    
    local deploy_output deploy_rc deploy_log_file
    deploy_log_file="${STATE_DIR}/deploy_output.log"
    

	# [cancorrect]   not: 5(300) after  End (VMthis Creationbecomeallif Successto )
    timeout 180s bash virt_deploy_modular_ds.sh -- \
         --hostname="${hostname}" \
         --release="${release}" \
         --CPUS="${cpus}" \
         --MEM="${memory}" \
         --DISKSIZE="${disk_size_gb}" \
         --installdir="${installdir}" \
         --nodownload="${nodownload}" \
         --bridge="${BRIDGE}" 2>&1 | tee "${deploy_log_file}"

    # timeout(124) Endbecome VMthis Existsdoif Success(0) 
    deploy_rc=${PIPESTATUS[0]}
    if [[ ${deploy_rc} -eq 124 ]]; then
      if virsh list --all | grep -q "mds.*running"; then
         log "[INFO] Deployment script  when (Timeout) - donotonly VM Execution duringthis Successto do."
         deploy_rc=0
      fi
    fi

    
    log "[STEP 08] ========== Deployment script when Output Completed =========="
    
    # Log Filefrom Output 
    if [[ -f "${deploy_log_file}" ]]; then
      deploy_output=$(cat "${deploy_log_file}")
    else
      deploy_output=""
    fi
    
    # All Output  (  )
    log "[STEP 08] Deployment script Execution Completed (exit code: ${deploy_rc})"
    if [[ -n "${deploy_output}" ]]; then
      log "[STEP 08] Deployment script All Output:"
      log "----------------------------------------"
      log "${deploy_output}"
      log "----------------------------------------"
    else
      log "[STEP 08] Deployment script Outputthis None"
    fi
    
    # Execution after VM Status Check
    log "[STEP 08] Deployment after VM Status Check"
    local new_vm_count=$(virsh list --all | grep -c "mds" 2>/dev/null || echo "0")
    new_vm_count=$(echo "${new_vm_count}" | tr -d '\n\r' | tr -d ' ' | grep -o '[0-9]*' | head -1)
    [[ -z "${new_vm_count}" ]] && new_vm_count="0"
    log "  New mds VM unitcan: ${new_vm_count}unit"
    
    if [[ "${new_vm_count}" -gt "${existing_vm_count}" ]]; then
      log "[STEP 08] VM Creation Success Check"
      virsh list --all | grep "mds" | while read line; do
        log "  VM Information: ${line}"
      done
    else
      log "WARNING: VMthis Creationbecomenot  Already Existsdo"
    fi
    # Deployment Result 
    if [[ ${deploy_rc} -ne 0 ]]; then
      log "[STEP 08] Sensor VM Deployment Failed (exit code: ${deploy_rc})"
      
      # correct Error  
      if echo "${deploy_output}" | grep -q "BIOS not enabled for VT-d/IOMMU"; then
        log "ERROR: BIOSfrom VT-d/IOMMU disablebecome exists."
        log " : BIOS Configurationfrom Intel VT-d or AMD-Vi (IOMMU)  activate do."
        whiptail --title "BIOS Configuration Required" \
                 --msgbox "VM Deployment Failed: BIOSfrom  this disablebecome exists.\n\n :\n1. System Reboot\n2. BIOS/UEFI Configuration true\n3. Intel VT-d or AMD-Vi (IOMMU) activate\n4. Configuration store after Reboot\n\nthis Configuration thisis VM Creationwill do can does not exist." 16 70
        return 1
      fi
      
      # Error existnotonly VMthis Creationbecomeisnot Check
      if virsh list --all | grep -q "mds"; then
        log "[STEP 08] Deployment scriptfrom Error notonly VM Creationdone. Continue truedodo."
      else
        log "ERROR: Deployment script Failed and VM Creation Failed"
        return 1
      fi
    else
      log "[STEP 08] Sensor VM Deployment Success"
    fi
    
    #  VM Status 
    log "[STEP 08]  VM Status:"
    virsh list --all | grep "mds" | while read line; do
      log "  ${line}"
    done
    
    log "[STEP 08] Sensor VM Deployment  Execution Completed"
  fi

  #######################################
  # 3) br-data and SPAN bridge Check, VM SPAN connection
  #######################################
  log "[STEP 08] Sensor VM Network interfacethiss add (SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE})"
  
  # br-data bridge Exists Check and Creation
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! ip link show br-data >/dev/null 2>&1; then
      log "br-data bridge Existsdonot all. canto Creationdo."
      if [[ -n "${DATA_NIC:-}" ]]; then
        # bridge Creation and Configuration
        ip link add name br-data type bridge
        ip link set dev br-data up
        ip link set dev "${DATA_NIC}" master br-data
        echo 0 > /sys/class/net/br-data/bridge/stp_state
        echo 0 > /sys/class/net/br-data/bridge/forward_delay
        log "br-data bridge Creation Completed: ${DATA_NIC}  connectiondone"
      else
        log "ERROR: DATA_NICthis Configurationbecomenot  br-data bridge Creationwill do can does not exist."
      fi
    else
      log "br-data bridge Already Existsdo."
    fi
  else
    log "[DRY-RUN] br-data bridge Exists Check and Requiredwhen Creation"
  fi
  
  # SPAN bridge Check and Creation (bridge Modein case)
  if [[ "${SPAN_ATTACH_MODE}" == "bridge" && "${DRY_RUN}" -eq 0 ]]; then
    if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
      for bridge_name in ${SPAN_BRIDGE_LIST}; do
        if ! ip link show "${bridge_name}" >/dev/null 2>&1; then
          log "SPAN bridge ${bridge_name} Existsdonot all. canto Creationdo."
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
            log "SPAN bridge ${bridge_name} Creation Completed: ${span_nic}  connectiondone"
          else
            log "ERROR: SPAN bridge ${bridge_name} dois NIC  can does not exist."
          fi
        else
          log "SPAN bridge ${bridge_name} Already Existsdo."
        fi
      done
    else
      log "WARNING: SPAN_BRIDGE_LIST exists."
    fi
  elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
    log "[DRY-RUN] SPAN bridge Exists Check and Requiredwhen Creation"
  fi
  
  # VMthis  Creationbecomeisnot check and XML cancorrect
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    # VM correctnot
    if virsh list --state-running | grep -q "\smds\s"; then
      log "mds VM correctnotdo..."
      virsh shutdown mds
      sleep 5
    fi
    
    # VMthis  Existsdoisnot Check
    if ! virsh list --all | grep -q "mds"; then
      log "ERROR: mds VMthis Creationbecomenot all. Deployment script Execution Check."
      return 1
    fi
    
    # Current XML backup
    local vm_xml_backup="${STATE_DIR}/mds_original.xml"
    if ! virsh dumpxml mds > "${vm_xml_backup}" 2>/dev/null; then
      log "ERROR: VM XML backup Failed"
      return 1
    fi
    log "Existing VM XML backup: ${vm_xml_backup}"
    
    # XML cancorrect  when File
    local vm_xml_new="${STATE_DIR}/mds_modified.xml"
    if ! virsh dumpxml mds > "${vm_xml_new}" 2>/dev/null; then
      log "ERROR: VM XML  Failed"
      return 1
    fi
    
	if [[ -f "${vm_xml_new}" && -s "${vm_xml_new}" ]]; then
      # [cancorrect] br-data during not  Apply
      # XML  Already br-data existisnot Check
      if grep -q "<source bridge='br-data'/>" "${vm_xml_new}"; then
          log "[INFO] br-data interfacethiss Already XML Existsdo. (add )"
      else
          log "br-data bridge interfacethiss add (XML  cando)"
      
          # </devices>   br-data interfacethiss add
          local br_data_interface="    <interface type='bridge'>
      <source bridge='br-data'/>
      <model type='virtio'/>
    </interface>"
      
          # when File usedo XML cancorrect
          local tmp_xml="${vm_xml_new}.tmp"
          awk -v interface="$br_data_interface" '
            /<\/devices>/ { print interface }
            { print }
          ' "${vm_xml_new}" > "${tmp_xml}"
          mv "${tmp_xml}" "${vm_xml_new}"
      fi
      
      # SPAN connection Mode  
      if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
        # SPAN NICs PF PCI passthrough(hostdev) add
        if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
          log "SPAN NIC PCIs PCI passthrough add: ${SENSOR_SPAN_VF_PCIS}"
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

              # when File usedo XML cancorrect
              local tmp_xml="${vm_xml_new}.tmp"
              awk -v hostdev="$hostdev_xml" '
                /<\/devices>/ { print hostdev }
                { print }
              ' "${vm_xml_new}" > "${tmp_xml}"
              mv "${tmp_xml}" "${vm_xml_new}"
              log "SPAN PCI(${pci_full}) hostdev attach adddone"
            else
              log "WARNING: done PCI address : ${pci_full}"
            fi
          done
        else
          log "WARNING: SENSOR_SPAN_VF_PCIS exists."
        fi
      elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
        # SPAN bridges virtio interfacethiss add
        if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
          log "SPAN bridges virtio interfacethiss add: ${SPAN_BRIDGE_LIST}"
          for bridge_name in ${SPAN_BRIDGE_LIST}; do
            # </devices>   bridge interfacethiss add
            local span_interface="    <interface type='bridge'>
      <source bridge='${bridge_name}'/>
      <model type='virtio'/>
    </interface>"
            
            # when File usedo XML cancorrect
            local tmp_xml="${vm_xml_new}.tmp"
            awk -v interface="$span_interface" '
              /<\/devices>/ { print interface }
              { print }
            ' "${vm_xml_new}" > "${tmp_xml}"
            mv "${tmp_xml}" "${vm_xml_new}"
            log "SPAN bridge ${bridge_name} virtio interfacethiss adddone"
          done
        else
          log "WARNING: SPAN_BRIDGE_LIST exists."
        fi
      else
        log "WARNING: unknown SPAN_ATTACH_MODE: ${SPAN_ATTACH_MODE}"
      fi
      
      # VM againcorrect
      log "cancorrectdone XML VM againcorrect"
      virsh undefine mds
      virsh define "${vm_xml_new}"
      
      # VM Start
      log "mds VM Start"
      virsh start mds
      
      log "br-data bridge and SPAN interfacethiss add Completed"
    else
      log "ERROR: VM XML Filethis exist donot all."
      return 1
    fi
  else
    log "[DRY-RUN] br-data bridge and SPAN interfacethiss add (is Executiondonot )"
    log "[DRY-RUN] br-data bridge: <interface type='bridge'><source bridge='br-data'/><model type='virtio'/></interface>"

    if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
      if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
        log "[DRY-RUN] SPAN NIC PCI passthrough : ${SENSOR_SPAN_VF_PCIS}"
        for pci_full in ${SENSOR_SPAN_VF_PCIS}; do
          log "[DRY-RUN] SPAN PCI(${pci_full}) hostdev add scheduled"
        done
      fi
    elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
      if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
        log "[DRY-RUN] SPAN bridge virtio interfacethiss : ${SPAN_BRIDGE_LIST}"
        for bridge_name in ${SPAN_BRIDGE_LIST}; do
          log "[DRY-RUN] bridge ${bridge_name} virtio interfacethiss add scheduled"
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
      
      # VM Execution Status Check
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
    echo "STEP 08 Execution Result"
    echo "------------------"
    echo "mds VM Creation: ${final_vm}"
    echo "mds VM Execution: ${final_running}"
    echo
    echo "VM Information:"
    echo "- name: mds"
    echo "- vCPU: ${cpus}"
    echo "- Memory: ${memory}MB"
    echo "- s: ${disksize}GB"
    echo
    echo "Network Configuration:"
    echo "- br-data bridge: L2-only bridge connectiondone (Sensor VMthis  IP Configuration)"
    echo "- SPAN connection Mode: ${SPAN_ATTACH_MODE}"

    if [[ "${SPAN_ATTACH_MODE}" == "pci" ]]; then
      if [[ -n "${SENSOR_SPAN_VF_PCIS:-}" ]]; then
        echo "- SPAN NIC PCIs: PCI passthrough connectiondone"
        for pci in ${SENSOR_SPAN_VF_PCIS}; do
          echo "  * ${pci}"
        done
      fi
      echo
      echo "Sensor Network :"
      echo "[DATA_NIC]──(L2-only)──[br-data]──(virtio)──[Sensor VM NIC]"
      echo "[SPAN NIC PF(s)]────(PCI passthrough via vfio-pci)──[Sensor VM]"
    elif [[ "${SPAN_ATTACH_MODE}" == "bridge" ]]; then
      if [[ -n "${SPAN_BRIDGE_LIST:-}" ]]; then
        echo "- SPAN bridges: L2 bridge virtio connectiondone"
        for bridge_name in ${SPAN_BRIDGE_LIST}; do
          echo "  * ${bridge_name}"
        done
      fi
      echo
      echo "Sensor Network :"
      echo "[DATA_NIC]──(L2-only)──[br-data]──(virtio)──[Sensor VM NIC]"
      echo "[SPAN_NIC(s)]──(L2-only)──[br-spanX]──(virtio)──[Sensor VM]"
    fi
    echo
    echo "* 'virsh list --all' to VM Status Checkwill do can exists."
    echo "* VMthis correct becomeif   correct  can exists."
    echo "* Sensor VM insidefrom br-data connectiondone NIC IP  Configurationplease do."
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
    # NUMA unitcan Check (lscpu use)
    ###########################################################################
    local numa_nodes=1
    if command -v lscpu >/dev/null 2>&1; then
        numa_nodes=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')
    fi
    [[ -z "${numa_nodes}" ]] && numa_nodes=1

    log "[STEP 09] NUMA  unitcan: ${numa_nodes}"

    ###########################################################################
    # 1. Sensor VM Exists Check
    ###########################################################################
    if ! virsh dominfo "${SENSOR_VM}" >/dev/null 2>&1; then
        whiptail --title "STEP 09 - Sensor None" --msgbox "Sensor VM(${SENSOR_VM})  can does not exist.\nSTEP 08from Sensor Deployment Completedbecomeisnot Checkplease do." 12 70
        log "[STEP 09] Sensor VM not found -> STEP Abort"
        return 1
    fi

    ###########################################################################
    # [NEW] 1.5. Sensor Alreadynot from /stellar/sensor  this + VM XML Path 
    #  - symlink  remove: VM XML <disk><source file='...'> Path /stellar/sensor  change
    #  - Existing /var/lib/libvirt/images  Deploymentdone Files  mv
    ###########################################################################
    local SRC_BASE="/var/lib/libvirt/images"
    local SRC_DIR="${SRC_BASE}/${SENSOR_VM}"          # /var/lib/libvirt/images/mds
    local DST_BASE="/stellar/sensor"
    local DST_DIR="${DST_BASE}/${SENSOR_VM}"          # /stellar/sensor/mds

    # VMthis dois s/ISO Path XMLfrom Check/will do  
    local OLD_PREFIX="${SRC_BASE}/${SENSOR_VM}"
    local NEW_PREFIX="${DST_BASE}/${SENSOR_VM}"

    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] (MOUNTCHK) mountpoint -q ${DST_BASE}"
        log "[DRY-RUN] (STOP) shutdown/destroy ${SENSOR_VM} if running"
        log "[DRY-RUN] (MOVE) mv ${SRC_DIR} -> ${DST_DIR}"
        log "[DRY-RUN] (XML) virsh dumpxml ${SENSOR_VM} > /tmp/${SENSOR_VM}.xml ; replace '${OLD_PREFIX}' -> '${NEW_PREFIX}' ; virsh define"
    else
        # /stellar/sensor mount Check (can)
        if ! mountpoint -q "${DST_BASE}" 2>/dev/null; then
            whiptail --title "STEP 09 - mount Error" --msgbox "${DST_BASE}  mountbecome existnot all.\n\nSTEP 07from /stellar/sensor mount  Completedplease do." 12 70
            log "[STEP 09] ERROR: ${DST_BASE} not mounted -> STEP Abort"
            return 1
        fi

        # VM Execution duringthisif before correctnot
        if virsh list --name | grep -q "^${SENSOR_VM}$"; then
            log "[STEP 09] ${SENSOR_VM} Execution during -> shutdown"
            virsh shutdown "${SENSOR_VM}" >/dev/null 2>&1 || true

            local t=0
            while virsh list --name | grep -q "^${SENSOR_VM}$"; do
                sleep 2
                t=$((t+2))
                if [[ $t -ge 120 ]]; then
                    log "[WARN] shutdown timeout -> destroy"
                    virsh destroy "${SENSOR_VM}" >/dev/null 2>&1 || true
                    break
                fi
            done
        fi

        sudo mkdir -p "${DST_BASE}"

        # 1) thisfrom this(mv)
        if [[ -d "${DST_DIR}" ]]; then
            log "[STEP 09] ${DST_DIR} Already Exists -> thisfrom this skip( not)"
        else
            if [[ -d "${SRC_DIR}" ]]; then
                log "[STEP 09] mv ${SRC_DIR} -> ${DST_DIR}"
                sudo mv "${SRC_DIR}" "${DST_DIR}"
            else
                log "[STEP 09] WARN: ${SRC_DIR} from does not exist. (Already thisbecome STEP 08 notcando)"
            fi
        fi

        # 2) VM XML : OLD_PREFIX -> NEW_PREFIX  Path  after define
        local TMP_XML="/tmp/${SENSOR_VM}.xml"
        local TMP_XML_NEW="/tmp/${SENSOR_VM}.xml.new"

        log "[STEP 09] VM XML export: ${TMP_XML}"
        virsh dumpxml "${SENSOR_VM}" > "${TMP_XML}" 2>/dev/null || {
            log "[STEP 09] ERROR: virsh dumpxml Failed"
            return 1
        }

        #  this  existisnot Check(toif  define not)
        if ! grep -q "${OLD_PREFIX//\//\\/}" "${TMP_XML}"; then
            log "[STEP 09] WARN: XML '${OLD_PREFIX}' Path does not exist. (Already done or all Path use)"
            # yes this to Continue truedo (define skip)
        else
            log "[STEP 09] VM XML patch: '${OLD_PREFIX}' -> '${NEW_PREFIX}'"
            sed "s|${OLD_PREFIX}|${NEW_PREFIX}|g" "${TMP_XML}" > "${TMP_XML_NEW}"

            #  after NEW Path sisnot Verification
            if ! grep -q "${NEW_PREFIX//\//\\/}" "${TMP_XML_NEW}"; then
                log "[STEP 09] ERROR: XML  Verification Failed(NEW Path not) -> define Abort"
                return 1
            fi

            log "[STEP 09] virsh define Apply"
            virsh define "${TMP_XML_NEW}" >/dev/null 2>&1 || {
                log "[STEP 09] ERROR: virsh define Failed"
                return 1
            }
        fi

        # 3) NEW Path s/ISO Exists   Verification
        #    (Minimum VM start when   notis file missing  not)
        log "[STEP 09] NEW Path Exists Check: ${DST_DIR}"
        if [[ ! -d "${DST_DIR}" ]]; then
            log "[STEP 09] ERROR: ${DST_DIR}  does not exist. this Failed/Path Error"
            return 1
        fi

        # XML done source file  from Exists 
        log "[STEP 09] XML source file Exists  "
        local missing=0
        while read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ ! -e "${f}" ]]; then
                log "[STEP 09] ERROR: missing file: ${f}"
                missing=$((missing+1))
            fi
        done < <(virsh dumpxml "${SENSOR_VM}" | awk -F"'" '/<source file=/{print $2}')

        if [[ "${missing}" -gt 0 ]]; then
            whiptail --title "STEP 09 - File " --msgbox "VM XMLthis dois Filethis ${missing}unit became.\n\nSTEP 08 againDeployment or Alreadynot File Location Checkplease do." 12 70
            log "[STEP 09] ERROR: XML source file missing count=${missing}"
            return 1
        fi
    fi

    ###########################################################################
    # 2. PCI Passthrough  connection (Action)
    ###########################################################################
    if [[ "${SPAN_ATTACH_MODE}" == "pci" && -n "${SENSOR_SPAN_VF_PCIS}" ]]; then
        log "[STEP 09] PCI Passthrough  connection  Start..."

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
                    log "[INFO] PCI (${pci_full}) Already connectionbecome exists."
                else
                    log "[ACTION] PCI (${pci_full}) VM connectiondo..."
                    if [[ "${_DRY}" -eq 0 ]]; then
                        if virsh attach-device "${SENSOR_VM}" "${pci_xml}" --config --live; then
                            log "[SUCCESS]  connection Success"
                        else
                            log "[ERROR]  connection Failed (Already use duringthis IOMMU Configuration check required)"
                        fi
                    else
                        log "[DRY-RUN] virsh attach-device ${SENSOR_VM} ${pci_xml} --config --live"
                    fi
                fi
            else
                log "[WARN] PCI address this not : ${pci_full}"
            fi
        done
    else
        log "[INFO] PCI Passthrough Mode    does not exist."
    fi

    ###########################################################################
    # 3. connection Status Verification (Verification)
    ###########################################################################
    log "[STEP 09] Sensor VM PCI Passthrough Status  Check"

    local hostdev_count=0
    if virsh dumpxml "${SENSOR_VM}" | grep -q "<hostdev.*type='pci'"; then
        hostdev_count=$(virsh dumpxml "${SENSOR_VM}" | grep -c "<hostdev.*type='pci'" || echo "0")
        log "[STEP 09] Sensor VM ${hostdev_count}unit PCI hostdev connectiondone"
    else
        log "[WARN] Sensor VM PCI hostdev does not exist."
    fi

    ###########################################################################
    # 4. CPU Affinity Apply (allduring NUMAfromonly)
    ###########################################################################
    if [[ "${numa_nodes}" -gt 1 ]]; then
        log "[STEP 09] Sensor VM CPU Affinity Apply Start"

        local available_cpus
        available_cpus=$(lscpu -p=CPU | grep -v '^#' | tr '\n' ',' | sed 's/,$//')

        if [[ -n "${available_cpus}" ]]; then
            log "[ACTION] CPU Affinity Configuration (All CPU )"
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
    # 4.5 Configuration Apply  before againStart
    ###########################################################################
    restart_vm_safely "${SENSOR_VM}"

    ###########################################################################
    # 5. Result 
    ###########################################################################
    local result_file="/tmp/step09_result.txt"
    {
        echo "STEP 09 - Verification Result"
        echo "==================="
        echo "- VM Status: $(virsh domstate ${SENSOR_VM} 2>/dev/null)"
        echo "- PCI  connection can: ${hostdev_count}unit"
        if [[ "${hostdev_count}" -gt 0 ]]; then
            echo "  (Success: PCI Passthrough correctto Applybecame)"
        else
            echo "  (Failed: PCI  connectionbecomenot all. Step 01 Configuration Checkplease do)"
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
                  --yesno "DP Appliance CLI package(dp_cli) s Installationdo,\nstellar User Applydo.\n\n(Current from dp_cli-*.tar.gz / dp_cli-*.tar File use)\n\nContinue truedodowhenwill you?" 15 85
    then
        log "User STEP 10 Execution Cancelleddid."
        return 0
    fi

    # 0)  Log File 
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Log File : ${ERRLOG}"
    else
        mkdir -p /var/log/aella || true
        : > "${ERRLOG}" || true
        chmod 644 "${ERRLOG}" || true
    fi

    # 1) color dp_cli package 
    local pkg=""
    pkg="$(ls -1 ./dp_cli-*.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "${pkg}" ]]; then
        pkg="$(ls -1 ./dp_cli-*.tar 2>/dev/null | sort -V | tail -n 1 || true)"
    fi

    if [[ -z "${pkg}" ]]; then
        whiptail --title "STEP 10 - DP CLI Installation" \
                 --msgbox "Current from(.) dp_cli-*.tar.gz or dp_cli-*.tar Filethis does not exist.\n\n) dp_cli-0.0.2.dev8402.tar.gz\n\nFile   STEP 10 allwhen Executionplease do." 14 90
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp_cli package not found in current directory."
        return 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] dp_cli package File feelnot: ${pkg}"

    # 2) required packages
    run_cmd "apt-get update -y"
    run_cmd "apt-get install -y python3-pip python3-venv"

    # 3) venv Creation/ after dp-cli Installation
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] venv Creation: ${VENV_DIR}"
        log "[DRY-RUN] venv dp-cli Installation: ${pkg}"
        log "[DRY-RUN]  Verification import Basedto cando"
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
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: ${ERRLOG}  Checkplease do." | tee -a "${ERRLOG}"
            return 1
        }

        "${VENV_DIR}/bin/python" -m pip install --upgrade --force-reinstall "${pkg}" >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli Installation Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: ${ERRLOG}  Checkplease do." | tee -a "${ERRLOG}"
            return 1
        }

        (cd /tmp && "${VENV_DIR}/bin/python" -c "import dp_cli; print('dp_cli import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp_cli import Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: ${ERRLOG}  Checkplease do." | tee -a "${ERRLOG}"
            return 1
        }

        if [[ ! -x "${VENV_DIR}/bin/aella_cli" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: ${VENV_DIR}/bin/aella_cli  does not exist." | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: dp-cli package console_scripts(aella_cli) in dobecome do." | tee -a "${ERRLOG}"
            return 1
        fi

        #  Verification import Basedonly cando (aella_cli Execution smoke test remove)
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; import dp_cli; from dp_cli import aella_cli_aio_appliance; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ERROR: dp-cli  import Verification Failed(venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HINT: ${ERRLOG}  Checkplease do." | tee -a "${ERRLOG}"
            return 1
        }
    fi

    # 4) /usr/local/bin/aella_cli 
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] /usr/local/bin/aella_cli  venv  Creation/"
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
        log "[DRY-RUN] /usr/bin/aella_cli  script Creationdo."
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
        log "[DRY-RUN] /etc/shells  /usr/bin/aella_cli  adddo(toif)."
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
        log "[WARN] user 'stellar'  Existsdonot  syslog  add all."
    fi

    # 9) login shell change
    if id stellar >/dev/null 2>&1; then
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] stellar Login  /usr/bin/aella_cli  changedo."
        else
            chsh -s /usr/bin/aella_cli stellar || true
        fi
    fi

    # 10) /var/log/aella  change
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] /var/log/aella from Creation/(stellar) change"
    else
        mkdir -p /var/log/aella
        if id stellar >/dev/null 2>&1; then
            chown -R stellar:stellar /var/log/aella || true
        fi
    fi

    # 11) Verification
    if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] Installation Verification stepis do."
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
    msg+="ACPS_USER    : ${ACPS_USERNAME:-<notConfiguration>}\n"
        msg+="ACPS_PASSWORD: ${ACPS_PASSWORD:-<notConfiguration>}\n"
    msg+="ACPS_URL     : ${ACPS_BASE_URL:-<notConfiguration>}\n"
    msg+="MGT_NIC      : ${MGT_NIC:-<notConfiguration>}\n"
    msg+="CLTR0_NIC    : ${CLTR0_NIC:-<notConfiguration>}\n"
    msg+="DATA_SSD_LIST: ${DATA_SSD_LIST:-<notConfiguration>}\n"

    local choice
    choice=$(whiptail --title "XDR Installer - environment Configuration" \
      --menu "${msg}" 22 80 10 \
      "1" "DRY_RUN  (0/1)" \
      "2" "DP_VERSION Configuration" \
      "3" "ACPS correct/ Configuration" \
      "4" "ACPS URL Configuration" \
      "5" " " \
      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      "1")
        # DRY_RUN 
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=1 (whenthis Mode) is.\n\n  candodois DRY_RUN=0  changedowhenwill you?" 12 70
          then
            DRY_RUN=0
          fi
        else
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=0 ( cando Mode) is.\n\nbeforedo DRY_RUN=1 (whenthis Mode)  changedowhenwill you?" 12 70
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
                           --inputbox "DP before(: 6.2.1) please enter." 10 60 "${DP_VERSION}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_ver}" ]]; then
          DP_VERSION="${new_ver}"
          save_config
          whiptail --title "DP_VERSION Configuration" \
                   --msgbox "DP_VERSION  ${DP_VERSION}  Configurationbecame." 8 60
        fi
        ;;

      "3")
        # ACPS correct / 
        local user pass
        user=$(whiptail --title "ACPS correct Configuration" \
                        --inputbox "ACPS correct(ID) please enter." 10 60 "${ACPS_USERNAME}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${user}" ]]; then
          continue
        fi

        pass=$(whiptail --title "ACPS  Configuration" \
                        --passwordbox "ACPS  please enter.\n(  Configuration File storebecome STEP 09from Auto will be used)" 10 60 "${ACPS_PASSWORD}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${pass}" ]]; then
          continue
        fi

        ACPS_USERNAME="${user}"
        ACPS_PASSWORD="${pass}"
        save_config
        whiptail --title "ACPS correct Configuration" \
                 --msgbox "ACPS_USERNAME  '${ACPS_USERNAME}'  Configurationbecame." 8 70
        ;;

      "4")
        # ACPS URL
        local new_url
        new_url=$(whiptail --title "ACPS URL Configuration" \
                           --inputbox "ACPS BASE URL please enter." 10 70 "${ACPS_BASE_URL}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_url}" ]]; then
          ACPS_BASE_URL="${new_url}"
          save_config
          whiptail --title "ACPS URL Configuration" \
                   --msgbox "ACPS_BASE_URL  '${ACPS_BASE_URL}'  Configurationbecame." 8 70
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

    local choice
    choice=$(whiptail --title "XDR Installer - Configuration" \
                      --menu "Configuration changeplease do:" \
                      22 90 10 \
                      "1" "DRY_RUN Mode: ${DRY_RUN} (1=whenthis, 0=Execution)" \
                      "2" "Sensor before: ${SENSOR_VERSION}" \
                      "3" "ACPS User: ${ACPS_USERNAME}" \
                      "4" "ACPS : (Configured)" \
                      "5" "ACPS URL: ${ACPS_BASE_URL}" \
                      "6" "Auto Reboot: ${ENABLE_AUTO_REBOOT} (1=, 0=)" \
                      "7" "SPAN connection Mode: ${SPAN_ATTACH_MODE} (pci/bridge)" \
                      "8" "Sensor Network Mode: ${SENSOR_NET_MODE} (bridge/nat)" \
                      "9" "Current Configuration " \
                      "10" "" \
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
        whiptail --title "Configuration change" --msgbox "DRY_RUNthis ${new_dry_run} changebecame." 8 60
        ;;
      2)
        local new_version
        new_version=$(whiptail --title "Sensor before Configuration" \
                               --inputbox "Sensor before please enter:" \
                               8 60 "${SENSOR_VERSION}" \
                               3>&1 1>&2 2>&3)
        if [[ -n "${new_version}" ]]; then
          save_config_var "SENSOR_VERSION" "${new_version}"
          whiptail --title "Configuration change" --msgbox "Sensor beforethis ${new_version} changebecame." 8 60
        fi
        ;;
      3)
        local new_username
        new_username=$(whiptail --title "ACPS User Configuration" \
                                --inputbox "ACPS User please enter:" \
                                8 60 "${ACPS_USERNAME}" \
                                3>&1 1>&2 2>&3)
        if [[ -n "${new_username}" ]]; then
          save_config_var "ACPS_USERNAME" "${new_username}"
          whiptail --title "Configuration change" --msgbox "ACPS Userthis changebecame." 8 60
        fi
        ;;
      4)
        local new_password
        new_password=$(whiptail --title "ACPS  Configuration" \
                                --passwordbox "ACPS  please enter:" \
                                8 60 \
                                3>&1 1>&2 2>&3)
        if [[ -n "${new_password}" ]]; then
          save_config_var "ACPS_PASSWORD" "${new_password}"
          whiptail --title "Configuration change" --msgbox "ACPS  changebecame." 8 60
        fi
        ;;
      5)
        local new_url
        new_url=$(whiptail --title "ACPS URL Configuration" \
                           --inputbox "ACPS URL please enter:" \
                           8 80 "${ACPS_BASE_URL}" \
                           3>&1 1>&2 2>&3)
        if [[ -n "${new_url}" ]]; then
          save_config_var "ACPS_BASE_URL" "${new_url}"
          whiptail --title "Configuration change" --msgbox "ACPS URLthis changebecame." 8 60
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
        whiptail --title "Configuration change" --msgbox "Auto Rebootthis ${new_reboot} changebecame." 8 60
        ;;
      7)
        local new_mode
        new_mode=$(whiptail --title "SPAN connection Mode Selection" \
                             --menu "SPAN NIC Sensor VM connectiondois Method please select:" \
                             12 70 2 \
                             "pci"    "PCI passthrough (PF  will do, sis  notuse)" \
                             "bridge" "L2 bridge virtio NIC" \
                             3>&1 1>&2 2>&3)
        if [[ -n "${new_mode}" ]]; then
          save_config_var "SPAN_ATTACH_MODE" "${new_mode}"
          whiptail --title "Configuration change" --msgbox "SPAN connection Mode ${new_mode} changebecame." 8 60
        fi
        ;;
      8)
        local new_net_mode
        new_net_mode=$(whiptail --title "Sensor Network Mode Configuration" \
                             --menu "Sensor Network Mode please select:" \
                             15 70 2 \
                             "bridge" "Bridge Mode: L2 bridge Based (default)" \
                             "nat" "NAT Mode: virbr0 NAT Network Based" \
                             3>&1 1>&2 2>&3)
        if [[ -n "${new_net_mode}" ]]; then
          save_config_var "SENSOR_NET_MODE" "${new_net_mode}"
          whiptail --title "Configuration change" --msgbox "Sensor Network Mode ${new_net_mode} changebecame.\n\nchangethis Applybecomeif STEP 01from allwhen Execution do." 12 70
        fi
        ;;
      9)
        local config_summary
        config_summary=$(cat <<EOF
Current XDR Installer Configuration
=======================

default Configuration:
- DRY_RUN: ${DRY_RUN}
- Sensor before: ${SENSOR_VERSION}
- Auto Reboot: ${ENABLE_AUTO_REBOOT}
- Sensor Network Mode: ${SENSOR_NET_MODE}
- SPAN connection Mode: ${SPAN_ATTACH_MODE}

ACPS Configuration:
- User: ${ACPS_USERNAME}
- URL: ${ACPS_BASE_URL}

Hardware Configuration:
- HOST NIC: ${HOST_NIC:-<notConfiguration>}
- DATA NIC: ${DATA_NIC:-<notConfiguration>}
- SPAN NICs: ${SPAN_NICS:-<notConfiguration>}
- Sensor vCPU: ${SENSOR_VCPUS:-<notConfiguration>}
- Sensor Memory: ${SENSOR_MEMORY_MB:-<notConfiguration>}MB

Configuration File: ${CONFIG_FILE}
EOF
)
        show_paged "Current Configuration" <(echo "${config_summary}")
        ;;
      10)
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

      menu_items+=("${i}" "${step_name} [${status}]")
    done
    menu_items+=("back" "")

    local choice
    choice=$(whiptail --title "XDR Installer - step Selection" \
                      --menu "Executionwill do step please select:" \
                      20 100 12 \
                      "${menu_items[@]}" \
                      3>&1 1>&2 2>&3) || break

    if [[ "${choice}" == "back" ]]; then
      break
    elif [[ "${choice}" =~ ^[0-9]+$ && ${choice} -ge 0 && ${choice} -lt ${NUM_STEPS} ]]; then
      run_step "${choice}"
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
    whiptail --title "XDR Installer - Auto Execution" \
             --msgbox "All step Completedbecame!" 8 60
    return
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"
  if ! whiptail --title "XDR Installer - Auto Execution" \
                --yesno "Next stepfrom Autoto Executiondowhenwill you?\n\nStart step: ${next_step_name}\n\nduring Faileddoif  stepfrom all." 12 80
  then
    return
  fi

  for ((i=next_idx; i<NUM_STEPS; i++)); do
    if ! run_step "${i}"; then
      whiptail --title "Auto Execution Abort" \
               --msgbox "STEP ${STEP_IDS[$i]} Execution during  did.\n\nAuto Execution Abortdo." 10 70
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
      status_msg="Currentnot Completeddone step None."
    else
      status_msg="not Completed step: ${LAST_COMPLETED_STEP}\nnot Execution whenEach: ${LAST_RUN_TIME}"
    fi

    local choice
    choice=$(whiptail --title "XDR Sensor Installer in menu" \
                      --menu "${status_msg}\n\nDRY_RUN=${DRY_RUN}, STATE_FILE=${STATE_FILE}" \
                      20 90 10 \
                      "1" "All step Auto Execution (Current Status  Next stepfrom truedo)" \
                      "2" "correct steponly Selection Execution" \
                      "3" "environment Configuration (DRY_RUN )" \
                      "4" "All Configuration inside Verification" \
                      "5" "script use inside" \
                      "6" "Log " \
                      "7" "End" \
                      3>&1 1>&2 2>&3) || continue

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
          whiptail --title "Log None" --msgbox " Log Filethis does not exist." 8 60
        fi
        ;;
      7)
        if whiptail --title "End Check" --yesno "XDR Installer Enddowhenwill you?" 8 60; then
          log "XDR Installer End"
          exit 0
        fi
        ;;
    esac
  done
}

#######################################
# All Configuration inside Verification
#######################################

menu_full_validation() {
  # All Verification  beforefor this DRY_RUN and this   Execution do
  # set -e  during do Faileddoif ,   fromis whento  when
  set +e

  local tmp_file="/tmp/xdr_sensor_validation_$(date '+%Y%m%d-%H%M%S').log"

  {
    echo "========================================"
    echo " XDR Sensor Installer All Configuration inside Verification"
    echo " Execution whenEach: $(date '+%F %T')"
    echo
    echo " *** Next whennot if sthiss or   if will be done." 
    echo " ***  whennot Enddoif q  if will be done."
    echo "========================================"
    echo

    ##################################################
    # 1. HWE kernel / IOMMU / GRUB Configuration Verification
    ##################################################
    echo "## 1. HWE kernel / IOMMU / GRUB Configuration Verification"
    echo
    echo "\$ uname -r"
    uname -r 2>&1 || echo "[WARN] uname -r Execution Failed"
    echo

    echo "\$ dpkg -l | grep linux-image"
    dpkg -l | grep linux-image 2>&1 || echo "[INFO] linux-image package displaybecomenot all."
    echo

    echo "\$ grep GRUB_CMDLINE_LINUX /etc/default/grub"
    grep GRUB_CMDLINE_LINUX /etc/default/grub 2>&1 || echo "[WARN] /etc/default/grub  GRUB_CMDLINE_LINUX  could not find."
    echo

    ##################################################
    # 2. SR-IOV / NIC Verification
    ##################################################
    echo "## 2. SR-IOV / NIC Verification"
    echo
    echo "\$ ip link show"
    ip link show 2>&1 || echo "[WARN] ip link show Execution Failed"
    echo

    echo "\$ lspci | grep -i ethernet"
    lspci | grep -i ethernet 2>&1 || echo "[WARN] lspci ethernet Information  Failed"
    echo

    ##################################################
    # 3. KVM / Libvirt Verification
    ##################################################
    echo "## 3. KVM / Libvirt Verification"
    echo

    echo "\$ lsmod | grep kvm"
    lsmod | grep kvm 2>&1 || echo "[WARN] kvm  kernel this becomenot   all."
    echo

    echo "\$ kvm-ok"
    if command -v kvm-ok >/dev/null 2>&1; then
      kvm-ok 2>&1 || echo "[WARN] kvm-ok Result OK  all."
    else
      echo "[INFO] kvm-ok this does not exist(cpu-checker package notInstallation)."
    fi
    echo

    echo "\$ systemctl status libvirtd --no-pager"
    systemctl status libvirtd --no-pager 2>&1 || echo "[WARN] libvirtd service Status Check Failed"
    echo

    echo "\$ virsh net-list --all"
    virsh net-list --all 2>&1 || echo "[WARN] virsh net-list --all Execution Failed"
    echo

    ##################################################
    # 4. Sensor VM / storage Verification
    ##################################################
    echo "## 4. Sensor VM / storage Verification"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all Execution Failed"
    echo

    echo "\$ lvs"
    lvs 2>&1 || echo "[WARN] LVM Information  Failed"
    echo

    echo "\$ df -h /stellar/sensor"
    df -h /stellar/sensor 2>&1 || echo "[INFO] /stellar/sensor mountin does not exist."
    echo

    echo "\$ ls -la /var/lib/libvirt/images/"
    ls -la /var/lib/libvirt/images/ 2>&1 || echo "[INFO] libvirt Alreadynot Directory does not exist."
    echo

    ##################################################
    # 5. System tuning Verification
    ##################################################
    echo "## 5. System tuning Verification"
    echo

    echo "\$ swapon --show"
    swapon --show 2>&1 || echo "[INFO] swapthis disablebecome exists."
    echo

    echo "\$ grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf"
    grep -E '^(net\.ipv4|vm\.)' /etc/sysctl.conf 2>&1 || echo "[INFO] sysctl tuning Configurationthis does not exist."
    echo

    echo "\$ systemctl status ntpsec --no-pager"
    systemctl status ntpsec --no-pager 2>&1 || echo "[INFO] ntpsec service Installation/activatebecomenot all."
    echo

    ##################################################
    # 6. Configuration File Verification
    ##################################################
    echo "## 6. Configuration File Verification"
    echo

    echo "STATE_FILE: ${STATE_FILE}"
    if [[ -f "${STATE_FILE}" ]]; then
      echo "--- ${STATE_FILE} insidefor ---"
      cat "${STATE_FILE}" 2>&1 || echo "[WARN] Status File  Failed"
    else
      echo "[INFO] Status Filethis does not exist."
    fi
    echo

    echo "CONFIG_FILE: ${CONFIG_FILE}"
    if [[ -f "${CONFIG_FILE}" ]]; then
      echo "--- ${CONFIG_FILE} insidefor ---"
      cat "${CONFIG_FILE}" 2>&1 || echo "[WARN] Configuration File  Failed"
    else
      echo "[INFO] Configuration Filethis does not exist."
    fi
    echo

    echo "========================================"
    echo " Verification Completed: $(date '+%F %T')"
    echo "========================================"

  } > "${tmp_file}" 2>&1

  show_textbox "XDR Sensor All Configuration inside Verification" "${tmp_file}"

  # when File correct
  rm -f "${tmp_file}"
  
  # set -e allwhen activate
  set -e
}

#######################################
# script use inside
#######################################

show_usage_help() {
  local msg
  msg=$'────────────────────────────────────────────────────────────
  ⭐ Stellar Cyber XDR Sensor – KVM Installer Usage Guide ⭐
  ────────────────────────────────────────────────────────────


  📌 **Required Information Before Use**
  - This installer requires *root* privileges.
    Please start in the following order:
      1) Switch to root using sudo -i
      2) Create directory with: mkdir -p /opt/xdr-installer
      3) Save this script to that directory and execute
  - Use **Space / ↓** to move to next page
  - Press **q** to quit


  ────────────────────────────────────────────
  ① 🔰 When using immediately after Ubuntu installation (Initial installation)
  ────────────────────────────────────────────
  - Select menu **1 (Auto-execute all steps)**  
    STEP 01 -> STEP 02 -> STEP 03 -> … will be executed automatically.

  - **After STEP 03 (Network) and STEP 05 (kernel tuning) complete, the system will automatically reboot.**
      -> After reboot, execute the script again  
         and select menu 1 again to **automatically continue from the next step**.

  ────────────────────────────────────────────
  ② 🔧 When some installation/environment is already configured
  ────────────────────────────────────────────
  - In menu **3 (Environment Configuration)**, you can configure the following:
      • DRY_RUN (simulation mode) — Default: 1 (for testing)  
      • SENSOR_VERSION (sensor version to install)
      • SENSOR_NET_MODE (bridge or nat)
      • SPAN_ATTACH_MODE (pci or bridge)
      • ACPS authentication information 

  - After configuration, select menu **1**  
    to automatically proceed from "the next step that has not been completed".

  ────────────────────────────────────────────
  ③ 🧩 When you want to execute only specific features or individual steps
  ────────────────────────────────────────────
  - Example: Sensor VM (mds) redeployment, network configuration change, image re-download, etc.  
  - In menu **2 (Select and execute specific steps only)**, you can execute individual steps separately.

  ────────────────────────────────────────────
  ④ 🔍 After all installation is complete – Configuration verification step
  ────────────────────────────────────────────
  - After installation is complete, execute menu **4 (Full configuration verification)**  
    to check if the following items match the installation guide.
      • KVM / Libvirt Status
      • Sensor VM (mds) Deployment and Execution Status
      • Network (ifupdown conversion) / SPAN PCI Passthrough connection Status
      • LVM storage Configuration (ubuntu-vg)

  - If WARN messages appear during verification  
    you can apply the required configuration again individually in menu **2**.

  ────────────────────────────────────────────
                  📦 Hardware and Software Requirements
  ────────────────────────────────────────────

  ● OS Requirements
    - Ubuntu Server 24.04 LTS
    - Keep default options during initial installation (SSH enabled)
    - **Note:** When executing the script, Netplan will be disabled and switched to **ifupdown**.

  ● Server Recommended Specifications (for physical servers)
    - CPU: 12 vCPU or more (automatically calculated based on total system cores)
    - Memory: 16GB or more (automatically calculated based on total system memory)
    - Disk: 
        • For OS and Sensor: use **ubuntu-vg** volume group
        • Minimum free space: 100GB or more recommended (minimum 80GB)
    - NIC Configuration:
        • Management (Host/MGT): 1GbE or more (for SSH access)
        • SPAN (Data): for mirroring traffic reception (PCI Passthrough recommended)

  ● BIOS Requirements
    - Intel VT-d / AMD-Vi (IOMMU) -> **Enabled** (required)
    - Virtualization Technology (VMX/SVM) -> **Enabled**
────────────────────────────────────────────'

  # Save content to temporary file and display with show_textbox
  local tmp_help_file="/tmp/xdr_sensor_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR Sensor Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}

# in Execution
main_menu