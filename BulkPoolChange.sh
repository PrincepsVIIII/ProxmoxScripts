#!/bin/bash

#VM Name
VMName="$1"
Reverse="reverse"

if [ "$Reverse" = "reverse" ]; then
  SOURCE_POOL_PREFIX="SysSecTeam"
  SOURCE_POOL_SUFFIX=""
  DESt_POOL_PREFIX="SysSecTeam"
  DEST_POOL_SUFFIX="_hidden"
else
  SOURCE_POOL_PREFIX="SysSecTeam"
  SOURCE_POOL_SUFFIX="_hidden"
  DEST_POOL_PREFIX="SysSecTeam"
  DEST_POOL_SUFFIX=""

echo "Fetching VMs matching name filter: $VMName..."
VMIDS=$(qm list | grep "${VMName}" | awk '{print $1}')


if [[ -z "$VMIDS" ]]; then
  echo "No VMs found matching $VMName on this host."
  exit 0
fi

echo "Found VMIDs: $VMIDS"

for VMID in $VMIDS; do
  FOUND_POOL=""
  VM_NAME=$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')

  for pool in $(pvesh get /pools --output-format json | jq -r '.[].poolid'); do
    if pvesh get /pools/$pool --output-format json \
      | jq '.members[]?.vmid' 2>/dev/null | grep -q "^$VMID$"; then
      FOUND_POOL=$pool
      break
    fi
  done
  if [[ -z "$FOUND_POOL" ]]; then
    echo "No pool found for VMID $VMID"
    continue
  fi
  temp="${FOUND_POOL//$SOURCE_POOL_PREFIX/}"
  temp="${temp//$SOURCE_POOL_SUFFIX/}"
  DEST_POOL="${DEST_POOL_PREFIX}${temp}${DEST_POOL_SUFFIX}"
  echo "Moving VM: ${VM_NAME} (VMID: ${VMID} From: ${FOUND_POOL} To: ${DEST_POOL})"
  pvesh set /pools/${DEST_POOL} --vms "$VMID" --allow-move

done

echo "Complete"