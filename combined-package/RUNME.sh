#!/bin/sh
# InkStain Screensaver + Native Reading Time combined installer entry point
# Trigger via Kindle search bar: ;log runme
#
# Setup:
#   1. Copy all files from this folder to /mnt/us/native-reading-time-package/
#   2. Copy this RUNME.sh to Kindle root (/mnt/us/RUNME.sh)
#   3. Eject Kindle, type ;log runme in search bar

PKG="/mnt/us/native-reading-time-package"
LOG="/mnt/us/reading-time/install.log"

mkdir -p /mnt/us/reading-time
echo "$(date): RUNME entry, uid=$(id -u), args=$*" >> "$LOG"

INSTALLER="$PKG/install-combined.sh"
if [ ! -f "$INSTALLER" ]; then
    echo "$(date): ERROR - installer not found: $INSTALLER" >> "$LOG"
    lipc-set-prop com.lab126.system toasterMessage "Installer not found" >/dev/null 2>&1 || true
    exit 1
fi

exec /bin/sh "$INSTALLER"
