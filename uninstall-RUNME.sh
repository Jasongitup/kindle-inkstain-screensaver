#!/bin/sh
LOG="/mnt/us/uninstall.log"
exec >> "$LOG" 2>&1
echo "$(date): === uninstall started ==="

# 1. Stop services
initctl stop inkstain-screensaver 2>/dev/null
initctl stop native-reading-time 2>/dev/null
echo "$(date): services stopped"

# 2. Remove Upstart configs
rm -f /etc/upstart/inkstain-screensaver.conf
rm -f /etc/upstart/native-reading-time.conf
rm -f /etc/init/inkstain-screensaver.conf
rm -f /etc/init/native-reading-time.conf
echo "$(date): upstart configs removed"

# 3. Remove all scripts and data
rm -rf /mnt/us/reading-time/
echo "$(date): reading-time directory removed"

# 4. Remove self
rm -f /mnt/us/RUNME.sh
echo "$(date): === uninstall done ==="
