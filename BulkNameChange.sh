#!/bin/bash

OldName=$1
NewName=$2

VMIDS=$(qm list | grep ${OldName} | awk '{print $1}')

for VMID in $VMIDS; do
  echo "changing $VMID name to $NewName"
  qm set "$VMID" --name "$NewName"
done
