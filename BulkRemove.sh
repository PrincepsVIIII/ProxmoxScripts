#!/bin/bash
name="$1"
[ -n "$name" ] || { echo "Usage: $0 <exact VM name>"; exit 1; }
ids=$(qm list | awk -v name="$name" 'NR > 1 && $2 == name {print $1}')
[ -n "$ids" ] || { echo "No VMs named: $name"; exit 0; }
echo "VMs to destroy: $ids"
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" == [yY] ]] || exit 0
for id in $ids; do qm destroy "$id" --purge 1; done