#!/bin/bash
POOL_BASE="SysSecTeam"
NAME="LinuxCTF"

VMIDS=$(qm list | grep "LinuxCTF" | awk '{print $1}')

for VMID in $VMIDS; do
    echo "Stopping and destroying VM $VMID..."
    qm stop $VMID
    qm destroy $VMID --purge
    echo "$VMID stopped and destroyed."
done