#!/usr/bin/env bash
#
# XDR Install Framework (SSH + Whiptail-based TUI)
# Version: 0.1 (skeleton)
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
)

# STEP display names (shown in UI)
STEP_NAMES=(
  "01. Detect and select hardware / NIC / disks"
  "02. Install HWE kernel"
  "03. Rename NICs / switch to ifupdown and configure networking"
  "04. Install and configure KVM / Libvirt"
  "05. Tune kernel parameters / KSM / swap"
  "06. Configure SR-IOV drivers (iavf/i40evf) + NTPsec"
  "07. LVM storage (DL/DA root + data)"
  "08. libvirt hooks and OOM recovery scripts"
  "09. Download DP image and deployment scripts"
  "10. Deploy DL-master VM"
  "11. Deploy DA-master VM"
  "12. SR-IOV / CPU Affinity / PCI Passthrough"
)

NUM_STEPS=${#STEP_IDS[@]}


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
  local title file tmpfile

  # ANSI color definitions
  local RED="\033[1;31m"
  local GREEN="\033[1;32m"
  local BLUE="\033[1;34m"
  local CYAN="\033[1;36m"
  local YELLOW="\033[1;33m"
  local RESET="\033[0m"

  # --- Argument handling (safe with set -u) ---
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
  else
    echo "show_paged: no content provided" >&2
    return 1
  fi

  clear
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

append_fstab_if_missing() {
  local line="$1"
  local mount_point="$2"

  if grep -qE"[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
    log "fstab: ${mount_point} entry already exists. (skip add)"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] add the following line to /etc/fstab: ${line}"
  else
    echo "${line}" >> /etc/fstab
    log "Added entry to /etc/fstab: ${line}"
  fi
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
  : "${DP_VERSION:=6.2.0}"
  : "${ACPS_USERNAME:=AellaMeta}"
  : "${ACPS_BASE_URL:=https://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=WroTQfm/W6x10}"

  # Auto reboot defaults
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"

  # Ensure NIC / disk selections are always defined
  : "${MGT_NIC:=}"
  : "${CLTR0_NIC:=}"
  : "${DATA_SSD_LIST:=}"
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
  local esc_mgt_nic esc_cltr0_nic esc_data_ssd
  esc_mgt_nic=${MGT_NIC//\"/\\\"}
  esc_cltr0_nic=${CLTR0_NIC//\"/\\\"}
  esc_data_ssd=${DATA_SSD_LIST//\"/\\\"}

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
DATA_SSD_LIST="${esc_data_ssd}"
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
    DATA_SSD_LIST)  DATA_SSD_LIST="${value}" ;;
    *)
      # Ignore unknown keys for now (extend here if needed)
      ;;
  esac

  save_config
}


#######################################
# State management
#######################################

# State file format (plain text):
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

  # Confirm whether to run this STEP
  if ! whiptail --title "XDR Installer - ${step_id}" \
                --yesno "${step_name}\n\nRun this step now?" 12 70
  then
    # Treat cancel as normal flow (not an error)
    log "User canceled running STEP ${step_id}."
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
    *)
      log "ERROR: Undefined STEP ID: ${step_id}"
      rc=1
      ;;
  esac

  if [[ "${rc}" -eq 0 ]]; then
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

          whiptail --title "Auto reboot" \
                   --msgbox "STEP ${step_id} (${step_name}) completed successfully.\n\nThe system will reboot automatically." 12 70

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
    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    whiptail --title "STEP failed - ${step_id}" \
             --msgbox "An error occurred while running STEP ${step_id} (${step_name}).\n\nCheck logs and rerun the STEP if needed.\nThe installer can continue to run." 14 80
  fi

  # Always return 0 so set -e is not triggered here
  return 0
  }


#######################################
# Hardware detection utilities
#######################################

list_nic_candidates() {
  # Exclude lo, virbr*, vnet*, tap*, docker*, br*, ovs, etc.
  ip -o link show | awk -F': ' '{print $2}' \
    | grep -Ev '^(lo|virbr|vnet|tap|docker|br-|ovs)' \
    || true
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
  : "${DATA_SSD_LIST:=}"

  ########################
  # 0) Reuse existing selections?
  ########################
  if [[ -n "${MGT_NIC}" && -n "${CLTR0_NIC}" && -n "${DATA_SSD_LIST}" ]]; then
    if whiptail --title "STEP 01 - Reuse previous selections" \
                --yesno "The following values are already set:\n\n- MGT_NIC: ${MGT_NIC}\n- CLTR0_NIC: ${CLTR0_NIC}\n- DATA_SSD_LIST: ${DATA_SSD_LIST}\n\nReuse these and skip STEP 01?\n\n(Choose No to re-select NICs/disks.)" 18 80
    then
      log "User chose to reuse existing STEP 01 selections (skip STEP 01)."

      # Ensure config is updated even when reusing
      save_config_var "MGT_NIC"       "${MGT_NIC}"
      save_config_var "CLTR0_NIC"     "${CLTR0_NIC}"
      save_config_var "DATA_SSD_LIST" "${DATA_SSD_LIST}"

      # Reuse counts as success with no further work → return 0
      return 0
    fi
  fi
  

  ########################
  # 1) List NIC candidates
  ########################
  local nics nic_list nic name idx

  # Guard against list_nic_candidates failure under set -e
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail --title "STEP 01 - NIC detection failed" \
             --msgbox "No usable NICs found.\n\nCheck ip link output and adjust the script." 12 70
    log "No NIC candidates. Check ip link output."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # Collect IP info and ethtool speed/duplex for each NIC
    local ipinfo speed duplex et_out

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

    # Show as "speed=..., duplex=..., ip=..." in whiptail menu
    nic_list+=("${name}" "speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
    ((idx++))
  done <<< "${nics}"

  ########################
  # 2) Select mgt NIC
  ########################
  local mgt_nic
  mgt_nic=$(whiptail --title "STEP 01 - Select mgt NIC" \
                     --menu "Choose the management (mgt) NIC.\nCurrent: ${MGT_NIC:-<none>}" \
                     20 80 10 \
                     "${nic_list[@]}" \
                     3>&1 1>&2 2>&3) || {
    log "User canceled mgt NIC selection."
    return 1
  }

  log "Selected mgt NIC: ${mgt_nic}"
  MGT_NIC="${mgt_nic}"
  save_config_var "MGT_NIC" "${MGT_NIC}"   ### Change 2: assign to variable before saving

  ########################
  # 3) Select cltr0 NIC
  ########################
  # Warn if cltr0 NIC matches mgt NIC
  local cltr0_nic
  cltr0_nic=$(whiptail --title "STEP 01 - Select cltr0 NIC" \
                       --menu "Select NIC for cluster/SR-IOV (cltr0).\n\nUsing a different NIC from mgt is recommended.\nCurrent: ${CLTR0_NIC:-<none>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
    log "User canceled cltr0 NIC selection."
    return 1
  }

  if [[ "${cltr0_nic}" == "${mgt_nic}" ]]; then
    if ! whiptail --title "Warning" \
                  --yesno "mgt NIC and cltr0 NIC are identical.\nThis is not recommended.\nContinue anyway?" 12 70
    then
      log "User canceled configuration with identical NICs."
      return 1    # step_01 may return 1; run_step handles rc
    fi
  fi


  log "Selected cltr0 NIC: ${cltr0_nic}"
  CLTR0_NIC="${cltr0_nic}"
  save_config_var "CLTR0_NIC" "${CLTR0_NIC}"   ### Change 3


  ########################
  # 4) Select SSDs for data
  ########################

  # Initialize variables
  local root_info="OS Disk: detection failed (needs check)"
  local disk_list=()
  local all_disks

  # List all physical disks (exclude loop, ram; include only type disk)
  # Output format: NAME SIZE MODEL
  all_disks=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1, $2, $3}')

  if [[ -z "${all_disks}" ]]; then
    whiptail --title "STEP 01 - Disk detection failed" \
             --msgbox "No physical disks found.\nCheck lsblk output." 12 70
    return 1
  fi

  # Iterate over disks
  while read -r d_name d_size d_model; do
  # Check if any child of the disk (/dev/d_name) is mounted at /
  # Using lsblk -r (raw) to inspect all children mountpoints
  if lsblk "/dev/${d_name}" -r -o MOUNTPOINT | grep -qE "^/$"; then
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
    whiptail --title "Warning" \
             --msgbox "No additional disks available for data.\n\nDetected OS disk:\n${root_info}" 12 70
    return 1
  fi

  # Build guidance message
  local msg_guide="Select disks for LVM/ES data.\n(Space: toggle, Enter: confirm)\n\n"
  msg_guide+="==================================================\n"
  msg_guide+=" [System protection] ${root_info}\n"
  msg_guide+="==================================================\n\n"
  msg_guide+="Select data disks from the list below:"

  local selected_disks
  selected_disks=$(whiptail --title "STEP 01 - Select data disks" \
                             --checklist "${msg_guide}" \
                             22 85 10 \
                             "${disk_list[@]}" \
                             3>&1 1>&2 2>&3) || {
    log "User canceled disk selection."
    return 1
  }

  # whiptail output is like "sdb" "sdc" → remove quotes
  selected_disks=$(echo "${selected_disks}" | tr -d '"')

  if [[ -z "${selected_disks}" ]]; then
    whiptail --title "Warning" \
             --msgbox "No disks selected.\nCannot proceed with LVM configuration." 10 70
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
[STEP 01 Summary]

- mgt NIC     : ${MGT_NIC}
- cltr0 NIC   : ${CLTR0_NIC}
- data disks  : ${DATA_SSD_LIST}

Config file: ${CONFIG_FILE}
EOF
)

  whiptail --title "STEP 01 complete" \
           --msgbox "${summary}" 18 80

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
  local cur_kernel hwe_installed
  cur_kernel=$(uname -r 2>/dev/null || echo "unknown")
  if dpkg -l | grep -q "^ii  ${pkg_name}[[:space:]]"; then
    hwe_installed="yes"
  else
    hwe_installed="no"
  fi

  {
    echo "Current kernel version (uname -r): ${cur_kernel}"
    echo
    echo "${pkg_name} install status: ${hwe_installed}"
    echo
    echo "This STEP will perform:"
    echo "  1) apt update"
    echo "  2) apt full-upgrade -y"
    echo "  3) install ${pkg_name} (skip if already installed)"
    echo
    echo "The new HWE kernel takes effect on the next host reboot."
    echo "This script is configured to reboot once automatically"
    echo "after STEP 05 (kernel tuning) completes."
  } > "${tmp_status}"


  # After computing cur_kernel/hwe_installed, show summary textbox

  if [[ "${hwe_installed}" == "yes" ]]; then
    if ! whiptail --title "STEP 02 - HWE kernel already installed" \
                  --yesno "linux-generic-hwe-24.04 is already installed. Skip STEP 02?" 18 80
    then
      log "User skipped STEP 02 because HWE kernel is already installed."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE kernel overview" "${tmp_status}"

  if ! whiptail --title "STEP 02 - confirmation" \
                 --yesno "Proceed with these actions?\n\n(Yes: continue / No: cancel)" 12 70
  then
    log "User canceled STEP 02 execution."
    return 0
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
  local new_kernel hwe_now
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # In DRY-RUN we don't install; reuse existing uname -r and status
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
  else
    # In real run, re-check current kernel and HWE package status
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
    echo "Previous kernel (uname -r): ${cur_kernel}"
    echo "Current kernel (uname -r): ${new_kernel}"
    echo
    echo "${pkg_name} installed (current): ${hwe_now}"
    echo
    echo "※ The new HWE kernel applies on the next host reboot."
    echo "   (uname -r output now may be unchanged before reboot.)"
    echo
    echo "※ This script performs a single automatic reboot after"
    echo "   STEP 05 (kernel tuning) depending on AUTO_REBOOT_AFTER_STEP_ID."
  } > "${tmp_status}"


  show_textbox "STEP 02 summary" "${tmp_status}"

  # Reboot happens once after STEP 05 via common logic (AUTO_REBOOT_AFTER_STEP_ID)
  log "[STEP 02] HWE kernel step completed. New kernel applies after host reboot."

  return 0
}



step_03_nic_ifupdown() {
  log "[STEP 03] NIC naming / ifupdown switch and network config"
  load_config

  # Use :- to guard against unset vars under set -u
  if [[ -z "${MGT_NIC:-}" || -z "${CLTR0_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NIC not set" \
             --msgbox "MGT_NIC or CLTR0_NIC is not configured.\n\nSelect NICs in STEP 01 first." 12 70
    log "MGT_NIC or CLTR0_NIC missing; skipping STEP 03."
    return 0   # Skip only this STEP; installer continues
  fi


  #######################################
  # 0) Check current NIC/PCI info
  #######################################
  local mgt_pci cltr0_pci
  mgt_pci=$(readlink -f "/sys/class/net/${MGT_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
  cltr0_pci=$(readlink -f "/sys/class/net/${CLTR0_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${mgt_pci}" || -z "${cltr0_pci}" ]]; then
    whiptail --title "STEP 03 - PCI info error" \
             --msgbox "Cannot fetch PCI bus info for selected NICs.\n\nCheck /sys/class/net/${MGT_NIC}/device or /sys/class/net/${CLTR0_NIC}/device." 12 70
    log "MGT_NIC=${MGT_NIC}(${mgt_pci}), CLTR0_NIC=${CLTR0_NIC}(${cltr0_pci}) → insufficient PCI info."
    return 1
  fi

  local tmp_pci="/tmp/xdr_step03_pci.txt"
  {
    echo "Selected NICs and PCI info"
    echo "----------------------"
    echo "MGT_NIC   : ${MGT_NIC}"
    echo "  -> PCI  : ${mgt_pci}"
    echo
    echo "CLTR0_NIC : ${CLTR0_NIC}"
    echo "  -> PCI  : ${cltr0_pci}"
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NIC/PCI review" "${tmp_pci}"
  
  #######################################
  # Roughly detect if desired network config already exists
  #######################################
  local maybe_done=0
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local iface_file="/etc/network/interfaces"

  if [[ -f "${udev_file}" ]] && \
     grep -q "KERNELS==\"${mgt_pci}\".*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null && \
     grep -q "KERNELS==\"${cltr0_pci}\".*NAME:=\"cltr0\"" "${udev_file}" 2>/dev/null; then
    if [[ -f "${iface_file}" ]] && \
       grep -q "^auto mgt" "${iface_file}" 2>/dev/null && \
       grep -q "iface mgt inet static" "${iface_file}" 2>/dev/null; then
      maybe_done=1
    fi
  fi

  if [[ "${maybe_done}" -eq 1 ]]; then
    if whiptail --title "STEP 03 - Looks already configured" \
                --yesno "udev rules and /etc/network/interfaces suggest config exists.\nSkip this STEP?" 18 80
    then
      log "User skipped STEP 03 because it seems already configured."
      return 0
    fi
    log "User chose to rerun STEP 03 anyway."
  fi


  #######################################
  # 1) Collect mgt IP settings (defaults from current state)
  #######################################
  local cur_cidr cur_ip cur_prefix cur_gw cur_dns
  cur_cidr=$(ip -4 -o addr show dev "${MGT_NIC}" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -n "${cur_cidr}" ]]; then
    cur_ip="${cur_cidr%/*}"
    cur_prefix="${cur_cidr#*/}"
  else
    cur_ip=""
    cur_prefix="24"
  fi
  cur_gw=$(ip route show default 0.0.0.0/0 dev "${MGT_NIC}" 2>/dev/null | awk '{print $3}' | head -n1)
  if [[ -z "${cur_gw}" ]]; then
    cur_gw=$(ip route show default 0.0.0.0/0 | awk '{print $3}' | head -n1)
  fi
  # DNS defaults per docs
  cur_dns="8.8.8.8 8.8.4.4"

  # IP address
  local new_ip
  new_ip=$(whiptail --title "STEP 03 - mgt IP setup" \
                    --inputbox "Enter IP address for mgt interface.\nExample: 10.4.0.210" \
                    10 60 "${cur_ip}" \
                    3>&1 1>&2 2>&3) || return 0

  # Prefix
  local new_prefix
  new_prefix=$(whiptail --title "STEP 03 - mgt Prefix" \
                        --inputbox "Enter subnet prefix length (/ value).\nExample: 24" \
                        10 60 "${cur_prefix}" \
                        3>&1 1>&2 2>&3) || return 0

  # Gateway
  local new_gw
  new_gw=$(whiptail --title "STEP 03 - gateway" \
                    --inputbox "Enter default gateway IP.\nExample: 10.4.0.254" \
                    10 60 "${cur_gw}" \
                    3>&1 1>&2 2>&3) || return 0

  # DNS
  local new_dns
  new_dns=$(whiptail --title "STEP 03 - DNS" \
                     --inputbox "Enter DNS servers separated by spaces.\nExample: 8.8.8.8 8.8.4.4" \
                     10 70 "${cur_dns}" \
                     3>&1 1>&2 2>&3) || return 0

  # Simple prefix → netmask conversion (common cases)
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
      # Unknown prefix → ask user for netmask directly
      netmask=$(whiptail --title "STEP 03 - Enter netmask manually" \
                         --inputbox "Unknown prefix (/ ${new_prefix}).\nEnter netmask manually.\nExample: 255.255.255.0" \
                         10 70 "255.255.255.0" \
                         3>&1 1>&2 2>&3) || return 1
      ;;
  esac

  #######################################
  # 2) Create udev 99-custom-ifnames.rules
  #######################################
  log "[STEP 03] Create /etc/udev/rules.d/99-custom-ifnames.rules"

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_bak="${udev_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${udev_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${udev_file}" "${udev_bak}"
    log "Backed up existing ${udev_file}: ${udev_bak}"
  fi

  local udev_content
  udev_content=$(cat <<EOF
# Management & Cluster Interface custom names (auto-generated)
# MGT_NIC=${MGT_NIC}, PCI=${mgt_pci}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${mgt_pci}", NAME:="mgt"

# Cluster Interface PCI-bus ${cltr0_pci}, create 2 SR-IOV VFs
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${cltr0_pci}", NAME:="cltr0", ATTR{device/sriov_numvfs}="2"
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${udev_file}:\n${udev_content}"
  else
    printf "%s\n" "${udev_content}" > "${udev_file}"
  fi

  # udev reload
  run_cmd "sudo udevadm control --reload"
  run_cmd "sudo udevadm trigger --type=devices --action=add"

  #######################################
  # 3) Create /etc/network/interfaces
  #######################################
  log "[STEP 03] Create /etc/network/interfaces"

  local iface_file="/etc/network/interfaces"
  local iface_bak="${iface_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${iface_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${iface_file}" "${iface_bak}"
    log "Backed up existing ${iface_file}: ${iface_bak}"
  fi

  local iface_content
  iface_content=$(cat <<EOF
source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The management network interface
auto mgt
iface mgt inet static
    address ${new_ip}
    netmask ${netmask}
    gateway ${new_gw}
    dns-nameservers ${new_dns}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Will write to ${iface_file}:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  #######################################
  # 4) Create /etc/network/interfaces.d/00-cltr0.cfg
  #######################################
  log "[STEP 03] Create /etc/network/interfaces.d/00-cltr0.cfg"

  local iface_dir="/etc/network/interfaces.d"
  local cltr0_cfg="${iface_dir}/00-cltr0.cfg"
  local cltr0_bak="${cltr0_cfg}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  if [[ -f "${cltr0_cfg}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${cltr0_cfg}" "${cltr0_bak}"
    log "Backed up existing ${cltr0_cfg}: ${cltr0_bak}"
  fi

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

  #######################################
  # 5) Register rt_mgt in /etc/iproute2/rt_tables
  #######################################
  log "[STEP 03] Add rt_mgt to /etc/iproute2/rt_tables"

  local rt_file="/etc/iproute2/rt_tables"
  if [[ ! -f "${rt_file}" && "${DRY_RUN}" -eq 0 ]]; then
    touch "${rt_file}"
  fi

  if grep -qE '^[[:space:]]*1[[:space:]]+rt_mgt' "${rt_file}" 2>/dev/null; then
    log "rt_tables: entry '1 rt_mgt' already exists."
  else
    local rt_line="1 rt_mgt"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will append '${rt_line}' to ${rt_file}"
    else
      echo "${rt_line}" >> "${rt_file}"
      log "Added '${rt_line}' to ${rt_file}"
    fi
  fi


  #######################################
  # 6) Disable netplan and switch to ifupdown
  #######################################
  log "[STEP 03] Install ifupdown and disable netplan"

  run_cmd "sudo apt update"
  run_cmd "sudo apt install -y ifupdown net-tools"

  # Move netplan config files
  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo mkdir -p /etc/netplan/disabled"
      log "[DRY-RUN] sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
    else
      sudo mkdir -p /etc/netplan/disabled
      sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/
    fi
  else
    log "No netplan yaml files to move (may already be relocated)."
  fi

  #######################################
  # 6-1) Disable systemd-networkd/netplan services and enable legacy networking
  #######################################
  log "[STEP 03] Disable systemd-networkd/netplan services; enable networking service"

  # Disable systemd-networkd / netplan related services
  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"

  # Enable legacy networking service
  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"


  #######################################
  # 8) Summary and reboot recommendation
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 03 Summary]

- udev rule file      : /etc/udev/rules.d/99-custom-ifnames.rules
  * mgt   -> PCI ${mgt_pci}
  * cltr0 -> PCI ${cltr0_pci}, sriov_numvfs=2

- /etc/network/interfaces
  * mgt IP      : ${new_ip}/${new_prefix} (netmask ${netmask})
  * gateway     : ${new_gw}
  * dns         : ${new_dns}

- /etc/network/interfaces.d/00-cltr0.cfg
  * cltr0 → manual mode

- /etc/iproute2/rt_tables
  * Add 1 rt_mgt if missing

- netplan disabled, switched to ifupdown + networking service

※ Network services may fail if restarted immediately.
  This script is set to auto-reboot twice: after STEP 03
  (NIC/ifupdown switch) and after STEP 05 (kernel tuning).
  When DRY_RUN=0 and each STEP succeeds, auto reboot runs.
EOF
)


    whiptail --title "STEP 03 complete" \
             --msgbox "${summary}" 25 80

    # Reboot handled in common logic (AUTO_REBOOT_AFTER_STEP_ID)
    log "[STEP 03] NIC ifupdown switch and network configuration finished."
    log "[STEP 03] This STEP (03_nic_ifupdown) is included for auto reboot."

    return 0
  }
  

step_04_kvm_libvirt() {
  log "[STEP 04] Install KVM / Libvirt and pin default network (virbr0)"
  load_config

  local tmp_info="/tmp/xdr_step04_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Summarize current KVM/Libvirt status
  #######################################
  {
    echo "Current KVM/Libvirt status"
    echo "--------------------------------"
    echo
    echo "1) CPU virtualization support (vmx/svm presence)"
    egrep -c '(vmx|svm)' /proc/cpuinfo 2>/dev/null || echo "0"
    echo
    echo "2) KVM/Libvirt package installation status (dpkg -l)"
    dpkg -l | egrep 'qemu-kvm|libvirt-daemon-system|libvirt-clients|virtinst|bridge-utils|qemu-utils|virt-viewer|genisoimage|net-tools|cpu-checker|ipset|ipcalc-ng' \
      || echo "(no related package info)"
    echo
    echo "3) libvirtd service state (brief)"
    systemctl is-active libvirtd 2>/dev/null || echo "inactive"
    echo
    echo "4) virsh net-list --all"
    virsh net-list --all 2>/dev/null || echo "(no libvirt network info)"
  } >> "${tmp_info}"

  show_textbox "STEP 04 - Current KVM/Libvirt status" "${tmp_info}"

  if ! whiptail --title "STEP 04 - confirmation" \
                 --yesno "Proceed with KVM/Libvirt package install and default network configuration?" 13 80
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

  if [[ -f "${default_net_xml_final}" ]]; then
    # Determine if already 192.168.122.1/24 with no DHCP
    if grep -q "<ip address='192.168.122.1' netmask='255.255.255.0'" "${default_net_xml_final}" 2>/dev/null && \
       ! grep -q "<dhcp>" "${default_net_xml_final}" 2>/dev/null; then
      need_redefine=0
      log "[STEP 04] ${default_net_xml_final} already defines default network as 192.168.122.1/24 without DHCP."
    else
      need_redefine=1
      log "[STEP 04] Detected DHCP or other settings in ${default_net_xml_final} → needs redefine."
    fi
  else
    need_redefine=1
    log "[STEP 04] ${default_net_xml_final} not found → default network must be defined."
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

	# Extra: wait for settings to flush to disk and stabilize
	log "[STEP 04] Waiting for settings to apply (5s)..."
	sleep 10
	sync	
	
  else
    log "[STEP 04] Default network already in desired state; skipping redefine."
  fi

  #######################################
  # 5) Final status summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 04 execution summary"
    echo "-----------------------"
    echo
    echo "# virsh net-list --all"
    virsh net-list --all 2>/dev/null || echo "(no libvirt network info)"
    echo
    echo "# Key parts of ${default_net_xml_final} (IP/DHCP)"
    if [[ -f "${default_net_xml_final}" ]]; then
      grep -E "<network>|<name>|<forward|<bridge|<ip|<dhcp" "${default_net_xml_final}" || cat "${default_net_xml_final}"
    else
      echo "${default_net_xml_final} does not exist."
    fi
    echo
    echo "※ /etc/libvirt/hooks/network and /etc/libvirt/hooks/qemu"
    echo "   assume virbr0 (default network: 192.168.122.0/24, no DHCP)."
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

    # 3) libvirtd / virtlogd service state
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
      fail_reasons+=(" - libvirtd service is not active.")
    fi

    if ! systemctl is-active --quiet virtlogd 2>/dev/null; then
      fail_reasons+=(" - virtlogd service is not active.")
    fi

    # 4) default network (virbr0) configuration state
    local default_net_xml_final="/etc/libvirt/qemu/networks/default.xml"

    if [[ ! -f "${default_net_xml_final}" ]]; then
      fail_reasons+=(" - ${default_net_xml_final} file does not exist.")
    else
      if ! grep -q "<ip address='192.168.122.1' netmask='255.255.255.0'>" "${default_net_xml_final}" 2>/dev/null; then
        fail_reasons+=(" - default network IP is not 192.168.122.1/24.")
      fi
      if grep -q "<dhcp>" "${default_net_xml_final}" 2>/dev/null; then
        fail_reasons+=(" - DHCP block remains in default network XML.")
      fi
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
      whiptail --title "STEP 04 validation failed" --msgbox "${msg}" 20 90
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
    echo "# IPv4 forwarding status"
    sysctl net.ipv4.ip_forward 2>/dev/null || echo "Failed to read net.ipv4.ip_forward"
    echo
    echo "# ARP-related settings (may already be set)"
    sysctl net.ipv4.conf.all.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_ignore 2>/dev/null || true
    sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null || true
    echo
    echo "# KSM status (0 = disabled, 1 = enabled)"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      cat /sys/kernel/mm/ksm/run
    else
      echo "/sys/kernel/mm/ksm/run not found."
    fi
    echo
    echo "# Current swap status"
    swapon --show || echo "(no active swap)"
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Current kernel/Swap status" "${tmp_info}"

  if ! whiptail --title "STEP 05 - confirmation" \
                 --yesno "Apply kernel params, disable KSM, disable Swap, and configure IOMMU per docs?\n\n(Yes: continue / No: cancel)" 15 80
  then
    log "User canceled STEP 05."
    return 0
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
    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] sudo update-grub"
    else
      log "[STEP 05] Running update-grub"
      sudo update-grub
    fi
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

  # Restart qemu-kvm to apply KSM setting
  if systemctl list-unit-files 2>/dev/null | grep -q '^qemu-kvm\.service'; then
    log "[STEP 05] Restarting qemu-kvm to apply KSM setting."

    # Use run_cmd to honor DRY_RUN
    run_cmd "sudo systemctl restart qemu-kvm"

    # Check KSM state after restart
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      log "[STEP 05] qemu-kvm restart → current /sys/kernel/mm/ksm/run:"
      cat /sys/kernel/mm/ksm/run >> "${LOG_FILE}" 2>&1
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

  if whiptail --title "STEP 05 - disable Swap" \
              --yesno "Disable Swap per docs and comment /swap.img in /etc/fstab.\n\nProceed now?" 13 80
  then
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
      if whiptail --title "STEP 05 - swap.img Zeroize" \
                  --yesno "/swap.img exists.\nDocs recommend zeroize with dd + truncate (takes time).\n\nProceed now?" 15 80
      then
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
    echo "STEP 05 execution summary"
    echo "----------------------"
    echo
    echo "# vm.min_free_kbytes (after apply)"
    sysctl vm.min_free_kbytes 2>/dev/null || echo "Failed to read vm.min_free_kbytes"
    echo
    echo "# ARP / ignore_routes_with_linkdown settings (after apply)"
    sysctl net.ipv4.conf.all.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_ignore 2>/dev/null || true
    sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null || true
    echo
    echo "# KSM state (/sys/kernel/mm/ksm/run)"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      cat /sys/kernel/mm/ksm/run
    else
      echo "/sys/kernel/mm/ksm/run not found."
    fi
    echo
    echo "# Current Swap status (swapon --show)"
    swapon --show || echo "(no active swap)"
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Summary" "${tmp_info}"

  # STEP 05 is considered complete here (save_state is called from run_step)
}




step_06_ntpsec() {
  log "[STEP 06] Install SR-IOV driver (iavf/i40evf) + configure NTPsec"
  load_config

  local tmp_info="/tmp/xdr_step06_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Install SR-IOV iavf(i40evf) driver
  #######################################
  log "[STEP 06] Starting SR-IOV iavf(i40evf) driver install"

  local iavf_url="https://github.com/intel/ethernet-linux-iavf/releases/download/v4.13.16/iavf-4.13.16.tar.gz"

  echo "=== Installing packages needed to build iavf driver (apt-get) ==="
  sudo apt-get update -y
  sudo apt-get install -y build-essential linux-headers-$(uname -r) curl

  echo
  echo "=== Downloading iavf driver archive (curl progress below) ==="
  (
    cd /tmp || exit 1
    curl -L -o iavf-4.13.16.tar.gz "${iavf_url}"
  )
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log "[ERROR] Failed to download iavf driver (rc=${rc})"
    whiptail --title "STEP 06 - iavf download failed" \
             --msgbox "Failed to download iavf driver (${iavf_url}).\n\nCheck network or GitHub access and retry." 12 80
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
    whiptail --title "STEP 06 - iavf build/install failed" \
             --msgbox "Failed to build or install iavf driver.\n\nCheck /var/log/xdr-installer.log." 12 80
    return 1
  fi
  echo "=== iavf driver build / install complete ==="
  log "[STEP 06] iavf driver build / install complete"

  #######################################
  # 1) Verify/apply SR-IOV VF driver (iavf/i40evf)
  #######################################
  log "[STEP 06] Attempting to load iavf/i40evf modules"
  sudo modprobe iavf 2>/dev/null || sudo modprobe i40evf 2>/dev/null || true

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
    systemctl is-active ntpsec 2>/dev/null || echo "inactive"
    echo
    echo "# ntpq -p (if available)"
    ntpq -p 2>/dev/null || echo "ntpq -p failed or ntpsec not installed"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV driver install / NTP status" "${tmp_info}"

  if ! whiptail --title "STEP 06 - confirmation" \
	             --yesno "After installing iavf(i40evf), configure NTPsec on the host.\n\nProceed?" 13 80
  then
    log "User canceled STEP 06."
    return 0
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
  log "[STEP 06] Comment restrict default kod ... rule"

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
    echo "STEP 06 (SR-IOV + NTPsec) execution summary"
    echo "----------------------------------------"
    echo
    echo "# SR-IOV VF driver (iavf/i40evf) module state (lsmod)"
    lsmod | grep -E '^(iavf|i40evf)\b' || echo "No loaded iavf/i40evf modules."
    echo
    echo "# XDR_NTPSEC_CONFIG section in ${NTP_CONF}"
    if [[ -f "${NTP_CONF}" ]]; then
      grep -n -A5 -B2 "${TAG_BEGIN}" "${NTP_CONF}" || sed -n '1,120p' "${NTP_CONF}"
    else
      echo "${NTP_CONF} does not exist."
    fi
    echo
    echo "# systemctl is-active ntpsec"
    systemctl is-active ntpsec 2>/dev/null || echo "inactive"
    echo
    echo "# ntpq -p"
    ntpq -p 2>/dev/null || echo "ntpq -p failed or awaiting sync"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV(iavf/i40evf) + NTPsec summary" "${tmp_info}"

  # save_state is called from run_step()
}


step_07_lvm_storage() {
  log "[STEP 07] Start LVM storage configuration"

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

  local DL_ROOT_LV="lv_dl_root"
  local DA_ROOT_LV="lv_da_root"
  local ES_VG="vg_dl"
  local ES_LV="lv_dl"

  if [[ -z "${DATA_SSD_LIST}" ]]; then
    whiptail --title "STEP 07 - data disks not set" \
             --msgbox "DATA_SSD_LIST is empty.\n\nSelect data disks in STEP 01 first." 12 70
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
    if whiptail --title "STEP 07 - appears already configured" \
                --yesno "vg_dl / lv_dl and ${UBUNTU_VG}/${DL_ROOT_LV}, ${UBUNTU_VG}/${DA_ROOT_LV}\nplus /stellar/dl and /stellar/da mounts already exist.\n\nThis STEP recreates disk partitions and should not normally be rerun.\n\nSkip this STEP?" 18 80
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

  show_textbox "STEP 07 - Confirm disks" "${tmp_info}"

  if ! whiptail --title "STEP 07 - WARNING" \
                 --yesno "All existing partitions/data on /dev/${DATA_SSD_LIST}\nwill be deleted and used exclusively for LVM.\n\nContinue?" 15 70
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

  local tmp_df="/tmp/xdr_step07_df.txt"
  {
    echo "=== df -h | egrep '/stellar/(dl|da)' ==="
    df -h | egrep '/stellar/(dl|da)' || echo "No /stellar/dl or /stellar/da mount info."
    echo

    echo "=== lvs ==="
    lvs
    echo

    # Verify like doc example after LV creation
    echo "=== lsblk (view all disks/partitions/Logical Volumes) ==="
    lsblk
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

  if ! whiptail --title "STEP 08 - confirmation" \
                 --yesno "Create/overwrite /etc/libvirt/hooks/network and qemu scripts per docs.\n\nProceed?" 13 80
  then
    log "User canceled STEP 08."
    return 0
  fi


  #######################################
  # 1) Create /etc/libvirt/hooks directory
  #######################################
  log "[STEP 08] Create /etc/libvirt/hooks directory if missing"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /etc/libvirt/hooks"
  else
    sudo mkdir -p /etc/libvirt/hooks
  fi

  #######################################
  # 2) Create /etc/libvirt/hooks/network (per docs)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Create/update ${HOOK_NET}"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Backed up existing ${HOOK_NET} to ${HOOK_NET_BAK}."
    else
      log "[DRY-RUN] Would back up existing ${HOOK_NET} to ${HOOK_NET_BAK}"
    fi
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

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] Would write the following to ${HOOK_NET}:\n${net_hook_content}"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_NET}"

  #######################################
  # 3) Create /etc/libvirt/hooks/qemu (full version)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Create/update ${HOOK_QEMU} (full NAT + OOM restart script)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Backed up existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}."
    else
      log "[DRY-RUN] Would back up existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}"
    fi
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
    log "[DRY-RUN] Would write the following to ${HOOK_QEMU}:\n${qemu_hook_content}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_QEMU}"


  ########################################
  # 4) Install OOM recovery scripts (last_known_good_pid, check_vm_state)
  ########################################
  log "[STEP 08] Install OOM recovery scripts (last_known_good_pid, check_vm_state)"

  local _DRY="${DRY_RUN:-0}"

  # 1) Create /usr/bin/last_known_good_pid (per docs)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would create /usr/bin/last_known_good_pid script"
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


  # 2) Create /usr/bin/check_vm_state (per docs)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Would create /usr/bin/check_vm_state script"
  else
    sudo tee /usr/bin/check_vm_state >/dev/null <<'EOF'
#!/bin/bash
VM_LIST=(dl-master da-master)
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
    sudo chmod +x /usr/bin/check_vm_state
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
    sudo crontab "${tmp_cron}"
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
    echo "STEP 08 execution summary"
    echo "----------------------"
    echo
    echo "# /etc/libvirt/hooks/network (first 30 lines)"
    if [[ -f /etc/libvirt/hooks/network ]]; then
      sed -n '1,30p' /etc/libvirt/hooks/network
    else
      echo "/etc/libvirt/hooks/network not found."
    fi
    echo
    echo "# /etc/libvirt/hooks/qemu (first 40 lines)"
    if [[ -f /etc/libvirt/hooks/qemu ]]; then
      sed -n '1,40p' /etc/libvirt/hooks/qemu
    else
      echo "/etc/libvirt/hooks/qemu not found."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 08 - Summary" "${tmp_info}"

  # save_state handled in run_step()
}


step_09_dp_download() {
  log "[STEP 09] Download DP deploy script and image (virt_deploy_uvp_centos.sh + qcow2)"
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
    whiptail --title "STEP 09 - Missing config" \
             --msgbox "${msg}" 15 70
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

    if whiptail --title "STEP 09 - reuse local qcow2" --yesno "${msg}" 18 80; then
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
      log "[STEP 09] Running sha1sum -c ${sha1}"

      (
        cd "${dl_img_dir}" || exit 2

        if ! sha1sum -c "${sha1}"; then
          log "[WARN] sha1sum failed or format error."

          if whiptail --title "STEP 09 - sha1 verification failed" \
                      --yesno "sha1 verification failed.\n\nProceed anyway?\n\n[Yes] continue\n[No] stop STEP 09" 14 80
          then
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
    echo "STEP 09 execution summary"
    echo "----------------------"
    echo
    echo "# Download directory: ${dl_img_dir}"
    ls -lh "${dl_img_dir}" 2>/dev/null || echo "(directory missing or inaccessible)"
    echo
    echo "# Config values used"
    echo "  - DP_VERSION   = ${ver}"
    echo "  - ACPS_USERNAME= ${acps_user}"
    echo "  - ACPS_BASE_URL= ${acps_url}"
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
      if ! whiptail --title "${step_name} - ${vm_name} redeploy confirmation" \
                    --defaultno \
                    --yesno "${msg}" 18 80; then
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

###############################################################################
# DL / DA VM memory setting (GB) – user input
###############################################################################
prompt_vm_memory() {
  # If config has values use them; otherwise use defaults shown (e.g., 156/80)
  local default_dl="${DL_MEM_GB:-156}"
  local default_da="${DA_MEM_GB:-80}"

  local dl_input da_input

  if command -v whiptail >/dev/null 2>&1; then
    dl_input=$(whiptail --title "DL VM memory" \
                         --inputbox "Enter DL VM memory in GB.\n\n(Current default: ${default_dl} GB)" \
                         12 60 "${default_dl}" 3>&1 1>&2 2>&3) || return 1

    da_input=$(whiptail --title "DA VM memory" \
                         --inputbox "Enter DA VM memory in GB.\n\n(Current default: ${default_da} GB)" \
                         12 60 "${default_da}" 3>&1 1>&2 2>&3) || return 1
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

    # DRY_RUN default value guard
    local _DRY_RUN="${DRY_RUN:-0}"

    # Default configuration values (can be overridden from environment variables/config file)
    local DL_HOSTNAME="${DL_HOSTNAME:-dl-master}"
    local DL_CLUSTERSIZE="${DL_CLUSTERSIZE:-1}"

    local DL_VCPUS="${DL_VCPUS:-42}"
    local DL_MEMORY_GB="${DL_MEMORY_GB:-156}"       # in GB
    local DL_DISK_GB="${DL_DISK_GB:-500}"           # in GB

    local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"
    local DL_BRIDGE="${DL_BRIDGE:-virbr0}"

    local DL_IP="${DL_IP:-192.168.122.2}"
    local DL_NETMASK="${DL_NETMASK:-255.255.255.0}"
    local DL_GW="${DL_GW:-192.168.122.1}"
    local DL_DNS="${DL_DNS:-8.8.8.8}"

    # DP_VERSION is managed in config
    local _DP_VERSION="${DP_VERSION:-}"
    if [ -z "${_DP_VERSION}" ]; then
        whiptail --title "STEP 10 - DL deploy" --msgbox "DP_VERSION is not set.\nSet it in Settings and rerun.\nSkipping this step." 12 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DP_VERSION not set. Skipping DL-master deploy."
        return 0
    fi

    # DL image directory (same as STEP 09)
    local DL_IMAGE_DIR="${DL_INSTALL_DIR}/images"

    # mgmt interface – use STEP 01 selection if present, else assume mgt
    local MGT_NIC_NAME="${MGT_NIC:-mgt}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [ -z "${HOST_MGT_IP}" ]; then
        # Prompt if host mgt IP cannot be auto-detected
        HOST_MGT_IP="$(whiptail --title "STEP 10 - DL deploy" \
            --inputbox "Enter host management interface IP (${MGT_NIC_NAME}).\nExample: 10.4.0.210" 12 80 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${HOST_MGT_IP}" ]; then
            whiptail --title "STEP 10 - DL deploy" --msgbox "Host management IP not available.\nSkipping DL-master deploy." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HOST_MGT_IP not available. Skipping."
            return 0
        fi
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
        whiptail --title "STEP 10 - DL deploy" --msgbox "Cannot find virt_deploy_uvp_centos.sh.\nComplete STEP 09 (download script/image) first.\nSkipping this step." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] virt_deploy_uvp_centos.sh not found. Skipping."
        return 0
    fi

    # Check DL image presence → if missing set nodownload=false
    local QCOW2_PATH="${DL_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local DL_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        # If missing locally, allow script to download from ACPS
        DL_NODOWNLOAD="false"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=false."
    fi

    # Ensure DL LV is mounted on /stellar/dl
    if ! mount | grep -q "on ${DL_INSTALL_DIR} "; then
        whiptail --title "STEP 10 - DL deploy" --msgbox "${DL_INSTALL_DIR} is not mounted.\nComplete STEP 07 (LVM) and fstab setup, then rerun.\nSkipping this step." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ${DL_INSTALL_DIR} not mounted. Skipping."
        return 0
    fi

    # DL OTP: use from config or prompt/save once
    local _DL_OTP="${DL_OTP:-}"
    if [ -z "${_DL_OTP}" ]; then
        _DL_OTP="$(whiptail --title "STEP 10 - DL deploy" \
            --passwordbox "Enter OTP for DL-master (issued from ACPS)." 12 70 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${_DL_OTP}" ]; then
            whiptail --title "STEP 10 - DL deploy" --msgbox "No OTP provided. Skipping DL-master deploy." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL_OTP not provided. Skipping."
            return 0
        fi
        DL_OTP="${_DL_OTP}"
        # Save OTP (reflect in configuration)
        if type save_config >/dev/null 2>&1; then
            save_config
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
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Removing old DL-master image files in ${DL_VM_DIR} (raw/log)."
                rm -f "${DL_VM_DIR}/${DL_HOSTNAME}.raw"  >/dev/null 2>&1 || true
                rm -f "${DL_VM_DIR}/${DL_HOSTNAME}.log"  >/dev/null 2>&1 || true
            fi
        fi
    fi

    ############################################################
    # Prompt for DL memory (default = current DL_MEMORY_GB)
    ############################################################
    local _DL_MEM_INPUT
    _DL_MEM_INPUT="$(whiptail --title "STEP 10 - DL memory" \
        --inputbox "Enter memory (GB) for DL-master VM.\n\nCurrent default: ${DL_MEMORY_GB} GB" \
        12 70 "${DL_MEMORY_GB}" \
        3>&1 1>&2 2>&3)"

    # If Cancel keep default; if OK validate and apply
    if [ $? -eq 0 ] && [ -n "${_DL_MEM_INPUT}" ]; then
        # basic numeric check
        if [[ "${_DL_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DL_MEM_INPUT}" -gt 0 ]; then
            DL_MEMORY_GB="${_DL_MEM_INPUT}"
        else
            whiptail --title "STEP 10 - DL memory" \
                --msgbox "Invalid memory value.\nUsing current default (${DL_MEMORY_GB} GB)." 10 70
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

    if ! whiptail --title "STEP 10 - DL deploy" --yesno "${SUMMARY}" 24 80; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] User canceled DL-master deploy."
        return 0
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Running DL-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Command not executed (DRY_RUN=1)."
        whiptail --title "STEP 10 - DL deploy (DRY RUN)" --msgbox "DRY_RUN mode.\n\nCommand printed but not executed:\n\n${CMD}" 20 80
        # Call mark_step_done function if it exists
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    eval "${CMD}"
    local RC=$?

    if [ ${RC} -ne 0 ]; then
        whiptail --title "STEP 10 - DL deploy" --msgbox "virt_deploy_uvp_centos.sh exited with code ${RC}.\nCheck status via virsh list / virsh console ${DL_HOSTNAME}." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master deploy failed with RC=${RC}."
        return ${RC}
    fi

    # Simple validation: VM definition existence / status
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: virt_deploy script finished, but virsh dominfo ${DL_HOSTNAME} failed."
    fi

    whiptail --title "STEP 10 - DL deploy complete" --msgbox "DL-master VM deployment complete.\n\nCheck install log output and\nvirsh list / virsh console ${DL_HOSTNAME} for status." 14 80

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

    local DA_IP="${DA_IP:-192.168.122.3}"
    local DA_NETMASK="${DA_NETMASK:-255.255.255.0}"
    local DA_GW="${DA_GW:-192.168.122.1}"
    local DA_DNS="${DA_DNS:-8.8.8.8}"

    # DP_VERSION is managed in config
    local _DP_VERSION="${DP_VERSION:-}"
    if [ -z "${_DP_VERSION}" ]; then
        whiptail --title "STEP 11 - DA Deployment" --msgbox "DP_VERSION is not set.\nPlease set the DP version in the configuration menu first, then run again.\nSkipping this step." 12 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DP_VERSION not set. Skipping DA-master deploy."
        return 0
    fi


    # host mgt NIC / IP
    : "${MGT_NIC:=mgt}"
    local MGT_NIC_NAME="${MGT_NIC}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [ -z "${HOST_MGT_IP}" ]; then
        HOST_MGT_IP="$(whiptail --title "STEP 11 - DA Deployment" \
            --inputbox "Please enter the IP address of the host management (mgt) interface (${MGT_NIC_NAME}).\n(Example: 10.4.0.210)" 12 80 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${HOST_MGT_IP}" ]; then
            whiptail --title "STEP 11 - DA Deployment" --msgbox "Unable to determine host management IP.\nSkipping DA-master deployment step." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] HOST_MGT_IP not available. Skipping."
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
        whiptail --title "STEP 11 - DA Deployment" --msgbox "virt_deploy_uvp_centos.sh file not found.\n\nPlease complete STEP 09 (DP script/image download) first, then run again.\nSkipping this step." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] virt_deploy_uvp_centos.sh not found. Skipping."
        return 0
    fi

    # Check if DA image file exists → nodownload=true if exists, false otherwise
    local QCOW2_PATH="${DA_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local DA_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        DA_NODOWNLOAD="false"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=false."
    fi

    # Check if DA LV is mounted at /stellar/da
    if ! mount | grep -q "on ${DA_INSTALL_DIR} "; then
        whiptail --title "STEP 11 - DA Deployment" --msgbox "${DA_INSTALL_DIR} is not currently mounted.\n\nPlease complete STEP 07 (LVM configuration) and /etc/fstab setup first,\nthen run again.\nSkipping this step." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] ${DA_INSTALL_DIR} not mounted. Skipping."
        return 0
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
                rm -f "${DA_VM_RAW}" "${DA_VM_LOG}" 2>/dev/null || true
            else
                # Fallback in case of old layout (/stellar/da/images/da-master.raw)
                rm -f "${DA_INSTALL_DIR}/images/${DA_HOSTNAME}.raw" \
                      "${DA_INSTALL_DIR}/images/${DA_HOSTNAME}.log" 2>/dev/null || true
            fi
        fi
    fi


    ############################################################
    # DA memory size input (default = current DA_MEMORY_GB)
    ############################################################
    local _DA_MEM_INPUT
    _DA_MEM_INPUT="$(whiptail --title "STEP 11 - DA Memory Configuration" \
        --inputbox "Please enter the memory (GB) to allocate to the DA-master VM.\n\nCurrent default: ${DA_MEMORY_GB} GB" \
        12 70 "${DA_MEMORY_GB}" \
        3>&1 1>&2 2>&3)"

    if [ $? -eq 0 ] && [ -n "${_DA_MEM_INPUT}" ]; then
        if [[ "${_DA_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DA_MEM_INPUT}" -gt 0 ]; then
            DA_MEMORY_GB="${_DA_MEM_INPUT}"
        else
            whiptail --title "STEP 11 - DA Memory Configuration" \
                --msgbox "The entered memory value is invalid.\nUsing the existing default (${DA_MEMORY_GB} GB)." 10 70
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

    # Final confirmation dialog
    local SUMMARY
    SUMMARY="Deploy DA-master VM with the following settings:

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

    if ! whiptail --title "STEP 11 - DA Deployment" --yesno "${SUMMARY}" 24 80; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] User cancelled DA-master deploy."
        return 0
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Running DA-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Not executing the above command."
        whiptail --title "STEP 11 - DA Deployment (DRY RUN)" --msgbox "DRY_RUN mode.\n\nOnly printed the command below without executing it.\n\n${CMD}" 20 80
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    eval "${CMD}"
    local RC=$?

    if [ ${RC} -ne 0 ]; then
        whiptail --title "STEP 11 - DA Deployment" --msgbox "virt_deploy_uvp_centos.sh execution ended with error code ${RC}.\n\nPlease check the status using virsh list, virsh console ${DA_HOSTNAME}, etc." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master deploy failed with RC=${RC}."
        return ${RC}
    fi

    # Simple validation: VM definition existence / status
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: virt_deploy script finished, but virsh dominfo ${DA_HOSTNAME} failed."
    fi

    whiptail --title "STEP 11 - DA Deployment Complete" --msgbox "DA-master VM deployment procedure completed.\n\nPlease check the installation script output log and\nstatus using virsh list / virsh console ${DA_HOSTNAME}." 14 80

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 11. DA-master VM deployment ====="
    echo
}


###############################################################################
# STEP 12 – SR-IOV VF Passthrough + CPU Affinity + CD-ROM removal + DL data LV
###############################################################################
step_12_sriov_cpu_affinity() {
    local STEP_ID="12_sriov_cpu_affinity"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM removal + DL data LV ====="

    # Load config
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"
    local DL_VM="${DL_VM_NAME:-dl-master}"
    local DA_VM="${DA_VM_NAME:-da-master}"

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
        whiptail --title "STEP 12 - SR-IOV" --msgbox "Failed to detect SR-IOV VF PCI devices.\nPlease check STEP 03 or BIOS settings." 12 70
        log "[STEP 12] No SR-IOV VF found → aborting STEP"
        return 1
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
    # 3. CD-ROM removal (detach-disk hda --config assumed)
    ###########################################################################
    _remove_cdrom() {
        local vm="$1"
        if ! virsh dominfo "${vm}" >/dev/null 2>&1; then
            return 0
        fi
        if [[ "${_DRY}" -eq 1 ]]; then
            log "[DRY-RUN] virsh detach-disk ${vm} hda --config"
            return 0
        fi
        # Ignore failure as it's not critical
        virsh detach-disk "${vm}" hda --config >/dev/null 2>&1 || true
        log "[STEP 12] ${vm}: CD-ROM(hda) detach attempt completed"
    }

    _remove_cdrom "${DL_VM}"
    _remove_cdrom "${DA_VM}"

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
                log "[ERROR] ${vm}: virsh attach-device failed (PCI=${pci})"
                log "[ERROR] virsh message:"
                while IFS= read -r line; do
                    log "  ${line}"
                done <<< "${out}"
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

    if [[ -e "${DATA_LV}" ]]; then
        if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh attach-disk ${DL_VM} ${DATA_LV} vdb --config"
            else
                if virsh dumpxml "${DL_VM}" | grep -q "target dev='vdb'"; then
                    log "[STEP 12] ${DL_VM} already has vdb → skipping data disk attach"
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
        log "[STEP 12] ${DATA_LV} does not exist, skipping DL data disk attach"
    fi

    ###########################################################################
    # 8. DL/DA VM restart
    ###########################################################################
    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            log "[STEP 12] Requesting ${vm} start"
            (( _DRY )) || virsh start "${vm}" || log "[WARN] ${vm} start failed"
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
    if [[ "${_DRY}" -eq 0 ]]; then
        local result_file="/tmp/step12_result.txt"
        rm -f "${result_file}"

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

                show_paged "STEP 12 – SR-IOV / CPU Affinity / DL data LV validation results" "${result_file}"
        
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





menu_config() {
  while true; do
    # Load latest configuration
    load_config

    local msg
    msg="Current Configuration\n\n"
    msg+="DRY_RUN      : ${DRY_RUN}\n"
    msg+="DP_VERSION   : ${DP_VERSION}\n"
    msg+="ACPS_USER    : ${ACPS_USERNAME:-<Not Set>}\n"
        msg+="ACPS_PASSWORD: ${ACPS_PASSWORD:-<Not Set>}\n"
    msg+="ACPS_URL     : ${ACPS_BASE_URL:-<Not Set>}\n"
    msg+="MGT_NIC      : ${MGT_NIC:-<Not Set>}\n"
    msg+="CLTR0_NIC    : ${CLTR0_NIC:-<Not Set>}\n"
    msg+="DATA_SSD_LIST: ${DATA_SSD_LIST:-<Not Set>}\n"

    local choice
    choice=$(whiptail --title "XDR Installer - Configuration" \
      --menu "${msg}" 22 80 10 \
      "1" "Toggle DRY_RUN (0/1)" \
      "2" "Set DP_VERSION" \
      "3" "Set ACPS Account/Password" \
      "4" "Set ACPS URL" \
      "5" "Go Back" \
      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      "1")
        # Toggle DRY_RUN
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=1 (simulation mode).\n\nChange to DRY_RUN=0 to execute actual commands?" 12 70
          then
            DRY_RUN=0
          fi
        else
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=0 (actual execution mode).\n\nSafely change to DRY_RUN=1 (simulation mode)?" 12 70
          then
            DRY_RUN=1
          fi
        fi
        save_config
        ;;

      "2")
        # Set DP_VERSION
        local new_ver
        new_ver=$(whiptail --title "DP_VERSION Configuration" \
                           --inputbox "Enter DP version (e.g., 6.2.0)." 10 60 "${DP_VERSION}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_ver}" ]]; then
          DP_VERSION="${new_ver}"
          save_config
          whiptail --title "DP_VERSION Configuration" \
                   --msgbox "DP_VERSION has been set to ${DP_VERSION}." 8 60
        fi
        ;;

      "3")
        # ACPS account / password
        local user pass
        user=$(whiptail --title "ACPS Account Configuration" \
                        --inputbox "Enter ACPS account (ID)." 10 60 "${ACPS_USERNAME}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${user}" ]]; then
          continue
        fi

        pass=$(whiptail --title "ACPS Password Configuration" \
                        --passwordbox "Enter ACPS password.\n(This value will be saved to the config file and automatically used in STEP 09)" 10 60 "${ACPS_PASSWORD}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${pass}" ]]; then
          continue
        fi

        ACPS_USERNAME="${user}"
        ACPS_PASSWORD="${pass}"
        save_config
        whiptail --title "ACPS Account Configuration" \
                 --msgbox "ACPS_USERNAME has been set to '${ACPS_USERNAME}'." 8 70
        ;;

      "4")
        # ACPS URL
        local new_url
        new_url=$(whiptail --title "ACPS URL Configuration" \
                           --inputbox "Enter ACPS BASE URL." 10 70 "${ACPS_BASE_URL}" \
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

  local ok_msgs=()
  local warn_msgs=()
  local err_msgs=()

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
      warn_msgs+=("HWE kernel series is installed but GRUB IOMMU options may differ from installation guide. Please re-check GRUB_CMDLINE_LINUX value in /etc/default/grub.")
    fi
  else
    # Only WARN here
    warn_msgs+=("Could not find linux-image-generic-hwe-24.04 / linux-generic-hwe-24.04 packages in dpkg -l | grep hwe output. Please compare current kernel version (uname -r) with \"HWE 24.04 Installation\" section in installation guide.")
  fi



  ###############################
  # 2. NIC(mgt, cltr0) / Network
  ###############################
  if ip link show mgt >/dev/null 2>&1 && ip link show cltr0 >/dev/null 2>&1; then
    ok_msgs+=("mgt / cltr0 interface rename applied")
  else
    err_msgs+=("mgt or cltr0 interface not visible. Need to re-check 03_NIC/ifupdown configuration (udev rename and /etc/network/interfaces.d/*).")
  fi

  # Check include setting in /etc/network/interfaces
  if grep -qE '^source /etc/network/interfaces.d/\*' /etc/network/interfaces 2>/dev/null; then
    ok_msgs+=("/etc/network/interfaces include setting for /etc/network/interfaces.d/* confirmed")
  else
    warn_msgs+=("/etc/network/interfaces does not have 'source /etc/network/interfaces.d/*' line. If mgt/cltr0 individual settings are in interfaces.d/*.cfg, need to add include setting.")
  fi

  if systemctl is-active --quiet networking; then
    ok_msgs+=("ifupdown-based networking service active")
  else
    warn_msgs+=("networking service is not in active state. Please re-check ifupdown transition and /etc/network/interfaces configuration.")
  fi

  ###############################
  # 3. KVM / Libvirt
  ###############################
  if [ -c /dev/kvm ]; then
    ok_msgs+=("/dev/kvm device exists: KVM virtualization available")
  elif lsmod | egrep -q '^(kvm|kvm_intel|kvm_amd)\b'; then
    ok_msgs+=("kvm-related kernel modules loaded (based on lsmod)")
  else
    warn_msgs+=("Cannot verify kvm device (/dev/kvm) or kvm modules. May need to re-check BIOS VT-x/VT-d or KVM settings.")
  fi

  if systemctl is-active --quiet libvirtd; then
    ok_msgs+=("libvirtd service active")
  else
    err_msgs+=("libvirtd service is inactive. Please run 'sudo systemctl enable --now libvirtd' before using virsh.")
  fi

  ###############################
  # 4. Kernel tuning / KSM / Swap
  ###############################
  if sysctl vm.min_free_kbytes 2>/dev/null | grep -q '1048576'; then
    ok_msgs+=("vm.min_free_kbytes = 1048576 (OOM prevention tuning applied)")
  else
    warn_msgs+=("vm.min_free_kbytes value may differ from installation guide (1048576). Please re-check /etc/sysctl.d/*.conf settings.")
  fi

  if [[ -f /sys/kernel/mm/ksm/run ]]; then
    local ksm_run
    ksm_run=$(cat /sys/kernel/mm/ksm/run 2>/dev/null)
    if [[ "${ksm_run}" = "0" ]]; then
      ok_msgs+=("KSM disabled (run=0)")
    else
      warn_msgs+=("KSM is still enabled (run=${ksm_run}). May need /etc/default/qemu-kvm configuration and service restart.")
    fi
  fi

  if swapon --show | grep -q .; then
    warn_msgs+=("swap is still enabled. Need to comment out /swap.img and re-check swapoff status.")
  else
    ok_msgs+=("swap disabled")
  fi

  ###############################
  # 5. NTPsec
  ###############################
  if systemctl is-active --quiet ntpsec; then
    ok_msgs+=("ntpsec service active")
  else
    warn_msgs+=("ntpsec service is not active. Time synchronization issues may occur, please configure ntpsec or alternative NTP service.")
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
        warn_msgs+=("Registered in fstab but /stellar/dl or /stellar/da mount seems missing. Please check 'mount -a' or individual mounts.")
      fi
    else
      warn_msgs+=("/stellar/dl or /stellar/da directory does not exist. Need to create directory and remount.")
    fi
  else
    err_msgs+=("/etc/fstab does not have lv_dl_root / lv_da_root entries. Please refer to LVM configuration section in installation guide to modify fstab.")
  fi

  ###############################
  # 7. VM deployment status / SR-IOV / CPU pin / CD-ROM
  ###############################
  local dl_defined=0
  local da_defined=0

  if virsh dominfo dl-master >/dev/null 2>&1; then
    dl_defined=1
  fi
  if virsh dominfo da-master >/dev/null 2>&1; then
    da_defined=1
  fi

  # 7-1. VM definition existence
  if (( dl_defined == 1 && da_defined == 1 )); then
    ok_msgs+=("dl-master / da-master libvirt domain definition complete")
  elif (( dl_defined == 1 || da_defined == 1 )); then
    warn_msgs+=("Only one of dl-master or da-master is defined. Please check virt_deploy step progress.")
  else
    warn_msgs+=("dl-master / da-master domain not yet defined. This is normal if before STEP 10/11 execution.")
  fi

  # 7-2. dl-master detailed validation (only if defined)
  if (( dl_defined == 1 )); then
    # SR-IOV hostdev
    if virsh dumpxml dl-master 2>/dev/null | grep -q '<hostdev '; then
      ok_msgs+=("dl-master SR-IOV VF(hostdev) passthrough configuration detected")
    else
      warn_msgs+=("dl-master XML does not have hostdev(SR-IOV) configuration yet. If using SR-IOV, need to complete STEP 12(SR-IOV/CPU Affinity).")
    fi

    # CPU pinning(cputune)
    if virsh dumpxml dl-master 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("dl-master CPU pinning(cputune) configuration detected")
    else
      warn_msgs+=("dl-master XML does not have CPU pinning(cputune) configuration. NUMA-based vCPU placement may not be applied.")
    fi

    # CD-ROM / ISO connection status
    if virsh dumpxml dl-master 2>/dev/null | grep -q '\.iso'; then
      warn_msgs+=("dl-master XML still has ISO(.iso) file connected. Need to remove ISO using virsh change-media or XML editing.")
    else
      ok_msgs+=("dl-master ISO not connected (even if CD-ROM device remains, .iso file is not connected)")
    fi
  fi

  # 7-3. da-master detailed validation (only if defined)
  if (( da_defined == 1 )); then
    # SR-IOV hostdev
    if virsh dumpxml da-master 2>/dev/null | grep -q '<hostdev '; then
      ok_msgs+=("da-master SR-IOV VF(hostdev) passthrough configuration detected")
    else
      warn_msgs+=("da-master XML does not have hostdev(SR-IOV) configuration yet. If using SR-IOV, need to complete STEP 12(SR-IOV/CPU Affinity).")
    fi

    # CPU pinning(cputune)
    if virsh dumpxml da-master 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("da-master CPU pinning(cputune) configuration detected")
    else
      warn_msgs+=("da-master XML does not have CPU pinning(cputune) configuration. NUMA-based vCPU placement may not be applied.")
    fi

    # CD-ROM / ISO connection status
    if virsh dumpxml da-master 2>/dev/null | grep -q '\.iso'; then
      warn_msgs+=("da-master XML still has ISO(.iso) file connected. Need to remove ISO using virsh change-media or XML editing.")
    else
      ok_msgs+=("da-master ISO not connected (even if CD-ROM device remains, .iso file is not connected)")
    fi
  fi

  ###############################
  # 8. libvirt hooks / ipset status (optional but important)
  ###############################
  if [[ -f /etc/libvirt/hooks/qemu ]]; then
    ok_msgs+=("/etc/libvirt/hooks/qemu script exists")
  else
    warn_msgs+=("Could not find /etc/libvirt/hooks/qemu script. NAT and OOM restart automation may not work.")
  fi

  ###############################
  # Build summary message (error → warning → normal)
  ###############################
  local summary=""
  local ok_cnt=${#ok_msgs[@]}
  local warn_cnt=${#warn_msgs[@]}
  local err_cnt=${#err_msgs[@]}

  summary+="[Full Configuration Validation Summary]\n\n"

  # 1) Overall status one-line summary
  if (( err_cnt == 0 && warn_cnt == 0 )); then
    summary+="- All major validation items defined in installation guide are normal.\n"
    summary+="  (No critical errors/warnings)\n\n"
  elif (( err_cnt == 0 && warn_cnt > 0 )); then
    summary+="- No critical errors, but some items may differ from guide.\n"
    summary+="  Please check [WARN] items below.\n\n"
  else
    summary+="- Some items detected with status different from guide.\n"
    summary+="  Please check [ERROR] and [WARN] items below first.\n\n"
  fi

  # 2) ERROR first
  if (( err_cnt > 0 )); then
    summary+="[ERROR]\n"
    for msg in "${err_msgs[@]}"; do
      summary+="  - ${msg}\n"
    done
    summary+="\n"
  fi

  # 3) Then WARN
  if (( warn_cnt > 0 )); then
    summary+="[WARN]\n"
    for msg in "${warn_msgs[@]}"; do
      summary+="  - ${msg}\n"
    done
    summary+="\n"
  fi

  # 4) OK is not listed in detail, just one line
  if (( err_cnt == 0 && warn_cnt == 0 )); then
    summary+="[OK]\n"
    summary+="  - All validation items match installation guide.\n"
  else
    summary+="[OK]\n"
    summary+="  - Other validation items not listed above are judged to be within normal range without major issues.\n"
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
      kvm-ok 2>&1 || echo "[WARN] kvm-ok result is not OK."
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

  # 1) Generate summary
  local summary
  summary=$(build_validation_summary "${tmp_file}")

  # 2) Show summary first in msgbox
  whiptail --title "Full Configuration Validation Summary" \
           --msgbox "${summary}" 25 90

  # 3) Show full validation log in detail using less
  show_paged "Full Configuration Validation Results (Detailed Log)" "${tmp_file}"
}


#######################################
# Script usage guide (using show_paged)
#######################################
show_usage_help() {

  local msg
  msg=$'────────────────────────────────────────────────────────────
              ⭐ Stellar Cyber Open XDR Platform – KVM Installer Usage Guide ⭐
────────────────────────────────────────────────────────────


📌 **Required Information Before Use**
- This installer requires *root privileges*.
  Please follow the steps below to start:
    1) Switch to root using sudo -i
    2) Create /root/xdr-installer directory
    3) Save this script to that directory and execute
- Use **spacebar / ↓ arrow key** to move to next page in guide messages
- Press **q** to exit


────────────────────────────────────────────
① 🔰 When using immediately after Ubuntu 24.04 initial installation
────────────────────────────────────────────
- Selecting menu **1 (Full Auto Execution)** will  
  automatically execute STEP 01 → STEP 02 → STEP 03 → … in order.

- **STEP 03, STEP 05 require server reboot.**
    → After reboot, run the script again and  
       selecting menu 1 again will **automatically continue from the next step**.

────────────────────────────────────────────
② 🔧 When some installation/environment is already configured
────────────────────────────────────────────
- Menu **3 (Configuration)** allows you to set:
    • DRY_RUN (simulation mode) — default: DRY_RUN=1  
    • DP_VERSION  
    • ACPS authentication information, etc.

- After configuration, selecting menu **1** will  
  automatically proceed from "the next step that is not yet completed".

────────────────────────────────────────────
③ 🧩 When you want to run specific features or individual steps only
────────────────────────────────────────────
- Examples: DL / DA redeployment, new DP image download, etc.  
- Menu **2 (Run Specific STEP)** allows you to run only the desired step independently.

────────────────────────────────────────────
④ 🔍 After full installation completion – Configuration validation step
────────────────────────────────────────────
- After completing all installation, running menu **4 (Full Configuration Validation)** will  
  allow you to verify that the following items match the installation guide:
    • KVM configuration  
    • DL / DA VM deployment status  
    • Network / SR-IOV / Storage configuration, etc.

- If WARN messages appear during validation,  
  you can re-apply necessary settings individually from menu **2**.

────────────────────────────────────────────
                📦 Hardware and Software Requirements
────────────────────────────────────────────

● OS Requirements
  - Ubuntu Server 24.04  
  - Keep default options during installation (only add SSH activation)
  - OS recommended on separate SSD of 1.7GB or more
  - Default management network (MGT) configured with netplan

● Server Requirements (Dell R650 or higher recommended)
  - CPU: 2 × Intel Xeon Gold 6542Y  
         (Hyper-threading enabled → total 96 vCPUs)
  - Memory: 256GB or more
  - Disk configuration:
      • Ubuntu OS + DL/DA VM → 1.92TB SSD (SATA)  
      • Elastic Data Lake → total 23TB  
        (3.84TB SSD × 6, SATA)
  - NIC configuration:
      • Management/Data network: 1Gb or 10Gb  
      • Cluster network: Intel X710 or E810 Dual-Port 10/25GbE SFP28

● BIOS Requirements
  - Intel Virtualization Technology → Enabled  
  - SR-IOV Global Enable → Enabled

────────────────────────────────────────────────────────────'

  # Save content to temporary file and display with show_textbox
  local tmp_help_file="/tmp/xdr_dp_usage_help_$(date '+%Y%m%d-%H%M%S').txt"
  echo "${msg}" > "${tmp_help_file}"
  show_textbox "XDR Platform Installer Usage Guide" "${tmp_help_file}"
  rm -f "${tmp_help_file}"
}


menu_select_step_and_run() {
  local menu_items=()
  local i
  for ((i=0; i<NUM_STEPS; i++)); do
    menu_items+=("$i" "${STEP_NAMES[$i]}")
  done

  local choice
  choice=$(whiptail --title "XDR Installer - Select Step to Run" \
                    --menu "Select step to execute:" 20 80 10 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3) || return 0

  run_step "${choice}"
}

menu_auto_continue_from_state() {
  local next_idx
  next_idx=$(get_next_step_index)

  if (( next_idx >= NUM_STEPS )); then
    whiptail --title "XDR Installer" \
             --msgbox "All steps are already completed.\n\nSTATE_FILE: ${STATE_FILE}" 10 70
    return 0
  fi

  local next_step_name="${STEP_NAMES[$next_idx]}"

  if ! whiptail --title "XDR Installer - Auto Continue" \
                --yesno "From current state, the next step is:\n\n${next_step_name}\n\nExecute from this step sequentially?" 15 70
  then
    # No / Cancel → cancel auto continue, return to main menu (not an error)
    log "User cancelled auto continue."
    return 0
  fi

  local i
  for ((i=next_idx; i<NUM_STEPS; i++)); do
    if ! run_step "$i"; then
      whiptail --title "XDR Installer" \
               --msgbox "STEP execution stopped.\n\nPlease check the log (${LOG_FILE}) for details." 10 70
      break
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

        choice=$(whiptail --title "XDR Installer Main Menu" \
          --menu "${status_msg}\n\nDRY_RUN=${DRY_RUN}, DP_VERSION=${DP_VERSION}, ACPS_BASE_URL=${ACPS_BASE_URL}\nSTATE_FILE=${STATE_FILE}" \
          20 90 10 \
          "1" "Auto execute all steps (continue from next step based on current state)" \
          "2" "Select and run specific step only" \
          "3" "Configuration (DRY_RUN, DP_VERSION, etc.)" \
          "4" "Full configuration validation" \
          "5" "Script usage guide" \
          "6" "Exit" \
		  3>&1 1>&2 2>&3) || choice="6"
          


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
            ;;
        esac


  done
}


#######################################
# Entry point
#######################################

main_menu