#!/bin/bash

for i in {1..38}; do
    VMID=$((750 + i))


    VMID=$((750 + i))
    
    echo "Cloning VM $SOURCE_VM -> $VMID with name $NAME into $POOL (host: $TARGET_HOST, storage: $STORAGE_TARGET)..."
    qm clone $SOURCE_VM $VMID --name $NAME --target $TARGET_HOST --pool $POOL --full True --format $FORMAT --storage $STORAGE_TARGET

done