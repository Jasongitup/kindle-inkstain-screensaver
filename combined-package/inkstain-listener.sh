#!/bin/sh
# ============================================================
# InkStain screensaver listener - single process polling
# Strategy: detect screenSaver -> wait for framework to finish
# drawing native wallpaper -> clear -> render inkstain receipt
# On wakeup: kill render, let framework restore UI naturally
# ============================================================

BASE="/mnt/us/reading-time"
RENDER="$BASE/bin/inkstain-screensaver.sh"
LOG="$BASE/inkstain-screensaver.log"
FBINK="/var/local/kmc/bin/fbink"
PID_FILE="$BASE/inkstain-render.pid"

exec >> "$LOG" 2>&1
echo "$(date): inkstain listener started, pid=$$"

if [ ! -f "$RENDER" ]; then
    echo "$(date): ERROR - render script not found: $RENDER"
    exit 1
fi

# Startup delay: short delay for framework to stabilize
# The seen_active boot protection below handles the rest
echo "$(date): startup delay 3s"
sleep 3

# Read current state as baseline — do NOT react to it
last_state=$(lipc-get-prop com.lab126.powerd state 2>/dev/null || echo "")
echo "$(date): baseline state: '$last_state' (no action on boot)"
render_active=0

# Boot protection: require seeing 'active' at least once before
# reacting to any screenSaver state. This prevents boot-time
# screenSaver transitions from triggering render.
seen_active=0
if [ "$last_state" = "active" ]; then
    seen_active=1
    echo "$(date): device already active, enabling screensaver detection"
else
    echo "$(date): device not active yet, waiting for first active state"
fi

# ========== Main loop: poll powerd state ==========
while true; do
    state=$(lipc-get-prop com.lab126.powerd state 2>/dev/null || echo "")

    if [ "$state" != "$last_state" ]; then
        echo "$(date): state changed: '$last_state' -> '$state'"
        last_state="$state"
    fi

    # Track if we've seen 'active' at least once (boot protection)
    case "$state" in
        *active*)
            if [ "$seen_active" -eq 0 ]; then
                seen_active=1
                echo "$(date): first active state detected, enabling screensaver detection"
            fi
            ;;
    esac

    # Only react to screensaver if we've seen active at least once
    case "$state" in
        *screenSaver*|*screensaver*)
            # Boot protection: skip if never seen active
            if [ "$seen_active" -eq 0 ]; then
                # Still booting, ignore screensaver state
                :
            elif [ "$render_active" -eq 0 ]; then
                # Wait for framework to finish drawing native wallpaper
                echo "$(date): screensaver detected, waiting 5s for native wallpaper"
                sleep 5

                # Verify still in screensaver before rendering
                state2=$(lipc-get-prop com.lab126.powerd state 2>/dev/null || echo "")
                case "$state2" in
                    *screenSaver*|*screensaver*|*readyToSuspend*|*suspending*|*suspended*)
                        echo "$(date): confirmed screensaver, starting render"
                        sh "$RENDER" &
                        render_pid=$!
                        echo "$render_pid" > "$PID_FILE"
                        render_active=1
                        echo "$(date): render started, pid=$render_pid"

                        # Wait for render to complete, then verify
                        sleep 3
                        if kill -0 "$render_pid" 2>/dev/null; then
                            wait "$render_pid" 2>/dev/null
                        fi

                        # Check if still in screensaver — re-render if needed
                        state3=$(lipc-get-prop com.lab126.powerd state 2>/dev/null || echo "")
                        case "$state3" in
                            *screenSaver*|*screensaver*|*readyToSuspend*|*suspending*|*suspended*)
                                echo "$(date): re-rendering to ensure visibility"
                                sh "$RENDER"
                                echo "$(date): re-render completed"
                                ;;
                            *)
                                echo "$(date): state changed to '$state3', skipping re-render"
                                ;;
                        esac
                        render_active=0
                        rm -f "$PID_FILE"
                        ;;
                    *)
                        echo "$(date): state changed to '$state2' during wait, aborting render"
                        ;;
                esac
            fi
            # Already rendering: do nothing, keep framebuffer as-is
            ;;
        *readyToSuspend*|*suspending*|*suspended*)
            # Deep sleep — keep render visible, do NOT clear
            ;;
        *active*)
            # Device is truly awake
            if [ "$render_active" -eq 1 ]; then
                # Kill render process if still running
                if [ -f "$PID_FILE" ]; then
                    pid=$(cat "$PID_FILE" 2>/dev/null)
                    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                        kill "$pid" 2>/dev/null
                        wait "$pid" 2>/dev/null
                        echo "$(date): render killed on wakeup (pid=$pid)"
                    fi
                    rm -f "$PID_FILE"
                fi
                render_active=0

                # Do NOT clear screen here — let framework restore UI naturally
                echo "$(date): wakeup detected, letting framework restore UI"
            fi
            ;;
    esac

    sleep 2
done
