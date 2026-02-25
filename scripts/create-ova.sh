#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Package a VMDK into an OVA (VMDK + OVF + manifest)
# ---------------------------------------------------------------------------
# Prerequisites:
#   - VMDK already created at output/vmdk/disk.vmdk (run create-vmdk.sh first)
#   - sha256sum available
# ---------------------------------------------------------------------------

VERSION="${VERSION:-latest}"
VM_NAME="${VM_NAME:-bootc-poc-${VERSION}}"
NUM_CPUS="${NUM_CPUS:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
DISK_CAPACITY="${DISK_CAPACITY:-60}"

VMDK_PATH="output/vmdk/disk.vmdk"
OVA_DIR="output/ova"
OVA_FILE="${OVA_DIR}/${VM_NAME}.ova"

if [[ ! -f "${VMDK_PATH}" ]]; then
    echo "ERROR: VMDK not found at ${VMDK_PATH}"
    echo "       Run 'make vmdk' first."
    exit 1
fi

echo "==> Packaging OVA: ${VM_NAME}"
echo "    VMDK:   ${VMDK_PATH}"
echo "    CPUs:   ${NUM_CPUS}"
echo "    Memory: ${MEMORY_MB} MB"
echo "    Disk:   ${DISK_CAPACITY} GiB"

mkdir -p "${OVA_DIR}"

DISK_SIZE=$(stat --format="%s" "${VMDK_PATH}" 2>/dev/null || stat -f "%z" "${VMDK_PATH}")

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

cp "${VMDK_PATH}" "${WORK_DIR}/disk.vmdk"

sed \
    -e "s/__VM_NAME__/${VM_NAME}/g" \
    -e "s/__NUM_CPUS__/${NUM_CPUS}/g" \
    -e "s/__MEMORY_MB__/${MEMORY_MB}/g" \
    -e "s/__DISK_SIZE__/${DISK_SIZE}/g" \
    -e "s/__DISK_CAPACITY__/${DISK_CAPACITY}/g" \
    configs/builder/bootc-poc.ovf > "${WORK_DIR}/${VM_NAME}.ovf"

(
    cd "${WORK_DIR}"
    sha256sum "${VM_NAME}.ovf" disk.vmdk > "${VM_NAME}.mf"
)

(
    cd "${WORK_DIR}"
    tar cf "${VM_NAME}.ova" "${VM_NAME}.ovf" disk.vmdk "${VM_NAME}.mf"
)

mv "${WORK_DIR}/${VM_NAME}.ova" "${OVA_FILE}"

echo "==> OVA created at ${OVA_FILE}"
echo "    Import into vSphere: Hosts > Deploy OVF Template > ${OVA_FILE}"
