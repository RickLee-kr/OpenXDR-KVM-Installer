# OpenXDR KVM Installer 프로젝트 규칙
(DP-Installer.sh 안정 버전 동작 고정 문서)

본 규칙은 현재 안정적으로 동작하는 DP-Installer.sh의
동작, 흐름, UI, 로그, 상태 구조를 “불변 계약”으로 정의한다.

---

## A. 디렉터리 / 파일 경로 계약 (변경 금지)
다음 경로와 파일명은 고정 계약이다:
- BASE_DIR="/root/xdr-installer"
- STATE_DIR="${BASE_DIR}/state"
- STEPS_DIR="${BASE_DIR}/steps"
- STATE_FILE="${STATE_DIR}/xdr_install.state"
- LOG_FILE="${STATE_DIR}/xdr_install.log"
- CONFIG_FILE="${STATE_DIR}/xdr_install.conf"

이 경로/이름은 변경하거나 일반화하지 않는다.

---

## B. STEP 모델 계약 (ID / 순서 / 의미 고정)
STEP는 배열 기반으로 정의되며, 아래 순서와 ID는 변경 불가:

01_hw_detect  
02_hwe_kernel  
03_nic_ifupdown  
04_kvm_libvirt  
05_kernel_tuning  
06_ntpsec  
07_lvm_storage  
08_libvirt_hooks  
09_dp_download  
10_dl_master_deploy  
11_da_master_deploy  
12_sriov_cpu_affinity  
13_install_dp_cli  

- STEP 번호, ID, 순서 변경 금지
- STEP 이름은 사용자 UI 계약이므로 임의 변경 금지

---

## C. 메인 메뉴 계약
메인 메뉴는 반드시 다음 의미를 유지해야 한다:

1) 다음 STEP부터 전체 자동 실행  
2) 특정 STEP만 선택 실행  
3) 설정(Configuration)  
4) 전체 설정 검증  
5) 사용 가이드  
6) 종료  

메뉴 하단 상태 영역에는 반드시 다음 정보가 표시되어야 한다:
- 마지막 완료 STEP / 실행 시간
- DRY_RUN 상태
- DP_VERSION
- ACPS_BASE_URL
- STATE_FILE 경로

---

## D. Cancel / ESC 동작 계약
- 사용자의 Cancel / ESC는 정상 흐름이다.
- Cancel은 실패(Failure)가 아니다.
- Cancel로 인해 스크립트가 종료되거나 set -e로 중단되면 안 된다.
- STEP 실행 결과에서 “취소”와 “실패”는 명확히 구분되어야 한다.

---

## E. 자동 재부팅 계약
- ENABLE_AUTO_REBOOT 기본값은 1
- AUTO_REBOOT_AFTER_STEP_ID 기본 대상:
  - 03_nic_ifupdown
  - 05_kernel_tuning

동작 규칙:
- 재부팅 전 반드시 whiptail 안내 메시지 출력
- DRY_RUN=1 → 실제 reboot 금지 (로그만 출력)
- DRY_RUN=0 → reboot 후 즉시 종료

---

## F. 설정(Config) 키 계약
아래 설정 키들은 안정 인터페이스로 고정되며 삭제/변경 금지:

- DRY_RUN
- DP_VERSION
- ACPS_USERNAME / ACPS_PASSWORD / ACPS_BASE_URL
- ENABLE_AUTO_REBOOT / AUTO_REBOOT_AFTER_STEP_ID

### NIC 관련
- MGT_NIC, CLTR0_NIC, HOST_NIC
- MGT_NIC_RENAMED, CLTR0_NIC_RENAMED, HOST_NIC_RENAMED
- MGT_NIC_SELECTED, CLTR0_NIC_SELECTED, HOST_NIC_SELECTED
- MGT_NIC_PCI, CLTR0_NIC_PCI, HOST_NIC_PCI
- MGT_NIC_MAC, CLTR0_NIC_MAC, HOST_NIC_MAC
- MGT_NIC_EFFECTIVE, CLTR0_NIC_EFFECTIVE, HOST_NIC_EFFECTIVE

### 클러스터
- CLUSTER_NIC_TYPE (기본 BRIDGE)
- CLUSTER_BRIDGE_NAME (기본 br-cluster)

### VM 기본값
- DL_VCPUS / DL_MEMORY_GB / DL_DISK_GB
- DA_VCPUS / DA_MEMORY_GB / DA_DISK_GB

새로운 키는 **추가만 가능**, 기존 키 변경/삭제 금지.

---

## G. State 파일 계약
state 파일에는 반드시 다음 정보가 유지되어야 한다:
- LAST_COMPLETED_STEP
- LAST_RUN_TIME
- NIC identity 정보 (PCI/MAC + 최종 effective name)

이 정보는 재부팅/재실행 시 NIC 불일치 문제를 방지하기 위한 핵심 데이터이므로 제거 금지.

---

## H. DP_VERSION 분기 계약
- DP_VERSION >= 6.2.1 인 경우 v621(KT 기준) 로직 사용
- DP_VERSION <= 6.2.0 인 경우 기존 로직 유지

두 로직은 통합하거나 단순화하지 않는다.
반드시 명확한 분기로 공존해야 한다.

---

## I. STEP 10 / STEP 11 관리 IP 처리 계약 (NAT 고정 모델)

- STEP 10 (DL Master Deploy) 및 STEP 11 (DA Master Deploy)에서
  VM에 설정·사용되는 관리 IP는 호스트의 MGT 인터페이스와 무관하다.

- 해당 단계에서 사용되는 관리 IP는
  libvirt NAT 네트워크(예: 192.168.123.0/24)에 고정된 값으로,
  다음과 같이 **상수처럼 취급되는 것이 계약이다**:

  - DL Master: 192.168.123.2
  - DA Master: 192.168.123.3

- 이 IP 값은 다음 이유로 절대 변경하거나 자동 계산하지 않는다:
  1) VM 최초 배포 및 설치 안정성 확보
  2) NIC rename, bridge 구성, 재부팅 여부와 독립된 동작 보장
  3) 자동화 스크립트 및 후속 CLI 접근의 일관성 유지

- STEP 10 / 11에서는 다음 행위를 금지한다:
  - 호스트 MGT 인터페이스 IP를 읽어 VM 관리 IP로 사용하는 행위
  - 사용자 입력 또는 외부 NIC 상태에 따라 관리 IP를 변경하는 행위
  - NAT 고정 IP 모델을 “정리” 또는 “일반화”하는 리팩토링

- NAT 고정 IP 모델은 현재 안정 버전의 핵심 설계이며,
  사용자가 명시적으로 요청하지 않는 한 변경 불가하다.

---

## J. 메모리 단위 계약
- DL/DA 메모리는 GB 단위로 저장
- 실제 libvirt 적용 시:
  - GB × 1024 × 1024 = KiB
- 단위 변경 또는 계산식 변경 금지

---

## K. 문자열 변경 금지
- 모든 whiptail 제목/본문/선택지
- 모든 로그 문구

위 문자열들은 안정 UI 계약이다.  
사용자가 “문구 변경”을 명시적으로 요청하지 않는 한 수정 금지.

---

## L. 이 계약 하에서 수정하는 방법
버그 수정 또는 기능 추가 시 Cursor는 반드시:

1) 영향 범위를 단일 STEP 또는 단일 함수로 제한한다
2) 기존 흐름, 반환값, 상태 저장 방식을 유지한다
3) 새 로직은:
   - config 플래그
   - DP_VERSION 분기
   - 사용자 명시적 확인
   중 하나 뒤에 배치한다
4) 기존 로그는 유지하고, 새 로그만 추가한다
5) 자동 이어서 실행(auto-continue) 동작을 절대 깨지 않는다

수정 결과는 반드시:
- 최소 diff
- 변경되지 않은 부분 명시
- 안정성 영향 없음 설명
을 포함해야 한다.

