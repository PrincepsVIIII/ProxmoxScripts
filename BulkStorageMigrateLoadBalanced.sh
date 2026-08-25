#!/bin/bash
set -euo pipefail

VM_NAME="${1:-}"
DISK="${2:-scsi0}"

ODD_STORAGE="${ODD_STORAGE:-cdr-iscsi3}"
EVEN_STORAGE="${EVEN_STORAGE:-cdr-iscsi4}"
TEAM_POOL_REGEX='^[Ss]ys[Ss]ec[Tt]eam0*([0-9]+)(_hidden)?$'

if [[ -z "$VM_NAME" ]]; then
  echo "Usage: $0 <vm-name> [disk]"
  echo "Example: $0 Pentesting-Lab"
  echo "Odd SysSecTeam pools move to:  $ODD_STORAGE"
  echo "Even SysSecTeam pools move to: $EVEN_STORAGE"
  exit 1
fi

VMIDS=$(qm list | awk -v name="$VM_NAME" '$2 == name {print $1}')

if [[ -z "$VMIDS" ]]; then
  echo "No VMs found with exact name: $VM_NAME"
  exit 0
fi

echo "Building VM to pool map..."

declare -A VM_TO_POOL

while read -r pool; do
  [[ -z "$pool" ]] && continue

  while read -r vmid; do
    [[ -z "$vmid" || "$vmid" == "null" ]] && continue
    VM_TO_POOL[$vmid]="$pool"
  done < <(
    pvesh get "/pools/$pool" --output-format json |
      jq -r '.members[]? | select(.type == "qemu") | .vmid'
  )
done < <(pvesh get /pools --output-format json | jq -r '.[].poolid')

for VMID in $VMIDS; do
  POOL="${VM_TO_POOL[$VMID]:-}"

  if [[ -z "$POOL" ]]; then
    echo "Skipping VMID $VMID ($VM_NAME): no pool found"
    continue
  fi

  if [[ ! "$POOL" =~ $TEAM_POOL_REGEX ]]; then
    echo "Skipping VMID $VMID ($VM_NAME): pool '$POOL' is not a SysSecTeam pool"
    continue
  fi

  TEAM_NUMBER="${BASH_REMATCH[1]}"

  if (( 10#$TEAM_NUMBER % 2 == 1 )); then
    STORAGE_TARGET="$ODD_STORAGE"
  else
    STORAGE_TARGET="$EVEN_STORAGE"
  fi

  echo "Moving VMID $VMID ($VM_NAME, pool: $POOL, disk: $DISK) to $STORAGE_TARGET"
  qm disk move "$VMID" "$DISK" "$STORAGE_TARGET" --format qcow2 --delete true
done

echo "Complete"
