#!/bin/sh

BASE="/mnt/us/reading-time"
DATA="$BASE/reading-time.tsv"
LOG="$BASE/dashboard-launch.log"
FBINK="/var/local/kmc/bin/fbink"
UI_DIR="$BASE/ui"
TOUCH="/dev/input/event1"
TOUCH_READER="$BASE/bin/reading-insights-touch.lua"
CC_DB="/var/local/cc.db"
PROGRESS_DB="$BASE/cc-progress-viewer.db"
PROGRESS_CACHE="$BASE/book-progress.tsv"

exec >> "$LOG" 2>&1
echo "$(date): interactive reading records launch, uid=$(id -u)"

fail() {
    echo "$(date): ERROR: $1"
    lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true
    exit 1
}

[ -x "$FBINK" ] || fail "未找到 Véra/KPM 系统级 FBInk"
[ -f "$UI_DIR/total.png" ] || fail "缺少阅读记录界面资源"
[ -f "$DATA" ] || fail "尚无阅读统计数据"
[ -r "$TOUCH" ] || fail "无法读取触摸设备，未打开阅读记录"
[ -f "$TOUCH_READER" ] || fail "缺少安全触摸监听器"
command -v lua >/dev/null 2>&1 || fail "未找到 Lua 运行环境"

RFONT="$BASE/fonts/NotoSansCJKsc-Regular.otf"
BFONT="$RFONT"
[ -f "$RFONT" ] || fail "缺少阅读记录中文字体"

ot() {
    ot_size="$1"; ot_top="$2"; ot_left="$3"; ot_right="$4"; ot_style="$5"; ot_msg="$6"
    "$FBINK" -q -b -t "regular=$RFONT,bold=$BFONT,px=$ot_size,top=$ot_top,left=$ot_left,right=$ot_right,style=$ot_style" "$ot_msg"
}
ot_white() {
    ow_size="$1"; ow_top="$2"; ow_left="$3"; ow_right="$4"; ow_style="$5"; ow_msg="$6"
    "$FBINK" -q -b -m -C WHITE -B BLACK -t "regular=$RFONT,bold=$BFONT,px=$ow_size,top=$ow_top,left=$ow_left,right=$ow_right,style=$ow_style" "$ow_msg"
}
ot_center() {
    oc_size="$1"; oc_top="$2"; oc_left="$3"; oc_right="$4"; oc_style="$5"; oc_msg="$6"
    "$FBINK" -q -b -m -t "regular=$RFONT,bold=$BFONT,px=$oc_size,top=$oc_top,left=$oc_left,right=$oc_right,style=$oc_style" "$oc_msg"
}
rect() {
    rect_top="$1"; rect_left="$2"; rect_width="$3"; rect_height="$4"; rect_color="$5"
    "$FBINK" -q -b -B "$rect_color" -k "top=$rect_top,left=$rect_left,width=$rect_width,height=$rect_height"
}
# Continuous, gap-free rounded rectangle approximation using horizontal
# bands. Unlike the old clipped-line outline, this has no broken corners.
round_fill() {
    rf_top="$1"; rf_left="$2"; rf_width="$3"; rf_height="$4"; rf_color="$5"
    rect $((rf_top+0)) $((rf_left+14)) $((rf_width-28)) 3 "$rf_color"
    rect $((rf_top+3)) $((rf_left+8)) $((rf_width-16)) 4 "$rf_color"
    rect $((rf_top+7)) $((rf_left+4)) $((rf_width-8)) 5 "$rf_color"
    rect $((rf_top+12)) "$rf_left" "$rf_width" $((rf_height-24)) "$rf_color"
    rect $((rf_top+rf_height-12)) $((rf_left+4)) $((rf_width-8)) 5 "$rf_color"
    rect $((rf_top+rf_height-7)) $((rf_left+8)) $((rf_width-16)) 4 "$rf_color"
    rect $((rf_top+rf_height-3)) $((rf_left+14)) $((rf_width-28)) 3 "$rf_color"
}
box() {
    box_top="$1"; box_left="$2"; box_width="$3"; box_height="$4"; box_thick="${5:-3}"
    round_fill "$box_top" "$box_left" "$box_width" "$box_height" BLACK
    inner=$((box_thick+1))
    round_fill $((box_top+inner)) $((box_left+inner)) $((box_width-inner*2)) $((box_height-inner*2)) WHITE
}
button() {
    btn_top="$1"; btn_left="$2"; btn_width="$3"; btn_height="$4"; btn_label="$5"; btn_selected="$6"
    if [ "$btn_selected" = "1" ]; then
        # This FBInk build does not reliably render white OpenType glyphs.
        # Use a soft gray selected state with black type and a short accent.
        round_fill "$btn_top" "$btn_left" "$btn_width" "$btn_height" BLACK
        round_fill $((btn_top+3)) $((btn_left+3)) $((btn_width-6)) $((btn_height-6)) GRAY8
        ot_center 34 $((btn_top+22)) $((btn_left+20)) $((1272-btn_left-btn_width+20)) BOLD "$btn_label"
        rect $((btn_top+btn_height-8)) $((btn_left+btn_width/2-50)) 100 5 BLACK
    else
        box "$btn_top" "$btn_left" "$btn_width" "$btn_height" 2
        ot_center 34 $((btn_top+22)) $((btn_left+20)) $((1272-btn_left-btn_width+20)) BOLD "$btn_label"
    fi
}
time_text() {
    tt_seconds="$1"; tt_h=$((tt_seconds/3600)); tt_m=$(((tt_seconds%3600)/60)); tt_s=$((tt_seconds%60))
    if [ "$tt_h" -gt 0 ]; then printf '%s小时%s分钟' "$tt_h" "$tt_m"
    elif [ "$tt_m" -gt 0 ]; then printf '%s分钟%s秒' "$tt_m" "$tt_s"
    else printf '%s秒' "$tt_s"; fi
}
days_in_month() {
    dim_y="$1"; dim_m="$2"
    case "$dim_m" in 1|3|5|7|8|10|12) echo 31;; 4|6|9|11) echo 30;;
        2) if { [ $((dim_y%400)) -eq 0 ] || { [ $((dim_y%4)) -eq 0 ] && [ $((dim_y%100)) -ne 0 ]; }; }; then echo 29; else echo 28; fi;;
    esac
}
# Monday-based weekday offset (0..6), calculated without GNU date -d.
weekday_offset() {
    awk -v y="$1" -v m="$2" 'BEGIN{if(m<3){m+=12;y--}k=y%100;j=int(y/100);h=(1+int(13*(m+1)/5)+k+int(k/4)+int(j/4)+5*j)%7;print (h+5)%7}'
}
shift_month() {
    sm_delta="$1"; daily_m=$((daily_m+sm_delta))
    while [ "$daily_m" -lt 1 ]; do daily_m=$((daily_m+12)); daily_y=$((daily_y-1)); done
    while [ "$daily_m" -gt 12 ]; do daily_m=$((daily_m-12)); daily_y=$((daily_y+1)); done
    selected_day=1
}

# Refresh a read-only book-progress cache once when the dashboard opens.
# Kindle's live catalog is never modified; querying a private snapshot also
# avoids holding a lock against the native library process.
refresh_progress_cache() {
    rm -f "$PROGRESS_DB" "$PROGRESS_CACHE" "$PROGRESS_CACHE.new"
    if command -v sqlite3 >/dev/null 2>&1 && [ -r "$CC_DB" ] && cp "$CC_DB" "$PROGRESS_DB" 2>/dev/null; then
        sqlite3 -readonly -separator "$(printf '\t')" "$PROGRESS_DB" \
            "SELECT CAST(p_percentFinished + 0.5 AS INTEGER), replace(replace(p_titles_0_nominal, char(9), ' '), char(10), ' ') FROM Entries WHERE p_titles_0_nominal IS NOT NULL AND p_percentFinished >= 0 AND p_percentFinished <= 100 ORDER BY p_lastAccess DESC;" \
            > "$PROGRESS_CACHE.new" 2>/dev/null || true
        [ -s "$PROGRESS_CACHE.new" ] && mv "$PROGRESS_CACHE.new" "$PROGRESS_CACHE"
    fi
    rm -f "$PROGRESS_DB" "$PROGRESS_CACHE.new"
}

draw_total() {
    total="$(awk -F '\t' 'NR>1{s+=$3}END{print s+0}' "$DATA")"
    days="$(awk -F '\t' 'NR>1&&$3>0{a[$1]=1}END{for(k in a)n++;print n+0}' "$DATA")"
    [ "$days" -gt 0 ] && average=$((total/days)) || average=0
    ot 70 390 95 60 BOLD "$(time_text "$total")"
    ot 32 520 125 680 BOLD "阅读天数  ${days}天"
    ot 32 520 730 95 BOLD "日均  $(time_text "$average")"
    ot_center 39 663 500 500 BOLD "${view_year}年"
    monthly="$(awk -F '\t' -v y="$view_year" 'NR>1&&substr($1,1,4)==y{m=substr($1,6,2)+0;s[m]+=$3}END{for(i=1;i<=12;i++)printf "%d %d\n",i,int(s[i]/60)}' "$DATA")"
    max="$(printf '%s\n' "$monthly" | awk '{if($2>m)m=$2}END{print m+0}')"
    # Keep small samples visually honest: five minutes must not fill the chart.
    if [ "$max" -le 60 ]; then scale_max=60
    elif [ "$max" -le 120 ]; then scale_max=120
    else scale_max=$((((max+59)/60)*60)); fi
    base=1390; chart_height=470; left0=82; slot=94; barw=48
    grid=1
    while [ "$grid" -le 3 ]; do
        gy=$((base-chart_height*grid/3))
        glabel=$((scale_max*grid/3)); ot 20 $((gy-26)) 82 1050 REGULAR "${glabel}分"
        grid=$((grid+1))
    done
    printf '%s\n' "$monthly" | while read -r mon mins; do
        x=$((left0+(mon-1)*slot)); h=$((mins*chart_height/scale_max)); [ "$mins" -gt 0 ] && [ "$h" -lt 8 ] && h=8
        bar_color=GRAY8
        [ "$view_year" = "$(date +%Y)" ] && [ "$mon" -eq "$(date +%m | sed 's/^0//')" ] && bar_color=BLACK
        [ "$h" -gt 0 ] && rect $((base-h)) "$x" "$barw" "$h" "$bar_color"
        ot 24 1410 "$x" $((1272-x-barw)) BOLD "${mon}月"
        [ "$mins" -gt 0 ] && ot 22 $((base-h-34)) "$x" $((1272-x-barw)) BOLD "$mins"
    done
}
draw_daily() {
    dim="$(days_in_month "$daily_y" "$daily_m")"; offset="$(weekday_offset "$daily_y" "$daily_m")"
    ot_center 39 342 500 500 BOLD "${daily_y}年${daily_m}月"
    read_days=0; day=1
    while [ "$day" -le "$dim" ]; do
        idx=$((offset+day-1)); row=$((idx/7)); col=$((idx%7)); x=$((75+col*165)); y=$((515+row*78))
        sec="$(awk -F '\t' -v d="$(printf '%04d-%02d-%02d' "$daily_y" "$daily_m" "$day")" 'NR>1&&$1==d{s+=$3}END{print s+0}' "$DATA")"
        [ "$sec" -gt 0 ] && read_days=$((read_days+1))
        if [ "$day" -eq "$selected_day" ]; then
            "$FBINK" -q -b -g "file=$UI_DIR/day-${day}.png,x=$((x-20)),y=$((y-14)),w=105,h=78"
        else
            ot 31 $((y-2)) "$x" $((1272-x-70)) BOLD "$day"
        fi
        # A single dot means this day has reading data. Minute labels were
        # intentionally removed to keep the compact calendar uncluttered.
        [ "$sec" -gt 0 ] && rect $((y+42)) $((x+24)) 14 14 BLACK
        day=$((day+1))
    done
    ot 29 948 95 60 BOLD "本月阅读 ${read_days} 天"
    selected_date="$(printf '%04d-%02d-%02d' "$daily_y" "$daily_m" "$selected_day")"
    day_total="$(awk -F '\t' -v d="$selected_date" 'NR>1&&$1==d{s+=$3}END{print s+0}' "$DATA")"
    ot 36 1060 90 60 BOLD "${daily_m}月${selected_day}日 阅读详情"
    if [ "$day_total" -gt 0 ]; then
        ot 42 1125 95 60 BOLD "共 $(time_text "$day_total")"
        y=1210
        awk -F '\t' -v d="$selected_date" 'NR>1&&$1==d{k=$2 SUBSEP $4;s[k]+=$3}END{for(k in s){split(k,a,SUBSEP);print s[k]"\t"a[2]}}' "$DATA" | sort -nr | head -3 | while IFS="$(printf '\t')" read -r sec title; do
            ot 27 "$y" 85 330 REGULAR "$title"
            ot 27 "$y" 930 55 BOLD "$(time_text "$sec")"
            y=$((y+72))
        done
    else
        ot 34 1160 95 60 REGULAR "当日无阅读记录"
    fi
}
draw_books() {
    all_books="$(awk -F '\t' 'NR>1{k=$2 SUBSEP $4;s[k]+=$3}END{for(k in s){split(k,a,SUBSEP);print s[k]"\t"a[2]"\t"a[1]}}' "$DATA" | sort -nr)"
    count="$(printf '%s\n' "$all_books" | awk 'NF{n++}END{print n+0}')"
    pages=$(((count+4)/5)); [ "$pages" -gt 0 ] || pages=1
    [ "$book_page" -gt "$pages" ] && book_page="$pages"; [ "$book_page" -lt 1 ] && book_page=1
    start=$(((book_page-1)*5+1)); end=$((start+4)); y=390; n=0
    printf '%s\n' "$all_books" | awk -v a="$start" -v b="$end" 'NR>=a&&NR<=b' | while IFS="$(printf '\t')" read -r sec title id; do
        [ -n "$title" ] || continue
        n=$((n+1))
        ot 34 "$y" 100 245 BOLD "$((start+n-1)). $title"
        ot 28 $((y+62)) 105 570 BOLD "阅读 $(time_text "$sec")"
        progress=""
        [ -f "$PROGRESS_CACHE" ] && progress="$(awk -F '\t' -v t="$title" '$2==t{print $1;exit}' "$PROGRESS_CACHE")"
        case "$progress" in ''|*[!0-9]*) progress="";; esac
        if [ -n "$progress" ]; then
            [ "$progress" -gt 100 ] && progress=100
            ot 27 $((y+62)) 940 75 BOLD "${progress}%"
            rect $((y+122)) 105 1030 20 GRAY6
            [ "$progress" -gt 0 ] && rect $((y+122)) 105 $((1030*progress/100)) 20 BLACK
        else
            ot 24 $((y+62)) 885 75 REGULAR "暂无进度"
        fi
        y=$((y+217))
    done
    ot_center 30 1504 410 410 BOLD "第 ${book_page} 页，共 ${pages} 页"
}
draw() {
    "$FBINK" -q -b -g "file=$UI_DIR/${mode}.png,x=0,y=0,w=-1,h=-1" || fail "无法显示 PNG 界面"
    case "$mode" in total) draw_total;; daily) draw_daily;; books) draw_books;; esac
    "$FBINK" -q -f -W GC16 -s
}

# Safety invariant: never disable or exclusively own touch input.
lipc-set-prop com.lab126.winmgr eatTapMode 0 >/dev/null 2>&1 || true
lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || true
cleanup() {
    lipc-set-prop com.lab126.winmgr eatTapMode 0 >/dev/null 2>&1 || true
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
    lipc-set-prop com.lab126.appmgrd start 'app://com.lab126.KPPMainApp?view=KPP_LIBRARY' >/dev/null 2>&1 || true
    sleep 1
    "$FBINK" -q -f -W GC16 -s >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

mode="total"; view_year="$(date +%Y)"; daily_y="$(date +%Y)"
# Normalize leading zeroes portably for BusyBox arithmetic.
daily_m="$(date +%m | sed 's/^0//')"; selected_day="$(date +%d | sed 's/^0//')"; book_page=1
refresh_progress_cache

while :; do
    draw
    dim="$(days_in_month "$daily_y" "$daily_m")"; offset="$(weekday_offset "$daily_y" "$daily_m")"
    action="$(lua "$TOUCH_READER" "$TOUCH" "$BASE/dashboard-touch.log" "$mode" "$offset" "$dim")" || action="exit"
    echo "$(date): dashboard action=$action mode=$mode"
    case "$action" in
        exit) break;;
        tab_total) mode="total";; tab_daily) mode="daily";; tab_books) mode="books";;
        year_prev) view_year=$((view_year-1));; year_next) view_year=$((view_year+1));;
        month_prev) shift_month -1;; month_next) shift_month 1;;
        day_*) selected_day="${action#day_}";;
        page_prev) [ "$book_page" -gt 1 ] && book_page=$((book_page-1));;
        page_next)
            book_count="$(awk -F '\t' 'NR>1{k=$2 SUBSEP $4;a[k]=1}END{for(k in a)n++;print n+0}' "$DATA")"
            book_pages=$(((book_count+4)/5)); [ "$book_pages" -gt 0 ] || book_pages=1
            [ "$book_page" -lt "$book_pages" ] && book_page=$((book_page+1))
            ;;
    esac
done

echo "$(date): interactive dashboard closed"
exit 0
