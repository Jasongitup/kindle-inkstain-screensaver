#!/bin/sh
# ============================================================
# Combined installer: Native Reading Time Tracker + InkStain Screensaver
# Installs both components with a single ;log runme
# ============================================================

PKG="/mnt/us/native-reading-time-package"
BASE="/mnt/us/reading-time"
INSTALL_LOG="$BASE/install.log"
JOB_READING="native-reading-time"
JOB_INKSTAIN="inkstain-screensaver"
CONF_READING="/etc/upstart/${JOB_READING}.conf"
CONF_INKSTAIN="/etc/upstart/${JOB_INKSTAIN}.conf"
DAEMON="$BASE/bin/native-reading-time-daemon.sh"
RENDER="$BASE/bin/inkstain-screensaver.sh"
LISTENER="$BASE/bin/inkstain-listener.sh"
QUICKTEST="$BASE/bin/inkstain-quicktest.sh"
VIEWER="/mnt/us/documents/阅读记录.sh"
TOUCH_READER="$BASE/bin/reading-insights-touch.lua"
UI_DIR="$BASE/ui"
FONT_DIR="$BASE/fonts"

toast() { lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true; }
fail() { echo "$(date): ERROR: $1" | tee -a "$INSTALL_LOG"; toast "Install failed: $1"; exit 1; }

mkdir -p "$BASE"
echo "$(date): combined installer entered, uid=$(id -u), args=$*" >> "$INSTALL_LOG"

# ;log runme must invoke this as root
[ "$(id -u)" -eq 0 ] || fail "not running as root; use ;log runme"
echo "$(date): root invocation confirmed" >> "$INSTALL_LOG"

# Repair input state left behind by any older dashboard version
lipc-set-prop com.lab126.winmgr eatTapMode 0 >/dev/null 2>&1 || true
lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true

# ========== Prerequisite checks ==========
[ -x /sbin/initctl ] || fail "Upstart not found"
[ -f /lib/ld-linux-armhf.so.3 ] || fail "not a kindlehf device"
[ -x "/var/local/kmc/bin/fbink" ] || fail "FBInk not found (need Vera/KPM)"

# Native reading time files
[ -f "$PKG/native-reading-time-daemon.sh" ] || fail "missing daemon payload"
[ -f "$PKG/native-reading-time.conf" ] || fail "missing reading Upstart config"
[ -f "$PKG/reading-dashboard.sh" ] || fail "missing dashboard launcher"
[ -f "$PKG/reading-insights-touch.lua" ] || fail "missing touch reader"

# InkStain screensaver files
[ -f "$PKG/inkstain-render.sh" ] || fail "missing inkstain render script"
[ -f "$PKG/inkstain-listener.sh" ] || fail "missing inkstain listener script"
[ -f "$PKG/inkstain-screensaver.conf" ] || fail "missing inkstain Upstart config"
[ -f "$PKG/inkstain-style.conf" ] || fail "missing inkstain style config"

# Optional files (font, UI assets) - skip if not in package
FONT_OK=0
[ -f "$PKG/NotoSansCJKsc-Regular.otf" ] && FONT_OK=1
UI_OK=0
[ -f "$PKG/ui/total.png" ] && UI_OK=1

echo "$(date): font in package: $FONT_OK, UI in package: $UI_OK" >> "$INSTALL_LOG"

# ========== Install native reading time ==========
mkdir -p "$BASE/bin" || fail "cannot create bin directory"

cp "$PKG/native-reading-time-daemon.sh" "$DAEMON.new" || fail "cannot stage daemon"
chmod 755 "$DAEMON.new" || fail "cannot chmod daemon"
mv "$DAEMON.new" "$DAEMON" || fail "cannot install daemon"

rm -f "$BASE/bin/reading-insights-server.sh"
killall reading-insights-server.sh >/dev/null 2>&1 || true

cp "$PKG/reading-dashboard.sh" "$VIEWER" || fail "cannot install dashboard launcher"
chmod 755 "$VIEWER" || fail "cannot chmod dashboard launcher"

rm -f "/mnt/us/documents/书籍进度探测.sh"
rm -f "/mnt/us/documents/阅读页数探测.sh"
rm -f "$BASE/bin/page-turn-probe-worker.sh" "$BASE/bin/page-turn-probe.lua" "$BASE/page-turn-probe.pid"
rm -f "/mnt/us/documents/阅读洞察.sh"

cp "$PKG/reading-insights-touch.lua" "$TOUCH_READER" || fail "cannot install touch reader"
chmod 644 "$TOUCH_READER" || fail "cannot chmod touch reader"

# Install UI assets if present in package
if [ "$UI_OK" -eq 1 ]; then
    mkdir -p "$UI_DIR" || fail "cannot create UI directory"
    cp "$PKG"/ui/*.png "$UI_DIR/" || fail "cannot install UI assets"
    chmod 644 "$UI_DIR"/*.png || fail "cannot chmod UI assets"
    echo "$(date): UI assets installed" >> "$INSTALL_LOG"
elif [ ! -d "$UI_DIR" ]; then
    echo "$(date): WARNING - UI assets not in package and not installed" >> "$INSTALL_LOG"
fi

# Install font: try package first, then search Kindle system fonts
mkdir -p "$FONT_DIR" || fail "cannot create font directory"
if [ "$FONT_OK" -eq 1 ]; then
    cp "$PKG/NotoSansCJKsc-Regular.otf" "$FONT_DIR/NotoSansCJKsc-Regular.otf" || fail "cannot install CJK font"
    rm -f "$FONT_DIR/DroidSansFallback.ttf"
    [ -f "$PKG/FONT-LICENSE.txt" ] && cp "$PKG/FONT-LICENSE.txt" "$FONT_DIR/FONT-LICENSE.txt" || true
    chmod 644 "$FONT_DIR"/* || fail "cannot chmod font files"
    echo "$(date): font installed from package" >> "$INSTALL_LOG"
elif [ -f "$FONT_DIR/NotoSansCJKsc-Regular.otf" ]; then
    echo "$(date): font already installed on device" >> "$INSTALL_LOG"
else
    # Search Kindle system for CJK fonts
    # Strategy 1: known CJK font names in system and user font directories
    SYS_FONT=""
    for candidate in \
        /mnt/us/fonts/NotoSansCJKsc-Regular.otf \
        /mnt/us/fonts/NotoSansCJK-Regular.otf \
        /mnt/us/fonts/DroidSansFallback.ttf \
        /mnt/us/fonts/SourceHanSansCN-Regular.otf \
        /mnt/us/fonts/SourceHanSerifCN-Regular.otf \
        /mnt/us/fonts/CJK.ttf \
        /usr/java/lib/fonts/CJK.ttf \
        /usr/java/lib/fonts/Heiti.ttf \
        /usr/java/lib/fonts/STHeiti.ttf \
        /usr/java/lib/fonts/STKaiReg.ttf \
        /usr/java/lib/fonts/STSongReg.ttf \
        /usr/java/lib/fonts/MYingHeiGB.ttf \
        /usr/java/lib/fonts/SongTi.ttf \
        /usr/java/lib/fonts/MTChinese.ttf \
        /usr/java/lib/fonts/NotoSansCJKsc-Regular.otf \
        /usr/java/lib/fonts/NotoSansCJK-Regular.otf \
        /usr/java/lib/fonts/DroidSansFallback.ttf; do
        if [ -f "$candidate" ]; then
            SYS_FONT="$candidate"
            break
        fi
    done

    # Strategy 2: find largest font > 2MB in user fonts dir and system fonts
    if [ -z "$SYS_FONT" ]; then
        SYS_FONT=$(find /mnt/us/fonts /usr/java/lib/fonts -name "*.ttf" -o -name "*.otf" 2>/dev/null | while read f; do
            size=$(wc -c < "$f" 2>/dev/null)
            [ -n "$size" ] && [ "$size" -gt 2000000 ] && echo "$size $f"
        done | sort -rn | head -1 | cut -d' ' -f2)
    fi

    # Strategy 3: any font > 500KB
    if [ -z "$SYS_FONT" ]; then
        SYS_FONT=$(find /mnt/us/fonts /usr/java/lib/fonts -name "*.ttf" -o -name "*.otf" 2>/dev/null | while read f; do
            size=$(wc -c < "$f" 2>/dev/null)
            [ -n "$size" ] && [ "$size" -gt 500000 ] && echo "$size $f"
        done | sort -rn | head -1 | cut -d' ' -f2)
    fi

    if [ -n "$SYS_FONT" ]; then
        cp "$SYS_FONT" "$FONT_DIR/NotoSansCJKsc-Regular.otf" || fail "cannot copy font from $SYS_FONT"
        chmod 644 "$FONT_DIR/NotoSansCJKsc-Regular.otf" || fail "cannot chmod font"
        echo "$(date): font installed from: $SYS_FONT" >> "$INSTALL_LOG"
    else
        fail "No CJK font found. Place a CJK font in /mnt/us/fonts/ or native-reading-time-package/"
    fi
fi

lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || lipc-set-prop com.lab126.scanner triggerUpdate 1 >/dev/null 2>&1 || true
echo "$(date): native reading time components installed" >> "$INSTALL_LOG"

# ========== Install InkStain screensaver ==========
cp "$PKG/inkstain-render.sh" "$RENDER.new" || fail "cannot stage render script"
chmod 755 "$RENDER.new" || fail "cannot chmod render script"
mv "$RENDER.new" "$RENDER" || fail "cannot install render script"

cp "$PKG/inkstain-listener.sh" "$LISTENER.new" || fail "cannot stage listener script"
chmod 755 "$LISTENER.new" || fail "cannot chmod listener script"
mv "$LISTENER.new" "$LISTENER" || fail "cannot install listener script"

cp "$PKG/inkstain-quicktest.sh" "$QUICKTEST.new" || fail "cannot stage quicktest script"
chmod 755 "$QUICKTEST.new" || fail "cannot chmod quicktest script"
mv "$QUICKTEST.new" "$QUICKTEST" || fail "cannot install quicktest script"

# Install style config (preserve existing user config)
if [ ! -f "$BASE/inkstain-style.conf" ]; then
    cp "$PKG/inkstain-style.conf" "$BASE/inkstain-style.conf" || fail "cannot install style config"
    chmod 644 "$BASE/inkstain-style.conf" || fail "cannot chmod style config"
    echo "$(date): style config installed (default)" >> "$INSTALL_LOG"
else
    echo "$(date): style config already exists, keeping user config" >> "$INSTALL_LOG"
fi

echo "$(date): inkstain screensaver components installed" >> "$INSTALL_LOG"

# ========== Install Upstart services ==========
ROOT_RW=0
root_ro() {
    if [ "$ROOT_RW" -eq 1 ]; then
        mntroot ro >/dev/null 2>&1 || /usr/sbin/mntroot ro >/dev/null 2>&1 || /sbin/mntroot ro >/dev/null 2>&1 || true
        ROOT_RW=0
    fi
}
trap root_ro EXIT INT TERM HUP

if mntroot rw >/dev/null 2>&1 || /usr/sbin/mntroot rw >/dev/null 2>&1 || /sbin/mntroot rw >/dev/null 2>&1; then
    ROOT_RW=1
else
    fail "cannot remount rootfs"
fi

# Reading time Upstart job
cp "$PKG/native-reading-time.conf" "$CONF_READING.new" || fail "cannot stage reading Upstart job"
chmod 644 "$CONF_READING.new" || fail "cannot chmod reading Upstart job"
mv "$CONF_READING.new" "$CONF_READING" || fail "cannot install reading Upstart job"

# InkStain screensaver Upstart job
cp "$PKG/inkstain-screensaver.conf" "$CONF_INKSTAIN.new" || fail "cannot stage inkstain Upstart job"
chmod 644 "$CONF_INKSTAIN.new" || fail "cannot chmod inkstain Upstart job"
mv "$CONF_INKSTAIN.new" "$CONF_INKSTAIN" || fail "cannot install inkstain Upstart job"

/sbin/initctl reload-configuration >/dev/null 2>&1 || true
root_ro
trap - EXIT INT TERM HUP

echo "$(date): both Upstart jobs installed" >> "$INSTALL_LOG"

# ========== Start services ==========
/sbin/initctl stop "$JOB_READING" >/dev/null 2>&1 || true
/sbin/initctl stop "$JOB_INKSTAIN" >/dev/null 2>&1 || true
sleep 1
/sbin/initctl start "$JOB_READING" >/dev/null 2>&1 || true
/sbin/initctl start "$JOB_INKSTAIN" >/dev/null 2>&1 || true

# ========== Verify ==========
sleep 2
reading_ok=0
inkstain_ok=0
/sbin/initctl status "$JOB_READING" 2>/dev/null | grep -q 'start/running' && reading_ok=1
/sbin/initctl status "$JOB_INKSTAIN" 2>/dev/null | grep -q 'start/running' && inkstain_ok=1

echo "$(date): reading=$reading_ok inkstain=$inkstain_ok" >> "$INSTALL_LOG"

if [ "$reading_ok" -eq 1 ] && [ "$inkstain_ok" -eq 1 ]; then
    echo "$(date): both services running" | tee -a "$INSTALL_LOG"
    toast "Reading tracker + InkStain screensaver installed"
    sync
    exit 0
elif [ "$reading_ok" -eq 1 ]; then
    echo "$(date): reading OK, inkstain failed" | tee -a "$INSTALL_LOG"
    toast "Reading tracker OK, screensaver failed - check log"
    sync
    exit 1
elif [ "$inkstain_ok" -eq 1 ]; then
    echo "$(date): inkstain OK, reading failed" | tee -a "$INSTALL_LOG"
    toast "Screensaver OK, reading tracker failed - check log"
    sync
    exit 1
else
    echo "$(date): both services failed" | tee -a "$INSTALL_LOG"
    toast "Both services failed - check install.log"
    sync
    exit 1
fi
