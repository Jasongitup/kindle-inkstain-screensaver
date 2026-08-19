#!/bin/sh
# ============================================================
# InkStain quick test - renders wallpaper directly, 15s then clears
# Usage: ;log runme test  or  sh /mnt/us/reading-time/bin/inkstain-quicktest.sh
# ============================================================

BASE="/mnt/us/reading-time"
RENDER="$BASE/bin/inkstain-screensaver.sh"
FBINK="/var/local/kmc/bin/fbink"
LOG="$BASE/inkstain-screensaver.log"
RENDER_LOG="$BASE/inkstain-render.log"
FONT_DIR="$BASE/fonts"
FONT_TARGET="$FONT_DIR/NotoSansCJKsc-Regular.otf"

# Find CJK font: check install location, then /mnt/us/fonts/, then system
find_font() {
    if [ -f "$FONT_TARGET" ]; then
        echo "$FONT_TARGET"
        return
    fi
    for f in /mnt/us/fonts/*.ttf /mnt/us/fonts/*.otf; do
        [ -f "$f" ] || continue
        size=$(wc -c < "$f" 2>/dev/null)
        if [ -n "$size" ] && [ "$size" -gt 500000 ]; then
            echo "$f"
            return
        fi
    done
    for f in /usr/java/lib/fonts/*.ttf /usr/java/lib/fonts/*.otf; do
        [ -f "$f" ] || continue
        size=$(wc -c < "$f" 2>/dev/null)
        if [ -n "$size" ] && [ "$size" -gt 500000 ]; then
            echo "$f"
            return
        fi
    done
}

# Show message: try -t with px= first, fallback to default FBInk rendering
msg() {
    font=$(find_font)
    "$FBINK" -q -c -W GC16 -f 2>>"$LOG"
    sleep 1
    if [ -n "$font" ]; then
        "$FBINK" -q -b -t "regular=$font,px=40,top=400,left=50,right=1800" "$1" 2>>"$LOG"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "$(date): -t failed rc=$rc, fallback default" >> "$LOG"
            "$FBINK" -q -b "$1" 2>>"$LOG"
            rc=$?
        fi
    else
        "$FBINK" -q -b "$1" 2>>"$LOG"
        rc=$?
    fi
    "$FBINK" -q -f -W GC16 2>>"$LOG"
    echo "$(date): msg '$1' rc=$rc font=${font:-none}" >> "$LOG"
    sleep 2
}

echo "$(date): === quick test started ===" >> "$LOG"

# Check render script
if [ ! -f "$RENDER" ]; then
    echo "$(date): ERROR - render script not found: $RENDER" >> "$LOG"
    msg "Render script not found"
    exit 1
fi

# Check FBInk
if [ ! -x "$FBINK" ]; then
    echo "$(date): ERROR - FBInk not found: $FBINK" >> "$LOG"
    exit 1
fi

# Check data file
if [ ! -f "$BASE/reading-time.tsv" ]; then
    echo "$(date): ERROR - reading-time.tsv not found" >> "$LOG"
    msg "No reading data"
    exit 1
fi

# Check font - try to find and install if missing
font_path=$(find_font)
if [ -z "$font_path" ]; then
    echo "$(date): ERROR - no CJK font found" >> "$LOG"
    msg "No CJK font found"
    exit 1
fi

# If font is not at expected location, copy it there
if [ "$font_path" != "$FONT_TARGET" ]; then
    mkdir -p "$FONT_DIR"
    cp "$font_path" "$FONT_TARGET" 2>/dev/null
    chmod 644 "$FONT_TARGET" 2>/dev/null
    echo "$(date): font copied from $font_path to $FONT_TARGET" >> "$LOG"
fi

msg "Rendering please wait"

# Clear old render log
> "$RENDER_LOG"

# Render with SKIP_STATE_CHECK=1
echo "$(date): rendering with SKIP_STATE_CHECK=1..." >> "$LOG"
SKIP_STATE_CHECK=1 sh "$RENDER" 2>>"$LOG"
render_exit=$?
echo "$(date): render exited with code $render_exit" >> "$LOG"

# Show render log content if render failed
if [ $render_exit -ne 0 ]; then
    echo "$(date): === render log dump ===" >> "$LOG"
    cat "$RENDER_LOG" >> "$LOG" 2>/dev/null
    echo "$(date): === end render log dump ===" >> "$LOG"
    msg "Render failed code=$render_exit"
    exit 1
fi

msg "Test OK clearing in 8s"
sleep 8
"$FBINK" -q -c -W GC16 -f 2>/dev/null || true
sleep 1
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null || true
echo "$(date): home restored, quick test done" >> "$LOG"
