#!/bin/bash

VMName="$1"
Reverse="$2"

# -------------------------
# Direction config
# -------------------------
if [[ "$Reverse" == "reverse" ]]; then
  SOURCE_POOL_PREFIX="SysSecTeam"
  SOURCE_POOL_SUFFIX=""
  DEST_POOL_PREFIX="SysSecTeam"
  DEST_POOL_SUFFIX="_hidden"
else
  SOURCE_POOL_PREFIX="SysSecTeam"
  SOURCE_POOL_SUFFIX="_hidden"
  DEST_POOL_PREFIX="SysSecTeam"
  DEST_POOL_SUFFIX=""
fi

# -------------------------
# VM lookup - Exact matches
# -------------------------
VMIDS=$(qm list | awk -v name="$VMName" '$2 == name {print $1}')

if [[ -z "$VMIDS" ]]; then
  echo "No VMs found matching $VMName"
  exit 0
fi

echo "Building VM → Pool map..."

declare -A VM_TO_POOL

while read -r pool; do
  pvesh get "/pools/$pool" --output-format json \
  | jq -r --arg pool "$pool" '.members[]?.vmid | "\(. ) \($pool)"'
done < <(pvesh get /pools --output-format json | jq -r '.[].poolid') \
| while read -r vmid pool; do
    VM_TO_POOL[$vmid]=$pool
done

# -------------------------
# Processing
# -------------------------
for VMID in $VMIDS; do

  VM_NAME=$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')

  FOUND_POOL="${VM_TO_POOL[$VMID]}"

  if [[ -z "$FOUND_POOL" ]]; then
    echo "No pool found for VMID $VMID"
    continue
  fi

  # strip current pool format
  temp="${FOUND_POOL#"$SOURCE_POOL_PREFIX"}"
  temp="${temp%"$SOURCE_POOL_SUFFIX"}"

  # build destination pool
  DEST_POOL="${DEST_POOL_PREFIX}${temp}${DEST_POOL_SUFFIX}"

  echo "Moving VM: $VM_NAME ($VMID) $FOUND_POOL → $DEST_POOL"

  pvesh set "/pools/$DEST_POOL" --vms "$VMID" --allow-move

done

echo "Complete"