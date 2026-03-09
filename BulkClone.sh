#!/bin/bash
SOURCE_VM=293
TARGET_HOST="cdr-vhost21"
POOL_BASE="SysSecTeam"
NAME="UbuntuWebServer"
FORMAT="qcow2"
STORAGE_TARGET_BASE="cdr-iscsi"

for i in {1..38}; do
    if (( i < 10 )); then
        #team numbers should be 2 digits
        POOL="${POOL_BASE}0${i}"
    else
        POOL="${POOL_BASE}${i}"
    fi
    # Balance between iscsi3 (even teams) and iscsi4 (odd teams)
    if (( i % 2 == 0 )); then
        STORAGE_TARGET="${STORAGE_TARGET_BASE}3"
    else
        STORAGE_TARGET="${STORAGE_TARGET_BASE}4"
    fi

    VMID=$((300 + i))
    
    echo "Cloning VM $SOURCE_VM -> $VMID with name $NAME into $POOL (host: $TARGET_HOST, storage: $STORAGE_TARGET)..."
    qm clone $SOURCE_VM $VMID --name $NAME --target $TARGET_HOST --pool $POOL --full True --format $FORMAT --storage $STORAGE_TARGET

done


