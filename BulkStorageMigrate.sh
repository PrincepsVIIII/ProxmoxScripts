Name="$1"
StorageTarget="$2" #cdr-iscsi4, cdr-iscsi3

VMIDS=$(qm list | grep " ${Name} " | awk '{print $1}')

for VMID in $VMIDS; do
  echo "Moving $VMID storage to $NewName"
  qm disk move "$VMID" "scsi0" "$StorageTarget" --format qcow2 --delete True
done
