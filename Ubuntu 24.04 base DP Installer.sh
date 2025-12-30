#!/usr/bin/env bash
#
# XDR Install Framework (SSH + Whiptail based TUI)
# Version: 0.1 (skeleton)
# Only basic framework is implemented, actual logic for each STEP is still DRY-RUN.

set -euo pipefail

#######################################
# Basic Configuration
#######################################

BASE_DIR="/root/xdr-installer"
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
  "06_ntpsec"
  "07_lvm_storage"
  "08_libvirt_hooks"
  "09_dp_download"
  "10_dl_master_deploy"
  "11_da_master_deploy"
  "12_sriov_cpu_affinity"
  "13_install_dp_cli"    
)

# STEP Names (descriptions displayed in UI)
STEP_NAMES=(
  "01. Hardware / NIC / Disk Detection and Selection"
  "02. HWE Kernel Installation"
  "03. NIC Naming/ifupdown Transition and Network Configuration"
  "04. KVM / Libvirt Installation and Basic Configuration"
  "05. Kernel Parameters / KSM / Swap Tuning"
  "06. SR-IOV Driver (iavf/i40evf) + NTPsec Configuration"
  "07. LVM Storage (DL/DA root + data)"
  "08. libvirt hooks and OOM Recovery Scripts"
  "09. DP Image and Deployment Script Download"
  "10. DL-master VM Deployment"
  "11. DA-master VM Deployment"
  "12. SR-IOV / CPU Affinity / PCI Passthrough"
  "13. Install DP Appliance CLI package"   
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
#   1) When passing content directly: show_paged "$big_message"
#   2) When passing title + file: show_paged "Title" "/path/to/file"
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

  # --- Argument processing (set -u environment safe) ---
  if [[ $# -eq 1 ]]; then
    # ① When only one argument: content string only case
    title="XDR Installer Guide"
    tmpfile=$(mktemp)
    printf "%s\n" "$1" > "$tmpfile"
    file="$tmpfile"
  elif [[ $# -ge 2 ]]; then
    # ② When two or more arguments: 1 = title, 2 = file path
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
  echo -e "${GREEN}※ Space/↓: Next page, ↑: Previous, q: Quit${RESET}"
  echo

  # --- Less protection from here: prevent exit from set -e ---
  set +e
  less -R "${file}"
  local rc=$?
  set -e
  # ----------------------------------------------------

  # In single argument mode, we created a tmpfile, so remove it if it exists
  [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"

  # Always consider it "success" regardless of less return code
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
    eval "${cmd}"
  fi
}

append_fstab_if_missing() {
  local line="$1"
  local mount_point="$2"

  if grep -qE"[[:space:]]${mount_point}[[:space:]]" /etc/fstab 2>/dev/null; then
    log "fstab: ${mount_point} entry already exists. (skipping addition)"
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
# Configuration Management (CONFIG_FILE)
#######################################

# CONFIG_FILE is assumed to be already defined above
# Example: CONFIG_FILE="${STATE_DIR}/xdr-installer.conf"
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
  fi

  # Default values (set only when not present)
  : "${DRY_RUN:=1}"  # Default is DRY_RUN=1 (safe mode)
  : "${DP_VERSION:=6.2.1}"
  : "${ACPS_USERNAME:=}"
  : "${ACPS_BASE_URL:=https://apsdev.stellarcyber.aihttps://acps.stellarcyber.ai}"
  : "${ACPS_PASSWORD:=}"

  # Auto-reboot related default values
  : "${ENABLE_AUTO_REBOOT:=1}"
  : "${AUTO_REBOOT_AFTER_STEP_ID:="03_nic_ifupdown 05_kernel_tuning"}"

  # Set default values for NIC / disk selection to ensure they are always defined
  : "${MGT_NIC:=}"
  : "${CLTR0_NIC:=}"
  : "${HOST_NIC:=}"  
  : "${DATA_SSD_LIST:=}"

  # [Additional] Variable initialization (to prevent set -u errors)
  : "${DL_MEMORY_GB:=}"
  : "${DA_MEMORY_GB:=}"
  : "${DL_HOSTNAME:=}"
  : "${DA_HOSTNAME:=}"  
  
}


save_config() {
  # Create directory for CONFIG_FILE
  mkdir -p "$(dirname "${CONFIG_FILE}")"

  # Replace " inside values with \" (to prevent config file corruption)
  local esc_dp_version esc_acps_user esc_acps_pass esc_acps_url
  esc_dp_version=${DP_VERSION//\"/\\\"}
  esc_acps_user=${ACPS_USERNAME//\"/\\\"}
  esc_acps_pass=${ACPS_PASSWORD//\"/\\\"}
  esc_acps_url=${ACPS_BASE_URL//\"/\\\"}

  # ★ Also escape NIC / disk values
  local esc_mgt_nic esc_cltr0_nic esc_data_ssd
  esc_mgt_nic=${MGT_NIC//\"/\\\"}
  esc_cltr0_nic=${CLTR0_NIC//\"/\\\"}
  esc_host_nic=${HOST_NIC//\"/\\\"}
  esc_data_ssd=${DATA_SSD_LIST//\"/\\\"}

  cat > "${CONFIG_FILE}" <<EOF
# xdr-installer environment configuration (auto-generated)
DRY_RUN=${DRY_RUN}
DP_VERSION="${esc_dp_version}"
ACPS_USERNAME="${esc_acps_user}"
ACPS_PASSWORD="${esc_acps_pass}"
ACPS_BASE_URL="${esc_acps_url}"
ENABLE_AUTO_REBOOT=${ENABLE_AUTO_REBOOT}
AUTO_REBOOT_AFTER_STEP_ID="${AUTO_REBOOT_AFTER_STEP_ID}"

# VM Configuration (memory, etc.)
DL_MEMORY_GB="${DL_MEMORY_GB:-}"
DA_MEMORY_GB="${DA_MEMORY_GB:-}"
DL_HOSTNAME="${DL_HOSTNAME:-}"
DA_HOSTNAME="${DA_HOSTNAME:-}"

# NIC / Disk selected in STEP 01
MGT_NIC="${esc_mgt_nic}"
CLTR0_NIC="${esc_cltr0_nic}"
HOST_NIC="${esc_host_nic}"
DATA_SSD_LIST="${esc_data_ssd}"
EOF
}


# For compatibility with existing code that may call save_config_var
# Update variables internally and call save_config() again to maintain compatibility
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

    # ★ Add here
    MGT_NIC)        MGT_NIC="${value}" ;;
    CLTR0_NIC)      CLTR0_NIC="${value}" ;;
    HOST_NIC)       HOST_NIC="${value}" ;;	
    DATA_SSD_LIST)  DATA_SSD_LIST="${value}" ;;

	DL_MEMORY_GB)   DL_MEMORY_GB="${value}" ;;
    DA_MEMORY_GB)   DA_MEMORY_GB="${value}" ;;
    DL_HOSTNAME)    DL_HOSTNAME="${value}" ;;
    DA_HOSTNAME)    DA_HOSTNAME="${value}" ;;	
	
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
    log "User canceled execution of STEP ${step_id}."
    return 0   # Must return 0 here so set -e doesn't trigger in the main case statement
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

  if [[ "${rc}" -eq 0 ]]; then
    log "===== STEP DONE: ${step_id} - ${step_name} ====="
    save_state "${step_id}"

    ###############################################
    # Common Auto-Reboot Processing
    ###############################################
    if [[ "${ENABLE_AUTO_REBOOT}" -eq 1 ]]; then
      # Process AUTO_REBOOT_AFTER_STEP_ID to allow multiple STEP IDs separated by spaces
      for reboot_step in ${AUTO_REBOOT_AFTER_STEP_ID}; do
        if [[ "${step_id}" == "${reboot_step}" ]]; then
          log "AUTO_REBOOT_AFTER_STEP_ID=${AUTO_REBOOT_AFTER_STEP_ID} (current STEP=${step_id}) is included → performing auto-reboot."

          whiptail --title "Auto Reboot" \
                   --msgbox "STEP ${step_id} (${step_name}) has been completed successfully.\n\nThe system will automatically reboot." 12 70

          if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "[DRY-RUN] Auto-reboot will not be performed."
            # If DRY_RUN, just exit here and continue to return 0 below
          else
            reboot
            # ★ Added here: immediately exit the entire shell session when reboot is called
            exit 0
          fi

          # If reboot was processed for this STEP, no need to check other items
          break
        fi
      done
    fi
  else
    log "===== STEP FAILED (rc=${rc}): ${step_id} - ${step_name} ====="
    whiptail --title "STEP Failed - ${step_id}" \
             --msgbox "An error occurred while executing STEP ${step_id} (${step_name}).\n\nPlease check the logs and re-run the STEP if necessary.\nThe installer can continue to run." 14 80
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

list_disk_candidates() {
  # Exclude physical disks that have root mounted
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
# [NEW] PDF Guide Based UEFI/XML Conversion and Partition Expansion Function
#######################################
apply_pdf_xml_patch() {
    local vm_name="$1"
    local mem_kb="$2"
    local vcpu="$3"
    local bridge_name="$4"
    local disk_path="$5"

    log "[PATCH] ${vm_name} :: Starting PDF guide based UEFI/XML conversion and Cloud-Init application"

    # 1. Stop VM and undefine existing definition
    run_cmd "virsh destroy ${vm_name} || true"
    run_cmd "virsh undefine ${vm_name} --nvram || virsh undefine ${vm_name} || true"

    # 2. Disk format conversion (QCOW2 -> RAW)
    # virt_deploy script may have created .qcow2 file (or file without extension)
    local qcow_disk="${disk_path%.*}.qcow2"
    # If raw file doesn't exist and only qcow2 exists, perform conversion
    if [[ ! -f "${disk_path}" ]] && [[ -f "${qcow_disk}" ]]; then
        log "[PATCH] Converting QCOW2 -> RAW... (${qcow_disk} -> ${disk_path})"
        run_cmd "qemu-img convert -f qcow2 -O raw ${qcow_disk} ${disk_path}"
        # Delete original qcow2 (to free up space)
        run_cmd "rm -f ${qcow_disk}"
    elif [[ -f "${disk_path}" ]]; then
        log "[PATCH] RAW file already exists, skipping conversion: ${disk_path}"
    else
        log "[ERROR] Could not find original disk image to convert."
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


    # 5. Create UEFI XML (reflects PDF content + Bridge + Raw Disk + Cloud-Init ISO)
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
# DRY-RUN Skeleton Implementation for Each STEP
# (Actual logic is not yet implemented here)
#######################################

step_01_hw_detect() {
  log "[STEP 01] Hardware / NIC / Disk Detection and Selection"

  # Load latest configuration (so script doesn't fail if it doesn't exist)
  if type load_config >/dev/null 2>&1; then
    load_config
  fi

  # Set default values to prevent set -u errors (empty string if not defined)
  : "${MGT_NIC:=}"
  : "${CLTR0_NIC:=}"
  : "${HOST_NIC:=}"
  : "${DATA_SSD_LIST:=}"

  ########################
  # 0) Reuse existing values
  ########################
  if [[ -n "${MGT_NIC}" && -n "${CLTR0_NIC}" && -n "${HOST_NIC}" && -n "${DATA_SSD_LIST}" ]]; then
    if whiptail --title "STEP 01 - Reuse Existing Selection" \
                --yesno "The following values are already set:\n\n- MGT_NIC: ${MGT_NIC}\n- CLTR0_NIC: ${CLTR0_NIC}\n- HOST_NIC: ${HOST_NIC}\n- DATA_SSD_LIST: ${DATA_SSD_LIST}\n\nDo you want to reuse these values and skip STEP 01?\n\n(Selecting No will allow you to reselect NIC/disk.)" 19 80
    then
      log "User chose to reuse existing STEP 01 selection values. (Skipping STEP 01)"

      # Ensure values are reflected in config file when reusing
      save_config_var "MGT_NIC"       "${MGT_NIC}"
      save_config_var "CLTR0_NIC"     "${CLTR0_NIC}"
      save_config_var "HOST_NIC"      "${HOST_NIC}"
      save_config_var "DATA_SSD_LIST" "${DATA_SSD_LIST}"

      # Reuse is 'success + nothing more to do in this step', so return 0 normally
      return 0
    fi
  fi


  ########################
  # 1) Query NIC candidates
  ########################
  local nics nic_list nic name idx

  # Defensive: prevent script from dying due to set -e even if list_nic_candidates fails
  nics="$(list_nic_candidates || true)"

  if [[ -z "${nics}" ]]; then
    whiptail --title "STEP 01 - NIC Detection Failed" \
             --msgbox "Could not find available NICs.\n\nPlease check ip link results and modify the script if necessary." 12 70
    log "No NIC candidates. Need to check ip link results."
    return 1
  fi

  nic_list=()
  idx=0
  while IFS= read -r name; do
    # Display IP information assigned to each NIC + ethtool Speed/Duplex
    local ipinfo speed duplex et_out tmp_speed tmp_duplex

    # IP information
    ipinfo=$(ip -o addr show dev "${name}" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [[ -z "${ipinfo}" ]] && ipinfo="(no ip)"

    # Default values
    speed="Unknown"
    duplex="Unknown"

    # Get Speed / Duplex using ethtool
    if command -v ethtool >/dev/null 2>&1; then
      # set -e defense: prevent script from dying even if ethtool fails || true
      et_out=$(ethtool "${name}" 2>/dev/null || true)

      # Speed:
      tmp_speed=$(printf '%s\n' "${et_out}" | awk -F': ' '/Speed:/ {print $2; exit}')
      [[ -n "${tmp_speed}" ]] && speed="${tmp_speed}"

      # Duplex:
      tmp_duplex=$(printf '%s\n' "${et_out}" | awk -F': ' '/Duplex:/ {print $2; exit}')
      [[ -n "${tmp_duplex}" ]] && duplex="${tmp_duplex}"
    fi

    # Display in whiptail menu as "speed=..., duplex=..., ip=..." format
    nic_list+=("${name}" "speed=${speed}, duplex=${duplex}, ip=${ipinfo}")
    ((idx++))
  done <<< "${nics}"

  ########################
  # 2) Select mgt NIC
  ########################
  local mgt_nic
  mgt_nic=$(whiptail --title "STEP 01 - Select mgt NIC" \
                     --menu "Select service (mgt) NIC.\nCurrent setting: ${MGT_NIC:-<none>}" \
                     20 80 10 \
                     "${nic_list[@]}" \
                     3>&1 1>&2 2>&3) || {
    log "User canceled mgt NIC selection."
    return 1
  }

  log "Selected mgt NIC: ${mgt_nic}"
  MGT_NIC="${mgt_nic}"
  save_config_var "MGT_NIC" "${MGT_NIC}"

  ########################
  # 3) Select cltr0 NIC
  ########################
  # Selecting the same NIC as mgt NIC is not recommended, so inform via message
  local cltr0_nic
  cltr0_nic=$(whiptail --title "STEP 01 - Select cltr0 NIC" \
                       --menu "Select cluster/SR-IOV (cltr0) NIC.\n\nIt is recommended to choose a different NIC from mgt NIC.\nCurrent setting: ${CLTR0_NIC:-<none>}" \
                       20 80 10 \
                       "${nic_list[@]}" \
                       3>&1 1>&2 2>&3) || {
    log "User canceled cltr0 NIC selection."
    return 1
  }

  if [[ "${cltr0_nic}" == "${mgt_nic}" ]]; then
    if ! whiptail --title "Warning" \
                  --yesno "mgt NIC and cltr0 NIC are the same.\nThis configuration is not recommended.\nDo you still want to continue?" 12 70
    then
      log "User canceled same NIC usage configuration."
      return 1
    fi
  fi

  log "Selected cltr0 NIC: ${cltr0_nic}"
  CLTR0_NIC="${cltr0_nic}"
  save_config_var "CLTR0_NIC" "${CLTR0_NIC}"

  ########################
  # 3-1) Select HOST access NIC (for direct KVM host access only)
  ########################
  local host_nic
  host_nic=$(whiptail --title "STEP 01 - Select Host Access NIC" \
                      --menu "Select NIC for direct access (management) to KVM host.\n(This NIC will be automatically configured with 192.168.0.100/24 without gateway.)\n\nCurrent setting: ${HOST_NIC:-<none>}" \
                      22 90 10 \
                      "${nic_list[@]}" \
                      3>&1 1>&2 2>&3) || {
    log "User canceled HOST_NIC selection."
    return 1
  }

  # Prevent duplicates (same NIC as mgt/cltr0 is not allowed)
  if [[ "${host_nic}" == "${MGT_NIC}" || "${host_nic}" == "${CLTR0_NIC}" ]]; then
    whiptail --title "Error" \
             --msgbox "HOST_NIC cannot be the same as MGT_NIC or CLTR0_NIC.\n\n- MGT_NIC : ${MGT_NIC}\n- CLTR0_NIC: ${CLTR0_NIC}\n- HOST_NIC : ${host_nic}" 12 80
    log "HOST_NIC duplicate selection: ${host_nic}"
    return 1
  fi

  log "Selected HOST_NIC: ${host_nic}"
  HOST_NIC="${host_nic}"
  save_config_var "HOST_NIC" "${HOST_NIC}"

  ########################
  # 4) Select data SSDs
  ########################

  # Initialize variables
  local root_info="OS Disk: Detection failed (verification needed)"
  local disk_list=()
  local all_disks

  # Query all physical disks (exclude loop, ram, etc., only disk type)
  # Output format: NAME SIZE MODEL TYPE
  all_disks=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1, $2, $3}')

  if [[ -z "${all_disks}" ]]; then
    whiptail --title "STEP 01 - Disk Detection Failed" \
             --msgbox "Could not find physical disks in the system.\nPlease check the lsblk command." 12 70
    return 1
  fi

  # Iterate through disks
  while read -r d_name d_size d_model; do
    # Check if any partition/volume under this disk (/dev/d_name) is mounted to / (root)
    if lsblk "/dev/${d_name}" -r -o MOUNTPOINT | grep -qE "^/$"; then
      # [OS disk found] -> Don't add to list, store in top info message variable
      root_info="OS Disk: ${d_name} (${d_size}) ${d_model} -> Ubuntu Linux (excluded from list)"
    else
      # [Data disk candidate]
      local flag="OFF"
      for selected in ${DATA_SSD_LIST}; do
        if [[ "${selected}" == "${d_name}" ]]; then
          flag="ON"
          break
        fi
      done
      disk_list+=("${d_name}" "${d_size}_${d_model}" "${flag}")
    fi
  done <<< "${all_disks}"

  # If no data disk candidates found
  if [[ ${#disk_list[@]} -eq 0 ]]; then
    whiptail --title "Warning" \
             --msgbox "No additional disks available for data use.\n\nDetected OS disk:\n${root_info}" 12 70
    return 1
  fi

  # Compose guide message
  local msg_guide="Select disks to use for LVM/ES data.\n(Space: select/deselect, Enter: confirm)\n\n"
  msg_guide+="==================================================\n"
  msg_guide+=" [System Protection] ${root_info}\n"
  msg_guide+="==================================================\n\n"
  msg_guide+="Select data disks from the list below:"

  local selected_disks
  selected_disks=$(whiptail --title "STEP 01 - Select Data Disks" \
                            --checklist "${msg_guide}" \
                            22 85 10 \
                            "${disk_list[@]}" \
                            3>&1 1>&2 2>&3) || {
    log "User canceled disk selection."
    return 1
  }

  # whiptail output is "sdb" "sdc" format → remove quotes
  selected_disks=$(echo "${selected_disks}" | tr -d '"')

  if [[ -z "${selected_disks}" ]]; then
    whiptail --title "Warning" \
             --msgbox "No disks selected.\nLVM configuration cannot proceed in this state." 10 70
    log "No data disks selected."
    return 1
  fi

  log "Selected data disks: ${selected_disks}"
  DATA_SSD_LIST="${selected_disks}"
  save_config_var "DATA_SSD_LIST" "${DATA_SSD_LIST}"

  ########################
  # 5) Display summary
  ########################
  local summary
  summary=$(cat <<EOF
[STEP 01 Result Summary]

- mgt NIC      : ${MGT_NIC}
- cltr0 NIC    : ${CLTR0_NIC}
- host NIC     : ${HOST_NIC} (will set 192.168.0.100/24, no gateway in STEP 03)
- Data Disks   : ${DATA_SSD_LIST}

Config file: ${CONFIG_FILE}
EOF
)

  whiptail --title "STEP 01 Complete" \
           --msgbox "${summary}" 18 80

  # Save once more as a precaution
  if type save_config >/dev/null 2>&1; then
    save_config
  fi

  # This STEP completed successfully, so state will be saved by save_state in the caller
}



step_02_hwe_kernel() {
  log "[STEP 02] HWE Kernel Installation"
  load_config

  local pkg_name="linux-generic-hwe-24.04"
  local tmp_status="/tmp/xdr_step02_status.txt"

  #######################################
  # 0) Check current kernel / package status
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
    echo "${pkg_name} installation status: ${hwe_installed}"
    echo
    echo "This STEP will perform the following tasks:"
    echo "  1) apt update"
    echo "  2) apt full-upgrade -y"
    echo "  3) ${pkg_name} installation (skip if already installed)"
    echo
    echo "New HWE kernel will be applied on next host reboot."
    echo "This script is configured to automatically reboot the host"
    echo "only once after STEP 05 (kernel tuning) is completed."
  } > "${tmp_status}"


  # ... After calculating cur_kernel, hwe_installed, show overview textbox, then add ...

  if [[ "${hwe_installed}" == "yes" ]]; then
    if ! whiptail --title "STEP 02 - HWE Kernel Already Installed" \
                  --yesno "linux-generic-hwe-24.04 package is already installed..." 18 80
    then
      log "User chose to skip STEP 02 entirely based on 'already installed' judgment."
      save_state "02_hwe_kernel"
      return 0
    fi
  fi
  

  show_textbox "STEP 02 - HWE Kernel Installation Overview" "${tmp_status}"

  if ! whiptail --title "STEP 02 Execution Confirmation" \
                 --yesno "Do you want to proceed with the above tasks?\n\n(Yes: Continue / No: Cancel)" 12 70
  then
    log "User canceled STEP 02 execution."
    return 0
  fi


  #######################################
  # 1) apt update / full-upgrade
  #######################################
  log "[STEP 02] Executing apt update / full-upgrade"
  run_cmd "sudo apt update"
  run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y"

  #######################################
  # 2) HWE Kernel Package Installation
  #######################################
  if [[ "${hwe_installed}" == "yes" ]]; then
    log "[STEP 02] ${pkg_name} package is already installed → skipping installation step"
  else
    log "[STEP 02] Installing ${pkg_name} package"
    run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt install -y ${pkg_name}"
  fi

  #######################################
  # 3) Post-installation status summary
  #######################################
  local new_kernel hwe_now
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # In DRY-RUN mode, no actual installation is performed, so use existing values for both uname -r and installation status
    new_kernel="${cur_kernel}"
    hwe_now="${hwe_installed}"
  else
    # In actual execution mode, check current kernel version and HWE package installation status again
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
    echo "${pkg_name} installation status (current): ${hwe_now}"
    echo
    echo "※ New HWE kernel will be applied on 'next host reboot'."
    echo "   (Current uname -r output may not change as it's before reboot.)"
    echo
    echo "※ This script will automatically reboot the host only once"
    echo "   when STEP 05 (kernel tuning) is completed,"
    echo "   according to AUTO_REBOOT_AFTER_STEP_ID setting."
  } > "${tmp_status}"


  show_textbox "STEP 02 Result Summary" "${tmp_status}"

  # Reboot itself is performed only once when STEP 05 is completed, by common logic (AUTO_REBOOT_AFTER_STEP_ID)
  log "[STEP 02] HWE kernel installation step completed. New HWE kernel will be applied on next host reboot."

  return 0
}


step_03_nic_ifupdown() {
  log "[STEP 03] NIC Naming/ifupdown Transition and Network Configuration"
  load_config

  # Must use :- form to prepare for set -u environment
  if [[ -z "${MGT_NIC:-}" || -z "${CLTR0_NIC:-}" || -z "${HOST_NIC:-}" ]]; then
    whiptail --title "STEP 03 - NIC Not Configured" \
             --msgbox "MGT_NIC or CLTR0_NIC or HOST_NIC is not set.\n\nYou must first select NICs in STEP 01." 12 70
    log "MGT_NIC or CLTR0_NIC or HOST_NIC is empty, cannot proceed with STEP 03. Skipping STEP 03."
    return 0   # Skip only this STEP and let installer continue
  fi

  #######################################
  # 0) Check current NIC/PCI information
  #######################################
  local mgt_pci cltr0_pci host_pci
  mgt_pci=$(readlink -f "/sys/class/net/${MGT_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
  cltr0_pci=$(readlink -f "/sys/class/net/${CLTR0_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')
  host_pci=$(readlink -f "/sys/class/net/${HOST_NIC}/device" 2>/dev/null | awk -F'/' '{print $NF}')

  if [[ -z "${mgt_pci}" || -z "${cltr0_pci}" || -z "${host_pci}" ]]; then
    whiptail --title "STEP 03 - PCI Information Error" \
             --msgbox "Could not retrieve PCI bus information for selected NICs.\n\nNeed to check /sys/class/net/${MGT_NIC}/device or /sys/class/net/${CLTR0_NIC}/device or /sys/class/net/${HOST_NIC}/device." 12 70
    log "MGT_NIC=${MGT_NIC}(${mgt_pci}), CLTR0_NIC=${CLTR0_NIC}(${cltr0_pci}), HOST_NIC=${HOST_NIC}(${host_pci}) → Insufficient PCI information."
    return 1
  fi

  local tmp_pci="/tmp/xdr_step03_pci.txt"
  {
    echo "Selected NIC and PCI Information"
    echo "----------------------"
    echo "MGT_NIC   : ${MGT_NIC}"
    echo "  -> PCI  : ${mgt_pci}"
    echo
    echo "CLTR0_NIC : ${CLTR0_NIC}"
    echo "  -> PCI  : ${cltr0_pci}"
    echo
    echo "HOST_NIC  : ${HOST_NIC}"
    echo "  -> PCI  : ${host_pci}"
  } > "${tmp_pci}"

  show_textbox "STEP 03 - NIC/PCI Verification" "${tmp_pci}"

  #######################################
  # Roughly determine if desired network configuration already exists
  #######################################
  local maybe_done=0
  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local iface_file="/etc/network/interfaces"
  local host_cfg="/etc/network/interfaces.d/02-hostmgmt.cfg"

  if [[ -f "${udev_file}" ]] && \
     grep -q "KERNELS==\"${mgt_pci}\".*NAME:=\"mgt\"" "${udev_file}" 2>/dev/null && \
     grep -q "KERNELS==\"${cltr0_pci}\".*NAME:=\"cltr0\"" "${udev_file}" 2>/dev/null && \
     grep -q "KERNELS==\"${host_pci}\".*NAME:=\"hostmgmt\"" "${udev_file}" 2>/dev/null; then
    if [[ -f "${iface_file}" ]] && \
       grep -q "^auto mgt" "${iface_file}" 2>/dev/null && \
       grep -q "iface mgt inet static" "${iface_file}" 2>/dev/null && \
       [[ -f "${host_cfg}" ]] && \
       grep -q "^auto hostmgmt" "${host_cfg}" 2>/dev/null && \
       grep -q "address 192\.168\.0\.100" "${host_cfg}" 2>/dev/null; then
      maybe_done=1
    fi
  fi

  if [[ "${maybe_done}" -eq 1 ]]; then
    if whiptail --title "STEP 03 - Already Configured" \
                --yesno "Looking at udev rules and /etc/network/interfaces, hostmgmt settings, it appears to be already configured.\n\nDo you want to skip this STEP?" 18 80
    then
      log "User chose to skip STEP 03 entirely based on 'already configured' judgment."
      return 0
    fi
    log "User chose to force re-execution of STEP 03."
  fi

  #######################################
  # 1) Collect mgt IP configuration values (default values extracted from current settings)
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
  # DNS default value is fixed according to documentation: 8.8.8.8 8.8.4.4
  cur_dns="8.8.8.8 8.8.4.4"

  # IP Address
  local new_ip
  new_ip=$(whiptail --title "STEP 03 - mgt IP Configuration" \
                    --inputbox "Enter IP address for mgt interface.\nExample: 10.4.0.210" \
                    10 60 "${cur_ip}" \
                    3>&1 1>&2 2>&3) || return 0

  # Prefix
  local new_prefix
  new_prefix=$(whiptail --title "STEP 03 - mgt Prefix" \
                        --inputbox "Enter subnet prefix (/value).\nExample: 24" \
                        10 60 "${cur_prefix}" \
                        3>&1 1>&2 2>&3) || return 0

  # Gateway
  local new_gw
  new_gw=$(whiptail --title "STEP 03 - Gateway" \
                    --inputbox "Enter default gateway IP.\nExample: 10.4.0.254" \
                    10 60 "${cur_gw}" \
                    3>&1 1>&2 2>&3) || return 0

  # DNS
  local new_dns
  new_dns=$(whiptail --title "STEP 03 - DNS" \
                     --inputbox "Enter DNS servers separated by spaces.\nExample: 8.8.8.8 8.8.4.4" \
                     10 70 "${cur_dns}" \
                     3>&1 1>&2 2>&3) || return 0

  # Simple prefix → netmask conversion (only handles a few representative values)
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
      netmask=$(whiptail --title "STEP 03 - Enter Netmask Directly" \
                         --inputbox "Unknown prefix: /${new_prefix}.\nPlease enter netmask directly.\nExample: 255.255.255.0" \
                         10 70 "255.255.255.0" \
                         3>&1 1>&2 2>&3) || return 1
      ;;
  esac

  #######################################
  # 2) Create udev 99-custom-ifnames.rules
  #######################################
  log "[STEP 03] Creating /etc/udev/rules.d/99-custom-ifnames.rules"

  local udev_file="/etc/udev/rules.d/99-custom-ifnames.rules"
  local udev_bak="${udev_file}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ -f "${udev_file}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${udev_file}" "${udev_bak}"
    log "Backed up existing ${udev_file}: ${udev_bak}"
  fi

  local udev_content
  udev_content=$(cat <<EOF
# Management & Cluster & HostMgmt Interface custom names (auto-generated)
# MGT_NIC=${MGT_NIC}, PCI=${mgt_pci}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${mgt_pci}", NAME:="mgt"

# Cluster Interface PCI-bus ${cltr0_pci}, Create 2 SR-IOV VFs
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${cltr0_pci}", NAME:="cltr0", ATTR{device/sriov_numvfs}="2"

# Host direct management interface (no gateway) PCI-bus ${host_pci}
ACTION=="add", SUBSYSTEM=="net", KERNELS=="${host_pci}", NAME:="hostmgmt"
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] rm -f ${udev_file}"
    log "[DRY-RUN] Will write the following content to ${udev_file}:\n${udev_content}"
  else
    rm -f "${udev_file}"
    printf "%s\n" "${udev_content}" > "${udev_file}"
  fi

  # udev reload
  run_cmd "sudo udevadm control --reload"
  run_cmd "sudo udevadm trigger --type=devices --action=add"

  # Apply initramfs
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo update-initramfs -u"
  else
    log "[STEP 03] Updating initramfs... (this may take a while)"
    run_cmd "sudo update-initramfs -u"
  fi

  #######################################
  # 3) Create /etc/network/interfaces (mgt)
  #######################################
  log "[STEP 03] Creating /etc/network/interfaces"

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
    log "[DRY-RUN] Will write the following content to ${iface_file}:\n${iface_content}"
  else
    printf "%s\n" "${iface_content}" > "${iface_file}"
  fi

  #######################################
  # 3-1) Create /etc/network/interfaces.d/02-hostmgmt.cfg (hostmgmt, no gateway, fixed IP)
  #######################################
  log "[STEP 03] Creating /etc/network/interfaces.d/02-hostmgmt.cfg (hostmgmt: 192.168.0.100/24, no gateway)"

  local iface_dir="/etc/network/interfaces.d"
  local host_cfg="${iface_dir}/02-hostmgmt.cfg"
  local host_bak="${host_cfg}.$(date +%Y%m%d-%H%M%S).bak"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${iface_dir}"
  fi

  if [[ -f "${host_cfg}" && "${DRY_RUN}" -eq 0 ]]; then
    cp -a "${host_cfg}" "${host_bak}"
    log "Backed up existing ${host_cfg}: ${host_bak}"
  fi

  local host_content
  host_content=$(cat <<EOF
# Host direct management interface (no gateway)
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

  #######################################
  # 4) Create /etc/network/interfaces.d/00-cltr0.cfg
  #######################################
  log "[STEP 03] Creating /etc/network/interfaces.d/00-cltr0.cfg"

  local cltr0_cfg="${iface_dir}/00-cltr0.cfg"
  local cltr0_bak="${cltr0_cfg}.$(date +%Y%m%d-%H%M%S).bak"

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
    log "[DRY-RUN] Will write the following content to ${cltr0_cfg}:\n${cltr0_content}"
  else
    printf "%s\n" "${cltr0_content}" > "${cltr0_cfg}"
  fi

  #######################################
  # 5) Register rt_mgt in /etc/iproute2/rt_tables
  #######################################
  log "[STEP 03] Registering rt_mgt in /etc/iproute2/rt_tables"

  local rt_file="/etc/iproute2/rt_tables"
  if [[ ! -f "${rt_file}" && "${DRY_RUN}" -eq 0 ]]; then
    touch "${rt_file}"
  fi

  if grep -qE '^[[:space:]]*1[[:space:]]+rt_mgt' "${rt_file}" 2>/dev/null; then
    log "rt_tables: 1 rt_mgt entry already exists."
  else
    local rt_line="1 rt_mgt"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will append '${rt_line}' to end of ${rt_file}"
    else
      echo "${rt_line}" >> "${rt_file}"
      log "Added '${rt_line}' to ${rt_file}"
    fi
  fi

  #######################################
  # 6) Disable netplan + transition to ifupdown
  #######################################
  log "[STEP 03] Installing ifupdown and disabling netplan"

  run_cmd "sudo apt update"
  run_cmd "sudo apt install -y ifupdown net-tools"

  # Move netplan configuration files
  if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo mkdir -p /etc/netplan/disabled"
      log "[DRY-RUN] sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/"
    else
      sudo mkdir -p /etc/netplan/disabled
      sudo mv /etc/netplan/*.yaml /etc/netplan/disabled/
    fi
  else
    log "No netplan yaml files to move (may have already been moved)."
  fi

  #######################################
  # 6-1) Disable systemd-networkd / netplan services + enable legacy networking
  #######################################
  log "[STEP 03] Disabling systemd-networkd / netplan services and enabling networking service"

  run_cmd "sudo systemctl stop systemd-networkd || true"
  run_cmd "sudo systemctl disable systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd || true"
  run_cmd "sudo systemctl mask systemd-networkd-wait-online || true"
  run_cmd "sudo systemctl mask netplan-* || true"

  run_cmd "sudo systemctl unmask networking || true"
  run_cmd "sudo systemctl enable networking || true"

  #######################################
  # 8) Summary and reboot recommendation
  #######################################
  local summary
  summary=$(cat <<EOF
[STEP 03 Result Summary]

- udev rules file      : /etc/udev/rules.d/99-custom-ifnames.rules
  * mgt      -> PCI ${mgt_pci}
  * cltr0    -> PCI ${cltr0_pci}, sriov_numvfs=2
  * hostmgmt -> PCI ${host_pci}

- /etc/network/interfaces
  * mgt IP      : ${new_ip}/${new_prefix} (netmask ${netmask})
  * gateway     : ${new_gw}
  * dns         : ${new_dns}

- /etc/network/interfaces.d/02-hostmgmt.cfg
  * hostmgmt IP : 192.168.0.100/24 (no gateway)

- /etc/network/interfaces.d/00-cltr0.cfg
  * cltr0 → manual mode

- /etc/iproute2/rt_tables
  * 1 rt_mgt added (if not present)

- netplan disabled, transitioned to ifupdown + networking service

※ Network service may fail if restarted immediately.
  This script is configured to automatically reboot the host twice:
  once when STEP 03 (NIC/ifupdown transition) is completed and
  once when STEP 05 (kernel tuning) is completed.
  When DRY_RUN=0, the host will automatically reboot when each STEP completes successfully.
EOF
)

  whiptail --title "STEP 03 Complete" \
           --msgbox "${summary}" 25 80

  log "[STEP 03] NIC ifupdown transition and network configuration completed."
  log "[STEP 03] This STEP (03_nic_ifupdown) is included in auto-reboot targets."

  return 0
}

  

step_04_kvm_libvirt() {
  log "[STEP 04] KVM / Libvirt Installation and default Network (virbr0) Fixed Configuration"
  load_config

  local tmp_info="/tmp/xdr_step04_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current KVM/Libvirt Status Summary
  #######################################
  {
    echo "Current KVM/Libvirt Related Status Summary"
    echo "--------------------------------"
    echo
    echo "1) CPU Virtualization Support (vmx/svm presence)"
    egrep -c '(vmx|svm)' /proc/cpuinfo 2>/dev/null || echo "0"
    echo
    echo "2) KVM/Libvirt related package installation status (dpkg -l)"
    dpkg -l | egrep 'qemu-kvm|libvirt-daemon-system|libvirt-clients|virtinst|bridge-utils|qemu-utils|virt-viewer|genisoimage|net-tools|cpu-checker|ipset|ipcalc-ng' \
      || echo "(no related package installation information)"
    echo
    echo "3) libvirtd Service Status (brief)"
    systemctl is-active libvirtd 2>/dev/null || echo "inactive"
    echo
    echo "4) virsh net-list --all"
    virsh net-list --all 2>/dev/null || echo "(No libvirt network information)"
  } >> "${tmp_info}"

  show_textbox "STEP 04 - Current KVM/Libvirt Status" "${tmp_info}"

  if ! whiptail --title "STEP 04 Execution Confirmation" \
                 --yesno "KVM/Libvirt package installation and default network...Do you want to continue?" 13 80
  then
    log "User canceled STEP 04 execution."
    return 0
  fi

  #######################################
  # 1) Install KVM and required packages (based on documentation + PDF requirements: add ovmf/cloud-image-utils)
  #######################################
  log "[STEP 04] Installing KVM and required packages (based on documentation)"

  # [Modified] Added ovmf and cloud-image-utils
  run_cmd "sudo apt-get update"
  run_cmd "sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
qemu-utils virt-viewer genisoimage net-tools cpu-checker ipset make gcc ipcalc-ng bridge-utils \
ovmf cloud-image-utils"


  #######################################
  # 2) libvirtd / virtlogd enable --now
  #######################################
  log "[STEP 04] libvirtd / virtlogd enable --now"

  run_cmd "sudo systemctl enable --now libvirtd"
  run_cmd "sudo systemctl enable --now virtlogd"

  # ★★★ [Added section] Wait until libvirtd is fully up (max 30 seconds) ★★★
  if [[ "${DRY_RUN}" -eq 0 ]]; then
      log "[STEP 04] Waiting for libvirtd service initialization (Socket ready check)..."
      local retry_count=0
      while [ $retry_count -lt 15 ]; do
          if virsh list >/dev/null 2>&1; then
              log "[STEP 04] libvirtd normal response confirmed."
              break
          fi
          sleep 2
          ((retry_count++))
      done
  fi
  # ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★

  # For verification – DRY_RUN doesn't actually execute
  log "[STEP 04] KVM configuration verification commands (lsmod, kvm-ok, systemctl status libvirtd)"
  run_cmd "lsmod | grep kvm || echo 'kvm module is not loaded.'"
  run_cmd "kvm-ok || echo 'kvm-ok failed (check cpu-checker package)'"
  run_cmd "sudo systemctl status libvirtd --no-pager || true"

  #######################################
  # 3) Check default network status
  #######################################
  local default_net_xml_final="/etc/libvirt/qemu/networks/default.xml"
  local need_redefine=0

  if [[ -f "${default_net_xml_final}" ]]; then
    # Determine if it's already 192.168.122.1/24 + no DHCP
    if grep -q "<ip address='192.168.122.1' netmask='255.255.255.0'" "${default_net_xml_final}" 2>/dev/null && \
       ! grep -q "<dhcp>" "${default_net_xml_final}" 2>/dev/null; then
      need_redefine=0
      log "[STEP 04] ${default_net_xml_final} already has default network configured with 192.168.122.1/24 + no DHCP."
    else
      need_redefine=1
      log "[STEP 04] DHCP or other settings detected in ${default_net_xml_final} → redefinition needed."
    fi
  else
    need_redefine=1
    log "[STEP 04] ${default_net_xml_final} does not exist → default network definition needed."
  fi

  #######################################
  # 4) Force default network according to documentation (if needed)
  #######################################
  if [[ "${need_redefine}" -eq 1 ]]; then
    log "[STEP 04] Redefining default network as NAT 192.168.122.0/24 (virbr0) without DHCP."

    mkdir -p "${STATE_DIR}"
    local backup_xml="${STATE_DIR}/default.xml.backup.$(date +%Y%m%d-%H%M%S)"
    local new_xml="${STATE_DIR}/default.xml"

    # Backup existing default.xml
    if virsh net-dumpxml default > "${backup_xml}" 2>/dev/null; then
      log "Backed up existing default network XML to ${backup_xml}."
    else
      log "virsh net-dumpxml default failed (existing default network may not exist) – skipping backup."
    fi

    # Final format desired by documentation: NAT, virbr0, 192.168.122.1/24, no DHCP block
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
    log "[STEP 04] Executing virsh net-destroy/undefine/define/autostart/start default"
    run_cmd "virsh net-destroy default || true"
    run_cmd "virsh net-undefine default || true"
    run_cmd "virsh net-define ${new_xml}"
    run_cmd "virsh net-autostart default"
    run_cmd "virsh net-start default || true"
	
	# [Additional] Wait until configuration file is fully written to disk and service stabilizes
	log "[STEP 04] Waiting for configuration to apply (5 seconds)..."
	sleep 10
	sync
  else
    log "[STEP 04] Default network is already in desired state, skipping redefinition."
  fi

  #######################################
  # 5) Final Status Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 04 execution summary"
    echo "-----------------------"
    echo
    echo "# virsh net-list --all"
    virsh net-list --all 2>/dev/null || echo "(No libvirt network information)"
    echo
    echo "# Key parts of ${default_net_xml_final} content (IP/DHCP status)"
    if [[ -f "${default_net_xml_final}" ]]; then
      grep -E "<network>|<name>|<forward|<bridge|<ip|<dhcp" "${default_net_xml_final}" || cat "${default_net_xml_final}"
    else
      echo "${default_net_xml_final} does not exist."
    fi
    echo
    echo "※ /etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu operate"
    echo "   on the assumption of virbr0 (default network: 192.168.122.0/24, no DHCP)."
  } > "${tmp_info}"

  show_textbox "STEP 04 - Result Summary" "${tmp_info}"

  #######################################
  # 6) Essential Component Verification and Error Handling
  #######################################

  # In DRY_RUN mode, skip verification but don't return
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[STEP 04] DRY-RUN mode, skipping essential component verification."
  else
    local fail_reasons=()

    # 1) Check if virsh / kvm-ok commands exist
    if ! command -v virsh >/dev/null 2>&1; then
      fail_reasons+=(" - virsh command (libvirt-clients package) is not available.")
    fi

    if ! command -v kvm-ok >/dev/null 2>&1; then
      fail_reasons+=(" - kvm-ok command (cpu-checker package) is not available.")
    fi

    # 2) Check if KVM kernel module is loaded
    if ! grep -q '^kvm ' /proc/modules; then
      fail_reasons+=(" - kvm kernel module is not loaded.")
    fi

    # 3) Check libvirtd / virtlogd service status
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
      fail_reasons+=(" - libvirtd service is not in active state.")
    fi

    if ! systemctl is-active --quiet virtlogd 2>/dev/null; then
      fail_reasons+=(" - virtlogd service is not in active state.")
    fi

    # 4) Check default network (virbr0) configuration status
    local default_net_xml_final="/etc/libvirt/qemu/networks/default.xml"

    if [[ ! -f "${default_net_xml_final}" ]]; then
      fail_reasons+=(" - ${default_net_xml_final} file does not exist.")
    else
      if ! grep -q "<ip address='192.168.122.1' netmask='255.255.255.0'>" "${default_net_xml_final}" 2>/dev/null; then
        fail_reasons+=(" - default network IP is not set to 192.168.122.1/24.")
      fi
      if grep -q "<dhcp>" "${default_net_xml_final}" 2>/dev/null; then
        fail_reasons+=(" - DHCP block remains in default network XML.")
      fi
    fi

    # 5) Provide guidance on failure and return rc=1
    if ((${#fail_reasons[@]} > 0)); then
      local msg="The following items were not properly installed/configured.\n\n"
      local r
      for r in "${fail_reasons[@]}"; do
        msg+="$r\n"
      done
      msg+="\n[STEP 04] After re-running KVM / Libvirt installation and default network (virbr0) configuration,\nPlease check the logs."

      log "[STEP 04] Essential component verification failed → returning rc=1"
      whiptail --title "STEP 04 Verification Failed" --msgbox "${msg}" 20 90
      return 1
    fi
  fi

  log "[STEP 04] Essential component verification completed – can proceed to next step."

  # save_state is called by run_step()
}
  


step_05_kernel_tuning() {
  log "[STEP 05] Kernel Tuning / KSM / Swap / IOMMU Configuration"
  load_config

  # DRY_RUN default value handling
  local _DRY="${DRY_RUN:-0}"

  local tmp_info="/tmp/xdr_step05_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current Status Summary
  #######################################
  {
    echo "Current Kernel/Memory Related Status Summary"
    echo "--------------------------------"
    echo
    echo "# vm.min_free_kbytes"
    sysctl vm.min_free_kbytes 2>/dev/null || echo "vm.min_free_kbytes query failed"
    echo
    echo "# IPv4 Forwarding Status"
    sysctl net.ipv4.ip_forward 2>/dev/null || echo "net.ipv4.ip_forward query failed"
    echo
    echo "# Some ARP related settings (may already be set)"
    sysctl net.ipv4.conf.all.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_ignore 2>/dev/null || true
    sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null || true
    echo
    echo "# KSM Status (0 = disabled, 1 = enabled)"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      cat /sys/kernel/mm/ksm/run
    else
      echo "/sys/kernel/mm/ksm/run file does not exist."
    fi
    echo
    echo "# Current Swap Status"
    swapon --show || echo "(No active swap)"
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Current Kernel/Swap Status" "${tmp_info}"

  if ! whiptail --title "STEP 05 Execution Confirmation" \
                 --yesno "Do you want to proceed with applying kernel parameters defined in documentation, disabling KSM, disabling Swap, and configuring IOMMU?\n\n(Yes: Continue / No: Cancel)" 15 80
  then
    log "User canceled STEP 05 execution."
    return 0
  fi

  #######################################
  # 0-1) Add IOMMU parameters to GRUB (intel_iommu=on iommu=pt)
  #######################################
  local grub_file="/etc/default/grub"
  local grub_backup="/etc/default/grub.xdr-backup.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${grub_file}" ]]; then
    log "[STEP 05] Backing up GRUB configuration: ${grub_backup}"

    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] sudo cp ${grub_file} ${grub_backup}"
    else
      sudo cp "${grub_file}" "${grub_backup}"
    fi

    # Add intel_iommu=on iommu=pt to GRUB_CMDLINE_LINUX (skip if already present)
    if grep -q '^GRUB_CMDLINE_LINUX=' "${grub_file}"; then
      if grep -q 'intel_iommu=on' "${grub_file}" && grep -q 'iommu=pt' "${grub_file}"; then
        log "[STEP 05] GRUB_CMDLINE_LINUX already has intel_iommu=on iommu=pt configured."
      else
        log "[STEP 05] Adding intel_iommu=on iommu=pt options to GRUB_CMDLINE_LINUX."

        if [[ "${_DRY}" -eq 1 ]]; then
          log "[DRY-RUN] sudo sed -i -E 's/^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"/\\1 intel_iommu=on iommu=pt\"/' ${grub_file}"
        else
          sudo sed -i -E 's/^(GRUB_CMDLINE_LINUX=")([^"]*)(")/\1\2 intel_iommu=on iommu=pt\3/' "${grub_file}"
        fi
      fi
    else
      log "[STEP 05] GRUB_CMDLINE_LINUX entry does not exist, adding new one."

      if [[ "${_DRY}" -eq 1 ]]; then
        log "[DRY-RUN] echo 'GRUB_CMDLINE_LINUX=\"intel_iommu=on iommu=pt\"' | sudo tee -a ${grub_file}"
      else
        echo 'GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"' | sudo tee -a "${grub_file}" >/dev/null
      fi
    fi

    # Execute update-grub
    if [[ "${_DRY}" -eq 1 ]]; then
      log "[DRY-RUN] sudo update-grub"
    else
      log "[STEP 05] Executing update-grub"
      sudo update-grub
    fi
  else
    log "[WARN] Could not find ${grub_file} file. Skipping GRUB/IOMMU configuration."
  fi
  
  #######################################
  # 1) Add XDR kernel parameter block to sysctl.conf
  #######################################
  local SYSCTL_FILE="/etc/sysctl.conf"
  local SYSCTL_BACKUP="/etc/sysctl.conf.backup.$(date +%Y%m%d-%H%M%S)"
  local TUNING_TAG_BEGIN="# XDR_KERNEL_TUNING_BEGIN"
  local TUNING_TAG_END="# XDR_KERNEL_TUNING_END"

  log "[STEP 05] Adding kernel parameters to /etc/sysctl.conf (XDR dedicated block)"

  # Check if block already exists
  if grep -q "${TUNING_TAG_BEGIN}" "${SYSCTL_FILE}" 2>/dev/null; then
    log "[STEP 05] XDR kernel tuning block already exists in ${SYSCTL_FILE} → skipping duplicate addition"
  else
    # Backup
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      cp -a "${SYSCTL_FILE}" "${SYSCTL_BACKUP}"
      log "Backed up existing ${SYSCTL_FILE}: ${SYSCTL_BACKUP}"
    else
      log "[DRY-RUN] Will backup ${SYSCTL_FILE} to ${SYSCTL_BACKUP}"
    fi

    # Parameter block from documentation
    local tuning_block
    tuning_block=$(cat <<EOF

${TUNING_TAG_BEGIN}
# ARP related tuning (ARP Flux prevention)
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 2

# Ignore routes when link is down
#net.ipv4.conf.data1g.ignore_routes_with_linkdown = 1
#net.ipv4.conf.data10g.ignore_routes_with_linkdown = 1
net.ipv4.conf.all.ignore_routes_with_linkdown = 1

# Reserve free memory for OOM prevention (approximately 1GB)
vm.min_free_kbytes = 1048576
${TUNING_TAG_END}
EOF
)

    if [[ "${DRY_RUN}" -eq 0 ]]; then
      printf "%s\n" "${tuning_block}" | sudo tee -a "${SYSCTL_FILE}" >/dev/null
      log "[STEP 05] Added XDR kernel tuning block to ${SYSCTL_FILE}"
    else
      log "[DRY-RUN] Will append XDR kernel tuning block to end of ${SYSCTL_FILE}"
    fi
  fi  # tuning block addition if

  # 1-1) Explicitly enable IPv4 forwarding (net.ipv4.ip_forward)
  if grep -q "^#\?net\.ipv4\.ip_forward" "${SYSCTL_FILE}"; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will change net.ipv4.ip_forward line in ${SYSCTL_FILE} to 'net.ipv4.ip_forward = 1'"
    else
      sudo sed -i -E 's|^#?net\.ipv4\.ip_forward *=.*$|net.ipv4.ip_forward = 1|' "${SYSCTL_FILE}"
      log "Changed net.ipv4.ip_forward value in ${SYSCTL_FILE} to 1"
    fi
  else
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will append 'net.ipv4.ip_forward = 1' to end of ${SYSCTL_FILE}"
    else
      echo "net.ipv4.ip_forward = 1" | sudo tee -a "${SYSCTL_FILE}" >/dev/null
      log "Appended net.ipv4.ip_forward = 1 to end of ${SYSCTL_FILE}"
    fi
  fi

  # Apply/verify sysctl
  log "[STEP 05] Applying kernel parameters with sysctl -p"
  run_cmd "sudo sysctl -p ${SYSCTL_FILE}"
  log "[STEP 05] Checking net.ipv4.ip_forward configuration status"
  run_cmd "grep net.ipv4.ip_forward /etc/sysctl.conf || echo '#net.ipv4.ip_forward=1 (commented out)'"
  run_cmd "sysctl net.ipv4.ip_forward"

  #######################################
  # 2) Disable KSM ( /etc/default/qemu-kvm )
  #######################################
  log "[STEP 05] Disabling KSM (KSM_ENABLED=0)"

  local QEMU_DEFAULT="/etc/default/qemu-kvm"
  local QEMU_BACKUP="/etc/default/qemu-kvm.backup.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${QEMU_DEFAULT}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      cp -a "${QEMU_DEFAULT}" "${QEMU_BACKUP}"
      log "Backed up existing ${QEMU_DEFAULT}: ${QEMU_BACKUP}"
    else
      log "[DRY-RUN] Will backup ${QEMU_DEFAULT} to ${QEMU_BACKUP}"
    fi

    # If KSM_ENABLED line exists, set to 0, otherwise add it
    if grep -q "^KSM_ENABLED=" "${QEMU_DEFAULT}" 2>/dev/null; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will change KSM_ENABLED value in ${QEMU_DEFAULT} to 0: sed -i 's/^KSM_ENABLED=.*/KSM_ENABLED=0/' ${QEMU_DEFAULT}"
      else
        sudo sed -i 's/^KSM_ENABLED=.*/KSM_ENABLED=0/' "${QEMU_DEFAULT}"
        log "Changed KSM_ENABLED value in ${QEMU_DEFAULT} to 0"
      fi
    else
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will append 'KSM_ENABLED=0' line to end of ${QEMU_DEFAULT}"
      else
        echo "KSM_ENABLED=0" | sudo tee -a "${QEMU_DEFAULT}" >/dev/null
        log "Appended KSM_ENABLED=0 to end of ${QEMU_DEFAULT}"
      fi
    fi
  else
    log "[STEP 05] ${QEMU_DEFAULT} file does not exist → skipping KSM configuration"
  fi

  # Restart qemu-kvm service to apply KSM settings
  if systemctl list-unit-files 2>/dev/null | grep -q '^qemu-kvm\.service'; then
    log "[STEP 05] Restarting qemu-kvm service to apply KSM settings."

    # Use run_cmd considering DRY_RUN mode
    run_cmd "sudo systemctl restart qemu-kvm"

    # Check KSM status after restart
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      log "[STEP 05] Current value of /sys/kernel/mm/ksm/run after qemu-kvm restart:"
      cat /sys/kernel/mm/ksm/run >> "${LOG_FILE}" 2>&1
    fi
  else
    log "[STEP 05] qemu-kvm service unit does not exist, skipping restart."
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      log "[STEP 05] Current value of /sys/kernel/mm/ksm/run:"
      cat /sys/kernel/mm/ksm/run >> "${LOG_FILE}" 2>&1
    fi
  fi

  #######################################
  # 3) Disable Swap and clean up /swap.img (optional)
  #######################################
  local do_swapoff=0
  local do_zeroize=0

  if whiptail --title "STEP 05 - Disable Swap" \
              --yesno "According to documentation, disable Swap and\ncomment out /swap.img entry in /etc/fstab.\n\nDo you want to proceed with disabling Swap now?" 13 80
  then
    do_swapoff=1
  else
    log "[STEP 05] User chose to skip Swap disabling."
  fi

  if [[ "${do_swapoff}" -eq 1 ]]; then
    log "[STEP 05] Proceeding with swapoff -a and commenting out /swap.img in /etc/fstab"

    # 3-1) swapoff -a
    run_cmd "sudo swapoff -a"

    # 3-2) Comment out /swap.img entry in /etc/fstab
    local FSTAB_FILE="/etc/fstab"
    local FSTAB_BACKUP="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"

    if [[ -f "${FSTAB_FILE}" ]]; then
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        cp -a "${FSTAB_FILE}" "${FSTAB_BACKUP}"
        log "Backed up existing ${FSTAB_FILE}: ${FSTAB_BACKUP}"
      else
        log "[DRY-RUN] Will backup ${FSTAB_FILE} to ${FSTAB_BACKUP}"
      fi

      if grep -q "/swap.img" "${FSTAB_FILE}" 2>/dev/null; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          log "[DRY-RUN] Will comment out /swap.img entry in ${FSTAB_FILE} (sed -i 's|^\\([^#].*/swap.img.*\\)|#\\1|')"
        else
          sudo sed -i 's|^\([^#].*swap.img.*\)|#\1|' "${FSTAB_FILE}"
          log "Commented out /swap.img entry in ${FSTAB_FILE}"
        fi
      else
        log "[STEP 05] No /swap.img entry in ${FSTAB_FILE} → skipping comment"
      fi
    else
      log "[STEP 05] ${FSTAB_FILE} file does not exist → skipping Swap fstab configuration"
    fi

    # 3-3) Whether to Zeroize /swap.img (optional)
    if [[ -f /swap.img ]]; then
      if whiptail --title "STEP 05 - swap.img Zeroize" \
                  --yesno "/swap.img file exists.\nDocumentation recommends Zeroize (complete deletion) using dd + truncate.\n\nThis may take some time.\nDo you want to proceed with Zeroize now?" 15 80
      then
        do_zeroize=1
      else
        log "[STEP 05] User chose to skip /swap.img Zeroize operation."
      fi
    else
      log "[STEP 05] /swap.img file does not exist → skipping Zeroize"
    fi

    if [[ "${do_zeroize}" -eq 1 ]]; then
      log "[STEP 05] Proceeding with /swap.img Zeroize (dd + truncate)"

      # According to documentation: dd if=/dev/zero of=/swap.img bs=1M count=8192 status=progress
      #            truncate -s 0 /swap.img
      run_cmd "sudo dd if=/dev/zero of=/swap.img bs=1M count=8192 status=progress"
      run_cmd "sudo truncate -s 0 /swap.img"
    fi
  fi

  #######################################
  # 4) Final Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 05 execution summary"
    echo "----------------------"
    echo
    echo "# vm.min_free_kbytes (after application)"
    sysctl vm.min_free_kbytes 2>/dev/null || echo "vm.min_free_kbytes query failed"
    echo
    echo "# Some ARP / ignore_routes_with_linkdown related settings (after application)"
    sysctl net.ipv4.conf.all.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_filter 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.default.arp_announce 2>/dev/null || true
    sysctl net.ipv4.conf.all.arp_ignore 2>/dev/null || true
    sysctl net.ipv4.conf.all.ignore_routes_with_linkdown 2>/dev/null || true
    echo
    echo "# KSM Status (/sys/kernel/mm/ksm/run)"
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
      cat /sys/kernel/mm/ksm/run
    else
      echo "/sys/kernel/mm/ksm/run file does not exist."
    fi
    echo
    echo "# Current Swap Status (swapon --show)"
    swapon --show || echo "(No active swap)"
  } >> "${tmp_info}"

  show_textbox "STEP 05 - Result Summary" "${tmp_info}"

  # STEP 05 itself is considered complete if successful up to here (save_state is called by run_step())
}




step_06_ntpsec() {
  log "[STEP 06] SR-IOV Driver (iavf/i40evf) Installation + NTPsec Configuration"
  load_config

  local tmp_info="/tmp/xdr_step06_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Install SR-IOV iavf(i40evf) driver
  #######################################
  log "[STEP 06] Starting SR-IOV iavf(i40evf) driver installation"

  local iavf_url="https://github.com/intel/ethernet-linux-iavf/releases/download/v4.13.16/iavf-4.13.16.tar.gz"

  echo "=== Installing packages required for iavf driver build (apt-get) ==="
  sudo apt-get update -y
  sudo apt-get install -y build-essential linux-headers-$(uname -r) curl

  echo
  echo "=== Downloading iavf driver archive (curl progress will be shown below) ==="
  (
    cd /tmp || exit 1
    curl -L -o iavf-4.13.16.tar.gz "${iavf_url}"
  )
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log "[ERROR] iavf driver download failed (rc=${rc})"
    whiptail --title "STEP 06 - iavf Download Failed" \
             --msgbox "Failed to download iavf driver (${iavf_url}).\n\nPlease check network or GitHub access and try again." 12 80
    return 1
  fi
  echo "=== iavf driver download completed ==="
  log "[STEP 06] iavf driver download completed"

  echo
  echo "=== Building / installing iavf driver. This may take some time. ==="
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
    log "[ERROR] iavf driver build/installation failed (rc=${rc})"
    whiptail --title "STEP 06 - iavf Build/Installation Failed" \
             --msgbox "Failed to build or install iavf driver.\n\nPlease check /var/log/xdr-installer.log." 12 80
    return 1
  fi
  echo "=== iavf driver build / installation completed ==="
  log "[STEP 06] iavf driver build / installation completed"

  #######################################
  # 1) Verify/Apply SR-IOV VF driver (iavf/i40evf)
  #######################################
  log "[STEP 06] Attempting to load iavf/i40evf module"
  sudo modprobe iavf 2>/dev/null || sudo modprobe i40evf 2>/dev/null || true

  {
    echo "--------------------------------------"
    echo "[SR-IOV] iavf(i40evf) driver installation and load"
    echo "  - URL : ${iavf_url}"
    echo
    echo "# lsmod | grep -E '^(iavf|i40evf)\\b'"
    lsmod | grep -E '^(iavf|i40evf)\b' || echo "No iavf/i40evf modules loaded."
    echo
  } >> "${tmp_info}"


  #######################################
  # 0) Current time/ntp status summary
  #######################################
  {
    echo "Current Time / NTP Related Status Summary"
    echo "--------------------------------"
    echo
    echo "# timedatectl"
    timedatectl 2>/dev/null || echo "timedatectl execution failed"
    echo
    echo "# ntpsec package status (dpkg -l ntpsec)"
    dpkg -l ntpsec 2>/dev/null || echo "No ntpsec package information"
    echo
    echo "# ntpsec service status (systemctl is-active ntpsec)"
    systemctl is-active ntpsec 2>/dev/null || echo "inactive"
    echo
    echo "# ntpq -p (if available)"
    ntpq -p 2>/dev/null || echo "ntpq -p execution failed or ntpsec not installed"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV Driver Installation / NTP Status" "${tmp_info}"

  if ! whiptail --title "STEP 06 Execution Confirmation" \
	             --yesno "After installing iavf(i40evf) driver on the host,\nNTPsec configuration will proceed.\n\nDo you want to continue?" 13 80
  then
    log "User canceled STEP 06 execution."
    return 0
  fi


  #######################################
  # 1) Install NTPsec
  #######################################
  log "[STEP 06] Installing NTPsec package"

  run_cmd "sudo apt-get update"
  run_cmd "sudo apt-get install -y ntpsec"

  #######################################
  # 2) Backup /etc/ntpsec/ntp.conf
  #######################################
  local NTP_CONF="/etc/ntpsec/ntp.conf"
  local NTP_CONF_BACKUP="/etc/ntpsec/ntp.conf.orig.$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${NTP_CONF}" "${NTP_CONF_BACKUP}"
      log "Backed up existing ${NTP_CONF} to ${NTP_CONF_BACKUP}."
    else
      log "[DRY-RUN] Will backup ${NTP_CONF} to ${NTP_CONF_BACKUP}"
    fi
  else
    log "[STEP 06] ${NTP_CONF} file does not exist. (Need to check ntpsec package installation status)"
  fi

  #######################################
  # 3) Comment out default Ubuntu NTP pool/server entries
  #######################################
  log "[STEP 06] Commenting out default Ubuntu NTP pool/server entries"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will comment out pool/server entries in ${NTP_CONF} (0~3 ubuntu pool, ntp.ubuntu.com)"
    else
      sudo sed -i 's/^pool 0.ubuntu.pool.ntp.org iburst/#pool 0.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 1.ubuntu.pool.ntp.org iburst/#pool 1.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 2.ubuntu.pool.ntp.org iburst/#pool 2.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^pool 3.ubuntu.pool.ntp.org iburst/#pool 3.ubuntu.pool.ntp.org iburst/' "${NTP_CONF}"
      sudo sed -i 's/^server ntp.ubuntu.com iburst/#server ntp.ubuntu.com iburst/' "${NTP_CONF}"
    fi
  fi

  #######################################
  # 4) Comment out restrict default kod ... line
  #######################################
  log "[STEP 06] Commenting out restrict default kod ... rule"

  if [[ -f "${NTP_CONF}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Will comment out 'restrict default kod nomodify nopeer noquery limited' line in ${NTP_CONF}"
    else
      sudo sed -i 's/^restrict default kod nomodify nopeer noquery limited/#restrict default kod nomodify nopeer noquery limited/' "${NTP_CONF}"
    fi
  fi

  #######################################
  # 5) Add Google NTP + us.pool servers, tinker panic 0, restrict default
  #######################################
  log "[STEP 06] Adding Google NTP servers and tinker panic 0, restrict default"

  local TAG_BEGIN="# XDR_NTPSEC_CONFIG_BEGIN"
  local TAG_END="# XDR_NTPSEC_CONFIG_END"

  if [[ -f "${NTP_CONF}" ]]; then
    if grep -q "${TAG_BEGIN}" "${NTP_CONF}" 2>/dev/null; then
      log "[STEP 06] XDR_NTPSEC_CONFIG block already exists in ${NTP_CONF} → skipping re-addition"
    else
      local ntp_block
      ntp_block=$(cat <<EOF

${TAG_BEGIN}
# Alternative NTP servers (based on documentation)
server time1.google.com prefer
server time2.google.com
server time3.google.com
server time4.google.com
server 0.us.pool.ntp.org
server 1.us.pool.ntp.org

# Configure to allow correction of large time differences
tinker panic 0

# Update restrict rule
restrict default nomodify nopeer noquery notrap
${TAG_END}
EOF
)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[DRY-RUN] Will append the following block to end of ${NTP_CONF}:\n${ntp_block}"
      else
        printf "%s\n" "${ntp_block}" | sudo tee -a "${NTP_CONF}" >/dev/null
        log "Added XDR_NTPSEC_CONFIG block to ${NTP_CONF}"
      fi
    fi
  else
    log "[STEP 06] ${NTP_CONF} does not exist, could not add NTP server configuration."
  fi

  #######################################
  # 6) Restart NTPsec and verify
  #######################################
  log "[STEP 06] Restarting NTPsec and checking status"

  run_cmd "sudo systemctl restart ntpsec"
  run_cmd "systemctl status ntpsec --no-pager || true"
  run_cmd "ntpq -p || true"

  #######################################
  # 7) Final Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 06 (SR-IOV + NTPsec) execution summary"
    echo "----------------------------------------"
    echo
    echo "# SR-IOV VF driver (iavf/i40evf) module status (lsmod)"
    lsmod | grep -E '^(iavf|i40evf)\b' || echo "No iavf/i40evf modules loaded."
    echo
    echo "# XDR_NTPSEC_CONFIG section in ${NTP_CONF}"
    if [[ -f "${NTP_CONF}" ]]; then
      grep -n -A5 -B2 "${TAG_BEGIN}" "${NTP_CONF}" || sed -n '1,120p' "${NTP_CONF}"
    else
      echo "${NTP_CONF} file does not exist."
    fi
    echo
    echo "# systemctl is-active ntpsec"
    systemctl is-active ntpsec 2>/dev/null || echo "inactive"
    echo
    echo "# ntpq -p"
    ntpq -p 2>/dev/null || echo "ntpq -p execution failed or synchronization pending"
  } >> "${tmp_info}"

  show_textbox "STEP 06 - SR-IOV(iavf/i40evf) + NTPsec Result Summary" "${tmp_info}"


  # save_state is called by parent run_step()
}


step_07_lvm_storage() {

  log "[STEP 07] LVM Storage Configuration Started"

  load_config
  # [Modified] Added automatic OS VG name detection logic
  local root_dev
  root_dev=$(findmnt -n -o SOURCE /)
 
  local UBUNTU_VG
  # Extract VG name that root device belongs to using lvs command (remove spaces)
  UBUNTU_VG=$(sudo lvs --noheadings -o vg_name "${root_dev}" 2>/dev/null | awk '{print $1}')
  # Fallback to default value if detection fails
  if [[ -z "${UBUNTU_VG}" ]]; then
    log "[WARN] Could not detect OS VG name, using default value (ubuntu-vg)."
    UBUNTU_VG="ubuntu-vg"
  else
    log "[STEP 07] Detected OS VG name: ${UBUNTU_VG}"
  fi
  local DL_ROOT_LV="lv_dl_root"
  local DA_ROOT_LV="lv_da_root"
	  
  local ES_VG="vg_dl"
  local ES_LV="lv_dl"

  if [[ -z "${DATA_SSD_LIST}" ]]; then
    whiptail --title "STEP 07 - Data Disk Not Configured" \
             --msgbox "DATA_SSD_LIST is not set.\n\nYou must first select data disks in STEP 01." 12 70
    log "DATA_SSD_LIST is empty, cannot proceed with STEP 07."
    return 1
  fi

  #######################################
  # Ask whether to skip if LVM/mount appears to be already configured
  #######################################
  local already_lvm=0

  # Use ES_VG, UBUNTU_VG, DL_ROOT_LV, DA_ROOT_LV values defined at top of existing script
  if vgs "${ES_VG}" >/dev/null 2>&1 && \
     lvs "${UBUNTU_VG}/${DL_ROOT_LV}" >/dev/null 2>&1 && \
     lvs "${UBUNTU_VG}/${DA_ROOT_LV}" >/dev/null 2>&1; then
    # Also check /stellar/dl, /stellar/da mounts
    if mount | grep -qE "on /stellar/dl " && mount | grep -qE "on /stellar/da "; then
      already_lvm=1
    fi
  fi

  if [[ "${already_lvm}" -eq 1 ]]; then
    if whiptail --title "STEP 07 - Already Configured" \
                --yesno "vg_dl / lv_dl and ${UBUNTU_VG}/${DL_ROOT_LV}, ${UBUNTU_VG}/${DA_ROOT_LV}\nand /stellar/dl, /stellar/da mounts already exist.\n\nThis STEP recreates disk partitions,\nso generally should not be run again.\n\nDo you want to skip this STEP?" 18 80
    then
      log "User chose to skip STEP 07 entirely based on 'already configured' judgment."
      return 0
    fi
    log "User chose to force re-execution of STEP 07. (Warning: risk of destroying existing data)"
  fi



  #######################################
  # Verify selected disks + destructive operation warning
  #######################################
  local tmp_info="/tmp/xdr_step07_disks.txt"
  : > "${tmp_info}"
  echo "[Selected Data Disk List]" >> "${tmp_info}"
  for d in ${DATA_SSD_LIST}; do
    {
      echo
      echo "=== /dev/${d} ==="
      lsblk "/dev/${d}" -o NAME,SIZE,TYPE,MOUNTPOINT
    } >> "${tmp_info}" 2>&1
  done

  show_textbox "STEP 07 - Disk Verification" "${tmp_info}"

  if ! whiptail --title "STEP 07 - Warning" \
                 --yesno "All existing partitions/data on the disks shown above (/dev/${DATA_SSD_LIST})\nwill be deleted and used exclusively for LVM.\n\nDo you want to continue?" 15 70
  then
    log "User canceled STEP 07 disk initialization."
    return 0
  fi

  #######################################
  # 0-5) Completely remove existing LVM/VG/LV from selected disks
  #######################################
  log "[STEP 07] Removing all existing LVM metadata (LV/VG/PV) from selected disks."

  local disk pv vg_name pv_list_for_disk

  for disk in ${DATA_SSD_LIST}; do
    log "[STEP 07] Starting cleanup of existing LVM structure for /dev/${disk}"

    # Query PV list on this disk (includes /dev/sdb, /dev/sdb1, etc.)
    pv_list_for_disk=$(sudo pvs --noheadings -o pv_name 2>/dev/null \
                         | awk "\$1 ~ /^\\/dev\\/${disk}([0-9]+)?\$/ {print \$1}")

    for pv in ${pv_list_for_disk}; do
      vg_name=$(sudo pvs --noheadings -o vg_name "${pv}" 2>/dev/null | awk '{print $1}')

      if [[ -n "${vg_name}" && "${vg_name}" != "-" ]]; then
        log "[STEP 07] PV ${pv} belongs to VG ${vg_name} → attempting LV/VG removal"

        # Remove all LVs in VG (ignore errors even if called multiple times)
        run_cmd "sudo lvremove -y ${vg_name} || true"

        # Remove VG (ignore error if already removed)
        run_cmd "sudo vgremove -y ${vg_name} || true"
      fi

      # Remove PV metadata
      run_cmd "sudo pvremove -y ${pv} || true"
    done

    # Remove remaining filesystem/partition signatures from entire disk
    log "[STEP 07] Executing wipefs on /dev/${disk} to remove filesystem/partition signatures"
    run_cmd "sudo wipefs -a /dev/${disk} || true"
  done


  #######################################
  # 1) Create GPT label + single partition on each disk
  #######################################
  log "[STEP 07] Creating disk GPT label and partitions"

  local d
  for d in ${DATA_SSD_LIST}; do
    run_cmd "sudo parted -s /dev/${d} mklabel gpt"
    run_cmd "sudo parted -s /dev/${d} mkpart primary ext4 1MiB 100%"
  done

  #######################################
  # 2) Create PV / VG / LV (for ES data)
  #######################################
  log "[STEP 07] Creating ES dedicated VG/LV (vg_dl / lv_dl)"

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
  log "[STEP 07] Creating DL/DA Root LV (${UBUNTU_VG}/${DL_ROOT_LV}, ${UBUNTU_VG}/${DA_ROOT_LV})"

  if lvs "${UBUNTU_VG}/${DL_ROOT_LV}" >/dev/null 2>&1; then
    log "LV ${UBUNTU_VG}/${DL_ROOT_LV} already exists → skipping creation"
  else
    run_cmd "sudo lvcreate -L 545G -n ${DL_ROOT_LV} ${UBUNTU_VG}"
  fi

  if lvs "${UBUNTU_VG}/${DA_ROOT_LV}" >/dev/null 2>&1; then
    log "LV ${UBUNTU_VG}/${DA_ROOT_LV} already exists → skipping creation"
  else
    run_cmd "sudo lvcreate -L 545G -n ${DA_ROOT_LV} ${UBUNTU_VG}"
  fi

  #######################################
  # 4) mkfs.ext4 (DL/DA Root + ES Data)
  #######################################
  log "[STEP 07] Formatting LV (mkfs.ext4)"

  local DEV_DL_ROOT="/dev/${UBUNTU_VG}/${DL_ROOT_LV}"
  local DEV_DA_ROOT="/dev/${UBUNTU_VG}/${DA_ROOT_LV}"
  local DEV_ES_DATA="/dev/${ES_VG}/${ES_LV}"

  if ! blkid "${DEV_DL_ROOT}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_DL_ROOT}"
  else
    log "Filesystem already exists: ${DEV_DL_ROOT} → skipping mkfs"
  fi

  if ! blkid "${DEV_DA_ROOT}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_DA_ROOT}"
  else
    log "Filesystem already exists: ${DEV_DA_ROOT} → skipping mkfs"
  fi

  if ! blkid "${DEV_ES_DATA}" >/dev/null 2>&1; then
    run_cmd "sudo mkfs.ext4 -F ${DEV_ES_DATA}"
  else
    log "Filesystem already exists: ${DEV_ES_DATA} → skipping mkfs"
  fi

  #######################################
  # 5) Create mount points
  #######################################
  log "[STEP 07] Creating /stellar/dl, /stellar/da directories"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /stellar/dl /stellar/da"
  else
    sudo mkdir -p /stellar/dl /stellar/da
  fi

  #######################################
  # 6) Register in /etc/fstab (same format as documentation)
  #######################################
  log "[STEP 07] Registering in /etc/fstab"

  local FSTAB_DL_LINE="${DEV_DL_ROOT} /stellar/dl ext4 defaults,noatime 0 2"
  local FSTAB_DA_LINE="${DEV_DA_ROOT} /stellar/da ext4 defaults,noatime 0 2"
  append_fstab_if_missing "${FSTAB_DL_LINE}" "/stellar/dl"
  append_fstab_if_missing "${FSTAB_DA_LINE}" "/stellar/da"

  #######################################
  # 7) Execute mount -a and verify results
  #######################################
  log "[STEP 07] Executing mount -a and checking mount status"

  run_cmd "sudo systemctl daemon-reload"
  run_cmd "sudo mount -a"

  local tmp_df="/tmp/xdr_step07_df.txt"
  {
    echo "=== df -h | egrep '/stellar/(dl|da)' ==="
    df -h | egrep '/stellar/(dl|da)' || echo "Currently no mount information for /stellar/dl, /stellar/da."
    echo

    echo "=== lvs ==="
    lvs
    echo

    # Same verification as 'lsblk output example after LV creation' in documentation
    echo "=== lsblk (verify entire disk/partition/Logical Volume structure) ==="
    lsblk
  } > "${tmp_df}" 2>&1
  
  

  #######################################
  # 8) Change /stellar ownership (documentation: chown -R stellar:stellar /stellar)
  #######################################
  log "[STEP 07] Changing /stellar ownership to stellar:stellar (same as documentation)"

  if id stellar >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] sudo chown -R stellar:stellar /stellar"
    else
      sudo chown -R stellar:stellar /stellar
      log "[STEP 07] /stellar ownership change completed"
    fi
  else
    log "[WARN] Could not find 'stellar' user account, skipping chown."
  fi

  #######################################
  # 9) Display result summary
  #######################################
  show_textbox "STEP 07 Result Summary" "${tmp_df}"

  # STEP successful → save_state is called by parent run_step()
}



step_08_libvirt_hooks() {
  log "[STEP 08] Installing libvirt hooks (/etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu)"
  load_config

  local tmp_info="/tmp/xdr_step08_info.txt"
  : > "${tmp_info}"

  #######################################
  # 0) Current hooks status summary
  #######################################
  {
    echo "/etc/libvirt/hooks directory and script status"
    echo "-------------------------------------------"
    echo
    echo "# Directory existence"
    if [[ -d /etc/libvirt/hooks ]]; then
      echo "/etc/libvirt/hooks directory exists."
      echo
      echo "# /etc/libvirt/hooks/network (first 20 lines if exists)"
      if [[ -f /etc/libvirt/hooks/network ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/network
      else
        echo "(network script not found)"
      fi
      echo
      echo "# /etc/libvirt/hooks/qemu (first 20 lines if exists)"
      if [[ -f /etc/libvirt/hooks/qemu ]]; then
        sed -n '1,20p' /etc/libvirt/hooks/qemu
      else
        echo "(qemu script not found)"
      fi
    else
      echo "/etc/libvirt/hooks directory does not exist yet."
    fi
  } >> "${tmp_info}"

  show_textbox "STEP 08 - Current hooks status" "${tmp_info}"

  if ! whiptail --title "STEP 08 Execution Confirmation" \
                 --yesno "The /etc/libvirt/hooks/network, /etc/libvirt/hooks/qemu scripts will be\ncompletely created/overwritten based on the document.\n\nDo you want to continue?" 13 80
  then
    log "User canceled STEP 08 execution."
    return 0
  fi


  #######################################
  # 1) Create /etc/libvirt/hooks directory
  #######################################
  log "[STEP 08] Creating /etc/libvirt/hooks directory (if not exists)"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p /etc/libvirt/hooks"
  else
    sudo mkdir -p /etc/libvirt/hooks
  fi

  #######################################
  # 2) Create /etc/libvirt/hooks/network (as per document)
  #######################################
  local HOOK_NET="/etc/libvirt/hooks/network"
  local HOOK_NET_BAK="/etc/libvirt/hooks/network.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Creating/Updating ${HOOK_NET}"

  if [[ -f "${HOOK_NET}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_NET}" "${HOOK_NET_BAK}"
      log "Backed up existing ${HOOK_NET} to ${HOOK_NET_BAK}."
    else
      log "[DRY-RUN] Will backup existing ${HOOK_NET} to ${HOOK_NET_BAK}"
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
    log "[DRY-RUN] Will write the following content to ${HOOK_NET}:\n${net_hook_content}"
  else
    printf "%s\n" "${net_hook_content}" | sudo tee "${HOOK_NET}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_NET}"

  #######################################
  # 3) Create /etc/libvirt/hooks/qemu (full version)
  #######################################
  local HOOK_QEMU="/etc/libvirt/hooks/qemu"
  local HOOK_QEMU_BAK="/etc/libvirt/hooks/qemu.backup.$(date +%Y%m%d-%H%M%S)"

  log "[STEP 08] Creating/Updating ${HOOK_QEMU} (full NAT + OOM restart script)"

  if [[ -f "${HOOK_QEMU}" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      sudo cp -a "${HOOK_QEMU}" "${HOOK_QEMU_BAK}"
      log "Backed up existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}."
    else
      log "[DRY-RUN] Will backup existing ${HOOK_QEMU} to ${HOOK_QEMU_BAK}"
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
# Unified structure: DL = 192.168.122.2, DA = 192.168.122.3
# (If deploying datasensor on virbr0 with 192.168.122.4, add to array below)
UI_EXC_LIST=(192.168.122.2 192.168.122.3)
IPSET_UI='ui'

# Create ipset ui if it doesn't exist + add exception IPs
IPSET_CONFIG=$(echo -n $(ipset list $IPSET_UI 2>/dev/null))
if ! [[ $IPSET_CONFIG =~ $IPSET_UI ]]; then
  ipset create $IPSET_UI hash:ip
  for IP in ${UI_EXC_LIST[@]}; do
    ipset add $IPSET_UI $IP
  done
fi

########################
# dl-master NAT / Forwarding
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
# da-master NAT / Forwarding
#  - Unified structure: DA also uses virbr0 + mgt for management+data processing
########################
if [ "${1}" = "da-master" ]; then
  # Internal IP also unified to 192.168.122.3
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
# datasensor NAT / Forwarding (Optional)
#  - Use only if continuing to use datasensor VM
#  - Example of attaching to virbr0 with 192.168.122.4
#  - If not using datasensor VM itself, this entire block can be deleted
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
    log "[DRY-RUN] Will write the following content to ${HOOK_QEMU}:\n${qemu_hook_content}"
  else
    printf "%s\n" "${qemu_hook_content}" | sudo tee "${HOOK_QEMU}" >/dev/null
  fi

  run_cmd "sudo chmod +x ${HOOK_QEMU}"


  ########################################
  # 4) Install OOM recovery scripts (last_known_good_pid, check_vm_state)
  ########################################
  log "[STEP 08] Installing OOM recovery scripts (last_known_good_pid, check_vm_state)"

  local _DRY="${DRY_RUN:-0}"

  # 1) Create /usr/bin/last_known_good_pid (as per document script)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Creating /usr/bin/last_known_good_pid script"
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


  # 2) Create /usr/bin/check_vm_state (as per document script)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Creating /usr/bin/check_vm_state script"
  else
    sudo tee /usr/bin/check_vm_state >/dev/null <<'EOF'
#!/bin/bash
VM_LIST=(dl-master da-master)
RUN_DIR=/var/run/libvirt/qemu

for VM in ${VM_LIST[@]}; do
    # Check if VM is in stopped state (no .xml file, no .pid file)
    if [ ! -e ${RUN_DIR}/${VM}.xml -a ! -e ${RUN_DIR}/${VM}.pid ]; then
        if [ -e ${RUN_DIR}/${VM}.lkg ]; then
            LKG_PID=$(cat ${RUN_DIR}/${VM}.lkg)

            # Check if OOM-killer killed this PID in dmesg
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


  # 3) Register cron (run check_vm_state every 5 minutes)
  if [[ "${_DRY}" -eq 1 ]]; then
    log "[DRY-RUN] Will register the following two lines in root crontab:"
    log "  SHELL=/bin/bash"
    log "  */5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1"
  else
    # Preserve existing crontab while ensuring SHELL and check_vm_state lines
    local tmp_cron added_flag
    tmp_cron="$(mktemp)"
    added_flag="0"

    # Dump existing crontab (create empty file if none exists)
    if ! sudo crontab -l 2>/dev/null > "${tmp_cron}"; then
      : > "${tmp_cron}"
    fi

    # Add SHELL=/bin/bash if not present
    if ! grep -q '^SHELL=' "${tmp_cron}"; then
      echo "SHELL=/bin/bash" >> "${tmp_cron}"
      added_flag="1"
    fi

    # Add check_vm_state line if not present
    if ! grep -q 'check_vm_state' "${tmp_cron}"; then
      echo "*/5 * * * * /bin/bash /usr/bin/check_vm_state > /dev/null 2>&1" >> "${tmp_cron}"
      added_flag="1"
    fi

    # Apply modified crontab
    sudo crontab "${tmp_cron}"
    rm -f "${tmp_cron}"

    if [[ "${added_flag}" = "1" ]]; then
      log "[STEP 08] Registered/Updated SHELL=/bin/bash and check_vm_state entries in root crontab."
    else
      log "[STEP 08] SHELL=/bin/bash and check_vm_state entries already exist in root crontab."
    fi
  fi



  #######################################
  # 5) Final Summary
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

  show_textbox "STEP 08 - Result Summary" "${tmp_info}"

  # save_state is handled by the parent run_step()
}


step_09_dp_download() {
  log "[STEP 09] DP Deployment Script and Image Download (Local Detection + Filename Conversion Applied)"
  load_config
  local tmp_info="/tmp/xdr_step09_info.txt"

  #######################################
  # 0) Check Configuration Values
  #######################################
  local ver="${DP_VERSION:-}"
  local acps_user="${ACPS_USERNAME:-}"
  local acps_pass="${ACPS_PASSWORD:-}"
  local acps_url="https://apsdev.stellarcyber.ai"  # [Requirement] Domain fixed

  # Check for required values
  local missing=""
  [[ -z "${ver}"       ]] && missing+="\n - DP_VERSION"
  [[ -z "${acps_user}" ]] && missing+="\n - ACPS_USERNAME"
  [[ -z "${acps_pass}" ]] && missing+="\n - ACPS_PASSWORD"

  if [[ -n "${missing}" ]]; then
    local msg="The following items are missing from the configuration:${missing}\n\nPlease set the values in the [Configuration] menu first and then re-run."
    log "[STEP 09] Missing configuration values: ${missing}"
    whiptail --title "STEP 09 - Missing Configuration" \
             --msgbox "${msg}" 15 70
    log "[STEP 09] Skipping STEP 09 due to missing configuration values."
    return 0
  fi

  # Clean up URL (remove trailing slash)
  acps_url="${acps_url%/}"

  #######################################
  # 1) Prepare Download Directory
  #######################################
  local dl_img_dir="/stellar/dl/images"
  log "[STEP 09] Download directory: ${dl_img_dir}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] sudo mkdir -p ${dl_img_dir}"
  else
    sudo mkdir -p "${dl_img_dir}"
  fi

  #######################################
  # 2) Define Download Targets/URLs
  #######################################
  # [Requirement] Script version fixed to 6.2.0
  local script_ver="6.2.0"
  local dp_script="virt_deploy_uvp_centos.sh"

  # [Core] Filename separation strategy
  # 1. Name to download from server (Long Name) - for SHA1 verification
  local remote_qcow2="aella-dataprocessor-ubuntu2404-py2-${ver}.qcow2"
  local remote_xml="aella-dataprocessor-ubuntu2404-py2-${ver}.xml"
  local remote_sha1="${remote_qcow2}.sha1"

  # 2. Name to save locally (Short Name - for Step 10/11 compatibility)
  local local_qcow2="aella-dataprocessor-${ver}.qcow2"

  # Assemble URL
  local url_script="${acps_url}/release/${script_ver}/dataprocessor/${dp_script}"
  local url_qcow2="${acps_url}/release/${ver}/dataprocessor/${remote_qcow2}"
  local url_xml="${acps_url}/release/${ver}/dataprocessor/${remote_xml}"
  local url_sha1="${acps_url}/release/${ver}/dataprocessor/${remote_sha1}"

  log "[STEP 09] Configuration Summary:"
  log "  - DP_VERSION     = ${ver}"
  log "  - ACPS_BASE_URL  = ${acps_url}"
  log "  - Download Filename (Server): ${remote_qcow2}"
  log "  - Saved Filename (Local)   : ${local_qcow2}"

  #######################################
  # 3-A) Check for reuse of existing qcow2 file >= 1GB in current directory
  #######################################
  local use_local_qcow=0
  local found_local_file=""
  local found_size=""
  local search_dir="."

  # Find the most recent *.qcow2 file >= 1GB (=1000M)
  found_local_file="$(
    find "${search_dir}" -maxdepth 1 -type f -name '*.qcow2' -size +1000M -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}'
  )"

  if [[ -n "${found_local_file}" ]]; then
    found_size="$(ls -lh "${found_local_file}" 2>/dev/null | awk '{print $5}')"

    local msg
    msg="Found a qcow2 file larger than 1GB in the current directory.\n\n"
    msg+="  File: ${found_local_file}\n"
    msg+="  Size: ${found_size}\n\n"
    msg+="Do you want to use this file and skip download?\n"
    msg+="(If selected, the file will be finally saved as '${local_qcow2}'.)"

    if whiptail --title "STEP 09 - Reuse Local qcow2" --yesno "${msg}" 18 80; then
      use_local_qcow=1
      log "[STEP 09] User chose to use local qcow2 file (${found_local_file})."

      if [[ "${DRY_RUN}" -eq 1 ]]; then
        # [Modified] Copy to remote_qcow2 (long name) first for SHA1 verification
        log "[DRY-RUN] sudo cp \"${found_local_file}\" \"${dl_img_dir}/${remote_qcow2}\""
      else
        # [Modified] Copy to remote_qcow2 (long name) first for SHA1 verification
        sudo cp "${found_local_file}" "${dl_img_dir}/${remote_qcow2}"
        log "[STEP 09] Local file copied to ${dl_img_dir}/${remote_qcow2} (for verification)"
      fi
    else
      log "[STEP 09] User chose to ignore local file and download new one from server."
    fi
  else
    log "[STEP 09] No reusable qcow2 file >= 1GB found in current directory."
  fi

  #######################################
  # 3-B) Force Refresh (Apply forced download policy)
  #######################################
  # [Requirement] Script, XML, SHA1 must be deleted and re-downloaded unconditionally
  # For images, delete and re-download if not using local file

  if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "[DRY-RUN] Simulating deletion of existing files (script, XML, SHA1)"
      [[ "${use_local_qcow}" -eq 0 ]] && log "[DRY-RUN] Simulating deletion of existing image"
  else
      # 1. Small files like script/XML/SHA1 are always deleted (always keep latest version)
      sudo rm -f "${dl_img_dir}/${dp_script}" \
                 "${dl_img_dir}/${remote_xml}" \
                 "${dl_img_dir}/${remote_sha1}" \
                 "${dl_img_dir}/*.xml" "${dl_img_dir}/*.sha1" # Clean up remaining files

      # 2. Images are deleted only when not using local files (delete both Short Name and Long Name)
      if [[ "${use_local_qcow}" -eq 0 ]]; then
          if [[ -f "${dl_img_dir}/${local_qcow2}" || -f "${dl_img_dir}/${remote_qcow2}" ]]; then
              log "[STEP 09] Force Refresh: Deleting existing qcow2 image"
              sudo rm -f "${dl_img_dir}/${local_qcow2}" "${dl_img_dir}/${remote_qcow2}"
          fi
      else
          log "[STEP 09] Using local file, skipping deletion of existing image."
      fi
  fi

  #######################################
  # 3-C) Actual Download (Maintain detailed logic)
  #######################################
  # If using local file, image is already copied, so exclude from download
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[DRY-RUN] (Password not shown in logs)"
    log "[DRY-RUN] Script: ${url_script}"
    log "[DRY-RUN] XML:    ${url_xml}"
    log "[DRY-RUN] SHA1:   ${url_sha1}"
    if [[ "${use_local_qcow}" -eq 0 ]]; then
        log "[DRY-RUN] Image:  ${url_qcow2}"
    fi

  else
    # Perform actual download
    (
      cd "${dl_img_dir}" || exit 1

      # 1) Deployment Script (unconditional)
      log "[STEP 09] Starting ${dp_script} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_script}" || {
        log "[ERROR] ${dp_script} download failed"
        exit 1
      }

      # 2) XML file (unconditional - Long Name)
      log "[STEP 09] Starting ${remote_xml} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_xml}" || {
        log "[WARN] XML download failed (continuing)"
      }

      # 3) SHA1 file (unconditional - Long Name)
      log "[STEP 09] Starting ${remote_sha1} download..."
      curl -O -k -u "${acps_user}:${acps_pass}" "${url_sha1}" || {
         log "[WARN] SHA1 download failed (verification impossible)"
      }

      # 4) qcow2 (if local not used - download with Long Name)
      if [[ "${use_local_qcow}" -eq 0 ]]; then
        log "[STEP 09] Starting image download: ${remote_qcow2}"
        echo "=== Downloading ${remote_qcow2} (curl progress shown below) ==="
        
        # -C - option allows resuming, but -O is used for overwrite due to Force Refresh policy
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
      log "[STEP 09] Error occurred during download, stopping STEP 09 (rc=${rc})"
      return 1
    fi
  fi

  #######################################
  # 4) Execute Permissions, Verification and Rename
  #######################################
  local _DRY="${DRY_RUN:-0}"

  if [[ "${_DRY}" -eq 0 ]]; then
    # 4-1) Grant script execute permissions
    if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
      sudo chmod +x "${dl_img_dir}/${dp_script}"
      log "[STEP 09] Granting execute permissions to ${dl_img_dir}/${dp_script}"
    else
      log "[STEP 09] Warning: ${dl_img_dir}/${dp_script} file not found."
    fi
    
    # 4-2) SHA1 Verification (only if Long Name file exists)
    # Even if local file was used, it was copied with remote_qcow2 name above, so verification is possible here
    if [[ -f "${dl_img_dir}/${remote_sha1}" && -f "${dl_img_dir}/${remote_qcow2}" ]]; then
      log "[STEP 09] Performing sha1sum -c ${remote_sha1} verification"

      (
        cd "${dl_img_dir}" || exit 2
        # Filename (remote_qcow2) is in sha1 file, so automatic matching
        if ! sha1sum -c "${remote_sha1}"; then
          log "[WARN] sha1sum verification failed."
          
          if whiptail --title "STEP 09 - sha1 Verification Failed" \
                      --yesno "sha1 verification failed.\n\nFile may be corrupted.\nDo you want to proceed anyway?\n\n[Yes] Continue\n[No] Abort" 14 80
          then
            log "[STEP 09] User ignored sha1 verification failure."
            exit 0
          else
            log "[STEP 09] User chose to abort."
            exit 3
          fi
        fi
        log "[STEP 09] sha1sum verification successful."
        exit 0
      )
      
      local sha_rc=$?
      case "${sha_rc}" in
        0) ;; # Normal
        2) log "[STEP 09] Directory access failed"; return 1 ;;
        3) log "[STEP 09] User abort request"; return 1 ;;
        *) log "[STEP 09] Unknown error during verification"; return 1 ;;
      esac
    else
      log "[STEP 09] Skipping verification as SHA1 file or image is missing."
    fi

    # 4-3) ★ Rename file (Long Name -> Short Name) ★
    # Whether downloaded or locally copied, current filename is remote_qcow2 (Long) -> change to local_qcow2 (Short)
    if [[ -f "${dl_img_dir}/${remote_qcow2}" ]]; then
        log "[STEP 09] Renaming file: ${remote_qcow2} -> ${local_qcow2}"
        sudo mv "${dl_img_dir}/${remote_qcow2}" "${dl_img_dir}/${local_qcow2}"
        
        # SHA1 file is no longer needed, so delete it (to prevent confusion)
        sudo rm -f "${dl_img_dir}/${remote_sha1}"
    fi

    #######################################
    # 5) Modify virt_deploy_uvp_centos.sh content (Reflect Short Name)
    #######################################
    local target_script="${dl_img_dir}/${dp_script}"
    local hardcoded_image_name="${local_qcow2}" # Use Short Name

    if [[ -f "${target_script}" ]]; then
        log "[STEP 09] Starting virt_deploy_uvp_centos.sh variable modification (Reflecting Short Name)"

        # 1. Modify IMAGE variable
        sed -i "s|^#\?IMAGE=\${DIR}/\${IMAGE_NAME}|IMAGE=${dl_img_dir}/${hardcoded_image_name}|" "${target_script}"

        # 2. Modify uvp_package_url
        sed -i "s|^#\?uvp_package_url=.*|uvp_package_url=https://\${FS_SERVER}/release/\${RELEASE}/dataprocessor/${hardcoded_image_name}|" "${target_script}"

        log "[STEP 09] virt_deploy_uvp_centos.sh internal variables (IMAGE, URL) patched."
    fi

    #######################################
    # 6) Copy to DA image directory as well
    #######################################
    local da_img_dir="/stellar/da/images"
    
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        run_cmd "sudo mkdir -p ${da_img_dir}"

        # Copy image (Short Name)
        if [[ -f "${dl_img_dir}/${local_qcow2}" ]]; then
            run_cmd "sudo cp ${dl_img_dir}/${local_qcow2} ${da_img_dir}/"
        else
            log "[WARN] ${local_qcow2} file not found, skipping DA image copy."
        fi

        # Copy script
        if [[ -f "${dl_img_dir}/${dp_script}" ]]; then
            run_cmd "sudo cp ${dl_img_dir}/${dp_script} ${da_img_dir}/"
        else
            log "[WARN] ${dp_script} file not found, skipping DA script copy."
        fi
    fi

  else
    # DRY_RUN mode
    log "[DRY-RUN] Skipping chmod, SHA1 verification, Rename, script modification, file copy"
  fi

  #######################################
  # 7) Final Summary
  #######################################
  : > "${tmp_info}"
  {
    echo "STEP 09 execution summary"
    echo "----------------------"
    if [[ "${use_local_qcow}" -eq 1 ]]; then
        echo "# Image Source: Reuse local file"
        echo "  - Original: ${found_local_file}"
    else
        echo "# Image Source: New download"
        echo "  - Original (URL): ${remote_qcow2}"
    fi
    echo
    echo "# Final Saved Name: ${local_qcow2}"
    echo "  (This filename will be used in Step 10/11)"
    echo
    echo "# Download Path: ${dl_img_dir}"
    echo "# Script Patch: Completed"
  } >> "${tmp_info}"

  show_textbox "STEP 09 - Result Summary" "${tmp_info}"
}



#######################################
# STEP 10/11 Dedicated Helper
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
      if ! whiptail --title "${step_name} - ${vm_name} Redeployment Confirmation" \
                    --defaultno \
                    --yesno "${msg}" 18 80; then
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

###############################################################################
# DL / DA VM Memory Configuration (GB unit) – User Input
###############################################################################
prompt_vm_memory() {
  # Use current config value as default if present, otherwise use existing hardcoded value as default
  # (186/156 here are examples: please match the values currently used in the script.)
  local default_dl="${DL_MEM_GB:-186}"
  local default_da="${DA_MEM_GB:-156}"

  local dl_input da_input

  if command -v whiptail >/dev/null 2>&1; then
    dl_input=$(whiptail --title "DL VM Memory Configuration" \
                         --inputbox "Enter DL VM memory capacity in GB.\n\n(Current default: ${default_dl} GB)" \
                         12 60 "${default_dl}" 3>&1 1>&2 2>&3) || return 1

    da_input=$(whiptail --title "DA VM Memory Configuration" \
                         --inputbox "Enter DA VM memory capacity in GB.\n\n(Current default: ${default_da} GB)" \
                         12 60 "${default_da}" 3>&1 1>&2 2>&3) || return 1
  else
    echo "Configure DL / DA VM memory capacity in GB."
    read -r -p "DL VM Memory (GB) [Default: ${default_dl}]: " dl_input
    read -r -p "DA VM Memory (GB) [Default: ${default_da}]: " da_input
  fi

  # Use default if empty
  [[ -z "${dl_input}" ]] && dl_input="${default_dl}"
  [[ -z "${da_input}" ]] && da_input="${default_da}"

  # Number validation (integers only)
  if ! [[ "${dl_input}" =~ ^[0-9]+$ ]]; then
    log "[WARN] DL memory value is not an integer: ${dl_input} → using ${default_dl} GB"
    dl_input="${default_dl}"
  fi
  if ! [[ "${da_input}" =~ ^[0-9]+$ ]]; then
    log "[WARN] DA memory value is not an integer: ${da_input} → using ${default_da} GB"
    da_input="${default_da}"
  fi

  DL_MEM_GB="${dl_input}"
  DA_MEM_GB="${da_input}"

  log "[CONFIG] DL VM Memory: ${DL_MEM_GB} GB"
  log "[CONFIG] DA VM Memory: ${DA_MEM_GB} GB"

  # Calculate KiB unit value (used in libvirt XML/virt-install)
  DL_MEM_KIB=$(( DL_MEM_GB * 1024 * 1024 ))
  DA_MEM_KIB=$(( DA_MEM_GB * 1024 * 1024 ))
}


###############################################################################
# STEP 10 - DL-master VM Deployment (using virt_deploy_uvp_centos.sh)
###############################################################################
step_10_dl_master_deploy() {
    local STEP_ID="10_dl_master_deploy"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 10. DL-master VM Deployment ====="

    # Load configuration (assume function already exists)
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DRY_RUN default value protection
    local _DRY_RUN="${DRY_RUN:-0}"

    # =========================================================================
    # [Added] VM Hostname (Role) Input Logic
    # Reason: According to PDF guide, NVRAM filename (${VM_NAME}_VARS.fd) must be unique,
    #         so user must directly specify dl-master, dl-worker1, etc.
    # =========================================================================

    # 1. Set default value (use existing config if present, otherwise dl-master)
    local default_hostname="${DL_HOSTNAME:-dl-master}"
    local vm_name_input

    # 2. Display whiptail input box
    vm_name_input=$(whiptail --title "STEP 10 - DL VM Name (Role) Configuration" \
        --inputbox "Enter the hostname of the DL VM to deploy.\n\n(Example: dl-master, dl-worker1, dl-worker2 ...)\n\n※ Important: This name will be used as NVRAM filename (\${VM_NAME}_VARS.fd)." \
        15 70 "${default_hostname}" \
        3>&1 1>&2 2>&3) || return 0  # Exit step if cancel button is pressed

    # 3. Validate input (use default if empty)
    if [[ -z "${vm_name_input}" ]]; then
        vm_name_input="dl-master"
    fi

    # 4. Update variable and save to config file (so it's remembered on re-execution)
    DL_HOSTNAME="${vm_name_input}"

    # Permanently save to config file if save_config_var function exists
    if type save_config_var >/dev/null 2>&1; then
        save_config_var "DL_HOSTNAME" "${DL_HOSTNAME}"
    fi

    log "[STEP 10] VM name to deploy confirmed: ${DL_HOSTNAME}"

    local DL_CLUSTERSIZE="${DL_CLUSTERSIZE:-1}"

    local DL_VCPUS="${DL_VCPUS:-42}"
    local DL_MEMORY_GB="${DL_MEMORY_GB:-186}"       # GB unit
    local DL_DISK_GB="${DL_DISK_GB:-500}"           # GB unit

    local DL_INSTALL_DIR="${DL_INSTALL_DIR:-/stellar/dl}"
    local DL_BRIDGE="${DL_BRIDGE:-virbr0}"

    local DL_IP="${DL_IP:-192.168.122.2}"
    local DL_NETMASK="${DL_NETMASK:-255.255.255.0}"
    local DL_GW="${DL_GW:-192.168.122.1}"
    local DL_DNS="${DL_DNS:-8.8.8.8}"

    # DP_VERSION is managed in config
    local _DP_VERSION="${DP_VERSION:-}"
    if [ -z "${_DP_VERSION}" ]; then
        whiptail --title "STEP 10 - DL Deployment" --msgbox "DP_VERSION is not set.\nPlease set the DP version in the Configuration menu first and then re-run.\nThis step will be skipped." 12 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DP_VERSION not set. Skipping DL-master deploy."
        return 0
    fi

    # DL image directory (same as STEP 09)
    local DL_IMAGE_DIR="${DL_INSTALL_DIR}/images"

    # -------------------------------------------------------------------------
    # [FIX-ALL] Clean up remaining RAW/directories regardless of VM definition (virsh dominfo) status
    #
    # 1) Even if user deploys with DL_HOSTNAME=dl-worker1, virt_deploy may use
    #    /stellar/dl/images/dl-master/ based on node-role=DL-master (role directory).
    # 2) Therefore, clean up both HOSTNAME directory + ROLE directory in advance.
    # 3) Also delete legacy flat files (.raw/.log) that are not in directory layout.
    #
    # ※ This block must always be executed first, regardless of 'virsh dominfo' success.
    # -------------------------------------------------------------------------
    local DL_DIR_HOST="${DL_IMAGE_DIR}/${DL_HOSTNAME}"
    local DL_DIR_ROLE="${DL_IMAGE_DIR}/dl-master"

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] rm -rf '${DL_DIR_HOST}' || true"
        echo "[DRY_RUN] rm -rf '${DL_DIR_ROLE}' || true"
        echo "[DRY_RUN] rm -f '${DL_IMAGE_DIR}/${DL_HOSTNAME}.raw' '${DL_IMAGE_DIR}/${DL_HOSTNAME}.log' || true"
        echo "[DRY_RUN] rm -f '${DL_IMAGE_DIR}/dl-master.raw' '${DL_IMAGE_DIR}/dl-master.log' || true"
    else
        [ -d "${DL_DIR_HOST}" ] && rm -rf "${DL_DIR_HOST}" >/dev/null 2>&1 || true
        [ -d "${DL_DIR_ROLE}" ] && rm -rf "${DL_DIR_ROLE}" >/dev/null 2>&1 || true

        rm -f "${DL_IMAGE_DIR}/${DL_HOSTNAME}.raw" "${DL_IMAGE_DIR}/${DL_HOSTNAME}.log" >/dev/null 2>&1 || true
        rm -f "${DL_IMAGE_DIR}/dl-master.raw" "${DL_IMAGE_DIR}/dl-master.log" >/dev/null 2>&1 || true
    fi

    # mgmt interface - Use value selected in STEP 01 if present, otherwise assume mgt
    local MGT_NIC_NAME="${MGT_NIC:-mgt}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [ -z "${HOST_MGT_IP}" ]; then
        # If host mgt IP cannot be obtained automatically, prompt user for input
        HOST_MGT_IP="$(whiptail --title "STEP 10 - DL Deployment" \
            --inputbox "Enter the IP of the host management interface (${MGT_NIC_NAME}).\n(Example: 10.4.0.210)" 12 80 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${HOST_MGT_IP}" ]; then
            whiptail --title "STEP 10 - DL Deployment" --msgbox "Cannot determine host management IP.\nSkipping DL-master deployment step." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] HOST_MGT_IP not available. Skipping."
            return 0
        fi
    fi

    # Locate virt_deploy_uvp_centos.sh
    # - If path saved in STEP 09 (DP_SCRIPT_PATH) exists, use it first
    # - Otherwise search in order: /stellar/dl/images, /stellar/dl, current directory
    local DP_SCRIPT_PATH_CANDIDATES=()
    [ -n "${DP_SCRIPT_PATH:-}" ] && DP_SCRIPT_PATH_CANDIDATES+=("${DP_SCRIPT_PATH}")

    # STEP 09 standard location
    DP_SCRIPT_PATH_CANDIDATES+=("${DL_IMAGE_DIR}/virt_deploy_uvp_centos.sh")
    # Consider case where it might be directly in DL_INSTALL_DIR like older versions
    DP_SCRIPT_PATH_CANDIDATES+=("${DL_INSTALL_DIR}/virt_deploy_uvp_centos.sh")
    # Case where user runs from current directory
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
        whiptail --title "STEP 10 - DL Deployment" --msgbox "virt_deploy_uvp_centos.sh file not found.\n\nPlease complete STEP 09 (DP script/image download) first and then re-run.\nThis step will be skipped." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] virt_deploy_uvp_centos.sh not found. Skipping."
        return 0
    fi

    # Check if DL image file exists → nodownload=true if exists, false otherwise
    local QCOW2_PATH="${DL_IMAGE_DIR}/aella-dataprocessor-${_DP_VERSION}.qcow2"
    local DL_NODOWNLOAD="true"

    if [ ! -f "${QCOW2_PATH}" ]; then
        # If local image doesn't exist, let script download from ACPS again
        DL_NODOWNLOAD="false"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL qcow2 image not found at ${QCOW2_PATH}. Will run with --nodownload=false."
    fi

    # Check if DL LV is mounted at /stellar/dl
    if ! mount | grep -q "on ${DL_INSTALL_DIR} "; then
        whiptail --title "STEP 10 - DL Deployment" --msgbox "${DL_INSTALL_DIR} is not currently mounted.\n\nPlease complete STEP 07 (LVM configuration) and /etc/fstab setup first,\nthen re-run.\nThis step will be skipped." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] ${DL_INSTALL_DIR} not mounted. Skipping."
        return 0
    fi

    # DL OTP: Use from config file if present, otherwise prompt once and save
    local _DL_OTP="${DL_OTP:-}"
    if [ -z "${_DL_OTP}" ]; then
        _DL_OTP="$(whiptail --title "STEP 10 - DL Deployment" \
            --passwordbox "Enter OTP value for DL-master.\n(OTP issued from ACPS)" 12 70 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${_DL_OTP}" ]; then
            whiptail --title "STEP 10 - DL Deployment" --msgbox "OTP value not entered. Skipping DL-master deployment." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL_OTP not provided. Skipping."
            return 0
        fi
        DL_OTP="${_DL_OTP}"
        # Save OTP (reflect in configuration)
        if type save_config >/dev/null 2>&1; then
            save_config
        fi
    fi

    # If VM already exists, strong warning + undefine (including nvram)
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
        # First: Strong warning + reconfirmation
        if ! confirm_destroy_vm "${DL_HOSTNAME}" "STEP 10 - DL Deployment"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Existing VM detected, user chose to keep it. Skipping."
            return 0
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Destroying and undefining existing ${DL_HOSTNAME}..."

        if [ "${_DRY_RUN}" -eq 1 ]; then
            echo "[DRY_RUN] virsh destroy '${DL_HOSTNAME}' || true"
            echo "[DRY_RUN] virsh undefine '${DL_HOSTNAME}' --nvram || virsh undefine '${DL_HOSTNAME}' || true"
        else
            virsh destroy "${DL_HOSTNAME}" >/dev/null 2>&1 || true
            virsh undefine "${DL_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DL_HOSTNAME}" >/dev/null 2>&1 || true
        fi
    fi

    ############################################################
    # DL Memory Input (default = current DL_MEMORY_GB)
    ############################################################
    local _DL_MEM_INPUT
    _DL_MEM_INPUT="$(whiptail --title "STEP 10 - DL Memory Configuration" \
        --inputbox "Enter memory (GB) to allocate to DL-master VM.\n\nCurrent default: ${DL_MEMORY_GB} GB" \
        12 70 "${DL_MEMORY_GB}" \
        3>&1 1>&2 2>&3)"

    # If user presses Cancel, keep default; if OK, validate value then apply
    if [ $? -eq 0 ] && [ -n "${_DL_MEM_INPUT}" ]; then
        # Simple numeric validation
        if [[ "${_DL_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DL_MEM_INPUT}" -gt 0 ]; then
            DL_MEMORY_GB="${_DL_MEM_INPUT}"
        else
            whiptail --title "STEP 10 - DL Memory Configuration" \
                --msgbox "Entered memory value is invalid.\nUsing existing default (${DL_MEMORY_GB} GB)." 10 70
        fi
    fi
    save_config_var "DL_MEMORY_GB" "${DL_MEMORY_GB}"

    # Save to config file if needed (reflect in configuration)
    if type save_config >/dev/null 2>&1; then
        save_config
    fi

    # Convert memory to MB
    local DL_MEMORY_MB=$(( DL_MEMORY_GB * 1024 ))

    # Command configuration for actual virt_deploy_uvp_centos.sh execution
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
--OTP=${DL_OTP} \
--ip=${DL_IP} \
--netmask=${DL_NETMASK} \
--gw=${DL_GW} \
--dns=${DL_DNS}"

    # Final confirmation dialog
    local SUMMARY
    SUMMARY="Deploy DL-master VM with the following settings:

  Hostname        : ${DL_HOSTNAME}
  Cluster Size    : ${DL_CLUSTERSIZE}
  DP Version      : ${_DP_VERSION}
  Host MGT IP     : ${HOST_MGT_IP}
  Bridge          : ${DL_BRIDGE}
  vCPU            : ${DL_VCPUS}
  Memory          : ${DL_MEMORY_GB} GB (${DL_MEMORY_MB} MB)
  Disk Size       : ${DL_DISK_GB} GB
  installdir      : ${DL_INSTALL_DIR}
  VM IP           : ${DL_IP}
  Netmask         : ${DL_NETMASK}
  Gateway         : ${DL_GW}
  DNS             : ${DL_DNS}
  nodownload      : ${DL_NODOWNLOAD}
  Script Path     : ${DP_SCRIPT_PATH}

Do you want to execute virt_deploy_uvp_centos.sh with these settings?"

    if ! whiptail --title "STEP 10 - DL Deployment" --yesno "${SUMMARY}" 24 80; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] User canceled DL-master deploy."
        return 0
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] Running DL-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Will not actually execute the above command."
        whiptail --title "STEP 10 - DL Deployment (DRY RUN)" --msgbox "DRY_RUN mode.\n\nOnly displayed the command below and did not execute it.\n\n${CMD}" 20 80
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution
    eval "${CMD}"
    local RC=$?

    if [ ${RC} -ne 0 ]; then
        whiptail --title "STEP 10 - DL Deployment" --msgbox "virt_deploy_uvp_centos.sh exited with error code ${RC}.\n\nCheck status using virsh list, virsh console ${DL_HOSTNAME}, etc." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master deploy failed with RC=${RC}."
        return ${RC}
    fi

    # Simple verification: VM definition / status
    if virsh dominfo "${DL_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] DL-master VM '${DL_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 10] WARNING: virt_deploy script finished, but virsh dominfo ${DL_HOSTNAME} failed."
    fi

    whiptail --title "STEP 10 - DL Deployment Complete" --msgbox "DL-master VM (UEFI) deployment and partition expansion configuration completed.\n\nInitial boot may take time due to Cloud-Init operations.\n\nCheck status using installation script output logs and\nvirsh list / virsh console ${DL_HOSTNAME}." 14 80

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 10. DL-master VM Deployment ====="
    echo
}



###############################################################################
# STEP 11 - DA-master VM Deployment (using virt_deploy_uvp_centos.sh)
###############################################################################
step_11_da_master_deploy() {
    local STEP_ID="11_da_master_deploy"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 11. DA-master VM Deployment ====="

    # Load configuration
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    # DRY_RUN default value protection
    local _DRY_RUN="${DRY_RUN:-0}"

    # -------------------------------------------------------------------------
    # [NEW] Get VM name (Hostname) input
    # -------------------------------------------------------------------------
    local default_hostname="${DA_HOSTNAME:-da-master}"
    local vm_name_input

    vm_name_input=$(whiptail --title "STEP 11 - DA VM Name Configuration" \
            --inputbox "Enter the hostname of the DA VM to deploy.\n\n(Example: da-master, da-worker1, da-worker2 ...)\n\n※ This name will also be used as NVRAM filename (\${VM_NAME}_VARS.fd)." \
            15 70 "${default_hostname}" \
            3>&1 1>&2 2>&3) || return 0

    if [[ -z "${vm_name_input}" ]]; then
        vm_name_input="da-master"
    fi

    # Apply entered name to variable
    DA_HOSTNAME="${vm_name_input}"

    # Save to config file
    save_config_var "DA_HOSTNAME" "${DA_HOSTNAME}"

    log "[STEP 11] Selected VM name: ${DA_HOSTNAME}"

    local DA_VCPUS="${DA_VCPUS:-46}"
    local DA_MEMORY_GB="${DA_MEMORY_GB:-156}"       # GB unit
    local DA_DISK_GB="${DA_DISK_GB:-500}"          # GB unit

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
        whiptail --title "STEP 11 - DA Deployment" --msgbox "DP_VERSION is not set.\nPlease set the DP version in the Configuration menu first and then re-run.\nThis step will be skipped." 12 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DP_VERSION not set. Skipping DA-master deploy."
        return 0
    fi

    # -------------------------------------------------------------------------
    # [FIX-ALL] Clean up remaining RAW/directories regardless of VM definition (virsh dominfo) status
    #
    # 1) Even if user deploys with DA_HOSTNAME=da-worker1, virt_deploy may leave
    #    /stellar/da/images/da-master/ or role-based directories based on node-role=resource.
    # 2) Therefore, clean up both HOSTNAME directory + ROLE directory (da-master) in advance.
    # 3) Also delete legacy flat files (.raw/.log) that are not in directory layout.
    #
    # ※ This block must always be executed first, regardless of 'virsh dominfo' success.
    # -------------------------------------------------------------------------
    local DA_DIR_HOST="${DA_IMAGE_DIR}/${DA_HOSTNAME}"
    local DA_DIR_ROLE="${DA_IMAGE_DIR}/da-master"

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] rm -rf '${DA_DIR_HOST}' || true"
        echo "[DRY_RUN] rm -rf '${DA_DIR_ROLE}' || true"
        echo "[DRY_RUN] rm -f '${DA_IMAGE_DIR}/${DA_HOSTNAME}.raw' '${DA_IMAGE_DIR}/${DA_HOSTNAME}.log' || true"
        echo "[DRY_RUN] rm -f '${DA_IMAGE_DIR}/da-master.raw' '${DA_IMAGE_DIR}/da-master.log' || true"
    else
        [ -d "${DA_DIR_HOST}" ] && rm -rf "${DA_DIR_HOST}" >/dev/null 2>&1 || true
        [ -d "${DA_DIR_ROLE}" ] && rm -rf "${DA_DIR_ROLE}" >/dev/null 2>&1 || true

        rm -f "${DA_IMAGE_DIR}/${DA_HOSTNAME}.raw" "${DA_IMAGE_DIR}/${DA_HOSTNAME}.log" >/dev/null 2>&1 || true
        rm -f "${DA_IMAGE_DIR}/da-master.raw" "${DA_IMAGE_DIR}/da-master.log" >/dev/null 2>&1 || true
    fi

    # host mgt NIC / IP
    : "${MGT_NIC:=mgt}"
    local MGT_NIC_NAME="${MGT_NIC}"
    local HOST_MGT_IP
    HOST_MGT_IP="$(ip -o -4 addr show "${MGT_NIC_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [ -z "${HOST_MGT_IP}" ]; then
        HOST_MGT_IP="$(whiptail --title "STEP 11 - DA Deployment" \
            --inputbox "Enter the IP of the host management (mgt) interface (${MGT_NIC_NAME}).\n(Example: 10.4.0.210)" 12 80 "" \
            3>&1 1>&2 2>&3)"
        if [ $? -ne 0 ] || [ -z "${HOST_MGT_IP}" ]; then
            whiptail --title "STEP 11 - DA Deployment" --msgbox "Cannot determine host management IP.\nSkipping DA-master deployment step." 10 70
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] HOST_MGT_IP not available. Skipping."
            return 0
        fi
    fi

    # cm_fqdn (DL cluster IP, CM address)
    # If not separately configured, use DL_IP or 192.168.122.2 as default
    : "${DL_IP:=192.168.122.2}"
    local CM_FQDN="${CM_FQDN:-${DL_IP}}"

    # Locate virt_deploy_uvp_centos.sh
    local DP_SCRIPT_PATH_CANDIDATES=()

    # 1) If path saved in config file exists, use it first
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
        whiptail --title "STEP 11 - DA Deployment" --msgbox "virt_deploy_uvp_centos.sh file not found.\n\nPlease complete STEP 09 (DP script/image download) first and then re-run.\nThis step will be skipped." 14 80
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
        whiptail --title "STEP 11 - DA Deployment" --msgbox "${DA_INSTALL_DIR} is not currently mounted.\n\nPlease complete STEP 07 (LVM configuration) and /etc/fstab setup first,\nthen re-run.\nThis step will be skipped." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] ${DA_INSTALL_DIR} not mounted. Skipping."
        return 0
    fi

    # If VM already exists: destroy + undefine (+nvram)
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
        # One more strong warning using common helper
        if ! confirm_destroy_vm "${DA_HOSTNAME}" "STEP 11 - DA Deployment"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Existing VM detected, user chose to keep it. Skipping."
            return 0
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Destroying and undefining existing ${DA_HOSTNAME}..."

        if [ "${_DRY_RUN}" -eq 1 ]; then
            echo "[DRY_RUN] virsh destroy '${DA_HOSTNAME}' || true"
            echo "[DRY_RUN] virsh undefine '${DA_HOSTNAME}' --nvram || virsh undefine '${DA_HOSTNAME}' || true"
        else
            virsh destroy "${DA_HOSTNAME}" >/dev/null 2>&1 || true
            virsh undefine "${DA_HOSTNAME}" --nvram >/dev/null 2>&1 || virsh undefine "${DA_HOSTNAME}" >/dev/null 2>&1 || true
        fi
    fi

    ############################################################
    # DA Memory Input (default = current DA_MEMORY_GB)
    ############################################################
    local _DA_MEM_INPUT
    _DA_MEM_INPUT="$(whiptail --title "STEP 11 - DA Memory Configuration" \
        --inputbox "Enter memory (GB) to allocate to DA-master VM.\n\nCurrent default: ${DA_MEMORY_GB} GB" \
        12 70 "${DA_MEMORY_GB}" \
        3>&1 1>&2 2>&3)"

    if [ $? -eq 0 ] && [ -n "${_DA_MEM_INPUT}" ]; then
        if [[ "${_DA_MEM_INPUT}" =~ ^[0-9]+$ ]] && [ "${_DA_MEM_INPUT}" -gt 0 ]; then
            DA_MEMORY_GB="${_DA_MEM_INPUT}"
        else
            whiptail --title "STEP 11 - DA Memory Configuration" \
                --msgbox "Entered memory value is invalid.\nUsing existing default (${DA_MEMORY_GB} GB)." 10 70
        fi
    fi

    if type save_config >/dev/null 2>&1; then
        save_config
    fi

    save_config_var "DA_MEMORY_GB" "${DA_MEMORY_GB}"

    # Convert memory to MB
    local DA_MEMORY_MB=$(( DA_MEMORY_GB * 1024 ))

    # node_role = resource (DA node)
    local DA_NODE_ROLE="resource"

    # Construct command to use for actual virt_deploy_uvp_centos.sh execution
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
  CM FQDN (DL IP) : ${CM_FQDN}
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

Do you want to execute virt_deploy_uvp_centos.sh with these settings?"

    if ! whiptail --title "STEP 11 - DA Deployment" --yesno "${SUMMARY}" 24 80; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] User canceled DA-master deploy."
        return 0
    fi

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] Running DA-master deploy command:"
    echo "  ${CMD}"
    echo

    if [ "${_DRY_RUN}" -eq 1 ]; then
        echo "[DRY_RUN] Will not actually execute the above command."
        whiptail --title "STEP 11 - DA Deployment (DRY RUN)" --msgbox "DRY_RUN mode.\n\nOnly displayed the command below and did not execute it.\n\n${CMD}" 20 80
        if type mark_step_done >/dev/null 2>&1; then
            mark_step_done "${STEP_ID}"
        fi
        return 0
    fi

    # Actual execution (existing code)
    eval "${CMD}"
    local RC=$?

    if [ ${RC} -ne 0 ]; then
        whiptail --title "STEP 11 - DA Deployment" --msgbox "virt_deploy_uvp_centos.sh exited with error code ${RC}.\n\nCheck status using virsh list, virsh console ${DA_HOSTNAME}, etc." 14 80
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master deploy failed with RC=${RC}."
        return ${RC}
    fi

    # Simple verification: VM definition / status (existing code)
    if virsh dominfo "${DA_HOSTNAME}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] DA-master VM '${DA_HOSTNAME}' successfully created/updated."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 11] WARNING: virt_deploy script finished, but virsh dominfo ${DA_HOSTNAME} failed."
    fi

    whiptail --title "STEP 11 - DA Deployment Complete" --msgbox "DA-master VM (UEFI) deployment and partition expansion configuration completed.\n\nInitial boot may take time due to Cloud-Init operations.\n\nCheck status using installation script output logs and\nvirsh list / virsh console ${DA_HOSTNAME}." 14 80

    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 11. DA-master VM Deployment ====="
    echo
}



###############################################################################
# STEP 12 – SR-IOV VF Passthrough + CPU Affinity + CD-ROM Removal + DL Data LV
###############################################################################
step_12_sriov_cpu_affinity() {
    local STEP_ID="12_sriov_cpu_affinity"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP START: ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM Removal + DL Data LV ====="

    # Load config
    if type load_config >/dev/null 2>&1; then
        load_config
    fi

    local _DRY="${DRY_RUN:-0}"

    # Use hostnames saved in STEP 10/11 as-is (dl-worker1, etc.)
    local DL_VM="${DL_HOSTNAME:-dl-master}"
    local DA_VM="${DA_HOSTNAME:-da-master}"

	# =========================================================================
	# [Moved] UEFI/XML conversion and partition expansion logic moved from steps 10/11 (modified version)
	# =========================================================================
	if [[ "${_DRY}" -eq 0 ]]; then
	    log "[STEP 12] Before SR-IOV/CPU configuration, performing PDF guide-based UEFI/XML conversion (regeneration) first."

	    # -----------------------------------------------------------------
	    # [Important] Force load memory values from config file (fix 186GB issue)
	    # -----------------------------------------------------------------
	    if [[ -f "${CONFIG_FILE}" ]]; then
	        # Directly find and read DL_MEMORY_GB value from config file
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
        
	        # [Modified] Changed default to 136 & unified variable names to prevent typos
	        # Use DL_MEMORY_GB read from config file if present, otherwise use 136
	        local dl_mem_gb="${DL_MEMORY_GB:-136}"
        
	        log "[STEP 12] DL-master memory applied value: ${dl_mem_gb} GB"

	        # Calculate KiB (use variable name dl_mem_gb exactly here)
	        local dl_mem_kib=$(( dl_mem_gb * 1024 * 1024 ))
        
	        # Assume default path
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

	        # [Modified] Keep default at 80
	        local da_mem_gb="${DA_MEMORY_GB:-156}"
        
	        log "[STEP 12] DA-master memory applied value: ${da_mem_gb} GB"

	        local da_mem_kib=$(( da_mem_gb * 1024 * 1024 ))
	        local da_raw_disk="${da_install_dir}/images/${DA_VM}/${DA_VM}.raw"

	        # Call common patch function
	        apply_pdf_xml_patch "${DA_VM}" "${da_mem_kib}" "${da_vcpus}" "${da_bridge}" "${da_raw_disk}"
	    else
	        log "[WARN] ${DA_VM} does not exist, skipping UEFI conversion."
	    fi
    
	    log "[STEP 12] UEFI XML conversion completed. Now adding SR-IOV and CPU Affinity configuration."
	else
	    log "[DRY-RUN] Simulating UEFI XML conversion and Raw conversion process to be performed in Step 12."
	fi
	# =========================================================================


    ###########################################################################
    # CPU PINNING RULES (NUMA Separation)
    # - DL: NUMA node0 (even cores) even numbers between 4~86 → 42 cores (4,6,...,86)
    # - DA: NUMA node1 (odd cores) odd numbers between 5~95 → 46 cores (5,7,...,95)
    #   * Assume 0,2 reserved for host in NUMA0, 1,3 reserved for host in NUMA1
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
    # 1. SR-IOV VF PCI Auto-Detection
    ###########################################################################
    log "[STEP 12] Auto-detecting SR-IOV VF PCI devices"

    local vf_list
    vf_list="$(lspci | awk '/Ethernet/ && /Virtual Function/ {print $1}' || true)"

    if [[ -z "${vf_list}" ]]; then
        whiptail --title "STEP 12 - SR-IOV" --msgbox "Failed to detect SR-IOV VF PCI devices.\nPlease check STEP 03 or BIOS settings." 12 70
        log "[STEP 12] No SR-IOV VF → Stopping STEP"
        return 1
    fi

    log "[STEP 12] Detected VF list:\n${vf_list}"

    local DL_VF DA_VF
    DL_VF="$(echo "${vf_list}" | sed -n '1p')"
    DA_VF="$(echo "${vf_list}" | sed -n '2p')"

    if [[ -z "${DA_VF}" ]]; then
        log "[WARN] Only 1 VF exists, applying VF Passthrough only to DL, DA will only have CPU Affinity without VF"
    fi

    ###########################################################################
    # 2. DL/DA VM shutdown (wait until completely down)
    ###########################################################################
    log "[STEP 12] Requesting DL/DA VM shutdown"

    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            local state
            state="$(virsh dominfo "${vm}" | awk -F': +' '/State/ {print $2}')"
            if [[ "${state}" != "shut off" ]]; then
                log "[STEP 12] Requesting ${vm} shutdown"
                (( _DRY )) || virsh shutdown "${vm}" || log "[WARN] ${vm} shutdown failed (ignoring and continuing)"
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
    # 3. CD-ROM Removal (assume detach-disk hda --config)
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
        # Ignore failures as they are not critical
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

        # PCI format: DDDD:BB:SS.F  (Example: 0000:8b:11.0)
        if [[ "${pci}" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
            domain="${BASH_REMATCH[1]}"
            bus="${BASH_REMATCH[2]}"
            slot="${BASH_REMATCH[3]}"
            func="${BASH_REMATCH[4]}"
        # Also handle BB:SS.F format just in case (Example: 8b:11.0)
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

        # Maximum vCPU count (design says DL=42, DA=46, but check based on actual XML)
        local max_vcpus
        max_vcpus="$(virsh vcpucount "${vm}" --maximum --config 2>/dev/null || echo 0)"

        if [[ "${max_vcpus}" -eq 0 ]]; then
            log "[WARN] ${vm}: Cannot determine vCPU count → Skipping CPU Affinity"
            return 0
        fi

        # Convert cpus_list to array
        local arr=()
        local c
        for c in ${cpus_list}; do
            arr+=("${c}")
        done

        if [[ "${#arr[@]}" -lt "${max_vcpus}" ]]; then
            log "[WARN] ${vm}: Specified CPU list count (${#arr[@]}) is less than maximum vCPU (${max_vcpus})."
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
    # 6. NUMA Memory Interleave (virsh numatune --config)
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
    # 7. DL Data Disk (LV) Attach (vg_dl/lv_dl → vdb, --config)
    ###########################################################################
    local DATA_LV="/dev/mapper/vg_dl-lv_dl"

    if [[ -e "${DATA_LV}" ]]; then
        if virsh dominfo "${DL_VM}" >/dev/null 2>&1; then
            if [[ "${_DRY}" -eq 1 ]]; then
                log "[DRY-RUN] virsh attach-disk ${DL_VM} ${DATA_LV} vdb --config"
            else
                if virsh dumpxml "${DL_VM}" | grep -q "target dev='vdb'"; then
                    log "[STEP 12] ${DL_VM} already has vdb → Skipping data disk attach"
                else
                    if virsh attach-disk "${DL_VM}" "${DATA_LV}" vdb --config >/dev/null 2>&1; then
                        log "[STEP 12] ${DL_VM} data disk (${DATA_LV}) attached as vdb (--config) completed"
                    else
                        log "[WARN] ${DL_VM} data disk (${DATA_LV}) attach failed"
                    fi
                fi
            fi
        else
            log "[STEP 12] ${DL_VM} VM not found → Skipping DL data disk attach"
        fi
    else
        log "[STEP 12] ${DATA_LV} does not exist, skipping DL data disk attach."
    fi

    ###########################################################################
    # 8. DL/DA VM Restart
    ###########################################################################
    for vm in "${DL_VM}" "${DA_VM}"; do
        if virsh dominfo "${vm}" >/dev/null 2>&1; then
            log "[STEP 12] Requesting ${vm} start"
            (( _DRY )) || virsh start "${vm}" || log "[WARN] ${vm} start failed"
        fi
    done

    # ★ Add here: Wait 5 seconds after VM start
    if [[ "${_DRY}" -eq 0 ]]; then
        log "[STEP 12] Waiting 5 seconds after DL/DA VM start (waiting for vCPU state stabilization)"
        sleep 5
    fi

    ###########################################################################
    # 9. Display basic verification results with show_paged
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

                show_paged "STEP 12 – SR-IOV / CPU Affinity / DL Data LV Verification Results" "${result_file}"
        
    fi

    ###########################################################################
    # 10. Mark STEP completion and exit log
    ###########################################################################
    if type mark_step_done >/dev/null 2>&1; then
        mark_step_done "${STEP_ID}"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== STEP END:   ${STEP_ID} - 12. SR-IOV + CPU Affinity + CD-ROM Removal + DL Data LV ====="
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

    if ! whiptail --title "STEP 13 Execution Confirmation" \
                  --yesno "Install DP Appliance CLI package (dp_cli) on the host\nand apply it to the stellar user.\n\n(Use dp_cli-*.tar.gz / dp_cli-*.tar files in current directory)\n\nDo you want to continue?" 15 85
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

    # 1) Search for local dp_cli package
    local pkg=""
    pkg="$(ls -1 ./dp_cli-*.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "${pkg}" ]]; then
        pkg="$(ls -1 ./dp_cli-*.tar 2>/dev/null | sort -V | tail -n 1 || true)"
    fi

    if [[ -z "${pkg}" ]]; then
        whiptail --title "STEP 13 - DP CLI Installation" \
                 --msgbox "No dp_cli-*.tar.gz or dp_cli-*.tar file found in current directory (.).\n\nExample: dp_cli-0.0.2.dev8402.tar.gz\n\nPlease prepare the file and re-run STEP 13." 14 90
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: dp_cli package not found in current directory."
        return 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] dp_cli package file detected: ${pkg}"

    # 2) required packages
    run_cmd "apt-get update -y"
    run_cmd "apt-get install -y python3-pip python3-venv"

    # 3) Create/initialize venv then install dp-cli
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

        # setuptools<81 pin
        "${VENV_DIR}/bin/python" -m pip install --upgrade pip "setuptools<81" wheel >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: venv pip/setuptools installation failed" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        "${VENV_DIR}/bin/python" -m pip install --upgrade --force-reinstall "${pkg}" >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: dp-cli installation failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        (cd /tmp && "${VENV_DIR}/bin/python" -c "import dp_cli; print('dp_cli import OK')") >>"${ERRLOG}" 2>&1 || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: dp_cli import failed (venv)" | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: Please check ${ERRLOG}." | tee -a "${ERRLOG}"
            return 1
        }

        if [[ ! -x "${VENV_DIR}/bin/aella_cli" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] ERROR: ${VENV_DIR}/bin/aella_cli does not exist." | tee -a "${ERRLOG}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] HINT: dp-cli package must include console_scripts (aella_cli) entry point." | tee -a "${ERRLOG}"
            return 1
        fi

        # Runtime verification performed only based on import (removed aella_cli execution smoke test)
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; import dp_cli; from dp_cli import aella_cli_aio_appliance; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || {
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

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: venv dp_cli import"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import dp_cli; print('dp_cli import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: venv pkg_resources"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; print('pkg_resources OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: runtime import check"
        (cd /tmp && "${VENV_DIR}/bin/python" -c "import pkg_resources; import dp_cli; from dp_cli import aella_cli_aio_appliance; print('runtime import OK')") >>"${ERRLOG}" 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP 13] verify: error log path => ${ERRLOG}"
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
    # Load latest configuration
    load_config

    local msg
    msg="Current Settings\n\n"
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
                      --yesno "Current DRY_RUN=1 (simulation mode).\n\nDo you want to change to DRY_RUN=0 (actual execution mode)?" 12 70
          then
            DRY_RUN=0
          fi
        else
          if whiptail --title "DRY_RUN Configuration" \
                      --yesno "Current DRY_RUN=0 (actual execution mode).\n\nDo you want to safely change to DRY_RUN=1 (simulation mode)?" 12 70
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
                           --inputbox "Enter DP version (Example: 6.2.1)." 10 60 "${DP_VERSION}" \
                           3>&1 1>&2 2>&3) || continue
        if [[ -n "${new_ver}" ]]; then
          DP_VERSION="${new_ver}"
          save_config
          whiptail --title "DP_VERSION Configuration" \
                   --msgbox "DP_VERSION has been set to ${DP_VERSION}." 8 60
        fi
        ;;

      "3")
        # ACPS Account / Password
        local user pass
        user=$(whiptail --title "ACPS Account Configuration" \
                        --inputbox "Enter ACPS account (ID)." 10 60 "${ACPS_USERNAME}" \
                        3>&1 1>&2 2>&3) || continue
        if [[ -z "${user}" ]]; then
          continue
        fi

        pass=$(whiptail --title "ACPS Password Configuration" \
                        --passwordbox "Enter ACPS password.\n(This value will be saved in the config file and automatically used in STEP 09)" 10 60 "${ACPS_PASSWORD}" \
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

  show_textbox "Installation Log (Last 200 Lines)" /tmp/xdr_log.txt
}

# Return summary of overall configuration validation results as English messages
build_validation_summary() {
  local validation_log="$1"   # Can check based on logs if needed, but here we re-check actual status

  local ok_msgs=()
  local warn_msgs=()
  local err_msgs=()

  ###############################
  # 1. HWE Kernel + IOMMU (grub)
  ###############################
  # Criteria:
  #   If dpkg -l full output contains any of the following strings, consider HWE kernel installation complete
  #     - linux-image-generic-hwe-24.04
  #     - linux-generic-hwe-24.04

  local hwe_found=0

  # || true to prevent entire script from dying if dpkg -l fails
  if LANG=C dpkg -l 2>/dev/null | grep -qE 'linux-(image-)?generic-hwe-24\.04' || true; then
    # grep exits 0 if matching line found, 1 if not found
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
  # 2. NIC (mgt, cltr0) / Network
  ###############################
  if ip link show mgt >/dev/null 2>&1 && ip link show cltr0 >/dev/null 2>&1; then
    ok_msgs+=("mgt / cltr0 interface rename applied")
  else
    err_msgs+=("mgt or cltr0 interface not visible. Need to re-check 03_NIC/ifupdown configuration (udev rename and /etc/network/interfaces.d/*).")
  fi

  # Check include setting in /etc/network/interfaces
  if grep -qE '^source /etc/network/interfaces.d/\*' /etc/network/interfaces 2>/dev/null; then
    ok_msgs+=("/etc/network/interfaces includes /etc/network/interfaces.d/* setting confirmed")
  else
    warn_msgs+=("/etc/network/interfaces does not have 'source /etc/network/interfaces.d/*' line. If mgt/cltr0 individual settings are in interfaces.d/*.cfg, include setting must be added.")
  fi

  if systemctl is-active --quiet networking; then
    ok_msgs+=("ifupdown-based networking service enabled")
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
    ok_msgs+=("libvirtd service enabled")
  else
    err_msgs+=("libvirtd service is inactive. Please run 'sudo systemctl enable --now libvirtd' before using virsh.")
  fi

  ###############################
  # 4. Kernel Tuning / KSM / Swap
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
      warn_msgs+=("KSM is still enabled (run=${ksm_run}). /etc/default/qemu-kvm configuration and service restart may be required.")
    fi
  fi

  if swapon --show | grep -q .; then
    warn_msgs+=("swap is still enabled. Need to re-check /swap.img comment-out and swapoff status.")
  else
    ok_msgs+=("swap disabled")
  fi

  ###############################
  # 5. NTPsec
  ###############################
  if systemctl is-active --quiet ntpsec; then
    ok_msgs+=("ntpsec service enabled")
  else
    warn_msgs+=("ntpsec service is not in active state. Time synchronization issues may occur, please configure ntpsec or alternative NTP service.")
  fi

  ###############################
  # 6. LVM / /stellar Mount
  ###############################
  if grep -q 'lv_dl_root' /etc/fstab && grep -q 'lv_da_root' /etc/fstab; then
    # Also check mount point directory existence
    if [[ -d /stellar/dl && -d /stellar/da ]]; then
      if mountpoint -q /stellar/dl && mountpoint -q /stellar/da; then
        ok_msgs+=("lv_dl_root / lv_da_root registered in fstab and /stellar/dl, /stellar/da mounted")
      else
        warn_msgs+=("Registered in fstab but /stellar/dl or /stellar/da mount appears missing. Please check 'mount -a' or individual mounts.")
      fi
    else
      warn_msgs+=("/stellar/dl or /stellar/da directory does not exist. Need to create directory and remount.")
    fi
  else
    err_msgs+=("/etc/fstab does not have lv_dl_root / lv_da_root entries. Please modify fstab referring to LVM configuration section in installation guide.")
  fi

  ###############################
  # 7. VM Deployment Status / SR-IOV / CPU Pin / CD-ROM
  ###############################
  local dl_defined=0
  local da_defined=0

  if virsh dominfo dl-master >/dev/null 2>&1; then
    dl_defined=1
  fi
  if virsh dominfo da-master >/dev/null 2>&1; then
    da_defined=1
  fi

  # 7-1. VM Definition Status
  if (( dl_defined == 1 && da_defined == 1 )); then
    ok_msgs+=("dl-master / da-master libvirt domain definition completed")
  elif (( dl_defined == 1 || da_defined == 1 )); then
    warn_msgs+=("Only one of dl-master or da-master is defined. Please check virt_deploy step progress.")
  else
    warn_msgs+=("dl-master / da-master domains not yet defined. This is normal if before STEP 10/11 execution.")
  fi

  # 7-2. dl-master detailed verification (only if defined)
  if (( dl_defined == 1 )); then
    # SR-IOV hostdev
    if virsh dumpxml dl-master 2>/dev/null | grep -q '<hostdev '; then
      ok_msgs+=("dl-master SR-IOV VF (hostdev) passthrough configuration detected")
    else
      warn_msgs+=("dl-master XML does not yet have hostdev (SR-IOV) configuration. If using SR-IOV, need to complete STEP 12 (SR-IOV/CPU Affinity).")
    fi

    # CPU pinning (cputune)
    if virsh dumpxml dl-master 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("dl-master CPU pinning (cputune) configuration detected")
    else
      warn_msgs+=("dl-master XML does not have CPU pinning (cputune) configuration. NUMA-based vCPU placement may not be applied.")
    fi

    # CD-ROM / ISO connection status
    if virsh dumpxml dl-master 2>/dev/null | grep -q '\.iso'; then
      warn_msgs+=("dl-master XML still has ISO (.iso) file connected. Need to remove ISO using virsh change-media or XML editing.")
    else
      ok_msgs+=("dl-master ISO not connected (even if CD-ROM device remains, .iso file is not connected)")
    fi
  fi

  # 7-3. da-master detailed verification (only if defined)
  if (( da_defined == 1 )); then
    # SR-IOV hostdev
    if virsh dumpxml da-master 2>/dev/null | grep -q '<hostdev '; then
      ok_msgs+=("da-master SR-IOV VF (hostdev) passthrough configuration detected")
    else
      warn_msgs+=("da-master XML does not yet have hostdev (SR-IOV) configuration. If using SR-IOV, need to complete STEP 12 (SR-IOV/CPU Affinity).")
    fi

    # CPU pinning (cputune)
    if virsh dumpxml da-master 2>/dev/null | grep -q '<cputune>'; then
      ok_msgs+=("da-master CPU pinning (cputune) configuration detected")
    else
      warn_msgs+=("da-master XML does not have CPU pinning (cputune) configuration. NUMA-based vCPU placement may not be applied.")
    fi

    # CD-ROM / ISO connection status
    if virsh dumpxml da-master 2>/dev/null | grep -q '\.iso'; then
      warn_msgs+=("da-master XML still has ISO (.iso) file connected. Need to remove ISO using virsh change-media or XML editing.")
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
  # Assemble summary messages (error → warning → normal)
  ###############################
  local summary=""
  local ok_cnt=${#ok_msgs[@]}
  local warn_cnt=${#warn_msgs[@]}
  local err_cnt=${#err_msgs[@]}

  summary+="[Overall Configuration Validation Summary]\n\n"

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

  # 4) OK only one line, not listed in detail
  if (( err_cnt == 0 && warn_cnt == 0 )); then
    summary+="[OK]\n"
    summary+="  - All validation items match installation guide.\n"
  else
    summary+="[OK]\n"
    summary+="  - Remaining validation items other than those listed above are judged to be within normal range without major issues.\n"
  fi

  echo "${summary}"
}



menu_full_validation() {
  # Full validation is read-only commands, so must execute actual commands regardless of DRY_RUN
  # Temporarily ignore errors in this block because set -e would exit if any command fails
  set +e

  local tmp_file="/tmp/xdr_full_validation_$(date '+%Y%m%d-%H%M%S').log"

  {
    echo "========================================"
    echo " XDR Installer Overall Configuration Validation"
    echo " Execution time: $(date '+%F %T')"
        echo
        echo " *** Press spacebar or down arrow to see next message." 
        echo " *** Press q to exit this message."
    echo "========================================"
    echo

    ##################################################
    # 1. HWE Kernel / IOMMU / GRUB Configuration Validation
    ##################################################
    echo "## 1. HWE Kernel / IOMMU / GRUB Configuration Validation"
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
    # 2. NIC / ifupdown / Routing Table Validation
    ##################################################
    echo "## 2. NIC / ifupdown / Routing Table Validation"
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
    # 3. KVM / Libvirt / default Network Validation
    ##################################################
    echo "## 3. KVM / Libvirt / default Network Validation"
    echo

    echo "\$ lsmod | grep kvm"
    lsmod | grep kvm 2>&1 || echo "[WARN] kvm-related kernel modules do not appear to be loaded."
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
    # 4. Kernel Tuning / KSM / Swap Configuration Validation
    ##################################################
    echo "## 4. Kernel Tuning / KSM / Swap Configuration Validation"
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
    # 5. NTPsec Configuration Validation
    ##################################################
    echo "## 5. NTPsec Configuration Validation"
    echo

    echo "\$ systemctl status ntpsec --no-pager"
    systemctl status ntpsec --no-pager 2>&1 || echo "[WARN] ntpsec service status check failed"
    echo

    echo "\$ ntpq -p"
    ntpq -p 2>&1 || echo "[WARN] ntpq -p execution failed (NTP synchronization may not have occurred)."
    echo

    ##################################################
    # 6. LVM / Filesystem / Mount Validation
    ##################################################
    echo "## 6. LVM / Filesystem / Mount Validation"
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
    # 7. libvirt hooks / OOM Recovery Script / cron Validation
    ##################################################
    echo "## 7. libvirt hooks / OOM Recovery Script / cron Validation"
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
    ls -l /usr/bin/last_known_good_pid /usr/bin/check_vm_state 2>&1 || echo "[WARN] last_known_good_pid or check_vm_state script not found."
    echo

    echo "\$ crontab -l"
    crontab -l 2>&1 || echo "[INFO] root crontab is empty or cannot be accessed."
    echo


    ##################################################
    # 8. VM Deployment Status / SR-IOV / CPU Affinity / Disk Validation
    ##################################################
    echo "## 8. VM Deployment Status / SR-IOV / CPU Affinity / Disk Validation"
    echo

    echo "\$ virsh list --all"
    virsh list --all 2>&1 || echo "[WARN] virsh list --all execution failed"
    echo

    echo "\$ virsh dominfo dl-master"
    virsh dominfo dl-master 2>&1 || echo "[WARN] Failed to retrieve dl-master domain information."
    echo

    echo "\$ virsh dominfo da-master"
    virsh dominfo da-master 2>&1 || echo "[WARN] Failed to retrieve da-master domain information."
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
    echo " Overall Configuration Validation Complete"
    echo "========================================"
    echo

  } > "${tmp_file}"

  # Re-enable set -e
  set -e

  # 1) Generate summary
  local summary
  summary=$(build_validation_summary "${tmp_file}")

  # 2) Show summary first with msgbox
  whiptail --title "Overall Configuration Validation Summary" \
           --msgbox "${summary}" 25 90

  # 3) View full validation log in detail with less
  show_paged "Overall Configuration Validation Results (Detailed Log)" "${tmp_file}"
}


#######################################
# Script Usage Guide (using show_paged)
#######################################
show_usage_help() {

  local msg
  msg=$'────────────────────────────────────────────────────────────
              ⭐ Stellar Cyber Open XDR Platform – KVM Installer Usage Guide ⭐
────────────────────────────────────────────────────────────


📌 **Essential Information Before Use**
- This installer requires *root privileges*.
  Please start in the following order:
    1) Switch to root with sudo -i
    2) Create /root/xdr-installer directory
    3) Save this script in that directory and execute
- Guide messages: Press **spacebar / ↓ arrow key** to move to next page
- To exit, press **q**


────────────────────────────────────────────
① 🔰 When using immediately after initial Ubuntu 24.04 installation
────────────────────────────────────────────
- Selecting menu **1 (Full Auto Execution)** will  
  automatically execute STEP 01 → STEP 02 → STEP 03 → … in order.

- **STEP 03, STEP 05 are steps that require server reboot.**
    → After reboot, run the script again and  
       selecting menu 1 again will **automatically continue from the next step**.

────────────────────────────────────────────
② 🔧 When some installation/environment is already configured
────────────────────────────────────────────
- Menu **3 (Configuration)** allows you to configure:
    • DRY_RUN (simulation mode) — Default: DRY_RUN=1  
    • DP_VERSION  
    • ACPS authentication information, etc.

- After configuration, selecting menu **1** will  
  automatically proceed from "the next step that is not yet completed".

────────────────────────────────────────────
③ 🧩 When you want to run only specific features or individual steps
────────────────────────────────────────────
- Example: DL / DA redeployment, new DP image download, etc.  
- Menu **2 (Execute Specific STEP)** allows you to run only the desired step independently.

────────────────────────────────────────────
④ 🔍 After full installation completion – Configuration verification step
────────────────────────────────────────────
- After completing all installation, executing menu **4 (Overall Configuration Validation)** allows you to  
  verify that the following items match the installation guide:
    • KVM configuration  
    • DL / DA VM deployment status  
    • Network / SR-IOV / Storage configuration, etc.

- If WARN messages appear during verification,  
  you can reapply necessary settings individually from menu **2**.

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
         (Hyper-threading enabled → Total 96 vCPUs)
  - Memory: 256GB or more
  - Disk Configuration:
      • Ubuntu OS + DL/DA VM → 1.92TB SSD (SATA)  
      • Elastic Data Lake → Total 23TB  
        (3.84TB SSD × 6, SATA)
  - NIC Configuration:
      • Management/Data Network: 1Gb or 10Gb  
      • Cluster Network: Intel X710 or E810 Dual-Port 10/25GbE SFP28

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
  choice=$(whiptail --title "XDR Installer - Select Step to Execute" \
                    --menu "Select the step to execute:" 20 80 10 \
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

  if ! whiptail --title "XDR Installer - Auto Proceed" \
                --yesno "From current state, the next step is:\n\n${next_step_name}\n\nDo you want to execute sequentially from this step?" 15 70
  then
    # No / Cancel → Cancel auto proceed, return to main menu (not an error)
    log "User canceled auto proceed."
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
          "1" "Auto execute all steps (proceed from next step based on current state)" \
          "2" "Execute specific step only" \
          "3" "Configuration (DRY_RUN, DP_VERSION, etc.)" \
          "4" "Overall configuration validation" \
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
# Entry Point
#######################################

main_menu