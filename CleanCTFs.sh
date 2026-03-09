#!/bin/bash
POOL_BASE="SysSecTeam"
NAME="LinuxCTF"

VMIDS=$(qm list | grep "LinuxCTF" | awk '{print $1}')