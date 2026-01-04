# OpenXDR KVM Installer

This repository contains automated deployment scripts for Stellar Cyber's OpenXDR Data Processor and Sensor components on KVM (Kernel-based Virtual Machine) hypervisors.

## Overview

These scripts provide an interactive, menu-driven installation process using `whiptail` for a text-based user interface (TUI). They automate the complete setup process for deploying OpenXDR components, including hardware detection, network configuration, KVM setup, and VM deployment.

The repository includes installers for:
- **Data Processor (DP)**: Standalone Data Processor deployment (Ubuntu 16.04 or 24.04 based)
- **Sensor**: Standalone Sensor deployment (standard or high-performance m6000-style)
- **AIO + Sensor**: Integrated deployment of both AIO (All-In-One) Data Processor and Sensor components on a single host

## Scripts

### Data Processor Installers

#### Ubuntu 16.04 base DP installer.sh

Deploys OpenXDR Data Processor versions up to **v6.2** on KVM. This installer is designed for Data Processors that use Ubuntu 16.04 as their base operating system.

**Key Features:**
- Automated hardware detection and selection
- Network configuration with custom interface naming
- KVM/libvirt setup and configuration
- Automated VM deployment for DL (Data Lake) and DA (Data Analytics) components
- SR-IOV configuration for high-performance networking

**Network Configuration:**
- **KVM Management Interface**: Automatically configured with IP address `192.168.0.100` for local KVM management
- **DL/DA Communication & Management**: Interfaces connected via NAT for communication and management
- **Cluster Interface**: Connected using SR-IOV-based Virtual Functions (VF) for high-performance cluster networking

#### Ubuntu 24.04 base DP Installer.sh

Deploys OpenXDR Data Processor versions **v6.3 and above** on KVM. This installer is designed for Data Processors that use Ubuntu 24.04 as their base operating system.

**Key Features:**
- Same automation features as the Ubuntu 16.04 installer
- Updated for Ubuntu 24.04 compatibility
- Enhanced kernel and hardware support

**Network Configuration:**
- **KVM Management Interface**: Automatically configured with IP address `192.168.0.100` for local KVM management
- **DL/DA Communication & Management**: Interfaces connected via NAT for communication and management
- **Cluster Interface**: Connected using SR-IOV-based Virtual Functions (VF) for high-performance cluster networking

### Sensor Installers

#### AIO-Sensor installer.sh

Deploys OpenXDR AIO (All-In-One) Data Processor and Sensor components together on KVM in a single integrated installation process. This installer provides a unified deployment solution for environments requiring both Data Processor and Sensor components on the same host.

**Key Features:**
- **Integrated Deployment**: Deploys both AIO (Data Processor) and Sensor VMs in a single installation process
- **13-Step Installation Process**: Comprehensive step-by-step installation with state tracking
- **Automatic Resource Calculation**: Automatically calculates VM resources (vCPU, memory) based on available system resources
- **LVM Storage Management**: Automated LVM storage configuration for both AIO and Sensor VMs
- **Hardware Enablement Kernel (HWE)**: Installs HWE kernel for better hardware support on Ubuntu systems
- **Network Mode**: NAT mode support for management and communication
- **SPAN Interface Support**: Multiple SPAN interfaces can be attached using PCI passthrough or bridge mode

**Installation Steps:**
1. Hardware / NIC / CPU / Memory / SPAN NIC Selection
2. HWE Kernel Installation
3. NIC Name/ifupdown Switch and Network Configuration
4. KVM / Libvirt Installation and Basic Configuration
5. Kernel Parameters / KSM / Swap Tuning
6. libvirt Hooks Installation
7. LVM Storage Configuration (AIO)
8. DP Download (AIO)
9. AIO VM Deployment
10. Sensor LV Creation + Image/Script Download
11. Sensor VM Deployment
12. PCI Passthrough / CPU Affinity
13. Install DP Appliance CLI package

**Network Configuration:**
- **Management Interface**: NAT mode for host and VM management
- **AIO Communication**: NAT-based network for AIO VM communication
- **Sensor Communication**: NAT-based network for Sensor VM communication
- **SPAN Interfaces**: Can be attached to Sensor VM using either:
  - PCI passthrough (recommended for best performance, requires IOMMU)
  - Bridge mode (alternative virtualized networking option)

**System Requirements:**
- **Operating System**: Ubuntu Server 20.04 / 22.04 / 24.04 LTS
- **CPU**: 12 vCPU or more (automatically calculated)
- **Memory**: 16GB or more (automatically calculated)
- **Disk**: Minimum 100GB free space (80GB minimum) in ubuntu-vg volume group
- **BIOS Settings**: Intel VT-d / AMD-Vi (IOMMU) enabled for PCI passthrough

**Special Notes:**
- System automatically reboots after STEP 03 (network configuration) and STEP 05 (kernel tuning)
- After reboot, simply run the installer again to automatically continue from the next step
- Netplan is disabled and replaced with ifupdown during installation (STEP 03)
- DRY_RUN mode (default: enabled) allows testing without making actual changes

#### xdr-6000-sensor-installer.sh

Deploys OpenXDR modular sensors on KVM, optimized for high-performance deployments similar to Stellar Cyber m6000 appliances.

**Key Features:**
- **Dual NUMA Node Architecture**: Deploys 2 sensor VMs across 2 NUMA nodes
- **High Performance**: Each VM supports 20 Gbps, providing up to **40 Gbps total sensor capacity**
- Flexible network configuration options

**Network Configuration:**
- **Management Interface**: Configurable as NAT or bridge mode
- **SPAN Interfaces**: Multiple SPAN interfaces can be selected and attached to sensors using either:
  - PCI passthrough (for direct hardware access)
  - Bridge mode (for virtualized networking)

#### xdr-sensor-installer.sh

Deploys OpenXDR modular sensors on KVM with flexible configuration options.

**Key Features:**
- Standard modular sensor deployment
- Flexible network configuration
- Support for multiple SPAN interfaces

**Network Configuration:**
- **Management Interface**: Configurable as NAT or bridge mode
- **SPAN Interfaces**: Multiple SPAN interfaces can be selected and attached to sensors using either:
  - PCI passthrough (for direct hardware access)
  - Bridge mode (for virtualized networking)

## Prerequisites

- **Operating System**: Ubuntu Server (version depends on the installer)
- **Root Access**: Scripts must be run with root privileges
- **Required Tools**: 
  - `whiptail` (for TUI interface)
  - KVM/libvirt support
  - Hardware virtualization enabled in BIOS

## Installation

1. Clone this repository or download the installer script for your target component
2. Switch to root user:
   ```bash
   sudo -i
   ```
3. Create the installation directory:
   ```bash
   mkdir -p /root/xdr-installer
   ```
4. Copy the appropriate installer script to the directory
5. Make the script executable:
   ```bash
   chmod +x <installer-script>.sh
   ```
6. Run the installer:
   ```bash
   ./<installer-script>.sh
   ```

## Usage

All installers provide an interactive menu-driven interface:

1. **Auto Execute All Steps**: Automatically executes all installation steps sequentially
2. **Execute Specific Step**: Run individual steps as needed
3. **Configuration**: Configure settings such as:
   - DRY_RUN mode (simulation mode)
   - Component versions
   - ACPS authentication information
4. **Full Configuration Validation**: Verify all configuration matches installation requirements
5. **Script Usage Guide**: View detailed usage instructions

## Features

- **Interactive TUI**: User-friendly text-based interface using `whiptail`
- **Step-by-Step Execution**: Modular step execution with state tracking
- **DRY_RUN Mode**: Test installations without making actual changes (default enabled)
- **State Management**: Tracks installation progress and allows resuming from any step
- **Comprehensive Logging**: Detailed logs for troubleshooting
- **Hardware Detection**: Automatic detection and selection of network interfaces and storage devices
- **Network Configuration**: Automated network setup with custom naming, SR-IOV support (DP installers), and NAT mode (Sensor/AIO installers)
- **VM Deployment**: Automated deployment of Data Processor and Sensor VMs
- **Automatic Resource Calculation**: VM resources (vCPU, memory) are automatically calculated based on available system resources
- **LVM Storage Management**: Automated LVM storage configuration for VM deployment
- **Hardware Enablement Kernel (HWE)**: Automatic HWE kernel installation for better hardware support
- **Auto-Reboot Support**: Automatic system reboots when necessary (e.g., after kernel installation or network configuration) with automatic resume

## Notes

- The installers automatically handle reboots when necessary (e.g., after kernel installation or network configuration)
- After a reboot, simply run the installer again and it will automatically continue from the next step
- All configuration is saved and can be reviewed or modified through the configuration menu
- **AIO-Sensor installer**: 
  - Netplan is automatically disabled and replaced with ifupdown during network configuration (STEP 03)
  - System automatically reboots after STEP 03 (network configuration) and STEP 05 (kernel tuning)
  - DRY_RUN mode is enabled by default - set DRY_RUN=0 in the configuration menu for actual installation
  - PCI passthrough for SPAN interfaces requires IOMMU to be enabled in BIOS
  - VM resources are automatically calculated - no manual configuration needed

## Support

For issues, questions, or contributions, please refer to the repository's issue tracker or contact Stellar Cyber support.

## License

Please refer to the license file in this repository for licensing information.

