#!/bin/bash
SOURCE_VM=110
TARGET_HOST="cdr-vhost21"
POOL="CompetitionCloud"

## Stop and purge old pfSense VMs
#for i in {1..15}; do
#    VMID=$((1000 + i))
#    echo "Stopping and destroying VM $VMID..."
#    qm stop $VMID
#    qm destroy $VMID --purge
#done

# Deploy new pfSense VMs
for i in {1..15}; do
    VMID=$((1000 + i))
    TEAM_PAD=$(printf "%02d" $i)
    NAME="Team${TEAM_PAD}pfSense"
    
    echo "Cloning VM $SOURCE_VM -> $VMID with name $NAME into $TARGET_HOST (pool: $POOL)..."
    qm clone $SOURCE_VM $VMID --name $NAME --target $TARGET_HOST --pool $POOL
done

echo "✅ pfSense deployment into pool '$POOL' complete."